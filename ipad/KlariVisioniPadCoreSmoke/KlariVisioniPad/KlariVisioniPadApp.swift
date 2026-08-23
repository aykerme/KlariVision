// KlariVision iPhone/iPad — evrensel uygulama girişi ve responsive kabuk.
// Compact genişlikte TabView, regular genişlikte NavigationSplitView kurulur;
// Study/Live state yeniden düzen sırasında korunur. Bu dosya ekranları
// birleştirir; analiz algoritması içermez.

import SwiftUI
import UniformTypeIdentifiers

@main
struct KlariVisioniPadApp: App {
    @State private var state = iPadAppState()

    var body: some Scene {
        WindowGroup {
            iPadRootView(state: state)
                .preferredColorScheme(state.theme.colorScheme)
        }
    }
}

struct iPadRootView: View {
    @Bindable var state: iPadAppState
    @State private var study = iPadStudyState()
    @State private var live = iPadLiveState()
    @State private var compactNavigation = iPadCompactNavigationState()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            study.handleSceneBackground()
            // LiveAnalyzer owns UIApplication.didEnterBackground handling so
            // the teardown has one reason-bearing source. A second nil-reason
            // stop here could win the race and leave compact UI in `.idle`
            // instead of the explicitly restartable `.interrupted` state.
        }
        .onAppear { configureGraphs() }
        .onChange(of: state.graphPitchColor) { _, _ in configureGraphs() }
        .onChange(of: state.graphGuideColor) { _, _ in configureGraphs() }
        // An edit in Settings' "Makam aralıkları" editor must relabel any
        // already-open graph immediately, not just future ones. Re-running
        // `configure` re-sends context on both sides (same shared store, so
        // this is just forcing the push, not changing what's referenced).
        .onChange(of: state.makamIntervals.overrides) { _, _ in configureGraphs() }
    }

    private func configureGraphs() {
        live.configure(graphPitchColor: state.graphPitchColor, guideColor: state.graphGuideColor, makamIntervals: state.makamIntervals)
        study.configure(graphPitchColor: state.graphPitchColor, guideColor: state.graphGuideColor, makamIntervals: state.makamIntervals)
    }

    @ViewBuilder private var regularBody: some View {
        NavigationSplitView {
            List {
                Section("GEZİNME") {
                    ForEach(iPadSection.allCases) { section in
                        Button {
                            Task {
                                if iPadNavigationSafety.stopsLive(whenMovingTo: section) { await live.stopForNavigation() }
                                if iPadNavigationSafety.pausesStudy(whenMovingTo: section) { study.pauseForLeavingWorkspace() }
                                state.selection = section
                            }
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .foregroundStyle(state.selection == section ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            state.selection == section
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                }
            }
            .navigationTitle("KlariVision")
        } detail: {
            switch state.selection {
            case .home: iPadHomeView(state: state, study: study, live: live, addRecordedStudy: addCompletedRecordingToStudies)
            case .library: iPadLibraryView(study: study, intervals: state.makamIntervals, retryCompletedRecording: retryCompletedRecording)
            case .settings: iPadSettingsView(state: state)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var compactBody: some View {
        switch compactNavigation.route {
        case .listening:
            iPadCompactStudyWorkspace(study: study, intervals: state.makamIntervals, close: { compactNavigation.closeWorkspace() }, retryCompletedRecording: retryCompletedRecording)
                .toolbar(.hidden, for: .tabBar)
        case .live:
            iPadCompactLiveWorkspace(state: state, live: live, study: study, close: { compactNavigation.closeWorkspace() }, addToStudies: addCompletedRecordingToStudies)
                .toolbar(.hidden, for: .tabBar)
        case .none:
            TabView(selection: Binding(get: { compactNavigation.section }, set: { destination in
                let decision = compactNavigation.select(destination)
                if decision.stopLive { Task { await live.stopForNavigation() } }
                if decision.pauseStudy { study.pauseForLeavingWorkspace() }
            })) {
                iPadCompactHomeView(state: state, study: study, live: live, onListening: { compactNavigation.openListening() }, onLive: { compactNavigation.openLive() }, addRecordedStudy: addCompletedRecordingToStudies)
                    .tabItem { Label(iPadSection.home.title, systemImage: iPadSection.home.symbol) }
                    .tag(iPadSection.home)
                iPadCompactLibraryView(study: study) { compactNavigation.openListening() }
                    .tabItem { Label(iPadSection.library.title, systemImage: iPadSection.library.symbol) }
                    .tag(iPadSection.library)
                NavigationStack { iPadSettingsView(state: state) }
                    .tabItem { Label(iPadSection.settings.title, systemImage: iPadSection.settings.symbol) }
                    .tag(iPadSection.settings)
            }
        }
    }

    private func addCompletedRecordingToStudies(_ recordingURL: URL) {
        Task {
            // Keep the URL captured by the completed-recording UI before the
            // asynchronous teardown; LiveState also retains it for a retry.
            await live.stopForNavigation()
            state.selection = .library
            compactNavigation.openListening()
            _ = await study.importAndAnalyze(recordingURL, engine: state.studyEngine, isCompletedRecording: true)
        }
    }

    private func retryCompletedRecording() {
        Task { _ = await study.retryCompletedRecording(engine: state.studyEngine) }
    }
}

private struct iPadHomeView: View {
    @Bindable var state: iPadAppState
    @Bindable var study: iPadStudyState
    @Bindable var live: iPadLiveState
    let addRecordedStudy: (URL) -> Void
    @State private var isPresentingImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bugün nasıl çalışmak istersin?")
                        .font(.largeTitle.bold())
                    Text("Yerel analizini dinle veya klarnetinle canlı çalış.")
                        .foregroundStyle(.secondary)
                }

                if live.phase == .running || live.phase == .requestingPermission {
                    iPadLiveWorkspace(live: live, study: study, intervals: state.makamIntervals, addToStudies: addRecordedStudy)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { modeCards }
                        VStack(spacing: 16) { modeCards }
                    }
                    if case let .interrupted(message) = live.phase { iPadLiveRestartCard(message: message, live: live, engine: state.liveEngine, signalGateDbFS: state.liveSignalGateDbFS) }
                    if case let .failed(message) = live.phase { iPadLiveRestartCard(message: message, live: live, engine: state.liveEngine, signalGateDbFS: state.liveSignalGateDbFS) }
                }
                if live.phase != .running && live.phase != .requestingPermission {
                    completedRecordingAction
                }
            }
            .padding(32)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Ana Sayfa")
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: iPadStudyImportService.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await study.importAndAnalyze(url, engine: state.studyEngine) }
            state.selection = .library
        }
    }

    @ViewBuilder private var completedRecordingAction: some View {
        if let url = live.completedRecordingURL {
            VStack(alignment: .leading, spacing: 10) {
                Text("WAV kaydı tamamlandı: \(url.lastPathComponent)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if study.hasImportedRecordedSource(url) {
                    Text("Bu kayıt Çalışmalar'a eklendi.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Çalışmalara Ekle") { addRecordedStudy(url) }
                        .buttonStyle(.borderedProminent)
                        .disabled(study.isImporting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var modeCards: some View {
        iPadModeCard(
            title: "Dinleme Modu",
            subtitle: "Ses veya video dosyanı analiz et, pitch eğrisini medya ile birlikte çalış.",
            symbol: "headphones",
            tint: .blue,
            action: "Dosya Seç"
        ) {
            isPresentingImporter = true
        }
        iPadModeCard(
            title: "Çalma Modu",
            subtitle: "Mikrofonla canlı pitch analizi yap, tüneri izle ve kaydet.",
            symbol: "mic.fill",
            tint: .green,
            action: "Başlat"
        ) { Task { await live.start(engine: state.liveEngine, signalGateDbFS: state.liveSignalGateDbFS) } }
    }
}

private struct iPadModeCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: String?
    var perform: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background(tint.opacity(0.13), in: Circle())
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action, let perform {
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(0.28)))
        .accessibilityElement(children: .combine)
    }
}

private struct iPadLiveRestartCard: View {
    let message: String
    @Bindable var live: iPadLiveState
    let engine: iPadPitchEngine
    let signalGateDbFS: Double

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView("Canlı çalışma durdu", systemImage: "mic.slash", description: Text(message))
            Button("Yeniden Başlat") { Task { await live.start(engine: engine, signalGateDbFS: signalGateDbFS) } }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct iPadLiveWorkspace: View {
    @Bindable var live: iPadLiveState
    @Bindable var study: iPadStudyState
    let intervals: iPadMakamIntervalsStore
    let addToStudies: (URL) -> Void
    @State private var isPresentingSettings = false

    private var frequency: String {
        guard let value = live.latestFrame?.frequency, value > 0 else { return "— Hz" }
        return String(format: "%.1f Hz", value)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(iPadTuner.label(for: live.latestFrame?.frequency)) · \(live.makam.rawValue) / \(live.karar.rawValue)").font(.largeTitle.bold()).monospacedDigit()
                    Text(frequency).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                iPadWorkspaceSettingsButton(label: "Makam ve karar") { isPresentingSettings = true }
                    .accessibilityValue("\(live.makam.rawValue), \(live.karar.rawValue)")
            }
            iPadLiveWebView(store: live.graph)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            HStack {
                Toggle("Eğriyi takip et", isOn: $live.followsCurve)
                Spacer()
                iPadRecordButton(recording: live.recording, isEnabled: live.phase == .running || live.recording == .active) { live.toggleRecording() }
                Button("Durdur") { live.stop() }
                    .buttonStyle(.borderedProminent).tint(.gray)
            }
            if case let .failed(message) = live.recording { Text(message).foregroundStyle(.red).font(.footnote) }
            if case let .completed(url) = live.recording {
                Text("Kayıt yerelde tamamlandı: \(url.lastPathComponent)").foregroundStyle(.secondary).font(.footnote)
                if study.hasImportedRecordedSource(url) {
                    Text("Bu WAV kaydı Çalışmalar'a eklendi.").foregroundStyle(.secondary).font(.footnote)
                } else {
                    Button("Çalışmalara Ekle") { addToStudies(url) }
                        .buttonStyle(.borderedProminent)
                        .disabled(study.isImporting)
                }
            }
        }
        .sheet(isPresented: $isPresentingSettings) {
            iPadLiveSettingsSheet(live: live, intervals: intervals)
        }
    }
}

