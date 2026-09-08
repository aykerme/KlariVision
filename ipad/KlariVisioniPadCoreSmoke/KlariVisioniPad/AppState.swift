// KlariVision iPhone/iPad — kök gezinme, tercihler ve müzik bağlamı.
// Compact tab ve regular sidebar aynı seçimi kullanır; geçiş politikaları
// görünmeyen canlı oturumu durdurur ve çalışmayı duraklatır. UserDefaults
// anahtarları iki cihaz ailesi için ortak kalıcı sözleşmedir.

import Foundation
import SwiftUI

enum iPadSection: String, CaseIterable, Identifiable {
    case home
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Ana Sayfa"
        case .library: "Çalışmalar"
        case .settings: "Ayarlar"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "waveform.path"
        case .settings: "gearshape"
        }
    }
}

enum iPadNavigationSafety {
    static func stopsLive(whenMovingTo destination: iPadSection) -> Bool { destination != .home }
    static func pausesStudy(whenMovingTo destination: iPadSection) -> Bool { destination != .library }
}

/// The compact phone shell keeps its tab selection separate from the active
/// workspace.  This is deliberately transient UI state: it is not persisted
/// and must survive size-class/orientation changes without being recreated.
enum iPadWorkspaceRoute: Equatable {
    case none
    case listening
    case live
}

struct iPadNavigationTeardown: Equatable {
    let stopLive: Bool
    let pauseStudy: Bool

    static let none = Self(stopLive: false, pauseStudy: false)
}

enum iPadCompactNavigationPolicy {
    static func teardown(whenMovingTo destination: iPadSection) -> iPadNavigationTeardown {
        iPadNavigationTeardown(
            stopLive: iPadNavigationSafety.stopsLive(whenMovingTo: destination),
            pauseStudy: iPadNavigationSafety.pausesStudy(whenMovingTo: destination)
        )
    }
}

/// Small, non-Codable route model for the compact TabView shell.  Route
/// transitions are explicit so tab changes can share one teardown decision.
struct iPadCompactNavigationState: Equatable {
    var section: iPadSection = .home
    var route: iPadWorkspaceRoute = .none

    mutating func openListening() { route = .listening }
    mutating func openLive() { route = .live }
    mutating func closeWorkspace() { route = .none }

    @discardableResult
    mutating func select(_ destination: iPadSection) -> iPadNavigationTeardown {
        let decision = iPadCompactNavigationPolicy.teardown(whenMovingTo: destination)
        section = destination
        route = .none
        return decision
    }
}

/// One case since D-039. The raw values are persisted in `Studies-v1.json`
/// and in UserDefaults, so decoding a study recorded under a removed engine
/// must not throw -- see `engine(_:)`, which maps any unknown or removed id
/// onto the engine this build has.
enum iPadPitchEngine: String, CaseIterable, Identifiable, Codable {
    case unifiedV1 = "unified_v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unifiedV1: "Birleşik (Unified v1)"
        }
    }
}

enum iPadTheme: String, CaseIterable, Identifiable {
    case focus
    case studio
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Çalışma odaklı"
        case .studio: "Stüdyo"
        case .classic: "Sıcak klasik"
        }
    }

    var colorScheme: ColorScheme? { self == .studio ? .dark : .light }
}

/// User-selected musical presentation. It only affects labels and guide lines;
/// incoming physical frequency frames are never transposed or rewritten.
enum iPadMakam: String, CaseIterable, Codable, Identifiable {
    case major = "Majör", minor = "Minör", nihavend = "Nihavend", kurdi = "Kürdi"
    case ussak = "Uşşak", hicaz = "Hicaz", hicazkar = "Hicazkâr", kurdilihicazkar = "Kürdilihicazkâr"
    var id: String { rawValue }

    /// 53-comma positions from the selected karar; guides are intentionally a
    /// display aid and do not imply automatic makam detection.
    var guideCommas: [Int] {
        switch self {
        case .major: [0, 9, 18, 22, 31, 40, 49, 53]
        case .minor, .nihavend: [0, 9, 13, 22, 31, 35, 44, 53]
        case .kurdi: [0, 5, 13, 22, 31, 35, 44, 53]
        case .ussak: [0, 8, 17, 22, 31, 39, 44, 53]
        case .hicaz: [0, 5, 18, 22, 31, 40, 44, 53]
        case .hicazkar: [0, 5, 18, 22, 31, 40, 49, 53]
        case .kurdilihicazkar: [0, 5, 13, 22, 31, 40, 49, 53]
        }
    }
}

