// KlariVision Android — sorun çerçeveleri, Swift iPadPitchFrame'den port edildi.
// Verilen bir anın frekansı, güven düzeyi ve ses karakteristiğini tutar.

package com.aykerme.klarivision.study

import kotlinx.serialization.Serializable

/**
 * Offline pitch analizi çıktısından tek bir zaman çerçevesi.
 * Verilen sürede algılanan frekans, sinyal güven puanı ve sesin karakteristiğini kaydeder.
 */
@Serializable
data class PitchFrame(
    /** Saniye cinsinden zaman konumu */
    val time: Double,
    /** Hert cinsinden frekans */
    val frequency: Double,
    /** 0.0…1.0 arası güven puanı */
    val confidence: Double,
    /** Sesin sesli (true) veya sessiz (false) olduğu */
    val voiced: Boolean
)
