// KlariVision macOS — Ayarlar ve Çalma modu SwiftUI bileşimi.
// Kullanıcı eylemlerini analizör ve grafik state'ine bağlar; ses algoritması
// içermez. Taslaklar yalnız “Uygula” ile kalıcı olur. Görünüm kapanırken
// medya/mikrofon oturumunu durdurmak ürün güvenliği sözleşmesidir.

import AppKit
import SwiftUI

struct SettingsSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let applyEnabled: Bool
    let apply: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("Bitti") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                content
                    .formStyle(.grouped)
                    .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Spacer()
                Button("Uygula", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!applyEnabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 520, height: 730)
    }
}
struct StudySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StudySettingsDraft
    @State private var intervalScale: LiveScale
    let apply: (StudySettingsDraft) -> Void

    init(draft: StudySettingsDraft, apply: @escaping (StudySettingsDraft) -> Void) {
        _draft = State(initialValue: draft)
        _intervalScale = State(initialValue: LiveMakamIntervals.makamScales.contains(LiveScale(rawValue: draft.scale) ?? .nihavent) ? LiveScale(rawValue: draft.scale)! : .nihavent)
        self.apply = apply
    }

    private var selectedIntervals: [Int] {
        draft.intervals[intervalScale.rawValue] ?? LiveMakamIntervals.defaults[intervalScale.rawValue]!
    }

    private var total: Int { selectedIntervals.reduce(0, +) }

    var body: some View {
        SettingsSheet(title: "Dinleme Modu Ayarları", applyEnabled: LiveMakamIntervals.isValid(draft.intervals), apply: {
            apply(draft)
            dismiss()
        }) {
            Form {
                Section("Görünüm") {
                    ColorPicker("Pitch eğrisi", selection: graphColorBinding(\.pitchHex))
                    ColorPicker("Nota kılavuzları", selection: graphColorBinding(\.noteGuideHex))
                    Button("Varsayılan renklere dön") { draft.graphAppearance = GraphAppearance() }
                }

                Section("Çalışma bağlamı") {
                    Picker("Makam / dizi", selection: $draft.scale) {
                        ForEach(LiveScale.allCases) { scale in
                            Text(scale.title).tag(scale.rawValue)
                        }
                    }
                    Picker("Karar", selection: $draft.tonic) {
                        ForEach([0, 2, 4, 5, 7, 9, 11], id: \.self) { note in
                            Text(noteName(note)).tag(note)
                        }
                    }
                    Stepper("Geri sayım: \(draft.countdown) sn", value: $draft.countdown, in: 0...60)
                }

                intervalSection
            }
        }
    }

    private var intervalSection: some View {
        Section("Makam Aralıkları") {
            Text("Yedi aralık toplamı bir oktavda 53 koma olmalıdır.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Makam", selection: $intervalScale) {
                ForEach(LiveMakamIntervals.makamScales) { scale in Text(scale.title).tag(scale) }
            }
            ForEach(Array(selectedIntervals.enumerated()), id: \.offset) { index, _ in
                Picker("Aralık \(index + 1)", selection: intervalBinding(at: index)) {
                    ForEach(1...13, id: \.self) { koma in Text("\(koma) koma").tag(koma) }
                }
            }
            HStack {
                Text("Toplam: \(total) / 53 koma").foregroundStyle(total == 53 ? .green : .red)
                Spacer()
                Button("Teoriye Dön") { draft.intervals[intervalScale.rawValue] = LiveMakamIntervals.defaults[intervalScale.rawValue] }
            }
        }
    }

    private func intervalBinding(at index: Int) -> Binding<Int> {
        Binding(get: { selectedIntervals[index] }, set: { value in
            var values = selectedIntervals
            values[index] = value
            draft.intervals[intervalScale.rawValue] = values
        })
    }

    private func graphColorBinding(_ keyPath: WritableKeyPath<GraphAppearance, String>) -> Binding<Color> {
        Binding(get: { GraphAppearance.color(hex: draft.graphAppearance[keyPath: keyPath]) }, set: { color in
            if let hex = GraphAppearance.hex(from: color) { draft.graphAppearance[keyPath: keyPath] = hex }
        })
    }
}