enum iPadKarar: String, CaseIterable, Codable, Identifiable {
    // Do/Re/Mi/Fa/Sol/La/Si solfège — matches the macOS viewer's own "Karar"
    // picker and note-label vocabulary exactly (frequency_viewer.py's
    // `#tonic` select and `SCALE_LABELS`). Turkish perde names (Rast, Dügâh,
    // …) were decided against for displayed note names/karar selection.
    case doNote = "Do", re = "Re", mi = "Mi", fa = "Fa", sol = "Sol", la = "La", si = "Si"
    var id: String { rawValue }
    var frequency: Double {
        switch self {
        case .doNote: return 523.251
        case .re: return 293.665
        case .mi: return 329.628
        case .fa: return 349.228
        case .sol: return 391.995
        case .la: return 440
        case .si: return 493.883
        }
    }

    /// Falls back to `.re` for any raw value this app no longer recognizes —
    /// e.g. a study saved before the Rast/Dügâh → Do/Re rename — instead of
    /// throwing. `[iPadStudy]` decodes as a single array in
    /// `iPadStudyLibraryStore.load()`, so one study with a stale "Rast"
    /// karar would otherwise fail the whole library's decode and silently
    /// empty the list.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = iPadKarar(rawValue: raw) ?? .re
    }
}

/// Which note vocabulary the graph's guide lines/labels use. `.makam` shows
/// the single-octave makam scale built from the selected karar (see
/// `iPadMusicContext.guideNotes()`); `.turkish` shows the full ±1-octave
/// 53-koma Sol Klarnet perde reference table, independent of karar — mirrors
/// macOS's separate "Türk Müziği · Sol Klarnet" scale-mode option
/// (frequency_viewer.py's `turkishNotes()`).
enum iPadScaleDisplay: String, CaseIterable, Codable, Identifiable {
    case makam = "Makam", turkish = "Türk Müziği (Sol Klarnet)"
    var id: String { rawValue }
}

struct iPadMusicContext: Codable, Equatable {
    var makam: iPadMakam = .nihavend
    var karar: iPadKarar = .re
    var followsCurve = true
    var scaleDisplay: iPadScaleDisplay = .makam

    func guideFrequencies(commas overrideCommas: [Int]? = nil) -> [Double] {
        (overrideCommas ?? makam.guideCommas).map { karar.frequency * pow(2, Double($0) / 53) }
    }

    /// Ascending-frequency solfège ring, matching how `iPadKarar`'s own tuned
    /// frequencies actually order (Re is lowest, Do highest) — NOT
    /// alphabetical/declaration order. Mirrors the macOS viewer's
    /// `makamLabel`/`makamNotes` naming (see frequency_viewer.py) exactly,
    /// using the same Do/Re/Mi/Fa/Sol/La/Si vocabulary.
    private static let perdeCycle: [iPadKarar] = [.re, .mi, .fa, .sol, .la, .si, .doNote]

    /// A perde's natural 53-koma distance from Re, derived from its own
    /// tuned frequency rather than a hardcoded table — stays correct if the
    /// karar frequencies are ever retuned.
    private static func naturalKoma(for perde: iPadKarar) -> Int {
        Int((53 * log2(perde.frequency / iPadKarar.re.frequency)).rounded())
    }

