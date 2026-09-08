// KlariVision Android — grafik kılavuz çizgileri/etiketleri hangi not sözlüğünü kullandığı,
// Swift iPadScaleDisplay'den port edildi.

package com.aykerme.klarivision.music

/**
 * Grafik kılavuz çizgileri ve etiketlerinin hangi not sözlüğünü kullanacağını belirler.
 */
enum class ScaleDisplay(val displayName: String) {
    MAKAM("Makam"),
    TURKISH_CLARINET("Türk Müziği (Sol Klarnet)");

    companion object {
        /**
         * Dizin adından ScaleDisplay bulur. Bilinmeyen değerler MAKAM döndürür.
         */
        fun fromDisplayName(name: String): ScaleDisplay {
            return values().firstOrNull { it.displayName == name } ?: MAKAM
        }
    }
}
