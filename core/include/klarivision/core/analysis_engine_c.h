#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kv_pitch_engine kv_pitch_engine;
typedef struct kv_v2_session kv_v2_session;
typedef struct kv_production_pitch_session kv_production_pitch_session;
typedef struct {
    double time_seconds;
    double frequency_hz;
    double confidence;
    int voiced;
} kv_pitch_frame;

/// Stable C ABI contract. New fields may only be appended in a later ABI
/// version; callers must reject a version other than KV_PITCH_C_ABI_V1.
typedef struct {
    unsigned int abi_version;
    unsigned int capabilities;
    unsigned int sample_rate_hz;
    size_t window_size;
    size_t hop_size;
    size_t v2_fixed_lag_frames;
    double default_minimum_rms;
} kv_pitch_contract_v1;

enum { KV_ENGINE_YIN_V1 = 0, KV_ENGINE_V2 = 1, KV_ENGINE_VPM_LIKE = 2, KV_ENGINE_HAPT_V1 = 3 };
enum { KV_PROFILE_REALTIME = 0, KV_PROFILE_OFFLINE_TRACK = 1 };
enum { KV_PITCH_C_ABI_V1 = 1 };
enum {
    KV_CAP_ENGINE_YIN_V1 = 1u << 0,
    KV_CAP_ENGINE_V2 = 1u << 1,
    KV_CAP_ENGINE_VPM_LIKE = 1u << 2,
    KV_CAP_PROFILE_REALTIME = 1u << 3,
    KV_CAP_PROFILE_OFFLINE_TRACK_V1 = 1u << 4,
    KV_CAP_SOURCE_TIMESTAMPS = 1u << 5,
    KV_CAP_V2_FIXED_LAG_FINISH = 1u << 6,
    KV_CAP_ENGINE_HAPT_V1 = 1u << 7,
};

/// Returns 1 on success and 0 for an invalid output pointer. Ownership remains
/// with the caller and no heap allocation occurs. PCM passed to process
/// functions is mono Float32 at sample_rate_hz; frame timestamps describe the
/// centre of that source window, not publication latency.
int kv_pitch_contract_get_v1(kv_pitch_contract_v1 *out_contract);

kv_pitch_engine *kv_pitch_engine_create(int engine, int profile);
void kv_pitch_engine_destroy(kv_pitch_engine *engine);
int kv_pitch_engine_push(kv_pitch_engine *engine, const float *samples, size_t count, double sample_rate);
size_t kv_pitch_engine_finish(kv_pitch_engine *engine);
int kv_pitch_engine_frame(const kv_pitch_engine *engine, size_t index, kv_pitch_frame *out_frame);
const char *kv_pitch_engine_last_error(const kv_pitch_engine *engine);

/// Canonical live/file causal session for YIN v1, V2 and VPM-like. Each call
/// consumes one complete analysis window centred on source_time_seconds and
/// returns 1 on success or 0 on failure. Its output vector is replaced on every
/// successful process or finish call; read output indices from zero each time.
kv_production_pitch_session *kv_production_pitch_session_create(
    int engine,
    double minimum_rms
);
void kv_production_pitch_session_reset(kv_production_pitch_session *session);
int kv_production_pitch_session_set_minimum_rms(
    kv_production_pitch_session *session,
    double minimum_rms
);
void kv_production_pitch_session_destroy(kv_production_pitch_session *session);
int kv_production_pitch_session_process_frame(
    kv_production_pitch_session *session,
    const float *samples,
    size_t count,
    double sample_rate,
    double source_time_seconds
);
size_t kv_production_pitch_session_finish(kv_production_pitch_session *session);
size_t kv_production_pitch_session_output_count(
    const kv_production_pitch_session *session
);
/// Reads one frame from the current process/finish output vector; returns 1 on
/// success and 0 for an invalid session, index, or output pointer.
int kv_production_pitch_session_output_frame(
    const kv_production_pitch_session *session,
    size_t index,
    kv_pitch_frame *out_frame
);
const char *kv_production_pitch_session_last_error(
    const kv_production_pitch_session *session
);

/// Stateful live V2 boundary. `source_time_seconds` is the centre of the
/// supplied analysis window. One call can expose bridged frames plus the
/// current resolved frame through output_count/output_frame.
kv_v2_session *kv_v2_session_create(double minimum_rms, size_t fixed_lag_frames);
void kv_v2_session_reset(kv_v2_session *session);
int kv_v2_session_set_minimum_rms(kv_v2_session *session, double minimum_rms);
void kv_v2_session_destroy(kv_v2_session *session);
int kv_v2_session_process_frame(
    kv_v2_session *session,
    const float *samples,
    size_t count,
    double sample_rate,
    double source_time_seconds
);
size_t kv_v2_session_finish(kv_v2_session *session);
size_t kv_v2_session_output_count(const kv_v2_session *session);
int kv_v2_session_output_frame(
    const kv_v2_session *session,
    size_t index,
    kv_pitch_frame *out_frame
);
const char *kv_v2_session_last_error(const kv_v2_session *session);

#ifdef __cplusplus
}
#endif
