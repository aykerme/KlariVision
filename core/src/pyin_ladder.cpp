#include "klarivision/core/pyin_ladder.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <numbers>
#include <utility>
#include <vector>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace klarivision::core {
namespace {

// ---------------------------------------------------------------------------
// CMND (YIN steps 1-3), reusing the exact algebra already in this repo (see
// analysis_engine.cpp's compute_yin_difference / compute_cumulative_mean_
// normalized_difference and pitch_engine_v2_session.cpp's yin_candidates):
// the difference function is expanded as energy(leading) + energy(delayed) -
// 2*correlation so it costs one dot product per lag instead of an explicit
// per-sample subtraction loop, and the running-average normalisation turns
// it into a curve that dips toward zero at the true period.
// ---------------------------------------------------------------------------

float dot_product(const float* left, const float* right, std::size_t count) {
#if defined(__APPLE__)
    float result = 0;
    vDSP_dotpr(left, 1, right, 1, &result, static_cast<vDSP_Length>(count));
    return result;
#else
    float result = 0;
    for (std::size_t index = 0; index < count; ++index) {
        result += left[index] * right[index];
    }
    return result;
#endif
}

std::vector<float> compute_prefix_energy(std::span<const float> samples) {
    std::vector<float> energy(samples.size() + 1, 0.0F);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        energy[index + 1] = energy[index] + samples[index] * samples[index];
    }
    return energy;
}

// d'(tau) for tau in [0, max_lag], d'(0) left at 1 by construction (the
// running average starts at zero, so lag 0 is defined as non-dipping).
// Kept in double past this point: the threshold sweep below compares many
// small differences against a 0.01-resolution grid, where float rounding
// would occasionally flip a comparison.
std::vector<double> compute_cmnd(std::span<const float> window, int max_lag) {
    const auto prefix = compute_prefix_energy(window);
    std::vector<float> difference(static_cast<std::size_t>(max_lag) + 1, 0.0F);
    for (int lag = 1; lag <= max_lag; ++lag) {
        const auto count = window.size() - static_cast<std::size_t>(lag);
        const float correlation = dot_product(window.data(), window.data() + lag, count);
        difference[static_cast<std::size_t>(lag)] = std::max(
            0.0F,  // clamp tiny negative floating-point error to zero
            prefix[count] +
                (prefix[window.size()] - prefix[static_cast<std::size_t>(lag)]) -
                2.0F * correlation
        );
    }

    std::vector<double> cmnd(static_cast<std::size_t>(max_lag) + 1, 1.0);
    double running = 0.0;
    for (int lag = 1; lag <= max_lag; ++lag) {
        running += static_cast<double>(difference[static_cast<std::size_t>(lag)]);
        if (running > 0.0) {
            cmnd[static_cast<std::size_t>(lag)] =
                static_cast<double>(difference[static_cast<std::size_t>(lag)]) *
                static_cast<double>(lag) / running;
        }
    }
    return cmnd;
}

// ---------------------------------------------------------------------------
// The 100-threshold Beta-mixture prior (Mauch & Dixon, ICASSP 2014).
// ---------------------------------------------------------------------------

constexpr int kThresholdCount = 100;
// s = 0.01 * (index + 1); s = 0.10 is therefore index 9. Classic
// single-threshold YIN uses 0.10 as its dip threshold, and this is the
// entry in the sweep that reproduces that exact answer.
constexpr int kClassicThresholdIndex = 9;

double log_beta_function(double a, double b) {
    return std::lgamma(a) + std::lgamma(b) - std::lgamma(a + b);
}

double beta_pdf(double x, double a, double b) {
    if (x <= 0.0 || x >= 1.0) return 0.0;
    const double log_pdf =
        (a - 1.0) * std::log(x) + (b - 1.0) * std::log(1.0 - x) - log_beta_function(a, b);
    return std::exp(log_pdf);
}

