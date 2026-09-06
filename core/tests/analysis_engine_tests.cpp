#include "klarivision/core/analysis_engine.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <numbers>
#include <stdexcept>
#include <vector>

namespace {

constexpr double rate = 48'000;

// Writes a stopped-cylinder (clarinet-like) tone into [from, to): fundamental
// plus a strong third and fifth, which is the partial structure every octave
// claim in this project is really about.
void clarinet_partials(
    std::vector<float>& buffer, const double f, const std::size_t from, const std::size_t to
) {
    for (std::size_t index = from; index < to && index < buffer.size(); ++index) {
        const double t = static_cast<double>(index) / rate;
        buffer[index] = static_cast<float>(
            0.30 * std::sin(2 * std::numbers::pi * f * t) +
            0.30 * std::sin(2 * std::numbers::pi * f * 3 * t) +
            0.18 * std::sin(2 * std::numbers::pi * f * 5 * t));
    }
}

std::size_t frames_near(
    const std::vector<klarivision::core::EngineFrame>& track,
    const double frequency,
    const double tolerance_hz,
    const double from_seconds,
    const double to_seconds
) {
    std::size_t count = 0;
    for (const auto& frame : track) {
        if (!frame.frequency_hz) continue;
        if (frame.time_seconds < from_seconds || frame.time_seconds > to_seconds) continue;
        if (std::abs(*frame.frequency_hz - frequency) < tolerance_hz) ++count;
    }
    return count;
}

}  // namespace

