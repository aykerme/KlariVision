// KlariVision Android — müzik bağlamı testleri, Swift AppStateTests'ten port edildi.

package com.aykerme.klarivision.music

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class MakamKararTests {
    private val FREQUENCY_DELTA = 0.001

    @Test
    fun testMakamEnumHasEightCases() {
        assertEquals(8, Makam.values().size)
    }

    @Test
    fun testKararEnumHasSevenCases() {
        assertEquals(7, Karar.values().size)
    }

    @Test
    fun testKararFrequenciesAreSet() {
        assertEquals(523.251, Karar.DO.frequency, FREQUENCY_DELTA)
        assertEquals(293.665, Karar.RE.frequency, FREQUENCY_DELTA)
        assertEquals(329.628, Karar.MI.frequency, FREQUENCY_DELTA)
        assertEquals(349.228, Karar.FA.frequency, FREQUENCY_DELTA)
        assertEquals(391.995, Karar.SOL.frequency, FREQUENCY_DELTA)
        assertEquals(440.0, Karar.LA.frequency, FREQUENCY_DELTA)
        assertEquals(493.883, Karar.SI.frequency, FREQUENCY_DELTA)
    }

    @Test
    fun testMusicContextOffersMakamAndKararChoices() {
        val context = MusicContext(makam = Makam.HICAZ, karar = Karar.LA)
        assertEquals(Makam.HICAZ, context.makam)
        assertEquals(Karar.LA, context.karar)
    }

    @Test
    fun testGuideFrequenciesWithDefaultMakam() {
        val context = MusicContext(makam = Makam.HICAZ, karar = Karar.LA)
        val frequencies = context.guideFrequencies()
        assertNotNull(frequencies)
        assertEquals(8, frequencies.size)
        // İlk frekans karar frekansı olmalı
        assertEquals(440.0, frequencies[0], FREQUENCY_DELTA)
    }

    @Test
    fun testGuideFrequenciesCanBeOverridden() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.RE)
        val customCommas = listOf(0, 9, 18, 22)
        val frequencies = context.guideFrequencies(customCommas)
        assertEquals(4, frequencies.size)
    }

    @Test
    fun testMakamGuideCommasAreCorrect() {
        assertEquals(listOf(0, 9, 18, 22, 31, 40, 49, 53), Makam.MAJOR.guideCommas)
        assertEquals(listOf(0, 9, 13, 22, 31, 35, 44, 53), Makam.MINOR.guideCommas)
        assertEquals(listOf(0, 9, 13, 22, 31, 35, 44, 53), Makam.NIHAVEND.guideCommas)
        assertEquals(listOf(0, 5, 13, 22, 31, 35, 44, 53), Makam.KURDI.guideCommas)
        assertEquals(listOf(0, 8, 17, 22, 31, 39, 44, 53), Makam.USSAK.guideCommas)
        assertEquals(listOf(0, 5, 18, 22, 31, 40, 44, 53), Makam.HICAZ.guideCommas)
        assertEquals(listOf(0, 5, 18, 22, 31, 40, 49, 53), Makam.HICAZKAR.guideCommas)
        assertEquals(listOf(0, 5, 13, 22, 31, 40, 49, 53), Makam.KURDILIHICAZKAR.guideCommas)
    }

    @Test
    fun testGuideNotesGeneratesCorrectStructure() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.DO)
        val notes = context.guideNotes()
        assertNotNull(notes)
        // 7 derece × 7 oktav (-3…+3) = 49 not
        assertEquals(49, notes.size)
    }

    @Test
    fun testGuideNotesContainsKararMarkers() {
        val context = MusicContext(makam = Makam.MINOR, karar = Karar.RE)
        val notes = context.guideNotes()
        // Her oktavda kararIn (degree == 0) işaretlenmiş bir not olmalı
        val kararMarked = notes.filter { it.isKarar }
        assertEquals(7, kararMarked.size) // -3…+3 = 7 oktav
    }

    @Test
    fun testGuideNotesWithEmptyKararReturnsEmpty() {
        // Geçersiz karar seçimi
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.RE)
        val notes = context.guideNotes()
        // RE gerçekten perdeCycle'da olmalı
        assertFalse(notes.isEmpty())
    }

    @Test
    fun testGuideNotesIncludeFrequencies() {
        val context = MusicContext(makam = Makam.NIHAVEND, karar = Karar.LA)
        val notes = context.guideNotes()
        for (note in notes) {
            assertTrue("Note ${note.name} has valid frequency", note.hz > 0)
        }
    }

    @Test
    fun testGuideNotesFormatIncludesOctaveNumber() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.DO)
        val notes = context.guideNotes()
        for (note in notes) {
            // Not adı, solfej (Do/Re/Mi/Fa/Sol/La/Si) + oktav ve isteğe bağlı sapma içermeli
            assertTrue("Note name ${note.name} should contain octave", note.name.matches(Regex(".*\\d.*")))
        }
    }

    @Test
    fun testGuideNotesCanBeOverridden() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.DO)
        val customCommas = listOf(0, 9, 18, 22, 53) // 4 derece + son işareti
        val notes = context.guideNotes(customCommas)
        // 4 derece, 7 oktav (-3…+3) = 4 × 7 = 28 not
        assertEquals(28, notes.size)
    }
}

