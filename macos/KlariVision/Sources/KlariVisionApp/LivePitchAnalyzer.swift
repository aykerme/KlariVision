// KlariVision macOS — canlı ses yakalama ve pitch üretim boru hattı.
// Akış: AVAudioEngine tap → mono PCM → RMS kapısı → üretim motoru → frame.
// Audio callback içinde ağır iş/UI yayını yapılmaz. YIN/V2/VPM davranışı ortak
// C++ oturumla birlikte değerlendirilir; tek taraflı eşik değişikliği yapılmaz.
// Sıra: ayarlar → modeller → motor adaptörleri → analizör → test yardımcıları.

import Accelerate
import AVFoundation
import Combine
import Foundation
import SwiftUI
import os

enum SignalGateSettings {
    static let defaultsKey = "minimumSignalRMS"
    static let defaultMinimumRMS = 0.015
    static let minimumDBFS = -60.0
    static let maximumDBFS = -20.0

    static func decibels(forRMS rms: Double) -> Double {
        20 * log10(max(rms, 0.000_000_000_001))
    }

    static func rms(forDecibels decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    static var storedMinimumRMS: Double {
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return stored > 0 ? stored : defaultMinimumRMS
    }
}
@MainActor
final class SignalLevelMonitor: ObservableObject {
    static let shared = SignalLevelMonitor()
    @Published private(set) var rms = 0.0
    private var lastPublication = 0.0

    nonisolated static func publish(rms: Double) {
        DispatchQueue.main.async {
            let monitor = SignalLevelMonitor.shared
            let now = ProcessInfo.processInfo.systemUptime
            guard now - monitor.lastPublication >= 0.08 else { return }
            monitor.lastPublication = now
            monitor.rms = max(0, rms)
        }
    }

    nonisolated static func reset() {
        DispatchQueue.main.async {
            let monitor = SignalLevelMonitor.shared
            monitor.rms = 0
            monitor.lastPublication = ProcessInfo.processInfo.systemUptime
        }
    }
}

struct SignalLevelMeter: View {
    let levelDBFS: Double
    let thresholdDBFS: Double

    var body: some View {
        GeometryReader { geometry in
            let range = SignalGateSettings.maximumDBFS - SignalGateSettings.minimumDBFS
            let level = min(1, max(0, (levelDBFS - SignalGateSettings.minimumDBFS) / range))
            let threshold = min(1, max(0, (thresholdDBFS - SignalGateSettings.minimumDBFS) / range))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(levelDBFS >= thresholdDBFS ? Color.green : Color.orange)
                    .frame(width: geometry.size.width * level)
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * threshold - 1)
            }
        }
        .frame(height: 12)
        .accessibilityLabel("Güncel ses seviyesi")
        .accessibilityValue(String(format: "%.1f dBFS, eşik %.1f dBFS", levelDBFS, thresholdDBFS))
    }
}

struct SignalGateControls: View {
    @AppStorage(SignalGateSettings.defaultsKey) private var minimumSignalRMS =
        SignalGateSettings.defaultMinimumRMS
    @ObservedObject private var signalLevel = SignalLevelMonitor.shared

    private var thresholdDBFS: Binding<Double> {
        Binding(
            get: { SignalGateSettings.decibels(forRMS: minimumSignalRMS) },
            set: { minimumSignalRMS = SignalGateSettings.rms(forDecibels: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Minimum işleme seviyesi")
                Spacer()
                Text(String(format: "%.1f dBFS", thresholdDBFS.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: thresholdDBFS,
                in: SignalGateSettings.minimumDBFS...SignalGateSettings.maximumDBFS,
                step: 0.5
            )
            SignalLevelMeter(
                levelDBFS: SignalGateSettings.decibels(forRMS: signalLevel.rms),
                thresholdDBFS: thresholdDBFS.wrappedValue
            )
            HStack {
                Text("−60 dBFS")
                Spacer()
                Text(signalLevel.rms > 0
                    ? String(format: "Güncel: %.1f dBFS", SignalGateSettings.decibels(forRMS: signalLevel.rms))
                    : "Çalma modu bekleniyor")
                Spacer()
                Text("−20 dBFS")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Çubuğun eşik çizgisinin altında kaldığı kareler işlenmez ve grafikte boş bırakılır.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @AppStorage(PitchEngineSettings.studyEngineKey) private var studyEngine = PitchEngineSettings.initialEngine
    @AppStorage(PitchEngineSettings.liveEngineKey) private var liveEngine = PitchEngineSettings.initialEngine
    @AppStorage(PitchEngineSettings.togetherEngineKey) private var togetherEngine = PitchEngineSettings.initialEngine
    @AppStorage(AppTheme.storageKey) private var themeName = AppTheme.focus.rawValue
    @State private var graphAppearance = GraphAppearance.stored()

    var body: some View {
        Form {
            Section("Görünüm") {
                Picker("Uygulama teması", selection: $themeName) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                Text("Tema ana pencere, Dinleme, Çalma ve ayarlar için birlikte uygulanır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Çalma Ayarları") {
                Picker("Varsayılan Çalma Hızı", selection: .constant(1.0)) {
                    Text("0,50×").tag(0.5)
                    Text("0,75×").tag(0.75)
                    Text("1,00×").tag(1.0)
                }
            }
            Section("Pitch Motoru") {
                // No picker: since D-039 there is one engine, and a control
                // with a single option reads as a choice that is not one.
                // The three stored keys (study/live/together) are still read
                // by the analysis paths and still resolve through
                // PitchEngineSettings, so an install holding a removed
                // engine's id falls back cleanly.
                LabeledContent("Çözümleme motoru", value: PitchEngineSettings.userChoices[0].title)
                    .accessibilityHint(AccessibilityText.engineDescription)
                Text("Dinleme, Çalma ve Birlikte Çal aynı motoru kullanır. Daha önce başka bir motorla çözümlenmiş çalışmalar kendi sonuçlarını korur; yeniden çözümlenirse bu motorla çözümlenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Grafik Renkleri") {
                HStack {
                    Text("Pitch eğrisi")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { GraphAppearance.color(hex: graphAppearance.pitchHex) },
                        set: { color in
                            if let hex = GraphAppearance.hex(from: color) {
                                graphAppearance.pitchHex = hex
                            }
                        }
                    ))
                    .frame(width: 60)
                }
                HStack {
                    Text("Not rehberi")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { GraphAppearance.color(hex: graphAppearance.noteGuideHex) },
                        set: { color in
                            if let hex = GraphAppearance.hex(from: color) {
                                graphAppearance.noteGuideHex = hex
                            }
                        }
                    ))
                    .frame(width: 60)
                }
                HStack {
                    Text("Mikrofon eğrisi")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { GraphAppearance.color(hex: graphAppearance.micHex) },
                        set: { color in
                            if let hex = GraphAppearance.hex(from: color) {
                                graphAppearance.micHex = hex
                            }
                        }
                    ))
                    .frame(width: 60)
                }
                Text("Bu renkler hem Dinleme hem Birlikte Çal grafiğinde kullanılır. Mikrofon eğrisi, çalınan dosyanın eğrisinden ayırt edilebilsin diye ayrı bir renk taşır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            studyEngine = PitchEngineSettings.resolvedSelection(studyEngine)
            liveEngine = PitchEngineSettings.resolvedSelection(liveEngine)
            togetherEngine = PitchEngineSettings.resolvedSelection(togetherEngine)
        }
        .onChange(of: graphAppearance) { _, newValue in
            newValue.save()
        }
    }
}

private struct LiveSignalSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Çalma Modu Ayarları", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button("Bitti") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                Section("Sinyal Kapısı") {
                    SignalGateControls()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 300)
    }
}

// MARK: - Canlı çalışma

struct LivePitchFrame: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let frequency: Double
    let confidence: Double
}

enum LivePitchErrorSeverity: CaseIterable, Hashable {
    case falseVoiced
    case missingVoiced
    case correctPitch
    case nearPitch
    case harmonicError
    case nonHarmonicError

    static func voicedClassification(_ signedCents: Double) -> Self {
        if abs(signedCents) <= 50.0 + 1e-9 { return .correctPitch }
        if abs(signedCents) <= 100.0 + 1e-9 { return .nearPitch }
        let harmonicTargets = [
            1_200 * log2(1.0 / 3.0),
            -1_200.0,
            1_200.0,
            1_200 * log2(3.0),
        ]
        return harmonicTargets.contains { abs(signedCents - $0) <= 90 }
            ? .harmonicError
            : .nonHarmonicError
    }

    var reportKey: String {
        switch self {
        case .falseVoiced: return "false_voiced"
        case .missingVoiced: return "missing_voiced"
        case .correctPitch: return "correct_pitch"
        case .nearPitch: return "near_pitch"
        case .harmonicError: return "harmonic_error"
        case .nonHarmonicError: return "non_harmonic_error"
        }
    }
}

struct LivePitchErrorRange {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let peakCents: Double
    let explicitSeverity: LivePitchErrorSeverity?

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        peakCents: Double,
        explicitSeverity: LivePitchErrorSeverity? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.peakCents = peakCents
        self.explicitSeverity = explicitSeverity
    }

    var severity: LivePitchErrorSeverity {
        explicitSeverity ?? .nonHarmonicError
    }
}

struct LivePitchErrorPoint {
    let time: TimeInterval
    let frequency: Double
    let severity: LivePitchErrorSeverity
    let isSerious: Bool

    init(time: TimeInterval, frequency: Double, severity: LivePitchErrorSeverity, isSerious: Bool = true) {
        self.time = time
        self.frequency = frequency
        self.severity = severity
        self.isSerious = isSerious
    }
}


enum LiveAnalysisResolution: String, CaseIterable, Identifiable {
    case balanced
    case detailed
    case precision
    case vibrato

    var id: String { rawValue }
    var title: String {
        switch self {
        case .balanced: return "Akıcı"
        case .detailed: return "Dengeli"
        case .precision: return "Sabit nota"
        case .vibrato: return "Hızlı vibrato"
        }
    }

    /// Analysis window controls pitch precision; hop controls how frequently
    /// the chart receives a new point.  The detailed default was selected
    /// against the fixed-grid VPM real-clarinet reference.
    var windowSize: Int {
        switch self {
        case .balanced: return 2_048
        case .detailed: return 2_048
        case .precision: return 8_192
        // A 32 ms window preserves low clarinet notes while reducing the
        // time-averaging that narrows 7.5–13 Hz vibrato in the normal mode.
        case .vibrato: return 1_536
        }
    }

    var hopSize: Int {
        switch self {
        case .balanced: return 1_024
        case .detailed, .precision: return 512
        case .vibrato: return 512
        }
    }
}

/// One case since D-039. The type is kept rather than folded away because
/// every live/study path, the report identifier and the C ABI call still take
/// an engine, and the four removed cases were removed from here first -- the
/// compiler then found each place that had been switching on them.
enum LivePitchEngine: String, CaseIterable, Identifiable {
    case unified

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unified: return "Birleşik (Unified v1)"
        }
    }

    var reportIdentifier: String {
        switch self {
        case .unified: return "unified_v1"
        }
    }

    /// A stored id naming a removed engine cannot be honoured, so it resolves
    /// here the same way PitchEngineSettings resolves it: to the engine this
    /// build has.
    static var storedUserSelection: LivePitchEngine { .unified }

    /// "Birlikte Çal" motoru `togetherEngineKey`'de ayrı saklanır; Dinleme
    /// (`liveEngineKey`) veya Çalma (`studyEngineKey`) seçimlerinden bağımsız.
    /// Bu ayrım, ileride yeniden birden çok motor olursa diye korunuyor.
    static var togetherModeSelection: LivePitchEngine { .unified }
}


// Empirically calibrated timestamp convention difference between the offline
// pYIN reader and KlariVision's centred real-time analysis window.
// This is only the initial display position. Direct-source validation finds
// the actual offset automatically from the two traces before it scores them.
let referencePYINTimeOffset = 0.0

