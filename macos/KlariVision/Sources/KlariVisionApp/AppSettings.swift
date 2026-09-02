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
    /// Kept only so existing installs open with their prior behaviour; this
    /// does not express a quality ranking or a recommended engine.
    static let initialEngine = "yin_v1"
    static let userChoices = [
        PitchEngineChoice(id: "yin_v1", title: "YIN v1"),
        PitchEngineChoice(id: "pitch_engine_v2", title: "Pitch Engine v2"),
        PitchEngineChoice(id: "vpm_like", title: "VPM-benzeri"),
        PitchEngineChoice(id: "hapt_v1", title: "Harmonik-Faz (HAPT)"),
    ]

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

/// Short, stable VoiceOver copy shared by the two primary study flows. The
/// engine wording deliberately describes four peer choices rather than a
/// recommendation or quality order.
enum AccessibilityText {
    static let listeningStatus = "Dinleme durumu"
    static let practiceStatus = "Çalma durumu"
    static let unsupportedDrop = "Dosya alınamadı. Desteklenen bir ses veya video dosyası bırakın."
    static let enginePickerHint = "YIN v1, Pitch Engine v2, VPM-benzeri ve Harmonik-Faz (HAPT) eşit kullanıcı seçenekleridir."
}

/// The two graph renderers use different technologies, but share these two
/// user-facing colour roles.  Keeping the persisted value as canonical hex
/// makes the WebKit bridge deterministic as well as easy to repair.
struct GraphAppearance: Codable, Equatable {
    static let pitchColorKey = "klarivision-graph-pitch-color-v1"
    static let noteGuideColorKey = "klarivision-graph-note-guide-color-v1"
    static let micColorKey = "klarivision-graph-mic-color-v1"
    static let defaultPitchHex = "#0A84FF"
    static let defaultNoteGuideHex = "#8E8E93"
    static let defaultMicHex = "#FF9F0A"

    var pitchHex: String
    var noteGuideHex: String
    var micHex: String

    init(pitchHex: String = Self.defaultPitchHex, noteGuideHex: String = Self.defaultNoteGuideHex, micHex: String = Self.defaultMicHex) {
        self.pitchHex = Self.normalizedHex(pitchHex) ?? Self.defaultPitchHex
        self.noteGuideHex = Self.normalizedHex(noteGuideHex) ?? Self.defaultNoteGuideHex
        self.micHex = Self.normalizedHex(micHex) ?? Self.defaultMicHex
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
            micHex: defaults.string(forKey: micColorKey) ?? defaultMicHex
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(pitchHex, forKey: Self.pitchColorKey)
        defaults.set(noteGuideHex, forKey: Self.noteGuideColorKey)
        defaults.set(micHex, forKey: Self.micColorKey)
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
