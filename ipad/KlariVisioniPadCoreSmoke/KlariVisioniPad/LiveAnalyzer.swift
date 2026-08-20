// KlariVision iPhone/iPad — mikrofon, WAV kayıt ve canlı pitch orkestrasyonu.
// Audio tap sahipli PCM kopyası üretir; dönüştürme, kayıt ve C ABI oturumu tek
// aktörde sıralanır. UI yalnız MainActor'da güncellenir. Kesinti, rota, arka
// plan ve media-services reset aynı idempotent teardown yolunu kullanır.

import AVFoundation
import Foundation
import OSLog
import UIKit

enum iPadLiveDiagnosticStage: String, Equatable, Sendable {
    case audioSessionCategory = "audio-session-category"
    case preferredSampleRate = "preferred-sample-rate"
    case audioSessionActivation = "audio-session-activation"
    case inputFormat = "input-output-format"
    case converterSetup = "converter-setup"
    case converterRuntime = "converter-runtime"
    case engineStart = "audio-engine-start"
    case recordingWrite = "recording-write"

    var userMessage: String {
        switch self {
        case .audioSessionCategory: "Mikrofon ses oturumu ayarlanamadı."
        case .preferredSampleRate: "48 kHz mikrofon tercihi uygulanamadı."
        case .audioSessionActivation: "Mikrofon ses oturumu etkinleştirilemedi."
        case .inputFormat: "Kullanılabilir bir mikrofon giriş biçimi bulunamadı."
        case .converterSetup: "Mikrofon biçimi 48 kHz çalışma biçimine dönüştürülemedi."
        case .converterRuntime: "Mikrofon verisi 48 kHz çalışma biçimine dönüştürülemedi."
        case .engineStart: "Mikrofon ses motoru başlatılamadı."
        case .recordingWrite: "WAV kaydı yazılamadı."
        }
    }
}

struct iPadLiveDiagnosticError: LocalizedError, Sendable {
    let stage: iPadLiveDiagnosticStage
    let domain: String
    let code: Int
    let detail: String

    var errorDescription: String? {
        "\(stage.userMessage) [\(domain) \(code): \(detail)]"
    }

    static func wrapping(_ error: Error, at stage: iPadLiveDiagnosticStage) -> Self {
        let nsError = error as NSError
        iPadLiveDiagnostics.logger.error("Live audio failure stage=\(stage.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .public)")
        return Self(stage: stage, domain: nsError.domain, code: nsError.code, detail: nsError.localizedDescription)
    }

    static func invalidInputFormat(sampleRate: Double, channels: Int) -> Self {
        let detail = "sampleRate=\(sampleRate), channels=\(channels)"
        iPadLiveDiagnostics.logger.error("Live audio failure stage=input-output-format \(detail, privacy: .public)")
        return Self(stage: .inputFormat, domain: "AVAudioInputNode", code: 0, detail: detail)
    }
}

enum iPadLiveDiagnostics {
    static let logger = Logger(subsystem: "com.aykerme.KlariVisioniPad", category: "LiveAudio")
}

private struct iPadLiveStartCancelled: Error {
    let reason: String?
}

struct iPadCapturedPCM: Sendable {
    let channels: [[Float]]
    let sampleRate: Double

    init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    init?(copying buffer: AVAudioPCMBuffer) {
        guard let pointers = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.frameLength)
        channels = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: pointers[$0], count: count))
        }
        sampleRate = buffer.format.sampleRate
    }
}

/// AVAudioEngine invokes its tap on a realtime queue. Building this callback
/// outside the @MainActor analyzer prevents Swift 6 from attaching UI actor
/// isolation to the AVFAudio callback. Only an owned, Sendable PCM copy crosses
/// into the worker actor; AVAudioPCMBuffer itself never leaves the callback.
enum iPadLiveTap {
    nonisolated static func make(worker: iPadLiveWorker) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            guard let captured = iPadCapturedPCM(copying: buffer) else {
                Task { await worker.consume(iPadCapturedPCM(channels: [], sampleRate: 0)) }
                return
            }
            Task { await worker.consume(captured) }
        }
    }
}

