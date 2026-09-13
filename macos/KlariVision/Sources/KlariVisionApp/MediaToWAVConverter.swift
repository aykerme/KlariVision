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
/// `AVAssetReader` ile üretir. Okuyucu yeniden örneklemeyi yapar; mono'ya
/// indirme ise burada kanalların ortalamasıyla yapılır. AVFoundation'ın kendi
/// mono indirmesi kanalları 1/√2 ile toplar: ffmpeg `-ac 1`'e göre +3 dB
/// yüksek seviye verir ve yüksek sesli stereo kayıtlarda kırpar.
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

        // Çok kanallı kaynakları okuyucu önce stereoya indirir; ortalamayı
        // en fazla iki kanal üzerinden alırız.
        let sourceChannels = audioTrack.formatDescriptions
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mChannelsPerFrame }
            .first ?? 1
        let readChannels = AVAudioChannelCount(min(max(sourceChannels, 1), 2))
        var readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: readChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        if sourceChannels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            readerSettings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaToWAVConversionError.setupFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaToWAVConversionError.setupFailed("Ses çıkışı okuyucuya eklenemedi.")
        }
        reader.add(output)

        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: readChannels, interleaved: false
        ), let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true
        ) else {
            throw MediaToWAVConversionError.setupFailed("PCM biçimi oluşturulamadı.")
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = try AVAudioFile(
            forWriting: destination,
            settings: monoFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard reader.startReading() else {
            throw MediaToWAVConversionError.readFailed(reader.error?.localizedDescription ?? "Bilinmeyen hata.")
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let buffer = monoPCMBuffer(from: sampleBuffer, readFormat: readFormat, monoFormat: monoFormat) else {
                reader.cancelReading()
                throw MediaToWAVConversionError.readFailed("Ses örnekleri kopyalanamadı.")
            }
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

    /// Kaynağı her zaman geçici bir WAV'a çözer -- kaynak WAV olsa bile:
    /// 44.1 kHz, stereo veya 24-bit bir WAV motorun beklediği biçimde değildir.
    /// Hem ilk analiz (`KlariVisionApp.swift`) hem de kaynak-karşılaştırma yolu
    /// (`LivePitchAnalyzer.swift`) bunu paylaşır.
    static func prepareWAV(for source: URL) -> Result<URL, Error> {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "KlariVision-\(UUID().uuidString).wav")
        do {
            try convert(source: source, destination: temporaryURL)
            return .success(temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return .failure(error)
        }
    }

    /// `prepareWAV(for:)`'ın ürettiği geçici dosyayı temizler.
    static func cleanUpTemporaryWAV(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func monoPCMBuffer(
        from sampleBuffer: CMSampleBuffer, readFormat: AVAudioFormat, monoFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let decoded = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        // Blok tamponu birden çok parçadan oluşabilir; ham işaretçiyle tek
        // parça varsaymak yerine kopyalamayı CoreMedia'ya bırakıyoruz.
        // `frameLength` önce ayarlanmalı: tampon listesinin bayt boyutu ondan
        // türetilir, sıfırken hiçbir şey kopyalanmaz.
        decoded.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: decoded.mutableAudioBufferList
        )
        guard status == noErr,
              let channels = decoded.floatChannelData,
              let target = mono.int16ChannelData?[0] else { return nil }

        let channelCount = Int(readFormat.channelCount)
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            let sample = max(-1, min(1, sum * scale))
            target[frame] = Int16((sample * Float(Int16.max)).rounded())
        }
        mono.frameLength = AVAudioFrameCount(frameCount)
        return mono
    }
}
