#include "klarivision/core/mpm.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace klarivision::core::v2 {

std::vector<PitchCandidate> mpm_candidates(
    const std::span<const float> samples,
    const double sample_rate,
    const double minimum_frequency_hz,
    const double maximum_frequency_hz,
    const double minimum_clarity
) {
    // Need at least one full analysis window, and the frequency band has to
    // make sense (max above min) before any lag math is meaningful.
    if (samples.size() < 1024 || sample_rate <= 0.0 ||
        minimum_frequency_hz <= 0.0 || maximum_frequency_hz <= minimum_frequency_hz) {
        return {};
    }

    // Remove the DC offset first: the NSDF below is an autocorrelation, and
    // any constant bias in the signal would inflate every lag's correlation
    // by the same amount, hiding the periodicity peaks we're looking for.
    const auto mean = std::accumulate(samples.begin(), samples.end(), 0.0) /   // average sample value = DC offset
        static_cast<double>(samples.size());
    std::vector<double> centred(samples.size());  // DC-free copy of the window, built below
    double energy = 0.0;                           // running sum of squares, used for the RMS gate
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centred[index] = static_cast<double>(samples[index]) - mean;  // subtract the DC offset from this sample
        energy += centred[index] * centred[index];                    // accumulate squared amplitude
    }
    const auto rms = std::sqrt(energy / static_cast<double>(samples.size()));  // root-mean-square loudness of the window
    // Silence/noise-floor gate: with essentially no signal energy, the NSDF
    // ratio below is a division of two near-zero numbers and produces
    // meaningless (often spuriously high) "pitch" candidates.
    if (rms <= 0.0001) {
        return {};
    }

    // Convert the requested frequency band into a lag (period, in samples)
    // search range: high frequency -> short lag, low frequency -> long lag.
    // The lag can never exceed half the window, or there would not be two
    // full periods left to compare against each other.
    const auto minimum_lag = std::max(2, static_cast<int>(sample_rate / maximum_frequency_hz));  // shortest period to test (highest pitch), floored at 2 samples
    const auto maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),               // never test a lag longer than half the window
        static_cast<int>(sample_rate / minimum_frequency_hz) // longest period to test (lowest pitch)
    );
    if (minimum_lag + 2 >= maximum_lag) {
        // Range too narrow to hold a real peak plus its two neighbours below.
        return {};
    }

    // Normalized Square Difference Function (McLeod & Wyvill's variant of
    // autocorrelation): for every candidate lag, correlate the signal with a
    // delayed copy of itself and normalise by the energy of both windows.
    // The result sits in roughly [-1, 1], where 1.0 means the waveform lines
    // up perfectly with itself after `lag` samples -- i.e. `lag` is (a
    // multiple of) the true period.
    std::vector<double> nsdf(static_cast<std::size_t>(maximum_lag + 1), 0.0);  // NSDF value per lag, indexed by lag itself
    for (auto lag = minimum_lag; lag <= maximum_lag; ++lag) {          // try every candidate period length...
        double correlation = 0.0;                                      // sum of leading*delayed products (raw autocorrelation at this lag)
        double normalisation = 0.0;                                    // sum of squared energies of both compared windows
        const auto count = static_cast<int>(centred.size()) - lag;     // how many sample pairs overlap at this lag
        for (auto index = 0; index < count; ++index) {                 // ...by sliding a copy of the signal `lag` samples over itself
            const auto leading = centred[static_cast<std::size_t>(index)];        // sample at time t
            const auto delayed = centred[static_cast<std::size_t>(index + lag)];  // sample at time t + lag
            correlation += leading * delayed;                          // accumulate the product (high when the two line up in phase)
            normalisation += leading * leading + delayed * delayed;    // accumulate combined energy for normalisation
        }
        if (normalisation > 1e-12) {  // guard against divide-by-near-zero on a near-silent sub-range
            nsdf[static_cast<std::size_t>(lag)] = 2.0 * correlation / normalisation;  // McLeod's NSDF normalisation formula
        }
    }

    // Peak picking: walk the NSDF curve and keep every local maximum whose
    // value clears `minimum_clarity`. Each such peak is a plausible
    // fundamental (or a harmonic/subharmonic of one); we deliberately return
    // all of them rather than just the tallest, so the caller's arbitration
    // logic can pick the musically correct one using other evidence.
    std::vector<PitchCandidate> candidates;
    for (auto lag = minimum_lag + 1; lag < maximum_lag; ++lag) {   // scan interior lags (need both neighbours to test for a peak)
        const auto previous = nsdf[static_cast<std::size_t>(lag - 1)];  // NSDF one lag before
        const auto current = nsdf[static_cast<std::size_t>(lag)];       // NSDF at this lag
        const auto next = nsdf[static_cast<std::size_t>(lag + 1)];      // NSDF one lag after
        if (current < minimum_clarity || current < previous || current <= next) {
            // Reject: either too weak to trust, or not a local maximum
            // (still rising, or already past the true peak).
            continue;
        }

        // Parabolic interpolation around the integer-lag peak: fit a
        // parabola through (previous, current, next) and solve for its
        // vertex. This recovers a sub-sample-accurate lag estimate instead
        // of being limited to whole-sample resolution, which matters a lot
        // at high fundamental frequencies where one sample of lag error is
        // a large relative pitch error.
        const auto denominator = previous - 2.0 * current + next;  // parabola's curvature term (second derivative)
        const auto correction = std::abs(denominator) > 1e-9
            ? std::clamp(0.5 * (previous - next) / denominator, -0.5, 0.5)  // sub-sample offset from the integer lag, clamped to +/-0.5 sample
            : 0.0;                                                          // near-flat curvature: no reliable correction, keep the integer lag
        const auto refined_lag = static_cast<double>(lag) + correction;  // sub-sample-accurate period estimate
        const auto frequency = sample_rate / refined_lag;                // period -> frequency conversion
        if (!std::isfinite(frequency) || frequency < minimum_frequency_hz ||
            frequency > maximum_frequency_hz) {
            // Interpolation nudged the estimate outside the requested band; drop it.
            continue;
        }
        // The NSDF peak height itself doubles as the candidate's confidence
        // ("periodicity"/clarity); onset-related evidence is not available
        // at this stage, so it is left at 0.0 for the caller to fill in.
        candidates.push_back(PitchCandidate{
            frequency,                       // refined fundamental-frequency estimate, in Hz
            std::clamp(current, 0.0, 1.0),   // NSDF peak height used as the confidence/clarity score
            0.0,                              // no onset evidence computed here; left for the caller
            CandidateSource::mpm,             // tag so downstream arbitration knows this came from MPM
        });
    }

    // Strongest (most periodic) candidates first, and cap the list so a
    // noisy window with many weak peaks can't blow up downstream arbitration
    // cost.
    std::sort(candidates.begin(), candidates.end(), [](const auto& left, const auto& right) {
        return left.periodicity > right.periodicity;  // descending by confidence
    });
    if (candidates.size() > 12) {
        candidates.resize(12);  // keep only the 12 strongest peaks
    }
    return candidates;
}

}  // namespace klarivision::core::v2
