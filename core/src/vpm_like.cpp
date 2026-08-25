#include "klarivision/core/vpm_like.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <numeric>
#include <vector>

namespace klarivision::core {
namespace {

// Pitch distance between two frequencies, in cents (1200 cents = one octave).
double cents_between(const double left, const double right) {
    return 1200.0 * std::log2(left / right);
}

// Detects a suspicious downward jump that looks like a harmonic-tracking
// error: `current` fell far enough below `previous` (>= 650 cents, roughly
// half an octave) *and* the ratio current/previous sits close to one of the
// classic subharmonic ratios (1/3, 1/2, 2/3). This is the trigger the
// hysteresis logic below uses to decide whether to trust a new, lower
// estimate immediately or wait for it to be confirmed across frames.
bool is_downward_harmonic_jump(const double previous, const double current) {
    if (current >= previous || std::abs(cents_between(current, previous)) < 650.0) {
        return false;  // not a downward jump, or too small to be a harmonic-tracking error
    }
    for (const auto ratio : {1.0 / 3.0, 0.5, 2.0 / 3.0}) {  // 1/3, 1/2 and 2/3 are the ratios a mistracked harmonic would produce
        if (std::abs(cents_between(current / previous, ratio)) <= 110.0) {
            return true;  // ratio matches one of the suspicious values closely enough
        }
    }
    return false;  // a big drop, but not to a recognisable subharmonic ratio
}

// Sub-sample-accurate peak location via parabolic interpolation: fits a
// parabola through three consecutive samples of `values` around `index` and
// returns the (fractional) index of its vertex. Falls back to the plain
// integer index at the array edges or when the samples are too flat to fit
// a meaningful parabola.
double parabolic_peak(const std::vector<double>& values, const int index) {
    if (index <= 0 || index + 1 >= static_cast<int>(values.size())) {
        return static_cast<double>(index);  // no room for both neighbours, can't interpolate
    }
    const auto left = values[index - 1];
    const auto middle = values[index];
    const auto right = values[index + 1];
    const auto denominator = left - 2.0 * middle + right;  // curvature of the parabola through the three points
    if (std::abs(denominator) < 1e-12) {
        return static_cast<double>(index);  // effectively flat, interpolation would be unstable
    }
    return static_cast<double>(index) +
        std::clamp(0.5 * (left - right) / denominator, -0.5, 0.5);  // vertex offset from `index`, clamped to +/-0.5
}

// Single-frequency Hann-windowed spectral amplitude probe (same family of
// computation as harmonic_probe.cpp's hann_windowed_probe, but window-power
// normalised instead of length-normalised) used by the spectral-relative
// correction pass below to compare candidate frequencies directly in the
// real spectrum.
double spectral_amplitude(
    const std::span<const double> samples,
    const double sample_rate,
    const double frequency
) {
    if (samples.size() < 8 || frequency <= 0.0 || frequency >= sample_rate / 2.0) {
        return 0.0;  // window too short, or frequency not representable
    }
    const auto denominator = static_cast<double>(samples.size() - 1);  // Hann window normaliser (N-1)
    const auto step = 2.0 * std::numbers::pi * frequency / sample_rate;  // per-sample phase increment of the probe frequency
    double real = 0.0;         // correlation against the cosine reference
    double imaginary = 0.0;    // correlation against the sine reference
    double window_sum = 0.0;   // total window weight applied, used to normalise the result
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / denominator
        );  // Hann taper for this sample
        const auto value = samples[index] * window;               // windowed sample
        const auto phase = step * static_cast<double>(index);     // accumulated phase of the probe frequency at this sample
        real += value * std::cos(phase);
        imaginary += value * std::sin(phase);
        window_sum += window;  // accumulate the window's own total weight
    }
    return window_sum > 0.0 ? 2.0 * std::hypot(real, imaginary) / window_sum : 0.0;  // magnitude of the (real, imaginary) probe, normalised by window weight
}

}  // namespace

