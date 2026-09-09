// KlariVision iPhone/iPad — Dinleme modu işlem ve oynatma state'i.
// Import → analiz → viewer hazırlığı → atomik kütüphane kaydı sırasını yönetir.
// Başarısız WAV aktarımı kaydı korur; tracker başarılı oturumda çift eklemeyi
// engeller. UI yalnız phase değerini sunar.

import AVFoundation
import Foundation
import UIKit

enum iPadStudyPhase: Equatable {
    case idle
    case importing
    case analyzing(Double)
    case ready
    case failed(String)
}

/// Keeps an app-session record of completed WAV imports without changing the
/// persisted study schema. A failed analysis releases the URL for retry.
struct iPadCompletedRecordingImportTracker: Equatable {
    private var imported: Set<URL> = []
    private var importing: Set<URL> = []

    mutating func begin(_ source: URL) -> Bool {
        let source = source.standardizedFileURL
        guard !imported.contains(source), !importing.contains(source) else { return false }
        importing.insert(source)
        return true
    }

    mutating func finish(_ source: URL, succeeded: Bool) {
        let source = source.standardizedFileURL
        importing.remove(source)
        if succeeded { imported.insert(source) }
    }

    func contains(_ source: URL) -> Bool { imported.contains(source.standardizedFileURL) }
}

@MainActor
private final class iPadStudyProgressReporter {
    private let publish: (Double) -> Void
    init(publish: @escaping (Double) -> Void) { self.publish = publish }
    func update(_ value: Double) { publish(value) }
}

@MainActor
protocol iPadIdleTimerPolicy: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

@MainActor
final class iPadSystemIdleTimerPolicy: iPadIdleTimerPolicy {
    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}

@MainActor
@Observable
final class iPadStudyState {
    var phase: iPadStudyPhase = .idle
    var currentStudy: iPadStudy?
    var playbackTime = 0.0
    var duration = 0.0
    var isPlaying = false
    var rate = 1.0
    var loopA: Double?
    var loopB: Double?
    var looping = false
    var followsCurve = false
    /// Whether the current study's source has a video track to toggle to.
    /// Drives whether the compact workspace shows a fullscreen toggle at all.
    var hasVideo = false
    /// true = video fills the stage, graph is the floating corner button;
    /// false = the reverse (default). Native-owned so the toggle button stays
    /// tappable regardless of the WebView's own pinch-zoom state.
    var isVideoFullscreen = false
    /// Whether the graph (rather than video) currently fills the WebView
    /// stage — drives `iPadStudyWebView`'s pinch handling (see its doc comment).
    var isGraphMode: Bool { !(hasVideo && isVideoFullscreen) }
    private(set) var studies: [iPadStudy] = []
    let webView = iPadStudyWebViewStore()
    private let idleTimer: any iPadIdleTimerPolicy
    private var idleTimerWasDisabled = false
    private let libraryStore: iPadStudyLibraryStore?
    private let viewerLoader: @MainActor (iPadStudyWebViewStore, iPadStudy) throws -> Void

    // MARK: - "Birlikte Çal" (T6)
    //
    // Oturum burada, `iPadStudyState` üzerinde tutulur — bir View'da değil —
    // çünkü bu sınıfın zaten var olan üç ayrılış noktası
    // (`pauseForLeavingWorkspace()`, `close()`, `handleSceneBackground()`)
    // hepsi buradan `stopTogetherMode()` çağırabilir. Mikrofonu yalnız
    // `.onDisappear`'a bağlamak sahne arka plana geçişini KAÇIRIR (view
    // kaybolmaz, uygulama arka plana düşer) — macOS'un
    // `closeWorkspaceAfterPausing` yorumlarında uyarılan tuzağın SwiftUI
    // muadili budur.
    private let togetherSession = iPadTogetherSession()
    private(set) var isTogetherModeOn = false
    private(set) var isTogetherMuted = false
    var togetherMicErrorMessage: String?
    // Recorded WAV files live outside Imports until this state successfully
    // copies and analyzes them.  Keep this transient guard separate from the
    // persisted study model so Studies-v1.json remains unchanged.
    private var completedRecordingImports = iPadCompletedRecordingImportTracker()
    private var retryableCompletedRecording: URL?
    private var pitchColor = "#67d5ff"
    private var guideColor = "#b7d8ff"
    private var kararColor = "#E75A5A"
    private var makamIntervals = iPadMakamIntervalsStore()

