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

enum iPadPitchEngine: String, CaseIterable, Identifiable, Codable {
    case yinV1 = "yin_v1"
    case pitchEngineV2 = "pitch_engine_v2"
    case vpmLike = "vpm_like"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yinV1: "YIN v1"
        case .pitchEngineV2: "Pitch Engine v2"
        case .vpmLike: "VPM-benzeri"
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
    case rast = "Rast", dugah = "Dügâh", segah = "Segâh", cargah = "Çargâh"
    case neva = "Neva", huseyni = "Hüseynî", acem = "Acem"
    var id: String { rawValue }
    var frequency: Double {
        switch self {
        case .rast: return 293.665
        case .dugah: return 329.628
        case .segah: return 349.228
        case .cargah: return 391.995
        case .neva: return 440
        case .huseyni: return 493.883
        case .acem: return 523.251
        }
    }
}

struct iPadMusicContext: Codable, Equatable {
    var makam: iPadMakam = .nihavend
    var karar: iPadKarar = .rast
    var followsCurve = true

    func guideFrequencies() -> [Double] {
        makam.guideCommas.map { karar.frequency * pow(2, Double($0) / 53) }
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
    static let komaIntervalsKey = "klarivision-ipad-53-koma-intervals-v1"
    static let defaultKomaIntervals = [4, 4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 5]

    var selection: iPadSection = .home
    var studyEngine: iPadPitchEngine { didSet { defaults.set(studyEngine.rawValue, forKey: Self.studyEngineKey) } }
    var liveEngine: iPadPitchEngine { didSet { defaults.set(liveEngine.rawValue, forKey: Self.liveEngineKey) } }
    var theme: iPadTheme { didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) } }
    var liveSignalGateDbFS: Double { didSet { defaults.set(Self.clampedGate(liveSignalGateDbFS), forKey: Self.liveGateKey) } }
    var graphPitchColor: String { didSet { defaults.set(graphPitchColor, forKey: Self.graphPitchColorKey) } }
    var graphGuideColor: String { didSet { defaults.set(graphGuideColor, forKey: Self.graphGuideColorKey) } }
    var komaIntervals: [Int] { didSet { if Self.validKomaIntervals(komaIntervals) { defaults.set(komaIntervals, forKey: Self.komaIntervalsKey) } } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        studyEngine = Self.engine(defaults.string(forKey: Self.studyEngineKey))
        liveEngine = Self.engine(defaults.string(forKey: Self.liveEngineKey))
        theme = iPadTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .focus
        liveSignalGateDbFS = Self.clampedGate(defaults.object(forKey: Self.liveGateKey) as? Double ?? -42)
        graphPitchColor = defaults.string(forKey: Self.graphPitchColorKey) ?? "#67d5ff"
        graphGuideColor = defaults.string(forKey: Self.graphGuideColorKey) ?? "#b7d8ff"
        let storedIntervals = defaults.array(forKey: Self.komaIntervalsKey) as? [Int] ?? Self.defaultKomaIntervals
        komaIntervals = Self.validKomaIntervals(storedIntervals) ? storedIntervals : Self.defaultKomaIntervals
    }

    static func engine(_ value: String?) -> iPadPitchEngine {
        iPadPitchEngine(rawValue: value ?? "") ?? .yinV1
    }

    static func clampedGate(_ dbFS: Double) -> Double { min(-20, max(-60, dbFS)) }
    static func rms(forDbFS dbFS: Double) -> Double { pow(10, clampedGate(dbFS) / 20) }
    static func validKomaIntervals(_ values: [Int]) -> Bool { values.count == 12 && values.allSatisfy { $0 > 0 } && values.reduce(0, +) == 53 }
    func resetKomaIntervals() { komaIntervals = Self.defaultKomaIntervals; defaults.set(komaIntervals, forKey: Self.komaIntervalsKey) }
}
