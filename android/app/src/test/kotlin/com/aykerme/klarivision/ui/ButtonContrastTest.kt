// KlariVision Android — dolu düğme kontrastının saf testi.
//
// Vurgu renkleri beyaz yazıyla WCAG AA'yı (4,5:1) geçmiyordu: mavi 3,65,
// yeşil 2,22, klasik kahverengi 4,32. `darkenedForWhiteText` aynı tonu
// koyulaştırarak sınırı geçirmeli, zaten geçen rengi değiştirmemeli.

package com.aykerme.klarivision.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ButtonContrastTest {

    @Test
    fun `tema vurgu renkleri beyaz yaziyla AA gecer`() {
        val accents = listOf(KvColors.AccentListening, KvColors.AccentPractice, KvColors.StatusRecording, Color(0xFFB5652E))
        accents.forEach { accent ->
            assertTrue("$accent koyulaştırılmadan AA'yı geçmemeli", accent.contrastWithWhite() < KvMinTextContrast)
            val button = accent.darkenedForWhiteText()
            assertTrue("$accent → $button: ${button.contrastWithWhite()}", button.contrastWithWhite() >= KvMinTextContrast)
        }
    }

    /** Ölçülen referans değerler: #0A84FF 3,65:1 ve #34C759 2,22:1. */
    @Test
    fun `kontrast hesabi WCAG ile uyumlu`() {
        assertEquals(3.65f, KvColors.AccentListening.contrastWithWhite(), 0.02f)
        assertEquals(2.22f, KvColors.AccentPractice.contrastWithWhite(), 0.02f)
        assertEquals(21f, Color.Black.contrastWithWhite(), 0.01f)
    }

    @Test
    fun `yeterince koyu renk degismez`() {
        val dark = Color(0xFF1F3A5F)
        assertEquals(dark, dark.darkenedForWhiteText())
    }
}
