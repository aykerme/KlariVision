// KlariVision Android — çevrimdışı çözme hattının saf (platformdan bağımsız)
// PCM hazırlama adımları: kanal indirgeme ve yeniden örnekleme.

package com.aykerme.klarivision.study

/**
 * Kanal-serpiştirilmiş (interleaved) PCM'i mono'ya indirger.
 */
object AudioMixdown {
    /**
     * `interleaved`'i kanal ortalamasıyla mono'ya indirger. Swift
     * tarafındaki `AVAssetReaderTrackOutput`'un `AVNumberOfChannelsKey: 1`
     * istekli downmix'iyle aynı basit ortalama semantiğini uygular
     * (bkz. `iPadOfflinePitchAnalyzer`, StudyModels.swift).
     *
     * `channelCount == 1` ise girdi değişmeden (kopyasız) döner.
     */
    fun downmixToMono(interleaved: FloatArray, channelCount: Int): FloatArray {
        require(channelCount > 0) { "Kanal sayısı pozitif olmalı." }
        if (channelCount == 1) return interleaved
        require(interleaved.size % channelCount == 0) {
            "Örnek sayısı kanal sayısına tam bölünmeli."
        }
        val frameCount = interleaved.size / channelCount
        val mono = FloatArray(frameCount)
        for (frame in 0 until frameCount) {
            var sum = 0f
            val base = frame * channelCount
            for (channel in 0 until channelCount) {
                sum += interleaved[base + channel]
            }
            mono[frame] = sum / channelCount
        }
        return mono
    }
}

/**
 * `core/tools/pitch_track_cli.cpp`'teki `resample()` ile BİREBİR aynı
 * doğrusal interpolasyon örnekleme oranı dönüştürücüsü. Bu katman pitch
 * kararı üretmez — yalnız PCM'i motorun beklediği 48 kHz'e taşır.
 */
object Resampler {
    /** Motor sözleşmesinin zorunlu kıldığı tek hedef hız — bkz. PitchContract. */
    const val TARGET_SAMPLE_RATE_HZ = 48_000.0

    /**
     * `source`'u `sourceRateHz`'den `targetRateHz`'e doğrusal interpolasyonla
     * yeniden örnekler. Kaynak zaten hedef hızdaysa `source`'u kopyasız
     * döner — CLI'daki `if(source.rate==target) return source.samples;`
     * kısayoluyla birebir aynı.
     *
     * Çıktı uzunluğu `source.size * targetRateHz / sourceRateHz` (tam sayıya
     * kırpılır), tıpkı CLI'daki gibi. Her çıktı örneği için kaynaktaki
     * kesirli konum `p` hesaplanır; `floor(p)` ile `floor(p)+1` (dizi
     * sonunda kırpılmış) arasında doğrusal interpolasyon yapılır.
     */
    fun resampleLinear(
        source: FloatArray,
        sourceRateHz: Double,
        targetRateHz: Double = TARGET_SAMPLE_RATE_HZ,
    ): FloatArray {
        require(sourceRateHz.isFinite() && sourceRateHz > 0) {
            "Kaynak örnekleme hızı sonlu ve pozitif olmalı."
        }
        require(targetRateHz.isFinite() && targetRateHz > 0) {
            "Hedef örnekleme hızı sonlu ve pozitif olmalı."
        }
        if (sourceRateHz == targetRateHz) return source
        if (source.isEmpty()) return FloatArray(0)

        val outputSize = (source.size * targetRateHz / sourceRateHz).toInt()
        val output = FloatArray(outputSize)
        for (i in 0 until outputSize) {
            val p = i * sourceRateHz / targetRateHz
            val lo = p.toInt()
            val hi = minOf(lo + 1, source.size - 1)
            output[i] = (source[lo] + (source[hi] - source[lo]) * (p - lo)).toFloat()
        }
        return output
    }
}
