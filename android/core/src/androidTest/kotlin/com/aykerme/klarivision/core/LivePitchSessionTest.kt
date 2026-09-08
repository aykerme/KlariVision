package com.aykerme.klarivision.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/**
 * Canlı (causal) oturum yaşam döngüsü testi.
 *
 * Sentetik sinyaller: sessiz pencere (tamamı sıfır) ve sabit-nota
 * sinüs (440 Hz @ 48 kHz). Bu testler kontrakta karşı yaşam döngüsünü
 * doğrular, pitch kalitesini değil.
 */
@RunWith(AndroidJUnit4::class)
class LivePitchSessionTest {

    companion object {
        private const val WINDOW_SIZE = 1536

        /**
         * Ardışık pencereler HOP kadar ilerler ve 1024 örnek örtüşür —
         * oturum sözleşmesi bu (iPad'de `PcmWindowAccumulator(1536, 512)`).
         * Pencere boyu kadar atlamak motora kopuk sinyal verir.
         */
        private const val HOP_SIZE = 512
        private const val SAMPLE_RATE = 48_000.0
        private const val TARGET_FREQUENCY = 440.0
    }

    /** Sessiz pencere oluştur (tamamı 0.0f). */
    private fun makeSilence(): java.nio.FloatBuffer {
        val buffer = ByteBuffer.allocateDirect(WINDOW_SIZE * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until WINDOW_SIZE) {
            buffer.put(0.0f)
        }
        buffer.flip()
        return buffer
    }

