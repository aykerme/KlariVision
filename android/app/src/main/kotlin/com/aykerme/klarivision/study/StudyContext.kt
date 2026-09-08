// KlariVision Android — çalışma müzik bağlamı, Swift iPadMusicContext'ten port edildi.
// makam, karar, kılavuz çizgisi ayarları ve ölçek sunumu.

package com.aykerme.klarivision.study

import kotlinx.serialization.Serializable
import com.aykerme.klarivision.music.Karar
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.MusicContext
import com.aykerme.klarivision.music.ScaleDisplay

/**
 * JSON depolanması için açık alan adlarıyla müzik bağlamı.
 * Studies-v1.json'de saklanır; MusicContext'e dönüştürülebilir.
 */
@Serializable
data class StudyContext(
    /** Müzik makamı */
    val makam: String = "Nihavend",
    /** Tonal merkez perde */
    val karar: String = "Re",
    /** Grafik eğrisini takip etme */
    val followsCurve: Boolean = true,
    /** Kılavuz not sözlüğü seçimi */
    val scaleDisplay: String = "Makam"
) {
    /**
     * Bu bağlamı yönetilen MusicContext'e dönüştür.
     * Bilinmeyen makam → NIHAVEND, bilinmeyen karar → RE.
     */
    fun toMusicContext(): MusicContext {
        val makamEnum = Makam.fromDisplayName(makam) ?: Makam.NIHAVEND
        val kararEnum = Karar.fromDisplayName(karar)
        val scaleEnum = ScaleDisplay.fromDisplayName(scaleDisplay)
        return MusicContext(
            makam = makamEnum,
            karar = kararEnum,
            followsCurve = followsCurve,
            scaleDisplay = scaleEnum
        )
    }

    companion object {
        /**
         * Bir MusicContext'ten StudyContext oluştur (JSON depolaması için).
         */
        fun from(context: MusicContext): StudyContext {
            return StudyContext(
                makam = context.makam.displayName,
                karar = context.karar.displayName,
                followsCurve = context.followsCurve,
                scaleDisplay = context.scaleDisplay.displayName
            )
        }
    }
}