// Equally-weighted mixture of three Beta pdfs (means 0.10 / 0.15 / 0.20,
// concentration a+b = 20 fixed) evaluated at each of the 100 thresholds and
// normalised to sum to 1 on its own. A function-local static means lgamma
// only ever runs once for the process, not once per pyin_ladder() call; the
// caller scales this fixed shape by (1 - absolute_minimum_prior) at use
// time, so the one-time computation stays independent of a runtime config
// value while still satisfying "the 100 priors sum to 1 - p_a" for whatever
// p_a is configured.
const std::array<double, kThresholdCount>& normalized_threshold_priors() {
    static const std::array<double, kThresholdCount> priors = [] {
        constexpr double kConcentration = 20.0;
        constexpr double kMeans[] = {0.10, 0.15, 0.20};
        std::array<double, kThresholdCount> raw{};
        double sum = 0.0;
        for (int index = 0; index < kThresholdCount; ++index) {
            const double threshold = 0.01 * static_cast<double>(index + 1);
            double mixture = 0.0;
            for (const double mean : kMeans) {
                const double a = kConcentration * mean;
                const double b = kConcentration * (1.0 - mean);
                mixture += beta_pdf(threshold, a, b);
            }
            mixture /= static_cast<double>(std::size(kMeans));
            raw[static_cast<std::size_t>(index)] = mixture;
            sum += mixture;
        }
        for (double& value : raw) value /= sum;
        return raw;
    }();
    return priors;
}

// ---------------------------------------------------------------------------
// YIN step 6: "best local estimate".
// ---------------------------------------------------------------------------
//
// The YIN paper's step 6 searches neighbouring *time* frames for a cleaner
// dip at the same lag. This ladder only has one frame, so it implements the
// lag-domain analogue instead: search neighbouring *lags* in the already-
// computed d' curve for a better minimum than the threshold sweep's raw
// pick, then re-run the search restricted to a fraction of that result, then
// parabola-interpolate. This is a deliberate deviation from the paper's own
// axis, not an oversight -- it re-reads the same d' array so it costs
// nothing beyond the two bounded scans.
struct RefinedLag {
    double lag{};
    double cmnd_value{};
};

int index_of_minimum(const std::vector<double>& cmnd, int lo, int hi, int max_lag) {
    lo = std::max(lo, 1);
    hi = std::min(hi, max_lag);
    int best = lo;
    for (int tau = lo; tau <= hi; ++tau) {
        if (cmnd[static_cast<std::size_t>(tau)] < cmnd[static_cast<std::size_t>(best)]) {
            best = tau;
        }
    }
    return best;
}

// `band_lo`/`band_hi` are this band's own designated lag range (its slice of
// the disjoint three-band coverage). Step 6's neighbourhood search is
// clamped to that range rather than the full [1, max_lag] the cumulative sum
// happens to span: the low band's cmnd array, for instance, holds values
// down to lag 1 purely so its own CMND normalisation has a complete running
// sum, but a lag of 1 there means ~48 kHz -- another band's territory
// entirely, computed on the wrong window size. Without this clamp, step 6
// can wander out of the band it was asked to refine within and answer a
// completely different octave.
RefinedLag refine_lag(
    const std::vector<double>& cmnd, int tau, int max_lag, double sample_rate,
    const PyinLadderConfig& config, int band_lo, int band_hi
) {
    int refined_tau = tau;
    if (config.best_local_window_seconds > 0.0) {
        // Tmax (25 ms = 1200 samples at 48 kHz) was sized for the YIN
        // paper's own single, wide lag range. This project's three bands
        // are each much narrower (a few hundred samples at most), so an
        // unscaled Tmax/2 radius does not stay "local" at all -- it covers
        // the *entire* low or mid band regardless of where tau sits,
        // reaching clean across an octave to whichever lag has the single
        // deepest dip in the band. For a steady tone that is very often an
        // exact harmonic multiple of tau (a pure sine repeats at every
        // multiple of its period, and a multiple's dip can legitimately be
        // deeper than the fundamental's own due to lag-quantisation), so an
        // unscaled search would silently re-introduce the octave errors the
        // ladder exists to avoid. Capping the radius at half of tau itself
        // keeps the search inside (0.5 tau, 1.5 tau) -- close enough to
        // exclude both the 2x multiple and the 1/2 submultiple -- while
        // still finding a cleaner nearby dip than the sweep's raw pick.
        const int half_window = std::max(
            1, std::min(
                   static_cast<int>(std::lround(config.best_local_window_seconds * sample_rate / 2.0)),
                   tau / 2
               )
        );
        const int stage_one = index_of_minimum(
            cmnd, std::max(band_lo, tau - half_window), std::min(band_hi, tau + half_window), max_lag
        );
        const int refine_span = std::max(
            1, static_cast<int>(std::lround(config.best_local_refine_fraction * stage_one))
        );
        refined_tau = index_of_minimum(
            cmnd, std::max(band_lo, stage_one - refine_span), std::min(band_hi, stage_one + refine_span),
            max_lag
        );
    }

    // Sub-sample parabolic interpolation around the final integer lag, same
    // technique used throughout the other engines in this repo.
    double correction = 0.0;
    if (refined_tau - 1 >= 1 && refined_tau + 1 <= max_lag) {
        const double previous = cmnd[static_cast<std::size_t>(refined_tau - 1)];
        const double current = cmnd[static_cast<std::size_t>(refined_tau)];
        const double next = cmnd[static_cast<std::size_t>(refined_tau + 1)];
        const double denominator = previous - 2.0 * current + next;
        if (std::abs(denominator) > 1e-9) {
            correction = std::clamp(0.5 * (previous - next) / denominator, -0.5, 0.5);
        }
    }
    return RefinedLag{
        static_cast<double>(refined_tau) + correction,
        cmnd[static_cast<std::size_t>(refined_tau)],
    };
}

