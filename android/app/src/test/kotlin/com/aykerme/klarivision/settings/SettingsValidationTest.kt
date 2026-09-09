// KlariVision Android — Ayarlar doğrulaması unit testleri.
// Clamp, doğrulama ve RMS dönüşüm işlevlerini test eder.

package com.aykerme.klarivision.settings

import org.junit.Test
import org.junit.Assert.*
import kotlin.math.abs
import kotlin.math.pow

class SettingsValidationTest {
    // ==================== Motor Doğrulaması ====================

    @Test
    fun testValidateEngineValid() {
        assertEquals("unified_v1", SettingsValidation.validateEngine("unified_v1"))
    }

    @Test
    fun testValidateEngineNull() {
        assertEquals("unified_v1", SettingsValidation.validateEngine(null))
    }

    @Test
    fun testValidateEngineBlank() {
        assertEquals("unified_v1", SettingsValidation.validateEngine(""))
    }

    @Test
    fun testValidateEngineUnknown() {
        assertEquals("unified_v1", SettingsValidation.validateEngine("unknown_engine"))
    }

    // ==================== Tema Doğrulaması ====================

    @Test
    fun testValidateThemeValid() {
        assertEquals("focus", SettingsValidation.validateTheme("focus"))
        assertEquals("studio", SettingsValidation.validateTheme("studio"))
        assertEquals("classic", SettingsValidation.validateTheme("classic"))
    }

    @Test
    fun testValidateThemeNull() {
        assertEquals("focus", SettingsValidation.validateTheme(null))
    }

    @Test
    fun testValidateThemeInvalid() {
        assertEquals("focus", SettingsValidation.validateTheme("invalid"))
    }

    // ==================== Kapı Clamp ====================

    @Test
    fun testClampGateMin() {
        // -70 sınırdan aşağı; -60'a clamp'lenecek
        assertEquals(-60.0, SettingsValidation.clampGate(-70.0), 1e-9)
    }

    @Test
    fun testClampGateMax() {
        // 0 sınırdan üstü; -20'ye clamp'lenecek
        assertEquals(-20.0, SettingsValidation.clampGate(0.0), 1e-9)
    }

    @Test
    fun testClampGateMiddle() {
        // -42 aralığın içinde; değişmeyecek
        assertEquals(-42.0, SettingsValidation.clampGate(-42.0), 1e-9)
    }

    @Test
    fun testClampGateExactMin() {
        assertEquals(-60.0, SettingsValidation.clampGate(-60.0), 1e-9)
    }

    @Test
    fun testClampGateExactMax() {
        assertEquals(-20.0, SettingsValidation.clampGate(-20.0), 1e-9)
    }

    @Test
    fun testClampGateDefault() {
        assertEquals(-42.0, SettingsValidation.clampGate(-42.0), 1e-9)
    }

    // ==================== RMS Dönüşümü ====================

    @Test
    fun testRmsForDbFsZero() {
        // 0 dBFS → 1.0 RMS
        // Clamp edildikten sonra -20 dBFS → 10^(-20/20) = 10^(-1) = 0.1
        // Ama 0 < -60 olmadığından -20'ye clamp'lenecek
        val result = SettingsValidation.rmsForDbFs(0.0)
        val expected = 0.1  // 10^(-20/20)
        assertEquals(expected, result, 1e-6)
    }

    @Test
    fun testRmsForDbFsDefault() {
        // -42 dBFS → 10^(-42/20) ≈ 0.00794
        val result = SettingsValidation.rmsForDbFs(-42.0)
        val expected = 10.0.pow(-42.0 / 20.0)
        assertEquals(expected, result, 1e-6)
    }

    @Test
    fun testRmsForDbFsMin() {
        // -60 dBFS → 10^(-60/20) = 10^(-3) = 0.001
        val result = SettingsValidation.rmsForDbFs(-60.0)
        val expected = 0.001
        assertEquals(expected, result, 1e-6)
    }

    // ==================== Renk Doğrulaması ====================

    @Test
    fun testValidateColorValidHex6() {
        assertEquals("#67d5ff", SettingsValidation.validateColor("#67d5ff", "#000000"))
        assertEquals("#E75A5A", SettingsValidation.validateColor("#E75A5A", "#000000"))
    }

    @Test
    fun testValidateColorValidHex8() {
        assertEquals("#67d5ffFF", SettingsValidation.validateColor("#67d5ffFF", "#000000"))
    }

    @Test
    fun testValidateColorNull() {
        val default = "#67d5ff"
        assertEquals(default, SettingsValidation.validateColor(null, default))
    }

    @Test
    fun testValidateColorBlank() {
        val default = "#67d5ff"
        assertEquals(default, SettingsValidation.validateColor("", default))
    }

    @Test
    fun testValidateColorNoHash() {
        val default = "#67d5ff"
        assertEquals(default, SettingsValidation.validateColor("67d5ff", default))
    }

    @Test
    fun testValidateColorWrongLength() {
        val default = "#67d5ff"
        assertEquals(default, SettingsValidation.validateColor("#67d5", default))
        assertEquals(default, SettingsValidation.validateColor("#67d5fffff", default))
    }

    @Test
    fun testValidateColorInvalidHex() {
        val default = "#67d5ff"
        assertEquals(default, SettingsValidation.validateColor("#67d5XY", default))
    }

    @Test
    fun testValidateColorUppercaseHex() {
        assertEquals("#67D5FF", SettingsValidation.validateColor("#67D5FF", "#000000"))
    }

    // ==================== 53-Koma Doğrulaması ====================

