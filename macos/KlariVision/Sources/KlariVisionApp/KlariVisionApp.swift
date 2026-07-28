import AppKit
import SwiftUI
import WebKit

@main
struct KlariVisionApp: App {
    @State private var library = RecentLibrary()

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
        }
        .defaultSize(width: 1100, height: 740)

        Settings {
            SettingsView()
        }
    }
}

@Observable
@MainActor
final class RecentLibrary {
    struct Item: Codable, Identifiable, Hashable {
        let viewerURL: String
        let label: String
        let analysedAt: String
        let cacheHit: Bool

        var id: String { viewerURL }

        enum CodingKeys: String, CodingKey {
            case viewerURL = "viewer_url"
            case label
            case analysedAt = "analysed_at"
            case cacheHit = "cache_hit"
        }
    }

    struct StudyMetadata: Codable, Hashable {
        var title: String
        var makam: String
        var karar: Int
    }

    private(set) var items: [Item] = []
    private var studyMetadata: [String: StudyMetadata] = [:]
    private(set) var selectedFile: URL?
    private(set) var isAnalysing = false
    private(set) var analysisMessage = ""
    private(set) var activeViewer: URL?
    var mediaLink = ""

    init() {
        reload()
    }

    func reload() {
        if let metadataData = try? Data(contentsOf: metadataURL()),
           let stored = try? JSONDecoder().decode([String: StudyMetadata].self, from: metadataData) {
            studyMetadata = stored
        }
        for root in dataRoots() {
            let file = root.appending(path: "data/recent_analyses.json")
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode([Item].self, from: data) else { continue }
            items = decoded
            return
        }
        items = []
    }

    func study(for item: Item) -> StudyMetadata {
        studyMetadata[item.id] ?? StudyMetadata(title: item.label, makam: "major", karar: 0)
    }

    func studySummary(for item: Item) -> String {
        let study = study(for: item)
        return "\(makamName(study.makam)) · \(kararName(study.karar)) karar"
    }

    func saveStudy(_ item: Item, title: String, makam: String, karar: Int) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        studyMetadata[item.id] = StudyMetadata(
            title: cleanedTitle.isEmpty ? item.label : cleanedTitle,
            makam: makam,
            karar: karar
        )
        let destination = metadataURL()
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(studyMetadata) {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func metadataURL() -> URL {
        dataRoots().first!.appending(path: "data/study_metadata.json")
    }

    func makamName(_ value: String) -> String {
        [
            "major": "Majör", "minor": "Minör", "nihavent": "Nihavend", "kurdi": "Kürdi",
            "ussak": "Uşşak", "hicaz": "Hicaz", "kurdilihicazkar": "Kürdilihicazkâr", "hicazkar": "Hicazkâr",
        ][value] ?? "Majör"
    }

    func kararName(_ value: Int) -> String {
        [0: "Do", 2: "Re", 4: "Mi", 5: "Fa", 7: "Sol", 9: "La", 11: "Si"][value] ?? "Do"
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectFile(url)
        }
    }

    func selectFile(_ url: URL) {
        selectedFile = url
        analyseSelectedFile()
    }

