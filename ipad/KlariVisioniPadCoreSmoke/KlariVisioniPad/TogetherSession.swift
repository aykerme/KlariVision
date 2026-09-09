// KlariVision iPad — "Birlikte Çal" modu: Dinleme oynatması sürerken
// mikrofonu da açık tutan, kullanıcının çaldığı eğriyi referansın üstüne
// ayrı renkte çizen oturum. Puanlama/karşılaştırma YOK — yalnız görsel
// üst üste bindirme.
//
// Bu dosya macOS'un StudyWorkspace.swift içindeki `TogetherSession`
// sınıfının (satır ~421-535) birebir aynasıdır: gönderme kuralları
// (`handle(_:)`) doğrudan oradan taşındı. İki platform arasındaki tek
// gerçek fark giriş gecikmesinin kaynağıdır — macOS 10 ms'lik sabit bir
// CoreAudio varsayımı kullanırken, iPad bunu cihazdan ölçer (bkz.
// `measureInputLatency()`).

import AVFoundation
import Foundation
import OSLog
import WebKit

/// Bir mikrofon karesinin oynatma zaman eksenine çevrilmiş, viewer'a
/// gönderilmeye hazır hâli. macOS'un `StudyPitchPoint`'inin karşılığı.
struct iPadTogetherMicPoint: Equatable {
    let time: Double
    let frequency: Double
}

/// Giriş gecikmesi değeri hangi kaynaktan geldi — tanılama için dışarı
/// veriliyor (bkz. `iPadTogetherSession.lastLatencySource`).
enum iPadMicLatencySource: String, Equatable {
    case measured = "AVAudioSession (ölçülen: inputLatency + ioBufferDuration)"
    case fallback = "muhafazakâr varsayılan (AVAudioSession değerleri okunamadı)"
}

/// "Birlikte Çal" modunun asıl davranışı: mikrofonu çalıştırır, her perde
/// karesini medyanın zaman eksenine çevirir ve yalnız oynatma sürerken
/// viewer'a yollar. Pitch kararı ÜRETMEZ — eşikler yalnız Dinleme
/// tarafından (macOS `StudyPitchTrack.minimumConfidence`) alınmıştır.
///
/// Tek teardown noktası `stop()`'tur. Görünüm kapanırken veya moddan
/// çıkılırken bunu çağırmayı unutmak mikrofonu açık bırakır — macOS
/// yorumlarında özellikle uyarılmış aynı tuzak burada da geçerli.
@MainActor
final class iPadTogetherSession {
    private static let logger = Logger(subsystem: "com.aykerme.KlariVisioniPad", category: "TogetherSession")

    // MARK: Eleme eşikleri — Dinleme tarafıyla (macOS StudyPitchTrack /
    // StudyModels.swift) birebir aynı. Yeni bir pitch kararı icat edilmiyor;
    // bu sadece hangi karelerin çizime değer olduğunu belirliyor.
    static let minimumFrequencyHz = 80.0
    static let minimumConfidence = 0.20

    // MARK: Giriş gecikmesi — muhafazakâr, belgelenmiş varsayılanlar.
    // AVAudioSession değerleri okunamazsa (örn. oturum henüz etkin değilken)
    // bu ikisinin toplamı kullanılır. Tipik dahili mikrofon + küçük I/O
    // arabelleği için makul bir üst sınır.
    private static let fallbackInputLatencySeconds = 0.015
    private static let fallbackIOBufferDurationSeconds = 0.010

    /// Geri sıçrama (arama / loop B→A dönüşü) toleransı. macOS'ta bu tespiti
    /// viewer sayfası kendi `tick()` döngüsünde yapıyor (frequency_viewer.py,
    /// `now<lastObservedMediaTime-.05`). iPad'in StudyViewer.html'i (T1) bu
    /// davranışı içermiyor, o yüzden burada — servis katmanında — aynı
    /// toleransla yapılıyor.
    private static let rewindToleranceSeconds = 0.05

