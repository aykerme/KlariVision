// KlariVision Android — müzik bağlamı ve kılavuz noter, Swift iPadMusicContext'ten port edildi.

package com.aykerme.klarivision.music

import kotlin.math.abs
import kotlin.math.log2
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Seçili makam ve karar tarafından tanımlanan müzik bağlamı.
 * Makam.guideCommas ve Karar.frequency'den başlayarak kılavuz frekansları ve etiketli notaları üretir.
 */
data class MusicContext(
    val makam: Makam = Makam.NIHAVEND,
    val karar: Karar = Karar.RE,
    val followsCurve: Boolean = true,
    val scaleDisplay: ScaleDisplay = ScaleDisplay.MAKAM
) {
    /**
     * Seçili makamın koma pozisyonlarından frekansları hesaplar.
     * @param overrideCommas Makam.guideCommas yerine kullanılan koma listesi (isteğe bağlı).
     * @return Frekans listesi, Hz cinsinden.
     */
    fun guideFrequencies(overrideCommas: List<Int>? = null): List<Double> {
        val commas = overrideCommas ?: makam.guideCommas
        return commas.map { comma ->
            karar.frequency * 2.0.pow(comma / 53.0)
        }
    }

    /**
     * Solfej halkası, gerçek ayarlanmış frekanslarla artan sırada (Re en düşük, Do en yüksek).
     * Bu, macOS izleyicisinin makamLabel/makamNotes adlandırması ile tam eşleşir.
     */
    private val perdeCycle: List<Karar> = listOf(Karar.RE, Karar.MI, Karar.FA, Karar.SOL, Karar.LA, Karar.SI, Karar.DO)

    /**
     * Re'den perde'nin doğal 53-koma uzaklığı, perde'nin kendi ayarlanmış frekansından türetildi.
     */
    private fun naturalKoma(perde: Karar): Int {
        return (53 * log2(perde.frequency / Karar.RE.frequency)).roundToInt()
    }

    /**
     * Makam kılavuz çizgileri macOS tarzı solfej etiketleriyle eşleştirilir:
     * - Taban not adı + oktav numarası
     * - Makamın koma pozisyonu o notanın doğal 53-koma pozisyonundan farklıysa ♯N/♭N koma-sapması eki
     *
     * -3…+3 oktavları span'ı (macOS makamNotes() ile aynı), çünkü çağıran (StudyViewer.html/LiveViewer.html)
     * zaten görünür aralığa klipler, bu yalnız grafik ulaşabileceği herhangi bir dikey aralığı/zoom'u/
     * takip konumunu kaplaması gerekir, tek oktavı değil.
     *
     * @param overrideCommas Makam.guideCommas yerine kullanılan koma listesi (isteğe bağlı).
     * @return (notAdı, frekans, karar mı) tuple'ı listesi.
     */
    fun guideNotes(overrideCommas: List<Int>? = null): List<GuideNote> {
        // Türkçe perde referans tablosunu kullan (uygulamanın sonraki sürümünde).
        // if (scaleDisplay == ScaleDisplay.TURKISH_CLARINET) { return turkishPitchReference() }

        val cycle = perdeCycle
        val rootIndex = cycle.indexOfFirst { it == karar }
        if (rootIndex == -1) return emptyList()

        val rootKoma = naturalKoma(karar)

        // 8 giriş [0,…,53]; sondaki oktav tekrarını kaldır ki her derece
        // yalnız bir kez listelenir, sonra her oktav kaydırmasında yeniden eklenir.
        val degreeCommas = (overrideCommas ?: makam.guideCommas).dropLast(1)
        val notes = mutableListOf<GuideNote>()

        for (octaveShift in -3..3) {
            for (degree in degreeCommas.indices) {
                val comma = degreeCommas[degree] + 53 * octaveShift
                val hz = karar.frequency * 2.0.pow(comma / 53.0)
                val base = cycle[(rootIndex + degree) % 7]
                val naturalStep = (((naturalKoma(base) - rootKoma) % 53 + 53) % 53) + 53 * octaveShift
                val adjustment = comma - naturalStep
                val suffix = when {
                    adjustment == 0 -> ""
                    adjustment > 0 -> " ♯$adjustment"
                    else -> " ♭${abs(adjustment)}"
                }
                val midi = (69 + 12 * log2(hz / 440.0)).roundToInt()
                val octave = midi / 12 - 1
                val noteName = "${base.displayName}$octave$suffix"
                notes.add(GuideNote(name = noteName, hz = hz, isKarar = degree == 0))
            }
        }

        return notes
    }

    /**
     * Bir kılavuz notası — ad, frekans, karar konumu indicesi.
     */
    data class GuideNote(val name: String, val hz: Double, val isKarar: Boolean)
}
