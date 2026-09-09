// KlariVision Android — "Birlikte Çal" modu mikrofon oturumu orkestrasyonu.
// macOS `StudyWorkspace.swift`'teki `TogetherSession` sınıfının (satır
// ~421-535) BİREBİR aynasıdır — özellikle `handle(...)` metodunun gönderme
// kuralları burada aynen taşınır. Dinleme grafiği çalarken mikrofonu da açık
// tutar: kullanıcının çaldığı eğri, referans eğrinin üstüne ayrı renkle
// çizilir. Puanlama/karşılaştırma YOK, pitch KARARI üretilmez (eşik/
// yumuşatma/oktav düzeltme icat edilmez) — yalnız Dinleme tarafının zaten
// kullandığı eleme eşikleri (frequency ≥ 80 Hz, confidence ≥ 0.20) uygulanır.
//
// Compose UI burada YAZILMAZ (ekran T5'in işi) — bu yalnız orkestratör
// katmanıdır. `state/LiveCaptureEngine` arayüzü (DEĞİŞTİRİLMEDİ) yeniden
// kullanılır; gerçek mikrofon motoru `state/LiveAudioCaptureEngine` üzerinden
// bağlanır.
//
// ÖNEMLİ ZAMAN TABANI FARKI (macOS'tan sapma, kasıtlı): macOS'ta
// `LivePitchFrame.time` duvar saatiyle (`Date().timeIntervalSinceReferenceDate`)
// aynı taban çizgisini paylaşır. Android'de `CorePitchFrame.time`
// (`study.PitchFrame.time`) `live/SampleClock`'tan gelir — mikrofon
// başladığında SIFIRLANAN, oturuma göreli bir sayaçtır. Bu yüzden her karenin
// duvar-saati karşılığı, mikrofon başlarken örneklenen [sessionStartWallSeconds]
// ile kurulur: `frameWallTime = sessionStartWallSeconds + frame.time`. Bu,
// [TogetherTimeMapping.mapFrameToMediaTime]'ın beklediği "frameTime ve wallNow
// aynı taban çizgisini paylaşır" varsayımını Android'in kendi zaman
// modeliyle yeniden kurar; formülün kendisi DEĞİŞMEZ.

package com.aykerme.klarivision.together

import android.content.Context
import android.util.Log
import com.aykerme.klarivision.state.LiveAudioCaptureEngine
import com.aykerme.klarivision.state.LiveCaptureEngine
import com.aykerme.klarivision.study.PitchFrame
import com.aykerme.klarivision.web.MicPoint
import com.aykerme.klarivision.web.PlaybackSnapshot
import com.aykerme.klarivision.web.StudyCommand
import kotlin.math.pow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Birlikte Çal modu UI'sinin tek gerçek kaynağı. */
data class TogetherUiState(
    val isRunning: Boolean = false,
    val muted: Boolean = false,
    val permissionRequired: Boolean = false,
    val errorMessage: String? = null,
    val latencySource: InputLatencySource? = null,
    val latencySeconds: Double? = null,
)

/**
 * "Birlikte Çal" modunun asıl davranışı: mikrofonu [LiveCaptureEngine]
 * arkasından çalıştırır, her perde karesini medyanın zaman eksenine çevirir
 * ve yalnız oynatma sürerken viewer'a yollar. Loop B→A dönüşü ve zamanda
 * geri sürükleme burada ELE ALINIR — Android StudyViewer.html'in kendi
 * `tick()` döngüsü macOS'un `frequency_viewer.py` tabanlı sayfasının aksine
 * bunu KENDİ BAŞINA tespit etmez; bu yüzden [onPlaybackSnapshot] geriye
 * sıçramayı burada yakalayıp `micTruncate` gönderir (bkz. görev notu).
 */
