#include "klarivision/core/hapt.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <random>
#include <vector>

using klarivision::core::diagnose_hapt_pitch;
using klarivision::core::estimate_hapt_pitch;
using klarivision::core::HAPTConfig;
using klarivision::core::HAPTPitch;
using klarivision::core::HAPTTracker;

namespace {

constexpr double kSampleRate = 48000.0;
constexpr int kWindow = 1536;

/// Builds one continuous-phase tone: `harmonics[i]` is the amplitude of the
/// (i+1)-th harmonic (index 0 == fundamental). A zero entry silences that
/// harmonic, letting tests build clarinet-like (odd-only) or full-series
/// spectra.
std::vector<float> tone(
    const double frequency,
    const double sample_rate,
    const int sample_count,
    const std::vector<double>& harmonics
) {
    std::vector<float> samples(static_cast<std::size_t>(sample_count));
    for (int index = 0; index < sample_count; ++index) {
        const auto t = static_cast<double>(index) / sample_rate;
        double value = 0.0;
        for (std::size_t harmonic = 0; harmonic < harmonics.size(); ++harmonic) {
            if (harmonics[harmonic] == 0.0) continue;
            value += harmonics[harmonic] *
                std::sin(2.0 * std::numbers::pi * static_cast<double>(harmonic + 1) * frequency * t);
        }
        samples[static_cast<std::size_t>(index)] = static_cast<float>(value);
    }
    return samples;
}

double cents(const double a, const double b) {
    return std::abs(1200.0 * std::log2(a / b));
}

}  // namespace

