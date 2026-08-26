#include "klarivision/core/analysis_engine.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <numbers>
#include <vector>

int main() {
    constexpr double rate = 48'000;

    // The offline harmonic path refinement has one contract and one risk.
    // The contract: it belongs to the offline profile only, so the live path
    // and its latency guarantee are untouched.  The risk: a path search that
    // suppresses isolated harmonic excursions could also erase a genuine
    // register leap, which on a clarinet is exactly the twelfth the instrument
    // overblows to.  Both are locked here.
    //
    // The repair itself is measured against the listener verdicts rather than
    // synthesised: a synthetic signal that reliably provokes the causal
    // failure could not be constructed -- the estimators handle clean missing
    // fundamentals correctly, and forcing the audio to jump makes the octave
    // the *right* answer.  See docs/TEST_BASELINE.md.
    {
        constexpr double low = 300;
        constexpr double high = 600;
        const auto clarinet_partials = [](std::vector<float>& buffer, const double f,
                                          const std::size_t from, const std::size_t to) {
            for (std::size_t index = from; index < to && index < buffer.size(); ++index) {
                const double t = static_cast<double>(index) / rate;
                buffer[index] = static_cast<float>(
                    0.30 * std::sin(2 * std::numbers::pi * f * t) +
                    0.30 * std::sin(2 * std::numbers::pi * f * 3 * t) +
                    0.18 * std::sin(2 * std::numbers::pi * f * 5 * t));
            }
        };
        std::vector<float> leap(48'000);
        const std::size_t leap_start = static_cast<std::size_t>(0.40 * rate);
        const std::size_t leap_end = static_cast<std::size_t>(0.80 * rate);
        clarinet_partials(leap, low, 0, leap_start);
        clarinet_partials(leap, high, leap_start, leap_end);
        clarinet_partials(leap, low, leap_end, leap.size());

        klarivision::core::PitchEngine offline(
            klarivision::core::PitchEngineId::yin_v1,
            klarivision::core::PitchEngineProfile::offline_track
        );
        const auto refined = offline.analyse(leap, rate);
        const auto baseline = offline.analyse_causal(leap, rate);
        const auto high_frames = [&](const std::vector<klarivision::core::EngineFrame>& track) {
            std::size_t count = 0;
            for (const auto& frame : track) {
                if (!frame.frequency_hz) continue;
                if (frame.time_seconds < 0.42 || frame.time_seconds > 0.78) continue;
                if (std::abs(*frame.frequency_hz - high) < 30) ++count;
            }
            return count;
        };
        // A leap the causal pass committed to must survive the path search.
        assert(high_frames(baseline) > 0);
        assert(high_frames(refined) >= high_frames(baseline));

        // The realtime profile must come back byte-for-byte from the causal
        // pass -- refinement is not allowed anywhere near the live contract.
        klarivision::core::PitchEngine live(
            klarivision::core::PitchEngineId::yin_v1,
            klarivision::core::PitchEngineProfile::realtime
        );
        const auto live_frames = live.analyse(leap, rate);
        const auto live_causal = live.analyse_causal(leap, rate);
        assert(live_frames.size() == live_causal.size());
        for (std::size_t index = 0; index < live_frames.size(); ++index) {
            assert(live_frames[index].frequency_hz.has_value() ==
                   live_causal[index].frequency_hz.has_value());
            if (live_frames[index].frequency_hz) {
                assert(std::abs(*live_frames[index].frequency_hz -
                                *live_causal[index].frequency_hz) < 1e-9);
            }
        }
    }

    // The offline stray-point rule drops short, isolated, low-confidence runs.
    // Its one real danger is the çarpma: a grace note is also short and also
    // low on evidence.  What saves it is that an ornament is *attached* to the
    // note it decorates, so it never has the silence on both sides the rule
    // requires.  That distinction is the whole safety argument, so it is
    // locked here rather than left to the threshold.
    {
        const auto partials = [](std::vector<float>& buffer, const double f,
                                 const std::size_t from, const std::size_t to) {
            for (std::size_t index = from; index < to && index < buffer.size(); ++index) {
                const double t = static_cast<double>(index) / rate;
                buffer[index] = static_cast<float>(
                    0.30 * std::sin(2 * std::numbers::pi * f * t) +
                    0.30 * std::sin(2 * std::numbers::pi * f * 3 * t) +
                    0.18 * std::sin(2 * std::numbers::pi * f * 5 * t));
            }
        };
        std::vector<float> ornament(48'000, 0.0F);
        partials(ornament, 300, static_cast<std::size_t>(0.30 * rate), static_cast<std::size_t>(0.34 * rate));
        partials(ornament, 400, static_cast<std::size_t>(0.34 * rate), static_cast<std::size_t>(0.74 * rate));
        for (const auto id : {klarivision::core::PitchEngineId::yin_v1,
                              klarivision::core::PitchEngineId::pitch_engine_v2,
                              klarivision::core::PitchEngineId::hapt_v1}) {
            klarivision::core::PitchEngine offline(id, klarivision::core::PitchEngineProfile::offline_track);
            klarivision::core::PitchEngine causal(id, klarivision::core::PitchEngineProfile::realtime);
            const auto refined = offline.analyse(ornament, rate);
            const auto baseline = causal.analyse(ornament, rate);
            const auto grace_frames = [&](const std::vector<klarivision::core::EngineFrame>& track) {
                std::size_t count = 0;
                for (const auto& frame : track) {
                    if (!frame.frequency_hz) continue;
                    if (frame.time_seconds < 0.30 || frame.time_seconds > 0.35) continue;
                    if (std::abs(*frame.frequency_hz - 300) < 20) ++count;
                }
                return count;
            };
            assert(grace_frames(baseline) > 0);
            assert(grace_frames(refined) == grace_frames(baseline));
        }
    }

    // A closed-pipe clarinet tone must not be promoted an octave up.  The
    // octave-recovery pass in `yin_candidates` exists to rescue a real
    // high-register fundamental that CMND read as its own f/2 sub-period, and
    // it fires on raw 2x spectral dominance.  On a clarinet that test alone is
    // not enough: the instrument's even partials are physically weak, so a
    // genuine fundamental can look dominated at 2x during a thin frame.  The
    // odd-harmonic occupancy check is what separates the two cases -- a real
    // fundamental owns 3f and 5f, a ghost owns neither.
    {
        constexpr double fundamental = 480;  // 2x lands at 960 Hz, inside the >800 Hz recovery band
        std::vector<float> clarinet(48'000);
        for (std::size_t index = 0; index < clarinet.size(); ++index) {
            const double t = static_cast<double>(index) / rate;
            clarinet[index] = static_cast<float>(
                0.30 * std::sin(2 * std::numbers::pi * fundamental * t) +        // fundamental
                0.34 * std::sin(2 * std::numbers::pi * fundamental * 3 * t) +    // strong third
                0.20 * std::sin(2 * std::numbers::pi * fundamental * 5 * t) +    // strong fifth
                0.02 * std::sin(2 * std::numbers::pi * fundamental * 2 * t)      // weak second, as physics requires
            );
        }
        klarivision::core::PitchEngine clarinet_engine(
            klarivision::core::PitchEngineId::yin_v1,
            klarivision::core::PitchEngineProfile::offline_track
        );
        const auto clarinet_frames = clarinet_engine.analyse(clarinet, rate);
        assert(!clarinet_frames.empty());
        std::size_t at_fundamental = 0;
        std::size_t at_octave = 0;
        for (const auto& frame : clarinet_frames) {
            if (!frame.frequency_hz) continue;
            if (std::abs(*frame.frequency_hz - fundamental) < 12) ++at_fundamental;
            if (std::abs(*frame.frequency_hz - fundamental * 2) < 24) ++at_octave;
        }
        assert(at_fundamental > 0);
        assert(at_octave == 0);
    }

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