private struct iPadLibraryView: View {
    @Bindable var study: iPadStudyState
    let intervals: iPadMakamIntervalsStore
    let retryCompletedRecording: () -> Void

    var body: some View {
        Group {
            switch study.phase {
            case .idle:
                if study.studies.isEmpty { ContentUnavailableView("Kayıt Bulunmadı", systemImage: "waveform.slash", description: Text("Dinleme Modu'ndan yerel bir ses veya video dosyası seçin.")) }
                else { iPadStudyLibraryList(study: study) }
            case .importing:
                iPadStudyProgressView(title: "Dosya hazırlanıyor", detail: "Dosya yalnız yerel çalışma alanına kopyalanıyor.", progress: nil)
            case let .analyzing(progress):
                iPadStudyProgressView(title: "Yerel pitch analizi yapılıyor", detail: "48 kHz mono Float32 kareleri seçtiğiniz motorla işleniyor.", progress: progress)
            case let .failed(message):
                VStack(spacing: 16) {
                    ContentUnavailableView("Çalışma Açılamadı", systemImage: "exclamationmark.triangle", description: Text(message))
                    if study.canRetryCompletedRecording {
                        Button("Çalışmalara Eklemeyi Yeniden Dene", action: retryCompletedRecording).buttonStyle(.borderedProminent)
                    }
                }
            case .ready:
                iPadStudyWorkspace(study: study, intervals: intervals)
            }
        }
        .navigationTitle("Çalışmalar")
    }
}

