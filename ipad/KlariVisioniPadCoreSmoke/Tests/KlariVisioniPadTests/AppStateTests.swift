@testable import KlariVisioniPad
import AVFoundation
import XCTest

final class AppStateTests: XCTestCase {
    @MainActor private final class TestIdleTimer: iPadIdleTimerPolicy {
        var isIdleTimerDisabled = false
    }

    func testInvalidStoredEngineFallsBackToYINv1() {
        XCTAssertEqual(iPadAppState.engine("unexpected"), .yinV1)
    }

    func testStudyAndLiveEngineKeysAreIndependent() {
        XCTAssertNotEqual(iPadAppState.studyEngineKey, iPadAppState.liveEngineKey)
    }

    func testStudyAndLiveEnginePersistenceRemainSeparate() {
        let name = "KlariVision-iPadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = iPadAppState(defaults: defaults)
        state.studyEngine = .vpmLike
        state.liveEngine = .pitchEngineV2
        let restored = iPadAppState(defaults: defaults)
        XCTAssertEqual(restored.studyEngine, .vpmLike)
        XCTAssertEqual(restored.liveEngine, .pitchEngineV2)
    }

    func testNavigationSafetyStopsHiddenLiveAndPausesStudy() {
        XCTAssertTrue(iPadNavigationSafety.stopsLive(whenMovingTo: .library))
        XCTAssertTrue(iPadNavigationSafety.stopsLive(whenMovingTo: .settings))
        XCTAssertFalse(iPadNavigationSafety.stopsLive(whenMovingTo: .home))
        XCTAssertTrue(iPadNavigationSafety.pausesStudy(whenMovingTo: .home))
        XCTAssertTrue(iPadNavigationSafety.pausesStudy(whenMovingTo: .settings))
        XCTAssertFalse(iPadNavigationSafety.pausesStudy(whenMovingTo: .library))
    }

    func testCompactNavigationKeepsTabsAndWorkspaceRouteSeparate() {
        var navigation = iPadCompactNavigationState()
        navigation.openListening()
        XCTAssertEqual(navigation.section, .home)
        XCTAssertEqual(navigation.route, .listening)
        navigation.openLive()
        XCTAssertEqual(navigation.route, .live)
        navigation.closeWorkspace()
        XCTAssertEqual(navigation.route, .none)
    }

    func testCompactTabSelectionClosesWorkspaceAndReturnsSafetyDecision() {
        var navigation = iPadCompactNavigationState()
        navigation.openLive()
        let liveDecision = navigation.select(.library)
        XCTAssertEqual(liveDecision, iPadNavigationTeardown(stopLive: true, pauseStudy: false))
        XCTAssertEqual(navigation.section, .library)
        XCTAssertEqual(navigation.route, .none)

        navigation.openListening()
        let settingsDecision = navigation.select(.settings)
        XCTAssertEqual(settingsDecision, iPadNavigationTeardown(stopLive: true, pauseStudy: true))
        XCTAssertEqual(navigation.route, .none)
    }

    func testCompactNavigationPolicyMatchesExistingNavigationSafety() {
        for section in iPadSection.allCases {
            let decision = iPadCompactNavigationPolicy.teardown(whenMovingTo: section)
            XCTAssertEqual(decision.stopLive, iPadNavigationSafety.stopsLive(whenMovingTo: section))
            XCTAssertEqual(decision.pauseStudy, iPadNavigationSafety.pausesStudy(whenMovingTo: section))
        }
    }

    func testCompactTeardownIsIdempotentAndRouteRemainsClosed() {
        var navigation = iPadCompactNavigationState()
        navigation.openLive()
        let first = navigation.select(.settings)
        let second = navigation.select(.settings)
        XCTAssertEqual(first, iPadNavigationTeardown(stopLive: true, pauseStudy: true))
        XCTAssertEqual(second, first)
        XCTAssertEqual(navigation.route, .none)
        XCTAssertEqual(navigation.section, .settings)
    }

