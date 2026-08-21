#include "klarivision/core/pitch_engine_v2_session.hpp"

#include "klarivision/core/swipe_prime.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <numeric>
#include <stdexcept>
#include <vector>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace klarivision::core::v2 {
namespace {

constexpr double kMinimumFrequency = 80.0;
constexpr double kMaximumFrequency = 1500.0;
constexpr double kAnalysisMaximumFrequency = 1650.0;

float float_dot(const float* left, const float* right, const std::size_t count) {
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

double centered_rms(const std::span<const float> samples) {
    if (samples.empty()) return 0;
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());
    double sum = 0;
    for (const float sample : samples) {
        const double centered = static_cast<double>(sample) - mean;
        sum += centered * centered;
    }
    return std::sqrt(sum / static_cast<double>(samples.size()));
}

std::vector<PitchCandidate> yin_candidates(
    const std::span<const float> samples,
    const double sample_rate
) {
    if (samples.size() < 1024) return {};
    const int minimum_lag = std::max(2, static_cast<int>(sample_rate / kAnalysisMaximumFrequency));
    const int maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / kMinimumFrequency)
    );
    if (minimum_lag + 2 >= maximum_lag) return {};

    std::vector<float> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        energy[index + 1] = energy[index] + samples[index] * samples[index];
    }
    std::vector<float> difference(static_cast<std::size_t>(maximum_lag + 1), 0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        const auto count = samples.size() - static_cast<std::size_t>(lag);
        const float correlation = float_dot(samples.data(), samples.data() + lag, count);
        difference[static_cast<std::size_t>(lag)] = std::max(
            0.0F,
            energy[count] + (energy[samples.size()] - energy[static_cast<std::size_t>(lag)]) -
                2.0F * correlation
        );
    }
    std::vector<float> normalized(static_cast<std::size_t>(maximum_lag + 1), 1);
    float cumulative = 0;
    for (int lag = 1; lag <= maximum_lag; ++lag) {
        cumulative += difference[static_cast<std::size_t>(lag)];
        if (cumulative > 0) {
            normalized[static_cast<std::size_t>(lag)] =
                difference[static_cast<std::size_t>(lag)] * static_cast<float>(lag) / cumulative;
        }
    }

    std::vector<PitchCandidate> result;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        const float previous = normalized[static_cast<std::size_t>(lag - 1)];
        const float current = normalized[static_cast<std::size_t>(lag)];
        const float following = normalized[static_cast<std::size_t>(lag + 1)];
        if (!(current <= previous && current < following && current < 0.50F)) continue;
        const float denominator = previous - 2.0F * current + following;
        const float correction = std::abs(denominator) > 0.000001F
            ? std::clamp(0.5F * (previous - following) / denominator, -0.5F, 0.5F)
            : 0.0F;
        const double frequency = sample_rate / (static_cast<double>(lag) + correction);
        if (std::isfinite(frequency) && frequency >= kMinimumFrequency &&
            frequency <= kAnalysisMaximumFrequency) {
            result.push_back(PitchCandidate{
                frequency,
                std::clamp(static_cast<double>(1.0F - current), 0.0, 1.0),
                0,
                CandidateSource::yin,
            });
        }
    }
    return result;
}

