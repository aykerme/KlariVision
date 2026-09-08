// KlariVision Android — Çalma (canlı) modu durum orkestrasyonu, Swift
// iPadLiveState'ten (LiveAnalyzer.swift) port edildi. Mikrofon yakalama
// motorunun kendisi (AudioRecord döngüsü) bu P5b'nin kapsamı DIŞINDA —
// `live/` paketine ayrı bir ajan yazıyor (bkz. görev notu). Bu dosya yalnız
// [LiveCaptureEngine] arayüzü arkasından o motoru sıralar; gerçek uygulama
// entegre edildiğinde bu arayüzü karşılayan bir sınıf DI ile geçirilir.
//
// Bu katman pitch KARARI üretmez — yalnız `live/`, `study/` ve `web/`
// katmanlarını sıralar.

package com.aykerme.klarivision.state

import android.content.Context
import com.aykerme.klarivision.live.LiveLifecycle
import com.aykerme.klarivision.live.RecordingPhase
import com.aykerme.klarivision.live.Tuner
import com.aykerme.klarivision.music.Karar
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.MusicContext
import com.aykerme.klarivision.music.ScaleDisplay
import com.aykerme.klarivision.study.PitchFrame
import com.aykerme.klarivision.web.GuidePayload
import com.aykerme.klarivision.web.LiveContextPayload
import com.aykerme.klarivision.web.LiveGraphBridge
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Canlı akışın durum makinesi aşamaları. `LivePhase` (live/ paketi, canlı
 * yakalama motorunun kendi durum makinesi) ile adı çakışmasın diye `2` eki
 * taşır — bu, orkestratörün DIŞA verdiği, UI'nin tükettiği ayrı bir sözleşme.
 */
enum class LivePhase2 { STOPPED, STARTING, RUNNING, FAILED }

/** Çalma modu UI'sinin tek gerçek kaynağı. */
data class LiveUiState(
    val phase: LivePhase2 = LivePhase2.STOPPED,
    val isRecording: Boolean = false,
    val tunerNote: String? = null,
    val tunerCents: Double? = null,
    val permissionRequired: Boolean = false,
    val errorMessage: String? = null,
)

/** Ekranın uykuya geçmemesi gereken aşamalar (bkz. görev notu "Boşta kalma politikası"). */
val LiveUiState.keepScreenOn: Boolean
    get() = phase == LivePhase2.STARTING || phase == LivePhase2.RUNNING

/**
 * Mikrofon yakalama motorunun [LiveOrchestrator]'ın ihtiyaç duyduğu yüzeyi —
 * Swift `iPadLiveAnalyzer`'ın (`start`/`stop`/`toggleRecording` + kare/kayıt/
 * hata sink'leri) Kotlin karşılığı. Gerçek `AudioRecord` tabanlı uygulama bu
 * P5b'nin kapsamı dışında ayrı yazılıyor; bu arayüz yalnız o motorla bu
 * orkestratör arasındaki sözleşmeyi sabitler.
 */
interface LiveCaptureEngine {
    /**
     * Yakalamayı başlatır. `onFrames`/`onRecording` UI iş parçacığında
     * (orkestratörün kendi kapsamında) çağrılabilir kabul edilir. İzin
     * reddi [SecurityException], diğer başlatma hataları başka bir
     * [Exception] (Türkçe, kullanıcıya gösterilebilir mesajlı) fırlatmalıdır.
     */
    suspend fun start(
        minimumRms: Double,
        onFrames: (List<PitchFrame>) -> Unit,
        onRecording: (RecordingPhase) -> Unit,
        onFailure: (String) -> Unit,
    )

    /** Yakalamayı durdurur; süregelen bir WAV kaydı varsa tamamlar ve döner. */
    suspend fun stop(): RecordingPhase

    /** WAV kaydını başlatır/bitirir; motor çalışmıyorsa mevcut durumu döner. */
    suspend fun toggleRecording(): RecordingPhase
}


/** Varsayılan sinyal kapısı — iPad tarafının `signalGateDbFS = -42` varsayılanıyla aynı ruhta. */
private const val DEFAULT_MINIMUM_RMS = 0.0079432823 // 10^(-42/20)

private const val PITCH_COLOR = "#67d5ff"
private const val GUIDE_COLOR = "#b7d8ff"
private const val KARAR_COLOR = "#E75A5A"

/**
 * Çalma (canlı) modunun durum orkestratörü. Mikrofon/kayıt/tuner'ı
 * [LiveCaptureEngine] arkasından sıralar, kareleri [LiveGraphBridge]'e taşır.
 */
