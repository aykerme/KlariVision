// KlariVision Android — Birlikte Çal modu zaman eşlemesi.
// Mikrofon karelerini medya zamanına dönüştür. Saf Kotlin — Android API'siz, JVM testleriyle koşabilir.

/**
 * Birlikte Çal modunda mikrofon karelerini oynatma zamanına eşleyen saf işlevler.
 * macOS StudyWorkspace.swift'teki `mapFrameToMediaTime` ve clamp kurallarını taşır.
 */
object TogetherTimeMapping {
    // Analiz penceresinin merkezi (örnek merkezine damgalanmış zaman için).
    // Pencere 1536 örnek / 48 kHz ≈ 32,0 ms; merkezi yaklaşık 16,0 ms.
    const val WINDOW_CENTER_SECONDS = (1536.0 / 2.0) / 48000.0

    /**
     * Sabit gecikmeyi hesapla: pencere merkezi + giriş gecikmesi.
     * Pencere merkezi sabiti tüm platformlarda aynıdır; giriş gecikmesi
     * platform tarafından sağlanır (Android: AudioRecord.getTimestamp(),
     * iOS: AVAudioSession.inputLatency).
     *
     * @param inputLatencySeconds Giriş gecikmesi (saniye cinsinden)
     * @return Toplam sabit gecikme (saniye cinsinden)
     */
    fun fixedLatency(inputLatencySeconds: Double): Double {
        return WINDOW_CENTER_SECONDS + inputLatencySeconds
    }

    /**
     * Saf ve test edilebilir zaman eşlemesi.
     * `frameTime` ve `wallNow` aynı duvar-saati taban çizgisini paylaşır (System.currentTimeMillis() / 1000).
     * `clockNow`, medya oynatıcısının o anki medya zamanıdır (saniye).
     * `userAlignment` saniye cinsindendir (milisaniyeyi 1000'e bölerek burada saniyeye çevrilir).
     *
     * Formül:
     * mediaTime = clockNow − (wallNow − frameTime) × rate − fixedLatency − userAlignment
     *
     * @param clockNow Medya oynatıcısının şimdiki medya zamanı (saniye)
     * @param wallNow Şimdiki duvar-saati (saniye)
     * @param frameTime Mikrofon karesinin duvar-saati (saniye)
     * @param rate Oynatma hızı (1.0 = normal, 0.5 = yarı hız)
     * @param userAlignmentSeconds Kullanıcı hizalaması (saniye)
     * @param fixedLatency Sabit gecikme: pencere merkezi + giriş gecikmesi (saniye)
     * @return Mikrofon karesinin medya zamanı (saniye)
     */
    fun mapFrameToMediaTime(
        clockNow: Double,
        wallNow: Double,
        frameTime: Double,
        rate: Double,
        userAlignmentSeconds: Double,
        fixedLatency: Double
    ): Double {
        return clockNow - (wallNow - frameTime) * rate - fixedLatency - userAlignmentSeconds
    }

    /**
     * Mikrofon hizalamasını −200…+200 ms aralığına kelepçeler.
     * −250 → −200, +250 → +200, 0 → 0, −200 → −200
     *
     * @param valueMs Hizalama (milisaniye)
     * @return Clamp'lenmiş hizalama (milisaniye)
     */
    fun clampMicAlignmentMs(valueMs: Double): Double {
        return maxOf(-200.0, minOf(200.0, valueMs))
    }
}