class TogetherOrchestrator(
    private val capture: LiveCaptureEngine,
    private val sendCommand: (StudyCommand) -> Unit,
    private val hasRecordAudioPermission: () -> Boolean,
    private val measureLatency: () -> InputLatencyEstimate,
    private val micColor: () -> String = { DEFAULT_MIC_COLOR },
    private val micAlignmentMs: () -> Double = { 0.0 },
    private val wallClockSeconds: () -> Double = { System.currentTimeMillis() / 1_000.0 },
    private val minimumRms: Double = DEFAULT_MINIMUM_RMS,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val log: (String) -> Unit = { Log.i(TAG, it) },
) {
    /**
     * Üretim kısa yolu: gerçek `AudioRecord` motorunu ([LiveAudioCaptureEngine])
     * ve gerçek Android gecikme ölçümünü ([AndroidLatencyMeasurementSource])
     * bağlar. `sendCommand`, çağıran tarafın (P5a) `StudyGraphBridge::enqueue`
     * gibi bir köprüye bağladığı lambdadır — bu sınıf `StudyGraphBridge`'i
     * (WebView gerektirir) DOĞRUDAN tutmaz, JVM testleriyle koşabilsin diye.
     */
    constructor(
        context: Context,
        sendCommand: (StudyCommand) -> Unit,
        micColor: () -> String = { DEFAULT_MIC_COLOR },
        micAlignmentMs: () -> Double = { 0.0 },
    ) : this(
        capture = LiveAudioCaptureEngine(context),
        sendCommand = sendCommand,
        hasRecordAudioPermission = {
            androidx.core.content.ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.RECORD_AUDIO,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        },
        measureLatency = { InputLatencyProbe.estimate(AndroidLatencyMeasurementSource(context)) },
        micColor = micColor,
        micAlignmentMs = micAlignmentMs,
    )

    private val _uiState = MutableStateFlow(TogetherUiState())
    val uiState: StateFlow<TogetherUiState> = _uiState.asStateFlow()

    /** Son işlenen mikrofon karesinin (oturuma göreli) zamanı — bkz. sınıf başı yorumu. */
    private var lastSeenFrameTime: Double? = null

    /** Mikrofon oturumu başladığında örneklenen duvar-saati taban çizgisi. */
    private var sessionStartWallSeconds: Double? = null

    /** `onPlaybackSnapshot`'tan gelen en güncel oynatma durumu. */
    private var latestSnapshot: PlaybackSnapshot? = null

    /** Bu oturum için seçilen giriş gecikmesi (saniye) — `start()`'ta bir kez ölçülür. */
    private var currentLatencySeconds: Double = InputLatencyProbe.FALLBACK_LATENCY_SECONDS

    /**
     * Modu açar: izin kontrolü → `micClear()` → `setMicColor(...)` → gecikme
     * ölçümü → mikrofon başlat. İzin yoksa mod hiç açılmaz, Türkçe açık hata
     * `uiState.errorMessage`'a yazılır. Zaten çalışıyorsa yok sayılır
     * (idempotent) — [LiveOrchestrator.start] ile aynı disiplin.
     */
    fun start() {
        if (_uiState.value.isRunning) return

        if (!hasRecordAudioPermission()) {
            _uiState.update {
                it.copy(permissionRequired = true, errorMessage = PERMISSION_DENIED_MESSAGE)
            }
            return
        }

        _uiState.update { it.copy(errorMessage = null, permissionRequired = false) }
        lastSeenFrameTime = null
        latestSnapshot = null

        sendCommand(StudyCommand.MicClear)
        sendCommand(StudyCommand.SetMicColor(micColor()))

        val latency = measureLatency()
        currentLatencySeconds = latency.seconds
        log(
            "Birlikte Çal giriş gecikmesi: ${(latency.seconds * 1_000).toInt()} ms " +
                "(kaynak: ${latency.source})",
        )
        _uiState.update { it.copy(latencySource = latency.source, latencySeconds = latency.seconds) }

        scope.launch {
            try {
                capture.start(minimumRms, ::handleFrames, {}, ::handleFailure)
                sessionStartWallSeconds = wallClockSeconds()
                _uiState.update { it.copy(isRunning = true) }
            } catch (permission: SecurityException) {
                _uiState.update {
                    it.copy(isRunning = false, permissionRequired = true, errorMessage = PERMISSION_DENIED_MESSAGE)
                }
            } catch (error: Exception) {
                _uiState.update {
                    it.copy(isRunning = false, errorMessage = error.message ?: "Mikrofon başlatılamadı.")
                }
            }
        }
    }

    /**
     * TEK teardown noktası: mikrofonu kapatır. Mod kapanırken/ekrandan
     * çıkarken bunun çağrılması ŞART — aksi halde mikrofon açık kalır
     * (macOS `closeWorkspaceAfterPausing` ile aynı disiplin). İdempotenttir:
     * art arda çağrılar güvenlidir, ikinci çağrı hiçbir şey yapmaz dışında
     * `capture.stop()`'u tekrar tetiklemez.
     */
    fun stop() {
        if (!_uiState.value.isRunning && sessionStartWallSeconds == null) return
        sessionStartWallSeconds = null
        lastSeenFrameTime = null
        latestSnapshot = null
        _uiState.update { it.copy(isRunning = false) }
        scope.launch {
            try {
                capture.stop()
            } catch (_: Exception) { /* zaten durmuş olabilir */ }
        }
    }

    /** Hoparlörden çalarken akustik geri beslemeyi önlemek için medya sesini kapat/aç. */
    fun setMuted(muted: Boolean) {
        _uiState.update { it.copy(muted = muted) }
        sendCommand(StudyCommand.Mute(muted))
    }

    /**
     * UI katmanının (T5), `StudyOrchestrator.uiState.playback`'ten gelen her
     * yeni anlık görüntüyü ilettiği giriş noktası. Hem kare→medya zamanı
     * çevirisinde kullanılacak en güncel saat/hız/oynatma durumunu tutar hem
     * de geriye sıçramayı (arama veya loop B→A dönüşü) tespit edip
     * `micTruncate` gönderir.
     */
    fun onPlaybackSnapshot(snapshot: PlaybackSnapshot) {
        val previous = latestSnapshot
        latestSnapshot = snapshot
        if (previous != null && snapshot.time < previous.time - BACKWARD_JUMP_TOLERANCE_SECONDS) {
            sendCommand(StudyCommand.MicTruncate(snapshot.time))
        }
    }

    /**
     * Kümülatif kare akışını medya zamanına çevirip viewer'a yollar.
     * macOS `TogetherSession.handle(...)`'daki gönderme kuralları BİREBİR:
     *  1) Yalnız oynarken nokta üret; duraklatılmışken imleci yine de
     *     ilerlet ki oynatma yeniden başladığında biriken kareler toptan
     *     gönderilmesin.
     *  2) Kareler kümülatif gelir; yalnız `frame.time > cursor` olanlar alınır.
     *  3) Her kare KENDİ `time`'ı üzerinden çevrilir (toplu gönderimde tek
     *     zaman damgası verilmez).
     *  4) Eleme: frequency sonlu ve ≥ 80 Hz, confidence ≥ 0.20.
     *  5) Sonuç mediaTime sonlu ve ≥ 0 olmalı; değilse kare atılır.
     *  6) Hiç nokta kalmadıysa köprüye çağrı yapılmaz.
     */
    private fun handleFrames(frames: List<PitchFrame>) {
        val snapshot = latestSnapshot
        if (snapshot == null || !snapshot.isPlaying) {
            lastSeenFrameTime = frames.lastOrNull()?.time ?: lastSeenFrameTime
            return
        }

        val cursor = lastSeenFrameTime
        val additions = frames.filter { frame -> cursor?.let { frame.time > it } ?: true }
        lastSeenFrameTime = frames.lastOrNull()?.time ?: lastSeenFrameTime
        if (additions.isEmpty()) return

        val wallNow = wallClockSeconds()
        val startWall = sessionStartWallSeconds ?: wallNow
        val clockNow = snapshot.time
        val rate = snapshot.rate
        val userAlignmentSeconds = TogetherTimeMapping.clampMicAlignmentMs(micAlignmentMs()) / 1_000.0
        val fixedLatency = TogetherTimeMapping.fixedLatency(currentLatencySeconds)

        val points = additions.mapNotNull { frame ->
            if (!frame.frequency.isFinite() || frame.frequency < MIN_FREQUENCY_HZ) return@mapNotNull null
            if (frame.confidence < MIN_CONFIDENCE) return@mapNotNull null

            val frameWallTime = startWall + frame.time
            val mediaTime = TogetherTimeMapping.mapFrameToMediaTime(
                clockNow = clockNow,
                wallNow = wallNow,
                frameTime = frameWallTime,
                rate = rate,
                userAlignmentSeconds = userAlignmentSeconds,
                fixedLatency = fixedLatency,
            )
            if (!mediaTime.isFinite() || mediaTime < 0.0) return@mapNotNull null
            MicPoint(time = mediaTime, frequency = frame.frequency)
        }
        if (points.isEmpty()) return
        sendCommand(StudyCommand.MicAppend(points))
    }

    private fun handleFailure(message: String) {
        scope.launch { try { capture.stop() } catch (_: Exception) { /* zaten durmuş olabilir */ } }
        sessionStartWallSeconds = null
        lastSeenFrameTime = null
        _uiState.update { it.copy(isRunning = false, errorMessage = message) }
    }

    companion object {
        private const val TAG = "TogetherOrchestrator"

        /** Dinleme tarafıyla aynı eleme eşikleri (bkz. macOS `StudyPitchTrack.minimumConfidence`). */
        const val MIN_FREQUENCY_HZ = 80.0
        const val MIN_CONFIDENCE = 0.20

        /**
         * Geriye sıçrama toleransı: normal ileri oynatımda `time` küçük
         * gürültülerle bile monoton artar; bu eşiğin altındaki azalışlar
         * gerçek bir arama/loop dönüşü değil, ölçüm gürültüsü sayılır.
         */
        const val BACKWARD_JUMP_TOLERANCE_SECONDS = 0.05

        const val DEFAULT_MIC_COLOR = "#FF9F0A"

        private const val PERMISSION_DENIED_MESSAGE =
            "Mikrofon izni verilmedi. Birlikte Çal modu açılamıyor — Ayarlar'dan izin verip yeniden deneyin."

        /** iPad/Live tarafıyla aynı varsayılan sinyal kapısı: 10^(-42/20). */
        private val DEFAULT_MINIMUM_RMS = 10.0.pow(-42.0 / 20.0)
    }
}
