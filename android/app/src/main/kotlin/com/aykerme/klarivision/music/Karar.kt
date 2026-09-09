// KlariVision Android — karar perdeleri ve frekansları, Swift iPadKarar'dan port edildi.
// Do/Re/Mi/Fa/Sol/La/Si solfej tablosu, macOS izleyicisinin "Karar" seçicisi ve
// not-etiket sözlüğü ile tam olarak eşleşir.

package com.aykerme.klarivision.music

/**
 * Karar (tonal merkez) için yedi perde seçeneği. Her perde kendi fiziksel frekansını taşır.
 * Türkçe perde adları (Rast, Dügâh, vb.) yerine Do/Re/Mi/Fa/Sol/La/Si solfej kullanılır.
 */
enum class Karar(val displayName: String, val frequency: Double) {
    DO("Do", 523.251),
    RE("Re", 293.665),
    MI("Mi", 329.628),
    FA("Fa", 349.228),
    SOL("Sol", 391.995),
    LA("La", 440.0),
    SI("Si", 493.883);

    companion object {
        /**
         * Dizin adından karar bulur. Bilinmeyen değerler RE (varsayılan) döndürür.
         * Bu, eski derlemelerdeki "Rast"/Dügâh → Do/Re isim değişikliğine karşı toleranslı.
         */
        fun fromDisplayName(name: String): Karar {
            return values().firstOrNull { it.displayName == name } ?: RE
        }
    }
}
