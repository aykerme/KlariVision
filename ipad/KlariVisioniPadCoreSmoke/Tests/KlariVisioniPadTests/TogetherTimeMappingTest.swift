@testable import KlariVisioniPad
import XCTest

final class TogetherTimeMappingTest: XCTestCase {
    // Tolerans: yaklaşık hesaplamalar için floatıng point hataları.
    private let tolerance = 1e-9

    func testWindowCenterSecondsIsCorrect() {
        // Pencere merkezi: (1536 / 2) / 48000 = 768 / 48000 ≈ 0.016 saniye
        let expected = (1536.0 / 2.0) / 48000.0
        XCTAssertEqual(expected, iPadTogetherTimeMapping.windowCenterSeconds, accuracy: tolerance)
    }

    func testWindowCenterSecondsIs16Ms() {
        // ~16,0 ms olmalı
        let msValue = iPadTogetherTimeMapping.windowCenterSeconds * 1000
        XCTAssertEqual(16.0, msValue, accuracy: 0.01)
    }

    func testFixedLatencyCalculation() {
        // Sabit gecikme = pencere merkezi + giriş gecikmesi
        let inputLatency = 0.010  // 10 ms
        let result = iPadTogetherTimeMapping.fixedLatency(inputLatencySeconds: inputLatency)
        let expected = iPadTogetherTimeMapping.windowCenterSeconds + inputLatency
        XCTAssertEqual(expected, result, accuracy: tolerance)
    }

    func testFixedLatencyWithZeroInputLatency() {
        let result = iPadTogetherTimeMapping.fixedLatency(inputLatencySeconds: 0.0)
        XCTAssertEqual(iPadTogetherTimeMapping.windowCenterSeconds, result, accuracy: tolerance)
    }

    func testMapFrameToMediaTimeFrameJustCreated() {
        // wallNow == frameTime → kare az önce oluşturuldu
        // mediaTime = clockNow − 0 − fixedLatency − userAlignment
        let clockNow = 10.0
        let wallNow = 1000.0
        let frameTime = 1000.0  // Aynı
        let rate = 1.0
        let userAlignment = 0.0
        let fixedLatency = 0.026  // ~26 ms toplam

        let result = iPadTogetherTimeMapping.mapFrameToMediaTime(
            clockNow: clockNow,
            wallNow: wallNow,
            frameTime: frameTime,
            rate: rate,
            userAlignmentSeconds: userAlignment,
            fixedLatency: fixedLatency
        )
        let expected = clockNow - fixedLatency
        XCTAssertEqual(expected, result, accuracy: tolerance)
    }

    func testMapFrameToMediaTimeWithUserAlignment() {
        // Kullanıcı kaydırması uygulanmış
        let clockNow = 10.0
        let wallNow = 1000.0
        let frameTime = 1000.0
        let rate = 1.0
        let userAlignment = 0.050  // 50 ms = 0.050 saniye
        let fixedLatency = 0.026

        let result = iPadTogetherTimeMapping.mapFrameToMediaTime(
            clockNow: clockNow,
            wallNow: wallNow,
            frameTime: frameTime,
            rate: rate,
            userAlignmentSeconds: userAlignment,
            fixedLatency: fixedLatency
        )
        let expected = clockNow - fixedLatency - userAlignment
        XCTAssertEqual(expected, result, accuracy: tolerance)
    }

    func testMapFrameToMediaTimeWithRate() {
        // Oynatma hızı 0.5 (yarı hız)
        let clockNow = 10.0
        let wallNow = 1000.0
        let frameTime = 999.0  // 1 saniye önce
        let rate = 0.5
        let userAlignment = 0.0
        let fixedLatency = 0.026

        let result = iPadTogetherTimeMapping.mapFrameToMediaTime(
            clockNow: clockNow,
            wallNow: wallNow,
            frameTime: frameTime,
            rate: rate,
            userAlignmentSeconds: userAlignment,
            fixedLatency: fixedLatency
        )
        // (wallNow - frameTime) * rate = (1000 - 999) * 0.5 = 0.5
        let expected = clockNow - 0.5 - fixedLatency
        XCTAssertEqual(expected, result, accuracy: tolerance)
    }

    func testMapFrameToMediaTimeFullFormula() {
        // Tam formülü test et
        let clockNow = 100.0
        let wallNow = 5000.0
        let frameTime = 4995.0  // 5 saniye önce
        let rate = 1.0
        let userAlignment = 0.100  // 100 ms = 0.1 saniye
        let fixedLatency = 0.026

        let result = iPadTogetherTimeMapping.mapFrameToMediaTime(
            clockNow: clockNow,
            wallNow: wallNow,
            frameTime: frameTime,
            rate: rate,
            userAlignmentSeconds: userAlignment,
            fixedLatency: fixedLatency
        )
        // clockNow - (5000 - 4995) * 1.0 - 0.026 - 0.1 = 100 - 5 - 0.026 - 0.1 = 94.874
        let expected = clockNow - 5.0 - fixedLatency - userAlignment
        XCTAssertEqual(expected, result, accuracy: tolerance)
    }

    func testClampMicAlignmentZero() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(0.0)
        XCTAssertEqual(0.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentWithinBounds() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(50.0)
        XCTAssertEqual(50.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentNegativeWithinBounds() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(-75.0)
        XCTAssertEqual(-75.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentBelowMin() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(-250.0)
        XCTAssertEqual(-200.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentAboveMax() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(250.0)
        XCTAssertEqual(200.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentAtMin() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(-200.0)
        XCTAssertEqual(-200.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentAtMax() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(200.0)
        XCTAssertEqual(200.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentExtremelyNegative() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(-1000.0)
        XCTAssertEqual(-200.0, result, accuracy: tolerance)
    }

    func testClampMicAlignmentExtremelyPositive() {
        let result = iPadTogetherTimeMapping.clampMicAlignmentMs(1000.0)
        XCTAssertEqual(200.0, result, accuracy: tolerance)
    }

    func testAppStateClampMicAlignmentMatches() {
        // iPadAppState.clampedMicAlignmentMs() aynı sonuç vermelidir
        XCTAssertEqual(iPadAppState.clampedMicAlignmentMs(-250.0), iPadTogetherTimeMapping.clampMicAlignmentMs(-250.0))
        XCTAssertEqual(iPadAppState.clampedMicAlignmentMs(250.0), iPadTogetherTimeMapping.clampMicAlignmentMs(250.0))
        XCTAssertEqual(iPadAppState.clampedMicAlignmentMs(0.0), iPadTogetherTimeMapping.clampMicAlignmentMs(0.0))
    }
}
