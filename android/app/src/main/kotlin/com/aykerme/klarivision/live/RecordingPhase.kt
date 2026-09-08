package com.aykerme.klarivision.live

/**
 * Kayıt (WAV) aşamaları.
 *
 * Swift kaynağı: `iPadRecordingPhase` (LiveModels.swift). Swift'teki
 * `completed(URL)` yerine burada dosya yolunu temsilen `String` kullanılır —
 * bu katman saf Kotlin'dir, Android/Uri API'sine bağımlı değildir.
 */
sealed class RecordingPhase {
    object Idle : RecordingPhase()
    object Active : RecordingPhase()
    data class Completed(val path: String) : RecordingPhase()
    data class Failed(val message: String) : RecordingPhase()
}
