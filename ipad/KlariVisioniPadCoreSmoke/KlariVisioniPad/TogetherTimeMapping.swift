// KlariVision iPad — Birlikte Çal modu zaman eşlemesi.
// Mikrofon karelerini medya zamanına dönüştür. Saf Swift.

import Foundation

/// Birlikte Çal modunda mikrofon karelerini oynatma zamanına eşleyen saf işlevler.
/// macOS StudyWorkspace.swift'teki `mapFrameToMediaTime` ve clamp kurallarını taşır.
enum iPadTogetherTimeMapping {
    // Analiz penceresinin merkezi (örnek merkezine damgalanmış zaman için).
    // Pencere 1536 örnek / 48 kHz ≈ 32,0 ms; merkezi yaklaşık 16,0 ms.
    static let windowCenterSeconds = (1536.0 / 2.0) / 48000.0

    /// Sabit gecikmeyi hesapla: pencere merkezi + giriş gecikmesi.
    /// Pencere merkezi sabiti tüm platformlarda aynıdır; giriş gecikmesi
    /// platform tarafından sağlanır (Android: AudioRecord.getTimestamp(),
    /// iOS: AVAudioSession.inputLatency).
    ///
    /// - Parameter inputLatencySeconds: Giriş gecikmesi (saniye cinsinden)
    /// - Returns: Toplam sabit gecikme (saniye cinsinden)
    static func fixedLatency(inputLatencySeconds: Double) -> Double {
        return windowCenterSeconds + inputLatencySeconds
    }

    /// Saf ve test edilebilir zaman eşlemesi.
    /// `frameTime` ve `wallNow` aynı duvar-saati taban çizgisini paylaşır (Date().timeIntervalSinceReferenceDate).
    /// `clockNow`, medya oynatıcısının o anki medya zamanıdır (saniye).
    /// `userAlignment` saniye cinsindendir (milisaniyeyi 1000'e bölerek burada saniyeye çevrilir).
    ///
    /// Formül:
    /// mediaTime = clockNow − (wallNow − frameTime) × rate − fixedLatency − userAlignment
    ///
    /// - Parameter clockNow: Medya oynatıcısının şimdiki medya zamanı (saniye)
    /// - Parameter wallNow: Şimdiki duvar-saati (saniye)
    /// - Parameter frameTime: Mikrofon karesinin duvar-saati (saniye)
    /// - Parameter rate: Oynatma hızı (1.0 = normal, 0.5 = yarı hız)
    /// - Parameter userAlignmentSeconds: Kullanıcı hizalaması (saniye)
    /// - Parameter fixedLatency: Sabit gecikme: pencere merkezi + giriş gecikmesi (saniye)
    /// - Returns: Mikrofon karesinin medya zamanı (saniye)
    static func mapFrameToMediaTime(
        clockNow: Double,
        wallNow: Double,
        frameTime: Double,
        rate: Double,
        userAlignmentSeconds: Double,
        fixedLatency: Double
    ) -> Double {
        return clockNow - (wallNow - frameTime) * rate - fixedLatency - userAlignmentSeconds
    }

    /// Mikrofon hizalamasını −200…+200 ms aralığına kelepçeler.
    /// −250 → −200, +250 → +200, 0 → 0, −200 → −200
    ///
    /// - Parameter valueMs: Hizalama (milisaniye)
    /// - Returns: Clamp'lenmiş hizalama (milisaniye)
    static func clampMicAlignmentMs(_ valueMs: Double) -> Double {
        return max(-200, min(200, valueMs))
    }
}