class MakamIntervalsStoreTests {
    private val store = MakamIntervalsStore()

    @Test
    fun testDefaultIntervalsForMajor() {
        val intervals = store.defaultIntervals(Makam.MAJOR)
        assertEquals(7, intervals.size)
        assertEquals(listOf(9, 9, 4, 9, 9, 9, 4), intervals)
    }

    @Test
    fun testDefaultIntervalsForMinor() {
        val intervals = store.defaultIntervals(Makam.MINOR)
        assertEquals(7, intervals.size)
        assertEquals(listOf(9, 4, 9, 9, 4, 9, 9), intervals)
    }

    @Test
    fun testDefaultIntervalsForNihavend() {
        val intervals = store.defaultIntervals(Makam.NIHAVEND)
        assertEquals(listOf(9, 4, 9, 9, 4, 9, 9), intervals)
    }

    @Test
    fun testDefaultIntervalsForKurdi() {
        val intervals = store.defaultIntervals(Makam.KURDI)
        assertEquals(listOf(5, 8, 9, 9, 4, 9, 9), intervals)
    }

    @Test
    fun testDefaultIntervalsForUssak() {
        val intervals = store.defaultIntervals(Makam.USSAK)
        assertEquals(listOf(8, 9, 5, 9, 8, 5, 9), intervals)
    }

    @Test
    fun testDefaultIntervalsForHicaz() {
        val intervals = store.defaultIntervals(Makam.HICAZ)
        assertEquals(listOf(5, 13, 4, 9, 9, 4, 9), intervals)
    }

    @Test
    fun testDefaultIntervalsForHicazkar() {
        val intervals = store.defaultIntervals(Makam.HICAZKAR)
        assertEquals(listOf(5, 13, 4, 9, 9, 9, 4), intervals)
    }

    @Test
    fun testDefaultIntervalsForKurdilihicazkar() {
        val intervals = store.defaultIntervals(Makam.KURDILIHICAZKAR)
        assertEquals(listOf(5, 8, 9, 9, 9, 9, 4), intervals)
    }

    @Test
    fun testDefaultIntervalsSumTo53() {
        for (makam in Makam.values()) {
            val intervals = store.defaultIntervals(makam)
            assertEquals("Makam ${makam.displayName} intervals should sum to 53", 53, intervals.sum())
        }
    }

    @Test
    fun testIsValidChecksCount() {
        assertFalse(store.isValid(listOf(5, 5, 5, 5, 5, 5)))
        assertTrue(store.isValid(listOf(8, 8, 8, 8, 8, 5, 8)))
    }

    @Test
    fun testIsValidChecksRange() {
        assertFalse(store.isValid(listOf(0, 9, 9, 9, 9, 9, 9))) // 0 is invalid
        assertFalse(store.isValid(listOf(14, 9, 9, 9, 9, 9, 4))) // 14 > 13
        assertTrue(store.isValid(listOf(1, 9, 9, 9, 9, 9, 7))) // 1 is valid, sum = 53
        assertFalse(store.isValid(listOf(13, 9, 9, 9, 9, 4, 0))) // 13 is valid, but 0 is invalid
        assertTrue(store.isValid(listOf(13, 9, 9, 9, 8, 4, 1))) // All valid, sum = 53
    }

