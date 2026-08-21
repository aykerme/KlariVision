#include "klarivision/core/vpm_like.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <numeric>
#include <vector>

namespace klarivision::core {
namespace {

double cents_between(const double left, const double right) {
    return 1200.0 * std::log2(left / right);
}

bool is_downward_harmonic_jump(const double previous, const double current) {
    if (current >= previous || std::abs(cents_between(current, previous)) < 650.0) {
        return false;
    }
    for (const auto ratio : {1.0 / 3.0, 0.5, 2.0 / 3.0}) {
        if (std::abs(cents_between(current / previous, ratio)) <= 110.0) {
            return true;
        }
    }
    return false;
}

double parabolic_peak(const std::vector<double>& values, const int index) {
    if (index <= 0 || index + 1 >= static_cast<int>(values.size())) {
        return static_cast<double>(index);
    }
    const auto left = values[index - 1];
    const auto middle = values[index];
    const auto right = values[index + 1];
    const auto denominator = left - 2.0 * middle + right;
    if (std::abs(denominator) < 1e-12) {
        return static_cast<double>(index);
    }
    return static_cast<double>(index) +
        std::clamp(0.5 * (left - right) / denominator, -0.5, 0.5);
}

double spectral_amplitude(
    const std::span<const double> samples,
    const double sample_rate,
    const double frequency
) {
    if (samples.size() < 8 || frequency <= 0.0 || frequency >= sample_rate / 2.0) {
        return 0.0;
    }
    const auto denominator = static_cast<double>(samples.size() - 1);
    const auto step = 2.0 * std::numbers::pi * frequency / sample_rate;
    double real = 0.0;
    double imaginary = 0.0;
    double window_sum = 0.0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / denominator
        );
        const auto value = samples[index] * window;
        const auto phase = step * static_cast<double>(index);
        real += value * std::cos(phase);
        imaginary += value * std::sin(phase);
        window_sum += window;
    }
    return window_sum > 0.0 ? 2.0 * std::hypot(real, imaginary) / window_sum : 0.0;
}

}  // namespace

VPMLikeTracker::VPMLikeTracker(const int downward_harmonic_confirmations)
    : required_confirmations_(std::max(1, downward_harmonic_confirmations)) {}