    init(
        libraryStore: iPadStudyLibraryStore? = nil,
        idleTimer: (any iPadIdleTimerPolicy)? = nil,
        viewerLoader: @escaping @MainActor (iPadStudyWebViewStore, iPadStudy) throws -> Void = iPadStudyViewerResource.load
    ) {
        self.libraryStore = libraryStore ?? (try? iPadStudyLibraryStore())
        self.idleTimer = idleTimer ?? iPadSystemIdleTimerPolicy()
        self.viewerLoader = viewerLoader
        studies = (try? self.libraryStore?.load()) ?? []
        webView.onSnapshot = { [weak self] values in
            Task { @MainActor [weak self] in self?.applySnapshot(values) }
        }
    }

    func hasImportedRecordedSource(_ source: URL) -> Bool {
        completedRecordingImports.contains(source)
    }

    var isImporting: Bool {
        switch phase {
        case .importing, .analyzing: true
        case .idle, .ready, .failed: false
        }
    }

    var canRetryCompletedRecording: Bool { retryableCompletedRecording != nil }

    @discardableResult
    func retryCompletedRecording(engine: iPadPitchEngine) async -> Bool {
        guard let retryableCompletedRecording else { return false }
        return await importAndAnalyze(retryableCompletedRecording, engine: engine, isCompletedRecording: true)
    }

    @discardableResult
    func importAndAnalyze(_ source: URL, engine: iPadPitchEngine, isCompletedRecording: Bool = false) async -> Bool {
        let recordedSource = source.standardizedFileURL
        if isCompletedRecording {
            guard completedRecordingImports.begin(recordedSource) else { return false }
        }
        phase = .importing
        do {
            let copied = try await Task.detached { try iPadStudyImportService.copyImportedFile(from: source) }.value
            phase = .analyzing(0)
            let reporter = iPadStudyProgressReporter { [weak self] value in self?.phase = .analyzing(value) }
            let frames = try await Task.detached {
                try await iPadOfflinePitchAnalyzer.analyze(fileURL: copied, engine: engine) { value in
                    Task { @MainActor in reporter.update(value) }
                }
            }.value
            let asset = AVURLAsset(url: copied)
            let duration = max(((try? await asset.load(.duration))?.seconds) ?? 0, 0)
            let study = iPadStudy(id: UUID(), sourceURL: copied, title: source.deletingPathExtension().lastPathComponent, duration: duration, frames: frames, engine: engine, context: iPadMusicContext(), analyzedAt: Date(), pipelineRevision: iPadOfflinePitchAnalyzer.pipelineRevision)
            // Prepare the viewer before committing the study. If this late step
            // fails, retry must not find a persisted record and create a second
            // study for the same completed recording.
            try viewerLoader(webView, study)
            let updatedStudies = [study] + studies
            try libraryStore?.save(updatedStudies)
            studies = updatedStudies
            currentStudy = study
            self.duration = study.duration
            playbackTime = 0
            hasVideo = study.isVideoSource
            isVideoFullscreen = false
            webView.enqueue(contextCommand(for: study.context))
            phase = .ready
            if isCompletedRecording { completedRecordingImports.finish(recordedSource, succeeded: true) }
            if isCompletedRecording { retryableCompletedRecording = nil }
            return true
        } catch let error as LocalizedError {
            phase = .failed(error.errorDescription ?? "Çalışma hazırlanamadı.")
        } catch {
            phase = .failed("Çalışma hazırlanamadı.")
        }
        if isCompletedRecording {
            completedRecordingImports.finish(recordedSource, succeeded: false)
            retryableCompletedRecording = recordedSource
        }
        return false
    }