    @Test
    fun testValidateKomaIntervalsValid() {
        val valid = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 5)
        assertTrue(SettingsValidation.validateKomaIntervals(valid))
    }

    @Test
    fun testValidateKomaIntervalsWrongCount() {
        val invalid = listOf(4, 4, 5, 4)  // Sadece 4 eleman
        assertFalse(SettingsValidation.validateKomaIntervals(invalid))
    }

    @Test
    fun testValidateKomaIntervalsWrongSum() {
        val invalid = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 6)  // Toplamı 54
        assertFalse(SettingsValidation.validateKomaIntervals(invalid))
    }

    @Test
    fun testValidateKomaIntervalsZeroElement() {
        val invalid = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 0)  // Bir 0
        assertFalse(SettingsValidation.validateKomaIntervals(invalid))
    }

    @Test
    fun testValidateKomaIntervalsNull() {
        assertFalse(SettingsValidation.validateKomaIntervals(null))
    }

    @Test
    fun testSanitizeKomaIntervalsValid() {
        val valid = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 5)
        assertEquals(valid, SettingsValidation.sanitizeKomaIntervals(valid))
    }

    @Test
    fun testSanitizeKomaIntervalsInvalid() {
        val invalid = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 6)  // Geçersiz
        assertEquals(SettingsKeys.KOMA_INTERVALS_53_DEFAULT,
            SettingsValidation.sanitizeKomaIntervals(invalid))
    }

    @Test
    fun testSanitizeKomaIntervalsNull() {
        assertEquals(SettingsKeys.KOMA_INTERVALS_53_DEFAULT,
            SettingsValidation.sanitizeKomaIntervals(null))
    }

    // ==================== Makam Koma Aralığı Doğrulaması ====================

    @Test
    fun testValidateMakamIntervalsValid() {
        val valid = listOf(9, 4, 9, 9, 4, 9, 9)  // Nihavend
        assertTrue("Geçerli makam aralıkları kabul edilmeli", SettingsValidation.validateMakamIntervals(valid))
    }

    @Test
    fun testValidateMakamIntervalsWrongCount() {
        val invalid = listOf(9, 4, 9)  // Sadece 3 eleman
        assertFalse("Yanlış sayıda eleman reddedilmeli", SettingsValidation.validateMakamIntervals(invalid))
    }

    @Test
    fun testValidateMakamIntervalsOutOfRange() {
        val invalid = listOf(9, 4, 9, 9, 4, 9, 14)  // Bir 14 (> 13)
        assertFalse("Aralık dışı değer reddedilmeli", SettingsValidation.validateMakamIntervals(invalid))
    }

    @Test
    fun testValidateMakamIntervalsZero() {
        val invalid = listOf(9, 4, 9, 9, 4, 9, 0)  // Bir 0 (< 1)
        assertFalse("Sıfır değer reddedilmeli", SettingsValidation.validateMakamIntervals(invalid))
    }

    @Test
    fun testValidateMakamIntervalsWrongSum() {
        val invalid = listOf(9, 4, 9, 9, 4, 9, 10)  // Toplamı 54
        assertFalse("Yanlış toplam reddedilmeli", SettingsValidation.validateMakamIntervals(invalid))
    }

    @Test
    fun testValidateMakamIntervalsNull() {
        assertFalse("Null reddedilmeli", SettingsValidation.validateMakamIntervals(null))
    }

    // ==================== Makam Doğrulaması ====================

    @Test
    fun testValidateMakamValid() {
        assertEquals("Nihavend", SettingsValidation.validateMakam("Nihavend"))
        assertEquals("Majör", SettingsValidation.validateMakam("Majör"))
    }

    @Test
    fun testValidateMakamNull() {
        assertEquals("Nihavend", SettingsValidation.validateMakam(null))
    }

    @Test
    fun testValidateMakamInvalid() {
        assertEquals("Nihavend", SettingsValidation.validateMakam("InvalidMakam"))
    }

    // ==================== Karar Doğrulaması ====================

    @Test
    fun testValidateKararValid() {
        assertEquals("Re", SettingsValidation.validateKarar("Re"))
        assertEquals("Do", SettingsValidation.validateKarar("Do"))
    }

    @Test
    fun testValidateKararNull() {
        assertEquals("Re", SettingsValidation.validateKarar(null))
    }

    @Test
    fun testValidateKararInvalid() {
        assertEquals("Re", SettingsValidation.validateKarar("InvalidKarar"))
    }

    // ==================== Ölçek Gösterimi Doğrulaması ====================

    @Test
    fun testValidateScaleDisplayValid() {
        assertEquals("Makam", SettingsValidation.validateScaleDisplay("Makam"))
        assertEquals("Türk Müziği (Sol Klarnet)", SettingsValidation.validateScaleDisplay("Türk Müziği (Sol Klarnet)"))
    }

    @Test
    fun testValidateScaleDisplayNull() {
        assertEquals("Makam", SettingsValidation.validateScaleDisplay(null))
    }

    @Test
    fun testValidateScaleDisplayInvalid() {
        assertEquals("Makam", SettingsValidation.validateScaleDisplay("InvalidDisplay"))
    }

    // ==================== Varsayılan Makam Aralıkları ====================

    @Test
    fun testDefaultIntervalsForMakamNihavend() {
        val intervals = SettingsValidation.defaultIntervalsForMakam("Nihavend")
        assertEquals(listOf(9, 4, 9, 9, 4, 9, 9), intervals)
    }

    @Test
    fun testDefaultIntervalsForMakamMajor() {
        val intervals = SettingsValidation.defaultIntervalsForMakam("Majör")
        assertEquals(listOf(9, 9, 4, 9, 9, 9, 4), intervals)
    }

    @Test
    fun testDefaultIntervalsForMakamUnknown() {
        val intervals = SettingsValidation.defaultIntervalsForMakam("UnknownMakam")
        assertEquals(emptyList<Int>(), intervals)
    }
}
