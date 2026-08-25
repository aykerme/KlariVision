#include "klarivision/core/hapt.hpp"
#include "klarivision/core/harmonic_probe.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <numbers>
#include <numeric>

namespace klarivision::core {
namespace {

constexpr std::size_t kMinimumSamples = 512;            // shortest window HAPT will attempt an estimate on
constexpr std::size_t kRecoveryWindowSamples = 768;      // sub-window length used for onset/decay recovery attempts
constexpr std::size_t kIFHalfWindowSamples = 1024;       // length of each of the two sub-windows probed for the IF phase-lock
constexpr std::size_t kIFShiftSamples = 512;             // time offset between the two IF sub-windows
constexpr std::size_t kIFMinimumSamples = kIFHalfWindowSamples + kIFShiftSamples;  // 1536, minimum frame size the IF refinement needs

// Pitch distance between two frequencies, in cents.
double cents_between(const double a, const double b) {
    return 1200.0 * std::log2(a / b);
}

// Clamp a score/ratio into the valid [0, 1] confidence range.
double clamp01(const double value) {
    return std::clamp(value, 0.0, 1.0);
}

// Sub-sample-accurate peak location via parabolic interpolation (same
// technique as mpm.cpp/vpm_like.cpp): fits a parabola through the three
// samples around `index` and returns the fractional index of its vertex.
double parabolic_refine(const std::vector<double>& values, const int index) {
    if (index <= 0 || index + 1 >= static_cast<int>(values.size())) {
        return static_cast<double>(index);  // no room for both neighbours, can't interpolate
    }
    const auto left = values[static_cast<std::size_t>(index - 1)];
    const auto middle = values[static_cast<std::size_t>(index)];
    const auto right = values[static_cast<std::size_t>(index + 1)];
    const auto denominator = left - 2.0 * middle + right;  // curvature term
    if (std::abs(denominator) < 1e-12) {
        return static_cast<double>(index);  // too flat to interpolate reliably
    }
    return static_cast<double>(index) +
        std::clamp(0.5 * (left - right) / denominator, -0.5, 0.5);  // vertex offset, clamped to +/-0.5
}

// Detects a suspicious downward jump that looks like a harmonic-tracking
// error: `current` fell below `previous` and their ratio sits close to a
// classic subharmonic ratio (1/3 or 1/2). Used by HAPTTracker::process
// below to decide whether a drop needs confirmation before being trusted.
bool is_downward_harmonic_jump(
    const double previous,
    const double current,
    const double ratio_cents_tolerance
) {
    if (!(current < previous)) {
        return false;  // not a downward move at all
    }
    for (const auto ratio : {1.0 / 3.0, 0.5}) {  // 1/3 and 1/2 are the ratios a mistracked harmonic would produce
        if (std::abs(cents_between(current / previous, ratio)) <= ratio_cents_tolerance) {
            return true;  // ratio matches closely enough to be suspicious
        }
    }
    return false;  // a real drop, but not to a recognisable subharmonic ratio
}

/// NSDF (McLeod-style normalized square difference function) over the full
/// resolvable lag range for a window of samples.
struct NSDFTable {
    std::vector<double> values;
    int minimum_lag{};
    int maximum_lag{};
};

std::optional<NSDFTable> compute_nsdf(
    const std::span<const float> samples,
    const double sample_rate,
    const HAPTConfig& config
) {
    const auto minimum_lag = std::max(2, static_cast<int>(sample_rate / config.maximum_frequency_hz));  // shortest period to test (highest pitch)
    const auto maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),                              // never test past half the window
        static_cast<int>(sample_rate / config.minimum_frequency_hz)        // longest period to test (lowest pitch)
    );
    if (minimum_lag + 2 >= maximum_lag) {
        return std::nullopt;  // range too narrow to hold a peak plus its neighbours
    }
    NSDFTable table;
    table.minimum_lag = minimum_lag;
    table.maximum_lag = maximum_lag;
    // One padding zero at each end (indices minimum_lag-1 and maximum_lag+1,
    // both untouched below) lets the peak search below treat the two lag
    // boundaries like any interior point instead of silently excluding them.
    // A true fundamental whose frequency sits close to maximum_frequency_hz
    // has its NSDF peak essentially at minimum_lag itself; without this, that
    // peak could never be selected as a candidate at all.
    table.values.assign(static_cast<std::size_t>(maximum_lag + 2), 0.0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {          // McLeod NSDF, same formula as mpm.cpp
        double correlation = 0.0;                                      // raw autocorrelation at this lag
        double normalisation = 0.0;                                    // combined energy of the two compared windows
        const auto count = static_cast<int>(samples.size()) - lag;     // number of overlapping sample pairs
        for (int index = 0; index < count; ++index) {
            const auto leading = static_cast<double>(samples[static_cast<std::size_t>(index)]);         // sample at time t
            const auto delayed = static_cast<double>(samples[static_cast<std::size_t>(index + lag)]);   // sample at time t + lag
            correlation += leading * delayed;
            normalisation += leading * leading + delayed * delayed;
        }
        if (normalisation > 1e-12) {  // guard against dividing by near-zero energy
            table.values[static_cast<std::size_t>(lag)] = 2.0 * correlation / normalisation;  // McLeod's NSDF normalisation
        }
    }
    return table;
}

/// Returns the NSDF value at an integer lag, or a negative sentinel when the
/// lag falls outside the table's computed range (i.e. "no evidence").
double nsdf_at_lag(const NSDFTable& table, const int lag) {
    if (lag < table.minimum_lag || lag > table.maximum_lag) {
        return -1.0;  // outside the computed range: "no evidence" sentinel
    }
    return table.values[static_cast<std::size_t>(lag)];  // direct lookup of the precomputed NSDF value
}

/// Sum of squared spectral magnitude at each `multiples[i] * frequency_hz`
/// probe, skipping any probe at or above a Nyquist guard band.
double probe_energy(
    const std::span<const float> samples,
    const double sample_rate,
    const double frequency_hz,
    const std::span<const double> multiples
) {
    const auto nyquist_guard = sample_rate * 0.475;  // stay safely below Nyquist to avoid aliasing probes
    double energy = 0.0;
    for (const auto multiple : multiples) {
        const auto probe_frequency = multiple * frequency_hz;   // this probe's actual frequency
        if (probe_frequency <= 0.0 || probe_frequency >= nyquist_guard) {
            continue;  // skip probes that fall outside the representable band
        }
        const auto amplitude = std::abs(hann_windowed_probe(samples, sample_rate, probe_frequency));  // spectral amplitude at this probe frequency
        energy += amplitude * amplitude;  // accumulate as energy (amplitude squared)
    }
    return energy;
}

struct RawHypothesis {
    double frequency_hz{};
    double periodicity{};
    double score{};
    HAPTHypothesisDiagnostic diagnostic{};
};

/// Scores every NSDF peak in `samples` against the inter-harmonic veto
/// (Fikir 1) and a small continuity bonus, returning the strongest one. Does
/// not apply onset/sustain thresholds or the IF refinement -- both are the
/// caller's responsibility so this can be reused unmodified for the onset
/// and decay recovery sub-windows.
std::optional<RawHypothesis> best_hypothesis(
    const std::span<const float> samples,
    const double sample_rate,
    const HAPTConfig& config,
    const std::optional<double> previous_frequency_hz,
    std::vector<HAPTHypothesisDiagnostic>* diagnostics_out
) {
    const auto table = compute_nsdf(samples, sample_rate, config);  // build the NSDF (periodicity-vs-lag) curve for this window
    if (!table) {
        return std::nullopt;  // window too short, or the frequency band collapsed
    }

    // Collect every local maximum of the NSDF above a low noise floor
    // (0.05): each is a plausible period, evaluated in more detail below.
    std::vector<int> peaks;
    for (int lag = table->minimum_lag; lag <= table->maximum_lag; ++lag) {
        const auto previous = table->values[static_cast<std::size_t>(lag - 1)];
        const auto current = table->values[static_cast<std::size_t>(lag)];
        const auto next = table->values[static_cast<std::size_t>(lag + 1)];
        if (current >= previous && current > next && current >= 0.05) {
            peaks.push_back(lag);
        }
    }
    if (peaks.empty()) {
        return std::nullopt;  // no periodicity evidence at all in this window
    }

    const auto half_width = hann_main_lobe_half_width_hz(samples.size(), sample_rate);  // narrowest frequency spacing this window's spectral probes can resolve
    const auto half_grid_floor_hz = 3.0 * half_width;    // below this frequency, a direct spectral half-harmonic probe is unreliable
    const auto third_grid_floor_hz = 4.5 * half_width;   // below this frequency, a direct spectral third-harmonic probe is unreliable
    const auto nyquist_guard = sample_rate * 0.475;       // safety margin below Nyquist for harmonic probes

    // Pass 1: score every peak's periodicity, half/third-grid veto and raw
    // odd-harmonic occupancy, and note each candidate's own absolute
    // harmonic energy. A candidate whose implied harmonics sit nowhere near
    // any real spectral content (a subharmonic far below the true tone, for
    // instance) has odd_amplitudes that are all just window-leakage noise --
    // all mutually comparable, so the {1,3,5}-vs-loudest-of-5 ratio can look
    // spuriously "fully occupied" even though none of it is real. Comparing
    // harmonic_energy across candidates first is what lets pass 2 tell that
    // apart from a candidate whose harmonics carry genuine energy.
    struct PreliminaryHypothesis {
        double frequency_hz{};
        double periodicity{};
        double harmonic_energy{};
        double half_veto{};
        double third_veto{};
        bool half_resolvable{};
        bool third_resolvable{};
        double odd_occupancy{};
    };
    std::vector<PreliminaryHypothesis> preliminary;
    preliminary.reserve(peaks.size());
    double global_max_harmonic_energy = 0.0;  // strongest absolute harmonic energy seen across all candidates, filled in as we go
    for (const auto lag : peaks) {
        const auto periodicity = clamp01(table->values[static_cast<std::size_t>(lag)]);  // NSDF peak height for this candidate
        const auto refined_lag = parabolic_refine(table->values, lag);  // sub-sample-accurate lag via parabolic interpolation
        if (refined_lag <= 0.0) {
            continue;  // interpolation produced a nonsensical lag, skip
        }
        const auto frequency = sample_rate / refined_lag;  // candidate fundamental frequency, in Hz
        if (!std::isfinite(frequency) || frequency < config.minimum_frequency_hz ||
            frequency > config.maximum_frequency_hz) {
            continue;  // outside the analysable pitch range
        }

        // Build the probe-frequency lists needed below: `k * frequency` for
        // the harmonic series itself, `k - 0.5` for the "half-grid" probes
        // that would only be present if the true period were half as long
        // (an octave lower), and `k - 1/3`/`k - 2/3` for the analogous
        // "third-grid" probes for a period a third as long (a twelfth
        // lower).
        const auto harmonic_count = std::max(1, std::min(
            config.harmonics_considered,
            static_cast<int>(nyquist_guard / frequency)
        ));  // how many harmonics of this candidate fit under the Nyquist guard
        std::vector<double> harmonic_multiples;
        std::vector<double> half_multiples;
        std::vector<double> third_multiples;
        harmonic_multiples.reserve(static_cast<std::size_t>(harmonic_count));
        half_multiples.reserve(static_cast<std::size_t>(harmonic_count));
        third_multiples.reserve(static_cast<std::size_t>(harmonic_count) * 2);
        for (int k = 1; k <= harmonic_count; ++k) {
            harmonic_multiples.push_back(static_cast<double>(k));            // k-th harmonic of the candidate itself
            half_multiples.push_back(static_cast<double>(k) - 0.5);          // "half-grid" probe between harmonics k-1 and k
            third_multiples.push_back(static_cast<double>(k) - 1.0 / 3.0);   // "third-grid" probe 1/3 below harmonic k
            third_multiples.push_back(static_cast<double>(k) - 2.0 / 3.0);   // "third-grid" probe 2/3 below harmonic k
        }

        const auto half_resolvable = frequency > half_grid_floor_hz;    // is the candidate high enough for a direct half-grid spectral probe?
        const auto third_resolvable = frequency > third_grid_floor_hz;  // same, for the third-grid probe
        const auto harmonic_energy = probe_energy(samples, sample_rate, frequency, harmonic_multiples);  // total spectral energy at this candidate's own harmonics

        // Inter-harmonic veto against an octave-too-low (half-period)
        // candidate: if the candidate is high enough, probe the spectrum
        // directly at the half-grid locations that only a real octave-down
        // tone would populate; if too low to probe directly, fall back to
        // comparing NSDF peak heights at the doubled lag instead.
        double half_veto = 0.0;  // 0 = no veto evidence, closer to 1 = strong evidence this candidate is really an octave too low
        if (half_resolvable) {
            const auto half_energy = probe_energy(samples, sample_rate, frequency, half_multiples);  // energy that would only exist for a true octave-down tone
            const auto total = half_energy + harmonic_energy;
            half_veto = total > 1e-18 ? clamp01(half_energy / total) : 0.0;  // fraction of combined energy that sits on the "wrong" (half) grid
        } else {
            const auto lower = nsdf_at_lag(*table, static_cast<int>(std::lround(2.0 * refined_lag)));  // NSDF value at twice this candidate's lag (the octave-down period)
            if (lower >= 0.0 && periodicity > 1e-9) {
                half_veto = clamp01(lower / periodicity - 1.0);  // how much stronger the octave-down peak is, relative to this candidate
            }
        }

        // Same idea as half_veto, but for a candidate that might really be
        // a twelfth too low (a third of the true period).
        double third_veto = 0.0;
        if (third_resolvable) {
            const auto third_energy = probe_energy(samples, sample_rate, frequency, third_multiples);
            const auto total = third_energy + harmonic_energy;
            third_veto = total > 1e-18 ? clamp01(third_energy / total) : 0.0;
        } else {
            const auto lower = nsdf_at_lag(*table, static_cast<int>(std::lround(3.0 * refined_lag)));  // NSDF value at three times this candidate's lag
            if (lower >= 0.0 && periodicity > 1e-9) {
                third_veto = clamp01(lower / periodicity - 1.0);
            }
        }

        // Odd-harmonic occupancy: a cylindrical, reed-driven bore (clarinet)
        // suppresses even harmonics by physics, not by having halved the
        // fundamental. Only checking {1, 3, 5} -- never the even harmonics
        // -- is what lets this rule tell the two situations apart; see
        // docs/HAPTPitchEngine.md "Klarnet akustiği".
        std::array<double, 3> odd_amplitudes{};      // amplitude at harmonics 1, 3, 5 (slots 0, 1, 2)
        std::array<bool, 3> odd_in_range{};          // whether each of those harmonics was actually probeable
        double loudest_harmonic_amplitude = 0.0;      // loudest of all probed harmonics, used as the comparison baseline
        for (int k = 1; k <= harmonic_count; ++k) {
            const auto amplitude = std::abs(
                hann_windowed_probe(samples, sample_rate, static_cast<double>(k) * frequency)
            );  // spectral amplitude at the k-th harmonic
            loudest_harmonic_amplitude = std::max(loudest_harmonic_amplitude, amplitude);
            if (k == 1 || k == 3 || k == 5) {
                const std::size_t slot = k == 1 ? 0 : (k == 3 ? 1 : 2);  // map harmonic number to its array slot
                odd_amplitudes[slot] = amplitude;
                odd_in_range[slot] = true;
            }
        }
        int odd_present = 0;   // how many of {1st, 3rd, 5th} harmonics are actually loud enough to count as "present"
        int odd_checked = 0;   // how many of {1st, 3rd, 5th} harmonics were even checkable at this frequency
        for (std::size_t slot = 0; slot < 3; ++slot) {
            if (!odd_in_range[slot]) {
                continue;  // this odd harmonic was above the Nyquist guard, skip it
            }
            ++odd_checked;
            if (loudest_harmonic_amplitude > 1e-12 &&
                odd_amplitudes[slot] >= config.odd_harmonic_relative_threshold * loudest_harmonic_amplitude) {
                ++odd_present;  // this odd harmonic is loud enough, relative to the loudest one, to count as present
            }
        }
        const auto odd_occupancy = odd_checked > 0
            ? static_cast<double>(odd_present) / static_cast<double>(odd_checked)
            : 1.0;  // fraction of checkable odd harmonics that are actually present (clarinet-shaped spectra score high here)

        global_max_harmonic_energy = std::max(global_max_harmonic_energy, harmonic_energy);  // track the strongest candidate seen so far, for pass 2's significance weighting
        preliminary.push_back({
            frequency, periodicity, harmonic_energy, half_veto, third_veto,
            half_resolvable, third_resolvable, odd_occupancy,
        });
    }
    if (preliminary.empty()) {
        return std::nullopt;  // every peak was rejected (bad lag, out-of-range frequency, ...)
    }

    // Pass 2: now that the frame's strongest absolute harmonic energy is
    // known, weight each candidate's odd-occupancy term by how much of that
    // energy is actually its own. A candidate with negligible absolute
    // energy (significance near 0) gets a neutral multiplier of 1 instead of
    // a possibly-spurious high or low one; only a candidate with real
    // spectral support (significance near 1) gets the full clarinet-shaped
    // (0.35 + 0.65*occupancy) modulation.
    std::optional<RawHypothesis> best;  // running best-scoring candidate across this pass
    for (const auto& candidate : preliminary) {
        // NSDF alone cannot separate the true period from any of its
        // integer multiples (2tau, 3tau, ..., k*tau all look comparably
        // periodic for a truly periodic waveform); only the half/third-grid
        // veto is checked explicitly, so an uncontested subharmonic far
        // below the true tone would otherwise win outright on periodicity.
        // `significance` is the generic guard for every other multiple: a
        // candidate whose own implied harmonics explain essentially none of
        // the frame's real spectral energy is suppressed regardless of how
        // periodic it measures, while a candidate that explains a real share
        // of it -- the true fundamental, or a legitimate close harmonic --
        // keeps its score close to unmodified.
        const auto significance = global_max_harmonic_energy > 1e-18
            ? clamp01(candidate.harmonic_energy / global_max_harmonic_energy)
            : 0.0;  // how much of the frame's total harmonic energy belongs to this candidate, 0..1
        const auto significance_factor = 0.10 + 0.90 * significance;  // never fully zero out a candidate, but scale strongly by significance
        const auto occupancy_factor = 0.35 + 0.65 * candidate.odd_occupancy;  // clarinet-shaped odd-harmonic occupancy modulation
        const auto effective_occupancy_factor = 1.0 - significance * (1.0 - occupancy_factor);  // blend toward "neutral" (1.0) for insignificant candidates

        // Small bonus for staying near the caller's previously tracked
        // pitch, up to 700 cents away; helps stabilise the winner among
        // near-tied candidates without overriding strong contrary evidence.
        double continuity_bonus = 0.0;
        if (previous_frequency_hz && *previous_frequency_hz > 0.0) {
            const auto cents = std::abs(cents_between(candidate.frequency_hz, *previous_frequency_hz));  // distance from the previous pitch, in cents
            continuity_bonus = std::clamp(0.10 * (1.0 - cents / 700.0), 0.0, 0.10);  // up to +0.10, decaying linearly to 0 by 700 cents away
        }

        // Final combined score: periodicity, scaled down by how
        // insignificant/non-clarinet-shaped the candidate's harmonics look,
        // and by the half/third-grid vetoes (each veto can cut the score by
        // up to 90%), plus the small continuity nudge.
        const auto score = clamp01(
            candidate.periodicity * effective_occupancy_factor * significance_factor *
            (1.0 - 0.9 * candidate.half_veto) * (1.0 - 0.9 * candidate.third_veto) + continuity_bonus
        );

        const HAPTHypothesisDiagnostic diagnostic{
            candidate.frequency_hz, candidate.periodicity, candidate.odd_occupancy,
            candidate.half_veto, candidate.third_veto,
            candidate.half_resolvable, candidate.third_resolvable, continuity_bonus, score, false,
        };
        if (!best || score > best->score) {
            best = RawHypothesis{candidate.frequency_hz, candidate.periodicity, score, diagnostic};  // new best-scoring candidate
        }
        if (diagnostics_out) {
            diagnostics_out->push_back(diagnostic);  // record every candidate's full scoring breakdown, not just the winner
        }
    }
    if (best && diagnostics_out) {
        for (auto& entry : *diagnostics_out) {
            if (entry.frequency_hz == best->frequency_hz) {
                entry.selected = true;  // mark the winning entry in the diagnostic record after the fact
            }
        }
    }
    return best;
}

struct IFLockResult {
    double frequency_hz{};
    bool applied{};
    int harmonic{};
};

/// Fikir 2: refines `frequency_hz` using the phase drift, at the strongest
/// odd harmonic, between two 1024-sample sub-windows offset by 512 samples
/// within the same 1536-sample analysis frame. See docs/HAPTPitchEngine.md
/// for the derivation of the +/- 93.75 Hz unambiguous range this relies on.
IFLockResult refine_with_instantaneous_frequency(
    const std::span<const float> samples,
    const double sample_rate,
    const double frequency_hz,
    const HAPTConfig& config
) {
    IFLockResult result{frequency_hz, false, 0};  // default: unrefined, unless every check below passes
    if (samples.size() < kIFMinimumSamples) {
        return result;  // not enough samples for the two offset sub-windows
    }
    const auto early = samples.first(kIFHalfWindowSamples);                    // first 1024-sample sub-window
    const auto late = samples.subspan(kIFShiftSamples, kIFHalfWindowSamples);  // second sub-window, shifted 512 samples later

    // Pick whichever of the 1st, 3rd or 5th harmonic has the strongest
    // combined probe response across both sub-windows -- that is the
    // cleanest phase reference available this frame.
    int chosen_harmonic = 0;
    double chosen_strength = -1.0;
    std::complex<double> chosen_early{};
    std::complex<double> chosen_late{};
    for (const int harmonic : {1, 3, 5}) {
        const auto probe_frequency = static_cast<double>(harmonic) * frequency_hz;  // this harmonic's frequency
        if (probe_frequency <= 0.0 || probe_frequency >= sample_rate * 0.475) {
            continue;  // outside the safely representable band
        }
        const auto early_probe = hann_windowed_probe(early, sample_rate, probe_frequency);  // complex spectral probe in the early sub-window
        const auto late_probe = hann_windowed_probe(late, sample_rate, probe_frequency);     // same probe in the late sub-window
        const auto strength = std::abs(early_probe) + std::abs(late_probe);                  // combined magnitude, used to pick the best harmonic
        if (strength > chosen_strength) {
            chosen_strength = strength;
            chosen_harmonic = harmonic;
            chosen_early = early_probe;
            chosen_late = late_probe;
        }
    }
    if (chosen_harmonic == 0) {
        return result;  // no usable harmonic found (all out of band)
    }

    const auto early_magnitude = std::abs(chosen_early);
    const auto late_magnitude = std::abs(chosen_late);
    if (early_magnitude <= 1e-12 || late_magnitude <= 1e-12) {
        return result;  // one of the two probes found essentially no energy: unreliable phase
    }
    // Guard against attack/transition frames: a genuinely steady tone keeps
    // comparable energy in both sub-windows.
    const auto amplitude_ratio_db = 20.0 * std::log10(late_magnitude / early_magnitude);  // how much louder/quieter the late window is, in dB
    if (std::abs(amplitude_ratio_db) > config.if_lock_max_amplitude_ratio_db) {
        return result;  // amplitude changed too much between sub-windows to trust the phase drift
    }

    // Phase-locked instantaneous frequency: the phase drift of the chosen
    // harmonic between the two time-shifted sub-windows is directly
    // proportional to how far the true frequency deviates from the probe
    // frequency (see docs/HAPTPitchEngine.md for the derivation and its
    // +/-93.75 Hz unambiguous range).
    const auto phase_difference = std::arg(chosen_late * std::conj(chosen_early));  // phase drift between the two sub-window probes
    const auto deviation_hz = -phase_difference * sample_rate /
        (2.0 * std::numbers::pi * static_cast<double>(kIFShiftSamples));  // convert phase drift -> frequency deviation from the probe frequency
    const auto refined_probe_frequency = static_cast<double>(chosen_harmonic) * frequency_hz + deviation_hz;  // corrected harmonic frequency
    const auto refined_frequency = refined_probe_frequency / static_cast<double>(chosen_harmonic);  // back down to a fundamental-frequency estimate
    if (!std::isfinite(refined_frequency) || refined_frequency <= 0.0) {
        return result;  // numerical failure, discard the refinement
    }
    const auto correction_cents = std::abs(cents_between(refined_frequency, frequency_hz));  // size of the correction being proposed
    if (correction_cents > config.if_lock_max_cents_correction) {
        return result;  // correction implausibly large: likely phase-wrap ambiguity, not a real refinement
    }
    result.frequency_hz = refined_frequency;
    result.applied = true;
    result.harmonic = chosen_harmonic;
    return result;
}

std::optional<HAPTPitch> estimate_impl(
    const std::span<const float> samples,
    const double sample_rate,
    const HAPTConfig& config,
    const std::optional<double> previous_frequency_hz,
    HAPTFrameDiagnostic* diagnostic
) {
    if (samples.size() < kMinimumSamples || sample_rate <= 0.0) {
        if (diagnostic) {
            diagnostic->decision = "rejected_invalid_frame_or_sample_rate";
        }
        return std::nullopt;  // not enough signal, or an invalid sample rate
    }

    // DC removal + RMS silence gate, same reasoning as the other engines.
    const auto mean = std::accumulate(
        samples.begin(), samples.end(), 0.0,
        [](const double sum, const float sample) { return sum + static_cast<double>(sample); }
    ) / static_cast<double>(samples.size());
    double square_sum = 0.0;
    for (const auto sample : samples) {
        const auto centered = static_cast<double>(sample) - mean;  // DC-free sample
        square_sum += centered * centered;                          // accumulate squared amplitude
    }
    const auto rms = std::sqrt(square_sum / static_cast<double>(samples.size()));  // window loudness
    if (diagnostic) {
        diagnostic->rms = rms;
        diagnostic->signal_eligible = rms >= config.minimum_rms;
    }
    if (rms < config.minimum_rms) {
        if (diagnostic) {
            diagnostic->decision = "rejected_rms_below_minimum";
        }
        return std::nullopt;  // too quiet to trust a pitch estimate
    }

    std::vector<HAPTHypothesisDiagnostic>* hypothesis_sink = diagnostic ? &diagnostic->hypotheses : nullptr;
    auto best = best_hypothesis(samples, sample_rate, config, previous_frequency_hz, hypothesis_sink);  // score every NSDF peak over the full window

    // Onset/decay recovery: if the full-window analysis found nothing
    // confident enough, the note may just be starting (onset) or ending
    // (decay/reverb tail) within this window, diluting the periodicity
    // measured over the whole thing. Retry on just the tail sub-window
    // (assume onset: signal recently became periodic) and, failing that,
    // just the head sub-window (assume decay: signal was periodic and is
    // now dying out). A successful recovery is scored down by 15% since it
    // only saw part of the window's evidence.
    bool used_recovery = false;
    if ((!best || best->score < config.onset_periodicity_threshold) &&
        samples.size() > kRecoveryWindowSamples) {
        if (diagnostic) {
            diagnostic->onset_recovery_attempted = true;
        }
        const auto tail = best_hypothesis(
            samples.last(kRecoveryWindowSamples), sample_rate, config, previous_frequency_hz, nullptr
        );  // re-analyse just the most recent part of the window
        if (tail && tail->score >= config.onset_periodicity_threshold) {
            best = RawHypothesis{tail->frequency_hz, tail->periodicity, tail->score * 0.85, tail->diagnostic};  // accept, with a confidence penalty
            used_recovery = true;
            if (diagnostic) {
                diagnostic->onset_recovery_used = true;
            }
        } else {
            if (diagnostic) {
                diagnostic->decay_recovery_attempted = true;
            }
            const auto head = best_hypothesis(
                samples.first(kRecoveryWindowSamples), sample_rate, config, previous_frequency_hz, nullptr
            );  // re-analyse just the earliest part of the window instead
            if (head && head->score >= config.onset_periodicity_threshold) {
                best = RawHypothesis{head->frequency_hz, head->periodicity, head->score * 0.85, head->diagnostic};  // accept, with the same penalty
                used_recovery = true;
                if (diagnostic) {
                    diagnostic->decay_recovery_used = true;
                }
            }
        }
    }

    if (!best) {
        if (diagnostic) {
            diagnostic->decision = "rejected_no_hypothesis";
        }
        return std::nullopt;  // no plausible pitch found even after recovery attempts
    }

    // Two-threshold hysteresis: a hypothesis close to the caller's current
    // contour only needs the lower sustain floor; anything else (a fresh
    // note, or a jump far from the contour) needs the stricter onset bar.
    double required_threshold = config.onset_periodicity_threshold;  // strict bar by default (fresh note / uncertain continuity)
    if (previous_frequency_hz && *previous_frequency_hz > 0.0) {
        const auto cents = std::abs(cents_between(best->frequency_hz, *previous_frequency_hz));  // distance from the caller's current tracked contour
        if (cents <= config.sustain_max_cents_from_contour) {
            required_threshold = config.sustain_periodicity_threshold;  // close to the existing contour: allow the looser sustain bar
        }
    }
    if (best->score < required_threshold) {
        if (diagnostic) {
            diagnostic->decision = "rejected_below_required_threshold";
        }
        return std::nullopt;  // best candidate isn't confident enough given its context
    }

    auto frequency = best->frequency_hz;
    if (diagnostic) {
        diagnostic->pre_if_lock_frequency_hz = frequency;
    }
    // Instantaneous-frequency phase-lock refinement (Fikir 2): only attempt
    // it on a full, un-recovered window with a periodicity high enough to
    // trust the phase measurement.
    if (!used_recovery && samples.size() >= kIFMinimumSamples &&
        best->periodicity >= config.if_lock_periodicity_threshold) {
        if (diagnostic) {
            diagnostic->if_lock_attempted = true;
        }
        const auto lock = refine_with_instantaneous_frequency(samples, sample_rate, frequency, config);
        if (lock.applied) {
            frequency = lock.frequency_hz;  // adopt the phase-refined frequency
            if (diagnostic) {
                diagnostic->if_lock_applied = true;
                diagnostic->if_lock_harmonic = lock.harmonic;
            }
        }
    }

    const HAPTPitch pitch{frequency, best->score};
    if (diagnostic) {
        diagnostic->pitch = pitch;
        diagnostic->decision = used_recovery
            ? "selected_onset_or_decay_recovery"
            : (diagnostic->if_lock_applied ? "selected_phase_locked_if_refined" : "selected_full_window_peak");
    }
    return pitch;
}

}  // namespace

