package com.aykerme.klarivision.core

/**
 * `kv_pitch_frame`'in Kotlin yansıması (analysis_engine_c.h). `timeSeconds`
 * kaynak analiz penceresinin MERKEZİNİ tanımlar, yayın gecikmesini değil.
 */
data class PitchFrame(
    val timeSeconds: Double,
    val frequencyHz: Double,
    val confidence: Double,
    val voiced: Boolean,
)