std::optional<VPMLikePitch> VPMLikeTracker::process(
    std::optional<VPMLikePitch> estimate,
    const std::optional<double> established_upper_to_estimate_ratio
) {
    if (!estimate) {
        reset();
        return std::nullopt;
    }
    if (!published_) {
        published_ = estimate;
        return estimate;
    }
    if (!is_downward_harmonic_jump(published_->frequency_hz, estimate->frequency_hz)) {
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
        *established_upper_to_estimate_ratio >= 2.5;
    if (upper_is_dominant) {
        pending_.reset();
        pending_confirmations_ = 0;
        return VPMLikePitch{published_->frequency_hz, std::min(estimate->confidence, 0.55)};
    }
    // The prior high contour is still a real spectral peak.  Treat a lower
    // 1/2 or 1/3 estimate as ambiguous until it persists; this is a veto, not
    // spectral promotion, so D-011 remains intact.
    const auto upper_is_supported = established_upper_to_estimate_ratio.has_value();
    if (!upper_is_supported) {
        pending_.reset();
        pending_confirmations_ = 0;
        published_ = estimate;
        return estimate;
    }
    if (pending_ && std::abs(cents_between(estimate->frequency_hz, pending_->frequency_hz)) <= 180.0) {
        ++pending_confirmations_;
    } else {
        pending_ = estimate;
        pending_confirmations_ = 1;
    }
    if (pending_confirmations_ >= required_confirmations_) {
        published_ = estimate;
        pending_.reset();
        pending_confirmations_ = 0;
        return estimate;
    }
    return VPMLikePitch{published_->frequency_hz, std::min(estimate->confidence, 0.55)};
}

void VPMLikeTracker::reset() {
    published_.reset();
    pending_.reset();
    pending_confirmations_ = 0;
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
        return std::nullopt;
    }

    const auto mean = std::reduce(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());
    std::vector<double> centered(samples.size());
    double square_sum = 0.0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centered[index] = samples[index] - mean;
        square_sum += centered[index] * centered[index];
    }
    const auto rms = std::sqrt(square_sum / static_cast<double>(centered.size()));
    if (diagnostic) {
        diagnostic->rms = rms;
    }
    if (rms < config.minimum_rms) {
        if (diagnostic) {
            diagnostic->decision = "rejected_rms_below_minimum";
        }
        return std::nullopt;
    }

    const auto minimum_lag = std::max(2, static_cast<int>(sample_rate / config.maximum_frequency_hz));
    const auto maximum_lag = std::min(
        static_cast<int>(centered.size() / 2),
        static_cast<int>(sample_rate / config.minimum_frequency_hz)
    );
    if (minimum_lag + 2 >= maximum_lag) {
        if (diagnostic) {
            diagnostic->decision = "rejected_empty_lag_range";
        }
        return std::nullopt;
    }

    std::vector<double> energy(centered.size() + 1, 0.0);
    for (std::size_t index = 0; index < centered.size(); ++index) {
        energy[index + 1] = energy[index] + centered[index] * centered[index];
    }

    std::vector<double> correlation(maximum_lag + 1, 0.0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        const auto count = static_cast<int>(centered.size()) - lag;
        const auto leading = energy[count];
        const auto delayed = energy[centered.size()] - energy[lag];
        const auto normalization = std::sqrt(std::max(1e-18, leading * delayed));
        double dot = 0.0;
        for (int index = 0; index < count; ++index) {
            dot += centered[index] * centered[index + lag];
        }
        correlation[lag] = dot / normalization;
    }

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
        return std::nullopt;
    }
    const auto strongest = *std::max_element(peaks.begin(), peaks.end(), [&](const int a, const int b) {
        return correlation[a] < correlation[b];
    });
    if (correlation[strongest] < config.minimum_periodicity) {
        if (diagnostic) {
            diagnostic->strongest_periodicity = correlation[strongest];
            diagnostic->decision = "rejected_strongest_periodicity_below_threshold";
        }
        return std::nullopt;
    }

    const auto acceptance = std::max(
        config.minimum_periodicity,
        correlation[strongest] * config.near_strongest_ratio
    );
    auto selected = strongest;
    for (const auto peak : peaks) {
        if (correlation[peak] >= acceptance) {
            selected = peak;
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
    auto weighted_period = parabolic_peak(correlation, selected) * correlation[selected];
    auto weight_sum = correlation[selected];
    for (int multiple = 2; multiple <= config.maximum_period_multiple; ++multiple) {
        const auto expected = selected * multiple;
        if (expected + 2 >= maximum_lag) {
            break;
        }
        const auto radius = std::max(2, selected / 6);
        const auto begin = std::max(minimum_lag + 1, expected - radius);
        const auto end = std::min(maximum_lag - 1, expected + radius);
        auto local = begin;
        for (auto lag = begin + 1; lag <= end; ++lag) {
            if (correlation[lag] > correlation[local]) {
                local = lag;
            }
        }
        if (correlation[local] < config.minimum_periodicity * 0.8) {
            continue;
        }
        const auto weight = correlation[local] * static_cast<double>(multiple);
        weighted_period += parabolic_peak(correlation, local) /
            static_cast<double>(multiple) * weight;
        weight_sum += weight;
    }
    const auto refined_period = weighted_period / std::max(1e-12, weight_sum);
    const auto autocorrelation_frequency = sample_rate / refined_period;
    if (diagnostic) {
        diagnostic->autocorrelation_frequency_hz = autocorrelation_frequency;
    }

    // The 2015 article explicitly tests 1/3, 1/2, 1x, 2x and 3x relatives
    // against the real spectrum, then chooses the lowest plausible one. The
    // exact app thresholds are private; the named config values above are our
    // reproducible interpretation and can be calibrated with regression data.
    const auto base_amplitude = spectral_amplitude(samples, sample_rate, autocorrelation_frequency);
    std::vector<std::pair<double, double>> relatives{
        {1.0 / 3.0, autocorrelation_frequency / 3.0},
        {1.0 / 2.0, autocorrelation_frequency / 2.0},
        {1.0, autocorrelation_frequency},
        {2.0, autocorrelation_frequency * 2.0},
        {3.0, autocorrelation_frequency * 3.0},
    };
    std::sort(relatives.begin(), relatives.end(), [](const auto& left, const auto& right) {
        return left.second < right.second;
    });
    auto chosen_frequency = autocorrelation_frequency;
    bool spectral_candidate_selected = false;
    for (const auto [multiplier, frequency] : relatives) {
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
        const auto amplitude = spectral_amplitude(samples, sample_rate, frequency);
        const auto side_offset = std::max(sample_rate / static_cast<double>(samples.size()), frequency * 0.012);
        const auto left = spectral_amplitude(samples, sample_rate, frequency - side_offset);
        const auto right = spectral_amplitude(samples, sample_rate, frequency + side_offset);
        const auto is_local_peak = amplitude >= left * 1.03 && amplitude >= right * 1.03;
        const auto is_absolute = amplitude >= config.minimum_absolute_spectral_amplitude;
        const auto is_relative = base_amplitude <= 1e-12 ||
            amplitude >= base_amplitude * config.minimum_relative_spectral_amplitude;
        const auto passes = is_local_peak && is_absolute && is_relative;
        // ACF is the periodic estimate. Spectral relatives may correct it
        // downward to a missing fundamental, but a bright upper harmonic must
        // not promote a strong ACF fundamental to 2x/3x.
        const auto does_not_promote = config.allow_spectral_promotion ||
            frequency <= autocorrelation_frequency * (1.0 + 1e-12);
        // The downward spectrum correction exists to repair an earlier,
        // near-strong ACF peak (for example 3f when the true fundamental is
        // weak). If the selected ACF peak is already the strongest peak,
        // overriding it with f/2 or f/3 creates the short subharmonic islands
        // seen in the adverse holdout even though ACF itself is correct.
        const auto does_not_override_strongest_acf = frequency >= autocorrelation_frequency * (1.0 - 1e-12) ||
            selected != strongest;
        const auto is_selected = passes && does_not_promote &&
            does_not_override_strongest_acf && !spectral_candidate_selected;
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
            chosen_frequency = frequency;
            spectral_candidate_selected = true;
            if (!diagnostic) {
                break;
            }
        }
    }

    if (!std::isfinite(chosen_frequency)) {
        if (diagnostic) {
            diagnostic->decision = "rejected_non_finite_frequency";
        }
        return std::nullopt;
    }
    const auto confidence = std::clamp(correlation[selected], 0.0, 1.0);
    if (confidence < config.minimum_output_confidence) {
        if (diagnostic) {
            diagnostic->decision = "rejected_output_confidence_below_threshold";
        }
        return std::nullopt;
    }
    const auto pitch = VPMLikePitch{
        chosen_frequency,
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

std::optional<VPMLikePitch> estimate_vpm_like_pitch(
    const std::span<const double> samples,
    const double sample_rate,
    const VPMLikeConfig& config
) {
    return estimate_impl(samples, sample_rate, config, nullptr);
}

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