    func command(_ command: iPadStudyCommand) { webView.enqueue(command) }

    /// `rate` and `followsCurve` are normally echo-driven (`applySnapshot`),
    /// which lags a WebView round trip.  The settings sheet's ± control can
    /// fire faster than that, so these two intents update locally first and
    /// let the next snapshot confirm.
    func setRate(_ value: Double) {
        let next = iPadStudyPlaybackRate.rate(at: iPadStudyPlaybackRate.index(for: value))
        rate = next
        command(.rate(next))
    }

    func toggleFollow() {
        followsCurve.toggle()
        command(.follow)
    }

    /// Flips which side (graph or video) fills the stage and tells the JS
    /// side to match. Called from the native floating toggle button.
    func toggleVideoFullscreen() {
        isVideoFullscreen.toggle()
        command(.setVideoFullscreen(isVideoFullscreen))
    }

    func configure(graphPitchColor: String, guideColor: String, kararColor: String, makamIntervals: iPadMakamIntervalsStore? = nil) {
        pitchColor = graphPitchColor
        self.guideColor = guideColor
        self.kararColor = kararColor
        if let makamIntervals { self.makamIntervals = makamIntervals }
        if let currentStudy { webView.enqueue(contextCommand(for: currentStudy.context)) }
    }

    func open(_ study: iPadStudy) {
        pauseForLeavingWorkspace()
        currentStudy = study
        duration = study.duration
        playbackTime = 0
        hasVideo = study.isVideoSource
        isVideoFullscreen = false
        do {
            try viewerLoader(webView, study)
            webView.enqueue(contextCommand(for: study.context))
            phase = .ready
        } catch { phase = .failed("Kaydedilmiş çalışma açılamadı.") }
    }

    func updateContext(makam: iPadMakam? = nil, karar: iPadKarar? = nil, scaleDisplay: iPadScaleDisplay? = nil) {
        guard var study = currentStudy else { return }
        if let makam { study.context.makam = makam }
        if let karar { study.context.karar = karar }
        if let scaleDisplay { study.context.scaleDisplay = scaleDisplay }
        currentStudy = study
        if let index = studies.firstIndex(where: { $0.id == study.id }) { studies[index] = study }
        try? libraryStore?.save(studies)
        webView.enqueue(contextCommand(for: study.context))
    }

    private func contextCommand(for context: iPadMusicContext) -> iPadStudyCommand {
        .context(context, pitchColor: pitchColor, guideColor: guideColor, kararColor: kararColor, komaOverride: makamIntervals.commas(for: context.makam))
    }

    func updateTitle(_ title: String) {
        guard var study = currentStudy else { return }
        study.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !study.title.isEmpty else { return }
        currentStudy = study
        if let index = studies.firstIndex(where: { $0.id == study.id }) { studies[index] = study }
        try? libraryStore?.save(studies)
    }

    func removeFromLibrary(_ study: iPadStudy) {
        pauseForLeavingWorkspace()
        do { studies = try libraryStore?.remove(study.id, from: studies) ?? studies }
        catch { phase = .failed("Çalışma listeden kaldırılamadı.") }
        if currentStudy?.id == study.id { close() }
    }

    func pauseForLeavingWorkspace() {
        command(.pause)
        setPlaying(false)
        // Çalışma alanından her ayrılış (gezinme, kütüphaneye dönüş, sahne
        // arka plana geçişi) mikrofonu da kapatmalı — aksi halde donanım
        // görünmeyen bir ekranın arkasında açık kalır.
        stopTogetherMode()
    }

    func handleSceneBackground() { pauseForLeavingWorkspace() }

