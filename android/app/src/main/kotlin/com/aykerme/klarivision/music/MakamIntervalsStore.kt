// KlariVision Android — makam aralık yönetimi, Swift iPadMakamIntervalsStore'dan port edildi.
// Kalıcılık bu katmanın kapsamı dışında (başka bir ajan DataStore'a yazacak).
// Yalnız doğrulama ve bellek içi saklama.

package com.aykerme.klarivision.music

/**
 * Ayarlanabilir makamlar için 7 koma-aralığı adımı için kalıcı, kullanıcı tarafından
 * değiştirilebilir geçersiz kılmaları tutacak mağaza. Majör/Minör sabit diyatonic
 * kalıbını korur; macOS'ta da seçenekler yoktur (MAKAM_DEFAULT_INTERVALS'ta da yok).
 */
class MakamIntervalsStore {
    /**
     * Düzenlenebilir makamlar — Majör ve Minör hariç.
     */
    private val editableModes = setOf(
        Makam.NIHAVEND,
        Makam.KURDI,
        Makam.USSAK,
        Makam.HICAZ,
        Makam.HICAZKAR,
        Makam.KURDILIHICAZKAR
    )

    /**
     * Makam başına kalıcı geçersiz kılmalar. Başlangıçta boş.
     */
    private val overrides = mutableMapOf<Makam, List<Int>>()

    /**
     * Makamın 7 koma delta adımı — kendi kümülatif guideCommas'ından türetildi
     * (8 giriş: ilk 0, sonra 53'te biten 7 adım). Editörün başlama noktası ve
     * "Teoriye Dön" sıfırlama hedefi.
     */
    fun defaultIntervals(makam: Makam): List<Int> {
        var previous = 0
        return makam.guideCommas.drop(1).map { value ->
            val delta = value - previous
            previous = value
            delta
        }
    }

    /**
     * Aralık listesini doğrular.
     * Geçerli: tam 7 element, her biri 1…13, toplam 53.
     */
    fun isValid(intervals: List<Int>): Boolean {
        return intervals.size == 7 &&
                intervals.all { it in 1..13 } &&
                intervals.sum() == 53
    }

    /**
     * Makam için geçerli aralıkları al (geçersiz kılmalar varsa, yoksa varsayılanlar).
     */
    fun intervals(makam: Makam): List<Int> {
        return overrides[makam] ?: defaultIntervals(makam)
    }

    /**
     * Makam aralıklarını ayarla. Yalnız düzenlenebilir makamlar üzerinde işlemi gerçekleştirir.
     * @return Geçerli mi?
     */
    fun setIntervals(makam: Makam, intervals: List<Int>): Boolean {
        if (!editableModes.contains(makam) || intervals.size != 7) return false
        overrides[makam] = intervals
        return isValid(intervals)
    }

    /**
     * Makamı varsayılan aralıklara sıfırla.
     */
    fun reset(makam: Makam) {
        overrides.remove(makam)
    }

    /**
     * Kümülatif koma pozisyonları (8 giriş — ilk 0, sonra 53'te biten 7 adım).
     * MusicContext.guideNotes(commas:)/guideFrequencies(commas:) için hazır.
     */
    fun commas(makam: Makam): List<Int> {
        if (!editableModes.contains(makam)) {
            return makam.guideCommas
        }

        var running = 0
        val result = mutableListOf(0)
        for (delta in intervals(makam)) {
            running += delta
            result.add(running)
        }
        return result
    }
}
