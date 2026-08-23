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
    @State private var isPresentingSettings = false

    private var frequency: String {
        guard let value = live.latestFrame?.frequency, value > 0 else { return "— Hz" }
        return String(format: "%.1f Hz", value)
    }

    private var isRunning: Bool { live.phase == .running }

    var body: some View {
        NavigationStack {
            // Same shape as the listening workspace: the graph owns the whole
            // surface (it can extend past the bottom safe area) and the
            // controls float on top instead of claiming a fixed strip. The top
            // safe area is left alone so the tuner badge sits below the
            // navigation bar rather than under its title.
            ZStack(alignment: .bottom) {
                iPadLiveWebView(store: live.graph)
                    .ignoresSafeArea(edges: .bottom)
                controls
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .overlay(alignment: .top) { tunerBadge }
            .navigationTitle("Çalma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { Task { await live.stopForNavigation(); close() } }
                        .accessibilityHint("Canlı analizi durdurur ve çalışma ekranını kapatır")
                }
            }
        }
    }

    /// Native, not HTML: the graph page is pinch/pan-driven and WKWebView owns
    /// no chrome of its own, so the readout lives outside the WebView where no
    /// gesture can move it.
    private var tunerBadge: some View {
        VStack(spacing: 0) {
            Text(iPadTuner.label(for: live.latestFrame?.frequency)).font(.title3.bold()).monospacedDigit()
            Text(frequency).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityLabel("Frekans")
                .accessibilityValue(frequency)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tüner")
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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .sheet(isPresented: $isPresentingSettings) {
            iPadLiveSettingsSheet(live: live, intervals: state.makamIntervals)
        }
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
        iPadWorkspaceSettingsButton(label: "Makam ve karar") { isPresentingSettings = true }
            .accessibilityValue("\(live.makam.rawValue), \(live.karar.rawValue)")
        iPadRecordButton(recording: live.recording, isEnabled: isRunning || live.recording == .active) { live.toggleRecording() }
        if isRunning || live.phase == .requestingPermission {
            Button("Durdur") { Task { await live.stopForNavigation(); close() } }
                .buttonStyle(.borderedProminent).tint(.gray).frame(minHeight: 44)
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
