// KlariVision Android — Birlikte Çal modu için giriş (mikrofon) gecikmesi
// tahmini. macOS'un `TogetherSession.fixedLatency`'sindeki 10 ms sabiti
// CoreAudio'ya ÖZGÜDÜR ve Android'e kopyalanamaz (bkz. görev notu) — burada
// cihazdan türetilen bir tahmin üretilir, üç kademeli düşüşle:
//   1) AudioRecord.getTimestamp(..., TIMEBASE_MONOTONIC) — varsa en doğrusu.
//   2) AudioManager PROPERTY_OUTPUT_FRAMES_PER_BUFFER / PROPERTY_OUTPUT_SAMPLE_RATE
//      tabanlı arabellek tahmini.
//   3) İkisi de yoksa [FALLBACK_LATENCY_SECONDS] — belgelenmiş, muhafazakâr bir sabit.
//
// Hangi kademenin kullanıldığı [InputLatencyEstimate.source] ile dışa
// verilir — tanılama amaçlı: kullanıcı hizalama kaydırıcısını (±200 ms) buna
// göre yorumlayabilsin. Bu tahmin KAÇINILMAZ OLARAK yaklaşıktır; kaydırıcı
// ince ayar içindir, kesin değer değildir.

package com.aykerme.klarivision.together

/** Gecikme tahmininin hangi kademeden geldiği. */
enum class InputLatencySource {
    AUDIO_TIMESTAMP,
    BUFFER_ESTIMATE,
    FALLBACK_DEFAULT,
}

/** Seçilen tahmin: saniye cinsinden gecikme + kaynağı. */
data class InputLatencyEstimate(
    val seconds: Double,
    val source: InputLatencySource,
)

/**
 * Platform ölçümlerini soyutlayan arayüz. Gerçek uygulama (Android'e bağımlı)
 * bu paketin dışında değil, aynı dosyada [AndroidLatencyMeasurementSource]
 * olarak yaşar; JVM testleri sahte uygulamalar geçirir. Her fonksiyon
 * ölçüm mümkün değilse/desteklenmiyorsa `null` döner — istisna fırlatmaz.
 */
interface LatencyMeasurementSource {
    /** `AudioRecord.getTimestamp(AudioTimestamp, TIMEBASE_MONOTONIC)` tabanlı ölçüm (saniye). */
    fun measureFromAudioTimestamp(): Double?

    /** `AudioManager.getProperty(PROPERTY_OUTPUT_FRAMES_PER_BUFFER/SAMPLE_RATE)` tabanlı tahmin (saniye). */
    fun measureFromBufferProperty(): Double?
}

/**
 * Saf, test edilebilir seçim mantığı: [source]'u sırayla dener, ilk geçerli
 * (sonlu, negatif olmayan) sonucu döner; hiçbiri yoksa [FALLBACK_LATENCY_SECONDS]'e düşer.
 */
object InputLatencyProbe {
    /**
     * Hiçbir ölçüm mümkün değilse kullanılan muhafazakâr varsayım.
     * Bu, CoreAudio'nun kesin 10 ms'lik donanım gecikmesiyle KARIŞTIRILMAMALI
     * — Android'de gerçek giriş gecikmesi cihaza göre büyük farklılık
     * gösterir (tipik olarak 20–100+ ms). Yalnız "hiçbir şey ölçülemedi"
     * durumunda bir başlangıç noktasıdır; kullanıcı hizalama kaydırıcısı
     * (±200 ms) geri kalanını üstlenir.
     */
    const val FALLBACK_LATENCY_SECONDS = 0.080

    fun estimate(source: LatencyMeasurementSource): InputLatencyEstimate {
        val fromTimestamp = source.measureFromAudioTimestamp()
        if (fromTimestamp != null && fromTimestamp.isFinite() && fromTimestamp >= 0.0) {
            return InputLatencyEstimate(fromTimestamp, InputLatencySource.AUDIO_TIMESTAMP)
        }
        val fromBuffer = source.measureFromBufferProperty()
        if (fromBuffer != null && fromBuffer.isFinite() && fromBuffer >= 0.0) {
            return InputLatencyEstimate(fromBuffer, InputLatencySource.BUFFER_ESTIMATE)
        }
        return InputLatencyEstimate(FALLBACK_LATENCY_SECONDS, InputLatencySource.FALLBACK_DEFAULT)
    }
}

