// KlariVision iPhone/iPad — C ABI v1'in tek Swift sınırı.
// ABI/48 kHz/1536/512 doğrulanır; opaque C++ oturumu güvenli Swift API'sine
// çevrilir. Çıktı vektörü her çağrıda yenilendiğinden sıfırdan okunur ve
// close sonrasında handle tekrar kullanılmaz.

import Foundation

enum iPadPitchABIError: LocalizedError {
    case contract, session, process, output
    var errorDescription: String? {
        switch self {
        case .contract: "Pitch çekirdeği mobil ABI v1 sözleşmesiyle uyuşmuyor."
        case .session: "Pitch oturumu oluşturulamadı."
        case .process: "Pitch çekirdeği ses penceresini işleyemedi."
        case .output: "Pitch çekirdeği sonuç karesini okuyamadı."
        }
    }
}

struct iPadPitchABIAdapter {
    static func contract() throws -> kv_pitch_contract_v1 {
        var value = kv_pitch_contract_v1()
        guard kv_pitch_contract_get_v1(&value) == 1,
              value.abi_version == KV_PITCH_C_ABI_V1,
              value.sample_rate_hz == 48_000,
              value.window_size == 1_536,
              value.hop_size == 512
        else { throw iPadPitchABIError.contract }
        return value
    }

    /// unified_v1's own decision latency, in hops. Deliberately separate from
    /// `contract().v2_fixed_lag_frames`, which the struct above hard-asserts
    /// as a stable field describing pitch_engine_v2 alone and must not be
    /// mutated for a new engine; see kv_unified_lag_frames() in
    /// analysis_engine_c.h.
    static func unifiedLagFrames() -> Int {
        Int(kv_unified_lag_frames())
    }
}

final class iPadProductionPitchSession {
    private var handle: OpaquePointer?

    init(engine: iPadPitchEngine, minimumRMS: Double? = nil) throws {
        let contract = try iPadPitchABIAdapter.contract()
        let rms = minimumRMS ?? contract.default_minimum_rms
        guard rms.isFinite, rms >= 0,
              let handle = kv_production_pitch_session_create(engine.coreValue, rms) else {
            throw iPadPitchABIError.session
        }
        self.handle = handle
    }

    func setMinimumRMS(_ value: Double) throws {
        guard value.isFinite, value >= 0, let handle,
              kv_production_pitch_session_set_minimum_rms(handle, value) == 1
        else { throw iPadPitchABIError.session }
    }

    deinit { close() }

    func process(samples: UnsafeBufferPointer<Float>, sourceTime: Double) throws -> [iPadPitchFrame] {
        guard samples.count == 1_536,
              let handle,
              kv_production_pitch_session_process_frame(handle, samples.baseAddress, samples.count, 48_000, sourceTime) == 1
        else { throw iPadPitchABIError.process }
        return try drainCurrentOutputs()
    }

    func finish() throws -> [iPadPitchFrame] {
        guard let handle else { return [] }
        _ = kv_production_pitch_session_finish(handle)
        return try drainCurrentOutputs()
    }

    func close() {
        if let handle { kv_production_pitch_session_destroy(handle); self.handle = nil }
    }

    private func drainCurrentOutputs() throws -> [iPadPitchFrame] {
        guard let handle else { return [] }
        // The C ABI replaces its output vector on every process/finish call.
        // Each result set therefore starts at index zero; no global cursor.
        return try (0..<Int(kv_production_pitch_session_output_count(handle))).map { index in
            var frame = kv_pitch_frame()
            guard kv_production_pitch_session_output_frame(handle, index, &frame) == 1 else {
                throw iPadPitchABIError.output
            }
            return iPadPitchFrame(time: frame.time_seconds, frequency: frame.frequency_hz, confidence: frame.confidence, voiced: frame.voiced != 0)
        }
    }
}