VPMLikeTracker::VPMLikeTracker(const int downward_harmonic_confirmations)
    : required_confirmations_(std::max(1, downward_harmonic_confirmations)) {}  // at least one confirming frame is always required

// Frame-to-frame hysteresis state machine: decides whether to publish a new
// per-frame pitch estimate immediately, or to keep repeating the last
// published pitch while a suspicious downward jump waits to be confirmed
// across several consecutive frames. This is what stops a single noisy
// frame from making the displayed pitch drop an octave for an instant.
std::optional<VPMLikePitch> VPMLikeTracker::process(
    std::optional<VPMLikePitch> estimate,
    const std::optional<double> established_upper_to_estimate_ratio
) {
    if (!estimate) {
        reset();  // no pitch this frame (silence/unvoiced): clear all tracking state
        return std::nullopt;
    }
    if (!published_) {
        published_ = estimate;  // first-ever estimate: nothing to compare against, publish it directly
        return estimate;
    }
    if (!is_downward_harmonic_jump(published_->frequency_hz, estimate->frequency_hz)) {
        // Ordinary frame-to-frame movement (not a suspicious harmonic drop):
        // publish immediately and clear any pending confirmation streak.
        pending_.reset();
        pending_confirmations_ = 0;
        published_ = estimate;
        return estimate;
    }

    // A brief f/2 island can have enough absolute spectrum to pass the frame
    // estimator even though the established direct line remains much louder.
    // Keep that contour while it has a clear 2.5x direct-line amplitude
    // advantage.  This is a causal veto, not a spectral promotion: a true
    // lower attack loses that old direct line and uses the normal confirmation
    // path below without looking at a future frame.
    const auto upper_is_dominant = established_upper_to_estimate_ratio &&
        *established_upper_to_estimate_ratio >= 2.5;  // the old higher contour is at least 2.5x louder than this new lower estimate
    if (upper_is_dominant) {
        // Veto outright: keep publishing the old (higher) contour, since it
        // is clearly still the dominant spectral content this frame.
        pending_.reset();
        pending_confirmations_ = 0;
        return VPMLikePitch{published_->frequency_hz, std::min(estimate->confidence, 0.55)};  // republish old pitch, confidence capped since this frame disagreed
    }
    // The prior high contour is still a real spectral peak.  Treat a lower
    // 1/2 or 1/3 estimate as ambiguous until it persists; this is a veto, not
    // spectral promotion, so D-011 remains intact.
    const auto upper_is_supported = established_upper_to_estimate_ratio.has_value();
    if (!upper_is_supported) {
        // No competing upper contour evidence at all: nothing to veto
        // against, so accept the new lower estimate immediately.
        pending_.reset();
        pending_confirmations_ = 0;
        published_ = estimate;
        return estimate;
    }
    if (pending_ && std::abs(cents_between(estimate->frequency_hz, pending_->frequency_hz)) <= 180.0) {
        ++pending_confirmations_;  // same pending candidate seen again (within 180 cents): one more confirmation
    } else {
        pending_ = estimate;         // new (or first) pending candidate: restart the confirmation count
        pending_confirmations_ = 1;
    }
    if (pending_confirmations_ >= required_confirmations_) {
        // Confirmed across enough consecutive frames: trust the drop and
        // switch the published pitch over to it.
        published_ = estimate;
        pending_.reset();
        pending_confirmations_ = 0;
        return estimate;
    }
    // Not confirmed yet: keep republishing the old pitch while the
    // candidate drop accumulates more confirmations.
    return VPMLikePitch{published_->frequency_hz, std::min(estimate->confidence, 0.55)};
}

void VPMLikeTracker::reset() {
    published_.reset();          // clear the currently published pitch
    pending_.reset();            // clear any pitch awaiting confirmation
    pending_confirmations_ = 0;  // reset the confirmation streak
}

