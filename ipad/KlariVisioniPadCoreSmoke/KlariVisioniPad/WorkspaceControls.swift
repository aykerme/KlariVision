// KlariVision iPhone/iPad — Dinleme ve Çalma çalışma alanlarının ortak
// kontrolleri: ayar sayfaları (sheet), makam aralık düzenleyicisi, ayar
// düğmesi ve kayıt düğmesi. Compact ve regular düzenler aynı parçaları
// kullanır; burada durum sahiplenilmez, yalnız bağlamalar tüketilir.

import SwiftUI
import UIKit

/// Gear button that replaces the old inline `Menu`s.  Both workspaces show it
/// in the same slot their previous menu occupied, so the control bars keep
/// their existing layout.
struct iPadWorkspaceSettingsButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "gearshape.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
    }
}

/// Playback position readout for the listening workspaces.  It replaces the old
/// position `Slider`: scrubbing is a one-finger horizontal drag on the graph
/// itself (see StudyViewer.html), which moves the recording under a playhead
/// that stays centered instead of dragging a second cursor across a bar.
/// The readout stays the accessible seek path — the responsive contract asks
/// for a non-gesture equivalent — so VoiceOver adjusts it in 5-second steps.
struct iPadStudyPositionReadout: View {
    let time: Double
    let duration: Double
    let seek: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.label(time)).font(.caption.monospacedDigit())
            Text("/").font(.caption).foregroundStyle(.secondary)
            Text(Self.label(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Konum")
        .accessibilityValue("\(Self.label(time)) / \(Self.label(duration))")
        .accessibilityHint("Grafiği tek parmakla yatay sürükleyerek de gezinebilirsiniz")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(duration > 0 ? min(duration, time + 5) : time + 5)
            case .decrement: seek(max(0, time - 5))
            @unknown default: break
            }
        }
    }

    static func label(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

/// Round record button.  Idle shows the familiar filled red dot; while a WAV
/// is being written the dot becomes a rounded square and blinks, unless the
/// system asks for reduced motion.
struct iPadRecordButton: View {
    let recording: iPadRecordingPhase
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBlinking = false

    private var isActive: Bool { recording == .active }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
                shape
                    .fill(.red)
                    .frame(width: isActive ? 18 : 20, height: isActive ? 18 : 20)
                    .opacity(isActive && isBlinking && !reduceMotion ? 0.3 : 1)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(isActive ? "WAV kaydını bitir" : "WAV kaydı başlat")
        .accessibilityValue(isActive ? "Kaydediliyor" : "")
        .onChange(of: isActive) { _, active in updateBlink(active) }
        .onAppear { updateBlink(isActive) }
    }

    private var shape: AnyShape {
        isActive ? AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)) : AnyShape(Circle())
    }

    private func updateBlink(_ active: Bool) {
        guard !reduceMotion else { isBlinking = false; return }
        if active {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isBlinking = true }
        } else {
            withAnimation(.default) { isBlinking = false }
        }
    }
}

// MARK: - "Birlikte Çal" (T6)

/// Dinleme çalışma alanına eklenen "Birlikte Çal" aç/kapa denetimi.
/// Görsel dil `loopButton` ile aynı: açıkken dolgulu, kapalıyken çerçeveli —
/// yalnız renkle değil, doldurma durumuyla da anlatılır.
struct iPadTogetherModeButton: View {
    let isOn: Bool
    let isBusy: Bool
    let action: () -> Void

    @ViewBuilder private var content: some View {
        if isBusy {
            ProgressView().frame(width: 44, height: 44)
        } else {
            Label("Birlikte Çal", systemImage: "mic.fill").labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    var body: some View {
        if isOn {
            Button(action: action) { content }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(isBusy)
                .accessibilityLabel("Birlikte Çal").accessibilityValue("Açık")
                .accessibilityHint("Mikrofonu açar; çaldığınız eğri referansın üstüne ayrı renkte çizilir")
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered).controlSize(.large).disabled(isBusy)
                .accessibilityLabel("Birlikte Çal").accessibilityValue("Kapalı")
                .accessibilityHint("Mikrofonu açar; çaldığınız eğri referansın üstüne ayrı renkte çizilir")
        }
    }
}

/// Yalnız referans çıkışını sessize alır — akustik geri besleme içindir.
/// Mikrofon çizimi sürmeye devam eder (bkz. `iPadTogetherSession.setMuted`).
/// Yalnız "Birlikte Çal" açıkken görünür.
struct iPadTogetherMuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isMuted ? "Ses çıkışını aç" : "Ses çıkışını kapat",
                  systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(isMuted ? "Ses çıkışını aç" : "Ses çıkışını kapat")
        .accessibilityValue(isMuted ? "Sessiz" : "Açık")
        .accessibilityHint("Akustik geri beslemeyi önlemek için yalnız referans sesini sessize alır")
    }
}