int main() {
    // 1. Pure sine, sub-cent accuracy from the phase-locked IF refinement.
    {
        const auto samples = tone(440.0, kSampleRate, kWindow, {1.0});
        const auto pitch = estimate_hapt_pitch(samples, kSampleRate);
        assert(pitch);
        assert(cents(pitch->frequency_hz, 440.0) < 1.0);
    }

    // 2. Clarinet-like spectrum (only odd harmonics): must resolve the true
    //    220 Hz fundamental, not double it to the (silent) 2nd harmonic
    //    position at 440 Hz.
    {
        const auto samples = tone(220.0, kSampleRate, kWindow, {0.62, 0.0, 0.28, 0.0, 0.10});
        const auto pitch = estimate_hapt_pitch(samples, kSampleRate);
        assert(pitch);
        assert(cents(pitch->frequency_hz, 220.0) < 15.0);
        assert(cents(pitch->frequency_hz, 440.0) > 100.0);
    }

    // 3. Full harmonic series: NSDF has a near-equal peak at twice the true
    //    period (half the frequency); the odd-harmonic-occupancy term must
    //    keep the engine from halving 300 Hz down to 150 Hz.
    {
        const auto samples = tone(300.0, kSampleRate, kWindow, {1.0, 0.7, 0.5, 0.35, 0.25});
        const auto pitch = estimate_hapt_pitch(samples, kSampleRate);
        assert(pitch);
        assert(cents(pitch->frequency_hz, 300.0) < 15.0);
        assert(cents(pitch->frequency_hz, 150.0) > 100.0);
    }

    // 4. The twelfth trap: a weak fundamental under a dominant 3rd harmonic
    //    must still resolve to the fundamental, not overblow to 3x.
    {
        const auto samples = tone(200.0, kSampleRate, kWindow, {0.12, 0.0, 0.74, 0.0, 0.14});
        const auto pitch = estimate_hapt_pitch(samples, kSampleRate);
        assert(pitch);
        assert(cents(pitch->frequency_hz, 200.0) < 15.0);
        assert(cents(pitch->frequency_hz, 600.0) > 100.0);
    }

    // 5. Below the window's spectral resolution gate (187.5 Hz for a
    //    1536-sample/48kHz window), the half/third grid falls back to the
    //    time-domain NSDF ratio and must still resolve correctly.
    {
        const auto samples = tone(120.0, kSampleRate, kWindow, {0.62, 0.0, 0.28, 0.0, 0.10});
        const auto diagnostic = diagnose_hapt_pitch(samples, kSampleRate);
        assert(diagnostic.pitch);
        assert(cents(diagnostic.pitch->frequency_hz, 120.0) < 15.0);
        const auto winner = std::find_if(
            diagnostic.hypotheses.begin(), diagnostic.hypotheses.end(),
            [](const auto& hypothesis) { return hypothesis.selected; }
        );
        assert(winner != diagnostic.hypotheses.end());
        assert(!winner->half_grid_spectrally_resolvable);
        assert(!winner->third_grid_spectrally_resolvable);
    }

    // 6. Vibrato (6 Hz rate, +/-50 cent depth) must not be flattened by the
    //    causal continuity bonus or the IF lock's 40-cent correction gate.
    {
        constexpr double f0 = 440.0;
        constexpr double vibrato_rate_hz = 6.0;
        constexpr double depth_cents = 50.0;
        constexpr int hop = 512;
        std::vector<float> buffer(static_cast<std::size_t>(kSampleRate * 0.5));
        double phase = 0.0;
        for (std::size_t index = 0; index < buffer.size(); ++index) {
            const auto t = static_cast<double>(index) / kSampleRate;
            const auto offset_cents = depth_cents * std::sin(2.0 * std::numbers::pi * vibrato_rate_hz * t);
            const auto instantaneous_f = f0 * std::pow(2.0, offset_cents / 1200.0);
            phase += 2.0 * std::numbers::pi * instantaneous_f / kSampleRate;
            buffer[index] = static_cast<float>(
                0.6 * std::sin(phase) + 0.25 * std::sin(3.0 * phase) + 0.1 * std::sin(5.0 * phase)
            );
        }
        std::optional<double> previous;
        double minimum_hz = 1e9;
        double maximum_hz = 0.0;
        for (std::size_t start = 0; start + kWindow <= buffer.size(); start += hop) {
            const std::span<const float> window(buffer.data() + start, kWindow);
            const auto pitch = estimate_hapt_pitch(window, kSampleRate, {}, previous);
            if (pitch) {
                minimum_hz = std::min(minimum_hz, pitch->frequency_hz);
                maximum_hz = std::max(maximum_hz, pitch->frequency_hz);
                previous = pitch->frequency_hz;
            }
        }
        const auto measured_depth_cents = 1200.0 * std::log2(maximum_hz / minimum_hz) / 2.0;
        assert(measured_depth_cents >= depth_cents * 0.90);
    }

    // 7. Onset recovery: a chirp attack transient (90->330 Hz sweep) over
    //    the first half of the window, settling into a clean clarinet-like
    //    330 Hz tone for the second half, fails the full-window onset gate
    //    (the sweep destroys periodicity at any single lag) but must still
    //    publish via the trailing 768-sample recovery pass.
    {
        std::vector<float> buffer(static_cast<std::size_t>(kWindow), 0.0F);
        double phase = 0.0;
        for (int index = 0; index < kWindow / 2; ++index) {
            const auto fraction = static_cast<double>(index) / (kWindow / 2);
            const auto instantaneous_f = 90.0 + (330.0 - 90.0) * fraction;
            phase += 2.0 * std::numbers::pi * instantaneous_f / kSampleRate;
            buffer[static_cast<std::size_t>(index)] = static_cast<float>(0.5 * std::sin(phase));
        }
        const auto tail = tone(330.0, kSampleRate, kWindow / 2, {0.62, 0.0, 0.28, 0.0, 0.10});
        std::copy(tail.begin(), tail.end(), buffer.begin() + kWindow / 2);
        const auto diagnostic = diagnose_hapt_pitch(buffer, kSampleRate);
        assert(diagnostic.onset_recovery_attempted);
        assert(diagnostic.onset_recovery_used);
        assert(diagnostic.pitch);
        assert(cents(diagnostic.pitch->frequency_hz, 330.0) < 25.0);
    }

    // 8. No spurious voicing on noise at/above the RMS gate.
    {
        std::mt19937 generator(1234);
        std::uniform_real_distribution<float> distribution(-0.05F, 0.05F);
        std::vector<float> noise(static_cast<std::size_t>(kWindow));
        for (auto& sample : noise) sample = distribution(generator);
        const auto pitch = estimate_hapt_pitch(noise, kSampleRate);
        assert(!pitch);
    }

    // 9. Determinism: identical input, identical output, twice in a row.
    {
        const auto samples = tone(261.63, kSampleRate, kWindow, {0.62, 0.0, 0.28, 0.0, 0.10});
        const auto first = estimate_hapt_pitch(samples, kSampleRate);
        const auto second = estimate_hapt_pitch(samples, kSampleRate);
        assert(first && second);
        assert(first->frequency_hz == second->frequency_hz);
        assert(first->confidence == second->confidence);
    }

    // HAPTTracker: a downward 1/2 or 1/3 harmonic jump is held for
    // `downward_harmonic_confirmations` frames before being accepted. A
    // constant, sustained RMS keeps the release detector inactive throughout
    // so these assertions isolate the harmonic-jump logic.
    {
        constexpr double sustained_rms = 0.2;
        HAPTConfig config;
        HAPTTracker tracker(config);
        const auto published = tracker.process(HAPTPitch{440.0, 0.9}, sustained_rms);
        assert(published && published->frequency_hz == 440.0);

        const auto held = tracker.process(HAPTPitch{220.0, 0.9}, sustained_rms);
        assert(held && held->frequency_hz == 440.0);

        const auto accepted = tracker.process(HAPTPitch{220.0, 0.9}, sustained_rms);
        assert(accepted && accepted->frequency_hz == 220.0);

        tracker.reset();
        assert(!tracker.published_frequency_hz());
        assert(!tracker.process(std::nullopt, sustained_rms));

        // An upward or ordinary movement (not a 1/2 or 1/3 relative) is
        // never held.
        assert(tracker.process(HAPTPitch{440.0, 0.9}, sustained_rms));
        const auto moved = tracker.process(HAPTPitch{493.88, 0.9}, sustained_rms);
        assert(moved && moved->frequency_hz == 493.88);
    }

    // HAPTTracker's RMS release detector: a genuine sharp release (two
    // consecutive >20% falls) suppresses publication even while the
    // estimator itself keeps reporting a plausible pitch, and a gentle
    // room-reverb-style decay (never a single sharp fall, but well below the
    // recent peak within a handful of frames) is caught by the same gate.
    {
        HAPTConfig config;
        HAPTTracker sharp_release_tracker(config);
        assert(sharp_release_tracker.process(HAPTPitch{330.0, 0.9}, 0.30));
        assert(sharp_release_tracker.process(HAPTPitch{330.0, 0.7}, 0.20));  // one fall, not yet armed
        assert(!sharp_release_tracker.process(HAPTPitch{330.0, 0.6}, 0.10));  // second fall arms it

        HAPTTracker gentle_decay_tracker(config);
        assert(gentle_decay_tracker.process(HAPTPitch{330.0, 0.9}, 0.30));
        bool suppressed_during_gentle_decay = false;
        double rms = 0.30;
        for (int step = 0; step < 20; ++step) {
            rms *= 0.90;  // well under the 20%-per-hop sharp-fall threshold
            const auto held = gentle_decay_tracker.process(HAPTPitch{330.0, 0.9}, rms);
            if (!held) {
                suppressed_during_gentle_decay = true;
                break;
            }
        }
        assert(suppressed_during_gentle_decay);
    }

    std::cout << "KlariVision Core HAPT tests passed.\n";
}