std::optional<VPMLikePitch> estimate_impl(
    const std::span<const double> samples,
    const double sample_rate,
    const VPMLikeConfig& config,
    VPMLikeFrameDiagnostic* diagnostic
) {
    if (samples.size() < 1024 || sample_rate <= 0.0) {
        if (diagnostic) {
            diagnostic->decision = "rejected_invalid_frame_or_sample_rate";
        }
        return std::nullopt;  // not enough signal, or an invalid sample rate
    }

    // Remove DC offset (same reasoning as mpm.cpp): an autocorrelation-style
    // estimator is biased by a constant offset in the signal.
    const auto mean = std::reduce(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());
    std::vector<double> centered(samples.size());
    double square_sum = 0.0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centered[index] = samples[index] - mean;               // DC-free sample
        square_sum += centered[index] * centered[index];        // accumulate squared amplitude for RMS
    }
    const auto rms = std::sqrt(square_sum / static_cast<double>(centered.size()));  // window loudness
    if (diagnostic) {
        diagnostic->rms = rms;
    }
    if (rms < config.minimum_rms) {
        if (diagnostic) {
            diagnostic->decision = "rejected_rms_below_minimum";
        }
        return std::nullopt;  // too quiet to trust a pitch estimate
    }

    // Convert the configured frequency band into a search range of lags
    // (periods, in samples), just like mpm.cpp's MPM candidate generator.
    const auto minimum_lag = std::max(2, static_cast<int>(sample_rate / config.maximum_frequency_hz));
    const auto maximum_lag = std::min(
        static_cast<int>(centered.size() / 2),
        static_cast<int>(sample_rate / config.minimum_frequency_hz)
    );
    if (minimum_lag + 2 >= maximum_lag) {
        if (diagnostic) {
            diagnostic->decision = "rejected_empty_lag_range";
        }
        return std::nullopt;  // frequency band collapses to (near) nothing at this sample rate/window
    }

    // Prefix sum of squared amplitudes, so the energy of any contiguous
    // sub-range of `centered` can be looked up in O(1) below instead of
    // being resummed for every lag (energy[b] - energy[a] = sum of squares
    // over [a, b)).
    std::vector<double> energy(centered.size() + 1, 0.0);
    for (std::size_t index = 0; index < centered.size(); ++index) {
        energy[index + 1] = energy[index] + centered[index] * centered[index];
    }

    // Normalised autocorrelation function (ACF) over the candidate lag
    // range: for each lag, correlate the signal with a delayed copy of
    // itself and divide by the geometric mean of the two windows' energies
    // (looked up via the prefix sums above), giving a value close to 1.0
    // when the waveform repeats after `lag` samples.
    std::vector<double> correlation(maximum_lag + 1, 0.0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        const auto count = static_cast<int>(centered.size()) - lag;  // number of overlapping sample pairs at this lag
        const auto leading = energy[count];                          // energy of the "leading" sub-window [0, count)
        const auto delayed = energy[centered.size()] - energy[lag];  // energy of the "delayed" sub-window [lag, size)
        const auto normalization = std::sqrt(std::max(1e-18, leading * delayed));  // normaliser, floored to avoid division by ~0
        double dot = 0.0;  // raw (unnormalised) autocorrelation at this lag
        for (int index = 0; index < count; ++index) {
            dot += centered[index] * centered[index + lag];
        }
        correlation[lag] = dot / normalization;  // normalised ACF value at this lag
    }

    // Peak picking: every lag whose ACF value is a local maximum
    // (>= its left neighbour, > its right neighbour) is a plausible period.
    std::vector<int> peaks;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        if (correlation[lag] >= correlation[lag - 1] &&
            correlation[lag] > correlation[lag + 1]) {
            peaks.push_back(lag);
        }
    }
    if (peaks.empty()) {
        if (diagnostic) {
            diagnostic->decision = "rejected_no_autocorrelation_peak";
        }
        return std::nullopt;  // completely flat/non-periodic ACF: no plausible pitch
    }
    const auto strongest = *std::max_element(peaks.begin(), peaks.end(), [&](const int a, const int b) {
        return correlation[a] < correlation[b];
    });  // lag of the single tallest ACF peak
    if (correlation[strongest] < config.minimum_periodicity) {
        if (diagnostic) {
            diagnostic->strongest_periodicity = correlation[strongest];
            diagnostic->decision = "rejected_strongest_periodicity_below_threshold";
        }
        return std::nullopt;  // even the best peak is too weak to trust as periodic
    }

    // Instead of always taking the single strongest peak, accept the
    // *shortest-lag* (i.e. highest-frequency) peak that is still "close
    // enough" to the strongest one (within `near_strongest_ratio`). Because
    // peaks are discovered in increasing-lag order, the first one found
    // above `acceptance` is the shortest such lag. This prefers the true
    // fundamental over an equally strong-looking peak at a longer,
    // sub-multiple lag (e.g. an octave-down ghost).
    const auto acceptance = std::max(
        config.minimum_periodicity,
        correlation[strongest] * config.near_strongest_ratio
    );
    auto selected = strongest;  // fallback if no earlier (shorter-lag) peak clears the acceptance bar
    for (const auto peak : peaks) {
        if (correlation[peak] >= acceptance) {
            selected = peak;  // first (shortest-lag) peak strong enough to accept
            break;
        }
    }
    if (diagnostic) {
        diagnostic->strongest_periodicity = correlation[strongest];
        diagnostic->acceptance_periodicity = acceptance;
        diagnostic->autocorrelation_candidates.reserve(peaks.size());
        for (const auto peak : peaks) {
            diagnostic->autocorrelation_candidates.push_back({
                peak,
                sample_rate / parabolic_peak(correlation, peak),
                correlation[peak],
                peak == strongest,
                correlation[peak] >= acceptance,
                peak == selected,
            });
        }
    }

    // ACF lag quantisation is most visible at high pitch. Yamaoka's later
    // refinement searches the 2T, 3T... peaks and divides their locations by
    // the multiple. This gives sub-sample precision without a longer audible
    // response window.
    //
    // Idea: the ACF also has peaks near 2*T, 3*T, ... (the period repeated
    // twice, three times, ...). Each of those peaks, divided by its
    // multiple, is an *independent* re-estimate of the same period T, and
    // because it is measured over a longer span it is less sensitive to
    // single-sample lag quantisation. Averaging all these re-estimates
    // (weighted by how strong and how high-multiple each one is) sharpens
    // the final period estimate beyond what parabolic interpolation on the
    // single T peak alone could achieve.
    auto weighted_period = parabolic_peak(correlation, selected) * correlation[selected];  // start the weighted sum with the base (1x) peak
    auto weight_sum = correlation[selected];                                                // and its own weight
    for (int multiple = 2; multiple <= config.maximum_period_multiple; ++multiple) {  // look for 2T, 3T, ... peaks
        const auto expected = selected * multiple;  // where the multiple-T peak should sit if the period is exact
        if (expected + 2 >= maximum_lag) {
            break;  // this multiple's expected location is outside the searched lag range; higher multiples will be too
        }
        const auto radius = std::max(2, selected / 6);       // search window around the expected location, to allow for drift
        const auto begin = std::max(minimum_lag + 1, expected - radius);
        const auto end = std::min(maximum_lag - 1, expected + radius);
        auto local = begin;  // running best lag found in [begin, end]
        for (auto lag = begin + 1; lag <= end; ++lag) {
            if (correlation[lag] > correlation[local]) {
                local = lag;  // found a taller peak nearby
            }
        }
        if (correlation[local] < config.minimum_periodicity * 0.8) {
            continue;  // no credible peak near this multiple; skip it rather than pollute the average
        }
        const auto weight = correlation[local] * static_cast<double>(multiple);  // stronger and higher-multiple peaks count more
        weighted_period += parabolic_peak(correlation, local) /
            static_cast<double>(multiple) * weight;  // this peak's own period re-estimate (interpolated location / multiple), weighted
        weight_sum += weight;
    }
    const auto refined_period = weighted_period / std::max(1e-12, weight_sum);  // weighted-average refined period, in samples
    const auto autocorrelation_frequency = sample_rate / refined_period;        // period -> frequency conversion
    if (diagnostic) {
        diagnostic->autocorrelation_frequency_hz = autocorrelation_frequency;
    }

    // The 2015 article explicitly tests 1/3, 1/2, 1x, 2x and 3x relatives
    // against the real spectrum, then chooses the lowest plausible one. The
    // exact app thresholds are private; the named config values above are our
    // reproducible interpretation and can be calibrated with regression data.
    //
    // Rationale: the ACF alone cannot always tell a true fundamental apart
    // from a strong harmonic (e.g. it may lock onto 3x the real fundamental
    // when the fundamental itself is weak). This pass probes the actual
    // spectrum at the ACF frequency and its 1/3x, 1/2x, 2x and 3x relatives,
    // and -- among the ones that look like a genuine local spectral peak --
    // prefers the *lowest* one that is plausible, since a missing/weak
    // fundamental with present harmonics is the more common failure mode
    // than the reverse.
    const auto base_amplitude = spectral_amplitude(samples, sample_rate, autocorrelation_frequency);  // spectral amplitude at the ACF's own frequency, used as the relative baseline
    std::vector<std::pair<double, double>> relatives{
        {1.0 / 3.0, autocorrelation_frequency / 3.0},
        {1.0 / 2.0, autocorrelation_frequency / 2.0},
        {1.0, autocorrelation_frequency},
        {2.0, autocorrelation_frequency * 2.0},
        {3.0, autocorrelation_frequency * 3.0},
    };
    std::sort(relatives.begin(), relatives.end(), [](const auto& left, const auto& right) {
        return left.second < right.second;  // ascending by frequency, so the loop below tests lowest first
    });
    auto chosen_frequency = autocorrelation_frequency;  // default: keep the ACF's own estimate if no relative is selected
    bool spectral_candidate_selected = false;
    for (const auto [multiplier, frequency] : relatives) {  // walk candidates lowest-frequency first
        const auto in_range = frequency >= config.minimum_frequency_hz &&
            frequency <= config.maximum_frequency_hz;
        if (!in_range) {
            if (diagnostic) {
                diagnostic->spectral_candidates.push_back({
                    multiplier, frequency, correlation[selected], 0.0, base_amplitude, 0.0,
                    0.0, 0.0, false, false, false, false, false,
                    "rejected_outside_frequency_range",
                });
            }
            continue;
        }
        const auto amplitude = spectral_amplitude(samples, sample_rate, frequency);  // this candidate's own spectral amplitude
        const auto side_offset = std::max(sample_rate / static_cast<double>(samples.size()), frequency * 0.012);  // how far to look either side, at least one FFT-bin's worth
        const auto left = spectral_amplitude(samples, sample_rate, frequency - side_offset);   // amplitude just below the candidate
        const auto right = spectral_amplitude(samples, sample_rate, frequency + side_offset);  // amplitude just above the candidate
        const auto is_local_peak = amplitude >= left * 1.03 && amplitude >= right * 1.03;  // must clearly stand above both neighbours (>=3%)
        const auto is_absolute = amplitude >= config.minimum_absolute_spectral_amplitude;  // must be loud enough in an absolute sense
        const auto is_relative = base_amplitude <= 1e-12 ||
            amplitude >= base_amplitude * config.minimum_relative_spectral_amplitude;  // must be a reasonable fraction of the ACF's own amplitude
        const auto passes = is_local_peak && is_absolute && is_relative;  // candidate looks like real, adequately loud spectral content
        // ACF is the periodic estimate. Spectral relatives may correct it
        // downward to a missing fundamental, but a bright upper harmonic must
        // not promote a strong ACF fundamental to 2x/3x.
        const auto does_not_promote = config.allow_spectral_promotion ||
            frequency <= autocorrelation_frequency * (1.0 + 1e-12);  // unless explicitly allowed, never move *up* past the ACF frequency
        // The downward spectrum correction exists to repair an earlier,
        // near-strong ACF peak (for example 3f when the true fundamental is
        // weak). If the selected ACF peak is already the strongest peak,
        // overriding it with f/2 or f/3 creates the short subharmonic islands
        // seen in the adverse holdout even though ACF itself is correct.
        const auto does_not_override_strongest_acf = frequency >= autocorrelation_frequency * (1.0 - 1e-12) ||
            selected != strongest;  // only allow a downward correction when the ACF didn't already pick its own strongest peak
        const auto is_selected = passes && does_not_promote &&
            does_not_override_strongest_acf && !spectral_candidate_selected;  // first (lowest-frequency) candidate that clears every gate wins
        if (diagnostic) {
            std::string decision;
            if (is_selected) {
                decision = "selected_first_supported_lowest_frequency";
            } else if (passes && !does_not_promote) {
                decision = "rejected_above_autocorrelation_fallback";
            } else if (passes && !does_not_override_strongest_acf) {
                decision = "rejected_below_strongest_autocorrelation_peak";
            } else if (passes) {
                decision = "rejected_higher_than_first_supported_candidate";
            } else if (!is_local_peak) {
                decision = "rejected_not_local_spectral_peak";
            } else if (!is_absolute) {
                decision = "rejected_below_absolute_spectral_support";
            } else {
                decision = "rejected_below_relative_spectral_support";
            }
            diagnostic->spectral_candidates.push_back({
                multiplier,
                frequency,
                correlation[selected],
                amplitude,
                base_amplitude,
                base_amplitude > 1e-12 ? amplitude / base_amplitude : 0.0,
                left,
                right,
                true,
                is_local_peak,
                is_absolute,
                is_relative,
                is_selected,
                decision,
            });
        }
        if (is_selected) {
            chosen_frequency = frequency;          // override the ACF estimate with this spectrally-supported relative
            spectral_candidate_selected = true;
            if (!diagnostic) {
                break;  // no need to keep testing candidates once one is chosen, unless diagnostics want the full record
            }
        }
    }

    if (!std::isfinite(chosen_frequency)) {
        if (diagnostic) {
            diagnostic->decision = "rejected_non_finite_frequency";
        }
        return std::nullopt;  // numerical failure somewhere upstream; never emit a garbage frequency
    }
    const auto confidence = std::clamp(correlation[selected], 0.0, 1.0);  // ACF peak height doubles as the output confidence
    if (confidence < config.minimum_output_confidence) {
        if (diagnostic) {
            diagnostic->decision = "rejected_output_confidence_below_threshold";
        }
        return std::nullopt;  // periodicity too weak to publish, even though a frequency was computed
    }
    const auto pitch = VPMLikePitch{
        chosen_frequency,  // final frequency: either the refined ACF estimate, or a spectrally-corrected relative of it
        confidence,
    };
    if (diagnostic) {
        diagnostic->pitch = pitch;
        diagnostic->decision = spectral_candidate_selected
            ? "selected_supported_spectral_candidate"
            : "selected_autocorrelation_fallback_no_spectral_candidate_passed";
    }
    return pitch;
}

// Public entry point: run the estimator without collecting diagnostics
// (the common, fast path used by production pitch tracking).
std::optional<VPMLikePitch> estimate_vpm_like_pitch(
    const std::span<const double> samples,
    const double sample_rate,
    const VPMLikeConfig& config
) {
    return estimate_impl(samples, sample_rate, config, nullptr);
}

// Diagnostic entry point: runs the same estimator but also records every
// intermediate decision (which peaks were tried, why each spectral
// candidate was accepted/rejected, etc.) for offline analysis and tests.
VPMLikeFrameDiagnostic diagnose_vpm_like_pitch(
    const std::span<const double> samples,
    const double sample_rate,
    const VPMLikeConfig& config
) {
    VPMLikeFrameDiagnostic diagnostic;
    estimate_impl(samples, sample_rate, config, &diagnostic);
    return diagnostic;
}

}  // namespace klarivision::core