/// Mod açıkken görünen, tek satırlık kulaklık önerisi. Gerekçe: hoparlörden
/// çalarken referansın kendisi mikrofona girip "kullanıcının eğrisi" gibi
/// çizilebilir (akustik geri besleme).
struct iPadTogetherHeadphoneHint: View {
    var body: some View {
        Label("Birlikte Çal açık — kulaklık kullanın, aksi halde referans sesi mikrofona karışabilir", systemImage: "headphones")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)
    }
}

/// Mikrofon izni reddi dahil, "Birlikte Çal" başlatma hatalarını gösterir.
struct iPadTogetherErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
    }
}

/// Hex string ↔ `Color` — yalnız bu dosyadaki "Birlikte Çal" renk seçicisi
/// için. Diğer grafik renkleri (Ayarlar sekmesi) düz `TextField` ile hex
/// string tutmaya devam ediyor; bu yalnız `ColorPicker` köprüsü.
private extension Color {
    init(hexString: String) {
        var value: UInt64 = 0
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return "#FF9F0A" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Makam/Karar rows plus the entry point to the comma-interval editor.  Both
/// settings sheets embed this, so the picker trio that used to be copied into
/// four view files now lives in one place.
struct iPadMusicContextSection: View {
    @Binding var makam: iPadMakam
    @Binding var karar: iPadKarar
    let intervals: iPadMakamIntervalsStore

    var body: some View {
        Section {
            Picker("Makam", selection: $makam) {
                ForEach(iPadMakam.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.navigationLink)
            Picker("Karar", selection: $karar) {
                ForEach(iPadKarar.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.navigationLink)
            NavigationLink {
                iPadMakamIntervalsView(makam: makam, store: intervals)
            } label: {
                LabeledContent("Aralıklar", value: iPadMakamIntervalsView.summary(for: makam, store: intervals))
            }
        } header: {
            Text("Makam ve Karar")
        } footer: {
            Text("Aralıklar, seçili makamın koma düzenini gösterir. Değiştirilmediyse \"Teori\" yazar.")
        }
    }
}

/// Comma-interval editor for one makam.  Reached both from a workspace's
/// settings sheet and from the global Ayarlar tab, so the two entry points
/// stay in sync by construction.
struct iPadMakamIntervalsView: View {
    let makam: iPadMakam
    let store: iPadMakamIntervalsStore

    static func summary(for makam: iPadMakam, store: iPadMakamIntervalsStore) -> String {
        guard iPadMakamIntervalsStore.editableModes.contains(makam) else { return "Sabit" }
        return store.overrides[makam] == nil ? "Teori" : "Özel"
    }

    private var isEditable: Bool { iPadMakamIntervalsStore.editableModes.contains(makam) }
    private var values: [Int] { store.intervals(for: makam) }
    private var total: Int { values.reduce(0, +) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Toplam") {
                    HStack(spacing: 6) {
                        Text("\(total) koma").monospacedDigit()
                        Image(systemName: total == 53 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(total == 53 ? Color.green : Color.red)
                }
                ForEach(values.indices, id: \.self) { index in
                    intervalRow(index)
                }
            } footer: {
                if isEditable {
                    Text("Her aralık 1–13 koma. Toplam 53'e dönene kadar değişiklik kaydedilmez.")
                } else {
                    Text("Bu makam teorik düzenle sabittir; aralıkları değiştirilemez.")
                }
            }
            if isEditable {
                Section {
                    Button("Teoriye Dön") { store.reset(makam) }
                        .disabled(store.overrides[makam] == nil)
                }
            }
        }
        .navigationTitle("\(makam.rawValue) aralıkları")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func intervalRow(_ index: Int) -> some View {
        let value = values[index]
        if isEditable {
            Stepper(value: Binding(get: { value }, set: { update(index, to: $0) }), in: 1...13) {
                LabeledContent("\(index + 1). aralık") { Text("\(value)").monospacedDigit() }
            }
            .accessibilityValue("\(value) koma")
        } else {
            LabeledContent("\(index + 1). aralık") { Text("\(value)").monospacedDigit() }
        }
    }

    private func update(_ index: Int, to newValue: Int) {
        var next = values
        next[index] = newValue
        store.setIntervals(next, for: makam)
    }
}

/// Listening-mode settings.  Playback rate is a native ±Stepper over the rate
/// table's index, so the 39-row picker is gone but the macOS 0,05× contract
/// (and its end-of-range dimming) is preserved for free.
struct iPadStudySettingsSheet: View {
    @Bindable var study: iPadStudyState
    @Bindable var appState: iPadAppState
    let intervals: iPadMakamIntervalsStore
    /// iPad keeps its own "Takip" toggle in the control bar; only the compact
    /// layout surfaces it here.
    var showsFollowToggle = true
    @Environment(\.dismiss) private var dismiss

    private var rateIndex: Binding<Int> {
        Binding(
            get: { iPadStudyPlaybackRate.index(for: study.rate) },
            set: { study.setRate(iPadStudyPlaybackRate.rate(at: $0)) }
        )
    }

    private var micColorBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: appState.graphMicColor) },
            set: { appState.graphMicColor = $0.hexString }
        )
    }

