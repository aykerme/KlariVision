// KlariVision macOS — uygulama genelindeki görünüm ve kullanıcı tercihleri.
// Tema, motor, erişilebilir metin ve grafik renklerinin tek yerel kaynağıdır.
// UserDefaults anahtarları kalıcı sözleşmedir; değişiklik göç planı gerektirir.
// Nota/görünüm seçimleri ölçülen fiziksel frekansı değiştirmemelidir.

import AppKit
import Accelerate
import AVFoundation
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

/// A single, persisted appearance choice shared by every native surface.  The
/// viewer used to own this setting in its page-local storage, which meant a
/// theme could change only the graph while the rest of the app stayed put.
enum AppTheme: String, CaseIterable, Identifiable {
    static let storageKey = "klarivision-app-theme-v1"

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
    var background: Color {
        switch self {
        case .focus: Color(nsColor: .windowBackgroundColor)
        case .studio: Color(red: 24 / 255, green: 30 / 255, blue: 37 / 255)
        case .classic: Color(red: 250 / 255, green: 244 / 255, blue: 234 / 255)
        }
    }
    var controlBackground: Color {
        switch self {
        case .focus: Color(nsColor: .controlBackgroundColor)
        case .studio: Color(red: 39 / 255, green: 48 / 255, blue: 58 / 255)
        case .classic: Color(red: 255 / 255, green: 250 / 255, blue: 241 / 255)
        }
    }
}

struct AppThemeKey: EnvironmentKey { static let defaultValue = AppTheme.focus }
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    func applyingAppTheme(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
            .preferredColorScheme(theme.colorScheme)
            .background(theme.background)
    }
}

struct PitchEngineChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

enum PitchEngineSettings {
    static let studyEngineKey = "klarivision-study-pitch-engine-v1"
    static let liveEngineKey = "klarivision-live-pitch-engine-v1"
    static let togetherEngineKey = "klarivision-together-pitch-engine-v1"
    /// The one engine the app runs. It was the default from D-038; D-039 then
    /// removed the four engines it had been measured against, so this is no
    /// longer a default among peers -- it is the engine.
    ///
    /// The choice was a product decision, not the tournament's automatic
    /// ranking: that ranking scores serious errors of every class together and
    /// still names vpm_like, because unified_v1 buys its zero harmonic errors
    /// with silence. The product requirement is the asymmetric one -- a silent
    /// point is preferred over a harmonic error.
    static let initialEngine = "unified_v1"

    /// One entry since D-039. Kept as a collection rather than collapsed into
    /// a constant because the persisted keys, the study cache and the C ABI
    /// all still carry an engine *id*, and a second engine would be added
    /// here again.
    static let userChoices = [
        PitchEngineChoice(id: "unified_v1", title: "Birleşik (Unified v1)"),
    ]

    /// Any stored value that is not a live engine id resolves to the engine
    /// this build has. That is the migration path for installs still holding
    /// "yin_v1", "pitch_engine_v2", "vpm_like" or "hapt_v1": those engines no
    /// longer exist, so the selection cannot be honoured, and falling back is
    /// the only remaining behaviour. Existing analysed studies are unaffected
    /// -- their cached results keep the engine id they were produced with.
    static func resolvedSelection(_ value: String?) -> String {
        guard let value, userChoices.contains(where: { $0.id == value }) else {
            return initialEngine
        }
        return value
    }

    static func storedSelection(
        for key: String,
        defaults: UserDefaults = .standard
    ) -> String {
        resolvedSelection(defaults.string(forKey: key))
    }
}

/// Short, stable VoiceOver copy shared by the two primary study flows.
enum AccessibilityText {
    static let listeningStatus = "Dinleme durumu"
    static let practiceStatus = "Çalma durumu"
    static let unsupportedDrop = "Dosya alınamadı. Desteklenen bir ses veya video dosyası bırakın."
    /// Read out on the settings row that names the analysis engine. There is
    /// nothing to choose any more, so this says what runs rather than offering
    /// a comparison.
    static let engineDescription = "Ses çözümlemesi Birleşik (Unified v1) motoruyla yapılır. Seçilebilir başka motor yoktur."
}