private struct iPadStudyLibraryList: View {
    @Bindable var study: iPadStudyState
    var body: some View {
        List(study.studies) { item in
            HStack { VStack(alignment: .leading) { Text(item.title); Text("\(item.context.makam.rawValue) · \(item.context.karar.rawValue)").font(.footnote).foregroundStyle(.secondary) }; Spacer(); Button("Aç") { study.open(item) }; Button("Kaldır", role: .destructive) { study.removeFromLibrary(item) } }
        }.navigationTitle("Çalışmalar")
    }
}

private struct iPadStudyProgressView: View {
    let title: String
    let detail: String
    let progress: Double?
    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress).progressViewStyle(.circular)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
        }.padding()
    }
}

private struct iPadStudyWorkspace: View {
    @Bindable var study: iPadStudyState
    let intervals: iPadMakamIntervalsStore
    @State private var isPresentingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            iPadStudyWebView(store: study.webView)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
            VStack(spacing: 12) {
                HStack {
                    TextField("Çalışma adı", text: Binding(get: { study.currentStudy?.title ?? "" }, set: { study.updateTitle($0) })).font(.headline)
                    Spacer()
                    Button("Kapat", role: .destructive) { study.close() }
                }
                // No position slider here either — scrubbing is the graph's own
                // one-finger horizontal drag, so the playhead stays centered.
                iPadStudyPositionReadout(time: study.playbackTime, duration: study.duration) { study.command(.seek($0)) }
                HStack(spacing: 12) {
                    Button(study.isPlaying ? "Duraklat" : "Oynat") { study.command(.playPause) }
                    Button("A'yı İşaretle") { study.command(.markA) }
                    Button("B'yi İşaretle") { study.command(.markB) }
                    Toggle("Loop", isOn: Binding(get: { study.looping }, set: { _ in study.command(.loop) }))
                    Toggle("Takip", isOn: Binding(get: { study.followsCurve }, set: { _ in study.command(.follow) }))
                    Spacer()
                    Text(iPadStudyPlaybackRate.label(for: study.rate)).monospacedDigit().foregroundStyle(.secondary)
                    iPadWorkspaceSettingsButton(label: "Çalışma ayarları") { isPresentingSettings = true }
                }
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $isPresentingSettings) {
            // "Takip" already has its own switch in this bar, so the sheet
            // omits it here and only the compact layout shows it.
            iPadStudySettingsSheet(study: study, intervals: intervals, showsFollowToggle: false)
        }
    }
}