    private let analyzer = iPadLiveAnalyzer()
    private weak var state: iPadStudyState?
    private var rewindWatchTask: Task<Void, Never>?

    /// Son işlenen mikrofon karesinin zamanı (`iPadPitchFrame.time`
    /// ekseninde). macOS'un `lastSeenFrameTime` kalıbının aynısı: kareler
    /// teorik olarak üst üste/yeniden gelse bile bu imleç öncekini bir daha
    /// işletmez.
    private var lastSeenFrameTime: TimeInterval?

    /// Bu "Birlikte Çal" oturumunun mikrofon oturumu başladığı andaki duvar
    /// saati (`Date().timeIntervalSinceReferenceDate`). iPad'in çekirdek
    /// işlemcisi (`iPadLiveCoreProcessor.process`, LiveModels.swift) her
    /// kareye yalnız SESSION'a göreli bir `sourceTime` damgalıyor
    /// (`centerSample / 48000`) — duvar saati değil. Bu çapa, o göreli
    /// zamanı macOS'un beklediği duvar-saati tabanına çevirmek için tutulur.
    private var micStartWallTime: Double?

    /// `measureInputLatency()`'nin ölçtüğü toplam giriş gecikmesi (saniye).
    private var inputLatencySeconds: Double?

    /// Tanılama: son ölçümün kaynağı (ölçülen mi, varsayılan mı).
    private(set) var lastLatencySource: iPadMicLatencySource?

    private var lastObservedPlaybackTime: Double?

    /// Referans çıkışının sessize alınıp alınmadığı. Hoparlörden çalarken
    /// referansın kendisi mikrofona girip "kullanıcının eğrisi" gibi
    /// çizilebilir (akustik geri besleme) — macOS'taki sessize alma
    /// denetiminin nedeni budur. UI (T6) burada kulaklık kullanmayı da
    /// önerebilir.
    private(set) var muted = false

    /// Oturum şu an mikrofonu tutuyor mu — `start`/`stop` idempotent
    /// çağrılar için.
    var isActive: Bool { state != nil }

    /// Mikrofonu `engine`'le başlatır, viewer mikrofon katmanını temizler ve
    /// rengi uygular. Sıra macOS'un davranışıyla aynı: önce `micClear()`,
    /// sonra mikrofon, sonra `setMicColor(...)`.
    ///
    /// Mikrofon izni reddedilirse (`iPadLiveError.permissionDenied`,
    /// Türkçe açıklamalı) mod açılmaz — hata olduğu gibi çağırana fırlatılır.
    func start(
        state: iPadStudyState,
        engine: iPadPitchEngine = .unifiedV1,
        minimumRMS: Double,
        micColorHex: String
    ) async throws {
        guard !isActive else { return }
        lastSeenFrameTime = nil
        lastObservedPlaybackTime = nil
        micStartWallTime = nil
        inputLatencySeconds = nil

        state.command(.micClear)

        analyzer.onFrames = { [weak self] frames in self?.handle(frames) }
        analyzer.onStopped = { [weak self] _, _ in
            // Kesinti, rota değişikliği, arka plana geçiş vb. yüzünden
            // mikrofon kendiliğinden durursa oturumu tutarlı bırak: yeni
            // `start` çağrısı temiz bir durumdan başlasın.
            self?.resetAfterAnalyzerStopped()
        }

        let startedAt = Date().timeIntervalSinceReferenceDate
        do {
            try await analyzer.start(engine: engine, minimumRMS: minimumRMS)
        } catch {
            analyzer.onFrames = nil
            analyzer.onStopped = nil
            Self.logger.error("Birlikte Çal mikrofonu başlatılamadı: \(String(describing: error), privacy: .public)")
            throw error
        }
        micStartWallTime = startedAt
        let latency = Self.measureInputLatency()
        inputLatencySeconds = latency.seconds
        lastLatencySource = latency.source

        self.state = state
        state.command(.setMicColor(micColorHex))
        startRewindWatch()
    }