/// The two graph renderers use different technologies, but share these two
/// user-facing colour roles.  Keeping the persisted value as canonical hex
/// makes the WebKit bridge deterministic as well as easy to repair.
struct GraphAppearance: Codable, Equatable {
    static let pitchColorKey = "klarivision-graph-pitch-color-v1"
    static let noteGuideColorKey = "klarivision-graph-note-guide-color-v1"
    static let micColorKey = "klarivision-graph-mic-color-v1"
    static let kararColorKey = "klarivision-graph-karar-color-v1"
    static let defaultPitchHex = "#0A84FF"
    static let defaultNoteGuideHex = "#8E8E93"
    static let defaultMicHex = "#FF9F0A"
    static let defaultKararHex = "#E75A5A"

    var pitchHex: String
    var noteGuideHex: String
    var micHex: String
    var kararHex: String

    init(pitchHex: String = Self.defaultPitchHex, noteGuideHex: String = Self.defaultNoteGuideHex, micHex: String = Self.defaultMicHex, kararHex: String = Self.defaultKararHex) {
        self.pitchHex = Self.normalizedHex(pitchHex) ?? Self.defaultPitchHex
        self.noteGuideHex = Self.normalizedHex(noteGuideHex) ?? Self.defaultNoteGuideHex
        self.micHex = Self.normalizedHex(micHex) ?? Self.defaultMicHex
        self.kararHex = Self.normalizedHex(kararHex) ?? Self.defaultKararHex
    }

    static func normalizedHex(_ value: String?) -> String? {
        guard let value,
              value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        return value.uppercased()
    }

    static func stored(defaults: UserDefaults = .standard) -> Self {
        Self(
            pitchHex: defaults.string(forKey: pitchColorKey) ?? defaultPitchHex,
            noteGuideHex: defaults.string(forKey: noteGuideColorKey) ?? defaultNoteGuideHex,
            micHex: defaults.string(forKey: micColorKey) ?? defaultMicHex,
            kararHex: defaults.string(forKey: kararColorKey) ?? defaultKararHex
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(pitchHex, forKey: Self.pitchColorKey)
        defaults.set(noteGuideHex, forKey: Self.noteGuideColorKey)
        defaults.set(micHex, forKey: Self.micColorKey)
        defaults.set(kararHex, forKey: Self.kararColorKey)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        Self().save(to: defaults)
    }

    static func color(hex: String) -> Color {
        let value = normalizedHex(hex) ?? defaultPitchHex
        let components = stride(from: 1, through: 5, by: 2).map {
            Double(Int(value[value.index(value.startIndex, offsetBy: $0)...value.index(value.startIndex, offsetBy: $0 + 1)], radix: 16) ?? 0) / 255
        }
        return Color(red: components[0], green: components[1], blue: components[2])
    }

    static func hex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    var pitchColor: Color { Self.color(hex: pitchHex) }
    var noteGuideColor: Color { Self.color(hex: noteGuideHex) }
    var micColor: Color { Self.color(hex: micHex) }
    var kararColor: Color { Self.color(hex: kararHex) }
}

enum MicrophoneSettings {
    static let micAlignmentKey = "klarivision-together-mic-alignment-ms-v1"
    static let defaultMicAlignment = 0.0

    /// Mikrofon hizalamasını −200…+200 ms aralığına kelepçeler.
    static func clampedMicAlignment(_ value: Double) -> Double {
        max(-200, min(200, value))
    }
}

@main
struct KlariVisionApp: App {
    @State private var library = RecentLibrary()
    @AppStorage(AppTheme.storageKey) private var themeName = AppTheme.focus.rawValue

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .focus }

    init() {
        // Swift Package uygulamaları Xcode'dan çalıştırıldığında bazen arka
        // planda kalabiliyor. Normal bir macOS uygulaması gibi etkinleştir.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            WelcomeView(library: library)
                .frame(minWidth: 880, minHeight: 640)
                .applyingAppTheme(theme)
        }
        .defaultSize(width: 1100, height: 740)

        Settings {
            SettingsView()
                .applyingAppTheme(theme)
        }
    }
}