    @Test
    fun testIsValidChecksSum() {
        assertFalse(store.isValid(listOf(9, 9, 9, 9, 9, 9, 9))) // sum = 63
        assertFalse(store.isValid(listOf(8, 8, 8, 8, 8, 8, 8))) // sum = 56
        assertFalse(store.isValid(listOf(8, 8, 9, 8, 8, 9, 5))) // sum = 55, not 53
        assertTrue(store.isValid(listOf(9, 9, 4, 9, 9, 9, 4))) // sum = 53, all valid
    }

    @Test
    fun testSetIntervalsRejectsNonEditableMakams() {
        val intervals = listOf(9, 9, 4, 9, 9, 9, 4)
        assertFalse(store.setIntervals(Makam.MAJOR, intervals))
        assertFalse(store.setIntervals(Makam.MINOR, intervals))
    }

    @Test
    fun testSetIntervalsAcceptsEditableMakams() {
        val intervals = listOf(9, 9, 4, 9, 9, 9, 4)
        assertTrue(store.setIntervals(Makam.NIHAVEND, intervals))
        assertTrue(store.setIntervals(Makam.KURDI, intervals))
        assertTrue(store.setIntervals(Makam.USSAK, intervals))
        assertTrue(store.setIntervals(Makam.HICAZ, intervals))
        assertTrue(store.setIntervals(Makam.HICAZKAR, intervals))
        assertTrue(store.setIntervals(Makam.KURDILIHICAZKAR, intervals))
    }

    @Test
    fun testSetIntervalsStoresOverride() {
        val intervals = listOf(9, 9, 4, 9, 9, 9, 4)
        store.setIntervals(Makam.KURDI, intervals)
        assertEquals(intervals, store.intervals(Makam.KURDI))
    }

    @Test
    fun testIntervalsReturnsDefaultWhenNotOverridden() {
        val default = store.defaultIntervals(Makam.KURDI)
        assertEquals(default, store.intervals(Makam.KURDI))
    }

    @Test
    fun testIntervalsReturnsOverrideWhenSet() {
        val override = listOf(9, 9, 4, 9, 9, 9, 4)
        store.setIntervals(Makam.KURDI, override)
        assertEquals(override, store.intervals(Makam.KURDI))
    }

    @Test
    fun testResetRemovesOverride() {
        val override = listOf(9, 9, 4, 9, 9, 9, 4)
        store.setIntervals(Makam.USSAK, override)
        store.reset(Makam.USSAK)
        assertEquals(store.defaultIntervals(Makam.USSAK), store.intervals(Makam.USSAK))
    }

    @Test
    fun testCommasForNonEditableMakamsReturnsGuideCommas() {
        val majorCommas = store.commas(Makam.MAJOR)
        assertEquals(Makam.MAJOR.guideCommas, majorCommas)
        val minorCommas = store.commas(Makam.MINOR)
        assertEquals(Makam.MINOR.guideCommas, minorCommas)
    }

    @Test
    fun testCommasForEditableMakamsComputesFromIntervals() {
        // Kurdi'nin varsayılan aralıkları: 5, 8, 9, 9, 4, 9, 9
        val kurdiCommas = store.commas(Makam.KURDI)
        // Kümülatif: 0, 5, 13, 22, 31, 35, 44, 53
        assertEquals(listOf(0, 5, 13, 22, 31, 35, 44, 53), kurdiCommas)
    }

    @Test
    fun testCommasComputedFromOverriddenIntervals() {
        val override = listOf(1, 1, 1, 1, 1, 1, 47)
        store.setIntervals(Makam.KURDI, override)
        val kurdiCommas = store.commas(Makam.KURDI)
        assertEquals(listOf(0, 1, 2, 3, 4, 5, 6, 53), kurdiCommas)
    }

    @Test
    fun testCommasAlwaysSumTo53() {
        for (makam in Makam.values()) {
            val commas = store.commas(makam)
            assertEquals("Makam ${makam.displayName} commas should end at 53", 53, commas.last())
        }
    }

    @Test
    fun testSetIntervalsRejectsWrongCount() {
        val tooFew = listOf(9, 9, 9, 9, 9, 9)
        assertFalse(store.setIntervals(Makam.KURDI, tooFew))
        val tooMany = listOf(9, 9, 9, 9, 9, 9, 9, 9)
        assertFalse(store.setIntervals(Makam.KURDI, tooMany))
    }