class LiveOrchestrator(
    private val capture: LiveCaptureEngine,
    private val minimumRms: Double = DEFAULT_MINIMUM_RMS,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    /**
     * Üretim kısa yolu: gerçek `AudioRecord` motorunu
     * ([LiveAudioCaptureEngine] üzerinden `live/LiveAudioCapture`) bağlar.
     * Yaşam döngüsü (onPause/onStop) durdurmaları için motorun
     * `attachLifecycle` çağrısı gerekiyorsa, motoru dışarıda kurup birincil
     * kurucuyu kullanın — `MainActivity` bunu yapar.
     */
    constructor(context: Context) : this(capture = LiveAudioCaptureEngine(context))

    private val lifecycle = LiveLifecycle()
    private val _uiState = MutableStateFlow(LiveUiState())
    val uiState: StateFlow<LiveUiState> = _uiState.asStateFlow()

    private var bridge: LiveGraphBridge? = null
    private var makam: Makam = Makam.NIHAVEND
    private var karar: Karar = Karar.RE
    private var scaleDisplay: ScaleDisplay = ScaleDisplay.MAKAM
    private var followsCurve: Boolean = true

    /** WebView'i barındıran köprüyü bağlar. UI, Compose `remember` ile sahipliği tutar. */
    fun attachBridge(bridge: LiveGraphBridge) {
        this.bridge = bridge
        publishContext()
    }

    /** Mikrofonu başlatır. Zaten başlıyor/çalışıyorsa yok sayılır (idempotent). */
    fun start() {
        val phase = _uiState.value.phase
        if (phase == LivePhase2.STARTING || phase == LivePhase2.RUNNING) return
        lifecycle.requestStart()
        _uiState.update { it.copy(phase = LivePhase2.STARTING, errorMessage = null, permissionRequired = false) }
        scope.launch {
            try {
                bridge?.load()
                // Yeni oturum, sample sayacını sıfırlar — grafiği de temizle
                // ki eski takip yeni takibin üstüne çizilmesin (bkz. iPad
                // `iPadLiveState.start` yorumu).
                bridge?.reset()
                capture.start(minimumRms, ::onFrames, ::onRecording, ::onFailure)
                lifecycle.started()
                publishContext()
                bridge?.setRunning(true)
                _uiState.update { it.copy(phase = LivePhase2.RUNNING, errorMessage = null) }
            } catch (permission: SecurityException) {
                bridge?.setRunning(false)
                lifecycle.stopped(reason = null)
                _uiState.update {
                    it.copy(
                        phase = LivePhase2.STOPPED,
                        permissionRequired = true,
                        errorMessage = "Mikrofon izni verilmedi. Ayarlar'dan izin verip yeniden başlatın.",
                    )
                }
            } catch (error: Exception) {
                bridge?.setRunning(false)
                val message = error.message ?: "Mikrofon başlatılamadı."
                lifecycle.failed(message)
                _uiState.update { it.copy(phase = LivePhase2.FAILED, errorMessage = message) }
            }
        }
    }

    /** Mikrofonu durdurur. `analyzer.stop` gibi zaten durmuşsa idempotenttir. */
    fun stop() {
        bridge?.setRunning(false)
        scope.launch {
            capture.stop()
            lifecycle.stopped(reason = null)
            _uiState.update { it.copy(phase = LivePhase2.STOPPED) }
        }
    }

    /** WAV kaydını açar/kapatır. */
    fun toggleRecording() {
        scope.launch {
            val result = capture.toggleRecording()
            onRecording(result)
        }
    }

    /**
     * Sistem izin dialoğunun sonucunu bildirir. `granted == true` ise
     * mikrofonu hemen başlatır; değilse `permissionRequired` işaretlenir.
     */
    fun onPermissionResult(granted: Boolean) {
        if (granted) {
            _uiState.update { it.copy(permissionRequired = false) }
            start()
        } else {
            _uiState.update {
                it.copy(
                    phase = LivePhase2.STOPPED,
                    permissionRequired = true,
                    errorMessage = "Mikrofon izni verilmedi. Ayarlar'dan izin verip yeniden başlatın.",
                )
            }
        }
    }

    /** Müzik bağlamını (makam/karar/gösterim) günceller ve grafiğe yollar. */
    fun applyMusicContext(makam: Makam, karar: Karar, scaleDisplay: ScaleDisplay) {
        this.makam = makam
        this.karar = karar
        this.scaleDisplay = scaleDisplay
        publishContext()
    }

    private fun onFrames(frames: List<PitchFrame>) {
        val lastVoiced = frames.lastOrNull { it.voiced && it.frequency > 0 }
        if (lastVoiced != null) {
            _uiState.update {
                it.copy(tunerNote = Tuner.label(lastVoiced.frequency), tunerCents = centsOffset(lastVoiced.frequency))
            }
        }
        bridge?.append(frames)
    }

    private fun onRecording(phase: RecordingPhase) {
        _uiState.update { it.copy(isRecording = phase is RecordingPhase.Active) }
    }

    private fun onFailure(message: String) {
        scope.launch { capture.stop() }
        bridge?.setRunning(false)
        lifecycle.failed(message)
        _uiState.update { it.copy(phase = LivePhase2.FAILED, errorMessage = message) }
    }

    private fun publishContext() {
        val activeBridge = bridge ?: return
        val musicContext = MusicContext(makam = makam, karar = karar, followsCurve = followsCurve, scaleDisplay = scaleDisplay)
        activeBridge.setContext(
            LiveContextPayload(
                makam = makam.displayName,
                karar = karar.displayName,
                guides = musicContext.guideNotes().map { GuidePayload(name = it.name, hz = it.hz, karar = it.isKarar) },
                follow = followsCurve,
                pitchColor = PITCH_COLOR,
                guideColor = GUIDE_COLOR,
                kararColor = KARAR_COLOR,
            ),
        )
    }
}

/** En yakın yarım tondan sapma, cent cinsinden (±50 aralığında). A4 = 440 Hz referans. */
private fun centsOffset(frequencyHz: Double): Double? {
    if (frequencyHz <= 0 || !frequencyHz.isFinite()) return null
    val midi = 69 + 12 * (ln(frequencyHz / 440.0) / ln(2.0))
    return (midi - midi.roundToInt()) * 100.0
}