    /// Tek teardown noktası: mikrofonu kapatır. Görünüm kapanırken veya
    /// moddan çıkılırken çağıran (T6) bunu MUTLAKA çağırmalı, aksi halde
    /// mikrofon açık kalır — macOS'un `closeWorkspaceAfterPausing`
    /// yorumlarında özellikle uyarılmış aynı tuzak.
    func stop() {
        rewindWatchTask?.cancel()
        rewindWatchTask = nil
        analyzer.onFrames = nil
        analyzer.onStopped = nil
        let wasActive = isActive
        state = nil
        lastSeenFrameTime = nil
        micStartWallTime = nil
        inputLatencySeconds = nil
        lastObservedPlaybackTime = nil
        guard wasActive else { return }
        Task { await analyzer.stop(reason: nil) }
    }

    /// Yalnız referans ÇIKIŞINI sessize alır/açar; mikrofon çizimi sürer.
    /// StudyViewer.html'de (T1) macOS'taki gibi bir `setMuted` köprüsü
    /// tanımlı değil, bu yüzden dosyaya dokunmadan doğrudan sayfanın
    /// DOM'undaki medya elemanı (`<video>`/`<audio>`) sessize alınıyor —
    /// macOS'un "yalnız çıkışı sessize al, mikrofon çizimi sürsün"
    /// davranışının birebir karşılığı.
    func setMuted(_ value: Bool) {
        muted = value
        let js = "(function(){var m=document.querySelector('video,audio');if(m){m.muted=\(value ? "true" : "false");}})();"
        state?.webView.webView.evaluateJavaScript(js)
    }

    private func resetAfterAnalyzerStopped() {
        rewindWatchTask?.cancel()
        rewindWatchTask = nil
        state = nil
        lastSeenFrameTime = nil
        micStartWallTime = nil
        inputLatencySeconds = nil
        lastObservedPlaybackTime = nil
    }

    // MARK: - Gönderme kuralları (macOS `TogetherSession.handle` birebir)

    private func handle(_ frames: [iPadPitchFrame]) {
        guard let state, let micStartWallTime, let inputLatencySeconds else { return }

        // Yalnız oynarken nokta üret. Medya duraklatılmışken mikrofon
        // donanımı açık kalır, yalnız çizim durur — bilinçli karar. İmleci
        // yine de ilerlet ki oynatma yeniden başladığında duraklama
        // sırasında biriken kareler toptan gönderilmesin.
        guard state.isPlaying else {
            lastSeenFrameTime = frames.last?.time ?? lastSeenFrameTime
            return
        }

        // Kareler kümülatif gelmiyor (iPadLiveWorker zaten yalnız yeni
        // birikimi yolluyor — LiveAnalyzer.swift), ama imleç yine de
        // korunuyor: macOS'un `lastSeenFrameTime` kalıbıyla aynı güvenlik
        // ağı, yalnız `frame.time > cursor` olan kareler alınır.
        let cursor = lastSeenFrameTime
        let additions = frames.filter { frame in cursor.map { frame.time > $0 } ?? true }
        lastSeenFrameTime = frames.last?.time ?? lastSeenFrameTime
        guard !additions.isEmpty else { return }

        // Her kare kendi `time`'ı üzerinden çevrilir; toplu gönderimde
        // partiye tek bir zaman damgası verilmez.
        let wallNow = Date().timeIntervalSinceReferenceDate
        let clockNow = state.playbackTime
        let rate = state.rate
        let userAlignment = iPadTogetherTimeMapping.clampMicAlignmentMs(
            UserDefaults.standard.double(forKey: iPadAppState.togetherMicAlignmentMsKey)
        ) / 1_000
        let fixedLatency = iPadTogetherTimeMapping.fixedLatency(inputLatencySeconds: inputLatencySeconds)

        // Eleme: frequency sonlu ve ≥ 80 Hz, confidence ≥ 0,20 — Dinleme
        // tarafıyla aynı eşikler.
        let points = additions.compactMap { frame -> iPadTogetherMicPoint? in
            guard frame.frequency.isFinite, frame.frequency >= Self.minimumFrequencyHz,
                  frame.confidence >= Self.minimumConfidence else { return nil }

            // `frame.time`, iPadLiveCoreProcessor'ın pencere MERKEZİNE göre
            // damgaladığı, oturum başlangıcına göreli bir zamandır. Ortak
            // `TogetherTimeMapping.fixedLatency(inputLatencySeconds:)` ise
            // (macOS'u birebir izleyerek) frameTime'ın pencere BAŞLANGICının
            // duvar saati olmasını ve merkez düzeltmesini kendisinin ayrıca
            // eklemesini bekler. İkisini çakıştırmamak için burada önce
            // merkez ofseti geri çıkarılıyor, sonra oturum başlangıç duvar
            // saatine ekleniyor.
            let windowStartSourceTime = frame.time - iPadTogetherTimeMapping.windowCenterSeconds
            let frameWallTime = micStartWallTime + windowStartSourceTime

            let mediaTime = iPadTogetherTimeMapping.mapFrameToMediaTime(
                clockNow: clockNow,
                wallNow: wallNow,
                frameTime: frameWallTime,
                rate: rate,
                userAlignmentSeconds: userAlignment,
                fixedLatency: fixedLatency
            )
            guard mediaTime.isFinite, mediaTime >= 0 else { return nil }
            return iPadTogetherMicPoint(time: mediaTime, frequency: frame.frequency)
        }
        guard !points.isEmpty else { return }
        state.command(.micAppend(points))
    }