final class LivePitchAnalyzer: ObservableObject, @unchecked Sendable {
    @Published private(set) var frames: [LivePitchFrame] = []
    @Published private(set) var currentFrequency: Double?
    @Published private(set) var currentConfidence = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isBenchmarkRunning = false
    @Published private(set) var status = "Mikrofonu başlatmaya hazır."
    @Published private(set) var resolution: LiveAnalysisResolution = .vibrato
    @Published private(set) var pitchEngine: LivePitchEngine = .unified
    @Published private(set) var referenceTestSourceName: String?
    @Published private(set) var referenceOfflineFrames: [LivePitchFrame] = []
    // Exact analytic target grid, including explicit silence, used by the
    // five-way direct-source validation report.
    private var analyticReferenceTruth: [(time: Double, frequency: Double?)] = []
    private var analyticReferenceOriginalTruth: [(time: Double, frequency: Double?)] = []
    private var analyticReferenceTransitions: [Double] = []
    private var analyticReferenceSamples: [Float] = []
    private var analyticReferenceSampleRate = 0.0
    private var signalThresholdHistory: [(sourceTime: Double, minimumRMS: Double)] = []
    @Published private(set) var referenceAnalysisMessage: String?
    @Published private(set) var referenceValidationSummary: String?
    @Published private(set) var referenceValidationDetails: String?
    @Published private(set) var referenceValidationReportURL: URL?
    @Published private(set) var referenceErrorRanges: [LivePitchErrorRange] = []
    @Published private(set) var referenceErrorPoints: [LivePitchErrorPoint] = []
    @Published private(set) var referenceTimeOffset = referencePYINTimeOffset
    @Published private(set) var referenceIsAnalytic = false
    // Kept visible during the live-engine calibration work.  The important
    // measurement is accepted points per second, not only pitch accuracy.
    @Published private(set) var livePointsPerSecond = 0.0
    @Published private(set) var liveComputeMilliseconds = 0.0
    @Published private(set) var liveDroppedEstimates = 0

    var hasCapturedFrames: Bool { !frames.isEmpty }
    var hasReferenceSource: Bool { referenceTestSourceURL != nil }
    var hasReferenceErrors: Bool { !referenceErrorRanges.isEmpty || !referenceErrorPoints.isEmpty }
    var referenceCurveTitle: String {
        referenceIsAnalytic ? "Matematiksel hedef" : "Kaynak pYIN"
    }
    /// A reference test has a meaningful musical timebase: the position in
    /// the file being played.  Normal microphone practice intentionally uses
    /// wall-clock time instead.
    var isReferenceTestRunning: Bool {
        referenceTestStartedAt != nil && (referencePlayer != nil || isBenchmarkRunning)
    }

    func graphTime(for wallClockTime: TimeInterval) -> TimeInterval {
        guard let startedAt = referenceTestStartedAt ?? practiceStartedAt else { return 0 }
        return max(0, wallClockTime - startedAt)
    }

    func graphNow(_ wallClockTime: TimeInterval) -> TimeInterval {
        referenceTimelineEnd ?? practiceTimelineEnd ?? graphTime(for: wallClockTime)
    }

    // Deterministic file/trace tests do not need Core Audio. Live capture
    // creates the engine on first microphone use.
    private var engine: AVAudioEngine?
    private let recordingLock = NSLock()
    private var recordingFile: AVAudioFile?
    private var recordingTemporaryURL: URL?
    private var recordingStartPending = false
    private let processingQueue = DispatchQueue(label: "com.aykerme.KlariVision.livePitch", qos: .userInitiated)
    private let benchmarkQueue = DispatchQueue(label: "com.aykerme.KlariVision.livePitch.benchmark", qos: .userInitiated)
    private let historyDuration: TimeInterval = 60
    // Audio hardware can deliver 4,096-frame callback blocks even when a
    // smaller tap size is requested. Split those blocks into hop-sized chunks
    // so one callback does not incorrectly become only one pitch point.
    private let liveInputLock = NSLock()
    private var liveCaptureWindow: [Float] = []
    // The visible low-latency estimator remains on its 1,536-sample window.
    // A longer causal history is consulted only when that short window sees
    // competing octave candidates; it adds no future look-ahead or UI delay.
    private let causalDecisionWindowSize = 4_096
    private var liveDecisionHistory: [Float] = []
    private var liveInputRemainder: [Float] = []
    private var liveRemainderStartTime: TimeInterval?
    // Two high-pass stages remove desk/room rumble introduced by the
    // speaker → microphone path.
    private var liveHighPass1PreviousInput: Float = 0
    private var liveHighPass1PreviousOutput: Float = 0
    private var liveHighPass2PreviousInput: Float = 0
    private var liveHighPass2PreviousOutput: Float = 0
    private var liveCaptureResolution: LiveAnalysisResolution = .vibrato
    private var liveQueuedAnalysisCount = 0
    private let maximumQueuedLiveAnalyses = 12
    private var liveRunID = UUID()
    private var liveMeasurementStartedAt: TimeInterval?
    private var liveMeasurementPublishedAt: TimeInterval = 0
    private var liveMeasurementCount = 0
    private var liveMeasurementTotalMilliseconds = 0.0
    private var liveDroppedEstimateCount = 0
    private var sampleWindow: [Float] = []
    private var sampleDecisionHistory: [Float] = []
    private var samplesSinceLastEstimate = 0
    private var processingResolution: LiveAnalysisResolution = .vibrato
    private var processingPitchEngine: LivePitchEngine = .unified
    private var minimumSignalRMS = SignalGateSettings.storedMinimumRMS
    private var signalSettingsObservation: AnyCancellable?
    private var currentFrameSignalEligible = true
    // Causal counterpart of pYIN's continuity decision.  Unlike offline
    // Viterbi, it deliberately retains no future frames, so microphone
    // practice remains immediate.
    // Source-time points withheld during a very short input dropout. They are
    // published only after the same raw YIN contour returns, so a release or
    // a new note never paints the intervening silence as voiced.
    // Replays of a reference sound must begin independently. Short note gaps
    // keep musical continuity; a longer silence clears it.
    #if !KLARIVISION_SWIFT_PACKAGE
    private var productionCoreSession: OpaquePointer?
    #endif
    private var productionCorePublishedFrames: [LivePitchFrame] = []
    // AVPlayer accepts the same broad audio/video formats as the rest of the
    // app. AVAudioPlayer silently refuses some M4A/container combinations.
    private var referencePlayer: AVPlayer?
    private var referenceTestSourceURL: URL?
    private var referenceTestStartedAt: TimeInterval?
    private var referenceTimelineEnd: TimeInterval?
    // Normal microphone practice has no media-file clock. Keep a local
    // session origin so the graph is always labelled 0, 1, 2… seconds rather
    // than with Apple's absolute reference-date seconds.
    private var practiceStartedAt: TimeInterval?
    private var practiceTimelineEnd: TimeInterval?
    private var referenceItemStatusObservation: NSKeyValueObservation?
    private var referenceAnalysisID = UUID()
    private var benchmarkTimer: DispatchSourceTimer?
    private var benchmarkRunID: UUID?

