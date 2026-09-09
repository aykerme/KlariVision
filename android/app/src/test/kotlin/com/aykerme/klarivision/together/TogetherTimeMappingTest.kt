// KlariVision Android — Birlikte Çal zaman eşlemesi testleri.
// Saf JVM testleri: Android API'si olmadan çalışır.

import org.junit.Test
import kotlin.math.abs
import org.junit.Assert.assertEquals

class TogetherTimeMappingTest {
    // Tolerans: yaklaşık hesaplamalar için floatıng point hataları.
    private val tolerance = 1e-9

    @Test
    fun windowCenterSecondsIsCorrect() {
        // Pencere merkezi: (1536 / 2) / 48000 = 768 / 48000 ≈ 0.016 saniye
        val expected = (1536.0 / 2.0) / 48000.0
        assertEquals(expected, TogetherTimeMapping.WINDOW_CENTER_SECONDS, tolerance)
    }

    @Test
    fun windowCenterSecondsIs16Ms() {
        // ~16,0 ms olmalı
        val msValue = TogetherTimeMapping.WINDOW_CENTER_SECONDS * 1000
        assertEquals(16.0, msValue, 0.01)
    }

    @Test
    fun fixedLatencyCalculation() {
        // Sabit gecikme = pencere merkezi + giriş gecikmesi
        val inputLatency = 0.010  // 10 ms (macOS'taki CoreAudio değeri)
        val result = TogetherTimeMapping.fixedLatency(inputLatency)
        val expected = TogetherTimeMapping.WINDOW_CENTER_SECONDS + inputLatency
        assertEquals(expected, result, tolerance)
    }

    @Test
    fun fixedLatencyWithZeroInputLatency() {
        val result = TogetherTimeMapping.fixedLatency(0.0)
        assertEquals(TogetherTimeMapping.WINDOW_CENTER_SECONDS, result, tolerance)
    }

    @Test
    fun mapFrameToMediaTimeFrameJustCreated() {
        // wallNow == frameTime → kare az önce oluşturuldu
        // mediaTime = clockNow − 0 − fixedLatency − userAlignment
        val clockNow = 10.0
        val wallNow = 1000.0
        val frameTime = 1000.0  // Aynı
        val rate = 1.0
        val userAlignment = 0.0
        val fixedLatency = 0.026  // ~26 ms toplam

        val result = TogetherTimeMapping.mapFrameToMediaTime(
            clockNow, wallNow, frameTime, rate, userAlignment, fixedLatency
        )
        val expected = clockNow - fixedLatency
        assertEquals(expected, result, tolerance)
    }

    @Test
    fun mapFrameToMediaTimeWithUserAlignment() {
        // Kullanıcı kaydırması uygulanmış
        val clockNow = 10.0
        val wallNow = 1000.0
        val frameTime = 1000.0
        val rate = 1.0
        val userAlignment = 0.050  // 50 ms = 0.050 saniye
        val fixedLatency = 0.026

        val result = TogetherTimeMapping.mapFrameToMediaTime(
            clockNow, wallNow, frameTime, rate, userAlignment, fixedLatency
        )
        val expected = clockNow - fixedLatency - userAlignment
        assertEquals(expected, result, tolerance)
    }

    @Test
    fun mapFrameToMediaTimeWithRate() {
        // Oynatma hızı 0.5 (yarı hız)
        val clockNow = 10.0
        val wallNow = 1000.0
        val frameTime = 999.0  // 1 saniye önce
        val rate = 0.5
        val userAlignment = 0.0
        val fixedLatency = 0.026

        val result = TogetherTimeMapping.mapFrameToMediaTime(
            clockNow, wallNow, frameTime, rate, userAlignment, fixedLatency
        )
        // (wallNow - frameTime) * rate = (1000 - 999) * 0.5 = 0.5
        val expected = clockNow - 0.5 - fixedLatency
        assertEquals(expected, result, tolerance)
    }

    @Test
    fun mapFrameToMediaTimeFullFormula() {
        // Tam formülü test et
        val clockNow = 100.0
        val wallNow = 5000.0
        val frameTime = 4995.0  // 5 saniye önce
        val rate = 1.0
        val userAlignment = 0.100  // 100 ms = 0.1 saniye
        val fixedLatency = 0.026

        val result = TogetherTimeMapping.mapFrameToMediaTime(
            clockNow, wallNow, frameTime, rate, userAlignment, fixedLatency
        )
        // clockNow - (5000 - 4995) * 1.0 - 0.026 - 0.1 = 100 - 5 - 0.026 - 0.1 = 94.874
        val expected = clockNow - 5.0 - fixedLatency - userAlignment
        assertEquals(expected, result, tolerance)
    }

    @Test
    fun clampMicAlignmentZero() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(0.0)
        assertEquals(0.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentWithinBounds() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(50.0)
        assertEquals(50.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentNegativeWithinBounds() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(-75.0)
        assertEquals(-75.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentBelowMin() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(-250.0)
        assertEquals(-200.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentAboveMax() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(250.0)
        assertEquals(200.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentAtMin() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(-200.0)
        assertEquals(-200.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentAtMax() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(200.0)
        assertEquals(200.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentExtremelyNegative() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(-1000.0)
        assertEquals(-200.0, result, tolerance)
    }

    @Test
    fun clampMicAlignmentExtremelyPositive() {
        val result = TogetherTimeMapping.clampMicAlignmentMs(1000.0)
        assertEquals(200.0, result, tolerance)
    }
}
