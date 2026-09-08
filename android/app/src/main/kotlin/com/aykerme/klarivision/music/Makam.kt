// KlariVision Android — makam ve karar müzik teorisi, Swift iPadMakam'dan port edildi.
// Kullanıcı tarafından seçilen müzik sunumu. Yalnız etiketleri ve kılavuz çizgileri etkiler;
// gelen fiziksel frekans çerçeveleri hiçbir zaman aktarılmaz veya yeniden yazılmaz.

package com.aykerme.klarivision.music

/**
 * Sekiz Türk müziği makamı. Her makamın 53-koma başlangıçları kendi `guideCommas` tablosunda
 * tanımlanır. Kılavuz çizgiler kasıtlı olarak gösterim yardımıdır ve otomatik makam algısını
 * anlamına gelmez.
 */
enum class Makam(val displayName: String, val guideCommas: List<Int>) {
    MAJOR("Majör", listOf(0, 9, 18, 22, 31, 40, 49, 53)),
    MINOR("Minör", listOf(0, 9, 13, 22, 31, 35, 44, 53)),
    NIHAVEND("Nihavend", listOf(0, 9, 13, 22, 31, 35, 44, 53)),
    KURDI("Kürdi", listOf(0, 5, 13, 22, 31, 35, 44, 53)),
    USSAK("Uşşak", listOf(0, 8, 17, 22, 31, 39, 44, 53)),
    HICAZ("Hicaz", listOf(0, 5, 18, 22, 31, 40, 44, 53)),
    HICAZKAR("Hicazkâr", listOf(0, 5, 18, 22, 31, 40, 49, 53)),
    KURDILIHICAZKAR("Kürdilihicazkâr", listOf(0, 5, 13, 22, 31, 40, 49, 53));

    companion object {
        /**
         * Dizin adından makam bulur. Bilinmeyen değerler null döndürür.
         */
        fun fromDisplayName(name: String): Makam? {
            return values().firstOrNull { it.displayName == name }
        }
    }
}
