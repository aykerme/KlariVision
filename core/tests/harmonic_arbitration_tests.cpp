#include "klarivision/core/harmonic_arbitration.hpp"
#include "klarivision/core/analysis_engine.hpp"

#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <vector>

using klarivision::core::spectral_existence;

namespace {

constexpr double kSampleRate = 48'000.0;
constexpr std::size_t kWindow = 1536;

// A window of a tone built from the given (harmonic_number, amplitude)
// pairs. Harmonics not listed carry zero amplitude, matching the measured
// closed-pipe clarinet spectrum used throughout this test file: energy
// only at odd multiples of the fundamental, nothing at 2f/4f.
std::vector<float> harmonic_window(
    const double fundamental_hz,
    const std::vector<std::pair<int, double>>& harmonics,
    const double phase_seconds = 0.0
) {
    std::vector<float> samples(kWindow);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double t = phase_seconds + static_cast<double>(index) / kSampleRate;
        double value = 0.0;
        for (const auto& [harmonic, amplitude] : harmonics) {
            value += amplitude * std::sin(
                2.0 * std::numbers::pi * fundamental_hz * static_cast<double>(harmonic) * t
            );
        }
        samples[index] = static_cast<float>(value);
    }
    return samples;
}

}  // namespace

int main() {
    // Case 0: silence carries no evidence either way.
    {
        const std::vector<float> silence(kWindow, 0.0F);
        const auto verdict = spectral_existence(silence, kSampleRate, 398.0, 1500.0);
        assert(!verdict.is_ghost_subharmonic);
        assert(verdict.dominant_multiple_ratio == 0.0);
    }

    // Case 1: the measured closed-pipe 398 Hz clarinet tone -- fundamental
    // present but 3-11 dB weaker than its own third harmonic, nothing at
    // the second harmonic. The candidate's own line is real, if soft; it
    // must not be flagged as a ghost.
    {
        const auto samples = harmonic_window(398.0, {{1, 0.30}, {3, 1.00}, {5, 0.40}, {7, 0.20}});
        const auto verdict = spectral_existence(samples, kSampleRate, 398.0, 1500.0);
        assert(!verdict.is_ghost_subharmonic);
    }

    // Case 2: the ghost. Nothing is played at 449/3 Hz -- the note actually
    // sounding is a full-series 449 Hz tone whose third harmonic (1347 Hz)
    // dominates its own attack, exactly as measured on the recording that
    // motivated this module. A period-domain estimator can still find a
    // spuriously competitive minimum there; the spectral check must call it
    // out decisively.
    {
        const double target = 449.0;
        const auto samples = harmonic_window(target, {{1, 0.35}, {2, 0.20}, {3, 1.00}, {4, 0.15}});
        const auto verdict = spectral_existence(samples, kSampleRate, target / 3.0, 1500.0);
        assert(verdict.is_ghost_subharmonic);
        assert(verdict.dominant_multiple_ratio > 12.0);
        // The dominant relative is the note's own fundamental (candidate's
        // 3x, since candidate = target / 3), not an arbitrary frequency.
        const double distance_to_target = std::abs(verdict.dominant_multiple_hz - target);
        assert(distance_to_target < 1.0);
    }

    // Case 3: a full harmonic series with a strong fundamental (the
    // recording's neighbouring 448 Hz note) must never be flagged --
    // today's correct behaviour must survive this change unchanged.
    {
        const auto samples = harmonic_window(
            448.0, {{1, 1.00}, {2, 0.55}, {3, 0.42}, {4, 0.20}, {5, 0.12}}
        );
        const auto verdict = spectral_existence(samples, kSampleRate, 448.0, 1500.0);
        assert(!verdict.is_ghost_subharmonic);
    }

    // Case 4: a genuine high fundamental with its own harmonics present
    // must not be treated as someone else's overtone merely because it is
    // an octave-plus above 400 Hz.
    {
        const auto samples = harmonic_window(1195.0, {{1, 1.00}, {2, 0.6}, {3, 0.3}});
        const auto verdict = spectral_existence(samples, kSampleRate, 1195.0, 1650.0);
        assert(!verdict.is_ghost_subharmonic);
    }

    // End-to-end: a sustained closed-pipe tone must never be published as
    // its own third harmonic. The engine that first failed this (yin_v1) has
    // since been removed, but the tone is kept and pointed at the surviving
    // engine: a quiet fundamental under a dominant third is the exact shape
    // the whole octave-error effort is about, so it is a live claim about
    // unified_v1 rather than a fossil of the old bug.
    {
        constexpr std::size_t hop = 512;
        constexpr double fundamental = 398.0;
        constexpr double duration_seconds = 1.0;
        const auto sample_count = static_cast<std::size_t>(duration_seconds * kSampleRate);
        std::vector<float> tone(sample_count);
        for (std::size_t index = 0; index < sample_count; ++index) {
            const double t = static_cast<double>(index) / kSampleRate;
            double value = 0.0;
            for (const auto& [harmonic, amplitude] : std::vector<std::pair<int, double>>{
                     {1, 0.30}, {3, 1.00}, {5, 0.40}, {7, 0.20}}) {
                value += amplitude * std::sin(2.0 * std::numbers::pi * fundamental * harmonic * t);
            }
            tone[index] = static_cast<float>(0.18 * value);
        }
        klarivision::core::ProductionPitchSession session(klarivision::core::PitchEngineId::unified_v1);
        std::size_t published_frames = 0;
        std::size_t correct_frames = 0;
        for (std::size_t start = 0; start + kWindow <= tone.size(); start += hop) {
            const double time = (static_cast<double>(start) + kWindow / 2.0) / kSampleRate;
            for (const auto& frame : session.process_frame(
                     std::span<const float>(tone).subspan(start, kWindow), kSampleRate, time
                 )) {
                if (!frame.frequency_hz) continue;
                ++published_frames;
                const double cents = std::abs(1200.0 * std::log2(*frame.frequency_hz / fundamental));
                // No frame may land within 55 cents of the third harmonic
                // (1194 Hz) -- the ghost this fix removes.
                const double cents_from_third = std::abs(
                    1200.0 * std::log2(*frame.frequency_hz / (fundamental * 3.0))
                );
                assert(cents_from_third > 55.0);
                if (cents < 55.0) ++correct_frames;
            }
        }
        assert(published_frames > 0);
        // The overwhelming majority of frames must land on the true,
        // if quieter, fundamental.
        assert(correct_frames * 10 >= published_frames * 9);
    }

    std::cout << "KlariVision Core harmonic arbitration tests passed.\n";
}