/// The AVAudioConverter input callback is synchronous but marked Sendable by
/// AVFAudio. This one-shot lock-protected owner makes the buffer transfer
/// explicit and safe if the framework ever invokes that callback off-thread.
private final class iPadConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        defer { buffer = nil }
        return buffer
    }
}

actor iPadLiveWorker {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var processor: iPadLiveCoreProcessor?
    private var recordingFile: AVAudioFile?
    private var batch: [iPadPitchFrame] = []
    private var flushScheduled = false
    private var frameSink: (@MainActor @Sendable ([iPadPitchFrame]) -> Void)?
    private var recordingSink: (@MainActor @Sendable (iPadRecordingPhase) -> Void)?
    private var failureSink: (@MainActor @Sendable (String) -> Void)?

    func setSinks(
        frames: @escaping @MainActor @Sendable ([iPadPitchFrame]) -> Void,
        recording: @escaping @MainActor @Sendable (iPadRecordingPhase) -> Void,
        failure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        frameSink = frames
        recordingSink = recording
        failureSink = failure
    }

    func start(engine: iPadPitchEngine, minimumRMS: Double, sampleRate: Double, channels: Int) throws {
        guard channels > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let processor = iPadLiveCoreProcessor(engine: engine, minimumRMS: minimumRMS)
        else { throw iPadLiveError.converter }
        self.sourceFormat = source
        self.targetFormat = target
        self.converter = converter
        self.processor = processor
        batch.removeAll()
    }

    func consume(_ captured: iPadCapturedPCM) async {
        guard let sourceFormat, let targetFormat, let converter, let processor,
              captured.channels.count == Int(sourceFormat.channelCount),
              captured.sampleRate == sourceFormat.sampleRate,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(captured.channels.first?.count ?? 0))
        else { await fail("Mikrofon biçimi dönüştürülemedi."); return }
        source.frameLength = AVAudioFrameCount(captured.channels.first?.count ?? 0)
        guard let sourcePointers = source.floatChannelData else { await fail("Mikrofon biçimi dönüştürülemedi."); return }
        for (index, channel) in captured.channels.enumerated() {
            channel.withUnsafeBufferPointer { sourcePointers[index].update(from: $0.baseAddress!, count: channel.count) }
        }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * 48_000 / max(sourceFormat.sampleRate, 1) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { await fail("Mikrofon biçimi dönüştürülemedi."); return }
        let provider = iPadConverterInput(source)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard let input = provider.take() else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData; return input
        }
        guard status != .error, error == nil, let samples = converted.floatChannelData?[0] else {
            let message = error.map { iPadLiveDiagnosticError.wrapping($0, at: .converterRuntime).errorDescription }
                ?? iPadLiveDiagnosticError(stage: .converterRuntime, domain: "AVAudioConverter", code: Int(status.rawValue), detail: "Dönüştürme çıktısı üretilemedi.").errorDescription
            if error == nil { iPadLiveDiagnostics.logger.error("Live audio failure stage=converter-runtime status=\(status.rawValue, privacy: .public)") }
            await fail(message ?? iPadLiveDiagnosticStage.converterRuntime.userMessage)
            return
        }
        if let recordingFile {
            do { try recordingFile.write(from: converted) }
            catch {
                await publishRecording(.failed(iPadLiveDiagnosticError.wrapping(error, at: .recordingWrite).errorDescription ?? iPadLiveDiagnosticStage.recordingWrite.userMessage))
                self.recordingFile = nil
            }
        }
        let frames = processor.process(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        await enqueue(frames)
    }

    func toggleRecording(in directory: URL) async -> iPadRecordingPhase {
        if recordingFile != nil { return await finishRecording() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let targetFormat else { throw iPadLiveError.converter }
            let url = directory.appendingPathComponent("KlariVision-\(UUID().uuidString).wav")
            recordingFile = try AVAudioFile(forWriting: url, settings: targetFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            await publishRecording(.active)
            return .active
        } catch {
            let state = iPadRecordingPhase.failed("WAV kaydı başlatılamadı.")
            await publishRecording(state)
            return state
        }
    }

    func stop() async -> iPadRecordingPhase {
        if let processor { await enqueue(processor.finishAndDestroy()) }
        self.processor = nil
        converter = nil
        sourceFormat = nil
        targetFormat = nil
        let recording = await finishRecording()
        await flushNow()
        return recording
    }

    func isActive() -> Bool { processor != nil || recordingFile != nil }

    private func finishRecording() async -> iPadRecordingPhase {
        guard let recordingFile else { return .idle }
        self.recordingFile = nil
        let state = iPadRecordingPhase.completed(recordingFile.url)
        await publishRecording(state)
        return state
    }

    private func enqueue(_ frames: [iPadPitchFrame]) async {
        guard !frames.isEmpty else { return }
        batch.append(contentsOf: frames)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            await self?.flushNow()
        }
    }

    private func flushNow() async {
        flushScheduled = false
        guard !batch.isEmpty else { return }
        let output = batch; batch.removeAll()
        await frameSink?(output)
    }

    private func publishRecording(_ state: iPadRecordingPhase) async { await recordingSink?(state) }
    private func fail(_ message: String) async { await failureSink?(message) }
}