/**
 * Gerçek Android ölçümü. `record`, çağıran tarafın (bkz.
 * `TogetherOrchestrator`'ın Android kurucusu) mikrofonu başlatmadan hemen
 * önce kısa ömürlü olarak açtığı/kapattığı bir `AudioRecord`'dır — asıl
 * yakalama hattını (`live/LiveAudioCapture`, DEĞİŞTİRİLMEDİ) hiç etkilemez,
 * yalnız bir kerelik bir zaman damgası okumak için var olur.
 *
 * `getTimestamp` desteklenmiyorsa veya bir istisna fırlatırsa sessizce
 * `null` döner — [InputLatencyProbe] bir sonraki kademeye düşer.
 */
class AndroidLatencyMeasurementSource(
    private val context: android.content.Context,
    private val openProbeRecord: () -> android.media.AudioRecord? = { defaultProbeRecord() },
) : LatencyMeasurementSource {

    override fun measureFromAudioTimestamp(): Double? {
        val record = try {
            openProbeRecord()
        } catch (_: SecurityException) {
            null
        } catch (_: Exception) {
            null
        } ?: return null
        return try {
            record.startRecording()
            // Donanımın gerçekten örnek üretmeye başlamasını beklemek için
            // küçük bir okuma yapılır — `getTimestamp` çoğu cihazda ilk
            // `read()`'den önce geçerli bir değer döndürmez.
            val scratch = ShortArray(PROBE_READ_FRAMES)
            record.read(scratch, 0, PROBE_READ_FRAMES)
            val timestamp = android.media.AudioTimestamp()
            if (record.getTimestamp(timestamp, android.media.AudioTimestamp.TIMEBASE_MONOTONIC) !=
                android.media.AudioRecord.SUCCESS
            ) {
                return null
            }
            val sampleRate = record.sampleRate.takeIf { it > 0 } ?: return null
            val nowNanos = System.nanoTime()
            // `timestamp.nanoTime`, `timestamp.framePosition`'ın donanımca
            // yakalandığı andır; o konumla şu an okunmuş en son konum
            // arasındaki fark, arabellekte bekleyen (henüz uygulamaya
            // ulaşmamış) örneklerin süresidir — giriş gecikmesinin
            // kendisidir.
            val elapsedSinceCapture = (nowNanos - timestamp.nanoTime) / 1_000_000_000.0
            if (elapsedSinceCapture.isFinite() && elapsedSinceCapture >= 0.0) elapsedSinceCapture else null
        } catch (_: Exception) {
            null
        } finally {
            try {
                record.stop()
            } catch (_: Exception) { /* zaten durmuş olabilir */ }
            try {
                record.release()
            } catch (_: Exception) { /* zaten serbest olabilir */ }
        }
    }

    override fun measureFromBufferProperty(): Double? {
        val audioManager = context.getSystemService(android.content.Context.AUDIO_SERVICE)
            as? android.media.AudioManager ?: return null
        val framesPerBuffer = audioManager
            .getProperty(android.media.AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)
            ?.toDoubleOrNull() ?: return null
        val sampleRate = audioManager
            .getProperty(android.media.AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
            ?.toDoubleOrNull() ?: return null
        if (sampleRate <= 0.0) return null
        return framesPerBuffer / sampleRate
    }

    private companion object {
        const val PROBE_READ_FRAMES = 256

        fun defaultProbeRecord(): android.media.AudioRecord? {
            val sampleRate = 48_000
            val channelConfig = android.media.AudioFormat.CHANNEL_IN_MONO
            val encoding = android.media.AudioFormat.ENCODING_PCM_16BIT
            val minBufferBytes = android.media.AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
            if (minBufferBytes <= 0) return null
            val record = android.media.AudioRecord(
                android.media.MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                encoding,
                minBufferBytes * 2,
            )
            return if (record.state == android.media.AudioRecord.STATE_INITIALIZED) record else {
                record.release()
                null
            }
        }
    }
}