    init() {
        let selected = LivePitchEngine.storedUserSelection
        pitchEngine = selected
        processingPitchEngine = selected
        #if !KLARIVISION_SWIFT_PACKAGE
        productionCoreSession = kv_production_pitch_session_create(
            Self.coreEngineID(for: selected), minimumSignalRMS
        )
        #endif
        signalSettingsObservation = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        ).sink { [weak self] _ in
            guard let self else { return }
            let updated = SignalGateSettings.storedMinimumRMS
            self.processingQueue.async { [weak self] in
                self?.minimumSignalRMS = updated
                #if !KLARIVISION_SWIFT_PACKAGE
                if let session = self?.productionCoreSession {
                    _ = kv_production_pitch_session_set_minimum_rms(session, updated)
                }
                #endif
            }
            DispatchQueue.main.async { [weak self] in
                self?.recordSignalThresholdChange(updated)
            }
        }
    }

    deinit {
        benchmarkTimer?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        discardRecording()
        #if !KLARIVISION_SWIFT_PACKAGE
        kv_production_pitch_session_destroy(productionCoreSession)
        #endif
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            prepareAndStartOrdinaryPractice()
        }
    }

    func toggleRecording() {
        if isRecording {
            finishRecordingAndPresentSavePanel()
            return
        }
        if isRunning, let engine {
            beginRecording(format: engine.inputNode.outputFormat(forBus: 0))
        } else {
            recordingStartPending = true
            prepareAndStartOrdinaryPractice()
        }
    }

    private func prepareAndStartOrdinaryPractice() {
        // Settings are applied only at a session boundary, so tracker state
        // can never leak between different C++ engine profiles.
        selectPitchEngineSynchronously(.storedUserSelection)
        // Ordinary microphone practice should use wall-clock time rather than
        // the frozen timeline of a previous source test.
        referenceTestStartedAt = nil
        referenceTimelineEnd = nil
        referenceOfflineFrames.removeAll(keepingCapacity: true)
        referenceIsAnalytic = false
        referenceErrorRanges.removeAll(keepingCapacity: true)
        referenceErrorPoints.removeAll(keepingCapacity: true)
        requestAndStart()
    }

    /// "Birlikte Çal" girişi (bkz. StudyWorkspace.swift → TogetherSession).
    /// Adi mikrofon pratiğinden tek farkı motor seçiminin `liveEngineKey`
    /// değil `togetherEngineKey`'den okunmasıdır. Kasıtlı olarak
    /// `playbackURL` geçirmez: "Kaynakla Test" akışı burada istenmiyor.
    func startForTogetherMode() {
        selectPitchEngineSynchronously(.togetherModeSelection)
        referenceTestStartedAt = nil
        referenceTimelineEnd = nil
        referenceOfflineFrames.removeAll(keepingCapacity: true)
        referenceIsAnalytic = false
        referenceErrorRanges.removeAll(keepingCapacity: true)
        referenceErrorPoints.removeAll(keepingCapacity: true)
        requestAndStart()
    }

    /// Plays a local audio file through the selected output while listening to
    /// the microphone. Only derived pitch points remain in the graph; the
    /// microphone signal itself is never written to disk.
    func startReferenceTest(with url: URL) {
        stop()
        frames.removeAll(keepingCapacity: true)
        currentFrequency = nil
        currentConfidence = 0
        referenceTestSourceName = url.deletingPathExtension().lastPathComponent
        referenceTestSourceURL = url
        referenceTimeOffset = referencePYINTimeOffset
        referenceTestStartedAt = nil
        referenceTimelineEnd = nil
        referenceOfflineFrames.removeAll(keepingCapacity: true)
        referenceIsAnalytic = false
        referenceValidationSummary = nil
        referenceValidationDetails = nil
        referenceValidationReportURL = nil
        referenceErrorRanges.removeAll(keepingCapacity: true)
        referenceErrorPoints.removeAll(keepingCapacity: true)
        referenceAnalysisMessage = "Kaynak çalıyor; karşılaştırma eğrisini testten sonra hazırlayabilirsin."
        // Generated validation recordings can display their exact expected
        // curve immediately, including during speaker → microphone tests.
        // Generic recordings continue to prepare their pYIN overlay.
        prepareReferenceOverlay()
        requestAndStart(playbackURL: url)
    }

    func prepareReferenceOverlay() {
        guard let source = referenceTestSourceURL else {
            referenceAnalysisMessage = "Önce Kaynakla Test ile bir ses veya video seç."
            return
        }
        let analysisID = UUID()
        referenceAnalysisID = analysisID
        referenceOfflineFrames.removeAll(keepingCapacity: true)
        analyticReferenceTruth.removeAll(keepingCapacity: true)
        analyticReferenceOriginalTruth.removeAll(keepingCapacity: true)
        analyticReferenceTransitions.removeAll(keepingCapacity: true)
        analyticReferenceSamples.removeAll(keepingCapacity: true)
        analyticReferenceSampleRate = 0
        signalThresholdHistory.removeAll(keepingCapacity: true)
        referenceIsAnalytic = false
        // A generated validation recording has an exact mathematical pitch
        // trace.  Prefer that trace over pYIN: an estimator must never be
        // treated as ground truth when the expected frequency is already
        // known.  Generic user recordings still fall back to pYIN below.
        if let expected = analyticReferenceFrames(for: source) {
            referenceOfflineFrames = expected
            referenceIsAnalytic = true
            referenceTimeOffset = 0
            referenceAnalysisMessage = "Matematiksel hedef eklendi · ölçüm: mavi · hedef: koyu"
            referenceValidationSummary = "Canlı motor matematiksel hedef eğriyle karşılaştırılıyor."
            referenceValidationDetails = nil
            referenceValidationReportURL = nil
            return
        }
        referenceAnalysisMessage = "Kaynak pYIN eğrisi hazırlanıyor…"
        prepareOfflineReference(for: source, analysisID: analysisID)
    }

    private struct AnalyticReferencePayload: Decodable {
        struct Point: Decodable {
            let time_seconds: Double
            let frequency_hz: Double?
        }
        struct Section: Decodable {
            let start_seconds: Double
            let end_seconds: Double
        }
        let ground_truth: [Point]
        let sections: [Section]?
    }

    /// Loads the exact 10 ms target curve shipped beside every synthetic
    /// tournament recording. The stress suite is deliberately harsh, but its
    /// mathematical pitch function remains the only valid correctness target.
    private func analyticReferenceFrames(for source: URL) -> [LivePitchFrame]? {
        let name = source.deletingPathExtension().lastPathComponent
        let manifestName: String
        switch name {
        case let value where value.hasPrefix("klarivision_validated_clarinet_"):
            manifestName = "klarivision_validated_clarinet_ground_truth_v1.json"
        case let value where value.hasPrefix("klarivision_stress_"):
            manifestName = "klarivision_stress_ground_truth_v2.json"
        case let value where value.hasPrefix("klarivision_pitch_tournament_holdout_"):
            // The file name is part of the frozen-fixture contract. Loading
            // v1 truth for a v3/v4 WAV makes every engine appear catastrophically
            // wrong even when its trace is correct, because the families begin
            // at different anchors.
            if value.hasSuffix("_v4") {
                manifestName = "klarivision_pitch_tournament_holdout_ground_truth_v4.json"
            } else if value.hasSuffix("_v3") {
                manifestName = "klarivision_pitch_tournament_holdout_ground_truth_v3.json"
            } else if value.hasSuffix("_v2") {
                manifestName = "klarivision_pitch_tournament_holdout_ground_truth_v2.json"
            } else {
                manifestName = "klarivision_pitch_tournament_holdout_ground_truth_v1.json"
            }
        default:
            return nil
        }
        let manifest = source.deletingLastPathComponent().appending(path: manifestName)
        guard let data = try? Data(contentsOf: manifest),
              let payload = try? JSONDecoder().decode(AnalyticReferencePayload.self, from: data) else {
            referenceAnalysisMessage = "Beklenen eğri dosyası bulunamadı; pYIN kullanılacak."
            return nil
        }
        analyticReferenceOriginalTruth = payload.ground_truth.map { ($0.time_seconds, $0.frequency_hz) }
        analyticReferenceTransitions = (payload.sections ?? []).flatMap { [$0.start_seconds, $0.end_seconds] }
        loadAnalyticReferenceSignal(from: source)
        signalThresholdHistory = [(0, minimumSignalRMS)]
        rebuildEffectiveAnalyticReference()
        return analyticReferenceTruth.compactMap { point in
            guard let frequency = point.frequency, frequency > 0 else { return nil }
            return LivePitchFrame(time: point.time, frequency: frequency, confidence: 1)
        }
    }

    private func loadAnalyticReferenceSignal(from source: URL) {
        guard let file = try? AVAudioFile(forReading: source),
              file.length > 0 else { return }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ), (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?.pointee else { return }
        analyticReferenceSamples = Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
        analyticReferenceSampleRate = file.processingFormat.sampleRate
    }

    private func rebuildEffectiveAnalyticReference() {
        guard !analyticReferenceOriginalTruth.isEmpty else { return }
        let window = resolution.windowSize
        let half = window / 2
        let history = signalThresholdHistory.sorted { $0.sourceTime < $1.sourceTime }
        analyticReferenceTruth = analyticReferenceOriginalTruth.map { point in
            guard let frequency = point.frequency, frequency > 0,
                  analyticReferenceSampleRate > 0,
                  !analyticReferenceSamples.isEmpty else { return point }
            let threshold = history.last(where: { $0.sourceTime <= point.time })?.minimumRMS
                ?? minimumSignalRMS
            let centre = Int((point.time * analyticReferenceSampleRate).rounded())
            let start = max(0, centre - half)
            let finish = min(analyticReferenceSamples.count, start + window)
            let rms = Self.centeredRMS(Array(analyticReferenceSamples[start..<finish]))
            return (point.time, rms < threshold ? nil : frequency)
        }
        referenceOfflineFrames = analyticReferenceTruth.compactMap { point in
            guard let frequency = point.frequency, frequency > 0 else { return nil }
            return LivePitchFrame(time: point.time, frequency: frequency, confidence: 1)
        }
    }

    private func recordSignalThresholdChange(_ minimumRMS: Double) {
        guard referenceIsAnalytic,
              signalThresholdHistory.last?.minimumRMS != minimumRMS else { return }
        let sourceTime: Double
        if let playerTime = referencePlayer?.currentTime().seconds, playerTime.isFinite {
            sourceTime = max(0, playerTime)
        } else if let origin = referenceTestStartedAt, let lastFrame = frames.last {
            sourceTime = max(0, lastFrame.time - origin)
        } else {
            sourceTime = max(0, referenceTimelineEnd ?? 0)
        }
        signalThresholdHistory.append((sourceTime, minimumRMS))
        rebuildEffectiveAnalyticReference()
    }

    private struct OfflinePitchPayload: Decodable {
        struct Frame: Decodable {
            let time_seconds: Double
            let frequency_hz: Double
            let confidence: Double?
        }
        let frames: [Frame]
    }

    /// Uses the exact offline pYIN pipeline already used by a normal study.
    /// The result is visual verification only; it does not affect the live
    /// microphone estimator or retain microphone audio.
    private func prepareOfflineReference(for source: URL, analysisID: UUID) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let output: String?
            let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents/KlariVision")

            if let engine = Self.bundledEngineExecutable() {
                let process = Process()
                process.executableURL = engine
                process.arguments = [source.path, "--makam", "huzzam", "--karar", "dugah", "--engine", "vamp"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    output = process.terminationStatus == 0
                        ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        : nil
                } catch { output = nil }
            } else {
                let python = root.appending(path: ".venv/bin/python")
                guard FileManager.default.isExecutableFile(atPath: python.path) else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.referenceAnalysisID == analysisID else { return }
                        self.referenceAnalysisMessage = "Kaynak pYIN eğrisi bu çalışma ortamında hazırlanamadı."
                    }
                    return
                }
                let escapedPath = source.path.replacingOccurrences(of: "\"", with: "\\\\\"")
                let script = "from pathlib import Path; from klarivision.local_app import analyse_upload; print(analyse_upload(Path(\"\(escapedPath)\"), \"huzzam\", \"dugah\", \"vamp\"))"
                let process = Process()
                process.executableURL = python
                process.arguments = ["-c", script]
                process.currentDirectoryURL = root
                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONPATH"] = root.appending(path: "src").path
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    output = process.terminationStatus == 0
                        ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        : nil
                } catch { output = nil }
            }

            guard let output,
                  let relativeViewer = output.split(whereSeparator: \.isNewline).last else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.referenceAnalysisID == analysisID else { return }
                    self.referenceAnalysisMessage = "Kaynak pYIN eğrisi hazırlanamadı."
                }
                return
            }
            let viewerString = String(relativeViewer).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let viewer = viewerString.hasPrefix("/")
                ? URL(fileURLWithPath: viewerString)
                : root.appending(path: viewerString)
            let pitchFile = viewer.deletingPathExtension().appendingPathExtension("vamp.json")
            guard let data = try? Data(contentsOf: pitchFile),
                  let payload = try? JSONDecoder().decode(OfflinePitchPayload.self, from: data) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.referenceAnalysisID == analysisID else { return }
                    self.referenceAnalysisMessage = "Kaynak pYIN verisi okunamadı."
                }
                return
            }
            let frames = payload.frames.map {
                LivePitchFrame(time: $0.time_seconds, frequency: $0.frequency_hz, confidence: $0.confidence ?? 0.95)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.referenceAnalysisID == analysisID else { return }
                self.referenceOfflineFrames = frames
                self.calibrateReferenceTimeOffsetIfPossible()
                self.referenceAnalysisMessage = "Kaynak pYIN eğrisi eklendi · canlı: mavi · kaynak: koyu"
                self.updateReferenceValidationReport()
            }
        }
    }

    private static func bundledEngineExecutable() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let executable = resources.appending(path: "Engine/KlariVisionEngine")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    /// Exports only derived time/frequency/confidence points. The microphone
    /// waveform is never retained or exported.
    func referenceCaptureData() -> Data? {
        guard let first = frames.first else { return nil }
        let origin = referenceTestStartedAt ?? first.time
        let rows: [[String: Any]] = frames.map { frame in
            [
                "time_seconds": round((frame.time - origin) * 1_000) / 1_000,
                "frequency_hz": round(frame.frequency * 100) / 100,
                "confidence": round(frame.confidence * 1_000) / 1_000,
            ]
        }
        let payload: [String: Any] = [
            "schema": "klarivision-live-reference-v1",
            "source_name": referenceTestSourceName ?? "microphone",
            "frames": rows,
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    func stop() {
        stopBenchmarkIfNeeded()
        // Drain V2's real fixed-lag suffix before invalidating queued capture
        // work.  The C++ session is terminal after this call and the next
        // start/reset creates a fresh one.
        #if !KLARIVISION_SWIFT_PACKAGE
        let finalProductionFrames = processingQueue.sync { [weak self] in
            self?.finishProductionPitchCore() ?? []
        }
        for frame in finalProductionFrames {
            append((frame.frequency, frame.confidence), capturedAt: frame.time)
        }
        #endif
        invalidateLiveCapture()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if isRecording {
            finishRecordingAndPresentSavePanel()
        } else {
            recordingStartPending = false
        }
        // AVAudioEngine can retain a completed input render cycle after a
        // stop. Resetting it here is essential when a user runs several
        // successive source-reference tests in the same app session.
        engine?.reset()
        referenceItemStatusObservation?.invalidate()
        referenceItemStatusObservation = nil
        referencePlayer?.pause()
        referencePlayer = nil
        if let startedAt = referenceTestStartedAt,
           let last = frames.last {
            referenceTimelineEnd = max(0, last.time - startedAt)
            // Speaker, output device and microphone buffering add a
            // run-specific delay. Recalculate it after the capture instead
            // of leaving the exact target curve at the zero-offset default.
            calibrateReferenceTimeOffsetIfPossible()
            updateReferenceValidationReport()
        }
        if let startedAt = practiceStartedAt,
           let last = frames.last {
            practiceTimelineEnd = max(0, last.time - startedAt)
        }
        isRunning = false
        currentFrequency = nil
        currentConfidence = 0
        SignalLevelMonitor.reset()
        status = "Mikrofon durduruldu."
    }

    private func beginRecording(format: AVAudioFormat) {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            recordingStartPending = false
            status = "Kayıt başlatılamadı: Geçerli bir mikrofon biçimi bulunamadı."
            return
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "KlariVision-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        do {
            let file = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            recordingLock.lock()
            recordingFile = file
            recordingTemporaryURL = temporaryURL
            recordingLock.unlock()
            recordingStartPending = false
            isRecording = true
            status = "Mikrofon dinleniyor. Kayıt yapılıyor."
        } catch {
            recordingStartPending = false
            try? FileManager.default.removeItem(at: temporaryURL)
            status = "Kayıt başlatılamadı: \(error.localizedDescription)"
        }
    }

    private func appendRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recordingFile else { return }
        do {
            try recordingFile.write(from: buffer)
        } catch {
            self.recordingFile = nil
            let temporaryURL = recordingTemporaryURL
            recordingTemporaryURL = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRecording = false
                self.status = "Kayıt sırasında hata oluştu: \(error.localizedDescription)"
                if let temporaryURL {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }
        }
    }

    private func finishRecordingAndPresentSavePanel() {
        recordingLock.lock()
        recordingFile = nil
        let temporaryURL = recordingTemporaryURL
        recordingTemporaryURL = nil
        recordingLock.unlock()
        recordingStartPending = false
        isRecording = false
        guard let temporaryURL else { return }

        if isRunning {
            status = "Mikrofon dinleniyor. Ses kaydedilmiyor."
        }
        Task { @MainActor in
            Self.presentRecordingSavePanel(for: temporaryURL)
        }
    }

    @MainActor
    private static func presentRecordingSavePanel(for temporaryURL: URL) {
        let panel = NSSavePanel()
        panel.title = "Kaydı Sakla"
        panel.prompt = "Kaydet"
        panel.nameFieldStringValue = defaultRecordingFilename()
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Kayıt kaydedilemedi"
                alert.runModal()
            }
        }
    }

    private func discardRecording() {
        recordingLock.lock()
        recordingFile = nil
        let temporaryURL = recordingTemporaryURL
        recordingTemporaryURL = nil
        recordingLock.unlock()
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    private static func defaultRecordingFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "KlariVision Kayıt \(formatter.string(from: now)).wav"
    }

    func runBenchmark() {
        startBenchmark()
    }

    /// Runs the live engine on the selected source file's PCM directly. This
    /// removes speaker, room and microphone differences, leaving a clean
    /// comparison against analytic truth when present, otherwise pYIN.
    func runSourceBenchmark() {
        guard let source = referenceTestSourceURL else {
            status = "Önce Kaynakla Test ile karşılaştırılacak dosyayı seç."
            return
        }
        startBenchmark(sourceURL: source)
    }

    /// Development verification path: the selected file is fed directly to
    /// the real-time engine while the exact same source is compared with its
    /// analytic truth when available, otherwise offline pYIN. There is no
    /// speaker, room, or microphone in this path.
    /// It is intentionally separate from normal live practice so it cannot
    /// change what a musician sees in day-to-day use.
    func validateSourceDirectly(with url: URL, engine: LivePitchEngine = .unified) {
        stop()
        selectPitchEngineSynchronously(engine)
        frames.removeAll(keepingCapacity: true)
        currentFrequency = nil
        currentConfidence = 0
        referenceTestSourceName = url.deletingPathExtension().lastPathComponent
        referenceTestSourceURL = url
        referenceTimeOffset = referencePYINTimeOffset
        referenceTestStartedAt = nil
        referenceTimelineEnd = nil
        referenceOfflineFrames.removeAll(keepingCapacity: true)
        referenceIsAnalytic = false
        referenceValidationSummary = nil
        referenceValidationDetails = nil
        referenceValidationReportURL = nil
        referenceErrorRanges.removeAll(keepingCapacity: true)
        referenceErrorPoints.removeAll(keepingCapacity: true)
        referenceAnalysisMessage = "Kaynak referansı ve \(engine.title) aynı dosyada hazırlanıyor…"
        prepareReferenceOverlay()
        runSourceBenchmark()
    }

    /// Replays the last direct-source validation with a different engine.
    /// Selecting a live engine normally only affects the *next microphone*
    /// session, which was easy to mistake for a failed source-test selection
    /// after a completed graph remained on screen.
    func rerunSourceValidation(with engine: LivePitchEngine) {
        guard let source = referenceTestSourceURL else {
            status = "Önce dosyadan motor testi için bir kaynak seç."
            return
        }
        validateSourceDirectly(with: source, engine: engine)
    }


    private func startBenchmark(sourceURL: URL? = nil) {
        stop()

        guard let url = sourceURL ?? Bundle.main.url(forResource: "canli_pitch_referans_v1", withExtension: "wav") else {
            status = "Motor testi kaydı uygulama içinde bulunamadı."
            return
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                status = "Motor testi kaydı okunamadı."
                return
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?.pointee,
                  buffer.frameLength > 0 else {
                status = "Motor testi kaydında ses örneği bulunamadı."
                return
            }

            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else {
                status = "Motor testi kaydının örnekleme hızı geçersiz."
                return
            }

            frames.removeAll(keepingCapacity: true)
            currentFrequency = nil
            currentConfidence = 0
            if sourceURL != nil {
                referenceTestStartedAt = Date().timeIntervalSinceReferenceDate
                referenceTimelineEnd = nil
            }
            isRunning = true
            isBenchmarkRunning = true
            status = sourceURL == nil
                ? "Motor testi çalışıyor · Mikrofon kullanılmıyor."
                : "Seçilen dosya canlı motorla işleniyor · Mikrofon kullanılmıyor."

            processingQueue.async { [weak self] in
                self?.resetProcessingState()
            }

            let runID = UUID()
            benchmarkRunID = runID
            // A direct-file benchmark may briefly run behind real time while
            // pYIN and YIN are both preparing. Preserve the file's own clock
            // on every YIN point; using the wall-clock completion time here
            // was the cause of the visible multi-second blue/grey offset.
            let sourceTimeOrigin = sourceURL == nil
                ? nil
                : (referenceTestStartedAt ?? Date().timeIntervalSinceReferenceDate)
            let sourceWindowHalfDuration = Double(processingResolution.windowSize) / (2 * sampleRate)
            var offset = 0
            var didFinish = false
            let chunkSize = 512
            let interval = DispatchTimeInterval.nanoseconds(Int((Double(chunkSize) / sampleRate) * 1_000_000_000))
            let timer = DispatchSource.makeTimerSource(queue: benchmarkQueue)
            benchmarkTimer = timer
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard offset < samples.count else {
                    guard !didFinish else { return }
                    didFinish = true
                    self.finishBenchmark(runID: runID)
                    return
                }
                let end = min(offset + chunkSize, samples.count)
                let chunk = Array(samples[offset..<end])
                offset = end
                // Both pYIN and the live YIN inspect a centred analysis
                // window. Timestamp the centre, not the final sample in that
                // window, so the two traces agree at note attacks as well.
                let sourceFrameTime = sourceTimeOrigin.map {
                    $0 + max(0, Double(end) / sampleRate - sourceWindowHalfDuration)
                }
                self.processingQueue.async { [weak self] in
                    self?.process(samples: chunk, sampleRate: sampleRate, capturedAt: sourceFrameTime)
                }
            }
            timer.resume()
        } catch {
            status = "Motor testi başlatılamadı: \(error.localizedDescription)"
        }
    }

    func setResolution(_ value: LiveAnalysisResolution) {
        resolution = value
        if referenceIsAnalytic {
            rebuildEffectiveAnalyticReference()
        }
        liveInputLock.lock()
        liveCaptureResolution = value
        liveCaptureWindow.removeAll(keepingCapacity: true)
        liveInputRemainder.removeAll(keepingCapacity: true)
        liveRemainderStartTime = nil
        liveInputLock.unlock()
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.processingResolution = value
            self.resetProcessingState()
        }
    }

    func setPitchEngine(_ value: LivePitchEngine) {
        // A source benchmark has one coherent engine state from its first
        // PCM block to its last. Changing it mid-run resets the causal state
        // and can leave a graph that appears not to reflect either choice.
        guard !isRunning else { return }
        pitchEngine = value
        status = "(value.title) seçildi. Mikrofonu başlattığında bu motor kullanılacak."
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.processingPitchEngine = value
            self.resetProcessingState()
        }
    }

    private func selectPitchEngineSynchronously(_ value: LivePitchEngine) {
        pitchEngine = value
        processingQueue.sync { [weak self] in
            guard let self else { return }
            self.processingPitchEngine = value
            self.resetProcessingState()
        }
    }

    private func requestAndStart(playbackURL: URL? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // Keep the selected playback source on every later run. Previously
            // it was only forwarded through the first permission prompt, so
            // source tests played once and then silently started microphone
            // mode on subsequent attempts.
            start(playbackURL: playbackURL)
        case .notDetermined:
            status = "Mikrofon izni bekleniyor…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    allowed ? self.start(playbackURL: playbackURL) : self.setPermissionDeniedStatus()
                }
            }
        default:
            setPermissionDeniedStatus()
        }
    }

    private func setPermissionDeniedStatus() {
        recordingStartPending = false
        status = "Mikrofon izni verilmedi. Sistem Ayarları > Gizlilik ve Güvenlik > Mikrofon bölümünden KlariVision'a izin verebilirsin."
    }

    private func resetProcessingState() {
        sampleWindow.removeAll(keepingCapacity: true)
        sampleDecisionHistory.removeAll(keepingCapacity: true)
        samplesSinceLastEstimate = 0
        currentFrameSignalEligible = true
        productionCorePublishedFrames.removeAll(keepingCapacity: true)
        #if !KLARIVISION_SWIFT_PACKAGE
        kv_production_pitch_session_destroy(productionCoreSession)
        productionCoreSession = kv_production_pitch_session_create(
            Self.coreEngineID(for: processingPitchEngine), minimumSignalRMS
        )
        #endif
    }

    #if !KLARIVISION_SWIFT_PACKAGE
    private static func coreEngineID(for engine: LivePitchEngine) -> Int32 {
        switch engine {
        case .unified: return Int32(KV_ENGINE_UNIFIED_V1)
        }
    }
    #endif

    private func invalidateLiveCapture() {
        liveInputLock.lock()
        liveRunID = UUID()
        liveCaptureWindow.removeAll(keepingCapacity: true)
        liveDecisionHistory.removeAll(keepingCapacity: true)
        liveInputRemainder.removeAll(keepingCapacity: true)
        liveRemainderStartTime = nil
        liveHighPass1PreviousInput = 0
        liveHighPass1PreviousOutput = 0
        liveHighPass2PreviousInput = 0
        liveHighPass2PreviousOutput = 0
        liveQueuedAnalysisCount = 0
        liveInputLock.unlock()
    }

    private func currentLiveRun(_ runID: UUID) -> Bool {
        liveInputLock.lock()
        defer { liveInputLock.unlock() }
        return liveRunID == runID
    }

    private func stopBenchmarkIfNeeded() {
        benchmarkTimer?.cancel()
        benchmarkTimer = nil
        benchmarkRunID = nil
        isBenchmarkRunning = false
    }

    private func finishBenchmark(runID: UUID) {
        // The timer can finish feeding chunks before the final YIN windows
        // have left the serial processing queue. Wait for that queue so the
        // validation report always covers the complete source file.
        processingQueue.async { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.benchmarkRunID == runID else { return }
                self.stopBenchmarkIfNeeded()
                self.isRunning = false
                if let startedAt = self.referenceTestStartedAt,
                   let last = self.frames.last {
                    self.referenceTimelineEnd = max(0, last.time - startedAt)
                }
                if self.referenceIsAnalytic {
                    self.referenceTimeOffset = 0
                } else {
                    self.calibrateReferenceTimeOffsetIfPossible()
                }
                self.status = "Motor testi tamamlandı."
                self.updateReferenceValidationReport()
            }
        }
    }

    /// Finds the pYIN time shift that makes the two independently calculated
    /// curves agree best. It is deliberately a test-harness calibration: it
    /// never alters a live pitch value or the musician-facing graph.
    private func calibrateReferenceTimeOffsetIfPossible() {
        guard !referenceIsAnalytic,
              let origin = referenceTestStartedAt,
              frames.count >= 80,
              referenceOfflineFrames.count >= 80 else { return }

        let reference = referenceOfflineFrames
            .filter { $0.frequency > 0 && $0.confidence > 0.1 }
            .sorted { $0.time < $1.time }
        let live = frames.sorted { $0.time < $1.time }
        guard reference.count > 1 else { return }

        func robustScore(offset: Double) -> (score: Double, matches: Int)? {
            var errors: [Double] = []
            var index = 0
            for frame in live {
                let sourceTime = frame.time - origin
                let referenceTime = sourceTime - offset
                while index + 1 < reference.count && reference[index + 1].time <= referenceTime {
                    index += 1
                }
                guard index + 1 < reference.count else { break }
                let lower = reference[index]
                let upper = reference[index + 1]
                let gap = upper.time - lower.time
                let maximumReferenceGap = referenceIsAnalytic ? 0.025 : 0.09
                guard gap > 0, gap <= maximumReferenceGap,
                      referenceTime >= lower.time, referenceTime <= upper.time else { continue }
                let position = (referenceTime - lower.time) / gap
                let expected = exp(log(lower.frequency) + position * (log(upper.frequency) - log(lower.frequency)))
                let cents = abs(1_200 * log2(frame.frequency / expected))
                if cents.isFinite { errors.append(cents) }
            }
            guard errors.count >= 80 else { return nil }
            errors.sort()
            let median = errors[errors.count / 2]
            let p90 = errors[min(errors.count - 1, Int(Double(errors.count - 1) * 0.90))]
            return (median + 0.35 * p90, errors.count)
        }

        var best: (offset: Double, score: Double, matches: Int)?
        // A direct-file test needs only tens of milliseconds, but a
        // speaker→microphone run also includes device startup and acoustic
        // latency. Search that broader range coarsely first.
        for milliseconds in stride(from: -2_000, through: 2_000, by: 5) {
            let offset = Double(milliseconds) / 1_000
            guard let candidate = robustScore(offset: offset) else { continue }
            // A long held note can make several neighbouring offsets score
            // virtually identically. Prefer the smallest shift in that tie
            // rather than keeping the first value at the edge of the search
            // range; note attacks will still win whenever they carry timing
            // information.
            if best == nil || candidate.score < best!.score - 0.05 ||
                (abs(candidate.score - best!.score) <= 0.05 && abs(offset) < abs(best!.offset)) {
                best = (offset, candidate.score, candidate.matches)
            }
        }
        guard let coarseBest = best else { return }
        best = coarseBest
        let centreMilliseconds = Int((coarseBest.offset * 1_000).rounded())
        for milliseconds in (centreMilliseconds - 12)...(centreMilliseconds + 12) {
            let offset = Double(milliseconds) / 1_000
            guard let candidate = robustScore(offset: offset) else { continue }
            if candidate.score < best!.score - 0.02 ||
                (abs(candidate.score - best!.score) <= 0.02 && abs(offset) < abs(best!.offset)) {
                best = (offset, candidate.score, candidate.matches)
            }
        }
        guard let best else { return }
        referenceTimeOffset = best.offset
        referenceAnalysisMessage = String(
            format: "Referans eğrisi eklendi · otomatik zaman eşleme: %+.3f sn",
            best.offset
        )
    }

    /// Produces a compact, repeatable regression report for the development
    /// source test. Voiced samples are compared in cents; analytic reference
    /// gaps are also inspected for pitch points incorrectly emitted in silence.
    private func updateReferenceValidationReport() {
        guard let origin = referenceTestStartedAt,
              !frames.isEmpty,
              !referenceOfflineFrames.isEmpty else { return }

        if referenceIsAnalytic, !analyticReferenceTruth.isEmpty {
            updateFiveWayReferenceValidation(origin: origin)
            return
        }

        let reference = referenceOfflineFrames
            .filter { $0.frequency > 0 && $0.confidence > 0.1 }
            .sorted { $0.time < $1.time }
        let live = frames.sorted { $0.time < $1.time }
        guard reference.count > 1 else { return }

        let silentReferenceGaps: [(start: Double, end: Double)] = referenceIsAnalytic
            ? zip(reference, reference.dropFirst()).compactMap { pair in
                let (lower, upper) = pair
                guard upper.time - lower.time > 0.025 else { return nil }
                return (lower.time + 0.005, upper.time - 0.005)
            }
            : []
        let falseVoicedExamples = live.compactMap { frame -> (time: Double, frequency: Double)? in
            let sourceTime = frame.time - origin - referenceTimeOffset
            guard silentReferenceGaps.contains(where: { $0.start <= sourceTime && sourceTime <= $0.end }) else {
                return nil
            }
            return (sourceTime, frame.frequency)
        }
        let silentReferencePoints = silentReferenceGaps.reduce(0) { total, gap in
            total + max(1, Int(((gap.end - gap.start) / 0.010).rounded()) + 1)
        }

        var errors: [(time: Double, cents: Double, signedCents: Double, expected: Double, actual: Double)] = []
        var index = 0
        for frame in live {
            let sourceTime = frame.time - origin
            // The display uses `reference + offset`; invert that relation to
            // look up the matching reference sample for a live timestamp.
            let referenceTime = sourceTime - referenceTimeOffset
            while index + 1 < reference.count && reference[index + 1].time <= referenceTime {
                index += 1
            }
            guard index + 1 < reference.count else { break }
            let lower = reference[index]
            let upper = reference[index + 1]
            let gap = upper.time - lower.time
            let maximumReferenceGap = referenceIsAnalytic ? 0.025 : 0.09
            guard gap > 0, gap <= maximumReferenceGap,
                  referenceTime >= lower.time, referenceTime <= upper.time else { continue }
            let position = (referenceTime - lower.time) / gap
            let expected = exp(log(lower.frequency) + position * (log(upper.frequency) - log(lower.frequency)))
            let signedDifference = 1_200 * log2(frame.frequency / expected)
            let difference = abs(signedDifference)
            guard difference.isFinite else { continue }
            errors.append((sourceTime, difference, signedDifference, expected, frame.frequency))
        }

        // Traverse expected voiced samples as well as emitted samples. The old
        // one-way comparison could see a wrong point, but could not see a
        // high-register glissando segment where the engine published nothing.
        let sourceLive = live.map { (time: $0.time - origin - referenceTimeOffset, frequency: $0.frequency) }
        let liveIntervals = zip(sourceLive, sourceLive.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0 > 0 && $0 < 0.050 }
            .sorted()
        let liveHop = liveIntervals.isEmpty ? 0.010 : liveIntervals[liveIntervals.count / 2]
        let missingTolerance = 0.55 * liveHop
        var missingVoiced: [(time: Double, expected: Double)] = []
        var liveIndex = 0
        let voicedReference = Array(reference.dropFirst().dropLast())
        for target in voicedReference {
            while liveIndex + 1 < sourceLive.count,
                  sourceLive[liveIndex + 1].time <= target.time {
                liveIndex += 1
            }
            let choices = [liveIndex - 1, liveIndex, liveIndex + 1].filter {
                sourceLive.indices.contains($0)
            }
            let nearest = choices.min { abs(sourceLive[$0].time - target.time) < abs(sourceLive[$1].time - target.time) }
            if nearest == nil || abs(sourceLive[nearest!].time - target.time) > missingTolerance {
                missingVoiced.append((target.time, target.frequency))
            }
        }
        var missingRanges: [(start: Double, end: Double, count: Int)] = []
        var activeMissing: (start: Double, end: Double, count: Int)?
        for item in missingVoiced {
            if var range = activeMissing, item.time - range.end <= 0.015 {
                range.end = item.time
                range.count += 1
                activeMissing = range
            } else {
                if let range = activeMissing, range.count >= 3 { missingRanges.append(range) }
                activeMissing = (item.time, item.time, 1)
            }
        }
        if let range = activeMissing, range.count >= 3 { missingRanges.append(range) }

        let sortedErrors = errors.map(\.cents).sorted()
        let median = sortedErrors.isEmpty ? nil : sortedErrors[sortedErrors.count / 2]
        let p95 = sortedErrors.isEmpty ? nil : sortedErrors[min(sortedErrors.count - 1, Int(Double(sortedErrors.count - 1) * 0.95))]
        let highExpected = voicedReference.filter { $0.frequency >= 900 }.count
        let highMissing = missingVoiced.filter { $0.expected >= 900 }.count
        let highErrors = errors.filter { $0.expected >= 900 }.map(\.cents).sorted()
        let highP95 = highErrors.isEmpty ? nil : highErrors[min(highErrors.count - 1, Int(Double(highErrors.count - 1) * 0.95))]
        let matchedExpected = voicedReference.count - missingVoiced.count

        // A single differing window can be a legitimate attack. Flag only a
        // sustained divergence of at least ~35 ms.
        var candidateRanges: [(start: Double, end: Double, peak: Double, count: Int)] = []
        var active: (start: Double, end: Double, peak: Double, count: Int)?
        for item in errors where item.cents >= 100 {
            if var range = active, item.time - range.end <= 0.08 {
                range.end = item.time
                range.peak = max(range.peak, item.cents)
                range.count += 1
                active = range
            } else {
                if let range = active, range.count >= 3 { candidateRanges.append(range) }
                active = (item.time, item.time, item.cents, 1)
            }
        }
        if let range = active, range.count >= 3 { candidateRanges.append(range) }

        referenceErrorRanges = candidateRanges.map {
            LivePitchErrorRange(
                startTime: $0.start,
                endTime: $0.end,
                peakCents: $0.peak,
                explicitSeverity: .nonHarmonicError
            )
        } + missingRanges.map {
            LivePitchErrorRange(startTime: $0.start, endTime: $0.end, peakCents: 0, explicitSeverity: .missingVoiced)
        }
        let persistentErrorPoints = errors.compactMap { item -> LivePitchErrorPoint? in
            guard item.cents >= 100,
                  candidateRanges.contains(where: { $0.start <= item.time && item.time <= $0.end }) else {
                return nil
            }
            return LivePitchErrorPoint(
                time: item.time,
                frequency: item.actual,
                severity: .voicedClassification(item.signedCents)
            )
        }
        referenceErrorPoints = (
            persistentErrorPoints + falseVoicedExamples.map {
                LivePitchErrorPoint(time: $0.time, frequency: $0.frequency, severity: .falseVoiced)
            } + missingVoiced.map {
                LivePitchErrorPoint(time: $0.time, frequency: $0.expected, severity: .missingVoiced)
            }
        ).sorted { $0.time < $1.time }

        let listed = candidateRanges.prefix(3).map {
            String(format: "%.2f–%.2f sn (%.0f cent)", $0.start, $0.end, $0.peak)
        }
        referenceValidationSummary = String(
            format: "Doğrulama: %d/%d kapsama · ortanca %@ cent · %%95 %@ cent · %d hata adayı · sessizlikte %d yanlış nokta · sesli hedefte %d eksik nokta",
            matchedExpected, voicedReference.count,
            median.map { String(format: "%.1f", $0) } ?? "—",
            p95.map { String(format: "%.1f", $0) } ?? "—",
            candidateRanges.count, falseVoicedExamples.count, missingVoiced.count
        )
        let missingListed = missingRanges.prefix(3).map {
            String(format: "%.2f–%.2f sn (eksik)", $0.start, $0.end)
        }
        referenceValidationDetails = (listed + missingListed).isEmpty
            ? "Kalıcı büyük sapma veya eksik perde bulunmadı."
            : "İncelenecek aralıklar: " + (listed + missingListed).joined(separator: " · ")

        // pYIN can finish before the direct-source YIN replay. Keep the live
        // on-screen estimate, but write the regression history only once the
        // complete source has passed through the real-time engine.
        if !isBenchmarkRunning {
            // Keep a few concrete frequency pairs in the development report.
            // This makes a 2x/3x harmonic error distinguishable from timing,
            // room noise or a normal note-transition frame without requiring
            // another screenshot from the user.
            let examples = errors
                .filter { $0.cents >= 100 }
                .sorted { $0.cents > $1.cents }
                .prefix(16)
                .map { (time: $0.time, expected: $0.expected, actual: $0.actual, signedCents: $0.signedCents) }
            persistReferenceValidationReport(
                matchedPoints: matchedExpected,
                expectedVoicedPoints: voicedReference.count,
                missingVoiced: missingVoiced,
                missingRanges: missingRanges,
                highExpectedPoints: highExpected,
                highMissingPoints: highMissing,
                highP95Cents: highP95,
                medianCents: median,
                p95Cents: p95,
                ranges: candidateRanges,
                examples: examples,
                falseVoicedExamples: Array(falseVoicedExamples.prefix(32)),
                silentReferencePoints: silentReferencePoints
            )
        }
    }

    /// Mirrors `scripts/pitch_error_metrics.py`: every analytic 10 ms target
    /// frame is classified once and every emitted frame can be consumed once.
    /// These same five classes drive both the text summary and graph overlay.
    private func updateFiveWayReferenceValidation(origin: TimeInterval) {
        let targets = analyticReferenceTruth.sorted { $0.time < $1.time }
        let outputs = frames
            .map { (time: $0.time - origin - referenceTimeOffset, frequency: $0.frequency) }
            .sorted { $0.time < $1.time }
        guard !targets.isEmpty else { return }

        let intervals = zip(outputs, outputs.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0 > 0 && $0 < 0.050 }
            .sorted()
        let hop = intervals.isEmpty ? 0.010 : intervals[intervals.count / 2]
        let tolerance = 0.55 * hop
        var used = Set<Int>()
        var points: [LivePitchErrorPoint] = []
        var counts: [LivePitchErrorSeverity: Int] = [:]
        var correctAbsoluteCents = 0.0
        var correctSilent = 0

        func lowerBound(_ time: Double) -> Int {
            var lower = 0
            var upper = outputs.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if outputs[middle].time < time { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }

        for target in targets {
            let insertion = lowerBound(target.time)
            var candidates: [Int] = []
            var left = insertion - 1
            while left >= 0, target.time - outputs[left].time <= tolerance {
                if !used.contains(left) { candidates.append(left) }
                left -= 1
            }
            var right = insertion
            while right < outputs.count, outputs[right].time - target.time <= tolerance {
                if !used.contains(right) { candidates.append(right) }
                right += 1
            }
            let match = candidates.min {
                abs(outputs[$0].time - target.time) < abs(outputs[$1].time - target.time)
            }
            if let match { used.insert(match) }

            let classification: LivePitchErrorSeverity?
            let markerFrequency: Double?
            if let expected = target.frequency, expected > 0 {
                guard let match else {
                    classification = .missingVoiced
                    markerFrequency = expected
                    counts[.missingVoiced, default: 0] += 1
                    points.append(LivePitchErrorPoint(time: target.time, frequency: expected, severity: .missingVoiced))
                    continue
                }
                let actual = outputs[match].frequency
                let signedCents = 1_200 * log2(actual / expected)
                let voicedClass = LivePitchErrorSeverity.voicedClassification(signedCents)
                classification = voicedClass
                markerFrequency = actual
                counts[voicedClass, default: 0] += 1
                if voicedClass == .correctPitch { correctAbsoluteCents += abs(signedCents) }
            } else if let match {
                classification = .falseVoiced
                markerFrequency = outputs[match].frequency
                counts[.falseVoiced, default: 0] += 1
            } else {
                classification = nil // Correct silence is outside the five coloured classes.
                markerFrequency = nil
                correctSilent += 1
            }
            if let classification, let markerFrequency {
                points.append(LivePitchErrorPoint(
                    time: target.time,
                    frequency: markerFrequency,
                    severity: classification
                ))
            }
        }

        // Keep the raw points for diagnostics, but only promote a discrepancy
        // to the coloured overlay after transition grace and three-frame
        // persistence.  This mirrors pitch_error_metrics.py.
        let transitions = analyticReferenceTransitions
        func isTransitionTolerated(_ point: LivePitchErrorPoint) -> Bool {
            transitions.contains { abs(point.time - $0) <= 0.030 + 1e-9 }
        }
        var seriousIndices = Set<Int>()
        var transitionTolerated = 0
        var transientTolerated = 0
        var ranges: [LivePitchErrorRange] = []
        for severity in [.falseVoiced, .missingVoiced, .harmonicError, .nonHarmonicError] as [LivePitchErrorSeverity] {
            let eligible = points.indices.filter {
                points[$0].severity == severity && !isTransitionTolerated(points[$0])
            }.sorted { points[$0].time < points[$1].time }
            transitionTolerated += points.indices.filter {
                points[$0].severity == severity && isTransitionTolerated(points[$0])
            }.count
            var active: [Int] = []
            func finishActive() {
                guard !active.isEmpty else { return }
                if active.count >= 3 {
                    active.forEach { seriousIndices.insert($0) }
                    ranges.append(LivePitchErrorRange(
                        startTime: points[active[0]].time,
                        endTime: points[active[active.count - 1]].time,
                        peakCents: 0,
                        explicitSeverity: severity
                    ))
                } else {
                    transientTolerated += active.count
                }
            }
            for index in eligible {
                if let last = active.last, points[index].time - points[last].time > 0.015 {
                    finishActive()
                    active.removeAll(keepingCapacity: true)
                }
                active.append(index)
            }
            finishActive()
        }
        let classifiedPoints = points.enumerated().map {
            LivePitchErrorPoint(
                time: $0.element.time,
                frequency: $0.element.frequency,
                severity: $0.element.severity,
                isSerious: seriousIndices.contains($0.offset)
            )
        }
        referenceErrorPoints = classifiedPoints.sorted { $0.time < $1.time }
        referenceErrorRanges = ranges.sorted { $0.startTime < $1.startTime }
        let falseVoiced = counts[.falseVoiced, default: 0]
        let missingVoiced = counts[.missingVoiced, default: 0]
        let correctPitch = counts[.correctPitch, default: 0]
        let harmonicError = counts[.harmonicError, default: 0]
        let nonHarmonicError = counts[.nonHarmonicError, default: 0]
        let nearPitch = counts[.nearPitch, default: 0]
        let seriousFalseVoiced = classifiedPoints.filter { $0.isSerious && $0.severity == .falseVoiced }.count
        let seriousMissingVoiced = classifiedPoints.filter { $0.isSerious && $0.severity == .missingVoiced }.count
        let seriousHarmonic = classifiedPoints.filter { $0.isSerious && $0.severity == .harmonicError }.count
        let seriousNonHarmonic = classifiedPoints.filter { $0.isSerious && $0.severity == .nonHarmonicError }.count
        let meanCorrect = correctPitch > 0 ? correctAbsoluteCents / Double(correctPitch) : nil
        referenceValidationSummary = String(
            format: "Ciddi doğrulama: yanlış sesli %d · eksik sesli %d · harmonik %d · diğer %d · yakın %d",
            seriousFalseVoiced, seriousMissingVoiced, seriousHarmonic, seriousNonHarmonic, nearPitch
        )
        referenceValidationDetails = String(
            format: "Ham: yanlış %d · eksik %d · harmonik %d · diğer %d · geçiş toleransı %d · kısa tolerans %d · doğru ort. %@ cent",
            falseVoiced, missingVoiced, harmonicError, nonHarmonicError, transitionTolerated, transientTolerated,
            meanCorrect.map { String(format: "%.2f", $0) } ?? "—"
        )
        if !isBenchmarkRunning {
            persistFiveWayReferenceValidationReport(
                targets: targets,
                correctSilent: correctSilent,
                counts: counts,
                correctAbsoluteCents: correctAbsoluteCents,
                points: classifiedPoints
            )
        }
    }

    private func persistFiveWayReferenceValidationReport(
        targets: [(time: Double, frequency: Double?)],
        correctSilent: Int,
        counts: [LivePitchErrorSeverity: Int],
        correctAbsoluteCents: Double,
        points: [LivePitchErrorPoint]
    ) {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents/KlariVision")
        let directory = root.appending(path: "outputs/validation-reports")
        let source = referenceTestSourceName ?? "source"
        let safeSource = source
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = "\(safeSource.isEmpty ? "source" : safeSource)-\(Int(Date().timeIntervalSince1970)).json"
        let voiced = targets.filter { ($0.frequency ?? 0) > 0 }.count
        let silent = targets.count - voiced
        let correctPitch = counts[.correctPitch, default: 0]
        let totalErrors = counts[.falseVoiced, default: 0]
            + counts[.missingVoiced, default: 0]
            + counts[.harmonicError, default: 0]
            + counts[.nonHarmonicError, default: 0]
        let serious = points.filter { $0.isSerious }
        let payload: [String: Any] = [
            "schema": "klarivision-direct-source-validation-v5",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "source_name": source,
            "engine": pitchEngine.reportIdentifier,
            "reference_engine": "analytic_ground_truth_with_shared_signal_gate",
            "default_minimum_signal_rms": SignalGateSettings.defaultMinimumRMS,
            "default_minimum_signal_dbfs": SignalGateSettings.decibels(
                forRMS: SignalGateSettings.defaultMinimumRMS
            ),
            "signal_threshold_history": signalThresholdHistory.map {
                [
                    "source_time_seconds": round($0.sourceTime * 1_000) / 1_000,
                    "minimum_rms": $0.minimumRMS,
                    "minimum_dbfs": SignalGateSettings.decibels(forRMS: $0.minimumRMS),
                ]
            },
            "reference_time_offset_seconds": referenceTimeOffset,
            "reference_voiced_frames": voiced,
            "reference_silent_frames": silent,
            "correct_silent_frames": correctSilent,
            "false_voiced_frames": counts[.falseVoiced, default: 0],
            "missing_voiced_frames": counts[.missingVoiced, default: 0],
            "correct_pitch_frames": correctPitch,
            "correct_pitch_absolute_cents_sum": round(correctAbsoluteCents * 1_000_000) / 1_000_000,
            "correct_pitch_mean_absolute_cents": correctPitch > 0
                ? round(correctAbsoluteCents / Double(correctPitch) * 1_000_000) / 1_000_000
                : NSNull(),
            "harmonic_error_frames": counts[.harmonicError, default: 0],
            "non_harmonic_error_frames": counts[.nonHarmonicError, default: 0],
            "total_error_frames": totalErrors,
            "near_pitch_frames": counts[.nearPitch, default: 0],
            "serious_false_voiced_frames": serious.filter { $0.severity == .falseVoiced }.count,
            "serious_missing_voiced_frames": serious.filter { $0.severity == .missingVoiced }.count,
            "serious_harmonic_error_frames": serious.filter { $0.severity == .harmonicError }.count,
            "serious_non_harmonic_error_frames": serious.filter { $0.severity == .nonHarmonicError }.count,
            "serious_total_error_frames": serious.count,
            "error_examples": points
                .filter { $0.severity != .correctPitch }
                .prefix(64)
                .map {
                    [
                        "kind": $0.severity.reportKey,
                        "serious": $0.isSerious,
                        "time_seconds": round($0.time * 1_000) / 1_000,
                        "marker_hz": round($0.frequency * 100) / 100,
                    ] as [String: Any]
                },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: filename)
            try data.write(to: destination, options: .atomic)
            referenceValidationReportURL = destination
        } catch {
            referenceValidationReportURL = nil
        }
    }

    /// Persists a compact, raw-audio-free record of each direct-source
    /// validation.  This turns a one-off visual comparison into a regression
    /// history that can be summarized by the project script.
    private func persistReferenceValidationReport(
        matchedPoints: Int,
        expectedVoicedPoints: Int,
        missingVoiced: [(time: Double, expected: Double)],
        missingRanges: [(start: Double, end: Double, count: Int)],
        highExpectedPoints: Int,
        highMissingPoints: Int,
        highP95Cents: Double?,
        medianCents: Double?,
        p95Cents: Double?,
        ranges: [(start: Double, end: Double, peak: Double, count: Int)],
        examples: [(time: Double, expected: Double, actual: Double, signedCents: Double)],
        falseVoicedExamples: [(time: Double, frequency: Double)],
        silentReferencePoints: Int
    ) {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents/KlariVision")
        let directory = root.appending(path: "outputs/validation-reports")
        let formatter = ISO8601DateFormatter()
        let createdAt = formatter.string(from: Date())
        let source = referenceTestSourceName ?? "source"
        let safeSource = source
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = "\(safeSource.isEmpty ? "source" : safeSource)-\(Int(Date().timeIntervalSince1970)).json"
        let roundedMedian: Any = medianCents.map { round($0 * 10) / 10 } ?? NSNull()
        let roundedP95: Any = p95Cents.map { round($0 * 10) / 10 } ?? NSNull()
        let highFrequencyCoverage: [String: Any] = [
            "range_hz": [900, 1500],
            "expected_voiced_points": highExpectedPoints,
            "missing_voiced_points": highMissingPoints,
            "coverage_percent": highExpectedPoints > 0
                ? round(Double(highExpectedPoints - highMissingPoints) / Double(highExpectedPoints) * 10_000) / 100
                : NSNull(),
            "p95_absolute_cent_error": highP95Cents.map { round($0 * 10) / 10 } ?? NSNull(),
        ]
        let missingExamples: [[String: Any]] = missingVoiced.prefix(64).map {
            ["time_seconds": round($0.time * 1_000) / 1_000, "expected_hz": round($0.expected * 100) / 100]
        }
        let missingRangePayload: [[String: Any]] = missingRanges.map {
            ["start_seconds": round($0.start * 1_000) / 1_000, "end_seconds": round($0.end * 1_000) / 1_000, "points": $0.count]
        }
        let payload: [String: Any] = [
            "schema": "klarivision-direct-source-validation-v2",
            "created_at": createdAt,
            "source_name": source,
            "engine": pitchEngine.reportIdentifier,
            "reference_engine": referenceIsAnalytic ? "analytic_ground_truth" : "offline_pyin",
            "reference_time_offset_seconds": referenceTimeOffset,
            "matched_points": matchedPoints,
            "expected_voiced_points": expectedVoicedPoints,
            "missing_voiced_points": missingVoiced.count,
            "coverage_percent": expectedVoicedPoints > 0
                ? round(Double(matchedPoints) / Double(expectedVoicedPoints) * 10_000) / 100
                : 0,
            "median_absolute_cent_error": roundedMedian,
            "p95_absolute_cent_error": roundedP95,
            "high_frequency_coverage": highFrequencyCoverage,
            "missing_voiced_examples": missingExamples,
            "missing_voiced_ranges": missingRangePayload,
            "silent_reference_points": silentReferencePoints,
            "false_voiced_points": falseVoicedExamples.count,
            "false_voiced_percent": silentReferencePoints > 0
                ? round(Double(falseVoicedExamples.count) / Double(silentReferencePoints) * 10_000) / 100
                : 0,
            "false_voiced_examples": falseVoicedExamples.map {
                [
                    "time_seconds": round($0.time * 1_000) / 1_000,
                    "actual_hz": round($0.frequency * 100) / 100,
                ]
            },
            "persistent_divergences": ranges.map {
                [
                    "start_seconds": round($0.start * 1_000) / 1_000,
                    "end_seconds": round($0.end * 1_000) / 1_000,
                    "peak_cents": round($0.peak * 10) / 10,
                    "points": $0.count,
                ]
            },
            "largest_error_examples": examples.map {
                [
                    "time_seconds": round($0.time * 1_000) / 1_000,
                    "expected_hz": round($0.expected * 100) / 100,
                    "actual_hz": round($0.actual * 100) / 100,
                    "signed_cents": round($0.signedCents * 10) / 10,
                    "frequency_ratio": round(($0.actual / $0.expected) * 1_000) / 1_000,
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: filename)
            try data.write(to: destination, options: .atomic)
            referenceValidationReportURL = destination
        } catch {
            // The visible in-memory report remains useful even when a sandbox
            // or disk policy prevents writing a history file.
            referenceValidationReportURL = nil
        }
    }

    private func start(playbackURL: URL? = nil) {
        guard !isRunning else { return }
        let audioEngine = engine ?? AVAudioEngine()
        engine = audioEngine
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            status = "Kullanılabilir bir mikrofon bulunamadı."
            return
        }

        input.removeTap(onBus: 0)
        let sampleRate = format.sampleRate
        invalidateLiveCapture()
        resetLivePerformance()
        practiceTimelineEnd = nil
        // Reference playback gets its origin at AVPlayer's actual start,
        // rather than while the item is still being decoded.
        practiceStartedAt = playbackURL == nil
            ? Date().timeIntervalSinceReferenceDate
            : nil
        // A new source test must never inherit the previous phrase's pitch
        // history.  Dispatching this reset asynchronously allowed the first
        // microphone buffers of a replay to be scored against stale notes,
        // which made the same passage behave differently after seeking back.
        processingQueue.sync { [weak self] in self?.resetProcessingState() }
        // A small capture buffer keeps the UI responsive.  The analyser still
        // works on its own larger, overlapping analysis window.
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.appendRecordingBuffer(buffer)
            guard let samples = buffer.floatChannelData?.pointee else { return }
            let copy = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            self?.captureLive(samples: copy, sampleRate: sampleRate, capturedAt: Date().timeIntervalSinceReferenceDate)
        }

        do {
            if recordingStartPending {
                beginRecording(format: format)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            if let playbackURL {
                guard FileManager.default.fileExists(atPath: playbackURL.path) else {
                    input.removeTap(onBus: 0)
                    audioEngine.stop()
                    isRunning = false
                    status = "Seçilen kaynak dosya bulunamadı. Lütfen dosyayı yeniden seç."
                    return
                }
                let item = AVPlayerItem(url: playbackURL)
                let player = AVPlayer(playerItem: item)
                player.volume = 1
                referencePlayer = player
                status = "Kaynak dosya hazırlanıyor…"
                referenceItemStatusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
                    DispatchQueue.main.async {
                        guard let self, self.referencePlayer === player else { return }
                        switch item.status {
                        case .readyToPlay:
                            // Start only once the local file has been decoded.
                            // This avoids a silent-looking reference test when
                            // AVPlayer is still preparing an M4A/MP4 container.
                            guard self.referenceTestStartedAt == nil else { return }
                            self.referenceTestStartedAt = Date().timeIntervalSinceReferenceDate
                            player?.play()
                            self.status = "Canlı referans testi oynuyor: \(playbackURL.lastPathComponent) · Ses kaydedilmiyor."
                        case .failed:
                            let detail = item.error?.localizedDescription ?? "bilinmeyen hata"
                            self.status = "Kaynak dosya oynatılamadı: \(detail)"
                        default:
                            break
                        }
                    }
                }
            } else {
                status = isRecording
                    ? "Mikrofon dinleniyor. Kayıt yapılıyor."
                    : "Mikrofon dinleniyor. Ses kaydedilmiyor."
            }
        } catch {
            input.removeTap(onBus: 0)
            discardRecording()
            recordingStartPending = false
            isRecording = false
            status = "Mikrofon başlatılamadı: \(error.localizedDescription)"
        }
    }

    private func process(
        samples: [Float],
        sampleRate: Double,
        capturedAt: TimeInterval? = nil
    ) {
        let currentResolution = processingResolution
        let currentPitchEngine = processingPitchEngine
        sampleWindow.append(contentsOf: samples)
        sampleDecisionHistory.append(contentsOf: samples)
        if sampleDecisionHistory.count > causalDecisionWindowSize {
            sampleDecisionHistory.removeFirst(sampleDecisionHistory.count - causalDecisionWindowSize)
        }
        if sampleWindow.count > currentResolution.windowSize {
            sampleWindow.removeFirst(sampleWindow.count - currentResolution.windowSize)
        }
        samplesSinceLastEstimate += samples.count
        guard sampleWindow.count >= currentResolution.windowSize,
              samplesSinceLastEstimate >= currentResolution.hopSize else { return }
        samplesSinceLastEstimate = 0
        // Offline pYIN selects a plausible path through adjacent candidates.
        // Here the same idea is made causal: only the preceding accepted
        // pitch is considered, without adding a future-frame delay.
        let result = estimateLivePitch(
            samples: sampleWindow,
            decisionSamples: sampleDecisionHistory,
            sampleRate: sampleRate,
            engine: currentPitchEngine,
            capturedAt: capturedAt
        )
        let productionFrames = productionCorePublishedFrames
        productionCorePublishedFrames.removeAll(keepingCapacity: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.usesProductionCore {
                self.appendProductionFrames(productionFrames)
                return
            }
            // Swift-package builds have no C++ core, so there is nothing to
            // publish: the engine lives entirely in C++.
            self.append(result, capturedAt: capturedAt)
        }
    }

    private func captureLive(samples: [Float], sampleRate: Double, capturedAt: TimeInterval) {
        liveInputLock.lock()
        let currentResolution = liveCaptureResolution
        if liveRemainderStartTime == nil {
            liveRemainderStartTime = capturedAt - Double(samples.count) / sampleRate
        }
        liveInputRemainder.append(contentsOf: conditionLiveInput(samples, sampleRate: sampleRate))
        let runID = liveRunID
        var jobs: [([Float], [Float], TimeInterval)] = []

        while liveInputRemainder.count >= currentResolution.hopSize {
            let chunk = Array(liveInputRemainder.prefix(currentResolution.hopSize))
            liveInputRemainder.removeFirst(currentResolution.hopSize)
            let chunkStart = liveRemainderStartTime ?? capturedAt
            let frameTime = chunkStart + Double(currentResolution.hopSize) / sampleRate
            liveRemainderStartTime = frameTime

            liveCaptureWindow.append(contentsOf: chunk)
            liveDecisionHistory.append(contentsOf: chunk)
            if liveDecisionHistory.count > causalDecisionWindowSize {
                liveDecisionHistory.removeFirst(liveDecisionHistory.count - causalDecisionWindowSize)
            }
            if liveCaptureWindow.count > currentResolution.windowSize {
                liveCaptureWindow.removeFirst(liveCaptureWindow.count - currentResolution.windowSize)
            }
            guard liveCaptureWindow.count >= currentResolution.windowSize else { continue }

            if liveQueuedAnalysisCount < maximumQueuedLiveAnalyses {
                liveQueuedAnalysisCount += 1
                jobs.append((liveCaptureWindow, liveDecisionHistory, frameTime))
            } else {
                liveDroppedEstimateCount += 1
            }
        }
        liveInputLock.unlock()

        for (window, decisionWindow, frameTime) in jobs {
            processingQueue.async { [weak self] in
                guard let self else { return }
                let engine = self.processingPitchEngine
                let calculationStartedAt = ProcessInfo.processInfo.systemUptime
                let result = self.estimateLivePitch(
                    samples: window,
                    decisionSamples: decisionWindow,
                    sampleRate: sampleRate,
                    engine: engine,
                    capturedAt: frameTime
                )
                let productionFrames = self.productionCorePublishedFrames
                self.productionCorePublishedFrames.removeAll(keepingCapacity: true)
                let calculationMilliseconds = (ProcessInfo.processInfo.systemUptime - calculationStartedAt) * 1_000
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentLiveRun(runID) else { return }
                    self.recordLivePerformance(calculationMilliseconds: calculationMilliseconds)
                    if self.usesProductionCore {
                        self.appendProductionFrames(productionFrames)
                        return
                    }
                    // Swift-package builds have no C++ core to publish from.
                    self.append(result, capturedAt: frameTime)
                }
                self.liveInputLock.lock()
                if self.liveRunID == runID {
                    self.liveQueuedAnalysisCount = max(0, self.liveQueuedAnalysisCount - 1)
                }
                self.liveInputLock.unlock()
            }
        }
    }

    /// Rejects low-frequency mechanical/room rumble without imposing a
    /// musical pitch floor.
    private func conditionLiveInput(_ samples: [Float], sampleRate: Double) -> [Float] {
        let cutoff = 100.0
        let rc = 1.0 / (2.0 * Double.pi * cutoff)
        let coefficient = Float(rc / (rc + 1.0 / sampleRate))
        var filtered: [Float] = []
        filtered.reserveCapacity(samples.count)
        for input in samples {
            let first = coefficient * (liveHighPass1PreviousOutput + input - liveHighPass1PreviousInput)
            liveHighPass1PreviousInput = input
            liveHighPass1PreviousOutput = first
            let second = coefficient * (liveHighPass2PreviousOutput + first - liveHighPass2PreviousInput)
            liveHighPass2PreviousInput = first
            liveHighPass2PreviousOutput = second
            filtered.append(second)
        }
        return filtered
    }

    /// Single live/study estimation path since D-039. Every pitch decision is
    /// the C++ unified session's; Swift measures the frame's RMS only to drive
    /// the on-screen signal meter and the eligibility flag the report uses.
    /// The published frames arrive through `productionCorePublishedFrames`,
    /// which is why this returns nil on the production path.
    private func estimateLivePitch(
        samples: [Float],
        decisionSamples: [Float]? = nil,
        sampleRate: Double,
        engine: LivePitchEngine,
        capturedAt: TimeInterval? = nil
    ) -> (frequency: Double, confidence: Double)? {
        let frameRMS = Self.centeredRMS(samples)
        SignalLevelMonitor.publish(rms: frameRMS)
        currentFrameSignalEligible = frameRMS >= minimumSignalRMS
        #if !KLARIVISION_SWIFT_PACKAGE
        return estimateProductionPitchCore(
            samples: samples,
            sampleRate: sampleRate,
            capturedAt: capturedAt,
            engine: engine
        )
        #else
        // No C++ core in the Swift-package build, and no Swift mirror of the
        // unified engine: the removed engines were the only ones that had one.
        return nil
        #endif
    }

    #if !KLARIVISION_SWIFT_PACKAGE
    /// Production boundary shared by microphone and Study analysis. C++ owns
    /// the causal publication and any returned short-gap frames. `engine` is
    /// carried through for the session the caller already built; there is one
    /// engine, so it selects nothing here.
    private func estimateProductionPitchCore(
        samples: [Float],
        sampleRate: Double,
        capturedAt: TimeInterval?,
        engine: LivePitchEngine
    ) -> (frequency: Double, confidence: Double)? {
        productionCorePublishedFrames.removeAll(keepingCapacity: true)
        guard let session = productionCoreSession, sampleRate > 0 else { return nil }
        let sourceTime = (capturedAt ?? 0) - Double(samples.count) / (2 * sampleRate)
        let processed = samples.withUnsafeBufferPointer { buffer in
            kv_production_pitch_session_process_frame(
                session, buffer.baseAddress, buffer.count, sampleRate, sourceTime
            )
        }
        guard processed != 0 else { return nil }
        for index in 0..<kv_production_pitch_session_output_count(session) {
            var frame = kv_pitch_frame()
            guard kv_production_pitch_session_output_frame(session, index, &frame) != 0,
                  frame.voiced != 0 else { continue }
            productionCorePublishedFrames.append(LivePitchFrame(
                time: frame.time_seconds,
                frequency: frame.frequency_hz,
                confidence: frame.confidence
            ))
        }
        return nil
    }

    private func finishProductionPitchCore() -> [LivePitchFrame] {
        guard let session = productionCoreSession else { return [] }
        _ = kv_production_pitch_session_finish(session)
        var result: [LivePitchFrame] = []
        for index in 0..<kv_production_pitch_session_output_count(session) {
            var frame = kv_pitch_frame()
            guard kv_production_pitch_session_output_frame(session, index, &frame) != 0,
                  frame.voiced != 0 else { continue }
            result.append(LivePitchFrame(
                time: frame.time_seconds,
                frequency: frame.frequency_hz,
                confidence: frame.confidence
            ))
        }
        return result
    }

    #endif


    private func append(
        _ result: (frequency: Double, confidence: Double)?,
        capturedAt: TimeInterval? = nil
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        guard let result else {
            currentFrequency = nil
            currentConfidence = 0
            if !isBenchmarkRunning || referenceTestStartedAt == nil {
                frames.removeAll { $0.time < now - historyDuration }
            }
            return
        }
        currentFrequency = result.frequency
        currentConfidence = result.confidence
        frames.append(LivePitchFrame(time: capturedAt ?? now, frequency: result.frequency, confidence: result.confidence))
        if !isBenchmarkRunning || referenceTestStartedAt == nil {
            frames.removeAll { $0.time < now - historyDuration }
        }
    }

    /// The shared C++ production session emits its own frames.  Do not append
    /// its `nil` Swift fallback after those frames: that would clear the
    /// live tuner immediately while leaving the graph point intact.
    private func appendProductionFrames(_ frames: [LivePitchFrame]) {
        guard !frames.isEmpty else {
            append(nil)
            return
        }
        for frame in frames {
            append((frame.frequency, frame.confidence), capturedAt: frame.time)
        }
    }

    /// True wherever the C++ core is linked. Every pitch decision is the
    /// core's; the Swift-package build has no engine at all, so it publishes
    /// nothing.
    private var usesProductionCore: Bool {
        #if !KLARIVISION_SWIFT_PACKAGE
        true
        #else
        false
        #endif
    }

    private func resetLivePerformance() {
        livePointsPerSecond = 0
        liveComputeMilliseconds = 0
        liveDroppedEstimates = 0
        liveMeasurementStartedAt = nil
        liveMeasurementPublishedAt = 0
        liveMeasurementCount = 0
        liveMeasurementTotalMilliseconds = 0
        liveDroppedEstimateCount = 0
    }

    private func recordLivePerformance(calculationMilliseconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if liveMeasurementStartedAt == nil {
            liveMeasurementStartedAt = now
            liveMeasurementPublishedAt = now
        }
        liveMeasurementCount += 1
        liveMeasurementTotalMilliseconds += calculationMilliseconds
        guard let startedAt = liveMeasurementStartedAt,
              now - liveMeasurementPublishedAt >= 1 else { return }

        let elapsed = max(0.001, now - startedAt)
        livePointsPerSecond = Double(liveMeasurementCount) / elapsed
        liveComputeMilliseconds = liveMeasurementTotalMilliseconds / Double(liveMeasurementCount)
        liveInputLock.lock()
        liveDroppedEstimates = liveDroppedEstimateCount
        liveInputLock.unlock()
        liveMeasurementPublishedAt = now
    }

    /// Shared gate level after removing the analysis frame's DC component.
    private static func centeredRMS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let squareSum = samples.reduce(0.0) {
            let centered = Double($1) - mean
            return $0 + centered * centered
        }
        return sqrt(squareSum / Double(samples.count))
    }



    private struct SwipePrimeSpectrumV2 {
        let squareRootMagnitudes: [Double]
        let sampleRate: Double
        let fftSize: Int

        func value(at frequency: Double) -> Double {
            guard frequency > 0, frequency < sampleRate / 2,
                  !squareRootMagnitudes.isEmpty else { return 0 }
            let position = frequency * Double(fftSize) / sampleRate
            let lower = Int(floor(position))
            guard lower >= 0, lower + 1 < squareRootMagnitudes.count else { return 0 }
            let fraction = position - Double(lower)
            return squareRootMagnitudes[lower] * (1 - fraction) +
                squareRootMagnitudes[lower + 1] * fraction
        }
    }

    /// Candidate-only approximation of SWIPE'. It deliberately does not run
    /// a dense pitch grid: YIN, autocorrelation and MPM already supply the
    /// candidates. We retain SWIPE's square-root spectrum and peak/valley
    /// contrast, and SWIPE' credit only for harmonic 1 and prime harmonics.
    private static func swipePrimeHarmonicSupports(
        samples: [Float],
        sampleRate: Double,
        candidateFrequencies: [Double]
    ) -> [Double] {
        guard samples.count >= 256, sampleRate > 0, !candidateFrequencies.isEmpty else {
            return Array(repeating: 0, count: candidateFrequencies.count)
        }
        var fftSize = 1
        while fftSize < samples.count { fftSize <<= 1 }

        var real = Array(repeating: 0.0, count: fftSize)
        var imaginary = Array(repeating: 0.0, count: fftSize)
        let denominator = Double(max(1, samples.count - 1))
        for index in samples.indices {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / denominator)
            real[index] = Double(samples[index]) * window
        }

        // In-place radix-2 FFT. V2 is experimental and isolated; once the
        // portable core is bridged into Swift this implementation disappears.
        var reversed = 0
        if fftSize > 1 {
            for index in 1..<fftSize {
                var bit = fftSize >> 1
                while bit > 0, (reversed & bit) != 0 {
                    reversed ^= bit
                    bit >>= 1
                }
                reversed ^= bit
                if index < reversed {
                    real.swapAt(index, reversed)
                    imaginary.swapAt(index, reversed)
                }
            }
        }

        var length = 2
        while length <= fftSize {
            let angle = -2 * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            var start = 0
            while start < fftSize {
                var weightReal = 1.0
                var weightImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let evenIndex = start + offset
                    let oddIndex = evenIndex + length / 2
                    let oddReal = real[oddIndex] * weightReal - imaginary[oddIndex] * weightImaginary
                    let oddImaginary = real[oddIndex] * weightImaginary + imaginary[oddIndex] * weightReal
                    let evenReal = real[evenIndex]
                    let evenImaginary = imaginary[evenIndex]
                    real[evenIndex] = evenReal + oddReal
                    imaginary[evenIndex] = evenImaginary + oddImaginary
                    real[oddIndex] = evenReal - oddReal
                    imaginary[oddIndex] = evenImaginary - oddImaginary
                    let nextWeightReal = weightReal * stepReal - weightImaginary * stepImaginary
                    weightImaginary = weightReal * stepImaginary + weightImaginary * stepReal
                    weightReal = nextWeightReal
                }
                start += length
            }
            length <<= 1
        }

        let magnitudes = (0...(fftSize / 2)).map { index in
            sqrt(hypot(real[index], imaginary[index]))
        }
        let spectrum = SwipePrimeSpectrumV2(
            squareRootMagnitudes: magnitudes,
            sampleRate: sampleRate,
            fftSize: fftSize
        )
        let analysisLimit = min(5_000.0, sampleRate / 2 * 0.98)

        func isPrime(_ value: Int) -> Bool {
            guard value >= 2 else { return false }
            if value == 2 { return true }
            var divisor = 2
            while divisor * divisor <= value {
                if value % divisor == 0 { return false }
                divisor += 1
            }
            return true
        }

        return candidateFrequencies.map { candidate in
            guard candidate.isFinite, candidate > 0 else { return 0 }
            let maximumHarmonic = Int(floor(analysisLimit / candidate))
            guard maximumHarmonic >= 1 else { return 0 }
            var innerProduct = 0.0
            var kernelNormSquared = 0.0
            var spectrumNormSquared = 0.0
            for harmonic in 1...maximumHarmonic {
                let peak = spectrum.value(at: candidate * Double(harmonic))
                spectrumNormSquared += peak * peak
                guard harmonic == 1 || isPrime(harmonic) else { continue }
                let weight = 1 / sqrt(Double(harmonic))
                let left = spectrum.value(at: candidate * (Double(harmonic) - 0.5))
                let right = spectrum.value(at: candidate * (Double(harmonic) + 0.5))
                innerProduct += weight * (peak - 0.5 * (left + right))
                kernelNormSquared += weight * weight
            }
            let normalization = sqrt(kernelNormSquared * spectrumNormSquared)
            guard normalization > 0.000_000_000_001 else { return 0 }
            return max(0, min(1, innerProduct / normalization))
        }
    }

    /// Experimental Vocal Pitch Monitor-style path: normalized autocorrelation
    /// with a first-strong-peak rule.  It publishes each confident raw estimate
    /// so short transitions and clarinet vibrato remain visible on the graph.
    private static func estimatePitchAutocorrelation(
        samples: [Float],
        sampleRate: Double,
        appliesHighRegisterGate: Bool = true
    ) -> (frequency: Double, confidence: Double)? {
        guard samples.count >= 1_024 else { return nil }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let centeredSamples = samples.map { Float(Double($0) - mean) }
        let minLag = max(2, Int(sampleRate / 1_500))
        let maxLag = min(samples.count / 2, Int(sampleRate / 80))
        guard minLag + 2 < maxLag else { return nil }

        var cumulativeEnergy = Array(repeating: 0.0, count: samples.count + 1)
        for index in centeredSamples.indices {
            let sample = Double(centeredSamples[index])
            cumulativeEnergy[index + 1] = cumulativeEnergy[index] + sample * sample
        }

        var correlation = Array(repeating: 0.0, count: maxLag + 1)
        for lag in minLag...maxLag {
            let count = centeredSamples.count - lag
            let leadingEnergy = cumulativeEnergy[count]
            let delayedEnergy = cumulativeEnergy[centeredSamples.count] - cumulativeEnergy[lag]
            let denominator = sqrt(max(1e-12, leadingEnergy * delayedEnergy))
            correlation[lag] = Double(vDSP.dot(centeredSamples[0..<count], centeredSamples[lag..<centeredSamples.count])) / denominator
        }

        var peaks: [Int] = []
        for lag in (minLag + 1)..<maxLag where correlation[lag] >= correlation[lag - 1] && correlation[lag] > correlation[lag + 1] {
            peaks.append(lag)
        }
        guard let strongest = peaks.max(by: { correlation[$0] < correlation[$1] }),
              correlation[strongest] >= 0.38 else { return nil }

        // A fundamental repeats at a longer period than a strong overtone.
        // Prefer the earliest peak that is almost as periodic as the strongest.
        let acceptance = max(0.52, correlation[strongest] * 0.84)
        let selected = peaks.first(where: { correlation[$0] >= acceptance }) ?? strongest

        let previous = correlation[selected - 1]
        let current = correlation[selected]
        let next = correlation[selected + 1]
        let denominator = previous - 2 * current + next
        let correction = abs(denominator) > 0.000_001 ? 0.5 * (previous - next) / denominator : 0
        let refinedLag = Double(selected) + max(-0.5, min(0.5, correction))
        let frequency = sampleRate / refinedLag
        guard frequency.isFinite, frequency >= 80, frequency <= 1_500 else { return nil }
        let confidence = max(0, min(1, current))

        // Clarinet attacks can briefly make an upper harmonic appear more
        // periodic than the fundamental.  VPM-style monitors leave such an
        // uncertain instant blank; drawing it as a 900–1500 Hz note produces
        // a visually distracting false spike.  Genuine high notes remain
        // visible once their periodicity is sufficiently strong.
        guard !appliesHighRegisterGate || frequency <= 900 || confidence >= 0.80 else { return nil }
        return (frequency, confidence)
    }

    /// McLeod Pitch Method candidate generator. Unlike the old one-result
    /// estimators, this keeps every sufficiently clear NSDF peak so V2 can
    /// compare the possible fundamental and harmonic periods explicitly.
    private static func estimatePitchMPMCandidates(
        samples: [Float],
        sampleRate: Double
    ) -> [(frequency: Double, confidence: Double)] {
        guard samples.count >= 1_024, sampleRate > 0 else { return [] }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let centered = samples.map { Float(Double($0) - mean) }
        let minLag = max(2, Int(sampleRate / 1_500))
        let maxLag = min(centered.count / 2, Int(sampleRate / 80))
        guard minLag + 2 < maxLag else { return [] }

        var cumulativeEnergy = Array(repeating: Float.zero, count: centered.count + 1)
        for index in centered.indices {
            cumulativeEnergy[index + 1] = cumulativeEnergy[index] + centered[index] * centered[index]
        }

        var nsdf = Array(repeating: Float.zero, count: maxLag + 1)
        centered.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in minLag...maxLag {
                let count = centered.count - lag
                let leadingEnergy = cumulativeEnergy[count]
                let delayedEnergy = cumulativeEnergy[centered.count] - cumulativeEnergy[lag]
                let normalisation = leadingEnergy + delayedEnergy
                guard normalisation > 0.000_000_001 else { continue }
                var correlation: Float = 0
                vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &correlation, vDSP_Length(count))
                nsdf[lag] = 2 * correlation / normalisation
            }
        }

        var candidates: [(frequency: Double, confidence: Double)] = []
        for lag in (minLag + 1)..<maxLag {
            let previous = nsdf[lag - 1]
            let current = nsdf[lag]
            let next = nsdf[lag + 1]
            guard current >= 0.55, current >= previous, current > next else { continue }
            let denominator = previous - 2 * current + next
            let correction: Float = abs(denominator) > 0.000_001
                ? max(-0.5, min(0.5, 0.5 * (previous - next) / denominator))
                : 0
            let refinedLag = Double(lag) + Double(correction)
            let frequency = sampleRate / refinedLag
            guard frequency.isFinite, frequency >= 80, frequency <= 1_500 else { continue }
            candidates.append((frequency, Double(max(0, min(1, current)))))
        }

        return Array(candidates.sorted { $0.confidence > $1.confidence }.prefix(12))
    }
}
