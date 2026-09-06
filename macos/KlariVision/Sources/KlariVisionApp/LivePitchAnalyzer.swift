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
            Section("Pitch Motorları") {
                Picker("Dinleme modu motoru", selection: $studyEngine) {
                    ForEach(PitchEngineSettings.userChoices) { engine in
                        Text(engine.title).tag(engine.id)
                    }
                }
                .accessibilityHint(AccessibilityText.enginePickerHint)
                Text("Dört motor eşit kullanıcı seçeneğidir. Yeni dosya yalnız seçilen motorla analiz edilir; mevcut çalışmada hazır sonuç yoksa yeniden analiz gerekir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Çalma modu motoru", selection: $liveEngine) {
                    ForEach(PitchEngineSettings.userChoices) { engine in
                        Text(engine.title).tag(engine.id)
                    }
                }
                .accessibilityHint(AccessibilityText.enginePickerHint)
                Text("Çalma modu motoru değişikliği mikrofonun bir sonraki başlatılışında uygulanır. İlk açılıştaki YIN v1 seçimi yalnız geriye uyumluluk içindir; öneri veya kalite sıralaması değildir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Birlikte Çal") {
                Picker("Birlikte Çal Motoru", selection: $togetherEngine) {
                    ForEach(PitchEngineSettings.userChoices) { engine in
                        Text(engine.title).tag(engine.id)
                    }
                }
                .accessibilityHint(AccessibilityText.enginePickerHint)
                Text("Dört motor eşit kullanıcı seçeneğidir. Yeni dosya yalnız seçilen motorla analiz edilir; mevcut çalışmada hazır sonuç yoksa yeniden analiz gerekir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Mikrofon hizalaması bilinçli olarak burada değil, çalışma
                // ekranının üst çubuğunda: doğru değer ancak çalarken eğriye
                // bakılarak bulunuyor ve ayrı bir pencereye gidip gelmek onu
                // kullanılamaz kılıyordu.
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

/// Candidate contract used only by the experimental engine. V1 intentionally
/// keeps its existing tuple-based YIN path so V2 experiments cannot mutate
/// the stable musician-facing decision logic.
struct LivePitchCandidateV2 {
    enum Source {
        case yin
        case autocorrelation
        case mpm
        case spectral
    }

    let frequency: Double
    let periodicity: Double
    let agreementSupport: Double
    let primeHarmonicSupport: Double
    let source: Source
}

struct LiveScoredPitchCandidateV2 {
    let candidate: LivePitchCandidateV2
    let emissionScore: Double
}

struct LivePitchPathFrameV2 {
    let capturedAt: TimeInterval?
    let candidates: [LiveScoredPitchCandidateV2]
    let signalEligible: Bool
}

struct VPMLikePitchDecision {
    let spectral: (frequency: Double, confidence: Double)
    let autocorrelation: (frequency: Double, confidence: Double)
}

/// Small causal guard shared by the two experimental engines.  It does not
/// smooth the contour: only a possible downward 1/3, 1/2 or 2/3 jump has to
/// survive one following analysis hop before it replaces the last published
/// pitch. Recovery from a false subharmonic is immediate; ordinary note
/// motion and vibrato pass through unchanged.
struct ExperimentalHarmonicJumpGate {
    let requiredConfirmations: Int
    private var publishedFrequency: Double?
    private var pending: (frequency: Double, confidence: Double, confirmations: Int)?

    init(requiredConfirmations: Int = 2) {
        self.requiredConfirmations = max(1, requiredConfirmations)
    }

    mutating func filter(
        _ result: (frequency: Double, confidence: Double)?
    ) -> (frequency: Double, confidence: Double)? {
        guard let result else {
            publishedFrequency = nil
            pending = nil
            return nil
        }
        guard let previous = publishedFrequency else {
            publishedFrequency = result.frequency
            return result
        }

        let jumpCents = abs(1_200 * log2(result.frequency / previous))
        let ratio = result.frequency / previous
        let subharmonicRatios = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        let isHarmonicJump = result.frequency < previous && jumpCents >= 650 && subharmonicRatios.contains {
            abs(1_200 * log2(ratio / $0)) <= 110
        }
        guard isHarmonicJump else {
            pending = nil
            publishedFrequency = result.frequency
            return result
        }

        if let pending,
           abs(1_200 * log2(result.frequency / pending.frequency)) <= 180 {
            let confirmations = pending.confirmations + 1
            if confirmations >= requiredConfirmations {
                self.pending = nil
                publishedFrequency = result.frequency
                return result
            }
            self.pending = (result.frequency, result.confidence, confirmations)
            return (previous, min(result.confidence, 0.55))
        }

        pending = (result.frequency, result.confidence, 1)
        // Keep the established contour visible while asking for one matching
        // follow-up frame.  The reduced confidence makes the held point
        // inspectable without drawing an artificial gap.
        return (previous, min(result.confidence, 0.55))
    }

    mutating func reset() {
        publishedFrequency = nil
        pending = nil
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

enum LivePitchEngine: String, CaseIterable, Identifiable {
    case yin
    case autocorrelation
    case candidateV2
    case vpmLike
    case hapt
    case unified

    var id: String { rawValue }
    var title: String {
        switch self {
        case .yin: return "YIN v1"
        case .autocorrelation: return "Öz-ilinti"
        case .candidateV2: return "Pitch Engine v2"
        case .vpmLike: return "VPM-benzeri"
        case .hapt: return "Harmonik-Faz (HAPT)"
        case .unified: return "Birleşik (Unified v1)"
        }
    }

    var reportIdentifier: String {
        switch self {
        case .yin: return "causal_yin_v1"
        case .autocorrelation: return "autocorrelation_experimental"
        case .candidateV2: return "pitch_engine_v2_experimental"
        case .vpmLike: return "yamaoka_vpm_like_experimental"
        case .hapt: return "hapt_v1"
        case .unified: return "unified_v1"
        }
    }

    static var storedUserSelection: LivePitchEngine {
        switch PitchEngineSettings.storedSelection(for: PitchEngineSettings.liveEngineKey) {
        case "pitch_engine_v2": return .candidateV2
        case "vpm_like": return .vpmLike
        case "hapt_v1": return .hapt
        case "unified_v1": return .unified
        default: return .yin
        }
    }

    /// "Birlikte Çal" motoru `togetherEngineKey`'de ayrı saklanır; Dinleme
    /// (`liveEngineKey`) veya Çalma (`studyEngineKey`) seçimlerinden bağımsız.
    static var togetherModeSelection: LivePitchEngine {
        switch PitchEngineSettings.storedSelection(for: PitchEngineSettings.togetherEngineKey) {
        case "pitch_engine_v2": return .candidateV2
        case "vpm_like": return .vpmLike
        case "hapt_v1": return .hapt
        case "unified_v1": return .unified
        default: return .yin
        }
    }
}

enum LiveGraphDisplay: String, CaseIterable, Identifiable {
    case selected
    case yin
    case autocorrelation
    case both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .selected: return "Seçili"
        case .yin: return "YIN"
        case .autocorrelation: return "Öz-ilinti"
        case .both: return "İkisi"
        }
    }
}

// Empirically calibrated timestamp convention difference between the offline
// pYIN reader and KlariVision's centred real-time analysis window.
// This is only the initial display position. Direct-source validation finds
// the actual offset automatically from the two traces before it scores them.
let referencePYINTimeOffset = 0.0

struct VPMLikeParityFrame: Codable {
    let time: Double
    let frequency: Double
    let confidence: Double
}

/// Serialized only by the deterministic test adapter. This is deliberately a
/// separate type from the VPM trace so reports cannot imply a C++ V2 parity
/// that does not exist yet.
struct PitchEngineV2ParityFrame: Codable {
    let time: Double
    let frequency: Double
    let confidence: Double
}

struct PitchEngineV2CandidateDiagnostic: Codable {
    let source: String
    let frequency: Double
    let periodicity: Double
    let agreementSupport: Double
    let primeHarmonicSupport: Double
    let emissionScore: Double
}

struct PitchEngineV2FrameDiagnostic: Codable {
    let time: Double
    let signalEligible: Bool
    let resolvedTime: Double?
    let resolvedSignalEligible: Bool
    let resolvedHighRegisterAgreement: Bool
    let rawFrequency: Double?
    let rawConfidence: Double?
    let publishedFrequency: Double?
    let publishedConfidence: Double?
    let candidates: [PitchEngineV2CandidateDiagnostic]
}

func shippedSwiftVPMLikeParityTrace(
    samples: [Float],
    sampleRate: Double,
    windowSize: Int = 1_536,
    hopSize: Int = 512,
    minimumRMS: Double = 0.015
) -> [VPMLikeParityFrame] {
    LivePitchAnalyzer().vpmLikeParityTrace(
        samples: samples,
        sampleRate: sampleRate,
        windowSize: windowSize,
        hopSize: hopSize,
        minimumRMS: minimumRMS
    )
}

func shippedSwiftPitchEngineV2ParityTrace(
    samples: [Float],
    sampleRate: Double,
    windowSize: Int = 1_536,
    hopSize: Int = 512,
    minimumRMS: Double = 0.015
) -> [PitchEngineV2ParityFrame] {
    LivePitchAnalyzer().pitchEngineV2ParityTrace(
        samples: samples,
        sampleRate: sampleRate,
        windowSize: windowSize,
        hopSize: hopSize,
        minimumRMS: minimumRMS
    )
}

func shippedSwiftPitchEngineV2CandidateDiagnostics(
    samples: [Float],
    sampleRate: Double,
    windowSize: Int = 1_536,
    hopSize: Int = 512,
    minimumRMS: Double = 0.015
) -> [PitchEngineV2FrameDiagnostic] {
    LivePitchAnalyzer().pitchEngineV2CandidateDiagnostics(
        samples: samples,
        sampleRate: sampleRate,
        windowSize: windowSize,
        hopSize: hopSize,
        minimumRMS: minimumRMS
    )
}

final class LivePitchAnalyzer: ObservableObject, @unchecked Sendable {
    @Published private(set) var frames: [LivePitchFrame] = []
    @Published private(set) var yinBenchmarkFrames: [LivePitchFrame] = []
    @Published private(set) var autocorrelationBenchmarkFrames: [LivePitchFrame] = []
    @Published private(set) var currentFrequency: Double?
    @Published private(set) var currentConfidence = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isBenchmarkRunning = false
    @Published private(set) var comparisonAvailable = false
    @Published private(set) var status = "Mikrofonu başlatmaya hazır."
    @Published private(set) var resolution: LiveAnalysisResolution = .vibrato
    @Published private(set) var pitchEngine: LivePitchEngine = .yin
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
    private var processingPitchEngine: LivePitchEngine = .yin
    private var minimumSignalRMS = SignalGateSettings.storedMinimumRMS
    private var signalSettingsObservation: AnyCancellable?
    private var currentFrameSignalEligible = true
    private var recentStableFrequencies: [Double] = []
    private var lastStableFrequency: Double?
    private var pendingLargeJump: (frequency: Double, confidence: Double)?
    private var pendingCausalYINJump: (frequency: Double, confidence: Double, confirmations: Int)?
    // Causal counterpart of pYIN's continuity decision.  Unlike offline
    // Viterbi, it deliberately retains no future frames, so microphone
    // practice remains immediate.
    private var lastCausalYINFrequency: Double?
    // Source-time points withheld during a very short input dropout. They are
    // published only after the same raw YIN contour returns, so a release or
    // a new note never paints the intervening silence as voiced.
    private var pendingCausalYINGapFrames: [LivePitchFrame] = []
    private var resolvedCausalYINGapFrames: [LivePitchFrame] = []
    // Replays of a reference sound must begin independently. Short note gaps
    // keep musical continuity; a longer silence clears it.
    private var consecutiveSilentYINEstimates = 0
    private var recentCausalYINRMSPeak = 0.0
    // V2 owns a five-frame fixed-lag path. At the default 512-sample hop and
    // 48 kHz input this is about 53 ms. Resolved points retain the timestamp
    // of the old source frame, so the graph is not shifted to the right.
    private let v2FixedLagFrames = 5
    private var v2PathFrames: [LivePitchPathFrameV2] = []
    private var v2ResolvedCapturedAt: TimeInterval?
    private var v2ResolvedHighRegisterAgreement = false
    private var v2ResolvedSignalEligible = true
    private var recentV2RMSPeak = 0.0
    private var lastPublishedV2Frame: LivePitchFrame?
    private var pendingV2GapFrames: [LivePitchFrame] = []
    private var v2HarmonicJumpGate = ExperimentalHarmonicJumpGate()
    private var v2LastCandidateDiagnostics: [PitchEngineV2CandidateDiagnostic] = []
    private var v2ResolvedCandidateDiagnostics: [PitchEngineV2CandidateDiagnostic] = []
    // Production V2 is owned by the portable C++ session. The Swift path is
    // retained only as a deterministic transition oracle for parity tests.
    #if !KLARIVISION_SWIFT_PACKAGE
    private var v2CoreSession: OpaquePointer?
    private var productionCoreSession: OpaquePointer?
    #endif
    private var v2CorePublishedFrames: [LivePitchFrame] = []
    private var productionCorePublishedFrames: [LivePitchFrame] = []
    private var usesSwiftV2Reference = false
    // VPM's ACF/spectrum pair can produce a short f/2 island after a valid
    // high contour. Keep it for three matching hops before replacing that
    // contour, mirroring the production C++ tracker.
    private var vpmHarmonicJumpGate = ExperimentalHarmonicJumpGate(requiredConfirmations: 3)
    private var lastPublishedVPMLikeFrame: LivePitchFrame?
    private var pendingVPMLikeGapFrames: [LivePitchFrame] = []
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
        v2CoreSession = kv_v2_session_create(minimumSignalRMS, v2FixedLagFrames)
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
                if let session = self?.v2CoreSession {
                    _ = kv_v2_session_set_minimum_rms(session, updated)
                }
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
        kv_v2_session_destroy(v2CoreSession)
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
        startBenchmark(comparingBothEngines: false)
    }

    /// Runs the live engine on the selected source file's PCM directly. This
    /// removes speaker, room and microphone differences, leaving a clean
    /// comparison against analytic truth when present, otherwise pYIN.
    func runSourceBenchmark() {
        guard let source = referenceTestSourceURL else {
            status = "Önce Kaynakla Test ile karşılaştırılacak dosyayı seç."
            return
        }
        startBenchmark(comparingBothEngines: false, sourceURL: source)
    }

    /// Development verification path: the selected file is fed directly to
    /// the real-time engine while the exact same source is compared with its
    /// analytic truth when available, otherwise offline pYIN. There is no
    /// speaker, room, or microphone in this path.
    /// It is intentionally separate from normal live practice so it cannot
    /// change what a musician sees in day-to-day use.
    func validateSourceDirectly(with url: URL, engine: LivePitchEngine = .yin) {
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

    /// Feeds the exact same reference samples to YIN and autocorrelation.  It
    /// is deliberately separate from microphone practice: two curves then
    /// differ only because of the pitch engines, not speakers or a room.
    func runBenchmarkComparison() {
        startBenchmark(comparingBothEngines: true)
    }

    private func startBenchmark(comparingBothEngines: Bool, sourceURL: URL? = nil) {
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
            yinBenchmarkFrames.removeAll(keepingCapacity: true)
            autocorrelationBenchmarkFrames.removeAll(keepingCapacity: true)
            comparisonAvailable = comparingBothEngines
            currentFrequency = nil
            currentConfidence = 0
            if sourceURL != nil {
                referenceTestStartedAt = Date().timeIntervalSinceReferenceDate
                referenceTimelineEnd = nil
            }
            isRunning = true
            isBenchmarkRunning = true
            status = comparingBothEngines
                ? "Karşılaştırmalı motor testi çalışıyor · Mikrofon kullanılmıyor."
                : sourceURL == nil
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
                    if comparingBothEngines {
                        self?.processComparison(samples: chunk, sampleRate: sampleRate)
                    } else {
                        self?.process(samples: chunk, sampleRate: sampleRate, capturedAt: sourceFrameTime)
                    }
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
        recentStableFrequencies.removeAll(keepingCapacity: true)
        lastStableFrequency = nil
        pendingLargeJump = nil
        pendingCausalYINJump = nil
        lastCausalYINFrequency = nil
        pendingCausalYINGapFrames.removeAll(keepingCapacity: true)
        resolvedCausalYINGapFrames.removeAll(keepingCapacity: true)
        consecutiveSilentYINEstimates = 0
        recentCausalYINRMSPeak = 0
        v2PathFrames.removeAll(keepingCapacity: true)
        v2ResolvedCapturedAt = nil
        v2ResolvedSignalEligible = true
        currentFrameSignalEligible = true
        recentV2RMSPeak = 0
        lastPublishedV2Frame = nil
        pendingV2GapFrames.removeAll(keepingCapacity: true)
        v2HarmonicJumpGate.reset()
        v2LastCandidateDiagnostics.removeAll(keepingCapacity: true)
        v2ResolvedCandidateDiagnostics.removeAll(keepingCapacity: true)
        v2CorePublishedFrames.removeAll(keepingCapacity: true)
        productionCorePublishedFrames.removeAll(keepingCapacity: true)
        #if !KLARIVISION_SWIFT_PACKAGE
        kv_v2_session_destroy(v2CoreSession)
        v2CoreSession = kv_v2_session_create(minimumSignalRMS, v2FixedLagFrames)
        kv_production_pitch_session_destroy(productionCoreSession)
        productionCoreSession = kv_production_pitch_session_create(
            Self.coreEngineID(for: processingPitchEngine), minimumSignalRMS
        )
        #endif
        vpmHarmonicJumpGate.reset()
        lastPublishedVPMLikeFrame = nil
        pendingVPMLikeGapFrames.removeAll(keepingCapacity: true)
    }

    #if !KLARIVISION_SWIFT_PACKAGE
    private static func coreEngineID(for engine: LivePitchEngine) -> Int32 {
        switch engine {
        case .yin: return Int32(KV_ENGINE_YIN_V1)
        case .candidateV2: return Int32(KV_ENGINE_V2)
        case .vpmLike: return Int32(KV_ENGINE_VPM_LIKE)
        case .autocorrelation: return Int32(KV_ENGINE_YIN_V1)
        case .hapt: return Int32(KV_ENGINE_HAPT_V1)
        case .unified: return Int32(KV_ENGINE_UNIFIED_V1)
        }
    }
    #endif

    /// Deterministic adapter around the shipped Swift VPM-like publication
    /// path. The parity harness uses this instead of maintaining a second
    /// Swift copy of the estimator. Timestamps identify the centre of the
    /// source analysis window; no decision-latency shift is applied.
    fileprivate func vpmLikeParityTrace(
        samples: [Float],
        sampleRate: Double,
        windowSize: Int = 1_536,
        hopSize: Int = 512,
        minimumRMS: Double = 0.015
    ) -> [VPMLikeParityFrame] {
        guard sampleRate > 0, windowSize >= 1_024, hopSize > 0,
              samples.count >= windowSize else { return [] }
        resetProcessingState()
        minimumSignalRMS = minimumRMS
        processingPitchEngine = .vpmLike

        var trace: [VPMLikeParityFrame] = []
        var end = windowSize
        while end <= samples.count {
            let window = Array(samples[(end - windowSize)..<end])
            let sourceTime = (Double(end) - Double(windowSize) / 2) / sampleRate
            let result = estimateLivePitch(
                samples: window,
                sampleRate: sampleRate,
                engine: .vpmLike,
                capturedAt: sourceTime
            )
            let bridged = resolveShortVPMLikeGap(
                result: result,
                capturedAt: sourceTime,
                signalEligible: currentFrameSignalEligible
            )
            trace.append(contentsOf: bridged.map {
                VPMLikeParityFrame(
                    time: $0.time,
                    frequency: $0.frequency,
                    confidence: $0.confidence
                )
            })
            if let result {
                trace.append(VPMLikeParityFrame(
                    time: sourceTime,
                    frequency: result.frequency,
                    confidence: result.confidence
                ))
            }
            end += hopSize
        }
        return trace
    }

    /// Deterministic adapter around the shipped Swift V2 publication path.
    /// Its result is compared to the Python benchmark mirror, not to C++:
    /// V2's complete portable production implementation is not present yet.
    fileprivate func pitchEngineV2ParityTrace(
        samples: [Float],
        sampleRate: Double,
        windowSize: Int = 1_536,
        hopSize: Int = 512,
        minimumRMS: Double = 0.015
    ) -> [PitchEngineV2ParityFrame] {
        guard sampleRate > 0, windowSize >= 1_024, hopSize > 0,
              samples.count >= windowSize else { return [] }
        resetProcessingState()
        minimumSignalRMS = minimumRMS
        processingPitchEngine = .candidateV2
        usesSwiftV2Reference = true
        defer { usesSwiftV2Reference = false }

        var trace: [PitchEngineV2ParityFrame] = []
        var end = windowSize
        while end <= samples.count {
            let window = Array(samples[(end - windowSize)..<end])
            let sourceTime = (Double(end) - Double(windowSize) / 2) / sampleRate
            let result = estimateLivePitch(
                samples: window,
                sampleRate: sampleRate,
                engine: .candidateV2,
                capturedAt: sourceTime
            )
            let bridged = resolveShortV2Gap(
                result: result,
                capturedAt: v2ResolvedCapturedAt,
                signalEligible: v2ResolvedSignalEligible
            )
            trace.append(contentsOf: bridged.map {
                PitchEngineV2ParityFrame(
                    time: $0.time,
                    frequency: $0.frequency,
                    confidence: $0.confidence
                )
            })
            if let result, let resolvedAt = v2ResolvedCapturedAt {
                trace.append(PitchEngineV2ParityFrame(
                    time: resolvedAt,
                    frequency: result.frequency,
                    confidence: result.confidence
                ))
            }
            end += hopSize
        }
        return trace
    }

    fileprivate func pitchEngineV2CandidateDiagnostics(
        samples: [Float],
        sampleRate: Double,
        windowSize: Int = 1_536,
        hopSize: Int = 512,
        minimumRMS: Double = 0.015
    ) -> [PitchEngineV2FrameDiagnostic] {
        guard sampleRate > 0, windowSize >= 1_024, hopSize > 0,
              samples.count >= windowSize else { return [] }
        resetProcessingState()
        minimumSignalRMS = minimumRMS
        processingPitchEngine = .candidateV2
        usesSwiftV2Reference = true
        defer { usesSwiftV2Reference = false }

        var diagnostics: [PitchEngineV2FrameDiagnostic] = []
        var end = windowSize
        while end <= samples.count {
            let window = Array(samples[(end - windowSize)..<end])
            let sourceTime = (Double(end) - Double(windowSize) / 2) / sampleRate
            let result = estimateLivePitch(
                samples: window,
                sampleRate: sampleRate,
                engine: .candidateV2,
                capturedAt: sourceTime
            )
            diagnostics.append(PitchEngineV2FrameDiagnostic(
                time: sourceTime,
                signalEligible: currentFrameSignalEligible,
                resolvedTime: v2ResolvedCapturedAt,
                resolvedSignalEligible: v2ResolvedSignalEligible,
                resolvedHighRegisterAgreement: v2ResolvedHighRegisterAgreement,
                rawFrequency: nil,
                rawConfidence: nil,
                publishedFrequency: result?.frequency,
                publishedConfidence: result?.confidence,
                candidates: v2ResolvedCandidateDiagnostics
            ))
            _ = resolveShortV2Gap(
                result: result,
                capturedAt: v2ResolvedCapturedAt,
                signalEligible: v2ResolvedSignalEligible
            )
            end += hopSize
        }
        return diagnostics
    }

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
        comparisonAvailable = false
        yinBenchmarkFrames.removeAll(keepingCapacity: true)
        autocorrelationBenchmarkFrames.removeAll(keepingCapacity: true)
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
        let resolvedGapFrames = currentPitchEngine == .yin ? resolvedCausalYINGapFrames : []
        resolvedCausalYINGapFrames.removeAll(keepingCapacity: true)
        let resolvedAt = currentPitchEngine == .candidateV2 ? v2ResolvedCapturedAt : capturedAt
        let resolvedV2GapFrames = currentPitchEngine == .candidateV2
            ? (usesSwiftV2Reference ? resolveShortV2Gap(
                result: result,
                capturedAt: resolvedAt,
                signalEligible: v2ResolvedSignalEligible
            ) : v2CorePublishedFrames)
            : []
        v2CorePublishedFrames.removeAll(keepingCapacity: true)
        let resolvedVPMLikeGapFrames = currentPitchEngine == .vpmLike
            ? resolveShortVPMLikeGap(
                result: result,
                capturedAt: capturedAt,
                signalEligible: currentFrameSignalEligible
            )
            : []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if currentPitchEngine != .autocorrelation, self.usesProductionCore {
                self.appendProductionFrames(productionFrames)
                return
            }
            for frame in resolvedGapFrames {
                self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
            }
            for frame in resolvedV2GapFrames {
                self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
            }
            for frame in resolvedVPMLikeGapFrames {
                self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
            }
            self.append(result, capturedAt: resolvedAt)
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
                let resolvedGapFrames = engine == .yin ? self.resolvedCausalYINGapFrames : []
                self.resolvedCausalYINGapFrames.removeAll(keepingCapacity: true)
                let resolvedAt = engine == .candidateV2 ? self.v2ResolvedCapturedAt : frameTime
                let resolvedV2GapFrames = engine == .candidateV2
                    ? (self.usesSwiftV2Reference ? self.resolveShortV2Gap(
                        result: result,
                        capturedAt: resolvedAt,
                        signalEligible: self.v2ResolvedSignalEligible
                    ) : self.v2CorePublishedFrames)
                    : []
                self.v2CorePublishedFrames.removeAll(keepingCapacity: true)
                let resolvedVPMLikeGapFrames = engine == .vpmLike
                    ? self.resolveShortVPMLikeGap(
                        result: result,
                        capturedAt: frameTime,
                        signalEligible: self.currentFrameSignalEligible
                    )
                    : []
                let calculationMilliseconds = (ProcessInfo.processInfo.systemUptime - calculationStartedAt) * 1_000
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentLiveRun(runID) else { return }
                    self.recordLivePerformance(calculationMilliseconds: calculationMilliseconds)
                    if engine != .autocorrelation, self.usesProductionCore {
                        self.appendProductionFrames(productionFrames)
                        return
                    }
                    for frame in productionFrames {
                        self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
                    }
                    for frame in resolvedGapFrames {
                        self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
                    }
                    for frame in resolvedV2GapFrames {
                        self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
                    }
                    for frame in resolvedVPMLikeGapFrames {
                        self.append((frame.frequency, frame.confidence), capturedAt: frame.time)
                    }
                    self.append(result, capturedAt: resolvedAt)
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

    private func processComparison(samples: [Float], sampleRate: Double) {
        let currentResolution = processingResolution
        let selectedEngine = processingPitchEngine
        sampleWindow.append(contentsOf: samples)
        if sampleWindow.count > currentResolution.windowSize {
            sampleWindow.removeFirst(sampleWindow.count - currentResolution.windowSize)
        }
        samplesSinceLastEstimate += samples.count
        guard sampleWindow.count >= currentResolution.windowSize,
              samplesSinceLastEstimate >= currentResolution.hopSize else { return }
        samplesSinceLastEstimate = 0

        // Each estimate reads the identical accumulated window at the same
        // instant. YIN keeps its normal stabilizer; autocorrelation remains
        // intentionally raw, exactly as it behaves in microphone practice.
        let rms = Self.centeredRMS(sampleWindow)
        SignalLevelMonitor.publish(rms: rms)
        let eligible = rms >= minimumSignalRMS
        let yin = eligible ? stabilize(
            Self.estimatePitch(samples: sampleWindow, sampleRate: sampleRate, engine: .yin),
            engine: .yin
        ) : nil
        let autocorrelation = eligible ? Self.estimatePitch(
            samples: sampleWindow,
            sampleRate: sampleRate,
            engine: .autocorrelation
        ) : nil
        DispatchQueue.main.async { [weak self] in
            self?.appendComparison(yin: yin, autocorrelation: autocorrelation, selectedEngine: selectedEngine)
        }
    }

    private func estimateLivePitch(
        samples: [Float],
        decisionSamples: [Float]? = nil,
        sampleRate: Double,
        engine: LivePitchEngine,
        capturedAt: TimeInterval? = nil
    ) -> (frequency: Double, confidence: Double)? {
        let frameRMS = Self.centeredRMS(samples)
        SignalLevelMonitor.publish(rms: frameRMS)
        let signalEligible = frameRMS >= minimumSignalRMS
        currentFrameSignalEligible = signalEligible
        #if !KLARIVISION_SWIFT_PACKAGE
        if engine != .autocorrelation, !usesSwiftV2Reference {
            return estimateProductionPitchCore(
                samples: samples,
                sampleRate: sampleRate,
                capturedAt: capturedAt,
                engine: engine
            )
        }
        #endif
        if !signalEligible {
            switch engine {
            case .candidateV2:
                return estimatePitchV2(
                    samples: samples,
                    sampleRate: sampleRate,
                    capturedAt: capturedAt,
                    signalEligible: false
                )
            case .yin:
                pendingCausalYINGapFrames.removeAll(keepingCapacity: true)
                resolvedCausalYINGapFrames.removeAll(keepingCapacity: true)
                consecutiveSilentYINEstimates += 1
            case .vpmLike:
                pendingVPMLikeGapFrames.removeAll(keepingCapacity: true)
                _ = vpmHarmonicJumpGate.filter(nil)
            case .autocorrelation, .hapt, .unified:
                break
            }
            return nil
        }
        if engine == .candidateV2 {
            let result = estimatePitchV2(
                samples: samples,
                sampleRate: sampleRate,
                capturedAt: capturedAt,
                signalEligible: true
            )
            // V2 emission scores below this boundary are concentrated at the
            // synthetic holdout's note edges and room-noise-only gaps. Keep
            // them available to the internal path, but do not publish them as
            // musician-facing pitch points.
            guard let result, result.confidence >= 0.70,
                  result.frequency <= 900 || v2ResolvedHighRegisterAgreement else { return nil }
            return stabilizeExperimentalHarmonicJump(result, engine: engine)
        }
        if engine == .vpmLike {
            // Keep the shipped Swift publication contract identical to the
            // canonical C++ trace: the calibrated frame estimator must clear
            // the 0.80 output gate, then the three-confirmation causal guard
            // may hold only a downward 1/3, 1/2 or 2/3 harmonic jump.
            let estimate = Self.estimatePitchVPMLike(
                samples: samples,
                sampleRate: sampleRate
            ).flatMap { $0.confidence >= 0.80 ? $0 : nil }
            return stabilizeExperimentalHarmonicJump(estimate, engine: engine)
        }
        guard engine == .yin else {
            return stabilizeExperimentalHarmonicJump(
                Self.estimatePitch(samples: samples, sampleRate: sampleRate, engine: engine),
                engine: engine
            )
        }

        resolvedCausalYINGapFrames.removeAll(keepingCapacity: true)

        let candidates = Self.yinCandidates(samples: samples, sampleRate: sampleRate)
        let confident = candidates.filter { $0.confidence >= 0.76 }
        // During a real performance, a quiet note, breathy attack or room
        // reflection can temporarily reduce YIN's periodicity score without
        // removing the musical fundamental.  Once a contour exists, retain
        // these usable candidates so continuity can make the best decision.
        // The stricter `confident` set is still used when a new contour starts.
        var usable = candidates.filter { $0.confidence >= 0.55 }
        let windowRMS = Self.centeredRMS(samples)
        recentCausalYINRMSPeak = max(windowRMS, recentCausalYINRMSPeak * 0.85)
        // A room tail can remain weakly periodic for a few hops after release.
        // Suppress it only when confidence has fallen below the normal gate
        // and energy has collapsed relative to the immediately preceding
        // contour. A quiet steady note ages the short peak out normally.
        let strongestConfidence = candidates.map(\.confidence).max() ?? 0
        if !usable.isEmpty, strongestConfidence < 0.90,
           windowRMS < recentCausalYINRMSPeak * 0.35 {
            usable.removeAll()
        }
        guard !usable.isEmpty else {
            consecutiveSilentYINEstimates += 1
            if let previous = lastCausalYINFrequency,
               let capturedAt,
               pendingCausalYINGapFrames.count < 7 {
                pendingCausalYINGapFrames.append(
                    LivePitchFrame(time: capturedAt, frequency: previous, confidence: 0.55)
                )
            } else {
                pendingCausalYINGapFrames.removeAll(keepingCapacity: true)
            }
            // With the fixed high-detail mode this is roughly one third of a
            // second. It separates independent takes without breaking normal
            // inter-note gaps and preserves the next take's first low note.
            if consecutiveSilentYINEstimates >= 30 {
                lastCausalYINFrequency = nil
                pendingCausalYINJump = nil
                pendingCausalYINGapFrames.removeAll(keepingCapacity: true)
            }
            return nil
        }
        consecutiveSilentYINEstimates = 0
        let windowEnergyScale = samples.reduce(0.0) { $0 + Double($1 * $1) } * Double(samples.count)

        func supportedUpperRegisterMate(
            above baseFrequency: Double
        ) -> (frequency: Double, confidence: Double)? {
            var supported: [(energy: Double, frequency: Double, confidence: Double)] = []
            for candidate in usable {
                let candidateEnergy = Self.spectralToneEnergy(
                    samples: samples,
                    sampleRate: sampleRate,
                    frequency: candidate.frequency
                )
                for factor in [3.0, 2.0] {
                    let upper = candidate.frequency * factor
                    guard upper > max(900, baseFrequency), upper <= 1_500 else { continue }
                    let upperEnergy = Self.spectralToneEnergy(
                        samples: samples,
                        sampleRate: sampleRate,
                        frequency: upper
                    )
                    if upperEnergy > max(candidateEnergy * 80, windowEnergyScale * 0.008) {
                        supported.append((upperEnergy, upper, candidate.confidence))
                    }
                }
            }
            guard let strongest = supported.max(by: { $0.energy < $1.energy }) else { return nil }
            return (strongest.frequency, strongest.confidence)
        }

        let selected: (frequency: Double, confidence: Double)
        if let previous = lastCausalYINFrequency {
            func distance(_ frequency: Double) -> Double {
                abs(1_200 * log2(frequency / previous))
            }
            func score(_ candidate: (frequency: Double, confidence: Double)) -> Double {
                // Retain a weaker candidate when it forms a smooth musical
                // continuation. This prevents the strong 2nd harmonic around
                // 110–150 Hz and the strong subharmonic above 880 Hz from
                // displacing the actual fundamental for a single hop.
                candidate.confidence - 0.30 * min(distance(candidate.frequency) / 700, 1)
            }
            let continuityCandidates = usable
            var best = continuityCandidates.max { score($0) < score($1) }
                ?? confident.max { score($0) < score($1) }!
            var spectrallyConfirmedJump = false

            func longHistorySupportsUpper(lower: Double, upper: Double) -> Bool {
                guard let decisionSamples,
                      decisionSamples.count >= causalDecisionWindowSize else { return false }
                let longer = Self.yinCandidates(samples: decisionSamples, sampleRate: sampleRate)
                    .filter { $0.confidence >= 0.55 }
                let lowerConfidence = longer
                    .filter { abs(1_200 * log2($0.frequency / lower)) < 90 }
                    .map(\.confidence).max() ?? 0
                guard let upperConfidence = longer
                    .filter({ abs(1_200 * log2($0.frequency / upper)) < 90 })
                    .map(\.confidence).max() else { return false }
                return upperConfidence >= lowerConfidence - 0.06
            }

            func overwhelmingSpectralUpper(lower: Double, upper: Double) -> Bool {
                guard let decisionSamples,
                      decisionSamples.count >= causalDecisionWindowSize else { return false }
                let shortLower = Self.spectralToneEnergy(
                    samples: samples, sampleRate: sampleRate, frequency: lower
                )
                let shortUpper = Self.spectralToneEnergy(
                    samples: samples, sampleRate: sampleRate, frequency: upper
                )
                let longLower = Self.spectralToneEnergy(
                    samples: decisionSamples, sampleRate: sampleRate, frequency: lower
                )
                let longUpper = Self.spectralToneEnergy(
                    samples: decisionSamples, sampleRate: sampleRate, frequency: upper
                )
                return shortUpper / max(shortLower, 0.000_000_001) >= 500 &&
                    longUpper / max(longLower, 0.000_000_001) >= 500
            }

            // YIN can regard a clarinet tone as periodic at a simple harmonic
            // fraction of its real period. Alongside octave errors, the
            // speaker → microphone path can produce 2/3× and 3/2× choices
            // from the instrument's strong odd harmonics (for example,
            // 220 Hz being reported near 147 Hz). Compare a small set of
            // harmonic mates only when one continues the previous contour.
            // Thus ordinary glissando remains untouched.
            func isNearPrevious(_ frequency: Double) -> Bool {
                abs(1_200 * log2(frequency / previous)) < 300
            }
            let baseEnergy = Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: best.frequency)
            for factor in [2.0, 3.0, 1.5, 2.0 / 3.0, 0.5, 1.0 / 3.0] {
                let mate = best.frequency * factor
                guard mate >= 80, mate <= 1_500, isNearPrevious(mate) else { continue }
                if Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: mate) > baseEnergy * 0.55 {
                    best = (mate, best.confidence)
                    break
                }
            }

            // Do not let continuity hide a real leap into the upper clarinet
            // register.  On the Şükrü Tunar reference, for example, YIN sees
            // both a 150 Hz sub-period and a much stronger, persistent
            // 600 Hz fundamental. The continuity score previously kept the
            // 150 Hz candidate forever. A real clarinet fundamental can be
            // slightly weaker than its sub-period, particularly through a
            // phone speaker or room microphone. Promote only an *upward*,
            // still-high-confidence candidate here; the three-frame gate
            // below still rejects a one-hop harmonic spike.
            let selectedBaseEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: best.frequency
            )
            let upperRegisterEvidence = usable.filter {
                $0.frequency > best.frequency &&
                distance($0.frequency) > 900
            }
            let supportedUpper = upperRegisterEvidence.filter {
                let upperEnergy = Self.spectralToneEnergy(
                    samples: samples, sampleRate: sampleRate, frequency: $0.frequency
                )
                return upperEnergy > max(selectedBaseEnergy * 12, windowEnergyScale * 0.005) &&
                    (longHistorySupportsUpper(lower: best.frequency, upper: $0.frequency) ||
                     overwhelmingSpectralUpper(lower: best.frequency, upper: $0.frequency))
            }
            if let upper = supportedUpper.max(by: {
                Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $0.frequency) <
                    Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $1.frequency)
            }) {
                best = upper
                spectrallyConfirmedJump = true
            }

            // The upper candidate may be usable but narrowly miss the normal
            // confidence set at a real register entry. Accept it only when
            // both the short spectrum and the longer causal history agree.
            let selectedEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: best.frequency
            )
            let octaveCandidates = usable.filter {
                let ratio = $0.frequency / best.frequency
                return ratio >= 1.85 && ratio <= 2.15 &&
                    $0.confidence >= best.confidence - 0.25 &&
                    Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $0.frequency) >
                        max(selectedEnergy * 12, windowEnergyScale * 0.005) &&
                    longHistorySupportsUpper(lower: best.frequency, upper: $0.frequency)
            }
            if let upper = octaveCandidates.max(by: {
                Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $0.frequency) <
                    Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $1.frequency)
            }) {
                best = upper
                spectrallyConfirmedJump = true
            }

            // Speaker → room → microphone playback can make a subharmonic
            // look slightly more periodic than the real clarinet fundamental.
            // When a plausible candidate remains close to the previous note,
            // keep it unless the distant candidate has materially stronger
            // evidence. If no nearby candidate exists, a genuine low-note or
            // octave change is still accepted immediately.
            let bestDistance = distance(best.frequency)
            if bestDistance > 650, !spectrallyConfirmedJump {
                let nearby = continuityCandidates.filter { distance($0.frequency) < 350 }
                if let stable = nearby.max(by: { $0.confidence < $1.confidence }),
                   stable.confidence >= best.confidence - 0.12 {
                    best = stable
                }
            }
            // A short-period subharmonic can be the only YIN candidate at a
            // descending clarinet phrase onset. Ask the independent
            // autocorrelation estimator only in this narrow ambiguity; the
            // ordinary low-latency YIN path remains unchanged everywhere else.
            if best.frequency < 220, distance(best.frequency) > 650,
               let autocorrelation = Self.estimatePitchAutocorrelation(samples: samples, sampleRate: sampleRate),
               autocorrelation.frequency > best.frequency * 1.75,
               autocorrelation.confidence >= 0.52 {
                best = autocorrelation
            }
            // A lost high-register fundamental can leave only a strong
            // subharmonic for one analysis hop. Do not publish that isolated
            // octave-scale jump; a real note change remains accepted on the
            // immediately following matching frame (about 11 ms later).
            if let rescuedUpper = supportedUpperRegisterMate(above: best.frequency) {
                best = rescuedUpper
                spectrallyConfirmedJump = true
            }
            let selectedDistance = distance(best.frequency)
            if selectedDistance > 900, abs(1_200 * log2(best.frequency / previous)) > 900 {
                // A vibrato can briefly make YIN alternate between a high
                // fundamental and its 1/2 or 2× harmonic. Require three
                // neighbouring estimates before publishing an octave-scale
                // change. A normal glissando never enters this branch: its
                // successive steps are much smaller than an octave.
                if var pending = pendingCausalYINJump,
                   abs(1_200 * log2(best.frequency / pending.frequency)) < 360 {
                    pending.confirmations += 1
                    if pending.confirmations < 3 {
                        pendingCausalYINJump = pending
                        return nil
                    }
                    pendingCausalYINJump = nil
                } else {
                    pendingCausalYINJump = (best.frequency, best.confidence, 1)
                    return nil
                }
            } else {
                pendingCausalYINJump = nil
            }
            selected = best
        } else {
            selected = confident.max { $0.confidence < $1.confidence }
                ?? usable.max { $0.confidence < $1.confidence }!
        }

        // Clarinet has strong odd harmonics. YIN can therefore report 3f at
        // a low-note attack, or f/3 in the high register. Resolve only these
        // overwhelming spectral cases; ordinary note transitions and
        // vibrato remain governed by the causal continuity logic above.
        var corrected = selected
        var selectedEnergy = Self.spectralToneEnergy(
            samples: samples, sampleRate: sampleRate, frequency: corrected.frequency
        )
        let lowerFundamentals = usable.filter {
            let ratio = corrected.frequency / $0.frequency
            return (ratio >= 1.85 && ratio <= 2.15 || ratio >= 2.85 && ratio <= 3.15) &&
                Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $0.frequency) >
                    selectedEnergy * 1.8
        }
        let isContinuousUpperContour: Bool
        if let previous = lastCausalYINFrequency {
            isContinuousUpperContour = abs(1_200 * log2(corrected.frequency / previous)) <= 300
        } else {
            isContinuousUpperContour = false
        }
        if !isContinuousUpperContour, let lower = lowerFundamentals.max(by: {
            Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $0.frequency) <
                Self.spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: $1.frequency)
        }) {
            corrected = lower
            selectedEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: lower.frequency
            )
        }

        // A hidden fundamental can leave nearly equal periodicities at f and
        // 2f. If the active contour has fallen to f, recover 2f only when it
        // is independently present in YIN with similar confidence and its
        // measured spectral line is decisively stronger. This is deliberately
        // narrower than a general spectral promotion rule.
        var octaveRecoveries: [(energy: Double, frequency: Double, confidence: Double)] = []
        for lower in usable {
            let upper = lower.frequency * 2
            guard upper > corrected.frequency * 1.5, upper <= 900 else { continue }
            let upperConfidence = usable
                .filter { abs(1_200 * log2($0.frequency / upper)) <= 55 }
                .map(\.confidence)
                .max()
            guard let upperConfidence, upperConfidence >= lower.confidence - 0.05 else { continue }
            let lowerEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: lower.frequency
            )
            let upperEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: upper
            )
            if upperEnergy > lowerEnergy * 3 {
                octaveRecoveries.append((upperEnergy, upper, upperConfidence))
            }
        }
        if let recovery = octaveRecoveries.max(by: { $0.energy < $1.energy }) {
            corrected = (recovery.frequency, recovery.confidence)
            selectedEnergy = recovery.energy
        }

        if let rescuedUpper = supportedUpperRegisterMate(above: corrected.frequency) {
            corrected = rescuedUpper
        }

        if !pendingCausalYINGapFrames.isEmpty {
            let rawContourReturned: Bool
            if let previous = lastCausalYINFrequency {
                rawContourReturned = candidates.contains {
                    $0.confidence >= 0.55 && abs(1_200 * log2($0.frequency / previous)) <= 90
                } && abs(1_200 * log2(corrected.frequency / previous)) <= 90
            } else {
                rawContourReturned = false
            }
            if rawContourReturned {
                resolvedCausalYINGapFrames = pendingCausalYINGapFrames
            }
            pendingCausalYINGapFrames.removeAll(keepingCapacity: true)
        }

        lastCausalYINFrequency = corrected.frequency
        return corrected
    }

    private func stabilizeExperimentalHarmonicJump(
        _ result: (frequency: Double, confidence: Double)?,
        engine: LivePitchEngine
    ) -> (frequency: Double, confidence: Double)? {
        switch engine {
        case .candidateV2:
            return v2HarmonicJumpGate.filter(result)
        case .vpmLike:
            return vpmHarmonicJumpGate.filter(result)
        case .yin, .autocorrelation, .hapt, .unified:
            return result
        }
    }

    #if !KLARIVISION_SWIFT_PACKAGE
    /// Production boundary shared by microphone and Study analysis. C++ owns
    /// the causal publication and any returned short-gap frames for all three
    /// user-facing pitch engines.
    private func estimateProductionPitchCore(
        samples: [Float],
        sampleRate: Double,
        capturedAt: TimeInterval?,
        engine: LivePitchEngine
    ) -> (frequency: Double, confidence: Double)? {
        productionCorePublishedFrames.removeAll(keepingCapacity: true)
        guard engine != .autocorrelation, let session = productionCoreSession,
              sampleRate > 0 else { return nil }
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

    /// Production V2 boundary. C++ owns candidate generation, fixed-lag
    /// resolution, publication protection and the short-gap bridge.
    private func estimatePitchV2Core(
        samples: [Float],
        sampleRate: Double,
        capturedAt: TimeInterval?
    ) -> (frequency: Double, confidence: Double)? {
        v2CorePublishedFrames.removeAll(keepingCapacity: true)
        v2ResolvedCapturedAt = nil
        guard let session = v2CoreSession, sampleRate > 0 else { return nil }
        let sourceTime = (capturedAt ?? 0) - Double(samples.count) / (2 * sampleRate)
        let processed = samples.withUnsafeBufferPointer { buffer in
            kv_v2_session_process_frame(
                session, buffer.baseAddress, buffer.count, sampleRate, sourceTime
            )
        }
        guard processed != 0 else { return nil }
        for index in 0..<kv_v2_session_output_count(session) {
            var frame = kv_pitch_frame()
            guard kv_v2_session_output_frame(session, index, &frame) != 0 else { continue }
            v2CorePublishedFrames.append(LivePitchFrame(
                time: frame.time_seconds,
                frequency: frame.frequency_hz,
                confidence: frame.confidence
            ))
        }
        return nil
    }
    #endif

    /// Swift transition oracle for V2 parity tests. Production selection goes
    /// through `estimatePitchV2Core`; this implementation is not user-facing.
    /// independent autocorrelation observation plus MPM/NSDF peaks, rewards
    /// cross-engine agreement and uses temporal memory owned only by V2.
    /// SWIPE'-like prime-harmonic support is followed by a five-frame,
    /// fixed-lag path decision. V1 remains fully independent.
    private func estimatePitchV2(
        samples: [Float],
        sampleRate: Double,
        capturedAt: TimeInterval?,
        signalEligible: Bool
    ) -> (frequency: Double, confidence: Double)? {
        let windowRMS = Self.centeredRMS(samples)
        recentV2RMSPeak = max(windowRMS, recentV2RMSPeak * 0.85)
        guard signalEligible else {
            v2LastCandidateDiagnostics.removeAll(keepingCapacity: true)
            return resolvePitchPathV2(
                candidates: [], capturedAt: capturedAt, signalEligible: false
            )
        }
        // Keep a small analysis guard band above the displayed 1500 Hz range.
        // At the boundary, the true period must not be excluded before the V2
        // path can compare it with its f/2 sub-period.
        var candidates = Self.yinCandidates(
            samples: samples, sampleRate: sampleRate, maximumFrequency: 1_650
        )
            .filter { $0.confidence >= 0.50 }
            .map {
                LivePitchCandidateV2(
                    frequency: $0.frequency,
                    periodicity: $0.confidence,
                    agreementSupport: 0.25,
                    primeHarmonicSupport: 0,
                    source: .yin
                )
            }

        // V2 evaluates this candidate together with YIN and MPM. Do not apply
        // the standalone high-register publication gate here: the path scorer
        // will require cross-estimator agreement before a weak candidate wins.
        if let autocorrelation = Self.estimatePitchAutocorrelation(
            samples: samples,
            sampleRate: sampleRate,
            appliesHighRegisterGate: false
        ) {
            candidates.append(LivePitchCandidateV2(
                frequency: autocorrelation.frequency,
                periodicity: autocorrelation.confidence,
                agreementSupport: 0.25,
                primeHarmonicSupport: 0,
                source: .autocorrelation
            ))
        }

        candidates.append(contentsOf: Self.estimatePitchMPMCandidates(
            samples: samples,
            sampleRate: sampleRate
        ).map {
            LivePitchCandidateV2(
                frequency: $0.frequency,
                periodicity: $0.confidence,
                agreementSupport: 0.25,
                primeHarmonicSupport: 0,
                source: .mpm
            )
        })

        let strongestPeriodicity = candidates.map(\.periodicity).max() ?? 0
        if strongestPeriodicity < 0.90, windowRMS < recentV2RMSPeak * 0.35 {
            candidates.removeAll()
        }

        let spectralPartners = candidates.compactMap { candidate -> LivePitchCandidateV2? in
            let upper = candidate.frequency * 2
            guard upper > 900, upper <= 1_650 else { return nil }
            let lowerEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: candidate.frequency
            )
            let upperEnergy = Self.spectralToneEnergy(
                samples: samples, sampleRate: sampleRate, frequency: upper
            )
            guard upperEnergy > lowerEnergy * 8 else { return nil }
            return LivePitchCandidateV2(
                frequency: upper,
                periodicity: max(0.92, candidate.periodicity),
                agreementSupport: 0.25,
                primeHarmonicSupport: 0,
                source: .spectral
            )
        }
        candidates.append(contentsOf: spectralPartners)

        guard !candidates.isEmpty else {
            v2LastCandidateDiagnostics.removeAll(keepingCapacity: true)
            return resolvePitchPathV2(
                candidates: [], capturedAt: capturedAt, signalEligible: true
            )
        }

        // Agreement is calculated before selection and retained per candidate.
        // Two independent estimators agreeing within 55 cents is stronger
        // evidence than either estimator's single highest peak.
        candidates = candidates.map { candidate in
            let agrees = candidates.contains { other in
                other.source != candidate.source &&
                    abs(1_200 * log2(other.frequency / candidate.frequency)) <= 55
            }
            return LivePitchCandidateV2(
                frequency: candidate.frequency,
                periodicity: candidate.periodicity,
                agreementSupport: agrees ? 1.0 : candidate.agreementSupport,
                primeHarmonicSupport: candidate.primeHarmonicSupport,
                source: candidate.source
            )
        }

        // One FFT is shared by every candidate. The lightweight SWIPE'-like
        // kernel rewards the first and prime harmonics and normalizes against
        // energy at all integer harmonics, reducing f/2 and f/3 choices that
        // explain only a subset of the observed clarinet spectrum.
        let primeSupports = Self.swipePrimeHarmonicSupports(
            samples: samples,
            sampleRate: sampleRate,
            candidateFrequencies: candidates.map(\.frequency)
        )
        candidates = candidates.enumerated().map { index, candidate in
            LivePitchCandidateV2(
                frequency: candidate.frequency,
                periodicity: candidate.periodicity,
                agreementSupport: candidate.agreementSupport,
                primeHarmonicSupport: primeSupports[index],
                source: candidate.source
            )
        }

        func emissionScore(_ candidate: LivePitchCandidateV2) -> Double {
            let score = 0.40 * candidate.periodicity +
                0.20 * candidate.agreementSupport +
                0.40 * candidate.primeHarmonicSupport
            // Keep this reference/parity implementation aligned with the
            // shared C++ V2 session: a spectral candidate exists only after
            // its exact 2× bin cleared the 8× energy gate.
            return candidate.source == .spectral ? max(score, 0.90) : score
        }

        let scoredCandidates = candidates.map {
            LiveScoredPitchCandidateV2(candidate: $0, emissionScore: emissionScore($0))
        }
        v2LastCandidateDiagnostics = scoredCandidates.map { scored in
            let source: String
            switch scored.candidate.source {
            case .yin: source = "yin"
            case .autocorrelation: source = "autocorrelation"
            case .mpm: source = "mpm"
            case .spectral: source = "spectral"
            }
            return PitchEngineV2CandidateDiagnostic(
                source: source,
                frequency: scored.candidate.frequency,
                periodicity: scored.candidate.periodicity,
                agreementSupport: scored.candidate.agreementSupport,
                primeHarmonicSupport: scored.candidate.primeHarmonicSupport,
                emissionScore: scored.emissionScore
            )
        }
        return resolvePitchPathV2(
            candidates: scoredCandidates,
            capturedAt: capturedAt,
            signalEligible: true
        )
    }

    private func resolvePitchPathV2(
        candidates: [LiveScoredPitchCandidateV2],
        capturedAt: TimeInterval?,
        signalEligible: Bool
    ) -> (frequency: Double, confidence: Double)? {
        v2ResolvedCapturedAt = nil
        v2ResolvedHighRegisterAgreement = false
        v2ResolvedSignalEligible = true
        v2ResolvedCandidateDiagnostics.removeAll(keepingCapacity: true)
        v2PathFrames.append(LivePitchPathFrameV2(
            capturedAt: capturedAt,
            candidates: candidates,
            signalEligible: signalEligible
        ))
        guard v2PathFrames.count > v2FixedLagFrames else { return nil }

        let oldest = v2PathFrames[0]
        defer { v2PathFrames.removeFirst() }
        v2ResolvedCapturedAt = oldest.capturedAt
        v2ResolvedSignalEligible = oldest.signalEligible
        guard !oldest.candidates.isEmpty else { return nil }

        // Silence is a hard path boundary. It must not let a note after a gap
        // rewrite the pitch before that gap.
        let voicedFrames = Array(v2PathFrames.prefix { !$0.candidates.isEmpty })
        var previousScores = voicedFrames[0].candidates.map(\.emissionScore)
        var backPointers: [[Int]] = []

        func transitionScore(from: Double, to: Double) -> Double {
            let cents = abs(1_200 * log2(to / from))
            var penalty = 0.18 * min(cents / 700, 1)
            if cents >= 850 { penalty += 0.12 }
            return -penalty
        }

        if voicedFrames.count > 1 {
            for frameIndex in 1..<voicedFrames.count {
                let prior = voicedFrames[frameIndex - 1].candidates
                let current = voicedFrames[frameIndex].candidates
                var currentScores = Array(repeating: -Double.infinity, count: current.count)
                var currentBackPointers = Array(repeating: 0, count: current.count)
                for currentIndex in current.indices {
                    for priorIndex in prior.indices {
                        let pathScore = previousScores[priorIndex] + transitionScore(
                            from: prior[priorIndex].candidate.frequency,
                            to: current[currentIndex].candidate.frequency
                        )
                        if pathScore > currentScores[currentIndex] {
                            currentScores[currentIndex] = pathScore
                            currentBackPointers[currentIndex] = priorIndex
                        }
                    }
                    currentScores[currentIndex] += current[currentIndex].emissionScore
                }
                previousScores = currentScores
                backPointers.append(currentBackPointers)
            }
        }

        var selectedIndex = previousScores.indices.max {
            previousScores[$0] < previousScores[$1]
        } ?? 0
        for pointers in backPointers.reversed() {
            selectedIndex = pointers[selectedIndex]
        }
        let selected = oldest.candidates[selectedIndex]
        v2ResolvedCandidateDiagnostics = oldest.candidates.map { scored in
            let source: String
            switch scored.candidate.source {
            case .yin: source = "yin"
            case .autocorrelation: source = "autocorrelation"
            case .mpm: source = "mpm"
            case .spectral: source = "spectral"
            }
            return PitchEngineV2CandidateDiagnostic(
                source: source,
                frequency: scored.candidate.frequency,
                periodicity: scored.candidate.periodicity,
                agreementSupport: scored.candidate.agreementSupport,
                primeHarmonicSupport: scored.candidate.primeHarmonicSupport,
                emissionScore: scored.emissionScore
            )
        }
        v2ResolvedHighRegisterAgreement = selected.candidate.agreementSupport >= 1.0 ||
            (selected.candidate.frequency > 900 &&
             selected.candidate.periodicity >= 0.80 &&
             selected.candidate.primeHarmonicSupport >= 0.75)
        return (
            selected.candidate.frequency,
            max(0, min(1, selected.emissionScore))
        )
    }

    /// Keep source-time continuity across a very short V2 publication gap,
    /// but only after the next resolved pitch independently returns to the
    /// same contour. A phrase release or a new note discards the held points.
    private func resolveShortV2Gap(
        result: (frequency: Double, confidence: Double)?,
        capturedAt: TimeInterval?,
        signalEligible: Bool
    ) -> [LivePitchFrame] {
        guard let capturedAt else { return [] }
        guard let result else {
            if !signalEligible {
                pendingV2GapFrames.removeAll(keepingCapacity: true)
                lastPublishedV2Frame = nil
                return []
            }
            if let last = lastPublishedV2Frame, pendingV2GapFrames.count < 7 {
                pendingV2GapFrames.append(LivePitchFrame(
                    time: capturedAt, frequency: last.frequency, confidence: last.confidence
                ))
            } else {
                pendingV2GapFrames.removeAll(keepingCapacity: true)
                lastPublishedV2Frame = nil
            }
            return []
        }

        let current = LivePitchFrame(
            time: capturedAt, frequency: result.frequency, confidence: result.confidence
        )
        defer { lastPublishedV2Frame = current }
        guard !pendingV2GapFrames.isEmpty else { return [] }
        defer { pendingV2GapFrames.removeAll(keepingCapacity: true) }
        guard let last = lastPublishedV2Frame,
              min(last.confidence, current.confidence) >= 0.70,
              abs(1_200 * log2(current.frequency / last.frequency)) <= 90
        else { return [] }
        return pendingV2GapFrames
    }

    private func resolveShortVPMLikeGap(
        result: (frequency: Double, confidence: Double)?,
        capturedAt: TimeInterval?,
        signalEligible: Bool
    ) -> [LivePitchFrame] {
        guard let capturedAt else { return [] }
        guard let result else {
            if !signalEligible {
                pendingVPMLikeGapFrames.removeAll(keepingCapacity: true)
                // A hard input gate ends the contour. Retaining this frame
                // allowed a later estimator-only gap to be backfilled from a
                // pitch published before the below-threshold interval.
                lastPublishedVPMLikeFrame = nil
                return []
            }
            if let last = lastPublishedVPMLikeFrame, pendingVPMLikeGapFrames.count < 7 {
                pendingVPMLikeGapFrames.append(LivePitchFrame(
                    time: capturedAt, frequency: last.frequency, confidence: last.confidence
                ))
            } else {
                pendingVPMLikeGapFrames.removeAll(keepingCapacity: true)
                // Once the seven-frame bridge budget is exhausted, end the
                // contour. Otherwise the next missing frame starts a fresh
                // queue from the same stale pitch and paints the tail of a
                // long silence as voiced when the estimator returns.
                lastPublishedVPMLikeFrame = nil
            }
            return []
        }

        let current = LivePitchFrame(
            time: capturedAt, frequency: result.frequency, confidence: result.confidence
        )
        defer { lastPublishedVPMLikeFrame = current }
        guard !pendingVPMLikeGapFrames.isEmpty else { return [] }
        defer { pendingVPMLikeGapFrames.removeAll(keepingCapacity: true) }
        guard let last = lastPublishedVPMLikeFrame,
              min(last.confidence, current.confidence) >= 0.70,
              abs(1_200 * log2(current.frequency / last.frequency)) <= 90
        else { return [] }
        return pendingVPMLikeGapFrames
    }

    /// Reject a one-frame octave/harmonic jump, but accept a genuine new note
    /// after one consistent follow-up frame.  A three-point median removes
    /// isolated jitter without flattening normal clarinet vibrato.
    private func stabilize(
        _ result: (frequency: Double, confidence: Double)?,
        engine: LivePitchEngine
    ) -> (frequency: Double, confidence: Double)? {
        guard let result else {
            pendingLargeJump = nil
            return nil
        }

        // The experimental autocorrelation trace intentionally remains raw.
        // This makes its density and vibrato response directly comparable with
        // Vocal Pitch Monitor; YIN retains its conservative stability filter.
        guard engine == .yin else { return result }

        if let lastStableFrequency {
            let distance = abs(1_200 * log2(result.frequency / lastStableFrequency))
            if distance > 850 {
                if let pendingLargeJump,
                   abs(1_200 * log2(result.frequency / pendingLargeJump.frequency)) < 180 {
                    self.pendingLargeJump = nil
                    recentStableFrequencies = [result.frequency]
                    self.lastStableFrequency = result.frequency
                    return result
                }
                pendingLargeJump = result
                return (lastStableFrequency, min(result.confidence, 0.55))
            }
        }

        pendingLargeJump = nil
        recentStableFrequencies.append(result.frequency)
        if recentStableFrequencies.count > 3 { recentStableFrequencies.removeFirst() }
        let sorted = recentStableFrequencies.sorted()
        let stableFrequency = sorted[sorted.count / 2]
        lastStableFrequency = stableFrequency
        return (stableFrequency, result.confidence)
    }

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

    private var usesProductionCore: Bool {
        #if !KLARIVISION_SWIFT_PACKAGE
        !usesSwiftV2Reference
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

    private func appendComparison(
        yin: (frequency: Double, confidence: Double)?,
        autocorrelation: (frequency: Double, confidence: Double)?,
        selectedEngine: LivePitchEngine
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        if let yin {
            yinBenchmarkFrames.append(LivePitchFrame(time: now, frequency: yin.frequency, confidence: yin.confidence))
        }
        if let autocorrelation {
            autocorrelationBenchmarkFrames.append(LivePitchFrame(time: now, frequency: autocorrelation.frequency, confidence: autocorrelation.confidence))
        }

        let selected = selectedEngine == .yin ? yin : autocorrelation
        guard let selected else {
            currentFrequency = nil
            currentConfidence = 0
            return
        }
        currentFrequency = selected.frequency
        currentConfidence = selected.confidence
        frames.append(LivePitchFrame(time: now, frequency: selected.frequency, confidence: selected.confidence))
        frames.removeAll { $0.time < now - historyDuration }
        yinBenchmarkFrames.removeAll { $0.time < now - historyDuration }
        autocorrelationBenchmarkFrames.removeAll { $0.time < now - historyDuration }
    }

    func graphFrames(for display: LiveGraphDisplay) -> [LivePitchFrame] {
        guard comparisonAvailable else { return frames }
        switch display {
        case .selected: return frames
        case .yin, .both: return yinBenchmarkFrames
        case .autocorrelation: return autocorrelationBenchmarkFrames
        }
    }

    func secondaryGraphFrames(for display: LiveGraphDisplay) -> [LivePitchFrame] {
        guard comparisonAvailable, display == .both else { return [] }
        return autocorrelationBenchmarkFrames
    }

    private static func estimatePitch(
        samples: [Float],
        sampleRate: Double,
        engine: LivePitchEngine
    ) -> (frequency: Double, confidence: Double)? {
        switch engine {
        case .yin:
            return estimatePitchYIN(samples: samples, sampleRate: sampleRate)
        case .autocorrelation:
            return estimatePitchAutocorrelation(samples: samples, sampleRate: sampleRate)
        case .candidateV2:
            // Stateless callers only need a seed. The actual V2 route goes
            // through `estimatePitchV2`, which owns its independent history.
            return estimatePitchYIN(samples: samples, sampleRate: sampleRate)
        case .vpmLike:
            return estimatePitchVPMLike(samples: samples, sampleRate: sampleRate)
        case .hapt:
            // No Swift mirror exists by design (see docs/HAPTPitchEngine.md);
            // this reference-only path (Swift Package / parity builds) is
            // unreachable for HAPT in the shipped app, which always routes
            // through the production C++ core.
            return nil
        case .unified:
            // C++-only by design, like HAPT: no Swift mirror. This
            // reference-only path (Swift Package / parity builds) is
            // unreachable for unified_v1 in the shipped app, which always
            // routes through the production C++ core.
            return nil
        }
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

    /// Low-latency YIN estimate for the live monitor. Offline recording
    /// analysis remains on the more detailed Vamp pYIN pipeline.
    private static func estimatePitchYIN(samples: [Float], sampleRate: Double) -> (frequency: Double, confidence: Double)? {
        guard let best = yinCandidates(samples: samples, sampleRate: sampleRate)
            .filter({ $0.confidence >= 0.76 })
            .max(by: { $0.confidence < $1.confidence }) else { return nil }
        return best
    }

    private static func yinCandidates(
        samples: [Float],
        sampleRate: Double,
        maximumFrequency: Double = 1_500
    ) -> [(frequency: Double, confidence: Double)] {
        guard samples.count >= 1_024 else { return [] }
        // Keep the complete hot path in Float/vDSP. The old version converted
        // every sample to Double and constructed hundreds of ArraySlice
        // values for each estimate; that limited live capture to ~9 Hz.
        let minLag = max(2, Int(sampleRate / maximumFrequency))
        let maxLag = min(samples.count / 2, Int(sampleRate / 80))
        guard minLag + 2 < maxLag else { return [] }

        // Difference function: Σ(x[n] - x[n + τ])².  Its dot-product term is
        // the expensive part of YIN.  vDSP executes it on Apple's vector
        // hardware rather than running millions of Swift scalar operations.
        var cumulativeEnergy = Array(repeating: Float.zero, count: samples.count + 1)
        for index in samples.indices {
            let sample = samples[index]
            cumulativeEnergy[index + 1] = cumulativeEnergy[index] + sample * sample
        }

        var difference = Array(repeating: Float.zero, count: maxLag + 1)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in minLag...maxLag {
                let count = samples.count - lag
                let leadingEnergy = cumulativeEnergy[count]
                let delayedEnergy = cumulativeEnergy[samples.count] - cumulativeEnergy[lag]
                var correlation: Float = 0
                vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &correlation, vDSP_Length(count))
                difference[lag] = max(0, leadingEnergy + delayedEnergy - 2 * correlation)
            }
        }

        var cumulative: Float = 0
        var normalized = Array(repeating: Float(1), count: maxLag + 1)
        for lag in 1...maxLag {
            cumulative += difference[lag]
            if cumulative > 0 { normalized[lag] = difference[lag] * Float(lag) / cumulative }
        }

        var candidates: [(frequency: Double, confidence: Double)] = []
        for selected in (minLag + 1)..<maxLag {
            let previous = normalized[selected - 1]
            let current = normalized[selected]
            let next = normalized[selected + 1]
            // Keep weaker local minima too. The continuity scorer above can
            // then rescue a quiet fundamental instead of selecting its louder
            // harmonic; initial/noisy frames still require high confidence.
            guard current <= previous, current < next, current < 0.50 else { continue }
            let denominator = previous - 2 * current + next
            let correction: Float = abs(denominator) > 0.000_001 ? 0.5 * (previous - next) / denominator : 0
            let refinedLag = Double(selected) + Double(max(-0.5, min(0.5, correction)))
            let frequency = sampleRate / refinedLag
            guard frequency.isFinite, frequency >= 80, frequency <= maximumFrequency else { continue }
            candidates.append((frequency, Double(max(0, min(1, 1 - current)))))
        }
        return candidates
    }

    /// Measures the energy of one narrow sinusoidal band. It is deliberately
    /// used only for an octave ambiguity around the current musical contour,
    /// not as a general spectral pitch detector. This makes it inexpensive
    /// while resolving the missing-fundamental ambiguity common in clarinet
    /// speaker → microphone playback.
    private static func spectralToneEnergy(
        samples: [Float],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        guard frequency > 0, samples.count > 8 else { return 0 }
        let angularStep = 2 * Double.pi * frequency / sampleRate
        let denominator = Double(max(1, samples.count - 1))
        var cosine = 0.0
        var sine = 0.0
        for (index, sample) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / denominator)
            let phase = angularStep * Double(index)
            let value = Double(sample) * window
            cosine += value * cos(phase)
            sine += value * sin(phase)
        }
        return cosine * cosine + sine * sine
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

    /// Independent implementation of the method Tadao Yamaoka documents for
    /// Vocal Pitch Monitor. It combines normalized autocorrelation, refinement
    /// from later period peaks and a spectrum check at 1/3, 1/2, 1x, 2x and
    /// 3x. The application's exact thresholds are not public, so the name and
    /// report identifier deliberately say "VPM-like", not Vocal Pitch Monitor.
    private static func estimatePitchVPMLike(
        samples: [Float],
        sampleRate: Double
    ) -> (frequency: Double, confidence: Double)? {
        estimatePitchVPMLikeDecision(samples: samples, sampleRate: sampleRate)?.spectral
    }

    private static func estimatePitchVPMLikeDecision(
        samples: [Float],
        sampleRate: Double
    ) -> VPMLikePitchDecision? {
        guard samples.count >= 1_024, sampleRate > 0 else { return nil }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        // Match the canonical C++ core's Double accumulation. The microphone
        // input remains Float32; only the estimator arithmetic is widened so
        // near-threshold ACF peaks cannot choose different harmonic branches
        // solely because of language-specific accumulation precision.
        let centered = samples.map { Double($0) - mean }
        let minimumFrequency = 80.0
        // Estimator-only headroom keeps a 1500 Hz boundary fundamental from
        // being excluded before the f/2 alternative can be compared. The UI
        // range itself remains unchanged.
        let maximumFrequency = 1_650.0
        let minimumLag = max(2, Int(sampleRate / maximumFrequency))
        let maximumLag = min(centered.count / 2, Int(sampleRate / minimumFrequency))
        guard minimumLag + 2 < maximumLag else { return nil }

        var cumulativeEnergy = Array(repeating: Double.zero, count: centered.count + 1)
        for index in centered.indices {
            cumulativeEnergy[index + 1] = cumulativeEnergy[index] + centered[index] * centered[index]
        }

        var correlation = Array(repeating: Double.zero, count: maximumLag + 1)
        centered.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in minimumLag...maximumLag {
                let count = centered.count - lag
                let leading = cumulativeEnergy[count]
                let delayed = cumulativeEnergy[centered.count] - cumulativeEnergy[lag]
                let normalization = sqrt(max(0.000_000_000_001, leading * delayed))
                var dot = 0.0
                vDSP_dotprD(base, 1, base.advanced(by: lag), 1, &dot, vDSP_Length(count))
                correlation[lag] = dot / normalization
            }
        }

        var peaks: [Int] = []
        for lag in (minimumLag + 1)..<maximumLag where
            correlation[lag] >= correlation[lag - 1] && correlation[lag] > correlation[lag + 1] {
            peaks.append(lag)
        }
        guard let strongest = peaks.max(by: { correlation[$0] < correlation[$1] }),
              correlation[strongest] >= 0.38 else { return nil }
        // Calibrated jointly on the exact synthetic stress set and the stable
        // voiced frames of the Şükrü Tunar pYIN reference. A higher ratio
        // prevents a weaker long-lag harmonic from replacing the strongest
        // plausible period without reducing voiced-frame coverage.
        let acceptance = max(0.38, correlation[strongest] * 0.90)
        let selected = peaks.first(where: { correlation[$0] >= acceptance }) ?? strongest

        func refinedPeak(_ index: Int) -> Double {
            guard index > 0, index + 1 < correlation.count else { return Double(index) }
            let left = correlation[index - 1]
            let middle = correlation[index]
            let right = correlation[index + 1]
            let denominator = left - 2 * middle + right
            let correction: Double = abs(denominator) > 0.000_001
                ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator))
                : 0
            return Double(index) + correction
        }

        // At high pitch one lag sample spans many cents. Later ACF peaks are
        // farther apart in samples; dividing their refined positions by N
        // yields a more precise fundamental period without future frames.
        var weightedPeriod = refinedPeak(selected) * correlation[selected]
        var weightSum = correlation[selected]
        for multiple in 2...6 {
            let expected = selected * multiple
            guard expected + 2 < maximumLag else { break }
            let radius = max(2, selected / 6)
            let lower = max(minimumLag + 1, expected - radius)
            let upper = min(maximumLag - 1, expected + radius)
            guard lower <= upper,
                  let local = (lower...upper).max(by: { correlation[$0] < correlation[$1] }),
                  correlation[local] >= 0.304 else { continue }
            let weight = correlation[local] * Double(multiple)
            weightedPeriod += refinedPeak(local) / Double(multiple) * weight
            weightSum += weight
        }
        let period = weightedPeriod / max(0.000_001, weightSum)
        let autocorrelationFrequency = sampleRate / period
        guard autocorrelationFrequency.isFinite else { return nil }

        func spectralAmplitude(_ frequency: Double) -> Double {
            guard frequency > 0, frequency < sampleRate / 2 else { return 0 }
            let energy = spectralToneEnergy(samples: samples, sampleRate: sampleRate, frequency: frequency)
            // spectralToneEnergy is an unnormalised squared projection. For
            // the symmetric Hann used there, sum(window) = (N - 1) / 2; the
            // sinusoid amplitude is 2 * magnitude / sum(window), matching the
            // canonical C++ spectral_amplitude implementation exactly.
            return 4 * sqrt(max(0, energy)) / Double(max(1, samples.count - 1))
        }

        let baseAmplitude = spectralAmplitude(autocorrelationFrequency)
        let relatives = [
            autocorrelationFrequency / 3,
            autocorrelationFrequency / 2,
            autocorrelationFrequency,
            autocorrelationFrequency * 2,
            autocorrelationFrequency * 3,
        ].sorted()
        var chosen = autocorrelationFrequency
        for frequency in relatives where frequency >= minimumFrequency && frequency <= maximumFrequency {
            let amplitude = spectralAmplitude(frequency)
            let sideOffset = max(sampleRate / Double(samples.count), frequency * 0.012)
            let left = spectralAmplitude(frequency - sideOffset)
            let right = spectralAmplitude(frequency + sideOffset)
            let localPeak = amplitude >= left * 1.03 && amplitude >= right * 1.03
            let absoluteSupport = amplitude >= 0.005
            let relativeSupport = baseAmplitude <= 0.000_000_001 || amplitude >= baseAmplitude * 0.080
            // Spectral relatives may reveal a missing fundamental below the
            // ACF estimate. Never promote a strong periodic estimate to a
            // bright 2x/3x harmonic merely because it is a sharper FFT peak.
            // A downward correction is valid only when ACF selected an
            // earlier near-strong peak. If ACF already selected its strongest
            // peak, the adverse holdout shows that f/2 spectral peaks are
            // transient distractors rather than better fundamentals.
            if frequency <= autocorrelationFrequency * (1 + 0.000_000_000_001),
               (frequency >= autocorrelationFrequency * (1 - 0.000_000_000_001) || selected != strongest),
               localPeak && absoluteSupport && relativeSupport {
                chosen = frequency
                break
            }
        }
        guard chosen.isFinite, chosen >= minimumFrequency, chosen <= maximumFrequency else { return nil }
        let confidence = max(0, min(1, correlation[selected]))
        return VPMLikePitchDecision(
            spectral: (chosen, confidence),
            autocorrelation: (autocorrelationFrequency, confidence)
        )
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
