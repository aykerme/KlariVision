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
    case coreProcessing

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Bu dosya türü desteklenmiyor. Ses veya video dosyası seçin."
        case .securityScope: "Seçilen dosyaya geçici erişim açılamadı."
        case .unableToCopy: "Dosya uygulamanın yerel çalışma alanına kopyalanamadı."
        case .noAudioTrack: "Dosyada analiz edilecek bir ses kanalı bulunamadı."
        case .decodeFailed: "Ses akışı 48 kHz çalışma biçimine dönüştürülemedi."
        case .coreContract: "Pitch çekirdeği beklenen mobil sözleşmeyle uyuşmuyor."
        case .coreProcessing: "Yerel pitch analizi tamamlanamadı."
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
    static func analyze(fileURL: URL, engine: iPadPitchEngine, progress: @escaping @Sendable (Double) -> Void) async throws -> [iPadPitchFrame] {
        let contract: kv_pitch_contract_v1
        let session: iPadProductionPitchSession
        do {
            contract = try iPadPitchABIAdapter.contract()
            session = try iPadProductionPitchSession(engine: engine)
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
        let windowSize = Int(contract.window_size)
        let hopSize = Int(contract.hop_size)
        var pending: [Float] = []
        var sourceOffset = 0
        var frames: [iPadPitchFrame] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw iPadStudyImportError.decodeFailed }
            let length = CMBlockBufferGetDataLength(block)
            var raw = Data(count: length)
            let status = raw.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw iPadStudyImportError.decodeFailed }
            raw.withUnsafeBytes { bytes in
                pending.append(contentsOf: bytes.bindMemory(to: Float.self))
            }
            while pending.count >= windowSize {
                let time = Double(sourceOffset + windowSize / 2) / 48_000
                do {
                    let window = analysisWindow(from: pending, windowSize: windowSize)
                    let output = try window.withUnsafeBufferPointer { try session.process(samples: $0, sourceTime: time) }
                    frames.append(contentsOf: output)
                } catch { throw iPadStudyImportError.coreProcessing }
                pending.removeFirst(hopSize)
                sourceOffset += hopSize
                progress(min(time / duration, 0.99))
            }
        }
        guard reader.status == .completed else { throw iPadStudyImportError.decodeFailed }
        do { frames.append(contentsOf: try session.finish()) }
        catch { throw iPadStudyImportError.coreProcessing }
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
        case .yinV1: Int32(KV_ENGINE_YIN_V1)
        case .pitchEngineV2: Int32(KV_ENGINE_V2)
        case .vpmLike: Int32(KV_ENGINE_VPM_LIKE)
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
    case context(iPadMusicContext, pitchColor: String, guideColor: String, komaOverride: [Int])
    case playPause, pause, seek(Double), rate(Double), markA, markB, loop, follow
    /// Which side (graph or video) fills the stage. Driven by the native
    /// floating toggle button so it stays tappable regardless of the
    /// WebView's own pinch-zoom state (see `iPadStudyWebView`).
    case setVideoFullscreen(Bool)
}

struct iPadStudyCommandQueue {
    private(set) var pending: [iPadStudyCommand] = []
    mutating func append(_ command: iPadStudyCommand) { pending.append(command) }
    mutating func drainWhenReady() -> [iPadStudyCommand] {
        defer { pending.removeAll() }
        return pending
    }
}