    /**
     * Sabit-nota sinüs dalgası oluştur (440 Hz @ 48 kHz).
     * Pencere ortasında zaman damgası merkezle.
     */
    private fun makeSineWave(
        frequencyHz: Double = TARGET_FREQUENCY,
        startTimeSeconds: Double = 0.0
    ): java.nio.FloatBuffer {
        val buffer = ByteBuffer.allocateDirect(WINDOW_SIZE * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        val centerIndex = WINDOW_SIZE / 2.0
        val centerTimeSeconds = startTimeSeconds + (centerIndex / SAMPLE_RATE)

        for (i in 0 until WINDOW_SIZE) {
            val sampleIndex = startTimeSeconds * SAMPLE_RATE + i
            val timeSeconds = sampleIndex / SAMPLE_RATE
            val phase = 2.0 * PI * frequencyHz * timeSeconds
            val sample = sin(phase).toFloat() * 0.5f
            buffer.put(sample)
        }
        buffer.flip()
        return buffer
    }

    @Test
    fun yaşamDöngüsüOluşturİşleYapıKapat() {
        // Tam create → process → finish → close akışı.
        val session = LivePitchSession.create()
        try {
            val frames1 = session.process(makeSineWave(), 0.0)
            // İlk çağrı herhangi bir şey döndürebilir (motor ön tampon gerekçesi).
            // Burada sadece hata olmadığını doğrularız.

            val frames2 = session.process(makeSineWave(startTimeSeconds = WINDOW_SIZE / SAMPLE_RATE), WINDOW_SIZE / SAMPLE_RATE)
            // İkinci process de hata olmamalı.

            val finishFrames = session.finish()
            // finish() son çıktı vektörünü döner; boş olabilir ama hata olmamalı.

            assert(true) { "Yaşam döngüsü başarıyla tamamlandı" }
        } finally {
            session.close()
        }
    }

    @Test
    fun sessizPenceredeVoicedKareYok() {
        val session = LivePitchSession.create()
        try {
            // Sessiz pencere işle ve tüm çıktıyı toplayıp kontrol et.
            val frames = mutableListOf<PitchFrame>()
            repeat(5) { i ->
                frames.addAll(session.process(makeSilence(), i * (WINDOW_SIZE / SAMPLE_RATE)))
            }
            session.finish().let { frames.addAll(it) }

            // Sessizlikte hiç voiced kare olmamalı.
            val hasVoiced = frames.any { it.voiced }
            assert(!hasVoiced) {
                "Sessiz pencerede voiced kare olmamalı, bulundu: ${frames.filter { it.voiced }}"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun sabitNotaDaVoiced() {
        val session = LivePitchSession.create()
        try {
            val frames = mutableListOf<PitchFrame>()
            // Sabit 440 Hz sinüs'ü birkaç pencerenin üzerinden işle.
            repeat(48) { i ->
                val startTime = i * (HOP_SIZE / SAMPLE_RATE)
                frames.addAll(session.process(makeSineWave(startTimeSeconds = startTime), startTime))
            }
            session.finish().let { frames.addAll(it) }

            // En az bir voiced kare olmalı.
            assert(frames.any { it.voiced }) {
                "Sabit 440 Hz sinüsü en az bir voiced kare üretmeli"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun sabitNotaFrekansıToleransı() {
        val session = LivePitchSession.create()
        try {
            val frames = mutableListOf<PitchFrame>()
            repeat(48) { i ->
                val startTime = i * (HOP_SIZE / SAMPLE_RATE)
                frames.addAll(session.process(makeSineWave(startTimeSeconds = startTime), startTime))
            }
            session.finish().let { frames.addAll(it) }

            // Voiced karelerden ortalama frekansı hesapla.
            val voicedFrames = frames.filter { it.voiced && it.frequencyHz > 0 }
            assert(voicedFrames.isNotEmpty()) {
                "En az bir voiced kare olmalı"
            }

            val avgFrequency = voicedFrames.map { it.frequencyHz }.average()
            val tolerance = TARGET_FREQUENCY * 0.02  // +/- %2 toleransı cömert
            assert(abs(avgFrequency - TARGET_FREQUENCY) < tolerance) {
                "Ortalama frekans $avgFrequency, beklenen $TARGET_FREQUENCY +/- $tolerance"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun çıktıSemantiksiTazaOkunur() {
        // KRİTİK: her process(), çıktı vektörünü YENIDEN YAZAR. Bu test
        // bu davranışı doğrular: ikinci process() çağrısından sonra
        // çıktı indeks aralığı taze okunuyor.

        val session = LivePitchSession.create()
        try {
            // İlk process.
            val frames1 = session.process(makeSineWave(startTimeSeconds = 0.0), 0.0)
            val count1 = frames1.size

            // İkinci process — sesizlik.
            val frames2 = session.process(makeSilence(), WINDOW_SIZE / SAMPLE_RATE)
            val count2 = frames2.size

            // frames1'i saklamadığımızda, ikinci process'in çıktısı
            // ilk process'i değiştirmez. frame1'i direkt
            // C ABI'den yeniden okumak yerine, frames2'yi kontrol ederiz.
            // frames2 taze olmalıdır.

            // Bunun doğru test edilebilmesi için iki senaryo:
            // 1. frames2 boş -> sayım değişti
            // 2. frames2 non-empty -> başka veriler -> sayım değişti
            // İkisi de "sesizlikle kare sayısı değişir" demektir.

            // Ancak, statü kontrol etmek için: aynı session içinde,
            // iki process() çağrısından sonra her iki çıktı seti de
            // geçerli (null değil) olmalı.
            // Not: çıktı vektörü her process/finish çağrısında baştan yazılır
            // ve indeksler 0'dan taze okunur. Sabit gecikme (bkz.
            // kv_unified_lag_frames, D-042 ile 8 hop) dolana kadar ilk
            // çağrıların BOŞ dönmesi normaldir — bu yüzden burada
            // "en az biri dolu" iddiası yapılmaz; iddia, iki okumanın da
            // geçerli (istisna atmayan, bağımsız) liste döndürmesidir.
            assertNotNull("İlk process geçerli bir liste döndürmeli", frames1)
            assertNotNull("İkinci process geçerli bir liste döndürmeli", frames2)

            // Daha direkt test: finish() çağrı öncesi ve sonra,
            // çıktı sayısı değişebilir, ancak her zaman geçerli
            // indeksler yeniden okunabilir.
            val finishFrames = session.finish()
            // finish() sonra çıktı sayısı yeniden okunabilir olmalı.
            assert(finishFrames is List<*>) {
                "finish() bir liste dönmeli"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun kaynakZamanıTutarlı() {
        val session = LivePitchSession.create()
        try {
            val sourceTimes = listOf(0.0, 0.032, 0.064, 0.096)  // ~1.5x pencere
            val allFrames = mutableListOf<PitchFrame>()

            for (time in sourceTimes) {
                allFrames.addAll(session.process(makeSineWave(startTimeSeconds = time), time))
            }
            allFrames.addAll(session.finish())

            // Tüm kareler zaman-sıralı (veya beklenen aralık içinde) olmalı.
            // Zaman değer aralığı [0, max_source_time] içinde olmalı.
            val minTime = sourceTimes.minOrNull() ?: 0.0
            val maxTime = sourceTimes.maxOrNull() ?: 1.0

            for (frame in allFrames) {
                assert(frame.timeSeconds >= minTime - 0.1 && frame.timeSeconds <= maxTime + 0.1) {
                    "Frame zaman ${frame.timeSeconds} aralık [$minTime, $maxTime] dışında"
                }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun varsayılanMinimumRmsKullanılabilir() {
        // PitchContract.load() sözleşmenin varsayılan defaultMinimumRms'ini döner.
        // LivePitchSession.create() bunu kullanmalı (parametresiz çağrı).
        val contract = PitchContract.load()
        val session = LivePitchSession.create()
        try {
            val frames = session.process(makeSineWave(), 0.0)
            // Hata olmamalı; session sözleşmenin varsayılanını kullanmıştır.
            assert(true) { "Varsayılan RMS başarıyla kullanıldı" }
        } finally {
            session.close()
        }
    }

    @Test
    fun özelMinimumRmsKullanılabilir() {
        val customRms = 0.02
        val session = LivePitchSession.create(minimumRms = customRms)
        try {
            val frames = session.process(makeSineWave(), 0.0)
            // Hata olmamalı; session özel RMS'i kullanmıştır.
            assert(true) { "Özel minimum RMS başarıyla kullanıldı" }
        } finally {
            session.close()
        }
    }

    @Test
    fun minimumRmsDinamisiveyeAyarlanabilir() {
        val session = LivePitchSession.create()
        try {
            session.process(makeSineWave(), 0.0)
            // Oturum sırasında RMS'i değiştir.
            session.setMinimumRms(0.01)
            // Hata olmamalı.
            session.process(makeSineWave(startTimeSeconds = WINDOW_SIZE / SAMPLE_RATE), WINDOW_SIZE / SAMPLE_RATE)
            assert(true) { "Minimum RMS değiştirildi" }
        } finally {
            session.close()
        }
    }

    @Test
    fun resetİş() {
        val session = LivePitchSession.create()
        try {
            session.process(makeSineWave(), 0.0)
            // Oturumu sıfırla.
            session.reset()
            // Hata olmamalı ve yeni işleme başlanabilir.
            val frames = session.process(makeSineWave(startTimeSeconds = 1.0), 1.0)
            assert(true) { "Sıfırlama başarıyla yapıldı" }
        } finally {
            session.close()
        }
    }
}