    private var micAlignmentBinding: Binding<Double> {
        Binding(
            get: { appState.togetherMicAlignmentMs },
            set: { appState.togetherMicAlignmentMs = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: rateIndex, in: 0...(iPadStudyPlaybackRate.values.count - 1)) {
                        LabeledContent("Hız") {
                            Text(iPadStudyPlaybackRate.label(for: study.rate)).monospacedDigit()
                        }
                    }
                    .accessibilityLabel("Çalma hızı")
                    .accessibilityValue(iPadStudyPlaybackRate.label(for: study.rate))
                    if study.rate != 1.0 {
                        Button("Normal Hıza Dön") { study.setRate(1.0) }
                    }
                } header: {
                    Text("Oynatma")
                } footer: {
                    Text("0,10× – 2,00× arası, 0,05× adımlarla.")
                }
                if showsFollowToggle {
                    Section("Grafik") {
                        Toggle("Eğriyi takip et", isOn: Binding(get: { study.followsCurve }, set: { _ in study.toggleFollow() }))
                    }
                }
                Section {
                    ColorPicker("Mikrofon eğrisi rengi", selection: micColorBinding, supportsOpacity: false)
                } header: {
                    Text("Birlikte Çal")
                } footer: {
                    Text("Mikrofonla çaldığınız eğri bu renkle, referansın üstüne çizilir.")
                }
                Section {
                    Slider(value: micAlignmentBinding, in: -200...200, step: 5) {
                        Text("Mikrofon hizalama")
                    } minimumValueLabel: {
                        Text("−200").font(.caption).monospacedDigit()
                    } maximumValueLabel: {
                        Text("+200").font(.caption).monospacedDigit()
                    }
                    .accessibilityLabel("Mikrofon hizalama")
                    .accessibilityValue("\(Int(appState.togetherMicAlignmentMs)) milisaniye")
                    LabeledContent("Hizalama") {
                        Text("\(Int(appState.togetherMicAlignmentMs)) ms").monospacedDigit()
                    }
                    if appState.togetherMicAlignmentMs != 0 {
                        Button("Sıfırla") { appState.togetherMicAlignmentMs = 0 }
                    }
                    if let source = study.togetherLatencySource {
                        LabeledContent("Ölçülen gecikme") {
                            if let ms = study.togetherLatencyMilliseconds {
                                Text("\(Int(ms)) ms").monospacedDigit()
                            } else {
                                Text("—")
                            }
                        }
                        Text(source.rawValue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ölçüm için Birlikte Çal'ı bir kez açın.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mikrofon hizalama")
                } footer: {
                    Text("Bu ince ayardır: uygulama giriş gecikmesini cihazdan ölçer, kaydırıcı yalnız kalan sapmayı düzeltir. 5 ms adımlarla, −200…+200 ms arası.")
                }
                iPadMusicContextSection(
                    makam: Binding(get: { study.currentStudy?.context.makam ?? .nihavend }, set: { study.updateContext(makam: $0) }),
                    karar: Binding(get: { study.currentStudy?.context.karar ?? .re }, set: { study.updateContext(karar: $0) }),
                    intervals: intervals
                )
            }
            .navigationTitle("Dinleme Ayarları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Live-mode settings.  "Takip" stays on the control bar, so this sheet only
/// carries the musical context.
struct iPadLiveSettingsSheet: View {
    @Bindable var live: iPadLiveState
    let intervals: iPadMakamIntervalsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                iPadMusicContextSection(makam: $live.makam, karar: $live.karar, intervals: intervals)
            }
            .navigationTitle("Çalma Ayarları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
