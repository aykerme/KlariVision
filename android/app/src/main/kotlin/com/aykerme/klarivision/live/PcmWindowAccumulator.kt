package com.aykerme.klarivision.live

/**
 * Platformdan bağımsız PCM pencere biriktiricisi.
 *
 * Swift kaynağı: `iPadPCMWindowAccumulator` (LiveModels.swift). Android
 * tarafında da AudioRecord/AAudio'dan bağımsız — saf Kotlin, JVM testiyle
 * koşar.
 *
 * Pencere boyutu 1536 örnek, hop (ilerleme) boyutu 512 örnektir; bu sabitler
 * C++ çekirdek motorunun beklediği çerçeve geometrisiyle eşleşir ve
 * değiştirilmemelidir.
 */
class PcmWindowAccumulator(
    val windowSize: Int = WINDOW_SIZE,
    val hopSize: Int = HOP_SIZE,
) {
    private val buffer = ArrayDeque<Float>()

    /** Bu biriktiriciye şimdiye kadar hop adımlarıyla tüketilen örnek sayısı. */
    var samplesConsumed: Int = 0
        private set

    /** Henüz tüketilmemiş (pencere haline gelmemiş) örnek sayısı. */
    val pendingSampleCount: Int
        get() = buffer.size

    /** Yeni gelen örnekleri biriktiriciye ekler. */
    fun append(input: FloatArray) {
        for (sample in input) buffer.addLast(sample)
    }

    /**
     * Elde yeterli örnek varken art arda tam pencereler üretir; her pencere
     * üretiminden sonra tampon hop kadar ilerletilir (kaydırmalı pencere).
     *
     * Kaynak zamanı KRİTİK: pencerenin BAŞLANGICINDAN değil, MERKEZİNDEN
     * türetilir — `sourceTime = centerSample / 48000.0`. Bu, Swift
     * tarafındaki `iPadLiveCoreProcessor.process` ile birebir aynı sözleşmedir;
     * çekirdek motor pencere ortasını temsil eden bir zaman damgası bekler,
     * pencerenin ilk örneğinin zamanını değil.
     */
    fun drainWindows(): List<PcmWindow> {
        val windows = mutableListOf<PcmWindow>()
        while (buffer.size >= windowSize) {
            val samples = FloatArray(windowSize)
            var i = 0
            for (sample in buffer) {
                if (i >= windowSize) break
                samples[i] = sample
                i++
            }
            val centerSample = samplesConsumed + windowSize / 2
            windows.add(PcmWindow(samples = samples, centerSample = centerSample))
            repeat(hopSize) { buffer.removeFirst() }
            samplesConsumed += hopSize
        }
        return windows
    }

    /** Biriktiriciyi sıfırlar: tampon boşalır, tüketilen örnek sayacı sıfırlanır. */
    fun reset() {
        buffer.clear()
        samplesConsumed = 0
    }

    companion object {
        const val WINDOW_SIZE = 1536
        const val HOP_SIZE = 512
        const val SAMPLE_RATE_HZ = 48_000.0
    }
}

/** Tek bir işlenmeye hazır pencere: örnekler ve pencere merkezinin örnek indeksi. */
data class PcmWindow(
    val samples: FloatArray,
    val centerSample: Int,
) {
    /** Pencerenin merkezine karşılık gelen kaynak zamanı (saniye), 48 kHz varsayımıyla. */
    val sourceTime: Double
        get() = centerSample / PcmWindowAccumulator.SAMPLE_RATE_HZ

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PcmWindow) return false
        return centerSample == other.centerSample && samples.contentEquals(other.samples)
    }

    override fun hashCode(): Int {
        var result = samples.contentHashCode()
        result = 31 * result + centerSample
        return result
    }
}