@MainActor
@Observable
final class iPadLiveState {
    static let makamKey = "klarivision-ipad-live-makam-v1"
    static let kararKey = "klarivision-ipad-live-karar-v1"
    private var lifecycle = iPadLiveLifecycle()
    var phase: iPadLivePhase { lifecycle.phase }
    var recording: iPadRecordingPhase = .idle
    var latestFrame: iPadPitchFrame?
    var makam: iPadMakam { didSet { defaults.set(makam.rawValue, forKey: Self.makamKey); publishContext() } }
    var karar: iPadKarar { didSet { defaults.set(karar.rawValue, forKey: Self.kararKey); publishContext() } }
    var followsCurve = true { didSet { publishContext() } }
    let graph = iPadLiveWebViewStore()
    private let analyzer = iPadLiveAnalyzer()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        makam = iPadMakam(rawValue: defaults.string(forKey: Self.makamKey) ?? "") ?? .nihavend
        karar = iPadKarar(rawValue: defaults.string(forKey: Self.kararKey) ?? "") ?? .rast
        analyzer.onFrames = { [weak self] frames in
            guard let self else { return }
            self.latestFrame = frames.last(where: \.voiced) ?? self.latestFrame
            self.graph.append(frames, context: self.musicContext)
        }
        analyzer.onStopped = { [weak self] reason, recording in
            guard let self else { return }
            // A completed WAV is a user-visible result. Stopping the live
            // session after recording must not replace it with `.idle`, or the
            // root cannot safely send that URL to the study importer.
            if case .completed = recording { self.recording = recording }
            self.lifecycle.stopped(reason: reason)
        }
        analyzer.onRecording = { [weak self] recording in self?.recording = recording }
    }

    var musicContext: iPadMusicContext { iPadMusicContext(makam: makam, karar: karar, followsCurve: followsCurve) }

    func configure(graphPitchColor: String, guideColor: String) {
        graph.setStyle(pitchColor: graphPitchColor, guideColor: guideColor)
        publishContext()
    }

    func start(engine: iPadPitchEngine, signalGateDbFS: Double = -42) async {
        lifecycle.requestStart()
        do { try graph.load(); try await analyzer.start(engine: engine, minimumRMS: iPadAppState.rms(forDbFS: signalGateDbFS)); publishContext(); lifecycle.started() }
        catch let cancellation as iPadLiveStartCancelled { lifecycle.stopped(reason: cancellation.reason) }
        catch let error as LocalizedError { lifecycle.failed(error.errorDescription ?? "Mikrofon başlatılamadı.") }
        catch { lifecycle.failed("Mikrofon başlatılamadı.") }
    }

    func stop() { Task { await analyzer.stop(reason: nil) } }
    func stopForNavigation() async { await analyzer.stop(reason: nil) }
    func toggleRecording() { Task { recording = await analyzer.toggleRecording() } }
    var completedRecordingURL: URL? {
        guard case let .completed(url) = recording else { return nil }
        return url
    }
    private func publishContext() { graph.setContext(musicContext) }
}