    /// Guide lines paired with mac-style solfège labels: base note name +
    /// octave number, plus a ♯N/♭N koma-deviation suffix when the makam's
    /// comma position departs from that note's natural 53-koma position
    /// (same idea as macOS's `makamLabel`). No Hz is included — the mobile
    /// graph shows names only.
    ///
    /// Spans octaves -3…+3 around the karar, same range as macOS's
    /// `makamNotes()` (`for(let octave=-3;octave<=3;octave++)` in
    /// frequency_viewer.py) — the caller (StudyViewer.html/LiveViewer.html)
    /// already clips to whatever's currently visible, so this just needs to
    /// cover any vertical range/zoom/follow position the graph can reach,
    /// not just the one octave straight above the karar.
    func guideNotes(commas overrideCommas: [Int]? = nil) -> [(name: String, hz: Double, isKarar: Bool)] {
        if scaleDisplay == .turkish { return iPadTurkishPitchReference.notes.map { ($0.name, $0.hz, false) } }
        let cycle = Self.perdeCycle
        guard let rootIndex = cycle.firstIndex(of: karar) else { return [] }
        let rootKoma = Self.naturalKoma(for: karar)
        // 8 entries [0,…,53]; drop the trailing octave-repeat so each of the
        // 7 within-octave degrees is only listed once, then re-added at every
        // octave shift below.
        let degreeCommas = Array((overrideCommas ?? makam.guideCommas).dropLast())
        var notes: [(name: String, hz: Double, isKarar: Bool)] = []
        notes.reserveCapacity(degreeCommas.count * 7)
        for octaveShift in -3...3 {
            for degree in degreeCommas.indices {
                let comma = degreeCommas[degree] + 53 * octaveShift
                let hz = karar.frequency * pow(2, Double(comma) / 53)
                let base = cycle[(rootIndex + degree) % 7]
                let naturalStep = (((Self.naturalKoma(for: base) - rootKoma) % 53 + 53) % 53) + 53 * octaveShift
                let adjustment = comma - naturalStep
                let suffix = adjustment == 0 ? "" : " \(adjustment > 0 ? "♯" : "♭")\(abs(adjustment))"
                let midi = Int((69 + 12 * log2(hz / 440)).rounded())
                let octave = midi / 12 - 1
                notes.append(("\(base.rawValue)\(octave)\(suffix)", hz, degree == 0))
            }
        }
        return notes
    }
}

/// Persisted, user-editable overrides for the 7 comma-interval steps of each
/// tunable makam — mirrors macOS's makam "Ayarlar" dialog (`makamIntervals`/
/// `localStorage` in frequency_viewer.py's settings dialog), stored here via
/// UserDefaults instead. Majör/Minör keep their fixed diatonic pattern, same
/// as macOS (they're absent from `MAKAM_DEFAULT_INTERVALS` there too).
@Observable
final class iPadMakamIntervalsStore {
    static let key = "klarivision-ipad-makam-koma-intervals-v1"
    static let editableModes: [iPadMakam] = [.nihavend, .kurdi, .ussak, .hicaz, .hicazkar, .kurdilihicazkar]

    private(set) var overrides: [iPadMakam: [Int]] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The 7 comma deltas a makam ships with, derived from its own
    /// cumulative `guideCommas` (which is 8 entries: a leading 0 for the
    /// tonic itself, then 7 step positions ending at 53) — the editor's
    /// starting point and the "Teoriye Dön" reset target.
    static func defaultIntervals(for makam: iPadMakam) -> [Int] {
        var previous = 0
        return makam.guideCommas.dropFirst().map { value -> Int in
            let delta = value - previous
            previous = value
            return delta
        }
    }

    static func isValid(_ intervals: [Int]) -> Bool {
        intervals.count == 7 && intervals.allSatisfy { $0 >= 1 && $0 <= 13 } && intervals.reduce(0, +) == 53
    }

    func intervals(for makam: iPadMakam) -> [Int] { overrides[makam] ?? Self.defaultIntervals(for: makam) }

    /// Cumulative comma positions (8 entries — leading 0, then 7 steps
    /// ending at 53) ready for `iPadMusicContext.guideNotes(commas:)`/
    /// `guideFrequencies(commas:)`.
    func commas(for makam: iPadMakam) -> [Int] {
        guard Self.editableModes.contains(makam) else { return makam.guideCommas }
        var running = 0
        var result = [0]
        for delta in intervals(for: makam) {
            running += delta
            result.append(running)
        }
        return result
    }

    /// Updates the in-memory draft immediately (so the Stepper always
    /// reflects the tap, even mid-edit while the 7-value total isn't 53 yet
    /// — same "live but only persist when valid" contract as the existing
    /// 53-koma section's `iPadAppState.komaIntervals`) and only writes
    /// through to UserDefaults once the total is valid again.
    @discardableResult
    func setIntervals(_ intervals: [Int], for makam: iPadMakam) -> Bool {
        guard Self.editableModes.contains(makam), intervals.count == 7 else { return false }
        overrides[makam] = intervals
        let valid = Self.isValid(intervals)
        if valid { persist() }
        return valid
    }

    func reset(_ makam: iPadMakam) {
        overrides[makam] = nil
        persist()
    }

    private func persist() {
        let encoded = overrides.reduce(into: [String: [Int]]()) { $0[$1.key.rawValue] = $1.value }
        defaults.set(encoded, forKey: Self.key)
    }

