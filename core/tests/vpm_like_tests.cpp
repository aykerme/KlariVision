#include "klarivision/core/vpm_like.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <vector>

using klarivision::core::estimate_vpm_like_pitch;
using klarivision::core::diagnose_vpm_like_pitch;
using klarivision::core::VPMLikePitch;
using klarivision::core::VPMLikeTracker;

namespace {

std::vector<double> tone(
    const double frequency,
    const double sample_rate,
    const int count,
    const double noise = 0.0
) {
    std::vector<double> result(count);
    for (int index = 0; index < count; ++index) {
        const auto phase = 2.0 * std::numbers::pi * frequency * index / sample_rate;
        const auto deterministic_noise = noise * std::sin(2.0 * std::numbers::pi * 1733.0 * index / sample_rate);
        // Fundamental plus clarinet-like odd harmonics.
        result[index] = 0.62 * std::sin(phase) +
            0.28 * std::sin(3.0 * phase) +
            0.10 * std::sin(5.0 * phase) + deterministic_noise;
    }
    return result;
}

std::vector<double> weak_fundamental_tone(
    const double frequency,
    const double sample_rate,
    const int count
) {
    std::vector<double> result(count);
    for (int index = 0; index < count; ++index) {
        const auto phase = 2.0 * std::numbers::pi * frequency * index / sample_rate;
        result[index] = 0.12 * std::sin(phase) +
            0.74 * std::sin(3.0 * phase) +
            0.14 * std::sin(5.0 * phase);
    }
    return result;
}

void expect_near(const double expected, const std::vector<double>& samples, const double sample_rate) {
    const auto result = estimate_vpm_like_pitch(samples, sample_rate);
    assert(result);
    const auto cents = std::abs(1200.0 * std::log2(result->frequency_hz / expected));
    assert(cents < 12.0);
}

}  // namespace

int main() {
    constexpr double sample_rate = 48000.0;
    // The live UI's low-latency window is 1,536 samples; the low clarinet
    // boundary must remain measurable without silently relying on a long
    // offline frame.
    expect_near(110.0, tone(110.0, sample_rate, 1536), sample_rate);
    expect_near(220.0, tone(220.0, sample_rate, 4096), sample_rate);
    // The blog's 1/3-family spectrum check exists for this exact failure:
    // autocorrelation can lock to a dominant third harmonic.
    expect_near(220.0, weak_fundamental_tone(220.0, sample_rate, 4096), sample_rate);
    expect_near(880.0, tone(880.0, sample_rate, 4096), sample_rate);
    expect_near(1173.0, tone(1173.0, sample_rate, 4096, 0.025), sample_rate);

    const auto diagnostic_samples = weak_fundamental_tone(220.0, sample_rate, 4096);
    const auto estimate = estimate_vpm_like_pitch(diagnostic_samples, sample_rate);
    const auto diagnostic = diagnose_vpm_like_pitch(diagnostic_samples, sample_rate);
    assert(estimate && diagnostic.pitch);
    assert(std::abs(estimate->frequency_hz - diagnostic.pitch->frequency_hz) < 1e-12);
    assert(std::abs(estimate->confidence - diagnostic.pitch->confidence) < 1e-12);
    assert(!diagnostic.autocorrelation_candidates.empty());
    assert(diagnostic.spectral_candidates.size() == 5);
    assert(diagnostic.decision == "selected_supported_spectral_candidate");
    // A weak fundamental is the legitimate correction case: ACF initially
    // selected an earlier near-strong 3f peak, not its strongest peak.
    assert(std::any_of(
        diagnostic.autocorrelation_candidates.begin(),
        diagnostic.autocorrelation_candidates.end(),
        [](const auto& candidate) { return candidate.selected && !candidate.strongest; }
    ));
    assert(std::count_if(
        diagnostic.spectral_candidates.begin(),
        diagnostic.spectral_candidates.end(),
        [](const auto& candidate) { return candidate.selected; }
    ) == 1);

    const std::vector<double> silence(4096, 0.0);
    assert(!estimate_vpm_like_pitch(silence, sample_rate));
    assert(diagnose_vpm_like_pitch(silence, sample_rate).decision ==
        "rejected_rms_below_minimum");

    // The shared gate rejects only values strictly below the configured RMS.
    // Alternating samples are already zero-mean, so their RMS is exact.
    klarivision::core::VPMLikeConfig rms_config;
    const auto alternating = [](const double amplitude) {
        std::vector<double> samples(4096);
        for (std::size_t index = 0; index < samples.size(); ++index) {
            samples[index] = index % 2 == 0 ? amplitude : -amplitude;
        }
        return samples;
    };
    assert(diagnose_vpm_like_pitch(alternating(0.0149), sample_rate, rms_config).decision ==
        "rejected_rms_below_minimum");
    assert(diagnose_vpm_like_pitch(alternating(0.0150), sample_rate, rms_config).decision !=
        "rejected_rms_below_minimum");
    assert(diagnose_vpm_like_pitch(alternating(0.0151), sample_rate, rms_config).decision !=
        "rejected_rms_below_minimum");

    // A short 1098 -> 549 Hz island with a much stronger surviving upper
    // line must not replace an established contour. This is deliberately a
    // veto rather than an extra fixed decision delay.
    VPMLikeTracker tracker;
    assert(tracker.process(VPMLikePitch{1098.7, 0.9}));
    for (int index = 0; index < 4; ++index) {
        const auto held = tracker.process(VPMLikePitch{549.35, 0.9}, 4.0);
        assert(held && std::abs(held->frequency_hz - 1098.7) < 0.1);
    }
    // When the old direct line is no longer dominant, retain the existing
    // three-frame ambiguity rule for a genuine lower note.
    tracker.reset();
    assert(tracker.process(VPMLikePitch{1098.7, 0.9}));
    for (int index = 0; index < 2; ++index) {
        const auto held = tracker.process(VPMLikePitch{549.35, 0.9}, 1.0);
        assert(held && std::abs(held->frequency_hz - 1098.7) < 0.1);
    }
    const auto accepted_lower = tracker.process(VPMLikePitch{549.35, 0.9}, 1.0);
    assert(accepted_lower && std::abs(accepted_lower->frequency_hz - 549.35) < 0.1);
    tracker.reset();
    assert(!tracker.process(std::nullopt));

    std::cout << "KlariVision Core VPM-like tests passed.\n";
}