enum iPadLiveError: LocalizedError, Sendable {
    case permissionDenied, audioSession, converter, core
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Mikrofon izni verilmedi. Ayarlar'dan izin verip yeniden başlatın."
        case .audioSession: "Ses oturumu başlatılamadı."
        case .converter: "Mikrofon biçimi 48 kHz çalışma biçimine dönüştürülemedi."
        case .core: "Canlı pitch çekirdeği başlatılamadı."
        }
    }
}

@MainActor
final class iPadLiveAnalyzer: NSObject {
    var onFrames: (([iPadPitchFrame]) -> Void)?
    var onRecording: ((iPadRecordingPhase) -> Void)?
    var onStopped: ((String?, iPadRecordingPhase) -> Void)?
    private var engine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let worker = iPadLiveWorker()
    private var idleTimerWasDisabled = false
    private var hasTap = false
    private weak var tappedInput: AVAudioInputNode?
    private var isStarting = false
    private var isStopping = false
    private var audioSessionIsActive = false
    private var startWasCancelled = false
    private var startStopReason: String?
    private var pendingOwnCategoryChanges = 0
    private var startAttempt = 0
    private(set) var recordingResult: iPadRecordingPhase = .idle

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: audioSession)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: audioSession)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: audioSession)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start(engine selectedEngine: iPadPitchEngine, minimumRMS: Double) async throws {
        if isStopping {
            throw iPadLiveStartCancelled(reason: "Ses oturumu kapanıyor. Kapanma tamamlanınca Başlat'a yeniden dokunun.")
        }
        guard !isStarting, !engine.isRunning, !hasTap else { return }
        var didStart = false
        isStarting = true
        startWasCancelled = false
        startStopReason = nil
        startAttempt &+= 1
        let attempt = startAttempt
        defer {
            isStarting = false
            if !didStart { Task { await self.stop(reason: nil) } }
        }
        guard await AVAudioApplication.requestRecordPermission() else { throw iPadLiveError.permissionDenied }
        try throwIfStartWasCancelled()
        // The category-change notification emitted by this call can arrive
        // after an await below. It is consumed once and expires shortly after
        // this start attempt, so later real category changes stay safe stops.
        pendingOwnCategoryChanges = 1
        expireExpectedCategoryChange(for: attempt)
        do { try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP]) }
        catch { throw iPadLiveDiagnosticError.wrapping(error, at: .audioSessionCategory) }
        do { try audioSession.setPreferredSampleRate(48_000) }
        catch { throw iPadLiveDiagnosticError.wrapping(error, at: .preferredSampleRate) }
        do { try audioSession.setActive(true) }
        catch { throw iPadLiveDiagnosticError.wrapping(error, at: .audioSessionActivation) }
        audioSessionIsActive = true
        let input = engine.inputNode
        // AVAudioNode's iOS header documents that an input-node tap attaches
        // to its output bus, and its example obtains this exact format first.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw iPadLiveDiagnosticError.invalidInputFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        }
        await worker.setSinks(
            frames: { [weak self] frames in self?.onFrames?(frames) },
            recording: { [weak self] state in self?.recordingResult = state; self?.onRecording?(state) },
            failure: { [weak self] message in Task { await self?.stop(reason: message) } }
        )
        try throwIfStartWasCancelled()
        do {
            try await worker.start(engine: selectedEngine, minimumRMS: minimumRMS, sampleRate: format.sampleRate, channels: Int(format.channelCount))
        } catch {
            throw iPadLiveDiagnosticError.wrapping(error, at: .converterSetup)
        }
        try throwIfStartWasCancelled()
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: iPadLiveTap.make(worker: worker))
        tappedInput = input
        hasTap = true
        try throwIfStartWasCancelled()
        engine.prepare()
        do { try engine.start() }
        catch { throw iPadLiveDiagnosticError.wrapping(error, at: .engineStart) }
        didStart = true
    }

    func toggleRecording() async -> iPadRecordingPhase {
        guard engine.isRunning else { return recordingResult }
        do {
            let directory = try iPadStudyImportService.importsDirectory().deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
            return await worker.toggleRecording(in: directory)
        } catch { return .failed("WAV kaydı başlatılamadı.") }
    }

    func stop(reason: String?) async {
        guard !isStopping else { return }
        if isStarting {
            startWasCancelled = true
            startStopReason = reason
        }
        let workerActive = await worker.isActive()
        guard hasTap || engine.isRunning || workerActive || audioSessionIsActive || isStarting else { return }
        isStopping = true
        defer { isStopping = false }
        if hasTap {
            // A route change can replace `engine.inputNode`. Removing from a
            // freshly queried node leaves the original tap installed and the
            // next installTap raises an Objective-C exception. Always detach
            // from the exact node that accepted this session's tap.
            tappedInput?.removeTap(onBus: 0)
            tappedInput = nil
            hasTap = false
        }
        engine.stop()
        engine.reset()
        let recording = await worker.stop()
        recordingResult = recording
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionIsActive = false
        // AVAudioEngine can retain route-specific graph state even after a
        // clean stop. A new instance makes the next explicit user start a
        // genuinely fresh session and guarantees that no old tap survives.
        engine = AVAudioEngine()
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        onStopped?(reason, recording)
    }

    @objc private func handleInterruption(_ note: Notification) {
        let rawType = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        iPadLiveDiagnostics.logger.notice("Live audio interruption type=\(rawType.map(String.init) ?? "missing", privacy: .public)")
        guard rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { await stop(reason: "Ses kesintiye uğradı. Yeniden başlatmak için Başlat'a dokunun.") }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        let rawReason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription).map(routeSummary) ?? "missing"
        let current = routeSummary(audioSession.currentRoute)
        let action = iPadLiveRouteChangePolicy.action(
            reasonRawValue: rawReason,
            expectedOwnCategoryChange: pendingOwnCategoryChanges > 0
        )
        if rawReason == AVAudioSession.RouteChangeReason.categoryChange.rawValue, pendingOwnCategoryChanges > 0 {
            pendingOwnCategoryChanges -= 1
        }
        iPadLiveDiagnostics.logger.notice("Live audio route change reason=\(rawReason.map(String.init) ?? "missing", privacy: .public) action=\(String(describing: action), privacy: .public) previous=\(previous, privacy: .public) current=\(current, privacy: .public)")
        guard case let .stop(reason) = action else { return }
        Task { await stop(reason: reason) }
    }
    @objc private func handleMediaServicesReset() { Task { await stop(reason: "Ses hizmeti sıfırlandı. Yeniden başlatmak için Başlat'a dokunun.") } }
    @objc private func handleBackground() { Task { await stop(reason: "Uygulama arka plana geçti. Mikrofon güvenle durduruldu.") } }

    private func throwIfStartWasCancelled() throws {
        if startWasCancelled { throw iPadLiveStartCancelled(reason: startStopReason) }
    }

    private func expireExpectedCategoryChange(for attempt: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.startAttempt == attempt else { return }
            self.pendingOwnCategoryChanges = 0
        }
    }

    private func routeSummary(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
    }
}
