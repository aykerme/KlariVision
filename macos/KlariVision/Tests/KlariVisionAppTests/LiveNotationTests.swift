import AppKit
import XCTest
@testable import KlariVisionApp

final class LiveNotationTests: XCTestCase {
    func testPitchEngineSettingsKeepsThreeNeutralUserChoices() {
        XCTAssertEqual(
            PitchEngineSettings.userChoices.map(\.id),
            ["yin_v1", "pitch_engine_v2", "vpm_like"]
        )
        XCTAssertEqual(
            PitchEngineSettings.userChoices.map(\.title),
            ["YIN v1", "Pitch Engine v2", "VPM-benzeri"]
        )
        XCTAssertEqual(PitchEngineSettings.initialEngine, "yin_v1")
        XCTAssertEqual(PitchEngineSettings.resolvedSelection(nil), "yin_v1")
        XCTAssertEqual(PitchEngineSettings.resolvedSelection("not-a-pitch-engine"), "yin_v1")
        for engine in PitchEngineSettings.userChoices {
            XCTAssertEqual(PitchEngineSettings.resolvedSelection(engine.id), engine.id)
            XCTAssertFalse(engine.title.localizedCaseInsensitiveContains("deneysel"))
        }
    }

    func testPitchEngineSelectionPersistsIndependentlyForStudyAndLiveModes() {
        let suiteName = "KlariVisionPitchEngineSettingsTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("vpm_like", forKey: PitchEngineSettings.studyEngineKey)
        defaults.set("pitch_engine_v2", forKey: PitchEngineSettings.liveEngineKey)

        XCTAssertEqual(
            PitchEngineSettings.storedSelection(
                for: PitchEngineSettings.studyEngineKey,
                defaults: defaults
            ),
            "vpm_like"
        )
        XCTAssertEqual(
            PitchEngineSettings.storedSelection(
                for: PitchEngineSettings.liveEngineKey,
                defaults: defaults
            ),
            "pitch_engine_v2"
        )
    }

    func testAppThemeHasStablePersistedChoices() {
        XCTAssertEqual(AppTheme(rawValue: "focus"), .focus)
        XCTAssertEqual(AppTheme(rawValue: "studio")?.colorScheme, .dark)
        XCTAssertEqual(AppTheme(rawValue: "classic")?.colorScheme, .light)
        XCTAssertNil(AppTheme(rawValue: "unknown"))
    }

    @MainActor
    func testAccessibilityCopyKeepsEngineChoiceNeutralAndDropFailureActionable() {
        XCTAssertEqual(AccessibilityText.listeningStatus, "Dinleme durumu")
        XCTAssertEqual(AccessibilityText.practiceStatus, "Çalma durumu")
        XCTAssertTrue(AccessibilityText.enginePickerHint.contains("eşit kullanıcı seçenekleridir"))
        XCTAssertFalse(AccessibilityText.enginePickerHint.localizedCaseInsensitiveContains("öner"))

        let library = RecentLibrary()
        library.reportDroppedFileFailure()
        XCTAssertEqual(library.analysisMessage, AccessibilityText.unsupportedDrop)
    }

    @MainActor
    func testDroppedMediaTypeAcceptsAudioAndRejectsText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlariVisionDropTypes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("sample.wav")
        let text = directory.appendingPathComponent("notes.txt")
        try Data().write(to: audio)
        try Data().write(to: text)