std::optional<PitchCandidate> autocorrelation_candidate(
    const std::span<const float> samples,
    const double sample_rate
) {
    if (samples.size() < 1024) return std::nullopt;
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());
    std::vector<float> centered(samples.size());
    std::vector<double> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centered[index] = static_cast<float>(static_cast<double>(samples[index]) - mean);
        const double value = centered[index];
        energy[index + 1] = energy[index] + value * value;
    }
    const int minimum_lag = std::max(2, static_cast<int>(sample_rate / kMaximumFrequency));
    const int maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / kMinimumFrequency)
    );
    if (minimum_lag + 2 >= maximum_lag) return std::nullopt;
    std::vector<double> correlation(static_cast<std::size_t>(maximum_lag + 1), 0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        const auto count = centered.size() - static_cast<std::size_t>(lag);
        const double denominator = std::sqrt(std::max(
            1e-12,
            energy[count] * (energy[centered.size()] - energy[static_cast<std::size_t>(lag)])
        ));
        correlation[static_cast<std::size_t>(lag)] =
            static_cast<double>(float_dot(centered.data(), centered.data() + lag, count)) /
            denominator;
    }
    std::vector<int> peaks;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        if (correlation[static_cast<std::size_t>(lag)] >= correlation[static_cast<std::size_t>(lag - 1)] &&
            correlation[static_cast<std::size_t>(lag)] > correlation[static_cast<std::size_t>(lag + 1)]) {
            peaks.push_back(lag);
        }
    }
    if (peaks.empty()) return std::nullopt;
    const int strongest = *std::max_element(peaks.begin(), peaks.end(), [&](const int left, const int right) {
        return correlation[static_cast<std::size_t>(left)] < correlation[static_cast<std::size_t>(right)];
    });
    if (correlation[static_cast<std::size_t>(strongest)] < 0.38) return std::nullopt;
    const double acceptance = std::max(0.52, correlation[static_cast<std::size_t>(strongest)] * 0.84);
    const auto accepted = std::find_if(peaks.begin(), peaks.end(), [&](const int lag) {
        return correlation[static_cast<std::size_t>(lag)] >= acceptance;
    });
    const int selected = accepted == peaks.end() ? strongest : *accepted;
    const double previous = correlation[static_cast<std::size_t>(selected - 1)];
    const double current = correlation[static_cast<std::size_t>(selected)];
    const double following = correlation[static_cast<std::size_t>(selected + 1)];
    const double denominator = previous - 2 * current + following;
    const double correction = std::abs(denominator) > 1e-6
        ? std::clamp(0.5 * (previous - following) / denominator, -0.5, 0.5) : 0;
    const double frequency = sample_rate / (static_cast<double>(selected) + correction);
    if (frequency < kMinimumFrequency || frequency > kMaximumFrequency) return std::nullopt;
    return PitchCandidate{frequency, std::clamp(current, 0.0, 1.0), 0, CandidateSource::autocorrelation};
}

std::vector<PitchCandidate> mpm_candidates_exact(
    const std::span<const float> samples,
    const double sample_rate
) {
    if (samples.size() < 1024) return {};
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());
    std::vector<float> centered(samples.size());
    std::vector<float> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centered[index] = static_cast<float>(static_cast<double>(samples[index]) - mean);
        energy[index + 1] = energy[index] + centered[index] * centered[index];
    }
    const int minimum_lag = std::max(2, static_cast<int>(sample_rate / kMaximumFrequency));
    const int maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / kMinimumFrequency)
    );
    std::vector<float> nsdf(static_cast<std::size_t>(maximum_lag + 1), 0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        const auto count = centered.size() - static_cast<std::size_t>(lag);
        const float normalization = energy[count] +
            (energy[centered.size()] - energy[static_cast<std::size_t>(lag)]);
        if (normalization > 1e-9F) {
            nsdf[static_cast<std::size_t>(lag)] =
                2.0F * float_dot(centered.data(), centered.data() + lag, count) / normalization;
        }
    }
    std::vector<PitchCandidate> result;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        const float previous = nsdf[static_cast<std::size_t>(lag - 1)];
        const float current = nsdf[static_cast<std::size_t>(lag)];
        const float following = nsdf[static_cast<std::size_t>(lag + 1)];
        if (current < 0.55F || current < previous || current <= following) continue;
        const float denominator = previous - 2.0F * current + following;
        const float correction = std::abs(denominator) > 1e-6F
            ? std::clamp(0.5F * (previous - following) / denominator, -0.5F, 0.5F) : 0;
        const double frequency = sample_rate / (static_cast<double>(lag) + correction);
        if (frequency >= kMinimumFrequency && frequency <= kMaximumFrequency) {
            result.push_back(PitchCandidate{
                frequency, std::clamp(static_cast<double>(current), 0.0, 1.0), 0,
                CandidateSource::mpm,
            });
        }
    }
    std::stable_sort(result.begin(), result.end(), [](const auto& left, const auto& right) {
        return left.periodicity > right.periodicity;
    });
    if (result.size() > 12) result.resize(12);
    return result;
}

