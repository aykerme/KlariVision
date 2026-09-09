// KlariVision Android — çevrimdışı medya çözme + pitch analizi hattı
// (dosya -> PCM -> pitch kareleri). Swift kaynağı: `iPadOfflinePitchAnalyzer`
// (StudyModels.swift). Bu katman pitch KARARI üretmez: eşikleme, yumuşatma,
// oktav düzeltme YOKTUR. Yalnız PCM'i hazırlar (mono + 48 kHz Float32) ve
// C++ çekirdeğinin ürettiği kareleri taşır.

package com.aykerme.klarivision.study

import com.aykerme.klarivision.core.OfflineTrackSession
import com.aykerme.klarivision.core.PitchFrame as CorePitchFrame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * `pitch_track_cli.cpp`'deki KV-PROGRESS aşama adlarıyla (`decode`,
 * `pitch`, `write`) birebir aynı token'lar — bir UI bu isimlere göre
 * görüntü metni eşleyebilir.
 */
enum class AnalysisStage(val token: String) {
    DECODE("decode"),
    PITCH("pitch"),
    WRITE("write"),
}

/**
 * Bir analiz aşamasının anlık durumu.
 *
 * `fraction == null`, aşamanın BELİRSİZ (indeterminate) olduğunu gösterir —
 * yalnız [AnalysisStage.PITCH] için geçerlidir: `OfflineTrackSession.finish()`
 * TEK BLOKLAYICI ÇAĞRIDIR ve ilerleme kancası yoktur (bkz.
 * `OfflineTrackSession.finish` KDoc'u ve `pitch_track_cli.cpp`'deki "pitch"
 * aşaması açıklaması — macOS'ta 191 s ses ≈ 50 s sürer). UI bu durumda
 * donmuş bir yüzde göstermek yerine belirsiz bir gösterge çizmelidir.
 */
data class AnalysisProgress(val stage: AnalysisStage, val fraction: Double?)

/** Çözme + analiz hattının sonucu. */
data class OfflineAnalysisResult(val frames: List<PitchFrame>, val durationSeconds: Double)

/**
 * `OfflineTrackSession`'ın test edilebilir yüzeyi. Üretimde gerçek
 * [OfflineTrackSession]'a ([OfflineTrackSessionAdapter] ile) sarılır; JVM
 * testlerinde native kütüphane yüklenemeyeceği için (bkz. `NativeBridge`
 * `System.loadLibrary`) sahte bir uygulamayla değiştirilebilir.
 * `OfflineTrackSession`'ın kendisi DEĞİŞTİRİLMEDİ — bu yalnız ince bir
 * ek arayüzdür.
 */
interface OfflineEngineSession : AutoCloseable {
    fun push(samples: FloatBuffer, sampleRateHz: Double)
    fun finish(): Int
    fun frame(index: Int): CorePitchFrame
}

/** [OfflineEngineSession] arayüzünü gerçek [OfflineTrackSession]'a bağlar. */
class OfflineTrackSessionAdapter(
    private val session: OfflineTrackSession = OfflineTrackSession.create(),
) : OfflineEngineSession {
    override fun push(samples: FloatBuffer, sampleRateHz: Double) = session.push(samples, sampleRateHz)
    override fun finish(): Int = session.finish()
    override fun frame(index: Int): CorePitchFrame = session.frame(index)
    override fun close() = session.close()
}

/**
 * Study/Dinleme modu için çevrimdışı medya çözme + pitch analizi hattı:
 * dosya -> PCM -> pitch kareleri.
 *
 * Adımlar (bkz. `iPadOfflinePitchAnalyzer.analyze`):
 * 1. [AudioDecoder.probe] ile kaynak süresi/biçimi okunur.
 * 2. [AudioDecoder.decode] parça parça ham PCM üretir; her parça mono'ya
 *    indirgenir ([AudioMixdown]) ve tek bir tampon halinde biriktirilir.
 *    İlerleme bu adımda 0.0 → 0.9 arasında raporlanır (kaynak zamanı /
 *    toplam süre).
 * 3. Biriken mono PCM, kaynak zaten 48 kHz değilse [Resampler] ile 48 kHz'e
 *    yeniden örneklenir ve [OfflineEngineSession.push] ile parça parça
 *    motora beslenir.
 * 4. TEK bir [OfflineEngineSession.finish] çağrısı yapılır — bu, ilerleme
 *    kancası olmayan bloklayıcı çağrıdır; bu aşama [AnalysisStage.PITCH]
 *    belirsiz (fraction=null) olarak raporlanır.
 * 5. Üretilen kareler [PitchFrame] listesine çevrilir ([AnalysisStage.WRITE],
 *    gerçek artan ilerlemeyle).
 */
object OfflinePitchAnalyzer {

    /** `Study.pipelineRevision` ile eşleşir — macOS/iPad ile paylaşılan damga. */
    const val PIPELINE_REVISION = "offline-unified-path-r2"

    /** Tek push çağrısı başına yaklaşık örnek sayısı (48 kHz'de ~1 saniye). */
    private const val PUSH_CHUNK_SAMPLES = 48_000