std::optional<HAPTPitch> estimate_hapt_pitch(
    const std::span<const float> samples,
    const double sample_rate,
    const HAPTConfig& config,
    const std::optional<double> previous_frequency_hz
) {
    return estimate_impl(samples, sample_rate, config, previous_frequency_hz, nullptr);
}

HAPTFrameDiagnostic diagnose_hapt_pitch(
    const std::span<const float> samples,
    const double sample_rate,
    const HAPTConfig& config,
    const std::optional<double> previous_frequency_hz
) {
    HAPTFrameDiagnostic diagnostic;
    estimate_impl(samples, sample_rate, config, previous_frequency_hz, &diagnostic);
    return diagnostic;
}

HAPTTracker::HAPTTracker(const HAPTConfig& config) : config_(config) {}

std::optional<HAPTPitch> HAPTTracker::process(std::optional<HAPTPitch> estimate, const double rms) {
    // RMS release detector: two consecutive sharp falls (an ordinary release)
    // or a direct drop below a fraction of the recent peak (a gentler
    // room-reverb tail) arm it; a recovered envelope un-arms it. See
    // HAPTConfig's release_* fields. This runs before the harmonic-jump
    // logic below and independently of `estimate`, so a still-decaying tail
    // stays suppressed even on a frame the estimator judged loud/periodic
    // enough to report (the sustain threshold is deliberately permissive).
    if (previous_rms_ > 0 && rms < previous_rms_ * config_.release_fall_ratio) {
        ++release_falls_;  // this frame fell sharply from the previous one: one step toward "release" detection
    } else if (!release_active_) {
        release_falls_ = 0;  // no sharp fall (and not already releasing): reset the fall counter
    }
    release_rms_peak_ = std::max(rms, release_rms_peak_ * .995);  // slowly-decaying running peak, tracks the loudest recent moment
    const bool decayed_below_recent_peak = release_rms_peak_ > 0 &&
        rms < release_rms_peak_ * config_.release_decayed_ratio;  // signal has quietly faded well below its recent peak (reverb-tail case)
    if (release_falls_ >= 2 || decayed_below_recent_peak) {
        release_active_ = true;  // arm release suppression: two sharp falls, or a decayed-below-peak tail
    }
    if (release_active_ && rms >= release_rms_peak_ * config_.release_recovery_ratio) {
        release_active_ = false;  // signal came back up enough: this was not actually a release
        release_falls_ = 0;
    }
    previous_rms_ = rms;  // remember this frame's RMS for next call's fall comparison

    if (release_active_) {
        // Suppress output entirely while a release/decay tail is active,
        // regardless of what the estimator itself reported this frame.
        published_.reset();
        pending_.reset();
        pending_confirmations_ = 0;
        return std::nullopt;
    }
    if (!estimate) {
        // No pitch this frame (silence/unvoiced): clear tracking state.
        published_.reset();
        pending_.reset();
        pending_confirmations_ = 0;
        return std::nullopt;
    }
    if (!published_) {
        published_ = estimate;  // first-ever estimate: publish directly
        return estimate;
    }
    const auto downward = is_downward_harmonic_jump(
        published_->frequency_hz, estimate->frequency_hz,
        config_.downward_harmonic_jump_ratio_cents_tolerance
    );  // does this frame look like a harmonic-tracking drop from the published pitch?
    if (!downward) {
        // Ordinary movement: publish immediately, clear pending state.
        pending_.reset();
        pending_confirmations_ = 0;
        published_ = estimate;
        return estimate;
    }
    if (pending_ && std::abs(cents_between(estimate->frequency_hz, pending_->frequency_hz)) <= 50.0) {
        ++pending_confirmations_;  // same pending candidate seen again: one more confirmation
    } else {
        pending_ = estimate;          // new (or first) pending candidate: restart the confirmation streak
        pending_confirmations_ = 1;
    }
    if (pending_confirmations_ >= std::max(1, config_.downward_harmonic_confirmations)) {
        // Confirmed across enough frames: trust the drop.
        published_ = estimate;
        pending_.reset();
        pending_confirmations_ = 0;
        return estimate;
    }
    // Not confirmed yet: keep republishing the old pitch while the
    // suspicious drop accumulates confirmations, with confidence capped by
    // whichever of the two pitches is less certain.
    return HAPTPitch{published_->frequency_hz, std::min(estimate->confidence, published_->confidence)};
}

void HAPTTracker::reset() {
    published_.reset();          // clear the currently published pitch
    pending_.reset();            // clear any pitch awaiting confirmation
    pending_confirmations_ = 0;  // reset the confirmation streak
    previous_rms_ = 0;           // forget the previous frame's loudness
    release_rms_peak_ = 0;       // forget the tracked recent loudness peak
    release_falls_ = 0;          // reset the sharp-fall counter
    release_active_ = false;     // clear release suppression
}

}  // namespace klarivision::core
