// KlariVision iPhone/iPad — AVFoundation'dan bağımsız canlı akış modelleri.
// Durum makinesi, rota kararı, 1536/512 PCM biriktirici ve çekirdek işlemci
// burada tutulur; böylece mikrofon olmadan birim test edilebilir.

import Foundation

enum iPadLivePhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case running
    case interrupted(String)
    case failed(String)
}

enum iPadRecordingPhase: Equatable, Sendable {
    case idle
    case active
    case completed(URL)
    case failed(String)
}

struct iPadLiveLifecycle: Equatable {
    private(set) var phase: iPadLivePhase = .idle
    mutating func requestStart() { phase = .requestingPermission }
    mutating func started() { phase = .running }
    mutating func failed(_ message: String) { phase = .failed(message) }
    mutating func stopped(reason: String?) { phase = reason.map(iPadLivePhase.interrupted) ?? .idle }
}

/// Route-change decisions stay independent of AVFoundation so the safety
/// contract can be exercised without an attached microphone.
enum iPadLiveRouteChangeAction: Equatable {
    case continueCapturing
    case stop(String)
}

enum iPadLiveRouteChangePolicy {
    // AVAudioSession.RouteChangeReason raw values. Keeping this mapping here
    // avoids making the policy depend on an audio-session instance.
    private enum Reason: UInt {
        case newDeviceAvailable = 1
        case oldDeviceUnavailable = 2
        case categoryChange = 3
        case override = 4
        case wakeFromSleep = 6
        case noSuitableRouteForCategory = 7
        case routeConfigurationChange = 8
    }

    static func action(reasonRawValue: UInt?, expectedOwnCategoryChange: Bool) -> iPadLiveRouteChangeAction {
        guard let reasonRawValue, let reason = Reason(rawValue: reasonRawValue) else {
            return .stop("Ses rotası değişti. Yeniden başlatmak için Başlat'a dokunun.")
        }
        switch reason {
        case .categoryChange where expectedOwnCategoryChange:
            // setCategory during a new start can publish this notification
            // after the engine setup has yielded; consume only that bounded,
            // explicitly tracked notification.
            return .continueCapturing
        case .override:
            // AVAudioSession's override reason changes the output port only.
            return .continueCapturing
        case .oldDeviceUnavailable:
            return .stop("Mikrofon rotası kaldırıldı. Yeniden başlatmak için Başlat'a dokunun.")
        case .noSuitableRouteForCategory:
            return .stop("Mikrofon için uygun ses rotası bulunamadı. Yeniden başlatmak için Başlat'a dokunun.")
        case .newDeviceAvailable, .categoryChange, .wakeFromSleep, .routeConfigurationChange:
            return .stop("Ses rotası değişti. Yeniden başlatmak için Başlat'a dokunun.")
        }
    }
}

struct iPadPCMWindowAccumulator {
    private(set) var samples: [Float] = []
    private(set) var samplesConsumed = 0
    let windowSize: Int
    let hopSize: Int

    init(windowSize: Int = 1_536, hopSize: Int = 512) {
        self.windowSize = windowSize
        self.hopSize = hopSize
    }

    mutating func append(_ input: UnsafeBufferPointer<Float>) { samples.append(contentsOf: input) }

    mutating func drainWindows() -> [(samples: [Float], centerSample: Int)] {
        var windows: [(samples: [Float], centerSample: Int)] = []
        while samples.count >= windowSize {
            windows.append((Array(samples.prefix(windowSize)), samplesConsumed + windowSize / 2))
            samples.removeFirst(hopSize)
            samplesConsumed += hopSize
        }
        return windows
    }
}

final class iPadLiveCoreProcessor {
    private var session: iPadProductionPitchSession?
    private var accumulator = iPadPCMWindowAccumulator()

    init?(engine: iPadPitchEngine, minimumRMS: Double? = nil) {
        session = try? iPadProductionPitchSession(engine: engine, minimumRMS: minimumRMS)
        guard session != nil else { return nil }
    }

    deinit { _ = finishAndDestroy() }

    func process(_ samples: UnsafeBufferPointer<Float>) -> [iPadPitchFrame] {
        accumulator.append(samples)
        var frames: [iPadPitchFrame] = []
        for window in accumulator.drainWindows() {
            guard let session else { break }
            let sourceTime = Double(window.centerSample) / 48_000
            guard let output = try? window.samples.withUnsafeBufferPointer({ try session.process(samples: $0, sourceTime: sourceTime) }) else { continue }
            frames.append(contentsOf: output)
        }
        return frames
    }

    func finishAndDestroy() -> [iPadPitchFrame] {
        guard let session else { return [] }
        let frames = (try? session.finish()) ?? []
        session.close()
        self.session = nil
        return frames
    }
}

enum iPadTuner {
    static func label(for frequency: Double?) -> String {
        guard let frequency, frequency > 0 else { return "—" }
        let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
        let names = ["Do", "Do♯", "Re", "Re♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]
        return "\(names[(midi % 12 + 12) % 12])\(midi / 12 - 1)"
    }
}
