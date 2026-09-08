// KlariVision Android — uygulama ayarları anahtarları ve varsayılan değerleri.
// UserDefaults Swift sözleşmesine eşlenmiş; hiç bir varsayılan değer,
// renk kodu, clamp sınırı veya koma dizisi değiştirilmeyecek.

// Saf Kotlin sabitleri ve veriler — Android API'siz.

/**
 * Tüm kalıcı uygulama ayarlarının anahtar tanımları ve varsayılan değerleri.
 * DataStore Preferences'de saklanacak.
 */
object SettingsKeys {
    // Pitch motoru tercihlerine ait anahtarlar
    const val STUDY_PITCH_ENGINE = "klarivision-android-study-pitch-engine-v1"
    const val STUDY_PITCH_ENGINE_DEFAULT = "unified_v1"

    const val LIVE_PITCH_ENGINE = "klarivision-android-live-pitch-engine-v1"
    const val LIVE_PITCH_ENGINE_DEFAULT = "unified_v1"

    // Tema seçimi
    const val THEME = "klarivision-android-theme-v1"
    const val THEME_DEFAULT = "focus"

    // Canlı analiz sinyali kapısı (dBFS cinsinden)
    const val LIVE_SIGNAL_GATE_DBFS = "klarivision-android-live-signal-gate-dbfs-v1"
    const val LIVE_SIGNAL_GATE_DBFS_DEFAULT = -42.0
    const val LIVE_SIGNAL_GATE_DBFS_MIN = -60.0
    const val LIVE_SIGNAL_GATE_DBFS_MAX = -20.0

    // Grafik renkleri (hex kodları)
    const val GRAPH_PITCH_COLOR = "klarivision-android-graph-pitch-color-v1"
    const val GRAPH_PITCH_COLOR_DEFAULT = "#67d5ff"

    const val GRAPH_GUIDE_COLOR = "klarivision-android-graph-guide-color-v1"
    const val GRAPH_GUIDE_COLOR_DEFAULT = "#b7d8ff"

    const val GRAPH_KARAR_COLOR = "klarivision-android-graph-karar-color-v1"
    const val GRAPH_KARAR_COLOR_DEFAULT = "#E75A5A"

    // 53-koma sistem ayarları (12 aralık, toplam 53 koma)
    const val KOMA_INTERVALS_53 = "klarivision-android-53-koma-intervals-v1"
    val KOMA_INTERVALS_53_DEFAULT = listOf(4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 5)

    // Makam özel koma aralıkları (makam adı -> 7 aralık dizisi)
    // Nihavend, Kürdi, Uşşak, Hicaz, Hicazkâr, Kürdilihicazkâr için ayarlanabilir
    const val MAKAM_KOMA_INTERVALS = "klarivision-android-makam-koma-intervals-v1"

    // Makam seçimi (canlı analiz modunda)
    const val LIVE_MAKAM = "klarivision-android-live-makam-v1"
    const val LIVE_MAKAM_DEFAULT = "Nihavend"

    // Karar (tonal merkezin adı)
    const val LIVE_KARAR = "klarivision-android-live-karar-v1"
    const val LIVE_KARAR_DEFAULT = "Re"

    // Ölçek gösterimi (Makam veya Türk Müziği)
    const val LIVE_SCALE_DISPLAY = "klarivision-android-live-scale-display-v1"
    const val LIVE_SCALE_DISPLAY_DEFAULT = "Makam"

    // Makam varsayılan koma aralıkları (7 eleman her biri)
    // Majör / Minör: sabit diatonic desen
    val MAKAM_DEFAULTS = mapOf(
        "Majör" to listOf(9, 9, 4, 9, 9, 9, 4),  // [0, 9, 18, 22, 31, 40, 49, 53]
        "Minör" to listOf(9, 4, 9, 9, 4, 9, 9),  // [0, 9, 13, 22, 31, 35, 44, 53]
        "Nihavend" to listOf(9, 4, 9, 9, 4, 9, 9),  // [0, 9, 13, 22, 31, 35, 44, 53]
        "Kürdi" to listOf(5, 8, 9, 9, 4, 9, 9),  // [0, 5, 13, 22, 31, 35, 44, 53]
        "Uşşak" to listOf(8, 9, 5, 9, 8, 5, 9),  // [0, 8, 17, 22, 31, 39, 44, 53]
        "Hicaz" to listOf(5, 13, 4, 9, 9, 4, 9),  // [0, 5, 18, 22, 31, 40, 44, 53]
        "Hicazkâr" to listOf(5, 13, 4, 9, 9, 9, 4),  // [0, 5, 18, 22, 31, 40, 49, 53]
        "Kürdilihicazkâr" to listOf(5, 8, 9, 9, 9, 9, 4)  // [0, 5, 13, 22, 31, 40, 49, 53]
    )

    // Ayarlanabilir makamlar (makam koma aralıkları kaydedilebilen)
    val EDITABLE_MAKAMS = listOf("Nihavend", "Kürdi", "Uşşak", "Hicaz", "Hicazkâr", "Kürdilihicazkâr")

    // Tüm geçerli makam adları
    val ALL_MAKAMS = listOf("Majör", "Minör", "Nihavend", "Kürdi", "Uşşak", "Hicaz", "Hicazkâr", "Kürdilihicazkâr")

    // Tüm geçerli karar adları (Do/Re/Mi/Fa/Sol/La/Si solfeje)
    val ALL_KARARS = listOf("Do", "Re", "Mi", "Fa", "Sol", "La", "Si")

    // Tüm geçerli ölçek gösterimi modları
    val ALL_SCALE_DISPLAYS = listOf("Makam", "Türk Müziği (Sol Klarnet)")
}