    /**
     * `sourcePath`'teki ses/video dosyasını çözer, mono'ya indirger, 48 kHz'e
     * yeniden örnekler ve `OfflineTrackSession` ile analiz eder.
     *
     * [dispatcher] varsayılan olarak `Dispatchers.IO`'dur — çözme işi ana
     * thread'de YAPILMAZ. Coroutine iptaline saygı duyar: her chunk/frame
     * adımında iptal kontrolü yapılır. Yalnız `finish()`'in kendisi native,
     * bloklayıcı bir çağrı olduğu için o an içindeyken iptal edilemez —
     * çağrı başlamadan hemen önce son kez kontrol edilir.
     *
     * Hata durumları [AudioDecodeException] (çözme) veya
     * `com.aykerme.klarivision.core.PitchAbiException` (motor) olarak
     * fırlatılır — ikisi de doğrudan kullanıcıya gösterilebilir Türkçe
     * mesaj taşır, burada sarılmaz/yutulmaz; canlı (causal) yola sessizce
     * düşülmez.
     */
    suspend fun analyze(
        sourcePath: String,
        decoder: AudioDecoder = MediaCodecAudioDecoder(),
        sessionFactory: () -> OfflineEngineSession = { OfflineTrackSessionAdapter() },
        dispatcher: CoroutineDispatcher = Dispatchers.IO,
        onProgress: suspend (AnalysisProgress) -> Unit = {},
    ): OfflineAnalysisResult = withContext(dispatcher) {
        val info = decoder.probe(sourcePath)
        val durationSeconds = maxOf(info.durationSeconds, 0.001)

        // 1) Çözme: her ham parça mono'ya indirgenir ve biriktirilir. Bu
        // döngü yalnız okuma/downmix yapar — henüz motora hiçbir şey
        // beslenmez, bu yüzden ilerlemesi 0.9'un altında tutulur (iPad
        // tarafındaki `progress(min(readSeconds / duration, 0.9))` ile aynı
        // sözleşme).
        val rawChunks = mutableListOf<FloatArray>()
        var totalSamples = 0
        decoder.decode(sourcePath) { chunk ->
            coroutineContext.ensureActive()
            val mono = if (chunk.channelCount <= 1) {
                chunk.interleavedSamples
            } else {
                AudioMixdown.downmixToMono(chunk.interleavedSamples, chunk.channelCount)
            }
            rawChunks.add(mono)
            totalSamples += mono.size
            val readSeconds = chunk.presentationTimeUs / 1_000_000.0
            onProgress(AnalysisProgress(AnalysisStage.DECODE, (readSeconds / durationSeconds).coerceIn(0.0, 0.9)))
        }

        val rawMono = FloatArray(totalSamples)
        var offset = 0
        for (piece in rawChunks) {
            piece.copyInto(rawMono, offset)
            offset += piece.size
        }
        rawChunks.clear()

        // 2) Yeniden örnekleme: kaynak zaten 48 kHz ise kopyasız döner.
        val resampled = Resampler.resampleLinear(rawMono, info.sampleRateHz.toDouble())

        val session = sessionFactory()
        try {
            var pos = 0
            while (pos < resampled.size) {
                coroutineContext.ensureActive()
                val end = minOf(pos + PUSH_CHUNK_SAMPLES, resampled.size)
                val direct = ByteBuffer.allocateDirect((end - pos) * Float.SIZE_BYTES)
                    .order(ByteOrder.nativeOrder())
                    .asFloatBuffer()
                direct.put(resampled, pos, end - pos)
                direct.flip()
                session.push(direct, Resampler.TARGET_SAMPLE_RATE_HZ)
                pos = end
            }
            onProgress(AnalysisProgress(AnalysisStage.DECODE, 0.9))

            // 3) Tüm-dosya analiz geçişi: tek bloklayıcı çağrı, ilerleme
            // kancası yok -> belirsiz (indeterminate) olarak raporlanır.
            coroutineContext.ensureActive()
            onProgress(AnalysisProgress(AnalysisStage.PITCH, null))
            val frameCount = session.finish()

            // 4) Kareleri taşı: gerçek, artan ilerleme (CLI'daki "write"
            // aşamasının Kotlin karşılığı — burada JSON'a değil, [PitchFrame]
            // listesine serileştirme).
            coroutineContext.ensureActive()
            val frames = ArrayList<PitchFrame>(frameCount)
            for (i in 0 until frameCount) {
                coroutineContext.ensureActive()
                val raw = session.frame(i)
                frames.add(
                    PitchFrame(
                        time = raw.timeSeconds,
                        frequency = raw.frequencyHz,
                        confidence = raw.confidence,
                        voiced = raw.voiced,
                    )
                )
                onProgress(AnalysisProgress(AnalysisStage.WRITE, (i + 1).toDouble() / frameCount))
            }
            if (frameCount == 0) {
                // Gerçekten sessiz/çok kısa bir kayıt: boş liste, hata değil
                // (bkz. OfflineTrackSession.finish KDoc'u).
                onProgress(AnalysisProgress(AnalysisStage.WRITE, 1.0))
            }
            OfflineAnalysisResult(frames = frames, durationSeconds = durationSeconds)
        } finally {
            session.close()
        }
    }
}
