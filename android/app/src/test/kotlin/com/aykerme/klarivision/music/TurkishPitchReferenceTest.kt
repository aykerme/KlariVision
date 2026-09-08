package com.aykerme.klarivision.music

import org.junit.Test
import org.junit.Assert.*

class TurkishPitchReferenceTest {

    @Test
    fun testTableElementCount() {
        // Tablo tam 73 girdisi olmalı (53-komalı Türk müziği ±1 oktav)
        assertEquals("Tablo boyutu 73 olmalı", 73, TurkishPitchReference.notes.size)
    }

    @Test
    fun testFirstEntry() {
        // İlk giriş: Do 97.78 Hz
        val first = TurkishPitchReference.notes.first()
        assertEquals("İlk perde adı Do olmalı", "Do", first.name)
        assertEquals("İlk perde 97.78 Hz olmalı", 97.78, first.hz, 0.001)
    }

    @Test
    fun testLastEntry() {
        // Son giriş: Do 782.24 Hz
        val last = TurkishPitchReference.notes.last()
        assertEquals("Son perde adı Do olmalı", "Do", last.name)
        assertEquals("Son perde 782.24 Hz olmalı", 782.24, last.hz, 0.001)
    }

    @Test
    fun testKnownPitches() {
        // Bilinen perdelerin frekanslarını doğrula
        val table = TurkishPitchReference.notes

        // Re 110.0 Hz (index 4)
        assertEquals("Re 110.0 Hz", "Re", table[4].name)
        assertEquals("Re 110.0 Hz frekansı", 110.0, table[4].hz, 0.001)

        // La 165.0 Hz (index 18)
        // Perdeler tablodaki konumlarına göre değil, frekanslarına göre aranır:
        // indeks tahmini tabloya bağımlı ve kırılgandır.
        for ((expectedName, hz) in listOf(
            "Re" to 110.0,
            "La" to 165.0,
            "Re" to 220.0,
            "La" to 330.0,
            "Re" to 440.0,
            "La" to 660.0,
        )) {
            val note = table.firstOrNull { kotlin.math.abs(it.hz - hz) < 0.001 }
            assertNotNull("$hz Hz tabloda bulunamadı", note)
            assertEquals("$hz Hz perde adı", expectedName, note!!.name)
        }
    }

    @Test
    fun testFrequenciesSorted() {
        // Frekanslar artan sırayla olmalı
        for (i in 1 until TurkishPitchReference.notes.size) {
            assertTrue(
                "Frekanslar sıralanmış olmalı: ${TurkishPitchReference.notes[i-1].hz} < ${TurkishPitchReference.notes[i].hz}",
                TurkishPitchReference.notes[i - 1].hz < TurkishPitchReference.notes[i].hz
            )
        }
    }

    @Test
    fun testAllNotesHaveNames() {
        // Tüm notaların adı olmalı
        for (note in TurkishPitchReference.notes) {
            assertFalse("Tüm notalar adlandırılmış olmalı", note.name.isBlank())
        }
    }

    @Test
    fun testAllFrequenciesPositive() {
        // Tüm frekanslar pozitif olmalı
        for (note in TurkishPitchReference.notes) {
            assertTrue("Tüm frekanslar pozitif olmalı", note.hz > 0)
        }
    }
}
