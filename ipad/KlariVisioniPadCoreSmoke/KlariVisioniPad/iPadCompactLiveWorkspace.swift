// KlariVision iPhone — compact genişlikte Çalma çalışma alanı.
// LiveState phase/kayıt/tüner değerlerini sunar; görünüm yalnız başlatma,
// durdurma ve “Çalışmalara Ekle” niyetlerini iletir. Ses motoru sahiplenmez.

import SwiftUI

struct iPadCompactLiveWorkspace: View {
    @Bindable var state: iPadAppState
    @Bindable var live: iPadLiveState
    @Bindable var study: iPadStudyState
    let close: () -> Void
    let addToStudies: (URL) -> Void

    private var frequency: String {
        guard let value = live.latestFrame?.frequency, value > 0 else { return "— Hz" }
        return String(format: "%.1f Hz", value)
    }

    private var isRunning: Bool { live.phase == .running }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(iPadTuner.label(for: live.latestFrame?.frequency)).font(.title.bold()).monospacedDigit()
                    Text(frequency).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel("Frekans")
                        .accessibilityValue(frequency)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tüner")
                iPadLiveWebView(store: live.graph)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 8)
            }
            .padding(.top, 10)
            .navigationTitle("Çalma")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { controls }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { Task { await live.stopForNavigation(); close() } }
                        .accessibilityHint("Canlı analizi durdurur ve çalışma ekranını kapatır")
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            if case let .failed(message) = live.phase { status(message, color: .red) }
            if case let .interrupted(message) = live.phase { status(message, color: .orange) }
            if case .requestingPermission = live.phase { status("Mikrofon izni bekleniyor…", color: .secondary) }
            if case let .completed(url) = live.recording {
                recordingResult(url)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 8) { buttons }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .background(.regularMaterial)
    }

    @ViewBuilder private func recordingResult(_ url: URL) -> some View {
        Text("WAV kaydı tamamlandı: \(url.lastPathComponent)").font(.footnote).foregroundStyle(.secondary)
            .lineLimit(1).accessibilityLabel("WAV kaydı tamamlandı")
        if study.hasImportedRecordedSource(url) {
            Text("Bu kayıt Çalışmalar'a eklendi.").font(.footnote).foregroundStyle(.secondary)
        } else {
            Button("Çalışmalara Ekle") { addToStudies(url) }
                .buttonStyle(.borderedProminent)
                .disabled(study.isImporting)
                .accessibilityHint("Kaydı seçili Dinleme motoruyla analiz eder")
        }
    }

    @ViewBuilder private var buttons: some View {
        Toggle(isOn: $live.followsCurve) { Label("Takip", systemImage: "scope") }
            .toggleStyle(.button).frame(minHeight: 44)
            .accessibilityLabel("Eğriyi takip et")
        Menu {
            Picker("Makam", selection: $live.makam) { ForEach(iPadMakam.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Karar", selection: $live.karar) { ForEach(iPadKarar.allCases) { Text($0.rawValue).tag($0) } }
        } label: { Label("Makam / Karar", systemImage: "music.note.list") }
            .frame(minHeight: 44)
            .accessibilityLabel("Makam ve karar")
            .accessibilityValue("\(live.makam.rawValue), \(live.karar.rawValue)")
        Button(live.recording == .active ? "Kaydı Bitir" : "WAV Kaydı") { live.toggleRecording() }
            .buttonStyle(.bordered).frame(minHeight: 44)
            .disabled(!isRunning && live.recording != .active)
            .accessibilityLabel(live.recording == .active ? "WAV kaydını bitir" : "WAV kaydı başlat")
        if isRunning || live.phase == .requestingPermission {
            Button("Durdur", role: .destructive) { Task { await live.stopForNavigation(); close() } }
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
        } else {
            Button("Yeniden Başlat") { Task { await live.start(engine: state.liveEngine, signalGateDbFS: state.liveSignalGateDbFS) } }
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
        }
    }

    private func status(_ message: String, color: Color) -> some View {
        Text(message).font(.footnote).foregroundStyle(color).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).accessibilityLabel(message)
    }
}

struct iPadCompactHomeView: View {
    @Bindable var state: iPadAppState
    @Bindable var study: iPadStudyState
    @Bindable var live: iPadLiveState
    let onListening: () -> Void
    let onLive: () -> Void
    let addRecordedStudy: (URL) -> Void
    @State private var isPresentingImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Bugün nasıl çalışmak istersin?").font(.largeTitle.bold())
                    Text("Yerel analizini dinle veya klarnetinle canlı çalış.").foregroundStyle(.secondary)
                    compactCard(title: "Dinleme Modu", subtitle: "Ses veya video dosyanı analiz et.", symbol: "headphones", tint: .blue, action: "Dosya Seç") { isPresentingImporter = true }
                    compactCard(title: "Çalma Modu", subtitle: "Mikrofonla canlı pitch analizi yap.", symbol: "mic.fill", tint: .green, action: "Başlat") {
                        onLive()
                        Task { await live.start(engine: state.liveEngine, signalGateDbFS: state.liveSignalGateDbFS) }
                    }
                    if case let .completed(url) = live.recording {
                        if study.hasImportedRecordedSource(url) {
                            Text("Bu WAV kaydı Çalışmalar'a eklendi.").foregroundStyle(.secondary)
                        } else {
                            Button("Çalışmalara Ekle") { addRecordedStudy(url) }
                                .buttonStyle(.borderedProminent)
                                .disabled(study.isImporting)
                                .accessibilityHint("Kaydı seçili Dinleme motoruyla analiz eder")
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Ana Sayfa")
            .fileImporter(isPresented: $isPresentingImporter, allowedContentTypes: iPadStudyImportService.supportedTypes, allowsMultipleSelection: false) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                onListening()
                Task { await study.importAndAnalyze(url, engine: state.studyEngine) }
            }
        }
    }

    private func compactCard(title: String, subtitle: String, symbol: String, tint: Color, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(tint)
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
            Button(action, action: perform).buttonStyle(.borderedProminent).tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
}
