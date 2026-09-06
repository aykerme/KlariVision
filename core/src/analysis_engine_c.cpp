#include "klarivision/core/analysis_engine_c.h"

#include "klarivision/core/unified_pitch_constants.hpp"
#include "klarivision/core/analysis_engine.hpp"

#include <exception>
#include <cmath>
#include <string>
#include <vector>

// This file is the C ABI bridge (opaque-handle wrappers) that lets the
// Swift apps (and any other C-compatible caller) drive the C++ pitch
// engine without exposing C++ types across the boundary. It contains no
// pitch-tracking logic of its own -- every function here just forwards to
// the real algorithms implemented in analysis_engine.cpp /
// unified_pitch_session.cpp and translates results into the plain-C
// `kv_pitch_frame` struct declared in analysis_engine_c.h. Each opaque
// struct below owns one C++ engine/session object plus a small cache of its
// most recent output frames (so index-based getters can be O(1) without a
// second engine call) and a last-error string for the C caller to inspect.
struct kv_pitch_engine {
    klarivision::core::PitchEngine engine;                       // the real offline/causal engine wrapper
    std::vector<klarivision::core::EngineFrame> frames;           // cached result of the last finish() call
    std::string error;                                            // last exception message, if any
    kv_pitch_engine(klarivision::core::PitchEngineId id, klarivision::core::PitchEngineProfile profile) : engine(id, profile) {}
};
struct kv_production_pitch_session {
    klarivision::core::ProductionPitchSession engine;              // the real unified_v1 session
    std::vector<klarivision::core::EngineFrame> frames;             // cached result of the last process_frame/finish call
    std::string error;
    kv_production_pitch_session(
        const klarivision::core::PitchEngineId id,
        const double minimum_rms
    ) : engine(id, klarivision::core::PitchEngineConfig{.minimum_rms = minimum_rms}) {}
};
extern "C" {
// Reports the ABI/feature contract this build implements, so a Swift
// caller can check compatibility and read the engines' default analysis
// parameters (sample rate, window/hop size, etc.) without hard-coding them.
int kv_pitch_contract_get_v1(kv_pitch_contract_v1 *out_contract) {
    if (!out_contract) return 0;  // null output pointer: nothing to fill in
    *out_contract = kv_pitch_contract_v1{
        .abi_version = KV_PITCH_C_ABI_V1,
        // Bitmask of every engine/profile/feature this build supports. The
        // four removed engines' bits (YIN_V1, V2, VPM_LIKE, HAPT_V1) are no
        // longer set; their positions stay reserved in the header so a caller
        // testing for one reads absent, not renumbered. KV_CAP_V2_FIXED_LAG_
        // FINISH goes with v2 for the same reason -- the unified engine's own
        // fixed-lag flush is reported through kv_unified_lag_frames().
        .capabilities = KV_CAP_PROFILE_REALTIME |
            KV_CAP_PROFILE_OFFLINE_TRACK_V1 | KV_CAP_SOURCE_TIMESTAMPS |
            KV_CAP_ENGINE_UNIFIED_V1,
        .sample_rate_hz = 48'000,
        .window_size = 1'536,
        .hop_size = 512,
        .v2_fixed_lag_frames = 5,
        .default_minimum_rms = 0.015,
    };
    return 1;
}
size_t kv_unified_lag_frames(void) {
    return klarivision::core::unified::kDefaultLagFrames;
}
// Allocates an offline/causal PitchEngine wrapper for the given engine id
// and analysis profile.
kv_pitch_engine *kv_pitch_engine_create(int id, int profile) {
    // Reserved ids 0-3 name removed engines and are rejected here rather than
    // resolved to the survivor: substituting a different engine's output for
    // the one that was asked for is the failure mode nothing downstream can see.
    if (id != KV_ENGINE_UNIFIED_V1 || profile < KV_PROFILE_REALTIME || profile > KV_PROFILE_OFFLINE_TRACK) return nullptr;
    try {
        return new kv_pitch_engine(static_cast<klarivision::core::PitchEngineId>(id), static_cast<klarivision::core::PitchEngineProfile>(profile));
    } catch (...) { return nullptr; }
}
void kv_pitch_engine_destroy(kv_pitch_engine *engine) { delete engine; }
// Appends a block of mono samples to the engine's internal buffer.
int kv_pitch_engine_push(kv_pitch_engine *engine, const float *samples, size_t count, double rate) {
    if (!engine || (!samples && count)) return 0;  // null engine, or a null buffer claiming non-zero samples
    try { engine->engine.push({samples, count}, rate); return 1; } catch (const std::exception& error) { engine->error = error.what(); return 0; }
}
// Runs the full pitch-tracking analysis over everything pushed so far and
// caches the resulting frames for kv_pitch_engine_frame to read.
size_t kv_pitch_engine_finish(kv_pitch_engine *engine) { if (!engine) return 0; try { engine->frames = engine->engine.finish(); return engine->frames.size(); } catch (const std::exception& error) { engine->error = error.what(); return 0; } }
// Reads one cached output frame by index into the plain-C output struct.
int kv_pitch_engine_frame(const kv_pitch_engine *engine, size_t index, kv_pitch_frame *out) { if (!engine || !out || index >= engine->frames.size()) return 0; const auto& f = engine->frames[index]; out->time_seconds=f.time_seconds; out->frequency_hz=f.frequency_hz.value_or(0); out->confidence=f.confidence; out->voiced=f.frequency_hz.has_value(); return 1; }
const char *kv_pitch_engine_last_error(const kv_pitch_engine *engine) { return engine ? engine->error.c_str() : "invalid engine"; }
// Allocates a streaming, causal ProductionPitchSession (the engine used by
// the live/study apps) for the given engine id and starting RMS floor.
kv_production_pitch_session *kv_production_pitch_session_create(
    const int id,
    const double minimum_rms
) {
    // See kv_pitch_engine_create: reserved ids 0-3 are refused, not remapped.
    if (id != KV_ENGINE_UNIFIED_V1 ||
        !std::isfinite(minimum_rms) || minimum_rms < 0) return nullptr;  // reject a removed engine id or a nonsensical RMS floor
    try {
        return new kv_production_pitch_session(
            static_cast<klarivision::core::PitchEngineId>(id), minimum_rms
        );
    } catch (...) { return nullptr; }
}
void kv_production_pitch_session_reset(kv_production_pitch_session *session) {
    if (!session) return;
    session->engine.reset(); session->frames.clear(); session->error.clear();  // rebuild the C++ session and clear the cached output/error
}
int kv_production_pitch_session_set_minimum_rms(
    kv_production_pitch_session *session,
    const double minimum_rms
) {
    if (!session || !std::isfinite(minimum_rms) || minimum_rms < 0) return 0;
    session->engine.set_minimum_rms(minimum_rms); return 1;
}
void kv_production_pitch_session_destroy(kv_production_pitch_session *session) { delete session; }
// Feeds one analysis window into the session and caches whatever frames it
// publishes this call.
int kv_production_pitch_session_process_frame(
    kv_production_pitch_session *session,
    const float *samples,
    const size_t count,
    const double rate,
    const double time
) {
    if (!session || (!samples && count) || !std::isfinite(rate) || rate <= 0 ||
        !std::isfinite(time)) return 0;  // reject any invalid input before touching the C++ engine
    try {
        session->frames = session->engine.process_frame({samples, count}, rate, time);
        session->error.clear(); return 1;
    } catch (const std::exception& error) {
        session->error = error.what(); session->frames.clear(); return 0;
    }
}
// Flushes the end-of-stream frames still held by the unified engine's
// fixed-lag window and caches the result.
size_t kv_production_pitch_session_finish(kv_production_pitch_session *session) {
    if (!session) return 0;
    try {
        session->frames = session->engine.finish();
        session->error.clear();
        return session->frames.size();
    } catch (const std::exception& error) {
        session->error = error.what(); session->frames.clear(); return 0;
    }
}
size_t kv_production_pitch_session_output_count(
    const kv_production_pitch_session *session
) { return session ? session->frames.size() : 0; }
int kv_production_pitch_session_output_frame(
    const kv_production_pitch_session *session,
    const size_t index,
    kv_pitch_frame *out
) {
    if (!session || !out || index >= session->frames.size()) return 0;
    const auto& frame = session->frames[index];
    out->time_seconds = frame.time_seconds;
    out->frequency_hz = frame.frequency_hz.value_or(0);
    out->confidence = frame.confidence;
    out->voiced = frame.frequency_hz.has_value();
    return 1;
}
const char *kv_production_pitch_session_last_error(
    const kv_production_pitch_session *session
) { return session ? session->error.c_str() : "invalid session"; }
// --- Removed v2 session (D-039), retained as failing stubs ---------------
// pitch_engine_v2 is gone. These symbols stay exported because the v1 ABI's
// symbol set is a frozen contract: a caller built against v1 must still link
// and must fail visibly rather than hit an unresolved symbol. There is no
// kv_v2_session type any more, so create can only ever return NULL and every
// other entry point is a no-op on a handle that cannot exist.
kv_v2_session *kv_v2_session_create(double, size_t) { return nullptr; }
void kv_v2_session_reset(kv_v2_session *) {}
int kv_v2_session_set_minimum_rms(kv_v2_session *, double) { return 0; }
void kv_v2_session_destroy(kv_v2_session *) {}
int kv_v2_session_process_frame(kv_v2_session *, const float *, size_t, double, double) { return 0; }
size_t kv_v2_session_finish(kv_v2_session *) { return 0; }
size_t kv_v2_session_output_count(const kv_v2_session *) { return 0; }
int kv_v2_session_output_frame(const kv_v2_session *, size_t, kv_pitch_frame *) { return 0; }
const char *kv_v2_session_last_error(const kv_v2_session *) {
    return "pitch_engine_v2 was removed; use the production pitch session";
}
}