    @MainActor
    func testPersistenceKeysAndLibraryFilenameRemainStable() throws {
        XCTAssertEqual(iPadAppState.studyEngineKey, "klarivision-ipad-study-pitch-engine-v1")
        XCTAssertEqual(iPadAppState.liveEngineKey, "klarivision-ipad-live-pitch-engine-v1")
        XCTAssertEqual(iPadLiveState.makamKey, "klarivision-ipad-live-makam-v1")
        XCTAssertEqual(iPadLiveState.kararKey, "klarivision-ipad-live-karar-v1")

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try iPadStudyLibraryStore(fileURL: root.appendingPathComponent("Studies-v1.json"))
        XCTAssertEqual(store.fileURL.lastPathComponent, "Studies-v1.json")
    }

    @MainActor
    func testStudyAndLiveWebViewsAreDistinctAndStableForStoreLifetime() throws {
        let library = try iPadStudyLibraryStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("web-\(UUID().uuidString).json"))
        let study = iPadStudyState(libraryStore: library, idleTimer: TestIdleTimer())
        let live = iPadLiveState(defaults: UserDefaults(suiteName: "KlariVision-web-\(UUID().uuidString)")!)
        let studyIdentity = study.webView.webViewIdentity
        let liveIdentity = live.graph.webViewIdentity
        XCTAssertNotEqual(studyIdentity, liveIdentity)
        XCTAssertEqual(study.webView.webViewIdentity, studyIdentity)
        XCTAssertEqual(live.graph.webViewIdentity, liveIdentity)
        study.pauseForLeavingWorkspace()
        XCTAssertEqual(study.webView.webViewIdentity, studyIdentity)
        XCTAssertEqual(live.graph.webViewIdentity, liveIdentity)
    }

    func testMusicContextsOfferAllRequestedChoicesAndPhysicalGuides() throws {
        XCTAssertEqual(iPadMakam.allCases.count, 8)
        XCTAssertEqual(iPadKarar.allCases.count, 7)
        let context = iPadMusicContext(makam: .hicaz, karar: .neva)
        XCTAssertEqual(try XCTUnwrap(context.guideFrequencies().first), 440, accuracy: 0.001)
        XCTAssertEqual(iPadTuner.label(for: 440), "La4") // physical pitch stays physical; context only labels/guides.
    }

    func testGateAndKomaValidation() {
        XCTAssertEqual(iPadAppState.rms(forDbFS: -20), 0.1, accuracy: 0.000001)
        XCTAssertEqual(iPadAppState.rms(forDbFS: -60), 0.001, accuracy: 0.000001)
        XCTAssertEqual(iPadAppState.defaultKomaIntervals.reduce(0, +), 53)
        XCTAssertTrue(iPadAppState.validKomaIntervals(iPadAppState.defaultKomaIntervals))
        XCTAssertFalse(iPadAppState.validKomaIntervals([53]))
    }

    func testLiveGateCanUpdateRealCABIProductionSession() throws {
        let session = try iPadProductionPitchSession(engine: .yinV1)
        defer { session.close() }
        XCTAssertNoThrow(try session.setMinimumRMS(iPadAppState.rms(forDbFS: -30)))
    }

    @MainActor func testLiveMusicSelectionPersistsSeparately() {
        let name = "KlariVision-iPadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let live = iPadLiveState(defaults: defaults)
        live.makam = .kurdilihicazkar
        live.karar = .huseyni
        let restored = iPadLiveState(defaults: defaults)
        XCTAssertEqual(restored.makam, .kurdilihicazkar)
        XCTAssertEqual(restored.karar, .huseyni)
    }

    @MainActor func testStudyPlaybackRestoresInjectedIdleTimer() throws {
        let timer = TestIdleTimer()
        let store = try iPadStudyLibraryStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("idle-\(UUID().uuidString).json"))
        let state = iPadStudyState(libraryStore: store, idleTimer: timer)
        state.setPlaying(true)
        XCTAssertTrue(timer.isIdleTimerDisabled)
        state.pauseForLeavingWorkspace()
        XCTAssertFalse(timer.isIdleTimerDisabled)
    }

    func testLibraryPersistsAppOwnedMetadataAndSafeRemove() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("Studies-v1.json")
        let store = try iPadStudyLibraryStore(fileURL: file)
        let owned = directory.appendingPathComponent("Imports/owned.wav")
        let study = iPadStudy(id: UUID(), sourceURL: owned, title: "Yerel çalışma", duration: 2, frames: [], engine: .yinV1, context: iPadMusicContext(makam: .ussak, karar: .dugah), analyzedAt: Date(timeIntervalSince1970: 0))
        try store.save([study])
        XCTAssertEqual(try store.load(), [study])
        XCTAssertEqual(try store.remove(study.id, from: [study]), [])
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path)) // list removal never targets media.
    }

    func testAllEnginesRemainNeutralUserChoices() {
        XCTAssertEqual(iPadPitchEngine.allCases.map(\.title), ["YIN v1", "Pitch Engine v2", "VPM-benzeri"])
    }

    func testStudyImportValidatesAudioAndVideoExtensions() {
        XCTAssertTrue(iPadStudyImportService.isSupported(URL(fileURLWithPath: "/tmp/example.m4a")))
        XCTAssertTrue(iPadStudyImportService.isSupported(URL(fileURLWithPath: "/tmp/example.mov")))
        XCTAssertFalse(iPadStudyImportService.isSupported(URL(fileURLWithPath: "/tmp/example.pdf")))
    }

    func testImportDestinationsCannotCollide() throws {
        let source = URL(fileURLWithPath: "/tmp/example.wav")
        XCTAssertNotEqual(
            try iPadStudyImportService.destinationURL(for: source),
            try iPadStudyImportService.destinationURL(for: source)
        )
    }

    func testCompletedRecordingImportTrackerPreventsDuplicatesOnlyAfterSuccess() {
        let recording = URL(fileURLWithPath: "/tmp/completed-recording.wav")
        var tracker = iPadCompletedRecordingImportTracker()
        XCTAssertTrue(tracker.begin(recording))
        XCTAssertFalse(tracker.begin(recording)) // concurrent taps share one import
        tracker.finish(recording, succeeded: false)
        XCTAssertFalse(tracker.contains(recording))
        XCTAssertTrue(tracker.begin(recording)) // failed analysis keeps the WAV retryable
        tracker.finish(recording, succeeded: true)
        XCTAssertTrue(tracker.contains(recording))
        XCTAssertFalse(tracker.begin(recording)) // successful import cannot be duplicated
    }

    @MainActor func testCompletedRecordingURLSurvivesLiveTeardownState() {
        let live = iPadLiveState(defaults: UserDefaults(suiteName: "KlariVision-recording-\(UUID().uuidString)")!)
        let recording = URL(fileURLWithPath: "/tmp/completed-recording.wav")
        live.recording = .completed(recording)
        XCTAssertEqual(live.completedRecordingURL, recording)
    }

    @MainActor func testStudyImportPhaseReportsInFlightWork() throws {
        let store = try iPadStudyLibraryStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phase-\(UUID().uuidString).json"))
        let state = iPadStudyState(libraryStore: store, idleTimer: TestIdleTimer())
        XCTAssertFalse(state.isImporting)
        state.phase = .importing
        XCTAssertTrue(state.isImporting)
        state.phase = .analyzing(0.42)
        XCTAssertTrue(state.isImporting)
        state.phase = .failed("retry")
        XCTAssertFalse(state.isImporting)
    }

    @MainActor func testCompletedWAVCopiesAnalyzesWithSelectedEngineAndCannotBeAddedTwice() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recording = directory.appendingPathComponent("live-recording.wav")
        try writeTestWAV(to: recording)
        let store = try iPadStudyLibraryStore(fileURL: directory.appendingPathComponent("Studies-v1.json"))
        let state = iPadStudyState(libraryStore: store, idleTimer: TestIdleTimer())

        let firstImport = await state.importAndAnalyze(recording, engine: .pitchEngineV2, isCompletedRecording: true)
        XCTAssertTrue(firstImport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path)) // original Recording WAV is never consumed
        XCTAssertEqual(state.studies.count, 1)
        XCTAssertEqual(state.currentStudy?.engine, .pitchEngineV2)
        XCTAssertNotEqual(state.currentStudy?.sourceURL.standardizedFileURL, recording.standardizedFileURL) // study owns an Imports copy
        let duplicateImport = await state.importAndAnalyze(recording, engine: .pitchEngineV2, isCompletedRecording: true)
        XCTAssertFalse(duplicateImport)
        XCTAssertEqual(state.studies.count, 1)
    }

    @MainActor func testFailedCompletedRecordingRemainsOnDiskAndOffersRetry() async throws {
        let recording = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording-failure-\(UUID().uuidString).pdf")
        try Data("not audio".utf8).write(to: recording)
        let store = try iPadStudyLibraryStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("failure-\(UUID().uuidString).json"))
        let state = iPadStudyState(libraryStore: store, idleTimer: TestIdleTimer())
        let failedImport = await state.importAndAnalyze(recording, engine: .yinV1, isCompletedRecording: true)
        XCTAssertFalse(failedImport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertTrue(state.canRetryCompletedRecording)
    }

    @MainActor func testLateViewerFailureDoesNotPersistAndRetryCreatesOneStudy() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording-viewer-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recording = directory.appendingPathComponent("live-recording.wav")
        try writeTestWAV(to: recording)
        let store = try iPadStudyLibraryStore(fileURL: directory.appendingPathComponent("Studies-v1.json"))
        var shouldFailViewer = true
        let state = iPadStudyState(libraryStore: store, idleTimer: TestIdleTimer()) { webView, study in
            if shouldFailViewer {
                shouldFailViewer = false
                throw iPadStudyImportError.unableToCopy
            }
            try iPadStudyViewerResource.load(into: webView, study: study)
        }

        let failedImport = await state.importAndAnalyze(recording, engine: .pitchEngineV2, isCompletedRecording: true)
        XCTAssertFalse(failedImport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertTrue(state.canRetryCompletedRecording)
        XCTAssertTrue(state.studies.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)

        let retry = await state.retryCompletedRecording(engine: .pitchEngineV2)
        XCTAssertTrue(retry)
        XCTAssertEqual(state.studies.count, 1)
        XCTAssertEqual(try store.load().count, 1)
    }

    private func writeTestWAV(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames: AVAudioFrameCount = 4_800
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000) * 0.2)
        }
        try file.write(from: buffer)
    }

    func testWebCommandsRemainSerializedUntilViewerIsReady() {
        var queue = iPadStudyCommandQueue()
        queue.append(.seek(12.5))
        queue.append(.rate(1.05))
        queue.append(.markA)
        queue.append(.markB)
        queue.append(.loop)
        XCTAssertEqual(queue.drainWhenReady(), [.seek(12.5), .rate(1.05), .markA, .markB, .loop])
        XCTAssertEqual(queue.drainWhenReady(), [])
    }

    func testStudyPlaybackRatesMatchMacOSStepperContract() throws {
        XCTAssertEqual(try XCTUnwrap(iPadStudyPlaybackRate.values.first), 0.10, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(iPadStudyPlaybackRate.values.last), 2.00, accuracy: 0.000_001)
        XCTAssertEqual(iPadStudyPlaybackRate.values.count, 39)
        XCTAssertTrue(zip(iPadStudyPlaybackRate.values, iPadStudyPlaybackRate.values.dropFirst()).allSatisfy { abs(($1 - $0) - 0.05) < 0.000_001 })
        XCTAssertEqual(iPadStudyPlaybackRate.label(for: 1.05), "1,05×")
    }

    func testBundledStudyViewerFollowChangesVerticalViewport() throws {
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "StudyViewer", withExtension: "html"))
        let source = try String(contentsOf: resource, encoding: .utf8)
        XCTAssertTrue(source.contains("if(following&&all.length)"))
        XCTAssertTrue(source.contains("verticalCenter=followedCenter(verticalCenter,median(nearby))"))
        XCTAssertTrue(source.contains("following ? cents(frequency) : frequency"))
        XCTAssertTrue(source.contains("visibleDuration=following?Math.min(12,d):d"))
        XCTAssertTrue(source.contains("timeX=time=>(time-windowStart)/visibleDuration*w"))
    }

    func testLiveGraphPayloadNormalizesNonFiniteFramesWithoutLosingVoicedPitch() throws {
        let frames = [
            iPadPitchFrame(time: 0, frequency: .nan, confidence: .infinity, voiced: false),
            iPadPitchFrame(time: 0.01, frequency: 440, confidence: 0.9, voiced: true),
            iPadPitchFrame(time: .nan, frequency: 220, confidence: 0.8, voiced: true),
        ]
        let payload = iPadLiveGraphPayload.make(from: frames)
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload[0]["f"] as? Double, 0)
        XCTAssertEqual(payload[0]["c"] as? Double, 0)
        XCTAssertEqual(payload[0]["v"] as? Bool, false)
        XCTAssertEqual(payload[1]["f"] as? Double, 440)
        XCTAssertEqual(payload[1]["v"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testBundledLiveViewerCannotRemainStuckBehindSuspendedAnimationFrame() throws {
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "LiveViewer", withExtension: "html"))
        let source = try String(contentsOf: resource, encoding: .utf8)
        XCTAssertTrue(source.contains("frameFallback = setTimeout"))
        XCTAssertTrue(source.contains("if (framePending) draw()"))
        XCTAssertTrue(source.contains("clearTimeout(frameFallback)"))
    }

    func testBundledLiveViewerScalesBothCanvasDimensionsForRetinaDisplays() throws {
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "LiveViewer", withExtension: "html"))
        let source = try String(contentsOf: resource, encoding: .utf8)
        XCTAssertTrue(source.contains("const backingWidth = Math.max(1, Math.round(width * scale))"))
        XCTAssertTrue(source.contains("const backingHeight = Math.max(1, Math.round(height * scale))"))
        XCTAssertTrue(source.contains("canvas.width = backingWidth"))
        XCTAssertTrue(source.contains("canvas.height = backingHeight"))
        XCTAssertFalse(source.contains("canvas.height = height"))
    }

    func testLiveDiagnosticPreservesStageAndSystemErrorIdentity() {
        let original = NSError(domain: "NSOSStatusErrorDomain", code: -50, userInfo: [NSLocalizedDescriptionKey: "Geçersiz parametre"])
        let diagnostic = iPadLiveDiagnosticError.wrapping(original, at: .engineStart)
        XCTAssertEqual(diagnostic.stage, .engineStart)
        XCTAssertEqual(diagnostic.domain, "NSOSStatusErrorDomain")
        XCTAssertEqual(diagnostic.code, -50)
        XCTAssertTrue(diagnostic.errorDescription?.contains("Mikrofon ses motoru") == true)
        XCTAssertTrue(diagnostic.errorDescription?.contains("NSOSStatusErrorDomain -50") == true)
    }

    func testLiveRoutePolicyOnlyIgnoresExpectedCategoryAndOutputOverride() {
        XCTAssertEqual(
            iPadLiveRouteChangePolicy.action(reasonRawValue: 3, expectedOwnCategoryChange: true),
            .continueCapturing
        )
        XCTAssertEqual(
            iPadLiveRouteChangePolicy.action(reasonRawValue: 4, expectedOwnCategoryChange: false),
            .continueCapturing
        )
        XCTAssertEqual(
            iPadLiveRouteChangePolicy.action(reasonRawValue: 3, expectedOwnCategoryChange: false),
            .stop("Ses rotası değişti. Yeniden başlatmak için Başlat'a dokunun.")
        )
        XCTAssertEqual(
            iPadLiveRouteChangePolicy.action(reasonRawValue: 2, expectedOwnCategoryChange: true),
            .stop("Mikrofon rotası kaldırıldı. Yeniden başlatmak için Başlat'a dokunun.")
        )
        XCTAssertEqual(
            iPadLiveRouteChangePolicy.action(reasonRawValue: 7, expectedOwnCategoryChange: true),
            .stop("Mikrofon için uygun ses rotası bulunamadı. Yeniden başlatmak için Başlat'a dokunun.")
        )
        XCTAssertEqual(
            iPadLiveRouteChangePolicy.action(reasonRawValue: 8, expectedOwnCategoryChange: true),
            .stop("Ses rotası değişti. Yeniden başlatmak için Başlat'a dokunun.")
        )
    }

    func testLiveLifecycleRequiresExplicitRestartAfterInterruption() {
        var lifecycle = iPadLiveLifecycle()
        lifecycle.requestStart()
        XCTAssertEqual(lifecycle.phase, .requestingPermission)
        lifecycle.started()
        lifecycle.stopped(reason: "Arka plan")
        XCTAssertEqual(lifecycle.phase, .interrupted("Arka plan"))
        lifecycle.requestStart()
        XCTAssertEqual(lifecycle.phase, .requestingPermission)
    }

    func testLiveLifecycleStopIsSafeToRepeatAndRestartIsExplicit() {
        var lifecycle = iPadLiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        lifecycle.stopped(reason: nil)
        XCTAssertEqual(lifecycle.phase, .idle)
        lifecycle.stopped(reason: nil)
        XCTAssertEqual(lifecycle.phase, .idle)
        lifecycle.requestStart()
        XCTAssertEqual(lifecycle.phase, .requestingPermission)
    }

    func testPCMAccumulatorProduces1536SampleWindowsAt512SampleHop() {
        var accumulator = iPadPCMWindowAccumulator()
        let input = (0..<2_560).map(Float.init)
        input.withUnsafeBufferPointer { accumulator.append($0) }
        let windows = accumulator.drainWindows()
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map(\.centerSample), [768, 1_280, 1_792])
        XCTAssertEqual(windows[1].samples.first, 512)
    }

    func testOfflineWindowIsExactly1536SamplesAndAdapterRejectsLongerInput() throws {
        let samples = (0..<4_096).map(Float.init)
        let window = iPadOfflinePitchAnalyzer.analysisWindow(from: samples, windowSize: 1_536)
        XCTAssertEqual(window.count, 1_536)
        let session = try iPadProductionPitchSession(engine: .yinV1)
        defer { session.close() }
        XCTAssertThrowsError(try samples.withUnsafeBufferPointer { try session.process(samples: $0, sourceTime: 0.016) })
    }

    func testAppABIAdapterProduces440HzFramesForEveryEngineAndBothConsumers() throws {
        let contract = try iPadPitchABIAdapter.contract()
        let rate = 48_000.0
        let windows = 18
        for engine in iPadPitchEngine.allCases {
            let studySession = try iPadProductionPitchSession(engine: engine)
            defer { studySession.close() }
            var studyFrames: [iPadPitchFrame] = []
            var liveFrames: [iPadPitchFrame] = []
            guard let liveProcessor = iPadLiveCoreProcessor(engine: engine) else {
                return XCTFail("Canlı tüketici oturumu kurulamadı: \(engine)")
            }
            for index in 0..<windows {
                let start = index * Int(contract.hop_size)
                let samples = (0..<Int(contract.window_size)).map {
                    Float(0.35 * sin(2 * .pi * 440 * Double(start + $0) / rate))
                }
                let time = Double(start + Int(contract.window_size) / 2) / rate
                studyFrames.append(contentsOf: try samples.withUnsafeBufferPointer {
                    try studySession.process(samples: $0, sourceTime: time)
                })
                samples.withUnsafeBufferPointer { liveFrames.append(contentsOf: liveProcessor.process($0)) }
            }
            studyFrames.append(contentsOf: try studySession.finish())
            _ = liveProcessor.finishAndDestroy()
            XCTAssertTrue(studyFrames.contains(where: { $0.voiced && abs($0.frequency - 440) < 15 }), "Dinleme adaptörü 440 Hz üretmedi: \(engine)")
            XCTAssertTrue(liveFrames.contains(where: { $0.voiced && abs($0.frequency - 440) < 15 }), "Çalma adaptörü 440 Hz üretmedi: \(engine)")
        }
    }
}
