// KlariVision iPhone/iPad — dosya alma, çevrimdışı analiz ve çalışma modelleri.
// Kullanıcı URL'si yalnız app-owned kopya alınırken açıktır. AVAssetReader sesi
// 48 kHz mono Float32'ye çevirir; C ABI kareleri ve metadata atomik saklanır.
// Liste kaydı silmek medya dosyasını silmez.

import AVFoundation
import AudioToolbox
import Foundation
import UniformTypeIdentifiers

struct iPadStudy: Identifiable, Equatable, Codable {
    let id: UUID
    let sourceURL: URL // Always the app-owned Imports copy; never the user-picked URL.
    var title: String
    let duration: Double
    let frames: [iPadPitchFrame]
    let engine: iPadPitchEngine
    var context: iPadMusicContext
    let analyzedAt: Date
    /// Identifies the pitch pipeline that produced `frames`. `nil` means the
    /// record predates this field: it was analyzed through the causal
    /// live/Çalma session (`iPadProductionPitchSession`) that Study used to
    /// reuse before this offline path existed, and its frames are not
    /// directly comparable to a fresh offline_track analysis. New studies
    /// stamp `iPadOfflinePitchAnalyzer.pipelineRevision`, mirroring macOS's
    /// `OFFLINE_TRACK_REVISION` (src/klarivision/pitch/cpp_engine.py) so a
    /// future pipeline change can tell old and new results apart the same
    /// way. Nothing currently re-analyzes automatically on a mismatch —
    /// this field only makes the distinction visible.
    var pipelineRevision: String? = nil

    /// Whether the source file has a video track to show, as opposed to
    /// audio-only. Drives the native graph/video fullscreen toggle button in
    /// the compact study workspace.
    var isVideoSource: Bool {
        guard let type = UTType(filenameExtension: sourceURL.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }
}

struct iPadStudyLibraryStore {
    let fileURL: URL
    init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let fileURL { self.fileURL = fileURL }
        else {
            let root = try iPadStudyImportService.importsDirectory(fileManager: fileManager).deletingLastPathComponent()
            self.fileURL = root.appendingPathComponent("Studies-v1.json")
        }
    }

    func load() throws -> [iPadStudy] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([iPadStudy].self, from: Data(contentsOf: fileURL))
    }

    func save(_ studies: [iPadStudy]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(studies).write(to: fileURL, options: .atomic)
    }

    @discardableResult func remove(_ id: UUID, from studies: [iPadStudy]) throws -> [iPadStudy] {
        let result = studies.filter { $0.id != id }
        try save(result) // Deliberately removes only the list record, never media or cached pitch frames.
        return result
    }
}

struct iPadPitchFrame: Codable, Equatable {
    let time: Double
    let frequency: Double
    let confidence: Double
    let voiced: Bool
}

enum iPadStudyImportError: LocalizedError, Equatable {
    case unsupportedType
    case securityScope
    case unableToCopy
    case noAudioTrack
    case decodeFailed
    case coreContract
    /// Carries the underlying `iPadPitchABIError`'s message (which itself
    /// carries `kv_pitch_engine_last_error` verbatim for an offline-engine
    /// failure) so a failed offline analysis is diagnosable in the UI
    /// instead of collapsing to one generic string.
    case coreProcessing(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Bu dosya türü desteklenmiyor. Ses veya video dosyası seçin."
        case .securityScope: "Seçilen dosyaya geçici erişim açılamadı."
        case .unableToCopy: "Dosya uygulamanın yerel çalışma alanına kopyalanamadı."
        case .noAudioTrack: "Dosyada analiz edilecek bir ses kanalı bulunamadı."
        case .decodeFailed: "Ses akışı 48 kHz çalışma biçimine dönüştürülemedi."
        case .coreContract: "Pitch çekirdeği beklenen mobil sözleşmeyle uyuşmuyor."
        case let .coreProcessing(message): "Yerel pitch analizi tamamlanamadı: \(message)"
        }
    }
}

enum iPadStudyImportService {
    static let supportedTypes: [UTType] = [.audio, .movie, .mpeg4Audio, .wav, .mpeg4Movie, .quickTimeMovie]

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    static func importsDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("KlariVision", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func copyImportedFile(from source: URL, fileManager: FileManager = .default) throws -> URL {
        guard isSupported(source) else { throw iPadStudyImportError.unsupportedType }
        let hasSecurityScope = source.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { source.stopAccessingSecurityScopedResource() } }

        let destination = try destinationURL(for: source, fileManager: fileManager)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.copyItem(at: coordinatedURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if coordinationError != nil || copyError != nil { throw iPadStudyImportError.unableToCopy }
        return destination
    }

    static func destinationURL(for source: URL, fileManager: FileManager = .default) throws -> URL {
        try importsDirectory(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(source.pathExtension)
    }
}

enum iPadOfflinePitchAnalyzer {
    /// Identifies the pipeline that produced a Study's persisted frames.
    /// Mirrors macOS's `OFFLINE_TRACK_REVISION`
    /// (src/klarivision/pitch/cpp_engine.py = "offline-unified-path-r2"):
    /// both go through the same underlying C++ offline_track_v1 pass
    /// (`PitchEngine::analyse`/`finish`, unified_v1), so they share its
    /// cache-invalidation key. See `iPadStudy.pipelineRevision`.
    static let pipelineRevision = "offline-unified-path-r2"

    /// Runs Study/Dinleme's whole-file, offline_track profile analysis (see
    /// `iPadOfflineTrackSession`) — never the live/causal
    /// `iPadProductionPitchSession` path that Çalma (live) mode uses. A
    /// failure here throws `iPadStudyImportError.coreProcessing` carrying
    /// the C ABI's own error message; it must never be swallowed into a
    /// silent fallback to the live path, which would make the failure
    /// invisible to both the user and this analyzer.
    static func analyze(fileURL: URL, engine: iPadPitchEngine, progress: @escaping @Sendable (Double) -> Void) async throws -> [iPadPitchFrame] {
        let session: iPadOfflineTrackSession
        do {
            session = try iPadOfflineTrackSession(engine: engine)
        } catch { throw iPadStudyImportError.coreContract }

        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw iPadStudyImportError.noAudioTrack }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw iPadStudyImportError.decodeFailed }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw iPadStudyImportError.decodeFailed }
        reader.add(output)

