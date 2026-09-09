#include "klarivision/core/harmonic_evidence.hpp"

#include "klarivision/core/harmonic_arbitration.hpp"
#include "klarivision/core/swipe_prime.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <optional>
#include <vector>

namespace klarivision::core {
namespace {

constexpr std::size_t kFamilyRatioCount = std::size(unified::kHarmonicFamilyRatios);

// ---------------------------------------------------------------------------
// Shared small helpers
// ---------------------------------------------------------------------------

// How many harmonics of `f` fit under the analysis ceiling, capped at 16 --
// beyond that, higher partials are dominated by noise on every instrument
// this engine sees and add more variance than signal.
std::size_t harmonic_count(const double f, const double maximum_hz) {
    if (f <= 0.0) {
        return 0;
    }
    return std::min<std::size_t>(16, static_cast<std::size_t>(std::floor(maximum_hz / f)));
}

// Parity is measured from spectral energy at k*f for k = 2..K, so the
// contract's "harmonics separated from neighbours by more than
// 1.5 * resolution_half_width_hz()" collapses to a single check: every
// consecutive pair of harmonics is exactly `f` apart, so either all of them
// clear the resolution guard or none do.
double spectral_parity_index(const FrameSpectrum& spectrum, const double f) {
    const auto K = harmonic_count(
        f, std::min(f * static_cast<double>(unified::kMinimumScoredPartials * 2),
                    unified::kSpectralAnalysisMaximumHz));
    if (K < 2 || f <= 1.5 * spectrum.resolution_half_width_hz()) {
        return 0.0;  // too few harmonics representable, or they'd blur into each other
    }
    double odd_energy = 0.0;
    double even_energy = 0.0;
    for (std::size_t k = 2; k <= K; ++k) {
        const double amplitude = spectrum.amplitude_at(static_cast<double>(k) * f);
        const double energy = amplitude * amplitude;
        if (k % 2 == 0) {
            even_energy += energy;
        } else {
            odd_energy += energy;
        }
    }
    constexpr double epsilon = 1e-9;
    return (odd_energy - even_energy) / (odd_energy + even_energy + epsilon);
}

// A(f) / max(A(2f), A(3f)), clamped to [0, 4]. When neither multiple carries
// measurable energy there is nothing for the candidate to be a ghost *of*,
// so it is scored as fully present rather than producing a 0/0 NaN.
double fundamental_presence_at(const FrameSpectrum& spectrum, const double f) {
    const double own = spectrum.amplitude_at(f);
    const double second = spectrum.amplitude_at(2.0 * f);
    const double third = spectrum.amplitude_at(3.0 * f);
    const double denominator = std::max(second, third);
    if (denominator <= 1e-12) {
        return 4.0;
    }
    return std::clamp(own / denominator, 0.0, 4.0);
}

// Same graded ghost-penalty curve as analysis_engine.cpp's
// ghost_subharmonic_penalty: a hard cutoff would let a merely-soft, real
// fundamental and a genuine autocorrelation ghost collide at the same
// boundary, so the penalty ramps in over a dominance-ratio span instead.
constexpr double kGhostRatioFloor = 6.0;
constexpr double kGhostRatioSpan = 20.0;
constexpr double kGhostMaxPenalty = 0.15;

double ghost_penalty_at(
    std::span<const float> samples,
    const double sample_rate,
    const double f,
    const double maximum_hz
) {
    const auto existence = spectral_existence(samples, sample_rate, f, maximum_hz);
    if (!existence.is_ghost_subharmonic) {
        return 0.0;
    }
    const double severity = std::clamp(
        (existence.dominant_multiple_ratio - kGhostRatioFloor) / kGhostRatioSpan, 0.0, 1.0
    );
    return kGhostMaxPenalty * severity;
}

}  // namespace

// A candidate's own predicted series is internally incoherent when it goes
// silent across a run of kSeriesCoherenceMinimumGapRun or more consecutive
// partials and then carries real energy again further up -- see
// unified_pitch_constants.hpp for the measured GCD-ghost case this exists
// to catch and the two design constraints (run length, relative threshold)
// that keep a clarinet's ordinary alternating odd/even series out of it.
// k = 1 (the fundamental) is excluded from the scan for the same reason
// TWM forgives it in `twm_error`: its absence is a property of the source's
// radiation, not evidence against the candidate.
//
// Exposed publicly (rather than kept file-local) so the live path can apply
// this exact same check to an already-decoded candidate once its lookahead
// audio has genuinely arrived -- see UnifiedPitchSession's lookahead buffer
// in unified_pitch_session.cpp, which retroactively vetoes a low-register
// winner the fixed-lag decoder already chose, using the same criterion
// `score_harmonic_evidence` applies offline.
bool has_series_incoherence(const FrameSpectrum& spectrum, const double f, const double maximum_hz) {
    const auto K = std::min(harmonic_count(f, maximum_hz), unified::kSeriesCoherenceCheckPartials);
    // Need at least a present partial, a qualifying gap, and a present
    // partial afterwards -- five slots (k = 2..6) is the smallest window
    // that can represent that.
    if (K < 5) {
        return false;
    }

    std::vector<double> amplitude(K + 1, 0.0);
    double loudest = 0.0;
    for (std::size_t k = 2; k <= K; ++k) {
        amplitude[k] = spectrum.amplitude_at(static_cast<double>(k) * f);
        loudest = std::max(loudest, amplitude[k]);
    }
    if (loudest <= 1e-12) {
        return false;  // nothing measurable in the checked window at all
    }

    // A GCD ghost's loudest "partial" is another real note, so it towers over
    // the ghost's own fundamental. A genuine low note does not behave that
    // way. Requiring this before the gap scan is what keeps the veto off the
    // innocent low notes that overlapping sources fill with holes -- see
    // kSeriesCoherenceFundamentalDominanceRatio for the measurement.
    const double fundamental = spectrum.amplitude_at(f);
    if (loudest < unified::kSeriesCoherenceFundamentalDominanceRatio * fundamental) {
        return false;
    }

    const double floor = unified::kSeriesCoherencePresenceRatio * loudest;
    std::size_t silent_run = 0;
    for (std::size_t k = 2; k <= K; ++k) {
        if (amplitude[k] < floor) {
            ++silent_run;
            continue;
        }
        if (silent_run >= unified::kSeriesCoherenceMinimumGapRun) {
            return true;  // a real partial reappeared after a multi-partial hole
        }
        silent_run = 0;
    }
    return false;
}

namespace {

// ---------------------------------------------------------------------------
// Two-way mismatch (Maher & Beauchamp, JASA 1994)
// ---------------------------------------------------------------------------

// Local maxima of the magnitude spectrum, refined by parabolic
// interpolation across the three bins straddling each peak. This is a
// light peak picker, not a tracker: TWM only needs approximate peak
// *locations* to compare a candidate's predicted harmonic series against.
std::vector<double> pick_spectral_peaks(const FrameSpectrum& spectrum, const double maximum_hz) {
    std::vector<double> peaks;
    if (spectrum.fft_size == 0 || spectrum.magnitude.size() < 3 || spectrum.sample_rate <= 0.0) {
        return peaks;
    }
    const double bin_hz = spectrum.sample_rate / static_cast<double>(spectrum.fft_size);
    const double loudest = *std::max_element(spectrum.magnitude.begin(), spectrum.magnitude.end());
    if (loudest <= 0.0) {
        return peaks;
    }
    // -34 dB below the loudest bin: generous enough to keep a soft
    // fundamental (a clarinet's can trail its own third harmonic by an
    // order of magnitude, see harmonic_arbitration.hpp) while dropping FFT
    // noise-floor wiggle.
    const double floor_magnitude = loudest * 0.02;
    for (std::size_t index = 1; index + 1 < spectrum.magnitude.size(); ++index) {
        const double frequency = static_cast<double>(index) * bin_hz;
        if (frequency > maximum_hz) {
            break;
        }
        const double left = spectrum.magnitude[index - 1];
        const double centre = spectrum.magnitude[index];
        const double right = spectrum.magnitude[index + 1];
        if (centre < floor_magnitude || centre < left || centre < right) {
            continue;
        }
        const double denominator = left - 2.0 * centre + right;
        const double offset = (denominator != 0.0) ? 0.5 * (left - right) / denominator : 0.0;
        peaks.push_back((static_cast<double>(index) + offset) * bin_hz);
    }
    return peaks;
}

// Distance from `target_hz` to the nearest entry of `others`, relative to
// `target_hz` itself so the result is a scale-invariant fraction rather
// than raw Hz -- a 20 Hz miss means very different things at 80 Hz and at
// 1600 Hz. An empty comparison set (no measured peaks at all, or a
// predicted harmonic with nothing nearby) saturates at 1.0, the same order
// of magnitude a genuinely absent partial would produce anyway.
double relative_mismatch(const double target_hz, const std::vector<double>& others) {
    if (others.empty() || target_hz <= 0.0) {
        return 1.0;
    }
    double best = std::numeric_limits<double>::infinity();
    for (const double other : others) {
        best = std::min(best, std::abs(other - target_hz));
    }
    return std::min(1.0, best / target_hz);
}

// E_twm = kTwmMeasuredWeight * E_m2p + kTwmPredictedWeight * E_p2m.
//
// E_m2p (measured -> predicted) is unweighted: every measured spectral peak
// is checked against the nearest predicted harmonic, regardless of which
// harmonic number that turns out to be.
//
// E_p2m (predicted -> measured) is parity-weighted: odd predicted
// harmonics always cost full price (this is what still kills an f/3
// ghost -- its odd-indexed predictions above 3f find no measured peak no
// matter how convincingly its even multiples of the true fundamental line
// up), while even harmonics are discounted by `parity.even_partial_weight()`
// once the running estimate is confidently clarinet-like. This second
// direction is also what kills octave errors: a candidate an octave below
// the truth explains every measured peak with its even harmonics, but its
// own odd-indexed predictions (1.5x, 2.5x, ... times the true fundamental)
// find nothing.
double twm_error(
    const double f,
    const double maximum_hz,
    const std::vector<double>& measured_peaks,
    const ParityEstimate& parity
) {
    const auto K = harmonic_count(f, maximum_hz);
    if (K == 0) {
        return 1.0;  // candidate itself is not representable: maximal error
    }

    double e_m2p = 0.0;
    if (!measured_peaks.empty()) {
        std::vector<double> predicted(K);
        for (std::size_t k = 1; k <= K; ++k) {
            predicted[k - 1] = static_cast<double>(k) * f;
        }
        for (const double peak : measured_peaks) {
            const double mismatch = relative_mismatch(peak, predicted);
            e_m2p += mismatch * mismatch;
        }
        e_m2p /= static_cast<double>(measured_peaks.size());
    } else {
        e_m2p = 1.0;  // nothing measured at all: no support for this candidate
    }

    double e_p2m = 0.0;
    double weight_sum = 0.0;
    for (std::size_t k = 1; k <= K; ++k) {
        // k == 1 is the fundamental, forgiven for the reason recorded beside
        // kFundamentalPartialWeight: its absence is a property of the source's
        // radiation, not evidence that the pitch is wrong. Every other odd
        // partial keeps full weight, and that is what still refuses a
        // subharmonic, whose own odd partials have nothing behind them.
        const double weight = (k == 1)         ? unified::kFundamentalPartialWeight
                            : (k % 2 == 0)     ? parity.even_partial_weight()
                                               : 1.0;
        const double mismatch = relative_mismatch(static_cast<double>(k) * f, measured_peaks);
        e_p2m += weight * mismatch * mismatch;
        weight_sum += weight;
    }
    if (weight_sum > 0.0) {
        e_p2m /= weight_sum;
    }

    return unified::kTwmMeasuredWeight * e_m2p + unified::kTwmPredictedWeight * e_p2m;
}

double twm_score_at(
    const double f,
    const double maximum_hz,
    const std::vector<double>& measured_peaks,
    const ParityEstimate& parity
) {
    return std::exp(-twm_error(f, maximum_hz, measured_peaks, parity) / unified::kTwmScale);
}

}  // namespace

double ParityEstimate::even_partial_weight() const {
    // Gated here, not on `index` itself, so the raw EMA keeps converging
    // underneath during warm-up even though nothing downstream sees it yet:
    // by the time `warm()` flips true the estimate is already at its
    // steady-state value instead of starting a fresh climb from 0.
    if (!warm()) {
        return 1.0;  // fully generic TWM: every partial costs full price
    }
    return std::clamp(1.0 - index, unified::kMinimumEvenWeight, 1.0);
}

bool ParityEstimate::warm() const {
    return samples >= unified::kParityWarmupFrames;
}

double cents_between(const double reference_hz, const double frequency_hz) {
    if (reference_hz <= 0.0 || frequency_hz <= 0.0) {
        return 0.0;
    }
    return 1200.0 * std::log2(frequency_hz / reference_hz);
}

bool is_harmonic_relationship(const double signed_cents) {
    for (const double target : unified::kHarmonicTargetCents) {
        if (std::abs(signed_cents - target) <= unified::kHarmonicToleranceCents) {
            return true;
        }
    }
    return false;
}

void update_parity_estimate(
    ParityEstimate& parity,
    const MultiResolutionSpectra& spectra,
    const double committed_frequency_hz,
    const double sample_rate
) {
    (void)sample_rate;  // sample rate is already baked into `spectra`; kept for interface symmetry
    const auto& spectrum = spectra.for_frequency(committed_frequency_hz);
    const double rho = spectral_parity_index(spectrum, committed_frequency_hz);
    // Plain EMA: index += alpha * (rho - index). Starting from the
    // struct's default of 0.0, a steadily odd-rich source (rho ~= 1) climbs
    // to 1 - (1 - alpha)^n; with kParityEmaAlpha = 0.15 that lands at ~0.73
    // after exactly kParityWarmupFrames (8) commits -- inside the "warm
    // clarinet" range by design, not by coincidence.
    parity.index += unified::kParityEmaAlpha * (rho - parity.index);
    parity.samples += 1;
}

void note_unvoiced_frame(ParityEstimate& parity) {
    // The struct is frozen at {index, samples}, so silence is modelled by
    // decaying both fields toward what a fresh, never-updated estimate
    // looks like, instead of adding a separate silence counter. `index` is
    // stepped toward 0 by a fixed 1/kParitySilenceResetFrames of the full
    // [-1, 1] range per call (not a multiplicative decay, which only ever
    // approaches 0 asymptotically) so a run of exactly
    // kParitySilenceResetFrames (40) silent frames returns it to exactly
    // 0, matching `samples` being walked back down by 1 each call.
    const double step = 1.0 / static_cast<double>(unified::kParitySilenceResetFrames);
    if (parity.index > 0.0) {
        parity.index = std::max(0.0, parity.index - step);
    } else if (parity.index < 0.0) {
        parity.index = std::min(0.0, parity.index + step);
    }
    parity.samples = (parity.samples > 0) ? parity.samples - 1 : 0;
}

namespace {

/// Per-candidate analysis ceiling: enough headroom for kMinimumScoredPartials
/// of this candidate, never below the shared floor and never above what the
/// sample rate can actually resolve.
double analysis_limit_for(
    const double frequency_hz, const double base_limit_hz, const double sample_rate
) {
    const auto nyquist = 0.5 * sample_rate * unified::kSpectralAnalysisHeadroom;
    const auto wanted =
        frequency_hz * static_cast<double>(unified::kMinimumScoredPartials);
    return std::min(std::max(base_limit_hz, wanted), nyquist);
}

}  // namespace

std::vector<HarmonicEvidence> score_harmonic_evidence(
    const std::span<const float> history,
    const MultiResolutionSpectra& spectra,
    const double sample_rate,
    const std::span<const double> candidate_frequencies_hz,
    const ParityEstimate& parity,
    const double maximum_analysis_frequency_hz,
    const std::span<const float> lookahead_samples
) {
    const std::size_t candidate_count = candidate_frequencies_hz.size();
    std::vector<HarmonicEvidence> evidence(candidate_count);
    if (candidate_count == 0) {
        return evidence;
    }

    // Peak picking is the expensive part of TWM and there are only three
    // bands no matter how many candidates (or harmonic-family competitors,
    // below) get scored against them, so it happens exactly once per band
    // per call.
    auto peak_limit = maximum_analysis_frequency_hz;
    for (const auto frequency : candidate_frequencies_hz) {
        peak_limit = std::max(
            peak_limit, analysis_limit_for(frequency, maximum_analysis_frequency_hz, sample_rate)
        );
    }
    const auto low_peaks = pick_spectral_peaks(spectra.low, peak_limit);
    const auto mid_peaks = pick_spectral_peaks(spectra.mid, peak_limit);
    const auto high_peaks = pick_spectral_peaks(spectra.high, peak_limit);
    const auto peaks_for = [&](const FrameSpectrum& band) -> const std::vector<double>& {
        if (&band == &spectra.low) {
            return low_peaks;
        }
        if (&band == &spectra.mid) {
            return mid_peaks;
        }
        return high_peaks;
    };

    // swipe_prime_harmonic_supports compresses the whole spectrum once per
    // call regardless of how many frequencies it scores, so every
    // SWIPE'-prime score this function will need -- the candidates
    // themselves, plus every in-range harmonic-family competitor used by
    // family_margin below -- is batched into a single combined call rather
    // than one call per frequency.
    std::vector<double> combined_frequencies(
        candidate_frequencies_hz.begin(), candidate_frequencies_hz.end()
    );
    std::vector<std::array<int, kFamilyRatioCount>> family_positions(candidate_count);
    for (std::size_t i = 0; i < candidate_count; ++i) {
        const double f = candidate_frequencies_hz[i];
        for (std::size_t r = 0; r < kFamilyRatioCount; ++r) {
            const double related = f * unified::kHarmonicFamilyRatios[r];
            if (related >= unified::kEstimatorMinimumHz && related <= unified::kEstimatorMaximumHz) {
                family_positions[i][r] = static_cast<int>(combined_frequencies.size());
                combined_frequencies.push_back(related);
            } else {
                family_positions[i][r] = -1;  // outside the representable range: not a real competitor
            }
        }
    }
    // The 5000 Hz default leaves a 1760 Hz candidate only two partials of
    // evidence (see unified_pitch_constants.hpp), handing the frame to its
    // subharmonic -- kSpectralAnalysisMaximumHz (8000) is passed explicitly
    // rather than relying on that default.
    // The low band, not the per-candidate band: SWIPE' scores a candidate
    // against its own partials, so the window has to resolve the *lowest*
    // frequency in the batch (family competitors reach down to
    // kEstimatorMinimumHz), and the low band is the full history window --
    // the same span this used to transform for itself before the kernel was
    // folded onto FrameSpectrum.
    const auto combined_supports = v2::swipe_prime_harmonic_supports(
        spectra.low, combined_frequencies, unified::kSpectralAnalysisMaximumHz
    );

    // Built at most once per call, and only if a low-register candidate
    // actually needs it: the series-coherence veto is the one piece of
    // evidence in this function allowed to look past `history`'s newest
    // sample (see kSeriesCoherenceLookaheadSamples), so it gets its own
    // spectrum rather than reusing spectra.low, which is causal by
    // construction. Low-register only, matching the measured failure mode
    // -- a common subharmonic of two higher notes only lands as low as
    // kLowRegisterHz in the first place, and mid/high candidates already
    // have enough partials in view for TWM's own averaging to catch a
    // comparable inconsistency.
    //
    // Built from `lookahead_samples` alone, not history + lookahead: the
    // whole reason this spectrum exists is that the causal window has
    // already been measured (see kSeriesCoherenceLookaheadSamples) to not
    // show the gap-and-recovery pattern yet, so folding it back in bought
    // nothing but a second, larger transform -- halving the FFT size here
    // was worth about half the added cost of this check on the frozen
    // holdout.
    std::optional<FrameSpectrum> coherence_spectrum;
    const auto coherence_spectrum_for = [&](const double f) -> const FrameSpectrum* {
        if (f >= unified::kLowRegisterHz || lookahead_samples.empty()) {
            return nullptr;
        }
        if (!coherence_spectrum) {
            coherence_spectrum = compute_frame_spectrum(lookahead_samples, sample_rate, AnalysisBand::low);
        }
        return &*coherence_spectrum;
    };

    for (std::size_t i = 0; i < candidate_count; ++i) {
        const double f = candidate_frequencies_hz[i];
        HarmonicEvidence& out = evidence[i];
        out.swipe_prime_support = combined_supports[i];

        const auto& primary_band = spectra.for_frequency(f);
        const auto limit = analysis_limit_for(f, maximum_analysis_frequency_hz, sample_rate);
        out.twm_score = twm_score_at(f, limit, peaks_for(primary_band), parity);
        out.fundamental_presence = fundamental_presence_at(primary_band, f);
        // Diagnostic only: measured at this *candidate*, never fed back
        // into the running ParityEstimate. An f/3 ghost sees the real
        // fundamental as its own third partial, so it would measure as
        // odd-rich and manufacture its own excuse for the even partials it
        // is missing -- exactly the failure mode ParityEstimate exists to
        // avoid, which is why it is only ever updated from a committed,
        // high-posterior frequency (see update_parity_estimate).
        out.parity_index = spectral_parity_index(primary_band, f);
        // See coherence_spectrum_for above: nullptr (so series_incoherent
        // stays false) for any mid/high candidate, and for every candidate
        // at all when no lookahead was supplied -- i.e. always, on the live
        // path. Also bounded to the first kSeriesCoherenceCandidateLimit
        // entries -- see that constant for why an FFT-per-candidate cost is
        // not affordable here and why the callers' probability-descending
        // order makes that bound safe.
        if (i < unified::kSeriesCoherenceCandidateLimit) {
            if (const auto* coherence = coherence_spectrum_for(f)) {
                out.series_incoherent = has_series_incoherence(*coherence, f, limit);
            }
        }

        out.band_blended = spectra.is_band_edge(f);
        if (out.band_blended) {
            const auto& partner_band = spectra.blend_partner(f);
            const double partner_twm = twm_score_at(
                f, limit, peaks_for(partner_band), parity
            );
            const double partner_presence = fundamental_presence_at(partner_band, f);
            const double partner_parity = spectral_parity_index(partner_band, f);
            out.twm_score = 0.5 * (out.twm_score + partner_twm);
            out.fundamental_presence = 0.5 * (out.fundamental_presence + partner_presence);
            out.parity_index = 0.5 * (out.parity_index + partner_parity);
        }

        out.ghost_penalty = ghost_penalty_at(history, sample_rate, f, limit);

        // family_margin = score(f) - max over the harmonic family of
        // score(f * ratio), with score = swipe_prime_support * twm_score --
        // the same two independent pieces of evidence combined, so a
        // relative only wins the comparison by actually fitting the
        // spectrum better, not merely by being spectrally louder.
        const double own_score = out.swipe_prime_support * out.twm_score;
        double best_family_score = 0.0;  // no in-range relative: nothing to lose to
        for (std::size_t r = 0; r < kFamilyRatioCount; ++r) {
            const int position = family_positions[i][r];
            if (position < 0) {
                continue;
            }
            const double related_hz = combined_frequencies[static_cast<std::size_t>(position)];
            const auto& related_band = spectra.for_frequency(related_hz);
            const double related_twm = twm_score_at(
                related_hz,
                analysis_limit_for(related_hz, maximum_analysis_frequency_hz, sample_rate),
                peaks_for(related_band), parity
            );
            const double related_score =
                combined_supports[static_cast<std::size_t>(position)] * related_twm;
            best_family_score = std::max(best_family_score, related_score);
        }
        out.family_margin = own_score - best_family_score;
    }

    return evidence;
}

}  // namespace klarivision::core
