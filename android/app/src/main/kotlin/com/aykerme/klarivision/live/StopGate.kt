package com.aykerme.klarivision.live

/**
 * Aynı anda birden çok kaynaktan (ses odağı kaybı, rota değişimi, yaşam
 * döngüsü onPause/onStop, `AudioRecord` hatası) gelebilecek durdurma
 * çağrılarının YALNIZ BİRİNİN yürütülmesini garanti eden saf kapı.
 *
 * Swift kaynağı: `iPadLiveAnalyzer.isStopping` bayrağı ve `stop(reason:)`
 * başındaki `guard !isStopping else { return }` (LiveAnalyzer.swift). Bu
 * sınıf o korumayı platformdan bağımsız, test edilebilir bir birime
 * çıkarır — Android API'sine bağımlı değildir, JVM testiyle koşar.
 *
 * Kullanım: dört durdurma kaynağı da [begin] çağırır; yalnız `true` dönen
 * ÇAĞIRAN taraf gerçek durdurma işini yapar (AudioRecord/thread/session
 * kapatma). İş bitince [complete] çağrılır ve kapı yeni bir başlatma
 * çevrimi için tekrar açılır — bu da her durdurmadan sonra YENİ bir
 * `AudioRecord`/`LivePitchSession` kurulmasını doğal olarak sağlar.
 */
class StopGate {
    private var stopping = false
    private var lastReason: String? = null

    /**
     * Bir durdurma isteğinin YÜRÜTÜLMESİ gerekip gerekmediğini döner.
     * `true` dönerse çağıran taraf gerçek durdurma işini yapmalı ve işi
     * bitince [complete] çağırmalıdır. `false` dönerse zaten sürmekte olan
     * bir durdurma vardır — çağıran hiçbir şey yapmamalıdır (idempotent).
     */
    fun begin(reason: String?): Boolean {
        if (stopping) return false
        stopping = true
        lastReason = reason
        return true
    }

    /** Sürmekte olan durdurmayı tamamlar; kapı yeni bir çevrim için açılır. */
    fun complete() {
        stopping = false
    }

    fun isStopping(): Boolean = stopping

    /** En son [begin] ile kabul edilen (yürütülen) durdurma nedeni. */
    fun lastReason(): String? = lastReason
}