private struct iPadSettingsView: View {
    @Bindable var state: iPadAppState

    var body: some View {
        Form {
            Section("Görünüm") {
                Picker("Uygulama teması", selection: $state.theme) {
                    ForEach(iPadTheme.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Dinleme Modu") {
                enginePicker("Pitch motoru", selection: $state.studyEngine)
            }
            Section("Çalma Modu") {
                enginePicker("Pitch motoru", selection: $state.liveEngine)
                Slider(value: $state.liveSignalGateDbFS, in: -60...(-20), step: 1) { Text("Sinyal kapısı") } minimumValueLabel: { Text("−60 dBFS") } maximumValueLabel: { Text("−20 dBFS") }
                Text("Sinyal kapısı: \(state.liveSignalGateDbFS, format: .number.precision(.fractionLength(0))) dBFS")
            }
            Section("Grafik renkleri") {
                TextField("Pitch rengi", text: $state.graphPitchColor)
                TextField("Kılavuz rengi", text: $state.graphGuideColor)
            }
            Section("53-koma aralıkları") {
                Text("Toplam: \(state.komaIntervals.reduce(0, +)) koma")
                ForEach(state.komaIntervals.indices, id: \.self) { index in
                    Stepper("Aralık \(index + 1): \(state.komaIntervals[index])", value: Binding(get: { state.komaIntervals[index] }, set: { value in var next = state.komaIntervals; next[index] = value; state.komaIntervals = next }), in: 1...12)
                }
                if !iPadAppState.validKomaIntervals(state.komaIntervals) { Text("Geçerli düzen 12 pozitif aralıktan ve toplam 53 komadan oluşmalıdır.").foregroundStyle(.red).font(.footnote) }
                Button("Varsayılan 53-koma düzenine dön") { state.resetKomaIntervals() }
            }
            // One editor, two entry points: this list and each workspace's
            // settings sheet push the same `iPadMakamIntervalsView`.
            Section("Makam aralıkları") {
                ForEach(iPadMakamIntervalsStore.editableModes) { makam in
                    NavigationLink {
                        iPadMakamIntervalsView(makam: makam, store: state.makamIntervals)
                    } label: {
                        LabeledContent(makam.rawValue, value: iPadMakamIntervalsView.summary(for: makam, store: state.makamIntervals))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ayarlar")
    }

    @ViewBuilder private func enginePicker(_ title: String, selection: Binding<iPadPitchEngine>) -> some View {
        Picker(title, selection: selection) {
            ForEach(iPadPitchEngine.allCases) { Text($0.title).tag($0) }
        }
        Text("YIN v1, Pitch Engine v2 ve VPM-benzeri eşit kullanıcı seçenekleridir.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