        XCTAssertTrue(RecentLibrary.isSupportedMediaFile(audio))
        XCTAssertFalse(RecentLibrary.isSupportedMediaFile(text))
    }

    func testStudyPitchTrackMatchesViewerCandidateFiltering() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "frames": [
                ["time_seconds": 0.000, "frequency_hz": 82.4069, "voiced": true, "confidence": 0.9],
                ["time_seconds": 0.005, "frequency_hz": 164.8138, "voiced": true, "confidence": 0.9],
                ["time_seconds": 0.010, "frequency_hz": 82.4069, "voiced": true, "confidence": 0.9],
                ["time_seconds": 0.015, "frequency_hz": 220.0, "voiced": true, "confidence": 0.1],
                ["time_seconds": 0.020, "frequency_hz": 220.0, "voiced": false, "confidence": 0.9],
            ],
        ])

        let points = try StudyPitchTrack.prepareDisplayPoints(from: data)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.frequency), [82.4069, 82.4069])
    }

    func testStudyPitchTrackUsesThreePointMedianInCentDomain() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "frames": [
                ["time_seconds": 0.000, "frequency_hz": 220.0, "voiced": true, "confidence": 0.9],
                ["time_seconds": 0.005, "frequency_hz": 230.0, "voiced": true, "confidence": 0.9],
                ["time_seconds": 0.010, "frequency_hz": 225.0, "voiced": true, "confidence": 0.9],
                ["time_seconds": 0.080, "frequency_hz": 240.0, "voiced": true, "confidence": 0.9],
            ],
        ])

        let points = try StudyPitchTrack.prepareDisplayPoints(from: data)

        XCTAssertEqual(points[1].frequency, 225.0, accuracy: 0.000_001)
        XCTAssertEqual(points[2].frequency, 225.0, accuracy: 0.000_001)
        XCTAssertEqual(points[3].time - points[2].time, 0.070, accuracy: 0.000_001)
    }

    func testStudyPitchTrackFallsBackToEmbeddedViewerCurveWhenSidecarIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlariVisionEmbeddedCurve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let viewer = directory.appendingPathComponent("legacy-study.html")
        try """
        <!doctype html><script>
        const frames=[{"t":0,"hz":82.4069},{"t":0.04,"hz":110.0}];
        const validation=null;
        </script>
        """.write(to: viewer, atomically: true, encoding: .utf8)

        let track = try StudyPitchTrack.load(viewer: viewer)

        XCTAssertEqual(track.points.map(\.frequency), [82.4069, 110.0])
    }

    func testStudyPitchTrackFindsRelatedSidecarWhenTheLegacyVampNameIsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlariVisionSidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let viewer = directory.appendingPathComponent("study.html")
        try "<html></html>".write(to: viewer, atomically: true, encoding: .utf8)
        let sidecar = directory.appendingPathComponent("study.offline-pitch.json")
        let payload = try JSONSerialization.data(withJSONObject: ["frames": [
            ["time_seconds": 0.0, "frequency_hz": 82.4069, "voiced": true, "confidence": 0.9],
        ]])
        try payload.write(to: sidecar)

        let track = try StudyPitchTrack.load(viewer: viewer)

        XCTAssertEqual(track.points, [StudyPitchPoint(time: 0, frequency: 82.4069)])
    }

    func testStudyGraphViewportClampsAndZooms() {
        XCTAssertEqual(StudyGraphViewport.windowStart(currentTime: 0, duration: 30, visibleDuration: 12), -6)
        XCTAssertEqual(StudyGraphViewport.windowStart(currentTime: 30, duration: 30, visibleDuration: 12), 24)
        XCTAssertEqual(StudyGraphViewport.zoomedDuration(2, deltaY: 1), 2)
        XCTAssertEqual(StudyGraphViewport.zoomedDuration(60, deltaY: -1), 60)
        XCTAssertEqual(StudyGraphViewport.zoomedVerticalSpan(200, deltaY: 1), 200)
        XCTAssertEqual(StudyGraphViewport.zoomedVerticalSpan(4_800, deltaY: -1), 4_800)
    }

    func testStudyGraphViewportUsesFollowHysteresis() {
        XCTAssertEqual(StudyGraphViewport.followedCenter(current: 0, pitch: 400, span: 1_000), 0)
        XCTAssertEqual(StudyGraphViewport.followedCenter(current: 0, pitch: 500, span: 1_000), 150)
        XCTAssertEqual(StudyGraphViewport.followedCenter(current: 0, pitch: -500, span: 1_000), -150)
    }

    func testPitchGraphVisibleRangeUsesOnlyTheCurrentWindow() {
        let points = stride(from: 0.0, through: 20.0, by: 0.1)
            .map { PitchGraphPoint(time: $0, frequency: 440) }

        let range = pitchGraphVisibleRange(
            points: points,
            windowStart: 8,
            windowEnd: 12,
            margin: 0.05
        )

        XCTAssertEqual(points[range.lowerBound].time, 8, accuracy: 0.000_001)
        XCTAssertEqual(points[range.upperBound - 1].time, 12, accuracy: 0.000_001)
        XCTAssertLessThan(range.count, points.count / 2)
    }

    func testPitchGraphVisibleRangeKeepsPointsInsideTheGapMargin() {
        let points = [
            PitchGraphPoint(time: 0.94, frequency: 440),
            PitchGraphPoint(time: 0.96, frequency: 440),
            PitchGraphPoint(time: 2.04, frequency: 440),
            PitchGraphPoint(time: 2.06, frequency: 440),
        ]

        let range = pitchGraphVisibleRange(
            points: points,
            windowStart: 1,
            windowEnd: 2,
            margin: 0.05
        )

        XCTAssertEqual(Array(points[range]).map(\.time), [0.96, 2.04])
    }

    func testPitchGraphGeometryMapsStudyCentreAndLiveEdge() {
        XCTAssertEqual(
            PitchGraphGeometry.x(for: 6, windowStart: 0, duration: 12, width: 600),
            300,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PitchGraphGeometry.x(for: 12, windowStart: 0, duration: 12, width: 600),
            600,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PitchGraphGeometry.y(for: 440, verticalCenter: 0, verticalSpan: 1_200, height: 300),
            150,
            accuracy: 0.000_001
        )
    }

    func testPitchGraphTimelineDetectsLoopAndSeekDiscontinuities() {
        XCTAssertFalse(PitchGraphTimeline.isDiscontinuity(previous: 4, current: 4.016, duration: 12))
        XCTAssertTrue(PitchGraphTimeline.isDiscontinuity(previous: 4, current: 0.5, duration: 12))
        XCTAssertTrue(PitchGraphTimeline.isDiscontinuity(previous: 4, current: 11, duration: 12))
    }

    func testPitchGraphRenderStateDoesNotRebuildForPresentationOnlyChanges() {
        let original = graphState(windowStart: 0, windowEnd: 12, playheadTime: 6)
        let shifted = graphState(windowStart: 1, windowEnd: 13, playheadTime: 7)
        let changedPoints = graphState(
            points: [
                PitchGraphPoint(time: 0, frequency: 440),
                PitchGraphPoint(time: 1, frequency: 466.16),
            ],
            windowStart: 1,
            windowEnd: 13,
            playheadTime: 7
        )

        XCTAssertFalse(shifted.requiresPathRebuild(comparedWith: original))
        XCTAssertTrue(changedPoints.requiresPathRebuild(comparedWith: shifted))
    }

    func testPitchGraphRenderStateDoesNotRebuildForVerticalFollowPanning() {
        let original = graphState(windowStart: 0, windowEnd: 12, playheadTime: 6, verticalCenter: 0)
        let panned = graphState(windowStart: 0, windowEnd: 12, playheadTime: 6, verticalCenter: 250)

        // Panning the follow-curve target is handled as a cheap transform in
        // PitchGraphNSView, not a full path rebuild.
        XCTAssertFalse(panned.requiresPathRebuild(comparedWith: original))
    }

    func testPitchGraphRenderStateRebuildsForVerticalZoom() {
        let original = graphState(windowStart: 0, windowEnd: 12, playheadTime: 6, verticalSpan: 1_200)
        let zoomed = graphState(windowStart: 0, windowEnd: 12, playheadTime: 6, verticalSpan: 600)

        // Zooming changes the vertical pixel scale, so it must still rebuild.
        XCTAssertTrue(zoomed.requiresPathRebuild(comparedWith: original))
    }

    @MainActor
    func testNativePitchGraphKeepsOneOpaqueSurfaceAcrossTimeAndResize() throws {
        let view = PitchGraphNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let centred = graphState(windowStart: 0, windowEnd: 12, playheadTime: 6)
        view.apply(centred)
        view.layoutSubtreeIfNeeded()
        let firstRebuildCount = view.pathRebuildCount

        view.apply(graphState(windowStart: 1, windowEnd: 13, playheadTime: 7))
        XCTAssertEqual(view.pathRebuildCount, firstRebuildCount)
        XCTAssertEqual(try XCTUnwrap(view.renderedPlayheadX), view.renderedChartRect.width / 2, accuracy: 0.000_001)

        view.apply(graphState(windowStart: 0, windowEnd: 12, playheadTime: 12))
        XCTAssertEqual(try XCTUnwrap(view.renderedPlayheadX), view.renderedChartRect.width, accuracy: 0.000_001)

        view.frame.size = CGSize(width: 880, height: 440)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.pathRebuildCount, firstRebuildCount)
        XCTAssertGreaterThan(view.renderedChartRect.width, 0)
        XCTAssertGreaterThan(view.renderedChartRect.height, 0)
        XCTAssertTrue(view.isOpaque)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 880,
            pixelsHigh: 440,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        view.layer?.render(in: context.cgContext)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(bitmap.colorAt(x: 440, y: 220)?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }

    func testStudyPlaybackClockKeepsSmallSnapshotCorrectionsMonotonic() {
        var clock = StudyPlaybackClock()
        clock.applySnapshot(time: 0, duration: 30, isPlaying: true, rate: 1, discontinuity: true, at: 0)
        XCTAssertEqual(clock.advance(to: 0.05), 0.05, accuracy: 0.000_001)

        // A typical coarse WebKit snapshot is a few milliseconds behind the
        // local presentation clock. It must slow down, not pull the graph
        // backwards in one frame.
        clock.applySnapshot(time: 0.095, duration: 30, isPlaying: true, rate: 1, discontinuity: false, at: 0.10)
        let afterSnapshot = clock.advance(to: 0.10)
        let nextFrame = clock.advance(to: 0.15)

        XCTAssertEqual(afterSnapshot, 0.10, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(nextFrame, afterSnapshot)
        XCTAssertLessThan(nextFrame, 0.15)
    }

    func testStudyPlaybackClockSpreadsForwardDriftInsteadOfJumping() {
        var clock = StudyPlaybackClock()
        clock.applySnapshot(time: 0, duration: 30, isPlaying: true, rate: 1, discontinuity: true, at: 0)
        _ = clock.advance(to: 0.10)

        clock.applySnapshot(time: 0.14, duration: 30, isPlaying: true, rate: 1, discontinuity: false, at: 0.10)
        XCTAssertEqual(clock.advance(to: 0.10), 0.10, accuracy: 0.000_001)

        let correctedFrame = clock.advance(to: 0.13)
        XCTAssertGreaterThan(correctedFrame, 0.13)
        XCTAssertLessThan(correctedFrame, 0.17)
    }

    func testStudyPlaybackClockImmediatelyAlignsSeekAndLoopDiscontinuities() {
        var clock = StudyPlaybackClock()
        clock.applySnapshot(time: 8, duration: 30, isPlaying: true, rate: 1, discontinuity: true, at: 0)
        _ = clock.advance(to: 0.10)

        clock.applySnapshot(time: 2, duration: 30, isPlaying: true, rate: 1, discontinuity: true, at: 0.10)
        XCTAssertEqual(clock.advance(to: 0.10), 2, accuracy: 0.000_001)
        XCTAssertEqual(clock.advance(to: 0.15), 2.05, accuracy: 0.000_001)
    }

    func testStudyPlaybackClockStopsAndClampsAtMediaBounds() {
        var clock = StudyPlaybackClock()
        clock.applySnapshot(time: 0.95, duration: 1, isPlaying: true, rate: 2, discontinuity: true, at: 0)
        XCTAssertEqual(clock.advance(to: 0.10), 1, accuracy: 0.000_001)

        clock.applySnapshot(time: 0.4, duration: 1, isPlaying: false, rate: 2, discontinuity: false, at: 0.10)
        XCTAssertEqual(clock.advance(to: 1), 0.4, accuracy: 0.000_001)
    }

    func testStudySettingsDraftParsesCompleteValidSnapshot() {
        let values: [String: Any] = [
            "theme": "studio", "scale": "hicaz", "tonic": 9, "countdown": 4,
            "intervals": validStudyIntervals(),
            "graphAppearance": ["pitchHex": "#112233", "noteGuideHex": "#445566"],
        ]

        let draft = try! XCTUnwrap(StudySettingsDraft(values: values))
        XCTAssertEqual(draft.scale, "hicaz")
        XCTAssertEqual(draft.countdown, 4)
        XCTAssertEqual(draft.graphAppearance, GraphAppearance(pitchHex: "#112233", noteGuideHex: "#445566"))
        XCTAssertEqual(draft.intervals["hicaz"], [5, 12, 5, 9, 8, 5, 9])
    }

    func testStudySettingsDraftRejectsInvalidMakamTotal() {
        var intervals = validStudyIntervals()
        intervals["nihavent"]![0] = 8
        let values: [String: Any] = [
            "theme": "focus", "scale": "nihavent", "tonic": 9, "countdown": 0,
            "intervals": intervals,
        ]

        XCTAssertNil(StudySettingsDraft(values: values))
    }

    private func validStudyIntervals() -> [String: [NSNumber]] {
        [
            "nihavent": [9, 4, 9, 9, 4, 9, 9],
            "kurdi": [4, 9, 9, 9, 4, 9, 9],
            "ussak": [8, 5, 9, 9, 4, 9, 9],
            "hicaz": [5, 12, 5, 9, 8, 5, 9],
            "kurdilihicazkar": [4, 9, 9, 9, 4, 9, 9],
            "hicazkar": [5, 12, 5, 9, 5, 12, 5],
        ].mapValues { $0.map(NSNumber.init(value:)) }
    }

    func testGraphAppearanceNormalizesOnlySixDigitHexColors() {
        XCTAssertEqual(GraphAppearance.normalizedHex("#0a84ff"), "#0A84FF")
        XCTAssertNil(GraphAppearance.normalizedHex("0A84FF"))
        XCTAssertNil(GraphAppearance.normalizedHex("#0A84F"))
        XCTAssertNil(GraphAppearance.normalizedHex("#0A84FG"))
    }

    func testGraphAppearanceRepairsInvalidStoredValues() {
        let defaults = UserDefaults(suiteName: "GraphAppearanceTests.invalid")!
        defaults.removePersistentDomain(forName: "GraphAppearanceTests.invalid")
        defaults.set("not-a-colour", forKey: GraphAppearance.pitchColorKey)
        defaults.set("#123456", forKey: GraphAppearance.noteGuideColorKey)

        let appearance = GraphAppearance.stored(defaults: defaults)
        XCTAssertEqual(appearance.pitchHex, GraphAppearance.defaultPitchHex)
        XCTAssertEqual(appearance.noteGuideHex, "#123456")
    }

    func testGraphAppearanceResetRestoresSharedDefaults() {
        let defaults = UserDefaults(suiteName: "GraphAppearanceTests.reset")!
        defaults.removePersistentDomain(forName: "GraphAppearanceTests.reset")
        GraphAppearance(pitchHex: "#112233", noteGuideHex: "#445566").save(to: defaults)

        GraphAppearance.reset(in: defaults)

        XCTAssertEqual(GraphAppearance.stored(defaults: defaults), GraphAppearance())
    }

    func testConcertScalesKeep440HzAsLa() {
        for scale in [LiveScale.major, .minor] {
            XCTAssertEqual(approximateNoteName(for: 440, scale: scale), "La4")
        }
    }

    func testEveryMakamDisplays440HzAsRe() {
        for scale in [LiveScale.nihavent, .kurdi, .ussak, .hicaz, .kurdilihicazkar, .hicazkar] {
            XCTAssertEqual(approximateNoteName(for: 440, scale: scale), "Re4")
        }
    }

    func testSolClarinetNotationIsConsistentAcrossOctaves() {
        for frequency in [220.0, 440.0, 880.0] {
            XCTAssertTrue(approximateNoteName(for: frequency, scale: .nihavent).hasPrefix("Re"))
            XCTAssertTrue(approximateNoteName(for: frequency, scale: .major).hasPrefix("La"))
        }
    }

    func testMajorGuideKeepsConcertTonicFrequency() {
        let guide = pitchGuide(scale: .major, tonic: 9)
        XCTAssertTrue(guide.contains { $0.label == "La" && abs($0.frequency - 440) < 0.001 })
    }

    func testGraphGuideShowsCompactReadableNoteNames() {
        XCTAssertEqual(pitchGraphNoteLabel("La", frequency: 440), "La4")
        XCTAssertEqual(pitchGraphNoteLabel("Si1 ♭1", frequency: 123.47), "Si1 ♭1")
    }

    func testMakamGuideUsesSolClarinetSoundingTonic() {
        let guide = pitchGuide(scale: .nihavent, tonic: 9)
        XCTAssertTrue(guide.contains { $0.label.hasPrefix("La") && abs($0.frequency - 329.6275569) < 0.001 })
        XCTAssertTrue(guide.contains { $0.label.hasPrefix("Re") && abs($0.frequency - 440) < 8 })
    }

    func testCustomMakamIntervalsChangeTheLivePitchGuide() {
        let defaultGuide = pitchGuide(scale: .nihavent, tonic: 9)
        let customGuide = pitchGuide(
            scale: .nihavent,
            tonic: 9,
            intervals: [8, 5, 9, 9, 4, 9, 9]
        )

        XCTAssertNotEqual(defaultGuide[1].frequency, customGuide[1].frequency)
    }

    func testMakamGuideUsesPracticeViewCommaLabels() {
        let guide = pitchGuide(scale: .ussak, tonic: 9)

        XCTAssertTrue(guide.contains { $0.label.hasSuffix("Si1 ♭1") })
    }

    func testCurrentLiveNoteUsesTheSameCommaLabelAsItsGuide() {
        let guide = pitchGuide(scale: .ussak, tonic: 9)
        let target = guide[1]

        XCTAssertEqual(
            nearestPitchGuideNoteName(for: target.frequency, scale: .ussak, tonic: 9),
            target.label
        )
    }

    func testMajorTunerTargetsTheNearestSelectedScaleDegree() {
        let guide = pitchGuide(scale: .major, tonic: 0)
        let do4 = try! XCTUnwrap(guide.first { $0.label == "Do" && abs($0.frequency - 261.625565) < 0.01 })
        let doSharp = do4.frequency * pow(2, 100 / 1_200)
        let target = try! XCTUnwrap(liveTunerTarget(for: doSharp, scale: .major, tonic: 0))

        XCTAssertEqual(target.label, "Do4")
        XCTAssertEqual(target.frequency, do4.frequency, accuracy: 0.001)
        XCTAssertEqual(target.centOffset, 100, accuracy: 0.001)
        XCTAssertFalse(target.usesKoma)
    }

    func testMakamTunerUsesCustomIntervalsAndKomaUnits() {
        let intervals = [8, 5, 9, 9, 4, 9, 9]
        let guide = pitchGuide(scale: .ussak, tonic: 9, intervals: intervals)
        let targetPitch = guide[1]
        let oneKomaSharp = targetPitch.frequency * pow(2, 1 / 53)
        let target = try! XCTUnwrap(liveTunerTarget(
            for: oneKomaSharp,
            scale: .ussak,
            tonic: 9,
            intervals: intervals
        ))

        XCTAssertEqual(target.label, targetPitch.label)
        XCTAssertEqual(target.frequency, targetPitch.frequency, accuracy: 0.001)
        XCTAssertTrue(target.usesKoma)
        XCTAssertEqual(target.komaOffset, 1, accuracy: 0.001)
    }

    func testTunerRejectsInvalidFrequency() {
        XCTAssertNil(liveTunerTarget(for: .nan, scale: .major, tonic: 0))
        XCTAssertNil(liveTunerTarget(for: 0, scale: .ussak, tonic: 9))
    }

    func testTunerRulerKeepsTwoSemitonesOfContextAroundMeasuredPitch() {
        let guide = pitchGuide(scale: .major, tonic: 0)
        let do4 = try! XCTUnwrap(guide.first { $0.label == "Do" && abs($0.frequency - 261.625565) < 0.01 })
        let target = try! XCTUnwrap(liveTunerTarget(
            for: do4.frequency * pow(2, 35 / 1_200),
            scale: .major,
            tonic: 0
        ))
        let ruler = TunerRulerModel(target: target, scale: .major, tonic: 0, intervals: LiveScale.major.intervals.map(Int.init))

        XCTAssertEqual(ruler.visibleCentRange.lowerBound, -165, accuracy: 0.001)
        XCTAssertEqual(ruler.visibleCentRange.upperBound, 235, accuracy: 0.001)
        XCTAssertTrue(ruler.ticks.contains { $0.centOffset == 0 && $0.isMajor })
        XCTAssertTrue(ruler.ticks.contains { $0.centOffset == 200 && $0.isMajor })
    }

    func testTunerRulerShowsEnharmonicChromaticLabels() {
        let target = try! XCTUnwrap(liveTunerTarget(for: 261.625565, scale: .major, tonic: 0))
        let ruler = TunerRulerModel(target: target, scale: .major, tonic: 0, intervals: LiveScale.major.intervals.map(Int.init))

        XCTAssertTrue(ruler.chromaticLabels.contains { $0.centOffset == 100 && $0.label == "Do♯ / Re♭4" })
    }

    func testMakamTunerRulerUsesCustomCommaLabelsWithoutChangingFrequency() {
        let intervals = [8, 5, 9, 9, 4, 9, 9]
        let guide = pitchGuide(scale: .ussak, tonic: 9, intervals: intervals)
        let targetPitch = guide[1]
        let target = try! XCTUnwrap(liveTunerTarget(for: targetPitch.frequency, scale: .ussak, tonic: 9, intervals: intervals))
        let ruler = TunerRulerModel(target: target, scale: .ussak, tonic: 9, intervals: intervals)

        XCTAssertTrue(ruler.makamLabels.contains { $0.label == targetPitch.label && abs($0.centOffset) < 0.001 })
        XCTAssertTrue(ruler.makamLabels.contains { $0.label.contains("♭") || $0.label.contains("♯") })
        XCTAssertEqual(target.frequency, targetPitch.frequency, accuracy: 0.001)
    }

    func testEnharmonicTunerLabelsKeepSolClarinetNotationSeparateFromFrequency() {
        XCTAssertEqual(enharmonicTunerNoteName(for: 440, scale: .major), "La4")
        XCTAssertEqual(enharmonicTunerNoteName(for: 440, scale: .nihavent), "Re4")
    }

    private func graphState(
        points: [PitchGraphPoint] = [
            PitchGraphPoint(time: 0, frequency: 440),
            PitchGraphPoint(time: 1, frequency: 440),
        ],
        windowStart: Double,
        windowEnd: Double,
        playheadTime: Double,
        verticalCenter: Double = 0,
        verticalSpan: Double = 1_200,
        fixedContentRange: ClosedRange<Double>? = nil
    ) -> PitchGraphRenderState {
        PitchGraphRenderState(
            points: points,
            appearance: GraphAppearance(),
            theme: "focus",
            scale: .major,
            tonic: 0,
            makamIntervals: LiveScale.major.intervals.map(Int.init),
            windowStart: windowStart,
            windowEnd: windowEnd,
            verticalCenter: verticalCenter,
            verticalSpan: verticalSpan,
            playheadTime: playheadTime,
            loopA: nil,
            loopB: nil,
            loopEnabled: false,
            timeTickStep: 1,
            maximumContinuousJumpCents: nil,
            includesGapAtLimit: true,
            emptyMessage: "Boş",
            fixedContentRange: fixedContentRange
        )
    }
}
