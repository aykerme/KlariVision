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
    if (samples.size() <= 8 || frequency <= 0.0 || frequency >= rate / 2.0) return 0.0;  // too short a window, or frequency not representable
    const double denominator = static_cast<double>(samples.size() - 1);  // Hann window normaliser (N-1)
    const double step = 2.0 * std::numbers::pi * frequency / rate;       // per-sample phase increment of the probe frequency
    double cosine = 0.0;  // real part accumulator (correlation against cos reference)
    double sine = 0.0;    // imaginary part accumulator (correlation against sin reference)
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / denominator
        );  // Hann taper for this sample
        const double value = samples[index] * window;         // windowed sample
        const double phase = step * static_cast<double>(index);  // accumulated phase of the probe frequency at this sample
        cosine += value * std::cos(phase);  // project onto the cosine reference
        sine += value * std::sin(phase);    // project onto the sine reference
    }
    const double energy = cosine * cosine + sine * sine;  // squared magnitude of the (cosine, sine) probe response
    return 4.0 * std::sqrt(energy) / denominator;  // scaled back to an amplitude estimate at `frequency`
}

}  // namespace

HarmonicExistence spectral_existence(
    std::span<const float> samples,
    const double sample_rate,
    const double candidate_hz,
    const double maximum_frequency_hz
) {
    HarmonicExistence result;  // defaults: not a ghost, no dominant multiple found yet
    if (candidate_hz <= 0.0) return result;
    const double own = spectral_amplitude(samples, sample_rate, candidate_hz);  // how much real spectral energy the candidate itself has
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
    for (const double factor : {2.0, 3.0}) {  // check only the octave (2x) and twelfth (3x) multiples
        const double multiple_hz = candidate_hz * factor;      // frequency of this multiple
        if (multiple_hz > maximum_frequency_hz) continue;      // multiple is outside the analysable band, skip it
        const double multiple_amplitude = spectral_amplitude(samples, sample_rate, multiple_hz);  // real energy at the multiple
        if (multiple_amplitude <= 0.0) continue;  // no energy there either, so it can't explain away the candidate
        const double ratio = multiple_amplitude / std::max(own, 1e-9);  // how many times louder the multiple is than the candidate itself
        if (ratio > result.dominant_multiple_ratio) {
            result.dominant_multiple_ratio = ratio;   // keep the strongest dominance ratio seen
            result.dominant_multiple_hz = multiple_hz; // ...and which multiple produced it
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
    constexpr double kGhostRatioThreshold = 6.0;  // dominance ratio above which the candidate is declared a ghost
    result.is_ghost_subharmonic = result.dominant_multiple_ratio > kGhostRatioThreshold;  // final verdict
    return result;
}

}  // namespace klarivision::core
