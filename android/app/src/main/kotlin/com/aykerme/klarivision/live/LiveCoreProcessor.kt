package com.aykerme.klarivision.live

/**
 * Bir pencerelik PCM'i işleyip pitch çerçeveleri üreten alıcı arayüzü.
 *
 * Bu katman, gerçek C ABI / `LivePitchSession` bağlantısına DERLEME BAĞIMLILIĞI
 * kurmaz — o başka bir parçada (`android/core/`) ayrıca yazılır. Burada yalnız
 * arayüz tanımlanır; gerçek uygulama bu arayüzü implemente ederek enjekte
 * edilir (bkz. `LiveCoreProcessor` constructor'ı).
 *
 * `T`, çağıranın seçtiği pitch çerçevesi tipidir — bu modül pitch kararı
 * üretmediği için çerçevenin iç yapısıyla ilgilenmez, yalnız taşır.
 */
fun interface PitchWindowSink<T> {
    /**
     * @param window Tam 1536 örneklik pencere.
     * @param sourceTime Pencere merkezine karşılık gelen kaynak zamanı (saniye).
     * @return Bu pencereden üretilen sıfır ya da daha fazla pitch çerçevesi.
     */
    fun process(window: FloatArray, sourceTime: Double): List<T>
}

/**
 * Ham PCM örneklerini 1536/512 pencerelere böler ve her pencereyi
 * [PitchWindowSink] üzerinden çekirdek işlemciye iletir.
 *
 * Swift kaynağı: `iPadLiveCoreProcessor` (LiveModels.swift). Swift'teki
 * doğrudan `iPadProductionPitchSession` bağımlılığı burada bir arayüze
 * (`PitchWindowSink`) indirgenmiştir — bu sınıf saf Kotlin'dir, C ABI'ye
 * veya Android'e bağımlı değildir, JVM testiyle koşar.
 */
class LiveCoreProcessor<T>(
    private val sink: PitchWindowSink<T>,
) {
    private val accumulator = PcmWindowAccumulator()

    /**
     * Yeni gelen örnekleri biriktirir; tamamlanan her pencereyi [sink]'e
     * iletip elde edilen çerçeveleri birleştirerek döner.
     */
    fun process(samples: FloatArray): List<T> {
        accumulator.append(samples)
        val frames = mutableListOf<T>()
        for (window in accumulator.drainWindows()) {
            frames.addAll(sink.process(window.samples, window.sourceTime))
        }
        return frames
    }

    /** Biriktiriciyi sıfırlar; bekleyen, tam olmayan pencereyi atar. */
    fun reset() {
        accumulator.reset()
    }
}