        defer { session.close() }
        guard reader.startReading() else { throw iPadStudyImportError.decodeFailed }

        let duration = max((try await asset.load(.duration)).seconds, 0.001)
        var sourceSamples = 0

        // Unlike the old causal path, this API takes the whole file: chunks
        // are only pushed into the engine's internal buffer here (fast —
        // no per-window analysis happens yet), so this loop's progress is
        // decode/read progress, not analysis progress. It is capped below
        // 0.9 so the remaining range is visibly left for `finish()` below,
        // which is where the actual whole-track pass runs.
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw iPadStudyImportError.decodeFailed }
            let length = CMBlockBufferGetDataLength(block)
            var raw = Data(count: length)
            let status = raw.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw iPadStudyImportError.decodeFailed }
            do {
                try raw.withUnsafeBytes { bytes in
                    try session.push(samples: bytes.bindMemory(to: Float.self), sampleRate: 48_000)
                }
            } catch let error as iPadPitchABIError {
                throw iPadStudyImportError.coreProcessing(error.errorDescription ?? "bilinmeyen hata")
            } catch { throw iPadStudyImportError.coreProcessing("\(error)") }
            sourceSamples += length / MemoryLayout<Float>.size
            let readSeconds = Double(sourceSamples) / 48_000
            progress(min(readSeconds / duration, 0.9))
        }
        guard reader.status == .completed else { throw iPadStudyImportError.decodeFailed }

        // The whole-track pass: everything above was preparation, and this
        // single call is where the time goes (~50 s for a 191 s recording).
        // kv_pitch_engine_set_progress reports real frame-level progress from
        // inside it, so the remaining 0.9...1.0 of the bar advances instead of
        // holding while the user waits.
        let frames: [iPadPitchFrame]
        do {
            frames = try session.finish { fraction in
                progress(0.9 + 0.1 * fraction)
            }
        }
        catch let error as iPadPitchABIError {
            throw iPadStudyImportError.coreProcessing(error.errorDescription ?? "bilinmeyen hata")
        } catch { throw iPadStudyImportError.coreProcessing("\(error)") }
        progress(1)
        return frames
    }

    static func analysisWindow(from pending: [Float], windowSize: Int) -> [Float] {
        Array(pending.prefix(windowSize))
    }
}

extension iPadPitchEngine {
    var coreValue: Int32 {
        switch self {
        case .unifiedV1: Int32(KV_ENGINE_UNIFIED_V1)
        }
    }
}

enum iPadStudyPlaybackRate {
    /// Matches the macOS viewer's `speedDown` / `speedUp` contract exactly:
    /// 0.10× through 2.00× in 0.05× increments.
    static let values = (2...40).map { Double($0) / 20 }

    static func label(for rate: Double) -> String {
        String(format: "%.2f×", rate).replacingOccurrences(of: ".", with: ",")
    }

    /// Index of the nearest table entry, clamped to the ends.  The ± control
    /// steps over indices rather than raw doubles so the 0,05× grid can never
    /// drift through repeated floating-point addition.
    static func index(for rate: Double) -> Int {
        guard let first = values.first, let last = values.last else { return 0 }
        if rate <= first { return 0 }
        if rate >= last { return values.count - 1 }
        return values.indices.min { abs(values[$0] - rate) < abs(values[$1] - rate) } ?? 0
    }

    static func rate(at index: Int) -> Double {
        values[min(max(index, 0), values.count - 1)]
    }
}

enum iPadStudyCommand: Equatable {
    case load(URL, [iPadPitchFrame])
    case context(iPadMusicContext, pitchColor: String, guideColor: String, kararColor: String, komaOverride: [Int])
    case playPause, pause, seek(Double), rate(Double), markA, markB, loop, follow
    /// Which side (graph or video) fills the stage. Driven by the native
    /// floating toggle button so it stays tappable regardless of the
    /// WebView's own pinch-zoom state (see `iPadStudyWebView`).
    case setVideoFullscreen(Bool)

    // "Birlikte Çal" mikrofon köprüsü (bkz. TogetherSession.swift). macOS'un
    // StudyWorkspace.swift'teki LocalViewer.Coordinator köprüsünün karşılığı;
    // StudyViewer.html'deki (T1) `window.kvStudy.receive` ayırıcısı bu dört
    // tipi zaten tanıyor.
    case micClear
    case micAppend([iPadTogetherMicPoint])
    case micTruncate(Double)
    case setMicColor(String)
}

struct iPadStudyCommandQueue {
    private(set) var pending: [iPadStudyCommand] = []
    mutating func append(_ command: iPadStudyCommand) { pending.append(command) }
    mutating func drainWhenReady() -> [iPadStudyCommand] {
        defer { pending.removeAll() }
        return pending
    }
}
