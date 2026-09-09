package com.aykerme.klarivision.live

import kotlin.math.ln
import kotlin.math.roundToInt

/**
 * Frekanstan nota adına çeviren yardımcı.
 *
 * Swift kaynağı: `iPadTuner` (LiveModels.swift). Nota adları Türkçe solfej
 * (Do, Do♯, Re, ...) — Swift tarafıyla birebir aynı isimlendirme ve
 * yuvarlama kuralı (en yakın yarım tona yuvarlama, A4=440 Hz referansı).
 */
object Tuner {
    private val noteNames = listOf(
        "Do", "Do♯", "Re", "Re♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si",
    )

    /**
     * Verilen frekans için nota adı + oktav döner (ör. "La4"). Frekans null
     * veya sıfır/negatifse "—" döner.
     */
    fun label(frequency: Double?): String {
        if (frequency == null || frequency <= 0) return "—"
        val midi = (69 + 12 * log2(frequency / 440.0)).roundToInt()
        val noteIndex = ((midi % 12) + 12) % 12
        val octave = midi / 12 - 1
        return "${noteNames[noteIndex]}$octave"
    }

    private fun log2(value: Double): Double = ln(value) / ln(2.0)
}
