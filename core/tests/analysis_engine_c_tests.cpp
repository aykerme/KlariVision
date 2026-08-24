#include "klarivision/core/analysis_engine_c.h"
#include "klarivision/core/analysis_engine.hpp"

#include <cassert>
#include <cmath>
#include <numbers>
#include <vector>

int main() {
    kv_pitch_contract_v1 contract{};
    assert(kv_pitch_contract_get_v1(&contract));
    assert(contract.abi_version == KV_PITCH_C_ABI_V1);
    assert(contract.sample_rate_hz == 48'000);
    assert(contract.window_size == 1536);
    assert(contract.hop_size == 512);
    assert(contract.v2_fixed_lag_frames == 5);
    assert(contract.default_minimum_rms == 0.015);
    assert((contract.capabilities & KV_CAP_ENGINE_YIN_V1) != 0);
    assert((contract.capabilities & KV_CAP_ENGINE_V2) != 0);
    assert((contract.capabilities & KV_CAP_ENGINE_VPM_LIKE) != 0);
    assert((contract.capabilities & KV_CAP_ENGINE_HAPT_V1) != 0);
    assert((contract.capabilities & KV_CAP_PROFILE_OFFLINE_TRACK_V1) != 0);
    assert(!kv_pitch_contract_get_v1(nullptr));

    constexpr double rate = 48'000;
    constexpr std::size_t window_size = 1536;
    auto* session = kv_v2_session_create(0.015, 5);
    assert(session != nullptr);
    std::vector<float> window(window_size);
    std::size_t published = 0;
    for (std::size_t frame = 0; frame < 12; ++frame) {
        for (std::size_t index = 0; index < window.size(); ++index) {
            window[index] = static_cast<float>(0.2 * std::sin(
                2 * std::numbers::pi * 440 * (frame * 512 + index) / rate
            ));
        }
        assert(kv_v2_session_process_frame(
            session, window.data(), window.size(), rate, frame * 512 / rate
        ));
        published += kv_v2_session_output_count(session);
        for (std::size_t index = 0; index < kv_v2_session_output_count(session); ++index) {
            kv_pitch_frame output{};
            assert(kv_v2_session_output_frame(session, index, &output));
            assert(output.voiced && std::abs(output.frequency_hz - 440) < 2);
        }
    }
    assert(published > 0);
    assert(kv_v2_session_finish(session) > 0);
    assert(kv_v2_session_finish(session) == 0);
    assert(!kv_v2_session_process_frame(session, window.data(), window.size(), rate, 1.0));
    kv_v2_session_reset(session);
    assert(kv_v2_session_output_count(session) == 0);
    assert(kv_v2_session_set_minimum_rms(session, 0.02));
    assert(!kv_v2_session_set_minimum_rms(session, -1));
    kv_v2_session_destroy(session);

    for (const int engine : {KV_ENGINE_YIN_V1, KV_ENGINE_V2, KV_ENGINE_VPM_LIKE, KV_ENGINE_HAPT_V1}) {
        auto* shared = kv_production_pitch_session_create(engine, 0.015);
        assert(shared != nullptr);
        std::size_t emitted = 0;
        for (std::size_t frame = 0; frame < 12; ++frame) {
            for (std::size_t index = 0; index < window.size(); ++index) {
                window[index] = static_cast<float>(0.2 * std::sin(
                    2 * std::numbers::pi * 440 * (frame * 512 + index) / rate
                ));
            }
            assert(kv_production_pitch_session_process_frame(
                shared, window.data(), window.size(), rate,
                (frame * 512 + window_size / 2) / rate
            ));
            emitted += kv_production_pitch_session_output_count(shared);
        }
        assert(emitted > 0);
        const auto tail = kv_production_pitch_session_finish(shared);
        if (engine == KV_ENGINE_V2) assert(tail > 0);
        else assert(tail == 0);
        assert(kv_production_pitch_session_finish(shared) == 0);
        assert(!kv_production_pitch_session_process_frame(
            shared, window.data(), window.size(), rate, 1.0
        ));
        assert(kv_production_pitch_session_set_minimum_rms(shared, 0.02));
        kv_production_pitch_session_reset(shared);
        kv_production_pitch_session_destroy(shared);
    }

    // The macOS Swift layer calls this C ABI verbatim.  Verify that its VPM
    // frame sequence, including a short amplitude trough and recovery, is an
    // exact adapter over the canonical C++ ProductionPitchSession.
    auto* bridge = kv_production_pitch_session_create(KV_ENGINE_VPM_LIKE, 0.015);
    assert(bridge != nullptr);
    klarivision::core::ProductionPitchSession canonical(
        klarivision::core::PitchEngineId::vpm_like
    );
    const std::vector<double> amplitudes{
        .20, .20, .20, .20, .08, .025, .014, .013, .017, .04, .10, .20,
    };
    for (std::size_t frame = 0; frame < amplitudes.size(); ++frame) {
        for (std::size_t index = 0; index < window.size(); ++index) {
            window[index] = static_cast<float>(amplitudes[frame] * std::sin(
                2 * std::numbers::pi * 440 * (frame * 512 + index) / rate
            ));
        }
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