double spectral_energy(
    const std::span<const float> samples,
    const double sample_rate,
    const double frequency
) {
    if (frequency <= 0 || samples.size() <= 8) return 0;
    const double angular_step = 2 * std::numbers::pi * frequency / sample_rate;
    const double denominator = static_cast<double>(std::max<std::size_t>(1, samples.size() - 1));
    double cosine = 0;
    double sine = 0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double window = 0.5 - 0.5 * std::cos(
            2 * std::numbers::pi * static_cast<double>(index) / denominator
        );
        const double phase = angular_step * static_cast<double>(index);
        const double value = static_cast<double>(samples[index]) * window;
        cosine += value * std::cos(phase);
        sine += value * std::sin(phase);
    }
    return cosine * cosine + sine * sine;
}

double cents(const double first, const double second) {
    return std::abs(1200 * std::log2(first / second));
}

std::vector<ScoredPitchCandidate> scored_candidates(
    const std::span<const float> samples,
    const double sample_rate,
    const double window_rms,
    const double recent_rms_peak,
    const bool preserve_slow_fade
) {
    auto candidates = yin_candidates(samples, sample_rate);
    candidates.erase(std::remove_if(candidates.begin(), candidates.end(), [](const auto& item) {
        return item.periodicity < 0.50;
    }), candidates.end());
    if (const auto candidate = autocorrelation_candidate(samples, sample_rate)) {
        candidates.push_back(*candidate);
    }
    const auto mpm = mpm_candidates_exact(samples, sample_rate);
    candidates.insert(candidates.end(), mpm.begin(), mpm.end());
    const auto strongest = std::max_element(candidates.begin(), candidates.end(), [](const auto& left, const auto& right) {
        return left.periodicity < right.periodicity;
    });
    if (!preserve_slow_fade && strongest != candidates.end() && strongest->periodicity < 0.90 &&
        window_rms < recent_rms_peak * 0.35) {
        candidates.clear();
    }
    const auto original_count = candidates.size();
    for (std::size_t index = 0; index < original_count; ++index) {
        const double upper = candidates[index].frequency_hz * 2;
        if (upper <= 900 || upper > kAnalysisMaximumFrequency) continue;
        if (spectral_energy(samples, sample_rate, upper) >
            spectral_energy(samples, sample_rate, candidates[index].frequency_hz) * 8) {
            candidates.push_back(PitchCandidate{
                upper, std::max(0.92, candidates[index].periodicity), 0, CandidateSource::spectral,
            });
        }
    }
    if (candidates.empty()) return {};

    std::vector<double> frequencies;
    frequencies.reserve(candidates.size());
    for (const auto& candidate : candidates) frequencies.push_back(candidate.frequency_hz);
    const auto supports = swipe_prime_harmonic_supports(samples, sample_rate, frequencies);
    std::vector<ScoredPitchCandidate> result;
    result.reserve(candidates.size());
    for (std::size_t index = 0; index < candidates.size(); ++index) {
        bool agrees = false;
        for (std::size_t other = 0; other < candidates.size(); ++other) {
            if (candidates[other].source != candidates[index].source &&
                cents(candidates[other].frequency_hz, candidates[index].frequency_hz) <= 55) {
                agrees = true;
                break;
            }
        }
        candidates[index].harmonic_support = supports[index];
        candidates[index].agreement_support = agrees;
        const double agreement = agrees ? 1.0 : 0.25;
        double score = 0.40 * candidates[index].periodicity + 0.20 * agreement +
            0.40 * supports[index];
        // This candidate exists only when its exact 2× spectral bin is at
        // least eight times stronger than the lower-period candidate. That
        // is direct fundamental evidence, not a generic octave preference;
        // keep the tracker from discarding it merely because period-domain
        // estimators agree on the lower harmonic.
        if (candidates[index].source == CandidateSource::spectral) {
            score = std::max(score, 0.90);
        }
        result.push_back(ScoredPitchCandidate{candidates[index], score});
    }
    return result;
}