struct LivePracticeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var intervals: [String: [Int]]
    @State private var selectedScale: LiveScale
    @State private var draft: [String: [Int]]
    @State private var draftGraphAppearance: GraphAppearance

    init(intervals: Binding<[String: [Int]]>, selectedScale: LiveScale) {
        _intervals = intervals
        _selectedScale = State(initialValue: LiveMakamIntervals.makamScales.contains(selectedScale) ? selectedScale : .nihavent)
        _draft = State(initialValue: intervals.wrappedValue)
        _draftGraphAppearance = State(initialValue: GraphAppearance.stored())
    }

    private var selectedIntervals: [Int] {
        draft[selectedScale.rawValue] ?? LiveMakamIntervals.defaults[selectedScale.rawValue]!
    }

    private var total: Int { selectedIntervals.reduce(0, +) }

    var body: some View {
        SettingsSheet(title: "Çalma Modu Ayarları", applyEnabled: total == 53 && LiveMakamIntervals.isValid(draft), apply: {
            intervals = draft
            LiveMakamIntervals.save(draft)
            draftGraphAppearance.save()
            dismiss()
        }) {
            Form {
                Section("Grafik renkleri") {
                    ColorPicker("Pitch eğrisi", selection: graphColorBinding(\.pitchHex))
                    ColorPicker("Nota kılavuzları", selection: graphColorBinding(\.noteGuideHex))
                    Button("Varsayılan renklere dön") {
                        draftGraphAppearance = GraphAppearance()
                    }
                }

                Section("Sinyal Kapısı") {
                    SignalGateControls()
                }

                Section("Makam Aralıkları") {
                    Text("Yedi aralık toplamı bir oktavda 53 koma olmalıdır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Makam", selection: $selectedScale) {
                        ForEach(LiveMakamIntervals.makamScales) { scale in
                            Text(scale.title).tag(scale)
                        }
                    }

                    ForEach(Array(selectedIntervals.enumerated()), id: \.offset) { index, value in
                        Picker("Aralık \(index + 1)", selection: intervalBinding(at: index)) {
                            ForEach(1...13, id: \.self) { koma in
                                Text("\(koma) koma").tag(koma)
                            }
                        }
                    }

                    HStack {
                        Text("Toplam: \(total) / 53 koma")
                            .foregroundStyle(total == 53 ? .green : .red)
                        Spacer()
                        Button("Teoriye Dön") {
                            draft[selectedScale.rawValue] = LiveMakamIntervals.defaults[selectedScale.rawValue]
                        }
                    }

                }
            }
        }
    }

    private func intervalBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: { selectedIntervals[index] },
            set: { value in
                var values = selectedIntervals
                values[index] = value
                draft[selectedScale.rawValue] = values
            }
        )
    }

    private func graphColorBinding(_ keyPath: WritableKeyPath<GraphAppearance, String>) -> Binding<Color> {
        Binding(
            get: { GraphAppearance.color(hex: draftGraphAppearance[keyPath: keyPath]) },
            set: { color in
                if let hex = GraphAppearance.hex(from: color) {
                    draftGraphAppearance[keyPath: keyPath] = hex
                }
            }
        )
    }
}

