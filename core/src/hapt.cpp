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

constexpr std::size_t kMinimumSamples = 512;
constexpr std::size_t kRecoveryWindowSamples = 768;
constexpr std::size_t kIFHalfWindowSamples = 1024;
constexpr std::size_t kIFShiftSamples = 512;
constexpr std::size_t kIFMinimumSamples = kIFHalfWindowSamples + kIFShiftSamples;  // 1536

double cents_between(const double a, const double b) {
    return 1200.0 * std::log2(a / b);
}

double clamp01(const double value) {
    return std::clamp(value, 0.0, 1.0);
}

double parabolic_refine(const std::vector<double>& values, const int index) {
    if (index <= 0 || index + 1 >= static_cast<int>(values.size())) {
        return static_cast<double>(index);
    }
    const auto left = values[static_cast<std::size_t>(index - 1)];
    const auto middle = values[static_cast<std::size_t>(index)];
    const auto right = values[static_cast<std::size_t>(index + 1)];
    const auto denominator = left - 2.0 * middle + right;
    if (std::abs(denominator) < 1e-12) {
        return static_cast<double>(index);
    }
    return static_cast<double>(index) +
        std::clamp(0.5 * (left - right) / denominator, -0.5, 0.5);
}

bool is_downward_harmonic_jump(
    const double previous,
    const double current,
    const double ratio_cents_tolerance
) {
    if (!(current < previous)) {
        return false;
    }
    for (const auto ratio : {1.0 / 3.0, 0.5}) {
        if (std::abs(cents_between(current / previous, ratio)) <= ratio_cents_tolerance) {
            return true;
        }
    }
    return false;
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
    const auto minimum_lag = std::max(2, static_cast<int>(sample_rate / config.maximum_frequency_hz));
    const auto maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / config.minimum_frequency_hz)
    );
    if (minimum_lag + 2 >= maximum_lag) {
        return std::nullopt;
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
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        double correlation = 0.0;
        double normalisation = 0.0;
        const auto count = static_cast<int>(samples.size()) - lag;
        for (int index = 0; index < count; ++index) {
            const auto leading = static_cast<double>(samples[static_cast<std::size_t>(index)]);
            const auto delayed = static_cast<double>(samples[static_cast<std::size_t>(index + lag)]);
            correlation += leading * delayed;
            normalisation += leading * leading + delayed * delayed;
        }
        if (normalisation > 1e-12) {
            table.values[static_cast<std::size_t>(lag)] = 2.0 * correlation / normalisation;
        }
    }
    return table;
}

/// Returns the NSDF value at an integer lag, or a negative sentinel when the
/// lag falls outside the table's computed range (i.e. "no evidence").
double nsdf_at_lag(const NSDFTable& table, const int lag) {
    if (lag < table.minimum_lag || lag > table.maximum_lag) {
        return -1.0;
    }
    return table.values[static_cast<std::size_t>(lag)];
}

