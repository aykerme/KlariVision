#include "klarivision/core/analysis_engine_c.h"
#include "klarivision/core/analysis_engine.hpp"
#include "klarivision/core/pitch_engine_v2_session.hpp"

#include <exception>
#include <cmath>
#include <string>
#include <vector>

struct kv_pitch_engine {
    klarivision::core::PitchEngine engine;
    std::vector<klarivision::core::EngineFrame> frames;
    std::string error;
    kv_pitch_engine(klarivision::core::PitchEngineId id, klarivision::core::PitchEngineProfile profile) : engine(id, profile) {}
};
struct kv_v2_session {
    klarivision::core::v2::PitchEngineV2Session engine;
    std::vector<klarivision::core::v2::PublishedPitchFrame> frames;
    std::string error;
    kv_v2_session(double minimum_rms, size_t fixed_lag_frames)
        : engine(minimum_rms, fixed_lag_frames) {}
};
struct kv_production_pitch_session {
    klarivision::core::ProductionPitchSession engine;
    std::vector<klarivision::core::EngineFrame> frames;
    std::string error;
    kv_production_pitch_session(
        const klarivision::core::PitchEngineId id,
        const double minimum_rms
    ) : engine(id, klarivision::core::PitchEngineConfig{.minimum_rms = minimum_rms}) {}
};
extern "C" {
int kv_pitch_contract_get_v1(kv_pitch_contract_v1 *out_contract) {
    if (!out_contract) return 0;
    *out_contract = kv_pitch_contract_v1{
        .abi_version = KV_PITCH_C_ABI_V1,
        .capabilities = KV_CAP_ENGINE_YIN_V1 | KV_CAP_ENGINE_V2 |
            KV_CAP_ENGINE_VPM_LIKE | KV_CAP_PROFILE_REALTIME |
            KV_CAP_PROFILE_OFFLINE_TRACK_V1 | KV_CAP_SOURCE_TIMESTAMPS |
            KV_CAP_V2_FIXED_LAG_FINISH | KV_CAP_ENGINE_HAPT_V1,
        .sample_rate_hz = 48'000,
        .window_size = 1'536,
        .hop_size = 512,
        .v2_fixed_lag_frames = 5,
        .default_minimum_rms = 0.015,
    };
    return 1;
}
kv_pitch_engine *kv_pitch_engine_create(int id, int profile) {
    if (id < KV_ENGINE_YIN_V1 || id > KV_ENGINE_HAPT_V1 || profile < KV_PROFILE_REALTIME || profile > KV_PROFILE_OFFLINE_TRACK) return nullptr;
    return new kv_pitch_engine(static_cast<klarivision::core::PitchEngineId>(id), static_cast<klarivision::core::PitchEngineProfile>(profile));
}
void kv_pitch_engine_destroy(kv_pitch_engine *engine) { delete engine; }
int kv_pitch_engine_push(kv_pitch_engine *engine, const float *samples, size_t count, double rate) {
    if (!engine || (!samples && count)) return 0;
    try { engine->engine.push({samples, count}, rate); return 1; } catch (const std::exception& error) { engine->error = error.what(); return 0; }
}
size_t kv_pitch_engine_finish(kv_pitch_engine *engine) { if (!engine) return 0; try { engine->frames = engine->engine.finish(); return engine->frames.size(); } catch (const std::exception& error) { engine->error = error.what(); return 0; } }
int kv_pitch_engine_frame(const kv_pitch_engine *engine, size_t index, kv_pitch_frame *out) { if (!engine || !out || index >= engine->frames.size()) return 0; const auto& f = engine->frames[index]; out->time_seconds=f.time_seconds; out->frequency_hz=f.frequency_hz.value_or(0); out->confidence=f.confidence; out->voiced=f.frequency_hz.has_value(); return 1; }
const char *kv_pitch_engine_last_error(const kv_pitch_engine *engine) { return engine ? engine->error.c_str() : "invalid engine"; }
kv_production_pitch_session *kv_production_pitch_session_create(
    const int id,
    const double minimum_rms
) {
    if (id < KV_ENGINE_YIN_V1 || id > KV_ENGINE_HAPT_V1 ||
        !std::isfinite(minimum_rms) || minimum_rms < 0) return nullptr;
    try {
        return new kv_production_pitch_session(
            static_cast<klarivision::core::PitchEngineId>(id), minimum_rms
        );
    } catch (...) { return nullptr; }
}
void kv_production_pitch_session_reset(kv_production_pitch_session *session) {
    if (!session) return;
    session->engine.reset(); session->frames.clear(); session->error.clear();
}
int kv_production_pitch_session_set_minimum_rms(
    kv_production_pitch_session *session,
    const double minimum_rms
) {
    if (!session || !std::isfinite(minimum_rms) || minimum_rms < 0) return 0;
    session->engine.set_minimum_rms(minimum_rms); return 1;
}
void kv_production_pitch_session_destroy(kv_production_pitch_session *session) { delete session; }
int kv_production_pitch_session_process_frame(
    kv_production_pitch_session *session,
    const float *samples,
    const size_t count,
    const double rate,
    const double time
) {
    if (!session || (!samples && count) || !std::isfinite(rate) || rate <= 0 ||
        !std::isfinite(time)) return 0;
    try {
        session->frames = session->engine.process_frame({samples, count}, rate, time);
        session->error.clear(); return 1;
    } catch (const std::exception& error) {
        session->error = error.what(); session->frames.clear(); return 0;
    }
}
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
kv_v2_session *kv_v2_session_create(double minimum_rms, size_t fixed_lag_frames) {
    if (!std::isfinite(minimum_rms) || minimum_rms < 0 || fixed_lag_frames == 0) return nullptr;
    try { return new kv_v2_session(minimum_rms, fixed_lag_frames); } catch (...) { return nullptr; }
}
void kv_v2_session_reset(kv_v2_session *session) {
    if (!session) return;
    session->engine.reset(); session->frames.clear(); session->error.clear();
}
int kv_v2_session_set_minimum_rms(kv_v2_session *session, double minimum_rms) {
    if (!session || !std::isfinite(minimum_rms) || minimum_rms < 0) return 0;
    session->engine.set_minimum_rms(minimum_rms); return 1;
}
void kv_v2_session_destroy(kv_v2_session *session) { delete session; }
int kv_v2_session_process_frame(kv_v2_session *session, const float *samples, size_t count, double rate, double time) {
    if (!session || (!samples && count) || !std::isfinite(rate) || rate <= 0 || !std::isfinite(time)) return 0;
    try {
        session->frames = session->engine.process_frame({samples, count}, rate, time);
        session->error.clear();
        return 1;
    } catch (const std::exception& error) { session->error = error.what(); session->frames.clear(); return 0; }
}
size_t kv_v2_session_finish(kv_v2_session *session) {
    if (!session) return 0;
    try {
        session->frames = session->engine.finish();
        session->error.clear();
        return session->frames.size();
    } catch (const std::exception& error) {
        session->error = error.what(); session->frames.clear(); return 0;
    }
}
size_t kv_v2_session_output_count(const kv_v2_session *session) { return session ? session->frames.size() : 0; }
int kv_v2_session_output_frame(const kv_v2_session *session, size_t index, kv_pitch_frame *out) {
    if (!session || !out || index >= session->frames.size()) return 0;
    const auto& frame = session->frames[index];
    out->time_seconds = frame.time_seconds; out->frequency_hz = frame.frequency_hz;
    out->confidence = frame.confidence; out->voiced = 1; return 1;
}
const char *kv_v2_session_last_error(const kv_v2_session *session) { return session ? session->error.c_str() : "invalid session"; }
}