    // MARK: - Geri sıçrama izleme (arama / loop B→A)

    private func startRewindWatch() {
        rewindWatchTask?.cancel()
        rewindWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.checkForRewind()
            }
        }
    }

    private func checkForRewind() {
        guard let state else { return }
        let now = state.playbackTime
        defer { lastObservedPlaybackTime = now }
        guard let previous = lastObservedPlaybackTime, now < previous - Self.rewindToleranceSeconds else { return }
        state.command(.micTruncate(now))
    }

    // MARK: - Giriş gecikmesi ölçümü

    /// `AVAudioSession.sharedInstance().inputLatency + ioBufferDuration`.
    /// Bu değer YAKLAŞIKTIR: kullanıcının hizalama kaydırıcısı (±200 ms,
    /// `iPadAppState.togetherMicAlignmentMs`) ince ayar içindir. Değerler
    /// okunamazsa (finite değilse veya oturum henüz etkin değilken sıfır
    /// dönerse) belgelenmiş, muhafazakâr bir varsayılana düşülür. Hangi
    /// kaynağın kullanıldığı `Logger` üzerinden tanılama için dışarı
    /// verilir.
    private static func measureInputLatency() -> (seconds: Double, source: iPadMicLatencySource) {
        let session = AVAudioSession.sharedInstance()
        let measuredInput = session.inputLatency
        let measuredBuffer = session.ioBufferDuration
        guard measuredInput.isFinite, measuredInput > 0, measuredBuffer.isFinite, measuredBuffer >= 0 else {
            let fallback = fallbackInputLatencySeconds + fallbackIOBufferDurationSeconds
            logger.notice("Giriş gecikmesi ölçülemedi (inputLatency=\(measuredInput, privacy: .public), ioBufferDuration=\(measuredBuffer, privacy: .public)); varsayılana düşüldü: \(fallback, privacy: .public)s")
            return (fallback, .fallback)
        }
        let total = measuredInput + measuredBuffer
        logger.notice("Giriş gecikmesi ölçüldü: inputLatency=\(measuredInput, privacy: .public)s + ioBufferDuration=\(measuredBuffer, privacy: .public)s = \(total, privacy: .public)s")
        return (total, .measured)
    }
}