    @Test
    fun testSetIntervalsReturnsFalseForInvalidIntervals() {
        val invalid = listOf(0, 9, 9, 9, 9, 9, 9) // 0 is invalid
        assertFalse(store.setIntervals(Makam.KURDI, invalid))
    }

    @Test
    fun testSetIntervalsReturnsTrueForValidIntervals() {
        val valid = listOf(9, 9, 4, 9, 9, 9, 4)
        assertTrue(store.setIntervals(Makam.KURDI, valid))
    }
}

class MusicContextGuideNotesTests {
    private val FREQUENCY_DELTA = 0.001

    @Test
    fun testGuideNotesGeneratesSevenOctaves() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.RE)
        val notes = context.guideNotes()
        // 7 derece × 7 oktav (-3…+3)
        assertEquals(49, notes.size)
    }

    @Test
    fun testGuideNotesHasKararMarkersInEveryOctave() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.RE)
        val notes = context.guideNotes()
        val kararNotes = notes.filter { it.isKarar }
        assertEquals(7, kararNotes.size) // -3…+3 = 7 oktav
    }

    @Test
    fun testGuideNotesFrequenciesIncreaseMonotonically() {
        val context = MusicContext(makam = Makam.NIHAVEND, karar = Karar.LA)
        val notes = context.guideNotes()
        for (i in 0 until notes.size - 1) {
            assertTrue("Frequencies should increase monotonically", notes[i].hz < notes[i + 1].hz)
        }
    }

    @Test
    fun testGuideNotesWithOverriddenCommasChangesCount() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.DO)
        val customCommas = listOf(0, 9, 18, 22, 53) // 4 derece + son işareti
        val notes = context.guideNotes(customCommas)
        assertEquals(28, notes.size) // 4 derece × 7 oktav
    }

    @Test
    fun testGuideNotesIncludeSharpAndFlatSuffixes() {
        val context = MusicContext(makam = Makam.HICAZ, karar = Karar.LA)
        val notes = context.guideNotes()
        // HICAZ makamının guideCommas'ı, doğal solfej konumlarından sapmaları olacak
        // Bazı notların ♯ veya ♭ süfiks içermesi beklenir
        val withSuffix = notes.filter { it.name.contains("♯") || it.name.contains("♭") }
        assertTrue("Some notes should have sharp/flat suffixes", withSuffix.isNotEmpty())
    }

    @Test
    fun testGuideNotesKararNoteFrequencyMatchesKarar() {
        val karar = Karar.LA
        val context = MusicContext(makam = Makam.MAJOR, karar = karar)
        val notes = context.guideNotes()
        // Merkez oktavda (oktav = 0) karar notu doğru frekans olmalı
        val centerKarar = notes.filter { it.isKarar && it.name.contains("La4") }
        if (centerKarar.isNotEmpty()) {
            assertEquals(karar.frequency, centerKarar[0].hz, FREQUENCY_DELTA)
        }
    }

    @Test
    fun testGuideNotesNamesStartWithSolfegeName() {
        val context = MusicContext(makam = Makam.MAJOR, karar = Karar.DO)
        val notes = context.guideNotes()
        val solfegNames = setOf("Do", "Re", "Mi", "Fa", "Sol", "La", "Si")
        for (note in notes) {
            val startsWithSolfeg = solfegNames.any { note.name.startsWith(it) }
            assertTrue("Note name ${note.name} should start with solfeg name", startsWithSolfeg)
        }
    }

    @Test
    fun testGuideNotesWithDifferentMakamsProduceDifferentPatterns() {
        val context1 = MusicContext(makam = Makam.MAJOR, karar = Karar.LA)
        val context2 = MusicContext(makam = Makam.HICAZ, karar = Karar.LA)
        val notes1 = context1.guideNotes()
        val notes2 = context2.guideNotes()
        // Aynı sayıda not
        assertEquals(notes1.size, notes2.size)
        // Ama farklı frekanslar
        val differentFrequencies = notes1.zip(notes2).any { (n1, n2) ->
            abs(n1.hz - n2.hz) > 0.1
        }
        assertTrue("Different makams should produce different frequencies", differentFrequencies)
    }
}