/// Sum of squared spectral magnitude at each `multiples[i] * frequency_hz`
/// probe, skipping any probe at or above a Nyquist guard band.
double probe_energy(
    const std::span<const float> samples,
    const double sample_rate,
    const double frequency_hz,
    const std::span<const double> multiples
) {
    const auto nyquist_guard = sample_rate * 0.475;
    double energy = 0.0;
    for (const auto multiple : multiples) {
        const auto probe_frequency = multiple * frequency_hz;
        if (probe_frequency <= 0.0 || probe_frequency >= nyquist_guard) {
            continue;
        }
        const auto amplitude = std::abs(hann_windowed_probe(samples, sample_rate, probe_frequency));
        energy += amplitude * amplitude;
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
    const auto table = compute_nsdf(samples, sample_rate, config);
    if (!table) {
        return std::nullopt;
    }

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
        return std::nullopt;
    }

    const auto half_width = hann_main_lobe_half_width_hz(samples.size(), sample_rate);
    const auto half_grid_floor_hz = 3.0 * half_width;
    const auto third_grid_floor_hz = 4.5 * half_width;
    const auto nyquist_guard = sample_rate * 0.475;

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
    double global_max_harmonic_energy = 0.0;
    for (const auto lag : peaks) {
        const auto periodicity = clamp01(table->values[static_cast<std::size_t>(lag)]);
        const auto refined_lag = parabolic_refine(table->values, lag);
        if (refined_lag <= 0.0) {
            continue;
        }
        const auto frequency = sample_rate / refined_lag;
        if (!std::isfinite(frequency) || frequency < config.minimum_frequency_hz ||
            frequency > config.maximum_frequency_hz) {
            continue;
        }

        const auto harmonic_count = std::max(1, std::min(
            config.harmonics_considered,
            static_cast<int>(nyquist_guard / frequency)
        ));
        std::vector<double> harmonic_multiples;
        std::vector<double> half_multiples;
        std::vector<double> third_multiples;
        harmonic_multiples.reserve(static_cast<std::size_t>(harmonic_count));
        half_multiples.reserve(static_cast<std::size_t>(harmonic_count));
        third_multiples.reserve(static_cast<std::size_t>(harmonic_count) * 2);
        for (int k = 1; k <= harmonic_count; ++k) {
            harmonic_multiples.push_back(static_cast<double>(k));
            half_multiples.push_back(static_cast<double>(k) - 0.5);
            third_multiples.push_back(static_cast<double>(k) - 1.0 / 3.0);
            third_multiples.push_back(static_cast<double>(k) - 2.0 / 3.0);
        }

        const auto half_resolvable = frequency > half_grid_floor_hz;
        const auto third_resolvable = frequency > third_grid_floor_hz;
        const auto harmonic_energy = probe_energy(samples, sample_rate, frequency, harmonic_multiples);

        double half_veto = 0.0;
        if (half_resolvable) {
            const auto half_energy = probe_energy(samples, sample_rate, frequency, half_multiples);
            const auto total = half_energy + harmonic_energy;
            half_veto = total > 1e-18 ? clamp01(half_energy / total) : 0.0;
        } else {
            const auto lower = nsdf_at_lag(*table, static_cast<int>(std::lround(2.0 * refined_lag)));
            if (lower >= 0.0 && periodicity > 1e-9) {
                half_veto = clamp01(lower / periodicity - 1.0);
            }
        }

        double third_veto = 0.0;
        if (third_resolvable) {
            const auto third_energy = probe_energy(samples, sample_rate, frequency, third_multiples);
            const auto total = third_energy + harmonic_energy;
            third_veto = total > 1e-18 ? clamp01(third_energy / total) : 0.0;
        } else {
            const auto lower = nsdf_at_lag(*table, static_cast<int>(std::lround(3.0 * refined_lag)));
            if (lower >= 0.0 && periodicity > 1e-9) {
                third_veto = clamp01(lower / periodicity - 1.0);
            }
        }

        // Odd-harmonic occupancy: a cylindrical, reed-driven bore (clarinet)
        // suppresses even harmonics by physics, not by having halved the
        // fundamental. Only checking {1, 3, 5} -- never the even harmonics
        // -- is what lets this rule tell the two situations apart; see
        // docs/HAPTPitchEngine.md "Klarnet akustiği".
        std::array<double, 3> odd_amplitudes{};
        std::array<bool, 3> odd_in_range{};
        double loudest_harmonic_amplitude = 0.0;
        for (int k = 1; k <= harmonic_count; ++k) {
            const auto amplitude = std::abs(
                hann_windowed_probe(samples, sample_rate, static_cast<double>(k) * frequency)
            );
            loudest_harmonic_amplitude = std::max(loudest_harmonic_amplitude, amplitude);
            if (k == 1 || k == 3 || k == 5) {
                const std::size_t slot = k == 1 ? 0 : (k == 3 ? 1 : 2);
                odd_amplitudes[slot] = amplitude;
                odd_in_range[slot] = true;
            }
        }
        int odd_present = 0;
        int odd_checked = 0;
        for (std::size_t slot = 0; slot < 3; ++slot) {
            if (!odd_in_range[slot]) {
                continue;
            }
            ++odd_checked;
            if (loudest_harmonic_amplitude > 1e-12 &&
                odd_amplitudes[slot] >= config.odd_harmonic_relative_threshold * loudest_harmonic_amplitude) {
                ++odd_present;
            }
        }
        const auto odd_occupancy = odd_checked > 0
            ? static_cast<double>(odd_present) / static_cast<double>(odd_checked)
            : 1.0;

        global_max_harmonic_energy = std::max(global_max_harmonic_energy, harmonic_energy);
        preliminary.push_back({
            frequency, periodicity, harmonic_energy, half_veto, third_veto,
            half_resolvable, third_resolvable, odd_occupancy,
        });
    }
    if (preliminary.empty()) {
        return std::nullopt;
    }

    // Pass 2: now that the frame's strongest absolute harmonic energy is
    // known, weight each candidate's odd-occupancy term by how much of that
    // energy is actually its own. A candidate with negligible absolute
    // energy (significance near 0) gets a neutral multiplier of 1 instead of
    // a possibly-spurious high or low one; only a candidate with real
    // spectral support (significance near 1) gets the full clarinet-shaped
    // (0.35 + 0.65*occupancy) modulation.
    std::optional<RawHypothesis> best;
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
            : 0.0;
        const auto significance_factor = 0.10 + 0.90 * significance;
        const auto occupancy_factor = 0.35 + 0.65 * candidate.odd_occupancy;
        const auto effective_occupancy_factor = 1.0 - significance * (1.0 - occupancy_factor);

        double continuity_bonus = 0.0;
        if (previous_frequency_hz && *previous_frequency_hz > 0.0) {
            const auto cents = std::abs(cents_between(candidate.frequency_hz, *previous_frequency_hz));
            continuity_bonus = std::clamp(0.10 * (1.0 - cents / 700.0), 0.0, 0.10);
        }

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
            best = RawHypothesis{candidate.frequency_hz, candidate.periodicity, score, diagnostic};
        }
        if (diagnostics_out) {
            diagnostics_out->push_back(diagnostic);
        }
    }
    if (best && diagnostics_out) {
        for (auto& entry : *diagnostics_out) {
            if (entry.frequency_hz == best->frequency_hz) {
                entry.selected = true;
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
    IFLockResult result{frequency_hz, false, 0};
    if (samples.size() < kIFMinimumSamples) {
        return result;
    }
    const auto early = samples.first(kIFHalfWindowSamples);
    const auto late = samples.subspan(kIFShiftSamples, kIFHalfWindowSamples);

    int chosen_harmonic = 0;
    double chosen_strength = -1.0;
    std::complex<double> chosen_early{};
    std::complex<double> chosen_late{};
    for (const int harmonic : {1, 3, 5}) {
        const auto probe_frequency = static_cast<double>(harmonic) * frequency_hz;
        if (probe_frequency <= 0.0 || probe_frequency >= sample_rate * 0.475) {
            continue;
        }
        const auto early_probe = hann_windowed_probe(early, sample_rate, probe_frequency);
        const auto late_probe = hann_windowed_probe(late, sample_rate, probe_frequency);
        const auto strength = std::abs(early_probe) + std::abs(late_probe);
        if (strength > chosen_strength) {
            chosen_strength = strength;
            chosen_harmonic = harmonic;
            chosen_early = early_probe;
            chosen_late = late_probe;
        }
    }
    if (chosen_harmonic == 0) {
        return result;
    }

    const auto early_magnitude = std::abs(chosen_early);
    const auto late_magnitude = std::abs(chosen_late);
    if (early_magnitude <= 1e-12 || late_magnitude <= 1e-12) {
        return result;
    }
    // Guard against attack/transition frames: a genuinely steady tone keeps
    // comparable energy in both sub-windows.
    const auto amplitude_ratio_db = 20.0 * std::log10(late_magnitude / early_magnitude);
    if (std::abs(amplitude_ratio_db) > config.if_lock_max_amplitude_ratio_db) {
        return result;
    }

    const auto phase_difference = std::arg(chosen_late * std::conj(chosen_early));
    const auto deviation_hz = -phase_difference * sample_rate /
        (2.0 * std::numbers::pi * static_cast<double>(kIFShiftSamples));
    const auto refined_probe_frequency = static_cast<double>(chosen_harmonic) * frequency_hz + deviation_hz;
    const auto refined_frequency = refined_probe_frequency / static_cast<double>(chosen_harmonic);
    if (!std::isfinite(refined_frequency) || refined_frequency <= 0.0) {
        return result;
    }
    const auto correction_cents = std::abs(cents_between(refined_frequency, frequency_hz));
    if (correction_cents > config.if_lock_max_cents_correction) {
        return result;
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
        return std::nullopt;
    }

    const auto mean = std::accumulate(
        samples.begin(), samples.end(), 0.0,
        [](const double sum, const float sample) { return sum + static_cast<double>(sample); }
    ) / static_cast<double>(samples.size());
    double square_sum = 0.0;
    for (const auto sample : samples) {
        const auto centered = static_cast<double>(sample) - mean;
        square_sum += centered * centered;
    }
    const auto rms = std::sqrt(square_sum / static_cast<double>(samples.size()));
    if (diagnostic) {
        diagnostic->rms = rms;
        diagnostic->signal_eligible = rms >= config.minimum_rms;
    }
    if (rms < config.minimum_rms) {
        if (diagnostic) {
            diagnostic->decision = "rejected_rms_below_minimum";
        }
        return std::nullopt;
    }

    std::vector<HAPTHypothesisDiagnostic>* hypothesis_sink = diagnostic ? &diagnostic->hypotheses : nullptr;
    auto best = best_hypothesis(samples, sample_rate, config, previous_frequency_hz, hypothesis_sink);

    bool used_recovery = false;
    if ((!best || best->score < config.onset_periodicity_threshold) &&
        samples.size() > kRecoveryWindowSamples) {
        if (diagnostic) {
            diagnostic->onset_recovery_attempted = true;
        }
        const auto tail = best_hypothesis(
            samples.last(kRecoveryWindowSamples), sample_rate, config, previous_frequency_hz, nullptr
        );
        if (tail && tail->score >= config.onset_periodicity_threshold) {
            best = RawHypothesis{tail->frequency_hz, tail->periodicity, tail->score * 0.85, tail->diagnostic};
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
            );
            if (head && head->score >= config.onset_periodicity_threshold) {
                best = RawHypothesis{head->frequency_hz, head->periodicity, head->score * 0.85, head->diagnostic};
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
        return std::nullopt;
    }

    // Two-threshold hysteresis: a hypothesis close to the caller's current
    // contour only needs the lower sustain floor; anything else (a fresh
    // note, or a jump far from the contour) needs the stricter onset bar.
    double required_threshold = config.onset_periodicity_threshold;
    if (previous_frequency_hz && *previous_frequency_hz > 0.0) {
        const auto cents = std::abs(cents_between(best->frequency_hz, *previous_frequency_hz));
        if (cents <= config.sustain_max_cents_from_contour) {
            required_threshold = config.sustain_periodicity_threshold;
        }
    }
    if (best->score < required_threshold) {
        if (diagnostic) {
            diagnostic->decision = "rejected_below_required_threshold";
        }
        return std::nullopt;
    }

    auto frequency = best->frequency_hz;
    if (diagnostic) {
        diagnostic->pre_if_lock_frequency_hz = frequency;
    }
    if (!used_recovery && samples.size() >= kIFMinimumSamples &&
        best->periodicity >= config.if_lock_periodicity_threshold) {
        if (diagnostic) {
            diagnostic->if_lock_attempted = true;
        }
        const auto lock = refine_with_instantaneous_frequency(samples, sample_rate, frequency, config);
        if (lock.applied) {
            frequency = lock.frequency_hz;
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
        ++release_falls_;
    } else if (!release_active_) {
        release_falls_ = 0;
    }
    release_rms_peak_ = std::max(rms, release_rms_peak_ * .995);
    const bool decayed_below_recent_peak = release_rms_peak_ > 0 &&
        rms < release_rms_peak_ * config_.release_decayed_ratio;
    if (release_falls_ >= 2 || decayed_below_recent_peak) {
        release_active_ = true;
    }
    if (release_active_ && rms >= release_rms_peak_ * config_.release_recovery_ratio) {
        release_active_ = false;
        release_falls_ = 0;
    }
    previous_rms_ = rms;

    if (release_active_) {
        published_.reset();
        pending_.reset();
        pending_confirmations_ = 0;
        return std::nullopt;
    }
    if (!estimate) {
        published_.reset();
        pending_.reset();
        pending_confirmations_ = 0;
        return std::nullopt;
    }
    if (!published_) {
        published_ = estimate;
        return estimate;
    }
    const auto downward = is_downward_harmonic_jump(
        published_->frequency_hz, estimate->frequency_hz,
        config_.downward_harmonic_jump_ratio_cents_tolerance
    );
    if (!downward) {
        pending_.reset();
        pending_confirmations_ = 0;
        published_ = estimate;
        return estimate;
    }
    if (pending_ && std::abs(cents_between(estimate->frequency_hz, pending_->frequency_hz)) <= 50.0) {
        ++pending_confirmations_;
    } else {
        pending_ = estimate;
        pending_confirmations_ = 1;
    }
    if (pending_confirmations_ >= std::max(1, config_.downward_harmonic_confirmations)) {
        published_ = estimate;
        pending_.reset();
        pending_confirmations_ = 0;
        return estimate;
    }
    return HAPTPitch{published_->frequency_hz, std::min(estimate->confidence, published_->confidence)};
}

void HAPTTracker::reset() {
    published_.reset();
    pending_.reset();
    pending_confirmations_ = 0;
    previous_rms_ = 0;
    release_rms_peak_ = 0;
    release_falls_ = 0;
    release_active_ = false;
}

}  // namespace klarivision::core
