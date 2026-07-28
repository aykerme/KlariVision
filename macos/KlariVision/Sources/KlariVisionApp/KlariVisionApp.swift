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
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 720)

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

    private(set) var items: [Item] = []
    private(set) var selectedFile: URL?
    private(set) var isAnalysing = false
    private(set) var analysisMessage = ""
    private(set) var activeViewer: URL?
    var mediaLink = ""

    init() {
        reload()
    }

    func reload() {
        for root in dataRoots() {
            let file = root.appending(path: "data/recent_analyses.json")
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode([Item].self, from: data) else { continue }
            items = decoded
            return
        }
        items = []
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

    func explainLinkImport() {
        analysisMessage = "Bağlantıdan içe aktarma bir sonraki native adımda açılacak."
    }

    func open(_ item: Item) {
        for root in dataRoots() {
            let relativePath = item.viewerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let viewer = root.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: viewer.path) {
                activeViewer = viewer
                return
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
}

struct WelcomeView: View {
    @Bindable var library: RecentLibrary
    @State private var isDropTarget = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Çalışma") {
                    Button { library.closeWorkspace() } label: {
                        Label("Yeni çalışma", systemImage: "plus.circle")
                    }
                }
                Section("Son çalışmalar") {
                    if library.items.isEmpty {
                        Text("Henüz kayıt yok")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.items) { item in
                            Button { library.open(item) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label).lineLimit(1)
                                    Text(item.analysedAt)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("KlariVision")
        } detail: {
            if let viewer = library.activeViewer {
                WorkspaceView(viewer: viewer, library: library)
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Yeni çalışma")
                            .font(.title2.weight(.semibold))
                        Text("Video veya ses kaydından pitch eğrisi oluştur.")
                            .foregroundStyle(.secondary)
                    }

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

                    if library.selectedFile != nil, !library.analysisMessage.isEmpty {
                        HStack(spacing: 10) {
                            if library.isAnalysing { ProgressView().controlSize(.small) }
                            Text(library.analysisMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Bağlantıdan içe aktar")
                            .font(.headline)
                        HStack {
                            TextField("YouTube veya video bağlantısı", text: $library.mediaLink)
                                .textFieldStyle(.roundedBorder)
                            Button("İçe Aktar") { library.explainLinkImport() }
                                .disabled(library.mediaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Bağlantı aktarımı, yerel dosya analizinden sonra native akışa eklenecek.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                }
                .padding(32)
                .frame(maxWidth: 860, alignment: .leading)
                }
            }
        }
    }
}

private struct WorkspaceView: View {
    let viewer: URL
    @Bindable var library: RecentLibrary
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Yeni çalışma", systemImage: "plus") { library.closeWorkspace() }
                Divider().frame(height: 18)
                Text(viewer.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ayarlar", systemImage: "gearshape") {
                    webView?.evaluateJavaScript("document.getElementById('makam-settings-open')?.click()")
                }
                .disabled(webView == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.bar)

            LocalViewer(viewer: viewer, readAccessRoot: library.viewerReadAccessRoot(for: viewer), webView: $webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LocalViewer: NSViewRepresentable {
    let viewer: URL
    let readAccessRoot: URL
    @Binding var webView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let hideStandaloneControls = """
        document.addEventListener('DOMContentLoaded', () => {
            const newRecording = document.getElementById('new-recording');
            if (newRecording) newRecording.style.display = 'none';
            const makamSettings = document.getElementById('makam-settings-open');
            if (makamSettings) makamSettings.style.display = 'none';
        });
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideStandaloneControls, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
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
        VStack(spacing: 12) {
            Image(systemName: selectedFile == nil ? "film.stack" : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(selectedFile == nil ? Color.accentColor : Color.green)
            Text(selectedFile?.lastPathComponent ?? "Dosyayı buraya sürükleyin")
                .font(.headline)
            Text(selectedFile == nil ? "veya bilgisayarınızdan bir video ya da ses kaydı seçin." : "Native analiz akışı için hazır.")
                .foregroundStyle(.secondary)
            Button("Dosya Seç", action: chooseFile)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .background(isTargeted ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7]))
        }
        .clipShape(.rect(cornerRadius: 14))
    }
}

private struct RecentRow: View {
    let item: RecentLibrary.Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .lineLimit(1)
                Text(item.analysedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.cacheHit {
                Text("Pitch hazır")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary)
        }
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("Görünüm") {
                Toggle("Koyu görünümü sistemden al", isOn: .constant(true))
                Toggle("Eğriyi dikey takip et", isOn: .constant(true))
            }
            Section("Çalışma") {
                Picker("Çalma hızı", selection: .constant(1.0)) {
                    Text("0,50×").tag(0.5)
                    Text("0,75×").tag(0.75)
                    Text("1,00×").tag(1.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 230)
        .padding()
    }
}
