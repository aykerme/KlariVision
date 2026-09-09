package com.aykerme.klarivision.live

/**
 * Canlı akışın durum makinesi aşamaları.
 *
 * Swift kaynağı: `iPadLivePhase` (LiveModels.swift). Birebir karşılık:
 * idle / requestingPermission / running / interrupted(mesaj) / failed(mesaj).
 */
sealed class LivePhase {
    object Idle : LivePhase()
    object RequestingPermission : LivePhase()
    object Running : LivePhase()
    data class Interrupted(val message: String) : LivePhase()
    data class Failed(val message: String) : LivePhase()
}