struct LivePracticeView: View {
    @StateObject private var analyzer = LivePitchAnalyzer()
    @State private var scale: LiveScale = .nihavent
    @State private var tonic = 9
    @State private var followsCurve = true
    @State private var visibleDuration = 12.0
    @State private var verticalSpan = 2_400.0
    @State private var verticalCenter = 0.0
    @State private var showsSignalSettings = false
    @State private var makamIntervals = LiveMakamIntervals.load()
    @State private var stopMicrophoneAfterSignalSettings = false
    @State private var recordingButtonDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(GraphAppearance.pitchColorKey) private var graphPitchHex = GraphAppearance.defaultPitchHex
    @AppStorage(GraphAppearance.noteGuideColorKey) private var graphNoteGuideHex = GraphAppearance.defaultNoteGuideHex
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) {
                    Label("Çalışmalara Dön", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 18)

                Label("Çalma Modu", systemImage: "mic.fill")
                    .font(.headline)

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)

            VStack(spacing: 12) {
                practiceControls

                LivePitchGraph(
                        frames: analyzer.frames,
                        appearance: GraphAppearance(pitchHex: graphPitchHex, noteGuideHex: graphNoteGuideHex),
                        scale: scale,
                        tonic: tonic,
                        makamIntervals: activeMakamIntervals,
                        followsCurve: followsCurve,
                        graphTime: analyzer.graphTime,
                        graphNow: analyzer.graphNow,
                        isAnimating: analyzer.isRunning || analyzer.isReferenceTestRunning,
                        visibleDuration: $visibleDuration,
                        verticalSpan: $verticalSpan,
                        verticalCenter: $verticalCenter,
                        onScroll: handleGraphScroll,
                        onVerticalDrag: handleGraphVerticalDrag
                    )
                .frame(minHeight: 330, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))

                Text("Tekerlek: zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showsSignalSettings, onDismiss: restoreMicrophoneAfterSignalSettings) {
            LivePracticeSettingsView(intervals: $makamIntervals, selectedScale: scale)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    presentSignalSettings()
                } label: {
                    Label("Ayarlar", systemImage: "slider.horizontal.3")
                }
                .help("Canlı sinyal eşiğini, ses seviyesini ve makam aralıklarını ayarla")
                .disabled(analyzer.isBenchmarkRunning || analyzer.isReferenceTestRunning)
            }
        }
        .onDisappear { analyzer.stop() }
        .onChange(of: analyzer.frames.count) {
            updateVerticalFollow()
        }
        .onChange(of: analyzer.isRecording) { _, isRecording in
            if isRecording {
                recordingButtonDimmed = false
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        recordingButtonDimmed = true
                    }
                }
            } else {
                withAnimation(.none) {
                    recordingButtonDimmed = false
                }
            }
        }
    }

    private func presentSignalSettings() {
        // A closed microphone is opened only while this sheet is visible so
        // the musician can set the threshold against a real VU reading.  On
        // dismissal we restore exactly that earlier off state.
        stopMicrophoneAfterSignalSettings = !analyzer.isRunning
        if stopMicrophoneAfterSignalSettings {
            analyzer.toggle()
        }
        showsSignalSettings = true
    }

    private func restoreMicrophoneAfterSignalSettings() {
        guard stopMicrophoneAfterSignalSettings else { return }
        stopMicrophoneAfterSignalSettings = false
        analyzer.stop()
    }

    private var activeMakamIntervals: [Int] {
        makamIntervals[scale.rawValue] ?? scale.intervals.map { Int($0) }
    }

    private var practiceControls: some View {
        ViewThatFits(in: .horizontal) {
            ZStack {
                HStack(alignment: .center) {
                    primaryPracticeControls
                        .frame(width: 300, alignment: .leading)

                    Spacer(minLength: 460)

                    secondaryPracticeControls
                        .frame(width: 280, alignment: .trailing)
                }

                tuner
            }
            // Reserve each side group before accepting the horizontal layout,
            // so the tuner stays at the graph's actual horizontal centre.
            .frame(minWidth: 1_040, minHeight: 132)

            VStack(spacing: 12) {
                tuner
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(alignment: .top, spacing: 20) {
                    primaryPracticeControls

                    Spacer(minLength: 20)

                    secondaryPracticeControls
                }
            }
        }
    }

    private var primaryPracticeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    analyzer.toggle()
                } label: {
                    Label(analyzer.isRunning ? "Durdur" : "Mikrofonu Başlat", systemImage: analyzer.isRunning ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    analyzer.toggleRecording()
                } label: {
                    Label(
                        analyzer.isRecording ? "Kaydı Durdur" : "Kayıt",
                        systemImage: analyzer.isRecording ? "stop.circle.fill" : "record.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .opacity(analyzer.isRecording && recordingButtonDimmed ? 0.45 : 1)
                .help(analyzer.isRecording ? "Kaydı durdur ve kaydet" : "Mikrofon sesini kaydet")
            }

            Toggle("Eğriyi takip et", isOn: $followsCurve)
                .toggleStyle(.switch)

            Text(analyzer.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel(AccessibilityText.practiceStatus)
                .accessibilityValue(analyzer.status)
        }
    }

    private var secondaryPracticeControls: some View {
        HStack(spacing: 8) {
            Picker("Makam", selection: $scale) {
                ForEach(LiveScale.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("Karar", selection: $tonic) {
                ForEach([0, 2, 4, 5, 7, 9, 11], id: \.self) { note in
                    Text(noteName(note)).tag(note)
                }
            }
            .labelsHidden()
            .frame(width: 76)

            Button {
                visibleDuration = 12
                verticalSpan = 2_400
                verticalCenter = 0
                followsCurve = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Canlı görünümü sıfırla")
            .accessibilityLabel("Canlı görünümü sıfırla")
            .accessibilityHint("Grafiğin zaman ve perde ölçeğini başlangıç değerlerine getirir.")
        }
    }

    private var tuner: some View {
        TunerPanel(
            frequency: analyzer.currentFrequency,
            scale: scale,
            tonic: tonic,
            intervals: activeMakamIntervals
        )
        .frame(width: 420)
    }

    private func handleGraphScroll(_ event: LiveGraphScrollEvent) {
        let factor = event.deltaY > 0 ? 0.86 : 1.16
        if event.shiftPressed {
            verticalSpan = min(4_800, max(240, verticalSpan * factor))
            return
        }

        let oldDuration = visibleDuration
        let nextDuration = min(60, max(2, oldDuration * factor))
        guard nextDuration != oldDuration else { return }
        visibleDuration = nextDuration
    }

    private func handleGraphVerticalDrag(_ event: LiveGraphVerticalDragEvent) {
        // A manual pan must take ownership from automatic follow. Start at
        // the currently displayed live pitch so the graph does not jump when
        // the user begins dragging.
        if followsCurve {
            if let latest = analyzer.frames.max(by: { $0.time < $1.time }) {
                verticalCenter = 1_200 * log2(latest.frequency / 440)
            }
            followsCurve = false
        }
        let drawableHeight = max(1, event.size.height - 44)
        verticalCenter += Double(event.deltaY / drawableHeight) * verticalSpan
    }

    private func updateVerticalFollow() {
        guard followsCurve,
              let latest = analyzer.frames.max(by: { $0.time < $1.time }) else { return }
        let pitch = 1_200 * log2(latest.frequency / 440)
        // Keep a small visual buffer above and below the curve. The display
        // remains still while the current point is visible; it moves only as
        // the point approaches an edge, then brings it modestly back inside.
        let edge = verticalSpan * 0.45
        let restingEdge = verticalSpan * 0.35
        if pitch > verticalCenter + edge {
            verticalCenter = pitch - restingEdge
        } else if pitch < verticalCenter - edge {
            verticalCenter = pitch + restingEdge
        }
    }

}
