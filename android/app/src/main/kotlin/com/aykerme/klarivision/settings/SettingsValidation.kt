// KlariVision Android — ayarlar doğrulaması ve clamp işlevleri.
// Saf Kotlin — Android API'siz, JVM testleriyle koşabilir.

import kotlin.math.pow

/**
 * Ayarlar değerlerinin doğrulanması ve clamp işlevleri.
 * Hatalı veya geçersiz değerler varsayılan veya clamp'lenmiş değerlere düşer;
 * hiçbir zaman çökmez.
 */
object SettingsValidation {
    /**
     * Pitch motoru adını doğrula.
     * Bilinmeyen değerler varsayılan "unified_v1" olur.
     */
    fun validateEngine(value: String?): String {
        if (value.isNullOrBlank()) return SettingsKeys.STUDY_PITCH_ENGINE_DEFAULT
        return if (value == "unified_v1") value else SettingsKeys.STUDY_PITCH_ENGINE_DEFAULT
    }

    /**
     * Tema adını doğrula.
     * Geçerli temalar: "focus", "studio", "classic"
     */
    fun validateTheme(value: String?): String {
        if (value.isNullOrBlank()) return SettingsKeys.THEME_DEFAULT
        return if (listOf("focus", "studio", "classic").contains(value)) value else SettingsKeys.THEME_DEFAULT
    }

    /**
     * Canlı sinyal kapısını dBFS cinsinden clamp et.
     * Aralık: [-60, -20]
     */
    fun clampGate(dbFS: Double): Double {
        return maxOf(SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MIN,
            minOf(SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MAX, dbFS))
    }

    /**
     * dBFS'i lineer RMS'e çevir.
     * Clamp'lenmiş kapı değerinden hesaplanır:
     * RMS = 10^(dBFS/20)
     */
    fun rmsForDbFs(dbFS: Double): Double {
        val clamped = clampGate(dbFS)
        return 10.0.pow(clamped / 20.0)
    }

    /**
     * Grafik renk kodunu doğrula (hex, # ile başlayan).
     * Format: #RRGGBB (6 hex digit)
     * Geçersiz değerler varsayılana düşer.
     */
    fun validateColor(value: String?, default: String): String {
        if (value.isNullOrBlank()) return default
        // Basit hex renk doğrulaması: #RRGGBB veya #RRGGBBAA
        if (!value.startsWith("#")) return default
        val hex = value.substring(1)
        if (hex.length !in listOf(6, 8)) return default
        if (!hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return default
        return value
    }

    /**
     * 53-koma aralıklarının dizisini doğrula.
     * Gereklilikler:
     * - Tam olarak 12 eleman
     * - Her eleman > 0
     * - Toplam = 53
     */
    fun validateKomaIntervals(values: List<Int>?): Boolean {
        if (values == null || values.size != 12) return false
        if (!values.all { it > 0 }) return false
        return values.sum() == 53
    }

    /**
     * 53-koma dizisini doğrula ve geçersizse varsayılana dön.
     */
    fun sanitizeKomaIntervals(values: List<Int>?): List<Int> {
        return if (validateKomaIntervals(values)) values!! else SettingsKeys.KOMA_INTERVALS_53_DEFAULT
    }

    /**
     * Makam koma aralıklarının dizisini doğrula.
     * Gereklilikler:
     * - Tam olarak 7 eleman
     * - Her eleman 1 ile 13 arasında
     * - Toplam = 53
     */
    fun validateMakamIntervals(values: List<Int>?): Boolean {
        if (values == null || values.size != 7) return false
        if (!values.all { it in 1..13 }) return false
        return values.sum() == 53
    }

    /**
     * Makam adını doğrula.
     * Geçerli makamlar: SettingsKeys.ALL_MAKAMS
     */
    fun validateMakam(value: String?): String {
        if (value.isNullOrBlank()) return SettingsKeys.LIVE_MAKAM_DEFAULT
        return if (SettingsKeys.ALL_MAKAMS.contains(value)) value else SettingsKeys.LIVE_MAKAM_DEFAULT
    }

    /**
     * Karar (tonal merkez) adını doğrula.
     * Geçerli karalar: Do, Re, Mi, Fa, Sol, La, Si
     */
    fun validateKarar(value: String?): String {
        if (value.isNullOrBlank()) return SettingsKeys.LIVE_KARAR_DEFAULT
        return if (SettingsKeys.ALL_KARARS.contains(value)) value else SettingsKeys.LIVE_KARAR_DEFAULT
    }

    /**
     * Ölçek gösterimi modunu doğrula.
     * Geçerli modlar: "Makam", "Türk Müziği (Sol Klarnet)"
     */
    fun validateScaleDisplay(value: String?): String {
        if (value.isNullOrBlank()) return SettingsKeys.LIVE_SCALE_DISPLAY_DEFAULT
        return if (SettingsKeys.ALL_SCALE_DISPLAYS.contains(value)) value else SettingsKeys.LIVE_SCALE_DISPLAY_DEFAULT
    }

    /**
     * Bir makam için varsayılan koma aralıklarını al.
     * Bilinmeyen makamlar için boş liste dön.
     */
    fun defaultIntervalsForMakam(makamName: String): List<Int> {
        return SettingsKeys.MAKAM_DEFAULTS[makamName] ?: emptyList()
    }
}
