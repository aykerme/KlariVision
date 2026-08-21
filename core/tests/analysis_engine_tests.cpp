#include "klarivision/core/analysis_engine.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <numbers>
#include <vector>

int main() {
    constexpr double rate = 48'000;
    std::vector<float> tone(48'000 * 2);
    for (std::size_t index = 0; index < tone.size(); ++index) tone[index] = static_cast<float>(0.2 * std::sin(2 * std::numbers::pi * 440 * index / rate));
    for (const auto id : {klarivision::core::PitchEngineId::yin_v1, klarivision::core::PitchEngineId::pitch_engine_v2, klarivision::core::PitchEngineId::vpm_like}) {
        klarivision::core::PitchEngine engine(id, klarivision::core::PitchEngineProfile::offline_track);
        const auto frames = engine.analyse(tone, rate);
        assert(!frames.empty()); bool found = false;
        for (const auto& frame : frames) if (frame.frequency_hz && std::abs(*frame.frequency_hz - 440) < 12) found = true;
        assert(found);

        // Study's causal baseline and the frame-at-a-time production session
        // are the same implementation, not two algorithms expected merely
        // to be close.
        klarivision::core::ProductionPitchSession live(id);
        std::vector<klarivision::core::EngineFrame> live_frames;
        constexpr std::size_t window = 1536;
        constexpr std::size_t hop = 512;
        for (std::size_t start = 0; start + window <= tone.size(); start += hop) {
            const double time = (start + window / 2.0) / rate;
            auto published = live.process_frame(
                std::span<const float>(tone).subspan(start, window), rate, time
            );
            live_frames.insert(live_frames.end(), published.begin(), published.end());
        }
        auto live_tail = live.finish();
        live_frames.insert(live_frames.end(), live_tail.begin(), live_tail.end());
        klarivision::core::PitchEngine causal_engine(
            id, klarivision::core::PitchEngineProfile::realtime
        );
        const auto causal_frames = causal_engine.analyse_causal(tone, rate);
        assert(live_frames.size() == causal_frames.size());
        for (std::size_t index = 0; index < live_frames.size(); ++index) {
            assert(live_frames[index].time_seconds == causal_frames[index].time_seconds);
            assert(live_frames[index].frequency_hz == causal_frames[index].frequency_hz);
            assert(live_frames[index].confidence == causal_frames[index].confidence);
        }
    }
    // The offline VPM adapter must preserve VPM's spectrum-aware final
    // estimate, rather than feeding raw f/2 ACF peaks back to the path solver.
    std::vector<float> high_tone(48'000 * 2);
    for (std::size_t index = 0; index < high_tone.size(); ++index) {
        high_tone[index] = static_cast<float>(0.2 * std::sin(2 * std::numbers::pi * 880 * index / rate));
    }
    klarivision::core::PitchEngine vpm(klarivision::core::PitchEngineId::vpm_like, klarivision::core::PitchEngineProfile::offline_track);
    const auto vpm_frames = vpm.analyse(high_tone, rate);
    assert(std::any_of(vpm_frames.begin(), vpm_frames.end(), [](const auto& frame) {
        return frame.frequency_hz && std::abs(*frame.frequency_hz - 880) < 15;
    }));

    klarivision::core::PitchEngine silence(klarivision::core::PitchEngineId::yin_v1, klarivision::core::PitchEngineProfile::offline_track);
    const std::vector<float> zeros(4096);
    for (const auto& frame : silence.analyse(zeros, rate)) assert(!frame.frequency_hz);

    // VPM release candidates are withheld, then retroactively bridged only
    // when the same contour returns inside the seven-frame limit.
    const auto vpm_window = [](const double amplitude, const std::size_t frame) {
        std::vector<float> result(1536);
        for (std::size_t index = 0; index < result.size(); ++index) {
            result[index] = static_cast<float>(amplitude * std::sin(
                2 * std::numbers::pi * 440 * (frame * 512 + index) / 48'000
            ));
        }
        return result;
    };
    klarivision::core::ProductionPitchSession vpm_dropout(
        klarivision::core::PitchEngineId::vpm_like
    );
    std::size_t vpm_frame = 0;
    for (int index = 0; index < 4; ++index, ++vpm_frame) {
        const auto window = vpm_window(.40, vpm_frame);
        assert(!vpm_dropout.process_frame(window, rate, vpm_frame * 512 / rate).empty());
    }
    for (const double amplitude : {.28, .14, .06}) {
        const auto window = vpm_window(amplitude, vpm_frame);
        (void)vpm_dropout.process_frame(window, rate, vpm_frame * 512 / rate);
        ++vpm_frame;
    }
    const auto recovered_window = vpm_window(.35, vpm_frame);
    const auto recovered = vpm_dropout.process_frame(
        recovered_window, rate, vpm_frame * 512 / rate
    );
    assert(recovered.size() >= 2);
    assert(vpm_dropout.last_vpm_diagnostic().bridged_frames > 0);
    assert(vpm_dropout.last_vpm_diagnostic().publication_reason == "same_contour_recovery");

    // A decaying tail that does not recover before the limit is discarded and
    // cannot reacquire the stale contour until a causal attack restores RMS.
    klarivision::core::ProductionPitchSession vpm_release(
        klarivision::core::PitchEngineId::vpm_like
    );
    vpm_frame = 0;
    for (int index = 0; index < 4; ++index, ++vpm_frame) {
        const auto window = vpm_window(.40, vpm_frame);
        (void)vpm_release.process_frame(window, rate, vpm_frame * 512 / rate);
    }
    bool release_started = false;
    for (const double amplitude : {.28, .14, .06, .05, .04, .035, .030, .027, .025, .023}) {
        const auto window = vpm_window(amplitude, vpm_frame);
        const auto emitted = vpm_release.process_frame(
            window, rate, vpm_frame * 512 / rate
        );
        release_started = release_started ||
            vpm_release.last_vpm_diagnostic().release_suspected;
        if (release_started) assert(emitted.empty());
        ++vpm_frame;
    }
    const auto attack_window = vpm_window(.35, vpm_frame);
    assert(!vpm_release.process_frame(
        attack_window, rate, vpm_frame * 512 / rate
    ).empty());
}