int main() {
    // Reserved ids 0-3 name engines that were removed (D-039). Construction
    // must fail rather than quietly run the surviving engine in their place.
    for (const auto removed : {klarivision::core::PitchEngineId::yin_v1_removed,
                               klarivision::core::PitchEngineId::pitch_engine_v2_removed,
                               klarivision::core::PitchEngineId::vpm_like_removed,
                               klarivision::core::PitchEngineId::hapt_v1_removed}) {
        assert(!klarivision::core::is_supported(removed));
        bool threw = false;
        try {
            klarivision::core::ProductionPitchSession rejected(removed);
        } catch (const std::invalid_argument&) { threw = true; }
        assert(threw);
        threw = false;
        try {
            klarivision::core::PitchEngine rejected(
                removed, klarivision::core::PitchEngineProfile::offline_track
            );
        } catch (const std::invalid_argument&) { threw = true; }
        assert(threw);
    }

    constexpr auto engine_id = klarivision::core::PitchEngineId::unified_v1;

    // The offline profile has one contract and one risk. The contract: it
    // belongs to the offline profile only, so the live path and its latency
    // guarantee are untouched. The risk: a whole-track decode that suppresses
    // isolated excursions could also erase a genuine register leap, which on a
    // clarinet is exactly the twelfth the instrument overblows to. Both are
    // locked here.
    {
        constexpr double low = 300;
        constexpr double high = 600;
        std::vector<float> leap(48'000);
        const std::size_t leap_start = static_cast<std::size_t>(0.40 * rate);
        const std::size_t leap_end = static_cast<std::size_t>(0.80 * rate);
        clarinet_partials(leap, low, 0, leap_start);
        clarinet_partials(leap, high, leap_start, leap_end);
        clarinet_partials(leap, low, leap_end, leap.size());

        klarivision::core::PitchEngine offline(
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        const auto refined = offline.analyse(leap, rate);
        const auto baseline = offline.analyse_causal(leap, rate);
        // A leap the causal pass committed to must survive the offline decode.
        assert(frames_near(baseline, high, 30, 0.42, 0.78) > 0);
        assert(frames_near(refined, high, 30, 0.42, 0.78) >=
               frames_near(baseline, high, 30, 0.42, 0.78));

        // The realtime profile must come back byte-for-byte from the causal
        // pass -- offline decoding is not allowed anywhere near the live
        // contract.
        klarivision::core::PitchEngine live(
            engine_id, klarivision::core::PitchEngineProfile::realtime
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
    // low on evidence. What saves it is that an ornament is *attached* to the
    // note it decorates, so it never has the silence on both sides the rule
    // requires. That distinction is the whole safety argument, so it is
    // locked here rather than left to the threshold.
    //
    // The invariant is survival, not an identical frame count: the offline
    // pass is a whole-track decode, not a refinement of the causal trace, so
    // it re-decides voicing at the note boundaries and legitimately lands a
    // frame or two either side of where the causal pass did.
    {
        std::vector<float> ornament(48'000, 0.0F);
        clarinet_partials(ornament, 300,
            static_cast<std::size_t>(0.30 * rate), static_cast<std::size_t>(0.34 * rate));
        clarinet_partials(ornament, 400,
            static_cast<std::size_t>(0.34 * rate), static_cast<std::size_t>(0.74 * rate));
        klarivision::core::PitchEngine offline(
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        klarivision::core::PitchEngine causal(
            engine_id, klarivision::core::PitchEngineProfile::realtime
        );
        const auto refined = offline.analyse(ornament, rate);
        const auto baseline = causal.analyse(ornament, rate);
        assert(frames_near(baseline, 300, 20, 0.28, 0.37) > 0);
        assert(frames_near(refined, 300, 20, 0.28, 0.37) > 0);
    }

    // A closed-pipe clarinet tone must not be promoted an octave up. The
    // instrument's even partials are physically weak, so a genuine fundamental
    // can look dominated at 2x during a thin frame; the odd-harmonic occupancy
    // is what separates a real fundamental (which owns 3f and 5f) from a ghost
    // (which owns neither).
    {
        constexpr double fundamental = 480;  // 2x lands at 960 Hz
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
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        const auto clarinet_frames = clarinet_engine.analyse(clarinet, rate);
        assert(!clarinet_frames.empty());
        assert(frames_near(clarinet_frames, fundamental, 12, 0, 1e9) > 0);
        assert(frames_near(clarinet_frames, fundamental * 2, 24, 0, 1e9) == 0);
    }

    // The mirror-image risk of reaching past 2x/3x: on a stopped cylinder the
    // 5th partial is a strong, genuinely present line, so a real low
    // fundamental must not be promoted onto it. What holds the two apart is
    // the path's transition cost -- a 5x alternative only pays for itself when
    // the neighbouring frames already sit there -- so a sustained tone must
    // come back as one stable pitch.
    {
        constexpr double fundamental = 150;  // 5x lands on 750 Hz
        std::vector<float> stopped_pipe(48'000);
        for (std::size_t index = 0; index < stopped_pipe.size(); ++index) {
            const double t = static_cast<double>(index) / rate;
            stopped_pipe[index] = static_cast<float>(
                0.06 * std::sin(2 * std::numbers::pi * fundamental * t) +      // deliberately weak fundamental
                0.34 * std::sin(2 * std::numbers::pi * fundamental * 3 * t) +  // dominant third
                0.30 * std::sin(2 * std::numbers::pi * fundamental * 5 * t)    // dominant fifth
            );
        }
        klarivision::core::PitchEngine stopped(
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        const auto frames = stopped.analyse(stopped_pipe, rate);
        std::size_t at_fundamental = 0;
        std::size_t at_fourth = 0;
        std::size_t at_fifth = 0;
        std::size_t voiced = 0;
        for (const auto& frame : frames) {
            if (!frame.frequency_hz) continue;
            ++voiced;
            const double cents = 1200.0 * std::log2(*frame.frequency_hz / fundamental);
            if (std::abs(cents) < 60) ++at_fundamental;
            if (std::abs(cents - 1200.0 * std::log2(4.0)) < 60) ++at_fourth;
            if (std::abs(cents - 1200.0 * std::log2(5.0)) < 60) ++at_fifth;
        }
        assert(voiced > 0);
        assert(at_fundamental * 20 >= voiced * 19);  // the tone stays on its own fundamental
        assert(at_fourth == 0);                      // never promoted onto 4x
        assert(at_fifth == 0);                       // ...nor onto its strong 5th partial
    }

    // Study's causal baseline and the frame-at-a-time production session are
    // the same implementation, not two algorithms expected merely to be close.
    {
        std::vector<float> tone(48'000 * 2);
        for (std::size_t index = 0; index < tone.size(); ++index) {
            tone[index] = static_cast<float>(
                0.2 * std::sin(2 * std::numbers::pi * 440 * index / rate));
        }
        klarivision::core::PitchEngine engine(
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        const auto frames = engine.analyse(tone, rate);
        assert(!frames.empty());
        assert(frames_near(frames, 440, 12, 0, 1e9) > 0);

        klarivision::core::ProductionPitchSession live(engine_id);
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
            engine_id, klarivision::core::PitchEngineProfile::realtime
        );
        const auto causal_frames = causal_engine.analyse_causal(tone, rate);
        assert(live_frames.size() == causal_frames.size());
        for (std::size_t index = 0; index < live_frames.size(); ++index) {
            assert(live_frames[index].time_seconds == causal_frames[index].time_seconds);
            assert(live_frames[index].frequency_hz == causal_frames[index].frequency_hz);
            assert(live_frames[index].confidence == causal_frames[index].confidence);
        }

        // A finished session refuses more input until it is reset.
        bool threw = false;
        try {
            (void)live.process_frame(
                std::span<const float>(tone).subspan(0, window), rate, 0.0
            );
        } catch (const std::logic_error&) { threw = true; }
        assert(threw);
        // ...and accepts input again after reset (whether this particular
        // frame publishes is the engine's business; not throwing is the
        // contract).
        live.reset();
        (void)live.process_frame(
            std::span<const float>(tone).subspan(0, window), rate, 0.0
        );
    }

    // A high tone inside the display range must be reported where it is, not
    // an octave down.
    {
        std::vector<float> high_tone(48'000 * 2);
        for (std::size_t index = 0; index < high_tone.size(); ++index) {
            high_tone[index] = static_cast<float>(
                0.2 * std::sin(2 * std::numbers::pi * 880 * index / rate));
        }
        klarivision::core::PitchEngine engine(
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        const auto frames = engine.analyse(high_tone, rate);
        assert(std::any_of(frames.begin(), frames.end(), [](const auto& frame) {
            return frame.frequency_hz && std::abs(*frame.frequency_hz - 880) < 15;
        }));
    }

    // Silence stays silent.
    {
        klarivision::core::PitchEngine silence(
            engine_id, klarivision::core::PitchEngineProfile::offline_track
        );
        const std::vector<float> zeros(4096);
        for (const auto& frame : silence.analyse(zeros, rate)) assert(!frame.frequency_hz);
    }
}