bool high_register_evidence(const PitchCandidate& candidate) {
    return candidate.agreement_support || (candidate.frequency_hz > 900 && candidate.periodicity >= 0.80 &&
        candidate.harmonic_support >= 0.75);
}

}  // namespace

PitchEngineV2Session::PitchEngineV2Session(
    const double minimum_rms,
    const std::size_t fixed_lag_frames
) : minimum_rms_(minimum_rms), tracker_(fixed_lag_frames, 700) {}

std::vector<PublishedPitchFrame> PitchEngineV2Session::process_frame(
    const std::span<const float> samples,
    const double sample_rate,
    const double source_time_seconds
) {
    if (finished_) throw std::logic_error("V2 session is finished; call reset before processing more frames");
    const double rms = centered_rms(samples);
    const bool eligible = rms >= minimum_rms_;
    // A real note release falls much faster than the intentionally slow
    // fade-down/up exercise.  Remember the state with each source frame so
    // delayed Viterbi resolution never applies a later window's gate.
    const bool was_release_active = release_active_;
    if (previous_rms_ > 0 && rms < previous_rms_ * 0.80) {
        ++release_falls_;
    } else if (!release_active_) {
        release_falls_ = 0;
    }
    release_rms_peak_ = std::max(rms, release_rms_peak_ * 0.995);
    if (release_falls_ >= 2) release_active_ = true;
    // Do not arm and immediately disarm on the second falling frame merely
    // because it is still near the long-lived peak.  Recovery is meaningful
    // only after a release had already been active for one source frame.
    if (was_release_active && rms >= release_rms_peak_ * 0.40) {
        release_active_ = false;
        release_falls_ = 0;
    }
    previous_rms_ = rms;
    recent_rms_peak_ = std::max(rms, recent_rms_peak_ * 0.85);
    const auto candidates = eligible
        ? scored_candidates(samples, sample_rate, rms, recent_rms_peak_, has_published_ && !release_active_)
        : std::vector<ScoredPitchCandidate>{};
    last_diagnostic_ = FrameDiagnostic{
        .input_time_seconds = source_time_seconds,
        .rms = rms,
        .input_signal_eligible = eligible,
        .input_release_active = release_active_,
        .candidates = candidates,
    };
    source_times_.push_back(source_time_seconds);
    source_signal_eligible_.push_back(eligible);
    source_release_active_.push_back(release_active_);
    const auto resolved = tracker_.push(candidates);
    if (!resolved) {
        last_diagnostic_.publication_reason = "fixed_lag_pending";
        return {};
    }

    const double resolved_time = source_times_.front();
    const bool source_eligible = source_signal_eligible_.front();
    const bool source_release_active = source_release_active_.front();
    source_times_.pop_front();
    source_signal_eligible_.pop_front();
    source_release_active_.pop_front();
    last_diagnostic_.resolved = true;
    last_diagnostic_.resolved_time_seconds = resolved_time;
    last_diagnostic_.resolved_signal_eligible = source_eligible;
    last_diagnostic_.resolved_release_active = source_release_active;
    last_diagnostic_.selected_candidate = resolved->candidate;
    last_diagnostic_.selected_emission_score = resolved->score;
    last_diagnostic_.selected_path_score = resolved->path_score;
    std::optional<PublishedPitchFrame> tentative;
    std::optional<PublishedPitchFrame> publication;
    if (resolved->candidate && source_eligible && !source_release_active &&
        (resolved->candidate->frequency_hz <= 900 || high_register_evidence(*resolved->candidate))) {
        tentative = PublishedPitchFrame{
            resolved_time, resolved->candidate->frequency_hz, resolved->score,
        };
        const bool stable_weak_contour = last_published_ && tentative->confidence >= 0.55 &&
            cents(tentative->frequency_hz, last_published_->frequency_hz) <= 90;
        if (tentative->confidence >= 0.70 || stable_weak_contour) {
            publication = harmonic_filter(*tentative);
            last_diagnostic_.publication_reason = stable_weak_contour && tentative->confidence < 0.70
                ? "stable_weak_contour" : "published";
        }
    }
    if (last_diagnostic_.publication_reason.empty()) {
        last_diagnostic_.publication_reason = !resolved->candidate ? "no_candidate" :
            !source_eligible ? "rms_gate" : source_release_active ? "release" : "publication_gate";
    }
    auto output = bridge_startup(publication, tentative);
    if (!publication && !has_published_ && tentative) return output;
    auto bridged = bridge_gap(publication, resolved_time, source_eligible);
    last_diagnostic_.bridged_frames = bridged.size() - (publication ? 1 : 0);
    output.insert(output.end(), bridged.begin(), bridged.end());
    if (publication) has_published_ = true;
    return output;
}

