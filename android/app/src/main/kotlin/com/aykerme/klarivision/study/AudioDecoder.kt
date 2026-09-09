// KlariVision Android — çevrimdışı medya çözme hattı: dosya -> ham PCM.
// Swift kaynağı: `iPadOfflinePitchAnalyzer`'ın AVURLAsset+AVAssetReader
// kısmı (StudyModels.swift). Android'de karşılığı MediaExtractor+MediaCodec.

package com.aykerme.klarivision.study

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.nio.ByteOrder
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Kaynak ses/video dosyasının ses izini çözer. Gerçek uygulama
 * ([MediaCodecAudioDecoder]) yalnız Android çalışma zamanında (cihaz ya da
 * enstrümantasyon testinde) çalışabilir — `MediaCodec`/`MediaExtractor`
 * gerçek kod çözücü gerektirir. Bu arayüz sayesinde
 * [OfflinePitchAnalyzer]'ın geri kalanı sahte (fake) bir çözücüyle JVM'de
 * test edilebilir; `MediaCodec`'i JVM testinde taklit etmeye ÇALIŞILMAZ.
 */
interface AudioDecoder {
    /**
     * Çözmeden ÖNCE seçilen ses izinin biçimini ve toplam süresini okur.
     * Hızlıdır — dosyanın tamamını çözmez, yalnız konteyner/iz başlığını
     * okur.
     */
    suspend fun probe(sourcePath: String): AudioSourceInfo

    /**
     * `sourcePath`'teki dosyanın seçilen ses izini uçtan uca çözer. Her PCM
     * parçası [onChunk] ile teslim edilir — `interleavedSamples` HENÜZ
     * mono'ya indirgenmemiş, HENÜZ 48 kHz'e yeniden örneklenmemiştir; bu
     * adımlar çağıran tarafta ([OfflinePitchAnalyzer]) yapılır (bu katman
     * pitch kararı üretmez, yalnız PCM taşır).
     *
     * Coroutine iptal edilirse çözme döngüsü
     * [kotlinx.coroutines.CancellationException] ile durur; kaynaklar
     * (extractor/codec) her koşulda serbest bırakılır.
     */
    suspend fun decode(sourcePath: String, onChunk: suspend (AudioChunk) -> Unit)
}

/** Çözücüden gelen ham (henüz mono/48 kHz olmayan), kanal-serpiştirilmiş bir PCM parçası. */
data class AudioChunk(
    val interleavedSamples: FloatArray,
    val channelCount: Int,
    val sampleRateHz: Int,
    /** Bu parçanın kaynak akışındaki konumu (mikrosaniye) — ilerleme hesaplaması için. */
    val presentationTimeUs: Long,
)

/** Seçilen ses izinin biçimi ve kaynak akışın toplam süresi. */
data class AudioSourceInfo(
    val durationSeconds: Double,
    val sampleRateHz: Int,
    val channelCount: Int,
)

/**
 * Çözme hattı hataları. Mesajlar kullanıcıya doğrudan gösterilebilir
 * Türkçe metinlerdir — `iPadStudyImportError` (StudyModels.swift) ile aynı
 * ruhta.
 */
sealed class AudioDecodeException(message: String) : Exception(message) {
    /** Dosyada ses izi yok (yalnız video parçası, ya da bozuk konteyner). */
    class NoAudioTrack : AudioDecodeException(
        "Dosyada analiz edilecek bir ses kanalı bulunamadı."
    )

    /** Dosya açılamadı (bulunamadı, izin yok, bozuk vb.). */
    class SourceUnavailable(detail: String) : AudioDecodeException(
        "Dosya açılamadı: $detail"
    )

    /** Kod çözücü oluşturulamadı ya da beklenmeyen bir çıkış biçimi üretti. */
    class UnsupportedFormat(detail: String) : AudioDecodeException(
        "Ses akışı çözülemedi: $detail"
    )
}

/**
 * `MediaExtractor` + `MediaCodec` ile gerçek Android çözücüsü.
 *
 * iPad tarafı (`AVURLAsset`/`AVAssetReader`) hedef örnekleme hızını/kanal
 * sayısını (48 kHz mono Float32) doğrudan `outputSettings` ile
 * AVFoundation'a bırakır; Android'de `MediaCodec`'in bu garantisi yoktur,
 * bu yüzden bu sınıf çıktısını KAYNAK hız/kanal sayısıyla, ham olarak
 * verir — mono indirgeme ve 48 kHz'e yeniden örnekleme
 * [OfflinePitchAnalyzer] tarafında ([AudioMixdown], [Resampler]) yapılır.
 */