// ---------------------------------------------------------------------------
// Per-band pipeline.
// ---------------------------------------------------------------------------

struct BandSpec {
    AnalysisBand band;
    std::size_t window_samples;
    double frequency_low_hz;
    double frequency_high_hz;
};

struct LocalMinimum {
    int tau;
    double value;
};

struct ClassicPick {
    bool valid{false};
    double frequency_hz{};
    double cmnd_value{1.0};
};

/// One band's measured difference curve, before any threshold is applied.
///
/// Measurement and decision are separated on purpose. The bands cover disjoint
/// lag ranges, so pooling their dips into a single sweep is exactly equivalent
/// to sweeping one continuous lag range -- and that equivalence is the whole
/// point. See pooled_sweep below.
struct BandMeasurement {
    BandSpec spec{};
    bool valid{false};
    std::vector<double> cmnd{};
    std::vector<LocalMinimum> minima{};
    int global_min_tau{0};
    int search_lo{0};
    int search_hi{0};
    int max_lag{0};
};

std::vector<float> tail_window(std::span<const float> samples, std::size_t n) {
    std::vector<float> window(n, 0.0F);
    const std::size_t available = std::min(n, samples.size());
    std::copy(
        samples.end() - static_cast<std::ptrdiff_t>(available), samples.end(),
        window.end() - static_cast<std::ptrdiff_t>(available)
    );
    return window;
}

BandMeasurement measure_band(
    std::span<const float> history, double sample_rate, const BandSpec& spec,
    const PyinLadderConfig& config
) {
    BandMeasurement measurement;
    measurement.spec = spec;

    const double frequency_low = std::max(spec.frequency_low_hz, config.minimum_frequency_hz);
    const double frequency_high = std::min(spec.frequency_high_hz, config.maximum_frequency_hz);
    if (frequency_high <= frequency_low) return measurement;  // band excluded by caller's own range

    const auto window = tail_window(history, spec.window_samples);

    const int min_lag = std::max(1, static_cast<int>(std::ceil(sample_rate / frequency_high)));
    int max_lag = static_cast<int>(std::floor(sample_rate / frequency_low));
    max_lag = std::min(max_lag, static_cast<int>(window.size()) - 2);
    // Need at least one lag with both neighbours inside [1, max_lag] for
    // local-minimum testing.
    if (min_lag + 2 >= max_lag) return measurement;

    measurement.cmnd = compute_cmnd(window, max_lag);
    measurement.max_lag = max_lag;

    // Local-minimum search is restricted to this band's own designated lag
    // range (its slice of the overall disjoint coverage), even though the
    // cumulative sum feeding d' had to start from lag 1.
    measurement.search_lo = std::max(min_lag, 2);
    measurement.search_hi = std::min(max_lag - 1, max_lag);
    if (measurement.search_lo > measurement.search_hi) return measurement;

    const auto& cmnd = measurement.cmnd;
    measurement.global_min_tau = measurement.search_lo;
    for (int tau = measurement.search_lo; tau <= measurement.search_hi; ++tau) {
        if (cmnd[static_cast<std::size_t>(tau)] <
            cmnd[static_cast<std::size_t>(measurement.global_min_tau)]) {
            measurement.global_min_tau = tau;
        }
        const bool is_local_minimum =
            cmnd[static_cast<std::size_t>(tau)] < cmnd[static_cast<std::size_t>(tau - 1)] &&
            cmnd[static_cast<std::size_t>(tau)] <= cmnd[static_cast<std::size_t>(tau + 1)];
        if (is_local_minimum) {
            measurement.minima.push_back(LocalMinimum{tau, cmnd[static_cast<std::size_t>(tau)]});
        }
    }
    // search_hi+1 was never scanned as a candidate tau but its value can
    // still beat every scanned tau (e.g. a monotonically-falling curve);
    // check it too so the absolute-minimum fallback is genuinely global.
    if (cmnd[static_cast<std::size_t>(measurement.search_hi + 1)] <
        cmnd[static_cast<std::size_t>(measurement.global_min_tau)]) {
        measurement.global_min_tau = measurement.search_hi + 1;
    }

    measurement.valid = true;
    return measurement;
}