std::vector<PublishedPitchFrame> PitchEngineV2Session::finish() {
    if (finished_) return {};
    finished_ = true;
    std::vector<PublishedPitchFrame> output;
    while (const auto resolved = tracker_.finish_next()) {
        // The tracker and source queues are advanced together.  Unlike the
        // former zero-window flush, the exact resolved source frame owns all
        // publication gates.
        const double source_time = source_times_.front();
        const bool source_eligible = source_signal_eligible_.front();
        const bool source_release_active = source_release_active_.front();
        source_times_.pop_front();
        source_signal_eligible_.pop_front();
        source_release_active_.pop_front();
        last_diagnostic_ = FrameDiagnostic{
            .resolved = true,
            .resolved_time_seconds = source_time,
            .resolved_signal_eligible = source_eligible,
            .resolved_release_active = source_release_active,
            .selected_candidate = resolved->candidate,
            .selected_emission_score = resolved->score,
            .selected_path_score = resolved->path_score,
            .finalized = true,
        };
        std::optional<PublishedPitchFrame> tentative;
        std::optional<PublishedPitchFrame> publication;
        if (resolved->candidate && source_eligible && !source_release_active &&
            (resolved->candidate->frequency_hz <= 900 || high_register_evidence(*resolved->candidate))) {
            tentative = PublishedPitchFrame{
                source_time, resolved->candidate->frequency_hz, resolved->score,
            };
            const bool stable_weak_contour = last_published_ && tentative->confidence >= 0.55 &&
                cents(tentative->frequency_hz, last_published_->frequency_hz) <= 90;
            if (tentative->confidence >= 0.70 || stable_weak_contour) {
                publication = harmonic_filter(*tentative);
                last_diagnostic_.publication_reason = stable_weak_contour && tentative->confidence < 0.70
                    ? "stable_weak_contour" : "published";
            }
        }
        if (last_diagnostic_.publication_reason.empty()) {
            last_diagnostic_.publication_reason = !resolved->candidate ? "no_candidate" :
                !source_eligible ? "rms_gate" : source_release_active ? "release" : "publication_gate";
        }
        auto published = bridge_startup(publication, tentative);
        if (!publication && !has_published_ && tentative) {
            output.insert(output.end(), published.begin(), published.end());
            continue;
        }
        auto bridged = bridge_gap(publication, source_time, source_eligible);
        last_diagnostic_.bridged_frames = bridged.size() - (publication ? 1 : 0);
        published.insert(published.end(), bridged.begin(), bridged.end());
        if (publication) has_published_ = true;
        output.insert(output.end(), published.begin(), published.end());
    }
    return output;
}

