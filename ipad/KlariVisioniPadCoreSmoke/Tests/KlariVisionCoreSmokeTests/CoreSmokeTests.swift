import Foundation
import XCTest

final class CoreSmokeTests: XCTestCase {
    func testContractAndEveryEngineLifecycle() {
        var contract = kv_pitch_contract_v1()
        XCTAssertEqual(kv_pitch_contract_get_v1(&contract), 1)
        XCTAssertEqual(contract.abi_version, UInt32(KV_PITCH_C_ABI_V1))
        XCTAssertEqual(contract.sample_rate_hz, 48_000)
        XCTAssertEqual(contract.window_size, 1_536)
        XCTAssertEqual(contract.hop_size, 512)
        XCTAssertEqual(contract.v2_fixed_lag_frames, 5)
        XCTAssertNotEqual(contract.capabilities & UInt32(KV_CAP_ENGINE_YIN_V1), 0)
        XCTAssertNotEqual(contract.capabilities & UInt32(KV_CAP_ENGINE_V2), 0)
        XCTAssertNotEqual(contract.capabilities & UInt32(KV_CAP_ENGINE_VPM_LIKE), 0)
        XCTAssertNotEqual(contract.capabilities & UInt32(KV_CAP_ENGINE_HAPT_V1), 0)

        let sampleRate = 48_000.0
        let windowSize = Int(contract.window_size)
        let hopSize = Int(contract.hop_size)
        for engine in [KV_ENGINE_YIN_V1, KV_ENGINE_V2, KV_ENGINE_VPM_LIKE, KV_ENGINE_HAPT_V1] {
            guard let session = kv_production_pitch_session_create(Int32(engine), contract.default_minimum_rms) else {
                return XCTFail("C ABI oturumu oluşturulamadı: \(engine)")
            }
            defer { kv_production_pitch_session_destroy(session) }

            for frame in 0..<12 {
                let samples = (0..<windowSize).map { index in
                    Float(0.2 * sin(2 * .pi * 440 * Double(frame * hopSize + index) / sampleRate))
                }
                let sourceTime = Double(frame * hopSize + windowSize / 2) / sampleRate
                let result = samples.withUnsafeBufferPointer {
                    kv_production_pitch_session_process_frame(session, $0.baseAddress, $0.count, sampleRate, sourceTime)
                }
                XCTAssertEqual(result, 1, "C ABI kareyi işleyemedi: \(engine)")
            }
            XCTAssertGreaterThan(kv_production_pitch_session_output_count(session), 0)
            _ = kv_production_pitch_session_finish(session)
            XCTAssertEqual(kv_production_pitch_session_finish(session), 0)
            kv_production_pitch_session_reset(session)
            XCTAssertEqual(kv_production_pitch_session_output_count(session), 0)
        }
    }
}