struct PooledMinimum {
    int tau{};
    double value{};
    std::size_t band{};
};

struct SweepOutcome {
    std::vector<PyinCandidate> candidates{};
    double voiced_fraction{0.0};
    ClassicPick classic{};
};

/// The threshold sweep, run once over every band's dips at the same time.
///
/// Running it per band would break the property the whole ladder rests on.
/// YIN's fourth step selects the *smallest* qualifying lag, and that word is
/// what forces the smallest element of the period set {T, 2T, 3T, ...} and so
/// prevents the estimator from sliding onto 2T or 3T. Three independent sweeps
/// lose that ordering across band boundaries: for a cleanly periodic tone every
/// threshold clears the dip in each band, so a subharmonic sitting one band
/// lower saturates to the same probability mass as the true fundamental, and
/// mass alone can no longer tell them apart.
///
/// The bands cover disjoint lag ranges, so pooling their dips and taking the
/// smallest tau under each threshold is exactly what a single continuous lag
/// range would have done. The normalised difference function is a ratio of
/// aperiodic to total power, which makes values from windows of different
/// lengths comparable on the same threshold scale.
SweepOutcome pooled_sweep(
    std::span<const BandMeasurement> bands, double sample_rate, const PyinLadderConfig& config
) {
    SweepOutcome outcome;

    std::vector<PooledMinimum> pooled;
    for (std::size_t band = 0; band < bands.size(); ++band) {
        if (!bands[band].valid) continue;
        for (const auto& minimum : bands[band].minima) {
            pooled.push_back(PooledMinimum{minimum.tau, minimum.value, band});
        }
    }

    // Absolute-minimum fallback, taken across every band for the same reason.
    bool have_fallback = false;
    PooledMinimum fallback{};
    for (std::size_t band = 0; band < bands.size(); ++band) {
        if (!bands[band].valid) continue;
        const auto tau = bands[band].global_min_tau;
        const auto value = bands[band].cmnd[static_cast<std::size_t>(tau)];
        if (!have_fallback || value < fallback.value) {
            fallback = PooledMinimum{tau, value, band};
            have_fallback = true;
        }
    }
    if (pooled.empty() && !have_fallback) return outcome;

    const auto& raw_priors = normalized_threshold_priors();
    std::array<double, kThresholdCount> priors_used{};
    for (int index = 0; index < kThresholdCount; ++index) {
        priors_used[static_cast<std::size_t>(index)] =
            raw_priors[static_cast<std::size_t>(index)] * (1.0 - config.absolute_minimum_prior);
    }

    // Single simultaneous walk: dips are admitted in ascending d' order, so
    // the admitted set only grows as the threshold grows, and the smallest
    // admitted tau is exactly pYIN's answer for that threshold.
    std::vector<std::size_t> order(pooled.size());
    for (std::size_t index = 0; index < order.size(); ++index) order[index] = index;
    std::sort(order.begin(), order.end(), [&](std::size_t left, std::size_t right) {
        return pooled[left].value < pooled[right].value;
    });

    std::vector<std::pair<PooledMinimum, double>> mass_by_tau;
    const auto accumulate = [&mass_by_tau](const PooledMinimum& winner, double mass) {
        for (auto& entry : mass_by_tau) {
            if (entry.first.tau == winner.tau && entry.first.band == winner.band) {
                entry.second += mass;
                return;
            }
        }
        mass_by_tau.emplace_back(winner, mass);
    };

    std::size_t walk = 0;
    bool have_best = false;
    PooledMinimum best{};
    bool any_failed = false;
    bool classic_resolved = false;
    PooledMinimum classic{};
    for (int index = 0; index < kThresholdCount; ++index) {
        const double threshold = 0.01 * static_cast<double>(index + 1);
        while (walk < order.size() && pooled[order[walk]].value < threshold) {
            const auto& admitted = pooled[order[walk]];
            if (!have_best || admitted.tau < best.tau) {
                best = admitted;
                have_best = true;
            }
            ++walk;
        }
        if (!have_best) {
            any_failed = true;
        } else {
            accumulate(best, priors_used[static_cast<std::size_t>(index)]);
        }
        if (index == kClassicThresholdIndex && have_best) {
            classic = best;
            classic_resolved = true;
        }
    }

    bool fallback_used = false;
    if (any_failed && have_fallback) {
        accumulate(fallback, config.absolute_minimum_prior);
        fallback_used = true;
        if (!classic_resolved) {
            // Classic single-threshold YIN's own fallback: no dip cleared
            // 0.10, so it reports the absolute minimum directly.
            classic = fallback;
            classic_resolved = true;
        }
    }

    for (const auto& [winner, mass] : mass_by_tau) {
        const auto& band = bands[winner.band];
        outcome.voiced_fraction += mass;
        const auto refined = refine_lag(
            band.cmnd, winner.tau, band.max_lag, sample_rate, config,
            band.search_lo, band.search_hi
        );
        const double frequency = sample_rate / refined.lag;
        const bool is_absolute_minimum =
            fallback_used && winner.tau == fallback.tau && winner.band == fallback.band;
        outcome.candidates.push_back(PyinCandidate{
            frequency, mass, refined.cmnd_value, band.spec.band, is_absolute_minimum,
        });
        if (classic_resolved && winner.tau == classic.tau && winner.band == classic.band) {
            outcome.classic.valid = true;
            outcome.classic.frequency_hz = frequency;
            outcome.classic.cmnd_value = refined.cmnd_value;
        }
    }

    return outcome;
}