class MediaCodecAudioDecoder : AudioDecoder {

    override suspend fun probe(sourcePath: String): AudioSourceInfo {
        val extractor = MediaExtractor()
        return try {
            openSource(extractor, sourcePath)
            val trackIndex = selectAudioTrackIndex(extractor) ?: throw AudioDecodeException.NoAudioTrack()
            val format = extractor.getTrackFormat(trackIndex)
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                format.getLong(MediaFormat.KEY_DURATION)
            } else {
                -1L
            }
            val durationSeconds = if (durationUs > 0) {
                durationUs / 1_000_000.0
            } else {
                // Bazı konteynerler/kod çözücüler iz biçiminde süre raporlamaz;
                // bu durumda konteyner meta verisine düş (iPad tarafındaki
                // `asset.load(.duration)` karşılığı).
                containerDurationSeconds(sourcePath)
            }
            AudioSourceInfo(durationSeconds = durationSeconds, sampleRateHz = sampleRate, channelCount = channelCount)
        } finally {
            extractor.release()
        }
    }

    override suspend fun decode(sourcePath: String, onChunk: suspend (AudioChunk) -> Unit) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            openSource(extractor, sourcePath)
            val trackIndex = selectAudioTrackIndex(extractor) ?: throw AudioDecodeException.NoAudioTrack()
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: throw AudioDecodeException.UnsupportedFormat("MIME türü okunamadı.")
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            val mediaCodec = try {
                MediaCodec.createDecoderByType(mime)
            } catch (e: Exception) {
                throw AudioDecodeException.UnsupportedFormat("Kod çözücü oluşturulamadı ($mime): ${e.message}")
            }
            codec = mediaCodec
            mediaCodec.configure(format, null, null, 0)
            mediaCodec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                coroutineContext.ensureActive()

                if (!inputDone) {
                    val inputIndex = mediaCodec.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val inputBuffer = mediaCodec.getInputBuffer(inputIndex)
                            ?: throw AudioDecodeException.UnsupportedFormat("Kod çözücü giriş tamponu alınamadı.")
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            mediaCodec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            mediaCodec.queueInputBuffer(inputIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                var outputIndex = mediaCodec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                while (outputIndex >= 0) {
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                    if (bufferInfo.size > 0) {
                        val outputBuffer = mediaCodec.getOutputBuffer(outputIndex)
                            ?: throw AudioDecodeException.UnsupportedFormat("Kod çözücü çıkış tamponu alınamadı.")
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        // MediaCodec bu yapılandırmada 16-bit PCM üretir (KEY_PCM_ENCODING
                        // istenmedi); float çalışma biçimine burada dönüştürülür.
                        val shorts = ShortArray(bufferInfo.size / 2)
                        outputBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(shorts)
                        val floats = FloatArray(shorts.size) { shorts[it] / 32768f }
                        onChunk(
                            AudioChunk(
                                interleavedSamples = floats,
                                channelCount = channelCount,
                                sampleRateHz = sampleRate,
                                presentationTimeUs = bufferInfo.presentationTimeUs,
                            )
                        )
                    }
                    mediaCodec.releaseOutputBuffer(outputIndex, false)
                    if (outputDone) break
                    outputIndex = mediaCodec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                }
            }
        } finally {
            codec?.let {
                try {
                    it.stop()
                } catch (_: Exception) {
                    // Zaten temizleme sırasındayız; durdurma hatası burada anlamsız.
                }
                it.release()
            }
            extractor.release()
        }
    }

    private fun openSource(extractor: MediaExtractor, sourcePath: String) {
        try {
            extractor.setDataSource(sourcePath)
        } catch (e: Exception) {
            throw AudioDecodeException.SourceUnavailable(e.message ?: "bilinmeyen hata")
        }
    }

    private fun selectAudioTrackIndex(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i
        }
        return null
    }

    private fun containerDurationSeconds(sourcePath: String): Double {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(sourcePath)
            val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            maxOf(ms / 1000.0, 0.001)
        } finally {
            retriever.release()
        }
    }

    private companion object {
        const val TIMEOUT_US = 10_000L
    }
}
