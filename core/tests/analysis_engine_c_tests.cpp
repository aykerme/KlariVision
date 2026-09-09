#include "klarivision/core/analysis_engine_c.h"
#include "klarivision/core/analysis_engine.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"

#include <cassert>
#include <cmath>
#include <numbers>
#include <vector>

namespace {

// Fills `window` with one hop's worth of a steady 440 Hz tone at `amplitude`,
// phase-continuous across frames.
void fill_tone(std::vector<float>& window, const std::size_t frame, const double amplitude) {
    constexpr double rate = 48'000;
    for (std::size_t index = 0; index < window.size(); ++index) {
        window[index] = static_cast<float>(amplitude * std::sin(
            2 * std::numbers::pi * 440 * (frame * 512 + index) / rate
        ));
    }
}

}  // namespace

int main() {
    kv_pitch_contract_v1 contract{};
    assert(kv_pitch_contract_get_v1(&contract));
    assert(contract.abi_version == KV_PITCH_C_ABI_V1);
    assert(contract.sample_rate_hz == 48'000);
    assert(contract.window_size == 1536);
    assert(contract.hop_size == 512);
    // Reserved field: it described pitch_engine_v2, which is gone. The layout
    // and the asserted value are the frozen part, not the meaning.
    assert(contract.v2_fixed_lag_frames == 5);
    assert(contract.default_minimum_rms == 0.015);
    assert((contract.capabilities & KV_CAP_ENGINE_UNIFIED_V1) != 0);
    assert((contract.capabilities & KV_CAP_PROFILE_REALTIME) != 0);
    assert((contract.capabilities & KV_CAP_PROFILE_OFFLINE_TRACK_V1) != 0);
    assert((contract.capabilities & KV_CAP_SOURCE_TIMESTAMPS) != 0);
    // Removed engines report their capability bit clear rather than having
    // their bit position reused by something else.
    assert((contract.capabilities & KV_CAP_ENGINE_YIN_V1) == 0);
    assert((contract.capabilities & KV_CAP_ENGINE_V2) == 0);
    assert((contract.capabilities & KV_CAP_ENGINE_VPM_LIKE) == 0);
    assert((contract.capabilities & KV_CAP_ENGINE_HAPT_V1) == 0);
    assert((contract.capabilities & KV_CAP_V2_FIXED_LAG_FINISH) == 0);
    assert(!kv_pitch_contract_get_v1(nullptr));
    assert(kv_unified_lag_frames() == klarivision::core::unified::kDefaultLagFrames);

    constexpr double rate = 48'000;
    constexpr std::size_t window_size = 1536;
    std::vector<float> window(window_size);

    // Every reserved engine id is refused outright, on both create paths. A
    // removed engine must not be silently served by the surviving one.
    for (const int removed :
         {KV_ENGINE_YIN_V1, KV_ENGINE_V2, KV_ENGINE_VPM_LIKE, KV_ENGINE_HAPT_V1}) {
        assert(kv_production_pitch_session_create(removed, 0.015) == nullptr);
        assert(kv_pitch_engine_create(removed, KV_PROFILE_REALTIME) == nullptr);
        assert(kv_pitch_engine_create(removed, KV_PROFILE_OFFLINE_TRACK) == nullptr);
    }

    // The removed v2 session entry points still link and still fail cleanly.
    assert(kv_v2_session_create(0.015, 5) == nullptr);
    assert(kv_v2_session_output_count(nullptr) == 0);
    assert(kv_v2_session_finish(nullptr) == 0);
    assert(!kv_v2_session_process_frame(nullptr, window.data(), window.size(), rate, 0.0));
    assert(!kv_v2_session_set_minimum_rms(nullptr, 0.02));

    auto* shared = kv_production_pitch_session_create(KV_ENGINE_UNIFIED_V1, 0.015);
    assert(shared != nullptr);
    std::size_t emitted = 0;
    for (std::size_t frame = 0; frame < 12; ++frame) {
        fill_tone(window, frame, 0.2);
        assert(kv_production_pitch_session_process_frame(
            shared, window.data(), window.size(), rate,
            (frame * 512 + window_size / 2) / rate
        ));
        emitted += kv_production_pitch_session_output_count(shared);
    }
    assert(emitted > 0);
    // The unified engine buffers a fixed-lag window, so end-of-stream always
    // has frames left to drain, and draining is idempotent.
    assert(kv_production_pitch_session_finish(shared) > 0);
    assert(kv_production_pitch_session_finish(shared) == 0);
    assert(!kv_production_pitch_session_process_frame(
        shared, window.data(), window.size(), rate, 1.0
    ));
    assert(kv_production_pitch_session_set_minimum_rms(shared, 0.02));
    kv_production_pitch_session_reset(shared);
    kv_production_pitch_session_destroy(shared);

    // The macOS Swift layer calls this C ABI verbatim.  Verify that its frame
    // sequence, including a short amplitude trough and recovery, is an exact
    // adapter over the canonical C++ ProductionPitchSession.
    auto* bridge = kv_production_pitch_session_create(KV_ENGINE_UNIFIED_V1, 0.015);
    assert(bridge != nullptr);
    klarivision::core::ProductionPitchSession canonical(
        klarivision::core::PitchEngineId::unified_v1
    );
    const std::vector<double> amplitudes{
        .20, .20, .20, .20, .08, .025, .014, .013, .017, .04, .10, .20,
    };
    for (std::size_t frame = 0; frame < amplitudes.size(); ++frame) {
        fill_tone(window, frame, amplitudes[frame]);
        const double time = (frame * 512 + window_size / 2) / rate;
        const auto expected = canonical.process_frame(window, rate, time);
        assert(kv_production_pitch_session_process_frame(
            bridge, window.data(), window.size(), rate, time
        ));
        assert(kv_production_pitch_session_output_count(bridge) == expected.size());
        for (std::size_t index = 0; index < expected.size(); ++index) {
            kv_pitch_frame actual{};
            assert(kv_production_pitch_session_output_frame(bridge, index, &actual));
            assert(actual.voiced == expected[index].frequency_hz.has_value());
            assert(actual.time_seconds == expected[index].time_seconds);
            assert(actual.frequency_hz == expected[index].frequency_hz.value_or(0));
            assert(actual.confidence == expected[index].confidence);
        }
    }
    kv_production_pitch_session_destroy(bridge);
}