double cents_between(double a, double b) {
    return std::abs(1200.0 * std::log2(a / b));
}

// Descending by period_probability, the sweep's real evidence. A genuine tie
// is broken toward the higher frequency (shorter period), matching the rule
// the pooled sweep already applies: given equal evidence, the smallest period
// is the answer. With one pooled sweep this is a formality rather than a
// correction, but it keeps the ordering total and deterministic.
bool candidate_order(const PyinCandidate& left, const PyinCandidate& right) {
    constexpr double kTieEpsilon = 1e-9;
    if (std::abs(left.period_probability - right.period_probability) > kTieEpsilon) {
        return left.period_probability > right.period_probability;
    }
    return left.frequency_hz > right.frequency_hz;
}

}  // namespace

PyinLadderResult pyin_ladder(
    std::span<const float> history, double sample_rate, const PyinLadderConfig& config
) {
    PyinLadderResult result;
    if (history.empty() || sample_rate <= 0.0) return result;

    // Apply the high-pass to a copy; the caller's span is never mutated.
    std::vector<float> filtered_storage;
    std::span<const float> working = history;
    if (config.apply_high_pass) {
        filtered_storage.assign(history.begin(), history.end());
        const double omega = 2.0 * std::numbers::pi * unified::kHighPassCutoffHz / sample_rate;
        const double cos_omega = std::cos(omega);
        const double sin_omega = std::sin(omega);
        const double q = std::numbers::sqrt2 / 2.0;  // Butterworth Q = 1/sqrt(2)
        const double alpha = sin_omega / (2.0 * q);
        const double a0 = 1.0 + alpha;
        const double b0 = (1.0 + cos_omega) / 2.0 / a0;
        const double b1 = -(1.0 + cos_omega) / a0;
        const double b2 = (1.0 + cos_omega) / 2.0 / a0;
        const double a1 = (-2.0 * cos_omega) / a0;
        const double a2 = (1.0 - alpha) / a0;
        double x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
        for (float& sample : filtered_storage) {
            const double x0 = sample;
            const double y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1;
            x1 = x0;
            y2 = y1;
            y1 = y0;
            sample = static_cast<float>(y0);
        }
        working = filtered_storage;
    }

    const std::array<BandSpec, 3> band_specs{{
        {AnalysisBand::low, unified::kLowWindowSamples, unified::kEstimatorMinimumHz,
         unified::kLowBandMaximumHz},
        {AnalysisBand::mid, unified::kMidWindowSamples, unified::kLowBandMaximumHz,
         unified::kMidBandMaximumHz},
        {AnalysisBand::high, unified::kHighWindowSamples, unified::kMidBandMaximumHz,
         unified::kEstimatorMaximumHz},
    }};

    std::array<BandMeasurement, 3> measurements{};
    for (std::size_t index = 0; index < band_specs.size(); ++index) {
        measurements[index] = measure_band(working, sample_rate, band_specs[index], config);
    }

    const auto swept = pooled_sweep(measurements, sample_rate, config);
    const auto all_candidates = swept.candidates;
    const bool classic_valid = swept.classic.valid;
    const double classic_frequency = swept.classic.frequency_hz;

    result.voiced_probability = std::min(swept.voiced_fraction, 1.0);
    result.classic_yin_frequency_hz = classic_frequency;

    // Merge candidates across bands, de-duplicating within
    // kCandidateMergeCents: keep the higher-period_probability entry's
    // metadata (frequency, band, cmnd, flag) but sum the two masses -- the
    // combined candidate carries the combined evidence even though only one
    // band's measurement describes it downstream.
    std::vector<PyinCandidate> merged;
    for (const auto& candidate : all_candidates) {
        auto match = std::find_if(merged.begin(), merged.end(), [&](const PyinCandidate& existing) {
            return cents_between(candidate.frequency_hz, existing.frequency_hz) <
                unified::kCandidateMergeCents;
        });
        if (match == merged.end()) {
            merged.push_back(candidate);
        } else {
            const double summed_mass = match->period_probability + candidate.period_probability;
            if (candidate.period_probability > match->period_probability) {
                *match = candidate;
            }
            match->period_probability = summed_mass;
        }
    }

    std::sort(merged.begin(), merged.end(), candidate_order);

    if (classic_valid && merged.size() > unified::kMaximumCandidates) {
        // classic_yin_frequency_hz is a documented invariant: it must
        // always appear in `candidates`. It is guaranteed to exist
        // somewhere in `merged` (every threshold's winner, including the
        // classic one, always lands in mass_by_tau), so if truncation would
        // drop it, force it back in rather than let the invariant break on
        // a crowded frame.
        const auto within_top = [&](std::size_t count) {
            return std::any_of(merged.begin(), merged.begin() + static_cast<std::ptrdiff_t>(count), [&](const auto& c) {
                return cents_between(c.frequency_hz, classic_frequency) < unified::kCandidateMergeCents;
            });
        };
        if (!within_top(unified::kMaximumCandidates)) {
            auto tail_match = std::find_if(
                merged.begin() + static_cast<std::ptrdiff_t>(unified::kMaximumCandidates), merged.end(),
                [&](const auto& c) {
                    return cents_between(c.frequency_hz, classic_frequency) < unified::kCandidateMergeCents;
                }
            );
            if (tail_match != merged.end()) {
                std::iter_swap(merged.begin() + static_cast<std::ptrdiff_t>(unified::kMaximumCandidates) - 1, tail_match);
                std::sort(
                    merged.begin(), merged.begin() + static_cast<std::ptrdiff_t>(unified::kMaximumCandidates),
                    candidate_order
                );
            }
        }
    }

    if (merged.size() > unified::kMaximumCandidates) {
        merged.resize(unified::kMaximumCandidates);
    }
    result.candidates = std::move(merged);

    return result;
}

}  // namespace klarivision::core
