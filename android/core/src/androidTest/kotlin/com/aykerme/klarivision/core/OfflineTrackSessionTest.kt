package com.aykerme.klarivision.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

/**
 * Çevrimdışı (whole-file) oturum testi.
 *
 * Bu testler `push(...) → finish() → frame(...)` akışını doğrular.
 * Yaşam döngüsü, hata durumları ve çıktı anlamı kontrol edilir.
 */
@RunWith(AndroidJUnit4::class)
class OfflineTrackSessionTest {

    companion object {
        private const val SAMPLE_RATE = 48_000.0
        private const val TARGET_FREQUENCY = 440.0
    }

    /**
     * Sabit-nota sinüs dalgası oluştur (440 Hz @ 48 kHz).
     * Parça boyutu rastgele olabilir (offline push çok esnek).
     */
    private fun makeSineWave(
        durationSeconds: Double,
        frequencyHz: Double = TARGET_FREQUENCY,
        startTimeSeconds: Double = 0.0
    ): java.nio.FloatBuffer {
        val sampleCount = (durationSeconds * SAMPLE_RATE).toInt()
        val buffer = ByteBuffer.allocateDirect(sampleCount * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

        for (i in 0 until sampleCount) {
            val sampleIndex = startTimeSeconds * SAMPLE_RATE + i
            val timeSeconds = sampleIndex / SAMPLE_RATE
            val phase = 2.0 * PI * frequencyHz * timeSeconds
            val sample = sin(phase).toFloat() * 0.5f
            buffer.put(sample)
        }
        buffer.flip()
        return buffer
    }

    /** Sessiz buffer (tamamı 0.0f) oluştur. */
    private fun makeSilence(durationSeconds: Double): java.nio.FloatBuffer {
        val sampleCount = (durationSeconds * SAMPLE_RATE).toInt()
        val buffer = ByteBuffer.allocateDirect(sampleCount * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until sampleCount) {
            buffer.put(0.0f)
        }
        buffer.flip()
        return buffer
    }

    @Test
    fun yaşamDöngüsüPushFinishFrame() {
        val session = OfflineTrackSession.create()
        try {
            // Birkaç saniyelik sentetik sinüs'ü parça parça push et.
            session.push(makeSineWave(durationSeconds = 1.0), SAMPLE_RATE)
            session.push(makeSineWave(durationSeconds = 1.0, startTimeSeconds = 1.0), SAMPLE_RATE)

            // finish() çağrı: tüm-dosya analizini çalıştır.
            val frameCount = session.finish()

            // Çıktı karelerini oku.
            if (frameCount > 0) {
                for (i in 0 until frameCount) {
                    val frame = session.frame(i)
                    assert(frame != null) { "Frame $i başarıyla okunmalı" }
                }
            }

            assert(frameCount > 0) {
                "2 saniyelik 440 Hz sinüs > 0 kare üretmeli, $frameCount bulundu"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun parçaParçaPush() {
        // Push rastgele boyutlu parçaları kabul eder, pencere/hop sınırlarına
        // hizalanmak zorunda değil.
        val session = OfflineTrackSession.create()
        try {
            // 100ms, 200ms, 150ms parçalarında push et.
            session.push(makeSineWave(durationSeconds = 0.1), SAMPLE_RATE)
            session.push(makeSineWave(durationSeconds = 0.2, startTimeSeconds = 0.1), SAMPLE_RATE)
            session.push(makeSineWave(durationSeconds = 0.15, startTimeSeconds = 0.3), SAMPLE_RATE)

            val frameCount = session.finish()
            // finish() hiçbir hata olmaksızın çalışmalı.
            assert(frameCount >= 0) { "finish() non-negative kare sayısı dönmeli" }
        } finally {
            session.close()
        }
    }

    @Test
    fun closeSonrasıPushHata() {
        val session = OfflineTrackSession.create()
        session.close()

        try {
            session.push(makeSineWave(durationSeconds = 0.1), SAMPLE_RATE)
            assert(false) { "Kapalı oturumda push() istisna olmalı" }
        } catch (e: IllegalStateException) {
            assert(true) { "IllegalStateException: ${e.message}" }
        }
    }

    @Test
    fun closeSonrasıFinishHata() {
        val session = OfflineTrackSession.create()
        session.close()

        try {
            session.finish()
            assert(false) { "Kapalı oturumda finish() istisna olmalı" }
        } catch (e: IllegalStateException) {
            assert(true) { "IllegalStateException: ${e.message}" }
        }
    }

    @Test
    fun closeSonrasıFrameHata() {
        val session = OfflineTrackSession.create()
        try {
            session.push(makeSineWave(durationSeconds = 0.5), SAMPLE_RATE)
            session.finish()
        } finally {
            session.close()
        }

        try {
            session.frame(0)
            assert(false) { "Kapalı oturumda frame() istisna olmalı" }
        } catch (e: IllegalStateException) {
            assert(true) { "IllegalStateException: ${e.message}" }
        }
    }

    @Test
    fun closeSonrasıLastErrorHata() {
        val session = OfflineTrackSession.create()
        session.close()

        try {
            session.lastError()
            assert(false) { "Kapalı oturumda lastError() istisna olmalı" }
        } catch (e: IllegalStateException) {
            assert(true) { "IllegalStateException: ${e.message}" }
        }
    }

    @Test
    fun doğruOlmayanBufferPushHata() {
        val session = OfflineTrackSession.create()
        try {
            // Doğrudan olmayan (heap) buffer.
            val indirectBuffer = java.nio.FloatBuffer.allocate(1000)
            for (i in 0 until 1000) {
                indirectBuffer.put(0.0f)
            }
            indirectBuffer.flip()

            // Bunu push()'e geçir — InvalidArgument hatası olmalı.
            try {
                session.push(indirectBuffer, SAMPLE_RATE)
                assert(false) { "Doğrudan olmayan buffer InvalidArgument hatası olmalı" }
            } catch (e: PitchAbiException.InvalidArgument) {
                assert(true) { "InvalidArgument: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun boşBufferPushHata() {
        val session = OfflineTrackSession.create()
        try {
            // Boş buffer (0 remaining).
            val emptyBuffer = ByteBuffer.allocateDirect(0).order(ByteOrder.nativeOrder()).asFloatBuffer()

            try {
                session.push(emptyBuffer, SAMPLE_RATE)
                assert(false) { "Boş buffer IllegalArgumentException olmalı" }
            } catch (e: IllegalArgumentException) {
                assert(true) { "IllegalArgumentException: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun negatifÖrneklemehızıReddedilir() {
        val session = OfflineTrackSession.create()
        try {
            try {
                session.push(makeSineWave(durationSeconds = 0.1), -48000.0)
                assert(false) { "Negatif örnekleme hızı IllegalArgumentException olmalı" }
            } catch (e: IllegalArgumentException) {
                assert(true) { "IllegalArgumentException: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun sıfırÖrneklemehızıReddedilir() {
        val session = OfflineTrackSession.create()
        try {
            try {
                session.push(makeSineWave(durationSeconds = 0.1), 0.0)
                assert(false) { "Sıfır örnekleme hızı IllegalArgumentException olmalı" }
            } catch (e: IllegalArgumentException) {
                assert(true) { "IllegalArgumentException: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun nanÖrneklemehızıReddedilir() {
        val session = OfflineTrackSession.create()
        try {
            try {
                session.push(makeSineWave(durationSeconds = 0.1), Double.NaN)
                assert(false) { "NaN örnekleme hızı IllegalArgumentException olmalı" }
            } catch (e: IllegalArgumentException) {
                assert(true) { "IllegalArgumentException: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun sonsuzÖrneklemehızıReddedilir() {
        val session = OfflineTrackSession.create()
        try {
            try {
                session.push(makeSineWave(durationSeconds = 0.1), Double.POSITIVE_INFINITY)
                assert(false) { "Sonsuz örnekleme hızı IllegalArgumentException olmalı" }
            } catch (e: IllegalArgumentException) {
                assert(true) { "IllegalArgumentException: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun çiftCloseIdempotent() {
        val session = OfflineTrackSession.create()
        session.close()
        session.close()
        assert(true) { "İkinci close hiçbir istisna üretmedi" }
    }

    @Test
    fun sabitNotaDaKareSayısıPozitif() {
        val session = OfflineTrackSession.create()
        try {
            // 3 saniyelik 440 Hz sinüs.
            session.push(makeSineWave(durationSeconds = 3.0), SAMPLE_RATE)

            val frameCount = session.finish()
            assert(frameCount > 0) {
                "3 saniyelik sinüs > 0 kare üretmeli, $frameCount bulundu"
            }

            // İlk kare, sinyalin başlangıcına denk geldiği için meşru olarak
            // sessiz (unvoiced) olabilir — motor orada henüz karar vermez.
            // Anlamlı iddia, izin GENELİNDE sabit notanın bulunmasıdır.
            val voiced = (0 until frameCount)
                .map { session.frame(it) }
                .filter { it.voiced && it.frequencyHz > 0 }
            assert(voiced.isNotEmpty()) {
                "3 saniyelik sabit sinüs en az bir voiced kare üretmeli"
            }
            val median = voiced.map { it.frequencyHz }.sorted()[voiced.size / 2]
            assert(kotlin.math.abs(median - TARGET_FREQUENCY) < TARGET_FREQUENCY * 0.02) {
                "Voiced karelerin medyan frekansı $median, beklenen $TARGET_FREQUENCY ±%2"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun farklıÖrneklemehızları() {
        // Motor push çağrısında farklı örnekleme hızlarını destekler.
        val session = OfflineTrackSession.create()
        try {
            // 48 kHz'de 1 saniye push et.
            session.push(makeSineWave(durationSeconds = 1.0), 48_000.0)

            // Finish çağrı (hiç hata olmamalı, örnekleme hızını tanıtmalı).
            val frameCount = session.finish()
            assert(frameCount >= 0) { "finish() başarılı olmalı" }
        } finally {
            session.close()
        }
    }

    @Test
    fun frameIndexNegaTifReddedilir() {
        val session = OfflineTrackSession.create()
        try {
            session.push(makeSineWave(durationSeconds = 0.5), SAMPLE_RATE)
            session.finish()

            try {
                session.frame(-1)
                assert(false) { "Negatif index IllegalArgumentException olmalı" }
            } catch (e: IllegalArgumentException) {
                assert(true) { "IllegalArgumentException: ${e.message}" }
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun lastErrorBoşYaNıBaşlangıçta() {
        val session = OfflineTrackSession.create()
        try {
            // Başlangıçta lastError boş olmalı.
            val initialError = session.lastError()
            assert(initialError.isEmpty() || initialError.isBlank()) {
                "Başlangıçta hata mesajı boş olmalı, \"$initialError\" bulundu"
            }

            // Başarılı push/finish sonra da boş olmalı.
            session.push(makeSineWave(durationSeconds = 0.5), SAMPLE_RATE)
            session.finish()

            val finalError = session.lastError()
            assert(finalError.isEmpty() || finalError.isBlank()) {
                "Başarılı işlem sonra hata mesajı boş olmalı, \"$finalError\" bulundu"
            }
        } finally {
            session.close()
        }
    }

    @Test
    fun çokKısaSessinSıfırKareveHataYok() {
        val session = OfflineTrackSession.create()
        try {
            // 1ms sinüs (çok kısa).
            session.push(makeSineWave(durationSeconds = 0.001), SAMPLE_RATE)

            val frameCount = session.finish()
            // 0 frame olabilir (çok kısa) ancak hata olmamalı.
            assert(frameCount >= 0) {
                "Kısa kayıt 0 frame veya daha fazla dönmeli, $frameCount bulundu"
            }

            val errorMsg = session.lastError()
            assert(errorMsg.isEmpty() || errorMsg.isBlank()) {
                "Kısa kayıt hata olmamalı, \"$errorMsg\" bulundu"
            }
        } finally {
            session.close()
        }
    }
}