    func close() {
        pauseForLeavingWorkspace()
        webView.close()
        webView.tearDownView()
        currentStudy = nil
        phase = .idle
        playbackTime = 0
        duration = 0
        hasVideo = false
        isVideoFullscreen = false
        setPlaying(false)
    }

    /// Mikrofonu başlatır; izin reddedilirse veya başka bir hata oluşursa
    /// `togetherMicErrorMessage` Türkçe açıklamayla dolar ve mod açılmaz.
    /// `minimumRMS`, Çalma Modu'nun sinyal kapısıyla aynı ölçekte —
    /// ayrı bir "Birlikte Çal" kapısı icat edilmiyor.
    func startTogetherMode(engine: iPadPitchEngine, minimumRMS: Double, micColorHex: String) async {
        guard !isTogetherModeOn else { return }
        togetherMicErrorMessage = nil
        do {
            try await togetherSession.start(state: self, engine: engine, minimumRMS: minimumRMS, micColorHex: micColorHex)
            isTogetherModeOn = true
        } catch {
            isTogetherModeOn = false
            togetherMicErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Birlikte Çal mikrofonu başlatılamadı."
        }
    }

    /// Tek teardown noktası burada sarmalanır. İdempotent: zaten kapalıyken
    /// çağrılması güvenlidir.
    func stopTogetherMode() {
        togetherSession.stop()
        isTogetherModeOn = false
        isTogetherMuted = false
    }

    /// Yalnız referans çıkışını sessize alır/açar — akustik geri besleme
    /// içindir, mikrofon çizimi sürer (bkz. `iPadTogetherSession.setMuted`).
    func toggleTogetherMute() {
        guard isTogetherModeOn else { return }
        isTogetherMuted.toggle()
        togetherSession.setMuted(isTogetherMuted)
    }

    /// Tanılama satırı için: ölçülen giriş gecikmesi kaynağı. `TogetherSession`
    /// bu değeri kendi `measureInputLatency()`'siyle oturum başlatılırken
    /// ölçer; burada yalnız hangi kaynağın kullanıldığını okuyoruz.
    var togetherLatencySource: iPadMicLatencySource? { togetherSession.lastLatencySource }

    /// `togetherLatencySource` ile aynı anda okunacak, kaba bir gecikme
    /// tahmini. `TogetherSession` ölçtüğü kesin saniye değerini dışarı
    /// vermiyor (dosyaya dokunulmuyor), bu yüzden tanılama satırı aynı
    /// AVAudioSession değerlerini burada ayrıca okur — oturum etkinken bu,
    /// oturumun kendi ölçümüyle aynı değerdir.
    var togetherLatencyMilliseconds: Double? {
        guard isTogetherModeOn else { return nil }
        let session = AVAudioSession.sharedInstance()
        let input = session.inputLatency
        let buffer = session.ioBufferDuration
        guard input.isFinite, buffer.isFinite else { return nil }
        return (input + buffer) * 1_000
    }

    private func applySnapshot(_ values: [String: Any]) {
        playbackTime = (values["time"] as? NSNumber)?.doubleValue ?? playbackTime
        duration = (values["duration"] as? NSNumber)?.doubleValue ?? duration
        setPlaying((values["isPlaying"] as? Bool) ?? isPlaying)
        rate = (values["rate"] as? NSNumber)?.doubleValue ?? rate
        loopA = (values["loopA"] as? NSNumber)?.doubleValue
        loopB = (values["loopB"] as? NSNumber)?.doubleValue
        looping = (values["loopEnabled"] as? Bool) ?? looping
        followsCurve = (values["followsCurve"] as? Bool) ?? followsCurve
    }

    func setPlaying(_ value: Bool) {
        if value {
            guard !isPlaying else { return }
            idleTimerWasDisabled = idleTimer.isIdleTimerDisabled
            idleTimer.isIdleTimerDisabled = true
        } else {
            idleTimer.isIdleTimerDisabled = idleTimerWasDisabled
        }
        isPlaying = value
    }
}
