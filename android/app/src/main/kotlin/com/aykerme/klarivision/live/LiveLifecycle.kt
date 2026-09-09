package com.aykerme.klarivision.live

/**
 * Canlı akış yaşam döngüsü durum makinesi.
 *
 * Swift kaynağı: `iPadLiveLifecycle` (LiveModels.swift). Swift tarafı
 * geçişleri önceki duruma bakmaksızın uygular (koşulsuz atama) — burada da
 * aynı davranış korunur. Bu, `stop()`'un idempotent olmasını doğal olarak
 * sağlar: zaten idle/interrupted durumundayken tekrar `stopped(reason)`
 * çağrılması hata üretmez, sadece aynı hedef duruma geçer.
 */
class LiveLifecycle {
    var phase: LivePhase = LivePhase.Idle
        private set

    /** İzin isteme aşamasına geçer. */
    fun requestStart() {
        phase = LivePhase.RequestingPermission
    }

    /** Akış başarıyla başladı. */
    fun started() {
        phase = LivePhase.Running
    }

    /** Akış hata ile sonlandı. */
    fun failed(message: String) {
        phase = LivePhase.Failed(message)
    }

    /**
     * Akışı durdurur. `reason` verilmişse `Interrupted(reason)`'a, verilmemişse
     * `Idle`'a geçer. Zaten durmuş bir durumdan tekrar çağrılması güvenlidir
     * (idempotent) — Swift tarafındaki koşulsuz atama semantiğiyle aynı.
     */
    fun stopped(reason: String? = null) {
        phase = reason?.let { LivePhase.Interrupted(it) } ?: LivePhase.Idle
    }
}
