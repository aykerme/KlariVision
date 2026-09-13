// KlariVision macOS — AVFoundation ile ses/video kaynağını 48 kHz mono
// 16-bit PCM WAV'a çözer. Paketlenmiş (App Store) derlemede motorun artık
// ffmpeg'e ihtiyaç duymaması için tek dönüştürme yolu budur; bkz.
// docs/app-store/ffmpeg-replacement.md. Yalnız geliştirici/CLI akışı
// (`local_app.py`'ye WAV önceden verilmeden doğrudan çağrılması) hâlâ
// ffmpeg kullanır ve bu dosyadan etkilenmez.

import AVFoundation
import CoreMedia
import Foundation

/// Paketlenmiş motorun konumu: universal olmayan (numpy gibi derlenmiş
/// bağımlılıklar yüzünden universal2 PyInstaller güvenilmediğinden) motor,
/// App Store paketinde `Contents/Resources/Engine-arm64` ve
/// `Engine-x86_64` olarak ayrı ayrı bulunur (bkz. scripts/build_app_store.sh).
/// Çalışma zamanı mimarisine göre doğru klasör seçilir; yalnız tek mimarili
/// bir motor taşıyan eski paketler (`scripts/build_beta_app.sh`'ın ürettiği
/// "Engine/" klasörü) için düz isme düşülür.
enum BundledEngine {
    static func executable() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        #if arch(arm64)
        let archName: String? = "arm64"
        #elseif arch(x86_64)
        let archName: String? = "x86_64"
        #else
        let archName: String? = nil
        #endif
        if let archName {
            let archSpecific = resources.appending(path: "Engine-\(archName)/KlariVisionEngine")
            if FileManager.default.isExecutableFile(atPath: archSpecific.path) {
                return archSpecific
            }
        }
        let generic = resources.appending(path: "Engine/KlariVisionEngine")
        return FileManager.default.isExecutableFile(atPath: generic.path) ? generic : nil
    }
}

enum MediaToWAVConversionError: Error, LocalizedError {
    case noAudioTrack
    case setupFailed(String)
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "Kaynakta ses parçası bulunamadı."
        case .setupFailed(let detail): "Ses okuyucu kurulamadı: \(detail)"
        case .readFailed(let detail): "Ses çözülemedi: \(detail)"
        case .writeFailed(let detail): "WAV yazılamadı: \(detail)"
        }
    }
}

/// Motorun beklediği tek girdi biçimini (48 kHz, mono, 16-bit PCM WAV)
/// `AVAssetReader` ile üretir. `AVAssetReaderTrackOutput`'un kendi
/// `outputSettings`'i örnekleme hızını ve kanal sayısını zaten istenen
/// hedefe düşürdüğü için ayrı bir yeniden örnekleme adımına gerek yok.
enum MediaToWAVConverter {
    static let targetSampleRate: Double = 48_000

    /// `source`'daki ilk ses parçasını çözüp `destination`'a yazar.
    /// `destination` zaten varsa üzerine yazılır. Senkron ve bloklayıcıdır;
    /// yalnız arka plan kuyruğundan çağır.
    static func convert(source: URL, destination: URL) throws {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw MediaToWAVConversionError.noAudioTrack
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaToWAVConversionError.setupFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaToWAVConversionError.setupFailed("Ses çıkışı okuyucuya eklenemedi.")
        }
        reader.add(output)

        guard let pcmFormat = AVAudioFormat(settings: outputSettings) else {
            throw MediaToWAVConversionError.setupFailed("PCM biçimi oluşturulamadı.")
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = try AVAudioFile(
            forWriting: destination,
            settings: pcmFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard reader.startReading() else {
            throw MediaToWAVConversionError.readFailed(reader.error?.localizedDescription ?? "Bilinmeyen hata.")
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let buffer = pcmBuffer(from: sampleBuffer, format: pcmFormat) else { continue }
            do {
                try file.write(from: buffer)
            } catch {
                reader.cancelReading()
                throw MediaToWAVConversionError.writeFailed(error.localizedDescription)
            }
        }

        if reader.status == .failed {
            throw MediaToWAVConversionError.readFailed(reader.error?.localizedDescription ?? "Bilinmeyen hata.")
        }
    }

    /// Kaynak zaten bir WAV dosyasıysa doğrudan onu döndürür (kopyalama/çözme
    /// gerekmez -- `local_app.py` tarafındaki `_persist_video_source`/`_to_wav`
    /// zaten aynı işi güvenli biçimde yapar); değilse `convert(source:destination:)`
    /// ile geçici bir WAV üretir. Hem ilk analiz (`KlariVisionApp.swift`) hem
    /// de kaynak-karşılaştırma yolu (`LivePitchAnalyzer.swift`) bunu paylaşır.
    static func prepareWAV(for source: URL) -> Result<URL, Error> {
        if ["wav", "wave"].contains(source.pathExtension.lowercased()) {
            return .success(source)
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "KlariVision-\(UUID().uuidString).wav")
        do {
            try convert(source: source, destination: temporaryURL)
            return .success(temporaryURL)
        } catch {
            return .failure(error)
        }
    }

    /// `prepareWAV(for:)`'ın ürettiği geçici dosyayı temizler; kaynağın
    /// kendisi döndürülmüşse (zaten WAV'dı) hiçbir şeye dokunmaz.
    static func cleanUpTemporaryWAV(_ url: URL, isOriginal: Bool) {
        guard !isOriginal else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.int16ChannelData else { return nil }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else {
            return nil
        }
        dataPointer.withMemoryRebound(to: Int16.self, capacity: frameCount) { source in
            channelData[0].update(from: source, count: frameCount)
        }
        return buffer
    }
}
