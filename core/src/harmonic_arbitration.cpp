#include "klarivision/core/harmonic_arbitration.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>

namespace klarivision::core {
namespace {

// Same Hann-windowed single-frequency amplitude estimate used by the YIN
// and VPM-like spectral-repair passes elsewhere in this codebase. Kept
// local so this file has no dependency on their internals -- this module
// must stay pure and stateless to be shared, and later mirrored in Swift,
// across all three engines.
double spectral_amplitude(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8 || frequency <= 0.0 || frequency >= rate / 2.0) return 0.0;
    const double denominator = static_cast<double>(samples.size() - 1);
    const double step = 2.0 * std::numbers::pi * frequency / rate;
    double cosine = 0.0;
    double sine = 0.0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / denominator
        );
        const double value = samples[index] * window;
        const double phase = step * static_cast<double>(index);
        cosine += value * std::cos(phase);
        sine += value * std::sin(phase);
    }
    const double energy = cosine * cosine + sine * sine;
    return 4.0 * std::sqrt(energy) / denominator;
}

}  // namespace

HarmonicExistence spectral_existence(
    std::span<const float> samples,
    const double sample_rate,
    const double candidate_hz,
    const double maximum_frequency_hz
) {
    HarmonicExistence result;
    if (candidate_hz <= 0.0) return result;
    const double own = spectral_amplitude(samples, sample_rate, candidate_hz);
    // Deliberately limited to 2x/3x, the two ambiguities autocorrelation
    // estimators actually produce on this instrument (octave and twelfth).
    // A wider search (checked and reverted: see git history) also catches
    // sub-periods of a sub-period, but a comparison against a multiple that
    // is *itself* not the true fundamental's real content produces false
    // positives on legitimate high notes whose own CMND ladder is strong at
    // several integer sub-multiples. Chasing the ghost chain further than
    // one hop belongs in a recursive caller that already has candidate
    // context (see `analysis_engine.cpp`'s corroboration checks), not in
    // this stateless per-frequency probe.
    for (const double factor : {2.0, 3.0}) {
        const double multiple_hz = candidate_hz * factor;
        if (multiple_hz > maximum_frequency_hz) continue;
        const double multiple_amplitude = spectral_amplitude(samples, sample_rate, multiple_hz);
        if (multiple_amplitude <= 0.0) continue;
        const double ratio = multiple_amplitude / std::max(own, 1e-9);
        if (ratio > result.dominant_multiple_ratio) {
            result.dominant_multiple_ratio = ratio;
            result.dominant_multiple_hz = multiple_hz;
        }
    }
    // A weak-but-real clarinet fundamental can still trail its own third
    // harmonic by several times over (measured as low as ~3x on a
    // legitimately soft, sustained fundamental); a genuine autocorrelation
    // ghost measured on the recording that motivated this check reached
    // ~8x even at its most transient, ambiguous frame, and the clean
    // sustained case reached ~24-27x. The threshold sits between the two
    // clusters, closer to the weak-but-real side so a real transient ghost
    // is still caught.
    constexpr double kGhostRatioThreshold = 6.0;
    result.is_ghost_subharmonic = result.dominant_multiple_ratio > kGhostRatioThreshold;
    return result;
}

}  // namespace klarivision::core
