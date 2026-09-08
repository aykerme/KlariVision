// KlariVision Android — Ayarlar anahtarları ve varsayılanları unit testleri.
// Tüm varsayılan değerlerin doğru olduğunu ve sabitlerin Swift sözleşmesine
// eşlendiğini doğrular.

package com.aykerme.klarivision.settings

import org.junit.Test
import org.junit.Assert.*

class SettingsKeysTest {
    @Test
    fun testStudyPitchEngineDefault() {
        assertEquals("unified_v1", SettingsKeys.STUDY_PITCH_ENGINE_DEFAULT)
    }

    @Test
    fun testLivePitchEngineDefault() {
        assertEquals("unified_v1", SettingsKeys.LIVE_PITCH_ENGINE_DEFAULT)
    }

    @Test
    fun testThemeDefault() {
        assertEquals("focus", SettingsKeys.THEME_DEFAULT)
    }

    @Test
    fun testLiveSignalGateDbFSDefault() {
        assertEquals(-42.0, SettingsKeys.LIVE_SIGNAL_GATE_DBFS_DEFAULT, 1e-9)
    }

    @Test
    fun testLiveSignalGateDbFSBounds() {
        assertEquals(-60.0, SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MIN, 1e-9)
        assertEquals(-20.0, SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MAX, 1e-9)
    }

    @Test
    fun testGraphPitchColorDefault() {
        assertEquals("#67d5ff", SettingsKeys.GRAPH_PITCH_COLOR_DEFAULT)
    }

    @Test
    fun testGraphGuideColorDefault() {
        assertEquals("#b7d8ff", SettingsKeys.GRAPH_GUIDE_COLOR_DEFAULT)
    }

    @Test
    fun testGraphKararColorDefault() {
        assertEquals("#E75A5A", SettingsKeys.GRAPH_KARAR_COLOR_DEFAULT)
    }

    @Test
    fun testKomaIntervals53Default() {
        val expected = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 5)
        assertEquals(expected, SettingsKeys.KOMA_INTERVALS_53_DEFAULT)
    }

    @Test
    fun testKomaIntervals53DefaultSum() {
        val sum = SettingsKeys.KOMA_INTERVALS_53_DEFAULT.sum()
        assertEquals(53, sum)
    }

    @Test
    fun testLiveMakamDefault() {
        assertEquals("Nihavend", SettingsKeys.LIVE_MAKAM_DEFAULT)
    }

    @Test
    fun testLiveKararDefault() {
        assertEquals("Re", SettingsKeys.LIVE_KARAR_DEFAULT)
    }

    @Test
    fun testLiveScaleDisplayDefault() {
        assertEquals("Makam", SettingsKeys.LIVE_SCALE_DISPLAY_DEFAULT)
    }

    @Test
    fun testMakamDefaults() {
        // Her makam için doğrulama
        SettingsKeys.MAKAM_DEFAULTS.forEach { (makam, intervals) ->
            assertEquals("Makam '$makam' 7 aralık içermeli", 7, intervals.size)
            assertEquals("Makam '$makam' toplamı 53 olmalı", 53, intervals.sum())
            intervals.forEach { interval ->
                assertTrue("Makam '$makam' aralığı 1-13 arasında olmalı: $interval", interval in 1..13)
            }
        }
    }

    @Test
    fun testEditableMakams() {
        // Ayarlanabilir makamlar tanımlanmalı
        val editable = SettingsKeys.EDITABLE_MAKAMS
        assertEquals(6, editable.size)
        assertTrue(editable.contains("Nihavend"))
        assertTrue(editable.contains("Kürdi"))
        assertTrue(editable.contains("Uşşak"))
        assertTrue(editable.contains("Hicaz"))
        assertTrue(editable.contains("Hicazkâr"))
        assertTrue(editable.contains("Kürdilihicazkâr"))
    }

    @Test
    fun testAllMakams() {
        val all = SettingsKeys.ALL_MAKAMS
        assertTrue(all.contains("Majör"))
        assertTrue(all.contains("Minör"))
        assertTrue(all.contains("Nihavend"))
        assertTrue(all.contains("Kürdi"))
        assertTrue(all.contains("Uşşak"))
        assertTrue(all.contains("Hicaz"))
        assertTrue(all.contains("Hicazkâr"))
        assertTrue(all.contains("Kürdilihicazkâr"))
        assertEquals(8, all.size)
    }

    @Test
    fun testAllKarars() {
        val all = SettingsKeys.ALL_KARARS
        assertEquals(listOf("Do", "Re", "Mi", "Fa", "Sol", "La", "Si"), all)
    }

    @Test
    fun testAllScaleDisplays() {
        val all = SettingsKeys.ALL_SCALE_DISPLAYS
        assertEquals(2, all.size)
        assertTrue(all.contains("Makam"))
        assertTrue(all.contains("Türk Müziği (Sol Klarnet)"))
    }
}
