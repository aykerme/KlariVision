// KlariVision macOS — uygulama girişi, ana gezinme ve çalışma kütüphanesi.
// RecentLibrary dosya seçimi → yerel analiz → viewer açılışı zincirini yönetir;
// görünümler yalnız kullanıcı niyetini state'e iletir. Kullanıcı medyası
// silinmez; arka plan sonucu MainActor üzerinde yayınlanır.

import AppKit
import Accelerate
import AVFoundation
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

// Consumes an analysis child process's stderr as it arrives (via
// `readabilityHandler`, never `readDataToEndOfFile()` after `waitUntilExit()`
// -- that pattern deadlocks once a child writes enough stderr to fill the
// pipe's kernel buffer before anyone has started reading it, which is
// exactly what a stream of KV-PROGRESS lines does on a multi-minute
// recording) and separates it into two things:
//   - KV-PROGRESS lines (see core/tools/pitch_track_cli.cpp and
//     src/klarivision/local_app.py for the producing side) are turned into a
//     Turkish status string and handed to `onProgress` immediately.
//   - Every other line is preserved verbatim, in order, for `errorText` --
//     the same detail the old `readDataToEndOfFile()` call used to hand the
//     failure path, just assembled incrementally instead of in one shot.
// `readabilityHandler` runs on a private queue Foundation manages per file
// handle, serially, so `pending`/`errorLines` need no lock -- but that queue
// only stops delivering once it hands back an empty Data (EOF) and the
// handler is cleared, which can race with the caller's `waitUntilExit()`
// returning. `waitUntilDone(timeout:)` blocks on a semaphore signalled
// exactly at that EOF, so `errorText` is only read once every line has
// actually been consumed.
// @unchecked Sendable: every mutable property is only ever touched from
// `readabilityHandler`'s callback, which Foundation invokes serially on one
// private queue per file handle -- never concurrently, and never from the
// thread that calls `attach`/`waitUntilDone`/`errorText`. `waitUntilDone`'s
// semaphore is the happens-before edge that makes reading `errorText`
// afterwards safe.
private final class StderrProgressCapture: @unchecked Sendable {
    private var pending: [UInt8] = []
    private(set) var errorLines: [String] = []
    private let onProgress: (String) -> Void
    private let doneSemaphore = DispatchSemaphore(value: 0)

