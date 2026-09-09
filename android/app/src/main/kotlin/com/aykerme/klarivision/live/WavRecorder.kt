package com.aykerme.klarivision.live

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Float32 (IEEE float) mono WAV dosyası yazan kayıt edici.
 *
 * Swift kaynağı: `iPadLiveWorker.toggleRecording`/`AVAudioFile` (LiveAnalyzer.swift)
 * — orada `AVAudioFile` RIFF başlığını kendi yazıyordu; burada elle yazılır
 * (bkz. görev talimatı). Yalnız `java.io.RandomAccessFile` kullanır — Android
 * API'sine bağımlı değildir, JVM testiyle (geçici dosyayla) koşar.
 *
 * Akış: [create] 44+12 baytlık bir başlık İSKELETİ (dataSize=0) yazar,
 * ardından [writeSamples] örnekleri sona ekler (dosya konumu her seferinde
 * sona sarılır — akış sırasında başlık bozulmaz). [finish] çağrıldığında
 * RIFF/`fact`/`data` uzunluk alanları GERÇEK toplam örnek sayısına göre
 * yeniden yazılır ve dosya kapatılır.
 *
 * `fact` parçası (IEEE float WAV'lerde standart, `dwSampleLength` — kanal
 * başına toplam örnek sayısı) dahildir; yalnız düz PCM tamsayı biçimlerinde
 * atlanabilecek bu parça, format kodu 3 (IEEE float) için beklenir.
 */
class WavRecorder private constructor(
    private val file: RandomAccessFile,
    val sampleRateHz: Int,
    val channelCount: Int,
) : AutoCloseable {

    /** Şimdiye kadar yazılan, kanal başına örnek sayısı (mono'da toplam örnek sayısıyla aynı). */
    var samplesWritten: Long = 0
        private set

    private var closed = false

    companion object {
        private const val BITS_PER_SAMPLE = 32
        private const val BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8
        private const val FORMAT_TAG_IEEE_FLOAT = 3
        private const val FMT_CHUNK_DATA_SIZE = 16
        private const val FACT_CHUNK_DATA_SIZE = 4

        /** RIFF+WAVE(12) + fmt parçası(8+16) + fact parçası(8+4) + data parça başlığı(8) = 56 bayt. */
        const val HEADER_SIZE_BYTES =
            12 + (8 + FMT_CHUNK_DATA_SIZE) + (8 + FACT_CHUNK_DATA_SIZE) + 8

        /**
         * [path]'te yeni bir WAV dosyası oluşturur (varsa üzerine yazılır) ve
         * başlık iskeletini hemen yazar. Üst dizinler yoksa oluşturulur.
         */
        fun create(path: File, sampleRateHz: Int = 48_000, channelCount: Int = 1): WavRecorder {
            require(sampleRateHz > 0) { "sampleRateHz pozitif olmalı." }
            require(channelCount > 0) { "channelCount pozitif olmalı." }
            path.parentFile?.mkdirs()
            val raf = RandomAccessFile(path, "rw")
            raf.setLength(0)
            val recorder = WavRecorder(raf, sampleRateHz, channelCount)
            recorder.writeHeader(dataSizeBytes = 0)
            return recorder
        }
    }

    /**
     * [samples]'daki ilk [count] örneği (Float32, little-endian, mono
     * serpiştirilmiş) dosyanın sonuna ekler. Kapatıldıktan sonra çağrılması
     * [IllegalStateException] fırlatır.
     */
    fun writeSamples(samples: FloatArray, count: Int = samples.size) {
        check(!closed) { "WavRecorder kapatıldıktan sonra kullanılamaz." }
        require(count in 0..samples.size) { "count, samples sınırları içinde olmalı." }
        if (count == 0) return
        val bytes = ByteArray(count * BYTES_PER_SAMPLE)
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until count) bb.putFloat(samples[i])
        file.seek(file.length())
        file.write(bytes)
        samplesWritten += count
    }

    /**
     * Başlıktaki RIFF/`fact`/`data` uzunluk alanlarını nihai veri boyutuna
     * göre günceller ve dosyayı kapatır. İdempotenttir: birden fazla
     * çağrılması güvenlidir, yalnız ilk çağrı dosyayı gerçekten kapatır ve
     * yazılan toplam örnek sayısını döner; sonraki çağrılar aynı sayıyı
     * (dosyayı tekrar açmadan) döner.
     */
    fun finish(): Long {
        if (!closed) {
            val dataSizeBytes = samplesWritten * BYTES_PER_SAMPLE
            file.seek(0)
            file.write(buildHeader(dataSizeBytes))
            closed = true
            file.close()
        }
        return samplesWritten
    }

    override fun close() {
        if (!closed) {
            closed = true
            file.close()
        }
    }

    private fun writeHeader(dataSizeBytes: Long) {
        file.seek(0)
        file.write(buildHeader(dataSizeBytes))
    }

    private fun buildHeader(dataSizeBytes: Long): ByteArray {
        val byteRate = sampleRateHz * channelCount * BYTES_PER_SAMPLE
        val blockAlign = channelCount * BYTES_PER_SAMPLE
        val sampleLengthPerChannel = (dataSizeBytes / BYTES_PER_SAMPLE).toInt()
        val riffSize = 4L +
            (8 + FMT_CHUNK_DATA_SIZE) +
            (8 + FACT_CHUNK_DATA_SIZE) +
            (8 + dataSizeBytes)

        val buffer = ByteBuffer.allocate(HEADER_SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt(riffSize.toInt())
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))

        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(FMT_CHUNK_DATA_SIZE)
        buffer.putShort(FORMAT_TAG_IEEE_FLOAT.toShort())
        buffer.putShort(channelCount.toShort())
        buffer.putInt(sampleRateHz)
        buffer.putInt(byteRate)
        buffer.putShort(blockAlign.toShort())
        buffer.putShort(BITS_PER_SAMPLE.toShort())

        buffer.put("fact".toByteArray(Charsets.US_ASCII))
        buffer.putInt(FACT_CHUNK_DATA_SIZE)
        buffer.putInt(sampleLengthPerChannel)

        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(dataSizeBytes.toInt())
        return buffer.array()
    }
}
