// KlariVision iPhone/iPad — C ABI v1'in tek Swift sınırı.
// ABI/48 kHz/1536/512 doğrulanır; opaque C++ oturumu güvenli Swift API'sine
// çevrilir. Çıktı vektörü her çağrıda yenilendiğinden sıfırdan okunur ve
// close sonrasında handle tekrar kullanılmaz.

import Foundation

enum iPadPitchABIError: LocalizedError {
    case contract, session, process, output
    /// Carries `kv_pitch_engine_last_error`'s own message verbatim so a
    /// whole-file offline analysis failure is diagnosable instead of
    /// collapsing to one generic string. Never swallowed silently — a
    /// silent fallback to the live/causal path would make the failure
    /// invisible (see StudyModels.swift's iPadOfflinePitchAnalyzer).
    case offlineProcessing(String)
    var errorDescription: String? {
        switch self {
        case .contract: "Pitch çekirdeği mobil ABI v1 sözleşmesiyle uyuşmuyor."
        case .session: "Pitch oturumu oluşturulamadı."
        case .process: "Pitch çekirdeği ses penceresini işleyemedi."
        case .output: "Pitch çekirdeği sonuç karesini okuyamadı."
        case let .offlineProcessing(message): "Yerel çevrimdışı pitch analizi başarısız oldu: \(message)"
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

/// Whole-file offline analysis session for Study/Dinleme mode. Wraps
/// `kv_pitch_engine_create(..., KV_PROFILE_OFFLINE_TRACK)` — the file-only,
/// future-aware `unified_v1` path (`PitchEngineProfile::offline_track` in
/// analysis_engine.hpp) — a different C++ code path from
/// `iPadProductionPitchSession` above, which wraps the causal
/// `kv_production_pitch_session_*` entry points used by Çalma (live) mode.
/// Do not use this type for the live path and do not change
/// `iPadProductionPitchSession` to use it.
///
/// Call pattern deliberately differs from the causal session's per-window
/// `process(...)`: `push` accepts arbitrarily sized PCM chunks (the engine
/// buffers internally — see `PitchEngine::push`/`finish` in
/// analysis_engine.hpp) and no analysis happens until `finish`, which runs
/// the whole-track pass once and returns every frame.
final class iPadOfflineTrackSession {
    private var handle: OpaquePointer?

    init(engine: iPadPitchEngine) throws {
        guard let handle = kv_pitch_engine_create(engine.coreValue, Int32(KV_PROFILE_OFFLINE_TRACK)) else {
            throw iPadPitchABIError.session
        }
        self.handle = handle
    }

    deinit { close() }

    /// Appends one chunk of mono Float32 PCM at `sampleRate`. Chunk
    /// boundaries need not align to any window/hop size.
    func push(samples: UnsafeBufferPointer<Float>, sampleRate: Double) throws {
        guard let handle else { throw iPadPitchABIError.offlineProcessing(lastError()) }
        guard kv_pitch_engine_push(handle, samples.baseAddress, samples.count, sampleRate) == 1 else {
            throw iPadPitchABIError.offlineProcessing(lastError())
        }
    }

    /// Runs the whole-track analysis over everything pushed so far and
    /// returns every produced frame. Not idempotent and not incremental —
    /// this single call is where all of the analysis time is spent (tens of
    /// seconds for a full recording).
    ///
    /// `onProgress` receives a 0...1 fraction as the decode advances. It is
    /// called synchronously from this thread, never concurrently and never
    /// after this call returns, so it must not block; hop it to the main
    /// actor if it drives UI.
    func finish(onProgress: ((Double) -> Void)? = nil) throws -> [iPadPitchFrame] {
        guard let handle else { return [] }
        // The C hook takes a context pointer rather than a Swift closure, so
        // the closure is bridged through an unmanaged box that lives exactly
        // as long as the call below.
        final class Box { let body: (Double) -> Void; init(_ b: @escaping (Double) -> Void) { body = b } }
        var box: Box?
        if let onProgress {
            let boxed = Box(onProgress)
            box = boxed
            kv_pitch_engine_set_progress(handle, { done, total, context in
                guard let context, total > 0 else { return }
                let unboxed = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                unboxed.body(Double(done) / Double(total))
            }, Unmanaged.passUnretained(boxed).toOpaque())
        }
        defer {
            if box != nil { kv_pitch_engine_set_progress(handle, nil, nil) }
        }
        let count = Int(kv_pitch_engine_finish(handle))
        if count == 0 {
            // Ambiguous by itself (a genuinely silent/short clip can also
            // produce zero frames) — kv_pitch_engine_last_error is the only
            // way to tell a real failure apart from a legitimate empty
            // result, since the C ABI leaves its error string empty when
            // finish() did not throw.
            let message = lastError()
            if !message.isEmpty { throw iPadPitchABIError.offlineProcessing(message) }
            return []
        }
        var frames: [iPadPitchFrame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            var frame = kv_pitch_frame()
            guard kv_pitch_engine_frame(handle, index, &frame) == 1 else {
                throw iPadPitchABIError.output
            }
            frames.append(iPadPitchFrame(time: frame.time_seconds, frequency: frame.frequency_hz, confidence: frame.confidence, voiced: frame.voiced != 0))
        }
        return frames
    }

    func close() {
        if let handle { kv_pitch_engine_destroy(handle); self.handle = nil }
    }

    private func lastError() -> String {
        guard let handle else { return "invalid engine" }
        return String(cString: kv_pitch_engine_last_error(handle))
    }
}
