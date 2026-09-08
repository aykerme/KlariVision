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
    /// Reserved. Historically pitch_engine_v2's fixed decision lag. That
    /// engine was removed (D-039) but the field cannot be: this struct's
    /// layout is the persisted v1 contract and callers hard-assert its value.
    /// It keeps reporting 5 and describes nothing this build runs. The
    /// unified engine's lag is kv_unified_lag_frames().
    size_t v2_fixed_lag_frames;
    double default_minimum_rms;
} kv_pitch_contract_v1;

/// Engine ids. 0-3 are RESERVED historical slots: the engines behind them
/// were removed in D-039 and their numbers are never reused or renumbered,
/// so a stored selection naming one stays recognisable as "an engine that
/// existed once". Passing a reserved id to any create function fails; it is
/// never silently resolved to the surviving engine.
enum { KV_ENGINE_YIN_V1 = 0, KV_ENGINE_V2 = 1, KV_ENGINE_VPM_LIKE = 2, KV_ENGINE_HAPT_V1 = 3, KV_ENGINE_UNIFIED_V1 = 4 };
enum { KV_PROFILE_REALTIME = 0, KV_PROFILE_OFFLINE_TRACK = 1 };
enum { KV_PITCH_C_ABI_V1 = 1 };
/// Capability bits. Like the engine ids, the bits of removed engines and
/// features stay declared and stay at their own positions; a build simply
/// stops setting them. Callers already test with `&`, so a removed engine
/// reads as absent rather than as a renumbered neighbour.
enum {
    KV_CAP_ENGINE_YIN_V1 = 1u << 0,
    KV_CAP_ENGINE_V2 = 1u << 1,
    KV_CAP_ENGINE_VPM_LIKE = 1u << 2,
    KV_CAP_PROFILE_REALTIME = 1u << 3,
    KV_CAP_PROFILE_OFFLINE_TRACK_V1 = 1u << 4,
    KV_CAP_SOURCE_TIMESTAMPS = 1u << 5,
    KV_CAP_V2_FIXED_LAG_FINISH = 1u << 6,
    KV_CAP_ENGINE_HAPT_V1 = 1u << 7,
    KV_CAP_ENGINE_UNIFIED_V1 = 1u << 8,
};

/// Returns 1 on success and 0 for an invalid output pointer. Ownership remains
/// with the caller and no heap allocation occurs. PCM passed to process
/// functions is mono Float32 at sample_rate_hz; frame timestamps describe the
/// centre of that source window, not publication latency.
int kv_pitch_contract_get_v1(kv_pitch_contract_v1 *out_contract);

/// Decision latency of the unified engine, in hops. Exposed as its own call
/// rather than as a field on kv_pitch_contract_v1: that struct's layout is a
/// persisted contract, callers assert on it, and appending to it would require
/// a new ABI version for what is a single engine's parameter. The v1 struct's
/// v2_fixed_lag_frames is a reserved leftover and describes nothing this build
/// runs (see its own comment).
size_t kv_unified_lag_frames(void);

kv_pitch_engine *kv_pitch_engine_create(int engine, int profile);
void kv_pitch_engine_destroy(kv_pitch_engine *engine);
int kv_pitch_engine_push(kv_pitch_engine *engine, const float *samples, size_t count, double sample_rate);
size_t kv_pitch_engine_finish(kv_pitch_engine *engine);
int kv_pitch_engine_frame(const kv_pitch_engine *engine, size_t index, kv_pitch_frame *out_frame);
const char *kv_pitch_engine_last_error(const kv_pitch_engine *engine);

/// Progress reporting for the offline (whole-file) analysis kv_pitch_engine
/// performs in kv_pitch_engine_finish.
///
/// Exposed as its own setter rather than as a field on kv_pitch_contract_v1
/// for the same reason kv_unified_lag_frames() is a call: that struct's layout
/// is a persisted contract that callers assert on, and appending to it would
/// require a new ABI version for what is one optional capability. Adding a
/// function is additive and leaves every existing caller binary-compatible.
///
/// `callback` may be NULL to clear a previously set one. `context` is passed
/// back untouched. The callback is invoked from the thread that called
/// kv_pitch_engine_finish, never concurrently, and never after that call
/// returns -- so it may safely touch caller state that outlives the call.
/// `done` never exceeds `total`; both count analysis frames, not samples.
///
/// Rationale: the offline profile decodes the whole file in one blocking
/// call (~50 s for a three-minute recording), so a caller with no hook can
/// only show an indeterminate spinner for the entire analysis.
typedef void (*kv_pitch_progress_fn)(size_t done, size_t total, void *context);

/// Returns 1 on success and 0 for an invalid engine handle.
int kv_pitch_engine_set_progress(
    kv_pitch_engine *engine,
    kv_pitch_progress_fn callback,
    void *context
);

/// Canonical live/file causal session for the unified engine. Each call
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

/// REMOVED (D-039), declarations retained. pitch_engine_v2 is gone, but the
/// v1 ABI's exported symbol set is a frozen contract, so these entry points
/// are kept and now fail cleanly: create returns NULL, every other call
/// returns 0. A caller built against v1 still links and gets a diagnosable
/// failure instead of an unresolved symbol. Nothing in this repository calls
/// them any more.
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