    private func load() {
        guard let raw = defaults.dictionary(forKey: Self.key) else { return }
        for (rawKey, rawValue) in raw {
            guard let makam = iPadMakam(rawValue: rawKey), Self.editableModes.contains(makam),
                  let intervals = rawValue as? [Int], Self.isValid(intervals) else { continue }
            overrides[makam] = intervals
        }
    }
}

@Observable
final class iPadAppState {
    static let studyEngineKey = "klarivision-ipad-study-pitch-engine-v1"
    static let liveEngineKey = "klarivision-ipad-live-pitch-engine-v1"
    static let themeKey = "klarivision-ipad-theme-v1"
    static let liveGateKey = "klarivision-ipad-live-signal-gate-dbfs-v1"
    static let graphPitchColorKey = "klarivision-ipad-graph-pitch-color-v1"
    static let graphGuideColorKey = "klarivision-ipad-graph-guide-color-v1"
    static let graphKararColorKey = "klarivision-ipad-graph-karar-color-v1"
    static let komaIntervalsKey = "klarivision-ipad-53-koma-intervals-v1"
    static let defaultKomaIntervals = [4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 5]

    var selection: iPadSection = .home
    var studyEngine: iPadPitchEngine { didSet { defaults.set(studyEngine.rawValue, forKey: Self.studyEngineKey) } }
    var liveEngine: iPadPitchEngine { didSet { defaults.set(liveEngine.rawValue, forKey: Self.liveEngineKey) } }
    var theme: iPadTheme { didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) } }
    var liveSignalGateDbFS: Double { didSet { defaults.set(Self.clampedGate(liveSignalGateDbFS), forKey: Self.liveGateKey) } }
    var graphPitchColor: String { didSet { defaults.set(graphPitchColor, forKey: Self.graphPitchColorKey) } }
    var graphGuideColor: String { didSet { defaults.set(graphGuideColor, forKey: Self.graphGuideColorKey) } }
    var graphKararColor: String { didSet { defaults.set(graphKararColor, forKey: Self.graphKararColorKey) } }
    var komaIntervals: [Int] { didSet { if Self.validKomaIntervals(komaIntervals) { defaults.set(komaIntervals, forKey: Self.komaIntervalsKey) } } }
    /// Shared, single instance — Study and Live graphs both read this via
    /// `configure(...)` so an edit in Settings updates both immediately.
    let makamIntervals: iPadMakamIntervalsStore

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        makamIntervals = iPadMakamIntervalsStore(defaults: defaults)
        studyEngine = Self.engine(defaults.string(forKey: Self.studyEngineKey))
        liveEngine = Self.engine(defaults.string(forKey: Self.liveEngineKey))
        theme = iPadTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .focus
        liveSignalGateDbFS = Self.clampedGate(defaults.object(forKey: Self.liveGateKey) as? Double ?? -42)
        graphPitchColor = defaults.string(forKey: Self.graphPitchColorKey) ?? "#67d5ff"
        graphGuideColor = defaults.string(forKey: Self.graphGuideColorKey) ?? "#b7d8ff"
        graphKararColor = defaults.string(forKey: Self.graphKararColorKey) ?? "#E75A5A"
        let storedIntervals = defaults.array(forKey: Self.komaIntervalsKey) as? [Int] ?? Self.defaultKomaIntervals
        komaIntervals = Self.validKomaIntervals(storedIntervals) ? storedIntervals : Self.defaultKomaIntervals
    }

    /// Fresh installs, unreadable values and any id naming one of the four
    /// engines removed in D-039 all resolve to unified_v1 -- the only engine
    /// this build can run. Previously analysed studies keep their own stored
    /// results; only the *selection* falls back.
    static func engine(_ value: String?) -> iPadPitchEngine {
        iPadPitchEngine(rawValue: value ?? "") ?? .unifiedV1
    }

    static func clampedGate(_ dbFS: Double) -> Double { min(-20, max(-60, dbFS)) }
    static func rms(forDbFS dbFS: Double) -> Double { pow(10, clampedGate(dbFS) / 20) }
    static func validKomaIntervals(_ values: [Int]) -> Bool { values.count == 12 && values.allSatisfy { $0 > 0 } && values.reduce(0, +) == 53 }
    func resetKomaIntervals() { komaIntervals = Self.defaultKomaIntervals; defaults.set(komaIntervals, forKey: Self.komaIntervalsKey) }
}