    init(onProgress: @escaping (String) -> Void) {
        self.onProgress = onProgress
    }

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flushRemainder()
                self.doneSemaphore.signal()
                return
            }
            self.consume(data)
        }
    }

    /// Blocks until the stderr pipe has reported EOF (readabilityHandler's
    /// empty-Data callback). Call only after `waitUntilExit()`, by which
    /// point the child has closed its stderr and EOF is imminent -- the
    /// timeout is a safety margin, not the expected path.
    func waitUntilDone(timeout: DispatchTime) {
        _ = doneSemaphore.wait(timeout: timeout)
    }

    var errorText: String { errorLines.joined(separator: "\n") }

    private func consume(_ data: Data) {
        pending.append(contentsOf: data)
        while let newlineIndex = pending.firstIndex(of: 0x0a) {
            let lineBytes = Array(pending[..<newlineIndex])
            pending.removeFirst(newlineIndex + 1)
            handleLine(lineBytes)
        }
    }

    private func flushRemainder() {
        guard !pending.isEmpty else { return }
        handleLine(pending)
        pending.removeAll()
    }

    private func handleLine(_ bytes: [UInt8]) {
        guard let line = String(bytes: bytes, encoding: .utf8), !line.isEmpty else { return }
        if let message = Self.progressMessage(from: line) {
            onProgress(message)
        } else {
            errorLines.append(line)
        }
    }

    // KV-PROGRESS protocol (canonical definition in
    // core/tools/pitch_track_cli.cpp, mirrored in
    // src/klarivision/local_app.py): one line, "KV-PROGRESS <stage>
    // <processed>/<total>". <stage> is a stable lowercase token; this is the
    // one place that maps it to the Turkish text a user sees.
    private static let stageLabels: [String: String] = [
        "extract": "Ses çıkarılıyor",
        "decode": "Ses okunuyor",
        "causal": "Temel geçiş",
        "pitch": "Perde analizi",
        "write": "Sonuçlar yazılıyor",
        "viewer": "Görünüm oluşturuluyor",
    ]

    private static func progressMessage(from line: String) -> String? {
        guard line.hasPrefix("KV-PROGRESS ") else { return nil }
        let parts = line.dropFirst("KV-PROGRESS ".count).split(separator: " ")
        guard parts.count == 2 else { return nil }
        let label = stageLabels[String(parts[0])] ?? "İşleniyor"
        let fraction = parts[1].split(separator: "/")
        guard fraction.count == 2,
              let processed = Int(fraction[0]),
              let total = Int(fraction[1]),
              total > 0 else {
            return "\(label)…"
        }
        let percent = min(100, max(0, Int((Double(processed) / Double(total) * 100).rounded())))
        return "\(label)… %\(percent)"
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

    private var selectedStudyEngine: String {
        PitchEngineSettings.storedSelection(for: PitchEngineSettings.studyEngineKey)
    }

    init() {
        reload()
    }

    func reload() {
        if let metadataData = try? Data(contentsOf: metadataURL()),
           let stored = try? JSONDecoder().decode([String: StudyMetadata].self, from: metadataData) {
            studyMetadata = stored
        }
        // A stale, empty `recent_analyses.json` can exist at an earlier root
        // (e.g. a leftover Application Support cache) while the actual
        // entries live at a later one. Stopping at the first root that merely
        // *decodes* would lock `items` to that empty file forever, which in
        // turn makes `item(for:)` never find a match. Prefer the first root
        // that actually has entries, and only fall back to an empty result
        // if none of them do.
        var fallback: [Item]?
        for root in dataRoots() {
            let file = root.appending(path: "data/recent_analyses.json")
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode([Item].self, from: data) else { continue }
            if !decoded.isEmpty {
                items = decoded
                return
            }
            if fallback == nil { fallback = decoded }
        }
        items = fallback ?? []
    }

    func study(for item: Item) -> StudyMetadata {
        studyMetadata[item.id] ?? StudyMetadata(title: item.label, makam: "major", karar: 0)
    }

    func studySummary(for item: Item) -> String {
        let study = study(for: item)
        return "\(makamName(study.makam)) · \(kararName(study.karar)) karar"
    }

    func formattedAnalysisDate(for item: Item) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "tr_TR")
        parser.dateFormat = "dd.MM.yyyy HH:mm"
        guard let date = parser.date(from: item.analysedAt) else { return item.analysedAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM · HH:mm"
        return formatter.string(from: date)
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

    /// Removes a study from the sidebar only. Its cached media and pitch data
    /// remain available on disk, so an accidental removal never loses a recording.
    func removeFromLibrary(_ item: Item) {
        items.removeAll { $0.id == item.id }
        studyMetadata.removeValue(forKey: item.id)
        if activeViewer.flatMap(item(for:))?.id == item.id {
            closeWorkspace()
        }
        deleteStudyFiles(item)
        saveMetadata()
        persistItems()
    }

    /// Deletes every file this study owns: the viewer page, every cached pitch
    /// track (any engine id, any offline_track revision), the extracted WAV and
    /// the imported video copy.
    ///
    /// Deliberately scoped to the app's own `outputs/`, `data/audio/` and
    /// `data/imports/` directories under the root that actually holds this
    /// viewer. Analysis only ever copies *into* those directories, so the file
    /// the user originally picked -- which lives wherever they keep it -- is
    /// unreachable from here and is never touched.
    ///
    /// Removing the cached track matters beyond disk space: `analyse_upload`
    /// treats an existing track for the same content signature as a cache hit,
    /// so leaving one behind means re-adding the study silently reuses the old
    /// engine's answer instead of re-analysing it.
    private func deleteStudyFiles(_ item: Item) {
        let manager = FileManager.default
        let relative = item.viewerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return }
        let roots = dataRoots()
        guard let root = roots.first(where: {
            manager.fileExists(atPath: $0.appending(path: relative).path)
        }) ?? roots.first else { return }

        let viewer = root.appending(path: relative)
        let stem = viewer.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem != "." , stem != ".." else { return }

        try? manager.removeItem(at: viewer)
        for directory in ["outputs", "data/audio", "data/imports"].map({ root.appending(path: $0) }) {
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            // `hasPrefix(stem + ".")` and not a looser match: two studies can
            // share a leading name and differ only by the content-signature
            // suffix the stem already carries.
            for name in names where name == stem || name.hasPrefix(stem + ".") {
                try? manager.removeItem(at: directory.appending(path: name))
            }
        }
    }

    private func metadataURL() -> URL {
        dataRoots().first!.appending(path: "data/study_metadata.json")
    }

    private func saveMetadata() {
        let destination = metadataURL()
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(studyMetadata) {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func persistItems() {
        let destination = dataRoots().first!.appending(path: "data/recent_analyses.json")
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: destination, options: .atomic)
        }
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
        guard Self.isSupportedMediaFile(url) else {
            selectedFile = nil
            analysisMessage = "Bu dosya desteklenen bir ses veya video biçimi değil. WAV, MP3, M4A ya da desteklenen bir video seçin."
            return
        }
        selectedFile = url
        analyseSelectedFile()
    }

    func acceptDroppedFile(_ url: URL) -> Bool {
        guard Self.isSupportedMediaFile(url) else {
            analysisMessage = "Bırakılan dosya desteklenmiyor. WAV, MP3, M4A veya video dosyası bırakın."
            return false
        }
        selectFile(url)
        return true
    }

    func reportDroppedFileFailure() {
        analysisMessage = AccessibilityText.unsupportedDrop
    }

    static func isSupportedMediaFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let knownExtensions: Set<String> = [
            "wav", "wave", "mp3", "m4a", "aac", "aiff", "aif", "flac",
            "mp4", "m4v", "mov", "avi", "mkv", "webm",
        ]
        if knownExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let type = values.contentType else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
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
        let selectedEngine = selectedStudyEngine
        let script = """
        from pathlib import Path
        from klarivision.local_app import analyse_upload
        print(analyse_upload(Path(\"\(sourcePath)\"), \"huzzam\", \"dugah\", \"\(selectedEngine)\"))
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
            let progress = StderrProgressCapture { message in
                DispatchQueue.main.async { [weak self] in
                    self?.analysisMessage = message
                }
            }
            progress.attach(to: error)

            do {
                try process.run()
                process.waitUntilExit()
                progress.waitUntilDone(timeout: .now() + 5)
                let standardOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let standardError = progress.errorText
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
        let selectedEngine = selectedStudyEngine

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = [source.path, "--makam", "huzzam", "--karar", "dugah", "--engine", selectedEngine]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            let progress = StderrProgressCapture { message in
                DispatchQueue.main.async { [weak self] in
                    self?.analysisMessage = message
                }
            }
            progress.attach(to: error)

            do {
                try process.run()
                process.waitUntilExit()
                progress.waitUntilDone(timeout: .now() + 5)
                let standardOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let standardError = progress.errorText
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

    func reanalyse(_ viewer: URL) {
        guard !isAnalysing else { return }
        guard let executable = bundledEngineExecutable() else {
            analysisMessage = "Seçili motorla yeniden analiz yalnız paketlenmiş C++ analiz motorunda kullanılabilir."
            return
        }
        let selectedEngine = selectedStudyEngine
        isAnalysing = true
        analysisMessage = "\(selectedEngine) ile pitch eğrisi hazırlanıyor…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--reanalyze-viewer", viewer.path, "--engine", selectedEngine]
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
                          let refreshedPath = standardOutput.split(whereSeparator: \.isNewline).last else {
                        self.analysisMessage = "Seçili motorla analiz yapılamadı. \(standardError)"
                        return
                    }
                    self.activeViewer = URL(fileURLWithPath: String(refreshedPath))
                    self.analysisMessage = "\(selectedEngine) pitch eğrisi hazır."
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAnalysing = false
                    self?.analysisMessage = "Motor başlatılamadı: \(error.localizedDescription)"
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

/// Hangi ekranın gösterildiğinin tek kaynağı. `library.activeViewer` ise hangi
/// dosyanın açık olduğunun kaynağıdır — ikisi ayrı sorulara cevap verir.
/// iPad tarafındaki `iPadWorkspaceRoute` (AppState.swift) aynı kalıbın örneğidir.
enum AppRoute: Equatable {
    case modeSelection
    case listening
    case live
    case together
}

/// Kenar çubuğu seçimi iki ayrı yönden değişebilir: kullanıcı bir kayda tıklar,
/// ya da yeni bir analiz bitip `activeViewer` dolunca senkron gözlemcisi seçimi
/// programlı olarak yazar.  Yalnız ilki route'u `.listening`'e çekmelidir —
/// ikincisi de çekerse "Birlikte Çal" için seçilen dosyanın analizi biter bitmez
/// mod sessizce Dinleme Modu'na dönüşür (hoparlör düğmesi ve mikrofon çizimi
/// `isTogetherMode`'a bağlı olduğu için ikisi birden kaybolur).
///
/// iPad tarafındaki `iPadCompactNavigationPolicy` gibi saf ve test edilebilir
/// tutuluyor; SwiftUI `@State`'i içinde saklı kalırsa bu hata yine sessizce
/// geri gelebilir.
struct StudySelectionSync: Equatable {
    private(set) var isSyncingFromViewer = false

    /// `activeViewer` değişti.  `true` dönerse çağıran seçimi yazmalıdır.
    /// Değer zaten aynıysa `onChange` tetiklenmeyeceği için bayrak da
    /// kaldırılmaz; aksi halde bir sonraki gerçek tıklamayı yutardı.
    mutating func viewerChanged(to identifier: String?, currentSelection: String?) -> Bool {
        guard identifier != currentSelection else { return false }
        isSyncingFromViewer = true
        return true
    }

    /// Seçim değişti.  `true` dönerse bu gerçek bir kullanıcı tıklamasıdır ve
    /// route `.listening` olmalıdır.
    mutating func selectionChangeIsUserDriven() -> Bool {
        if isSyncingFromViewer {
            isSyncingFromViewer = false
            return false
        }
        return true
    }
}

struct WelcomeView: View {
    @Bindable var library: RecentLibrary
    @State private var route: AppRoute = .modeSelection
    /// `library.activeViewer` → `selectedStudyID` senkronunu kullanıcının
    /// kendi kenar çubuğu seçiminden ayırır; bkz. aşağıdaki iki `onChange`.
    @State private var selectionSync = StudySelectionSync()
    @State private var itemToRemove: RecentLibrary.Item?
    @State private var itemToEdit: RecentLibrary.Item?
    @State private var selectedStudyID: RecentLibrary.Item.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedStudyID) {
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
                            RecentRow(
                                item: item,
                                title: library.study(for: item).title,
                                summary: library.studySummary(for: item)
                            )
                            .tag(item.id)
                            .help(item.label)
                            .contextMenu {
                                Button {
                                    itemToEdit = item
                                } label: {
                                    Label("Çalışmayı Düzenle", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    itemToRemove = item
                                } label: {
                                    Label("Çalışmayı Sil", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Çalışmalar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("KlariVision")
        } detail: {
            switch route {
            case .live:
                LivePracticeView {
                    route = .modeSelection
                }
            case .modeSelection, .listening, .together:
                if let viewer = library.activeViewer {
                    WorkspaceView(viewer: viewer, library: library, isTogetherMode: route == .together)
                } else {
                    ModeSelectionView(library: library, route: $route)
                }
            }
        }
        .sheet(item: $itemToEdit) { item in
            StudyEditor(item: item, library: library) { _, _ in }
        }
        .onChange(of: selectedStudyID) { _, identifier in
            // Kenar çubuğu seçimi `library.activeViewer` değiştiğinde aşağıdaki
            // gözlemci tarafından programlı olarak da güncelleniyor.  O senkron
            // güncelleme kullanıcı tıklaması sayılmamalı: sayılırsa Birlikte Çal
            // için seçilen dosyanın analizi biter bitmez route `.listening`'e
            // düşüyor ve mod sessizce Dinleme Modu'na dönüşüyordu.
            guard selectionSync.selectionChangeIsUserDriven() else { return }
            guard let identifier,
                  let item = library.items.first(where: { $0.id == identifier }) else { return }
            // Kenar çubuğundan seçilen kayıtlar yalnız Dinleme Modu'na girer.
            route = .listening
            library.open(item)
        }
        .onChange(of: library.activeViewer) { _, viewer in
            let identifier = viewer.flatMap { library.item(for: $0)?.id }
            // Değer gerçekten değişmiyorsa `onChange` tetiklenmez; bayrağı yalnız
            // tetikleneceği durumda kaldır, yoksa bir sonraki gerçek kullanıcı
            // tıklamasını yutar.
            guard selectionSync.viewerChanged(to: identifier, currentSelection: selectedStudyID) else { return }
            selectedStudyID = identifier
        }
        .alert(
            "Çalışma silinsin mi?",
            isPresented: Binding(
                get: { itemToRemove != nil },
                set: { if !$0 { itemToRemove = nil } }
            ),
            presenting: itemToRemove
        ) { item in
            Button("Vazgeç", role: .cancel) {}
            Button("Sil", role: .destructive) {
                library.removeFromLibrary(item)
                itemToRemove = nil
            }
        } message: { item in
            Text("\(library.study(for: item).title) listeden kaldırılır ve bu çalışmaya ait görünüm, ses kopyası ile pitch verileri silinir. Kendi seçtiğin özgün dosyaya dokunulmaz. Bu işlem geri alınamaz.")
        }
    }
}

/// Changes placement without changing the identity or parentage of either
/// child.  Conditional HStack/VStack branches recreated WKWebView exactly at
/// the 900 pt threshold, leaving the old media element audible in the process.
private struct ModeSelectionView: View {
    @Bindable var library: RecentLibrary
    @Binding var route: AppRoute
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 7) {
                    Label("KlariVision", systemImage: "waveform.path.ecg")
                        .font(.title2.weight(.bold))
                    Text("Pitch analizine nasıl başlamak istersiniz?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 20) {
                    ListeningModeCard(
                        isTargeted: $isDropTarget,
                        selectedFile: library.selectedFile,
                        chooseFile: {
                            route = .listening
                            library.chooseFile()
                        }
                    )
                    .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
                            library.reportDroppedFileFailure()
                            return false
                        }
                        route = .listening
                        _ = provider.loadObject(ofClass: URL.self) { value, _ in
                            DispatchQueue.main.async {
                                guard let url = value else {
                                    library.reportDroppedFileFailure()
                                    return
                                }
                                _ = library.acceptDroppedFile(url)
                            }
                        }
                        return true
                    }

                    PlayingModeCard {
                        library.closeWorkspace()
                        route = .live
                    }

                    TogetherModeCard(selectedFile: library.selectedFile) {
                        // Mikrofon henüz bağlanmadı; burada tek teardown noktası
                        // bırakılıyor — mikrofon durdurma sonraki görevde eklenecek.
                        library.closeWorkspace()
                        route = .together
                        library.chooseFile()
                    }
                }

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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(AccessibilityText.listeningStatus)
                    .accessibilityValue(library.analysisMessage)
                }
            }
            .padding(36)
            .frame(maxWidth: 920)
        }
    }
}

private struct ListeningModeCard: View {
    @Binding var isTargeted: Bool
    let selectedFile: URL?
    let chooseFile: () -> Void

    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(isTargeted ? 0.24 : 0.14))
                    .frame(width: 72, height: 72)

                Image(systemName: selectedFile == nil ? "headphones" : "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(selectedFile == nil ? Color.blue : Color.green)
            }

            VStack(spacing: 6) {
                Text("Dinleme Modu")
                    .font(.title3.weight(.bold))

                Text(selectedFile?.lastPathComponent ?? "Ses veya video dosyanızı yükleyin, pitch analizini başlatın.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Button(action: chooseFile) {
                Label("Dosya Seç / Yükle", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.blue.opacity(isTargeted ? 0.12 : 0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    isTargeted ? Color.blue : Color.blue.opacity(0.28),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dinleme Modu")
        .accessibilityHint("Bir ses veya video dosyası seçin ya da bu karta sürükleyin.")
    }
}

private struct PlayingModeCard: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 72, height: 72)

                Image(systemName: "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 6) {
                Text("Çalma Modu")
                    .font(.title3.weight(.bold))

                Text("Mikrofonunuzu kullanarak canlı, gerçek zamanlı pitch analizi yapın.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Button(action: start) {
                Label("Başlat", systemImage: "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.green.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Çalma Modu")
        .accessibilityHint("Mikrofonla canlı pitch analizini başlatır.")
    }
}

/// "Dosya Seç" ile aynı `library.chooseFile` yolunu kullanır, ama kasıtlı olarak
/// `onDrop` taşımaz: bu modda yalnız yeni dosya seçimiyle girilir, kenar
/// çubuğundaki eski kayıtlar (Dinleme Modu'na özgü) bu moda giremez.
private struct TogetherModeCard: View {
    let selectedFile: URL?
    let start: () -> Void

    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.14))
                    .frame(width: 72, height: 72)

                Image(systemName: selectedFile == nil ? "person.wave.2" : "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(selectedFile == nil ? Color.purple : Color.green)
            }

            VStack(spacing: 6) {
                Text("Birlikte Çal")
                    .font(.title3.weight(.bold))

                Text(selectedFile?.lastPathComponent ?? "Dosya çalarken kendi çalışınızı aynı grafikte, ikinci renkle görün.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Button(action: start) {
                Label("Dosya Seç", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.purple)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.purple.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.purple.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Birlikte Çal")
        .accessibilityHint("Bir dosya seçin; dosya çalarken mikrofonunuzdaki perde aynı grafiğe eklenir.")
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
                Text("\(summary) · \(date)")
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

    private var date: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "tr_TR")
        parser.dateFormat = "dd.MM.yyyy HH:mm"
        guard let value = parser.date(from: item.analysedAt) else { return item.analysedAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM · HH:mm"
        return formatter.string(from: value)
    }
}

struct StudyEditor: View {
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