std::vector<PublishedPitchFrame> PitchEngineV2Session::bridge_startup(
    const std::optional<PublishedPitchFrame>& publication,
    const std::optional<PublishedPitchFrame>& tentative
) {
    if (has_published_) return {};
    if (!publication) {
        if (!tentative || tentative->confidence < 0.55 || pending_startup_.size() >= 5) {
            pending_startup_.clear();
        } else if (pending_startup_.empty() ||
                   cents(tentative->frequency_hz, pending_startup_.back().frequency_hz) <= 90) {
            pending_startup_.push_back(*tentative);
        } else {
            pending_startup_.clear();
        }
        return {};
    }
    std::vector<PublishedPitchFrame> result;
    if (!pending_startup_.empty() && publication->confidence >= 0.70 &&
        cents(publication->frequency_hz, pending_startup_.back().frequency_hz) <= 90) {
        result = pending_startup_;
    }
    pending_startup_.clear();
    return result;
}

std::optional<PublishedPitchFrame> PitchEngineV2Session::harmonic_filter(
    const PublishedPitchFrame& frame
) {
    if (!published_frequency_) {
        published_frequency_ = frame.frequency_hz;
        return frame;
    }
    const double previous = *published_frequency_;
    const double ratio = frame.frequency_hz / previous;
    const bool harmonic_jump = frame.frequency_hz < previous && cents(frame.frequency_hz, previous) >= 650 &&
        (cents(ratio, 1.0 / 3.0) <= 110 || cents(ratio, 0.5) <= 110 || cents(ratio, 2.0 / 3.0) <= 110);
    if (!harmonic_jump) {
        pending_harmonic_.reset();
        published_frequency_ = frame.frequency_hz;
        return frame;
    }
    if (pending_harmonic_ && cents(frame.frequency_hz, pending_harmonic_->frequency) <= 180) {
        ++pending_harmonic_->confirmations;
        if (pending_harmonic_->confirmations >= 2) {
            pending_harmonic_.reset();
            published_frequency_ = frame.frequency_hz;
            return frame;
        }
    } else {
        pending_harmonic_ = PendingPitch{frame.frequency_hz, frame.confidence, 1};
    }
    return PublishedPitchFrame{frame.time_seconds, previous, std::min(frame.confidence, 0.55)};
}

std::vector<PublishedPitchFrame> PitchEngineV2Session::bridge_gap(
    const std::optional<PublishedPitchFrame>& frame,
    const double source_time_seconds,
    const bool source_signal_eligible
) {
    if (!frame) {
        if (!source_signal_eligible) {
            pending_gap_.clear();
            last_published_.reset();
        } else if (last_published_ && pending_gap_.size() < 7) {
            pending_gap_.push_back(PublishedPitchFrame{
                source_time_seconds, last_published_->frequency_hz, last_published_->confidence,
            });
        } else {
            pending_gap_.clear();
            last_published_.reset();
        }
        return {};
    }
    std::vector<PublishedPitchFrame> result;
    if (!pending_gap_.empty() && last_published_ &&
        // A slow, still-periodic contour can legitimately dip below the
        // normal 0.70 publication score.  It may bridge a short dropout only
        // after both endpoints retain the same contour and at least the
        // weaker continuity evidence used for publication.
        std::min(last_published_->confidence, frame->confidence) >= 0.55 &&
        cents(frame->frequency_hz, last_published_->frequency_hz) <= 90) {
        result = pending_gap_;
    }
    pending_gap_.clear();
    result.push_back(*frame);
    last_published_ = frame;
    return result;
}

void PitchEngineV2Session::reset() {
    recent_rms_peak_ = 0;
    release_rms_peak_ = 0;
    previous_rms_ = 0;
    release_falls_ = 0;
    release_active_ = false;
    tracker_.reset();
    source_times_.clear();
    source_signal_eligible_.clear();
    source_release_active_.clear();
    published_frequency_.reset();
    pending_harmonic_.reset();
    last_published_.reset();
    pending_gap_.clear();
    pending_startup_.clear();
    has_published_ = false;
    last_diagnostic_ = {};
    finished_ = false;
}

void PitchEngineV2Session::set_minimum_rms(const double minimum_rms) {
    if (std::isfinite(minimum_rms) && minimum_rms >= 0) minimum_rms_ = minimum_rms;
}

}  // namespace klarivision::core::v2