    func analyseSelectedFile() {
        guard let selectedFile, !isAnalysing else { return }
        if let bundledEngine = bundledEngineExecutable() {
            analyseWithBundledEngine(selectedFile, executable: bundledEngine)
            return
        }
        guard let root = projectRoot() else {
            analysisMessage = "KlariVision analiz motoru bulunamadı. Projeyi Xcode içinden açtığından emin ol."
            return
        }
        guard let python = pythonExecutable(in: root) else {
            analysisMessage = "Python çalışma ortamı bulunamadı."
            return
        }

        isAnalysing = true
        analysisMessage = "Pitch analizi hazırlanıyor…"
        let sourcePath = selectedFile.path.replacingOccurrences(of: "\\\"", with: "\\\\\\\"")
        let script = """
        from pathlib import Path
        from klarivision.local_app import analyse_upload
        print(analyse_upload(Path(\"\(sourcePath)\"), \"huzzam\", \"dugah\", \"vamp\"))
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", script]
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = root.appending(path: "src").path
            process.environment = environment
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
                let standardOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAnalysing = false
                    guard process.terminationStatus == 0,
                          let relativeViewer = standardOutput.split(whereSeparator: \.isNewline).last else {
                        let detail = standardError.isEmpty ? "Lütfen tekrar dene." : standardError
                        self.analysisMessage = "Analiz oluşturulamadı. \(detail)"
                        return
                    }
                    let viewer = root.appending(path: String(relativeViewer).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    self.analysisMessage = "Pitch eğrisi hazır."
                    self.activeViewer = viewer
                    self.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAnalysing = false
                    self?.analysisMessage = "Analiz motoru başlatılamadı: \(error.localizedDescription)"
                }
            }
        }
    }

    private func analyseWithBundledEngine(_ source: URL, executable: URL) {
        isAnalysing = true
        analysisMessage = "Pitch analizi hazırlanıyor…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = [source.path, "--makam", "huzzam", "--karar", "dugah", "--engine", "vamp"]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
                let standardOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAnalysing = false
                    guard process.terminationStatus == 0,
                          let viewerPath = standardOutput.split(whereSeparator: \.isNewline).last else {
                        let detail = standardError.isEmpty ? "Lütfen tekrar dene." : standardError
                        self.analysisMessage = "Analiz oluşturulamadı. \(detail)"
                        return
                    }
                    self.analysisMessage = "Pitch eğrisi hazır."
                    self.activeViewer = URL(fileURLWithPath: String(viewerPath))
                    self.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAnalysing = false
                    self?.analysisMessage = "Analiz motoru başlatılamadı: \(error.localizedDescription)"
                }
            }
        }
    }

    func explainLinkImport() {
        analysisMessage = "Bağlantıdan içe aktarma bir sonraki native adımda açılacak."
    }

    func open(_ item: Item) {
        for root in dataRoots() {
            let relativePath = item.viewerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let viewer = root.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: viewer.path) {
                if let bundledEngine = bundledEngineExecutable() {
                    refreshWithBundledEngine(viewer, executable: bundledEngine)
                } else {
                    activeViewer = viewer
                }
                return
            }
        }
    }

    func item(for viewer: URL) -> Item? {
        for root in dataRoots() where viewer.path.hasPrefix(root.path) {
            let relative = "/" + viewer.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return items.first(where: { $0.viewerURL == relative })
        }
        return nil
    }

    private func refreshWithBundledEngine(_ viewer: URL, executable: URL) {
        isAnalysing = true
        analysisMessage = "Çalışma güncel arayüzle hazırlanıyor…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--refresh-viewer", viewer.path]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
                let standardOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAnalysing = false
                    if process.terminationStatus == 0,
                       let refreshedPath = standardOutput.split(whereSeparator: \.isNewline).last {
                        self.activeViewer = URL(fileURLWithPath: String(refreshedPath))
                    } else {
                        // A legacy item can still be opened if a very old cache
                        // no longer contains every file needed for refresh.
                        self.activeViewer = viewer
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAnalysing = false
                    self?.activeViewer = viewer
                }
            }
        }
    }

    func closeWorkspace() {
        activeViewer = nil
        selectedFile = nil
        analysisMessage = ""
    }

    func viewerReadAccessRoot(for viewer: URL) -> URL {
        dataRoots().first(where: { viewer.path.hasPrefix($0.path) }) ?? viewer.deletingLastPathComponent()
    }

    private func dataRoots() -> [URL] {
        let manager = FileManager.default
        let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "KlariVision")
        var roots = [appSupport]
        var cursor = URL(fileURLWithPath: manager.currentDirectoryPath)
        for _ in 0..<5 {
            roots.append(cursor)
            cursor.deleteLastPathComponent()
        }
        return roots
    }

    private func projectRoot() -> URL? {
        for root in dataRoots() {
            if FileManager.default.fileExists(atPath: root.appending(path: "src/klarivision/local_app.py").path) {
                return root
            }
        }
        let documentsRoot = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents/KlariVision")
        return FileManager.default.fileExists(atPath: documentsRoot.appending(path: "src/klarivision/local_app.py").path) ? documentsRoot : nil
    }

    private func pythonExecutable(in root: URL) -> URL? {
        let candidates = [root.appending(path: ".venv/bin/python"), URL(fileURLWithPath: "/usr/bin/python3")]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func bundledEngineExecutable() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let executable = resources.appending(path: "Engine/KlariVisionEngine")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }
}

struct WelcomeView: View {
    @Bindable var library: RecentLibrary
    @State private var isDropTarget = false

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    if library.items.isEmpty {
                        ContentUnavailableView {
                            Label("Kayıt Bulunmadı", systemImage: "waveform.slash")
                        } description: {
                            Text("Henüz analiz edilmiş bir çalışma yok.")
                        }
                        .padding(.vertical, 20)
                    } else {
                        ForEach(library.items) { item in
                            Button {
                                library.open(item)
                            } label: {
                                RecentRow(
                                    item: item,
                                    title: library.study(for: item).title,
                                    summary: library.studySummary(for: item)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(item.label)
                        }
                    }
                } header: {
                    Text("Son Çalışmalar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("KlariVision")
        } detail: {
            if let viewer = library.activeViewer {
                WorkspaceView(viewer: viewer, library: library)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Hero / Başlık Bölümü
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 52, height: 52)
                                Image(systemName: "waveform.path.ecg")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Yeni Analiz Çalışması")
                                    .font(.title2.weight(.bold))
                                Text("Makam ve pitch eğrisi analizi için bir ses veya video dosyası yükleyin.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Sürükle-Bırak Alanı
                        DropZone(isTargeted: $isDropTarget, selectedFile: library.selectedFile) {
                            library.chooseFile()
                        }
                        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                            guard let provider = providers.first else { return false }
                            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { value, _ in
                                guard let url = value as? URL else { return }
                                Task { @MainActor in library.selectFile(url) }
                            }
                            return true
                        }

                        // Analiz Durum Paneli
                        if library.selectedFile != nil || !library.analysisMessage.isEmpty {
                            HStack(spacing: 12) {
                                if library.isAnalysing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(library.analysisMessage)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        }

                        // Bağlantı ile İçe Aktarma Kartı
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Bağlantıdan İçe Aktar", systemImage: "link")
                                .font(.headline)

                            HStack(spacing: 10) {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(.tertiary)
                                    TextField("YouTube veya video bağlantısı yapıştırın…", text: $library.mediaLink)
                                        .textFieldStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                                Button("İçe Aktar") {
                                    library.explainLinkImport()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(library.mediaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            Text("Çevrimiçi akış kaynaklarından pitch analizi alma özelliği yakında native olarak sunulacaktır.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
                    }
                    .padding(36)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        }
    }
}

private struct WorkspaceView: View {
    let viewer: URL
    @Bindable var library: RecentLibrary
    @State private var webView: WKWebView?
    @State private var isEditingStudy = false

    var body: some View {
        VStack(spacing: 0) {
            // macOS Görünümüne Uygun Üst Bar
            HStack(spacing: 14) {
                Button {
                    library.closeWorkspace()
                } label: {
                    Label("Geri", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Divider()
                    .frame(height: 16)

                Image(systemName: "waveform")
                    .foregroundStyle(.tint)

                Text(library.item(for: viewer).map { library.study(for: $0).title } ?? viewer.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button {
                    webView?.evaluateJavaScript("document.getElementById('makam-settings-open')?.click()")
                } label: {
                    Label("Makam Ayarları", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .disabled(webView == nil)

                Button {
                    isEditingStudy = true
                } label: {
                    Label("Çalışmayı Düzenle", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(library.item(for: viewer) == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }

            LocalViewer(
                viewer: viewer,
                readAccessRoot: library.viewerReadAccessRoot(for: viewer),
                study: library.item(for: viewer).map { library.study(for: $0) },
                webView: $webView
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $isEditingStudy) {
            if let item = library.item(for: viewer) {
                StudyEditor(item: item, library: library) { makam, karar in
                    applyStudyContext(makam: makam, karar: karar)
                }
            }
        }
    }

    private func applyStudyContext(makam: String, karar: Int) {
        webView?.evaluateJavaScript("""
        (() => {
            const scale = document.getElementById('scale-mode');
            const tonic = document.getElementById('tonic');
            if (scale) { scale.value = '\(makam)'; scale.dispatchEvent(new Event('change')); }
            if (tonic) { tonic.value = '\(karar)'; tonic.dispatchEvent(new Event('change')); }
        })();
        """)
    }
}

private struct LocalViewer: NSViewRepresentable {
    let viewer: URL
    let readAccessRoot: URL
    let study: RecentLibrary.StudyMetadata?
    @Binding var webView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let hideStandaloneControls = """
        (() => {
            document.body.classList.add('native-shell');
            const newRecording = document.getElementById('new-recording');
            if (newRecording) newRecording.style.display = 'none';
            const makamSettings = document.getElementById('makam-settings-open');
            if (makamSettings) makamSettings.style.display = 'none';
        })();
        """
        let studyContext = study.map {
            """
            (() => {
                const scale = document.getElementById('scale-mode');
                const tonic = document.getElementById('tonic');
                if (scale) { scale.value = '\($0.makam)'; scale.dispatchEvent(new Event('change')); }
                if (tonic) { tonic.value = '\($0.karar)'; tonic.dispatchEvent(new Event('change')); }
            })();
            """
        } ?? ""
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideStandaloneControls + studyContext, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(viewer, allowingReadAccessTo: readAccessRoot)
        DispatchQueue.main.async { self.webView = webView }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != viewer else { return }
        webView.loadFileURL(viewer, allowingReadAccessTo: readAccessRoot)
    }
}

private struct DropZone: View {
    @Binding var isTargeted: Bool
    let selectedFile: URL?
    let chooseFile: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1))
                    .frame(width: 64, height: 64)

                Image(systemName: selectedFile == nil ? (isTargeted ? "arrow.down.circle.fill" : "arrow.up.doc.fill") : "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(selectedFile == nil ? Color.accentColor : Color.green)
            }

            VStack(spacing: 6) {
                Text(selectedFile?.lastPathComponent ?? "Ses veya Video Dosyasını Buraya Sürükleyin")
                    .font(.headline.weight(.semibold))

                Text(selectedFile == nil ? "MP4, MOV, MP3 veya WAV formatındaki dosyaları destekler" : "Analiz için hazırlandı.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: chooseFile) {
                Label(selectedFile == nil ? "Dosya Seçin" : "Başka Dosya Seç", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [8, 6])
                )
        }
    }
}

private struct RecentRow: View {
    let item: RecentLibrary.Item
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "waveform.path")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(summary) · \(item.analysedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if item.cacheHit {
                Text("Hazır")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct StudyEditor: View {
    let item: RecentLibrary.Item
    @Bindable var library: RecentLibrary
    let onApply: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var makam: String
    @State private var karar: Int

    init(
        item: RecentLibrary.Item,
        library: RecentLibrary,
        onApply: @escaping (String, Int) -> Void
    ) {
        self.item = item
        self.library = library
        self.onApply = onApply
        let study = library.study(for: item)
        _title = State(initialValue: study.title)
        _makam = State(initialValue: study.makam)
        _karar = State(initialValue: study.karar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Çalışmayı Düzenle")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Çalışma adı", text: $title)
                Picker("Makam / dizi", selection: $makam) {
                    Text("Majör").tag("major")
                    Text("Minör").tag("minor")
                    Text("Nihavend").tag("nihavent")
                    Text("Kürdi").tag("kurdi")
                    Text("Uşşak").tag("ussak")
                    Text("Hicaz").tag("hicaz")
                    Text("Kürdilihicazkâr").tag("kurdilihicazkar")
                    Text("Hicazkâr").tag("hicazkar")
                }
                Picker("Karar", selection: $karar) {
                    Text("Do").tag(0)
                    Text("Re").tag(2)
                    Text("Mi").tag(4)
                    Text("Fa").tag(5)
                    Text("Sol").tag(7)
                    Text("La").tag(9)
                    Text("Si").tag(11)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Vazgeç") { dismiss() }
                Spacer()
                Button("Kaydet") {
                    library.saveStudy(item, title: title, makam: makam, karar: karar)
                    onApply(makam, karar)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("Görünüm") {
                Toggle("Koyu görünümü sistemden al", isOn: .constant(true))
                Toggle("Eğriyi dikey takip et", isOn: .constant(true))
            }
            Section("Çalma Ayarları") {
                Picker("Varsayılan Çalma Hızı", selection: .constant(1.0)) {
                    Text("0,50×").tag(0.5)
                    Text("0,75×").tag(0.75)
                    Text("1,00×").tag(1.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 240)
    }
}
