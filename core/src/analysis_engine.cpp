#include "klarivision/core/analysis_engine.hpp"

#include "klarivision/core/pitch_engine_v2_session.hpp"
#include "klarivision/core/vpm_like.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <numbers>
#include <numeric>
#include <stdexcept>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace klarivision::core {
namespace {
struct Candidate { double frequency{}; double confidence{}; double emission{}; };
constexpr double kSilenceEmission = -0.80;
constexpr std::size_t kMaximumBridgeFrames = 7;

double centered_rms(std::span<const float> samples) {
    if (samples.empty()) return 0;
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) / samples.size();
    double sum = 0;
    for (const float sample : samples) { const double x = sample - mean; sum += x * x; }
    return std::sqrt(sum / samples.size());
}

double spectral_energy(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8 || frequency <= 0) return 0;
    const double step = 2 * std::numbers::pi * frequency / rate;
    const double denominator = static_cast<double>(samples.size() - 1);
    double cosine = 0;
    double sine = 0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double window = 0.5 - 0.5 * std::cos(2 * std::numbers::pi * index / denominator);
        const double value = samples[index] * window;
        const double phase = step * index;
        cosine += value * std::cos(phase);
        sine += value * std::sin(phase);
    }
    return cosine * cosine + sine * sine;
}

double spectral_amplitude(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8) return 0;
    // `spectral_energy` uses the same Hann window. Its coherent window sum is
    // (N-1)/2, so this converts the complex magnitude to the normalized
    // amplitude used by the VPM-like estimator's 0.005 direct-support gate.
    return 4.0 * std::sqrt(spectral_energy(samples, rate, frequency)) /
        static_cast<double>(samples.size() - 1);
}

double cents_distance(double a, double b) { return std::abs(1200.0 * std::log2(a / b)); }

float float_dot(const float* left, const float* right, const std::size_t count) {
#if defined(__APPLE__)
    float result = 0;
    vDSP_dotpr(left, 1, right, 1, &result, static_cast<vDSP_Length>(count));
    return result;
#else
    float result = 0;
    for (std::size_t index = 0; index < count; ++index) result += left[index] * right[index];
    return result;
#endif
}

std::vector<Candidate> yin_candidates(std::span<const float> samples, double rate, const PitchEngineConfig& config) {
    const int min_lag = std::max(2, static_cast<int>(rate / config.maximum_frequency_hz));
    const int max_lag = std::min(static_cast<int>(samples.size() / 2), static_cast<int>(rate / config.minimum_frequency_hz));
    if (min_lag + 2 >= max_lag) return {};
    std::vector<float> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        energy[index + 1] = energy[index] + samples[index] * samples[index];
    }
    std::vector<float> difference(static_cast<std::size_t>(max_lag + 1), 0);
    for (int lag = min_lag; lag <= max_lag; ++lag) {
        const auto count = samples.size() - static_cast<std::size_t>(lag);
        const float correlation = float_dot(samples.data(), samples.data() + lag, count);
        difference[static_cast<std::size_t>(lag)] = std::max(
            0.0F,
            energy[count] + (energy[samples.size()] - energy[static_cast<std::size_t>(lag)]) -
                2.0F * correlation
        );
    }
    std::vector<float> cumulative(static_cast<std::size_t>(max_lag + 1), 1);
    float total = 0;
    for (int lag = 1; lag <= max_lag; ++lag) {
        total += difference[static_cast<std::size_t>(lag)];
        if (total > 0) cumulative[static_cast<std::size_t>(lag)] =
            difference[static_cast<std::size_t>(lag)] * static_cast<float>(lag) / total;
    }
    std::vector<Candidate> result;
    for (int lag = min_lag + 1; lag < max_lag; ++lag) {
        if (!(cumulative[lag] <= cumulative[lag - 1] && cumulative[lag] < cumulative[lag + 1] && cumulative[lag] < 0.50)) continue;
        const float denominator = cumulative[lag - 1] - 2.0F * cumulative[lag] + cumulative[lag + 1];
        const float correction = std::abs(denominator) > 0.000001F
            ? std::clamp(0.5F * (cumulative[lag - 1] - cumulative[lag + 1]) / denominator, -0.5F, 0.5F)
            : 0;
        const double frequency = rate / (lag + correction);
        if (frequency >= config.minimum_frequency_hz && frequency <= config.maximum_frequency_hz) {
            const double confidence = std::clamp(static_cast<double>(1.0F - cumulative[lag]), 0.0, 1.0);
            result.push_back({frequency, confidence, std::log(std::max(1e-6, confidence))});
        }
    }
    std::sort(result.begin(), result.end(), [](const Candidate& a, const Candidate& b) { return a.confidence > b.confidence; });
    const auto original_count = result.size();
    for (std::size_t index = 0; index < original_count; ++index) {
        const double upper = result[index].frequency * 2;
        if (upper <= 800 || upper > config.maximum_frequency_hz) continue;
        if (spectral_energy(samples, rate, upper) >
            spectral_energy(samples, rate, result[index].frequency) * 8) {
            // A narrow direct-spectrum recovery for an f/2 period choice.
            // The high confidence ensures the offline path resolver retains
            // this evidence instead of preferring the repeated lower period.
            result.push_back({upper, 0.99999, std::log(0.99999)});
        }
    }
    std::sort(result.begin(), result.end(), [](const Candidate& a, const Candidate& b) { return a.confidence > b.confidence; });
    if (result.size() > 12) result.resize(12);
    return result;
}

std::optional<Candidate> causal_yin_choice(
    const std::vector<Candidate>& candidates,
    const std::optional<Candidate>& previous
) {
    if (candidates.empty()) return std::nullopt;
    // `yin_candidates` grants this confidence only to a high-register line
    // whose directly measured spectrum exceeds its f/2 candidate by 8x.
    // Do not let continuity pull that explicit fundamental back to a stable
    // low sub-period.
    const auto direct_high = std::max_element(
        candidates.begin(), candidates.end(), [](const Candidate& left, const Candidate& right) {
            const bool left_is_direct_high = left.frequency > 800 && left.confidence >= .9999;
            const bool right_is_direct_high = right.frequency > 800 && right.confidence >= .9999;
            if (left_is_direct_high != right_is_direct_high) return !left_is_direct_high;
            return left.frequency < right.frequency;
        }
    );
    if (direct_high != candidates.end() &&
        direct_high->frequency > 800 && direct_high->confidence >= .9999) return *direct_high;
    std::optional<Candidate> best;
    double best_score = -std::numeric_limits<double>::infinity();
    for (const auto& candidate : candidates) {
        if (candidate.confidence < .55) continue;
        double score = candidate.confidence;
        if (previous) {
            const double distance = cents_distance(candidate.frequency, previous->frequency);
            score -= .30 * std::min(distance / 700.0, 1.0);
        }
        if (score > best_score) { best = candidate; best_score = score; }
    }
    return best;
}

void append_bridged(
    std::vector<EngineFrame>& output,
    std::vector<EngineFrame>& pending_gap,
    std::optional<EngineFrame>& last,
    const std::optional<EngineFrame>& frame,
    bool signal_eligible,
    double hop_seconds,
    double minimum_endpoint_confidence
) {
    if (!frame) {
        if (!signal_eligible) { pending_gap.clear(); last.reset(); }
        else if (last && pending_gap.size() < kMaximumBridgeFrames) {
            pending_gap.push_back({last->time_seconds + (pending_gap.size() + 1) * hop_seconds, last->frequency_hz, last->confidence});
        } else { pending_gap.clear(); last.reset(); }
        return;
    }
    if (!pending_gap.empty() && last && last->frequency_hz && frame->frequency_hz &&
        std::min(last->confidence, frame->confidence) >= minimum_endpoint_confidence &&
        cents_distance(*last->frequency_hz, *frame->frequency_hz) <= 90) {
        output.insert(output.end(), pending_gap.begin(), pending_gap.end());
    }
    pending_gap.clear();
    output.push_back(*frame); last = frame;
}

[[maybe_unused]] std::vector<Candidate> vpm_candidates(std::span<const float> samples, double rate, const PitchEngineConfig& config) {
    std::vector<double> copied(samples.begin(), samples.end());
    VPMLikeConfig vpm; vpm.minimum_frequency_hz = config.minimum_frequency_hz; vpm.maximum_frequency_hz = std::max(1650.0, config.maximum_frequency_hz); vpm.minimum_rms = config.minimum_rms;
    const auto diagnostic = diagnose_vpm_like_pitch(copied, rate, vpm);
    // `diagnostic.pitch` is the VPM-like estimator's final spectrum-aware
    // decision. Feeding its raw ACF alternatives back into the generic path
    // resolver discarded that decision and repeatedly selected f/2 instead.
    if (diagnostic.pitch && diagnostic.pitch->confidence >= vpm.minimum_output_confidence &&
        diagnostic.pitch->frequency_hz <= config.maximum_frequency_hz) {
        return {{diagnostic.pitch->frequency_hz, diagnostic.pitch->confidence,
                 std::log(diagnostic.pitch->confidence)}};
    }
    return {};
}

[[maybe_unused]] std::vector<EngineFrame> resolve_track(const std::vector<std::vector<Candidate>>& frames, double rate, const PitchEngineConfig& config, PitchEngineId id) {
    struct State { std::optional<Candidate> candidate; double score; int prior; };
    std::vector<std::vector<State>> layers;
    const double width = id == PitchEngineId::pitch_engine_v2 ? 700.0 : (id == PitchEngineId::vpm_like ? 420.0 : 500.0);
    for (std::size_t frame = 0; frame < frames.size(); ++frame) {
        std::vector<State> current; current.push_back({std::nullopt, kSilenceEmission, -1});
        for (const auto& candidate : frames[frame]) current.push_back({candidate, candidate.emission, -1});
        if (!layers.empty()) {
            for (auto& state : current) {
                double best = -std::numeric_limits<double>::infinity(); int prior = 0;
                for (std::size_t previous = 0; previous < layers.back().size(); ++previous) {
                    const auto& before = layers.back()[previous];
                    double transition = 0;
                    if (state.candidate && before.candidate) transition = -std::min(cents_distance(state.candidate->frequency, before.candidate->frequency) / width, 3.0);
                    else if (state.candidate || before.candidate) transition = -0.55;
                    const double score = before.score + state.score + transition;
                    if (score > best) { best = score; prior = static_cast<int>(previous); }
                }
                state.score = best; state.prior = prior;
            }
        }
        layers.push_back(std::move(current));
    }
    std::vector<EngineFrame> output(frames.size());
    if (layers.empty()) return output;
    int state = static_cast<int>(std::max_element(layers.back().begin(), layers.back().end(), [](const State& a, const State& b) { return a.score < b.score; }) - layers.back().begin());
    for (std::size_t index = layers.size(); index-- > 0;) {
        const auto& selected = layers[index][state];
        output[index].time_seconds = (static_cast<double>(index * config.hop_size + config.window_size / 2) / rate);
        if (selected.candidate) { output[index].frequency_hz = selected.candidate->frequency; output[index].confidence = selected.candidate->confidence; }
        state = selected.prior;
        if (state < 0 && index > 0) state = 0;
    }
    return output;
}
}  // namespace

struct ProductionPitchSession::Impl {
    PitchEngineId id;
    PitchEngineConfig config;
    std::optional<Candidate> last_yin;
    std::optional<Candidate> pending_yin_jump;
    int pending_yin_confirmations{};
    int silent_yin_estimates{};
    double recent_yin_rms_peak{};
    double yin_release_rms_peak{};
    double previous_yin_rms{};
    int yin_release_falls{};
    bool yin_release_active{};
    std::optional<EngineFrame> vpm_last_strong_contour;
    std::vector<EngineFrame> vpm_pending_gap;
    double vpm_release_rms_peak{};
    double vpm_direct_support_peak{};
    double previous_vpm_rms{};
    int vpm_release_falls{};
    bool vpm_release_suspected{};
    bool vpm_waiting_for_attack{};
    VPMSessionDiagnostic vpm_diagnostic;
    VPMLikeTracker vpm_tracker;
    v2::PitchEngineV2Session v2_session;
    std::vector<EngineFrame> pending_gap;
    std::optional<EngineFrame> last_published;
    bool finished{};

    Impl(const PitchEngineId selected, const PitchEngineConfig selected_config)
        : id(selected), config(selected_config), v2_session(selected_config.minimum_rms, 5) {}
};

ProductionPitchSession::ProductionPitchSession(
    const PitchEngineId id,
    const PitchEngineConfig config
) : impl_(std::make_unique<Impl>(id, config)) {}

ProductionPitchSession::~ProductionPitchSession() = default;
ProductionPitchSession::ProductionPitchSession(ProductionPitchSession&&) noexcept = default;
ProductionPitchSession& ProductionPitchSession::operator=(ProductionPitchSession&&) noexcept = default;

std::vector<EngineFrame> ProductionPitchSession::process_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time
) {
    if (rate <= 0 || samples.size() < impl_->config.window_size) return {};
    if (impl_->finished) throw std::logic_error("Pitch session is finished; call reset before processing more frames");
    if (impl_->id == PitchEngineId::pitch_engine_v2) {
        std::vector<EngineFrame> output;
        for (const auto& frame : impl_->v2_session.process_frame(samples, rate, source_time)) {
            output.push_back({frame.time_seconds, frame.frequency_hz, frame.confidence});
        }
        return output;
    }

    const double rms = centered_rms(samples);
    const bool eligible = rms >= impl_->config.minimum_rms;
    std::optional<EngineFrame> publication;
    if (impl_->id == PitchEngineId::yin_v1) {
        // A note release falls much faster than the intentional, slow fades
        // used in musical phrasing.  Preserve that distinction causally: two
        // sharp RMS falls arm a release until a new attack has recovered.
        if (impl_->previous_yin_rms > 0 && rms < impl_->previous_yin_rms * .80) {
            ++impl_->yin_release_falls;
        } else if (!impl_->yin_release_active) {
            impl_->yin_release_falls = 0;
        }
        impl_->recent_yin_rms_peak = std::max(rms, impl_->recent_yin_rms_peak * .85);
        impl_->yin_release_rms_peak = std::max(rms, impl_->yin_release_rms_peak * .995);
        if (impl_->yin_release_falls >= 2) impl_->yin_release_active = true;
        if (impl_->yin_release_active && rms >= impl_->yin_release_rms_peak * .40) {
            impl_->yin_release_active = false;
            impl_->yin_release_falls = 0;
        }
        impl_->previous_yin_rms = rms;
        if (impl_->yin_release_active) {
            impl_->last_yin.reset();
            impl_->pending_yin_jump.reset();
            impl_->pending_yin_confirmations = 0;
        }
        if (eligible) {
            const auto candidates = yin_candidates(samples, rate, impl_->config);
            auto choice = causal_yin_choice(candidates, impl_->last_yin);
            if (!impl_->last_yin) {
                const auto confident = std::max_element(
                    candidates.begin(), candidates.end(),
                    [](const Candidate& left, const Candidate& right) {
                        return left.confidence < right.confidence;
                    }
                );
                if (confident != candidates.end() && confident->confidence >= .76) choice = *confident;
            }
            // The same narrow ambiguity repair exists in the established
            // live YIN path: 2f must be a real YIN minimum with almost equal
            // periodicity and at least three times the measured line energy.
            if (choice) {
                std::optional<Candidate> recovery;
                double recovery_energy = 0;
                for (const auto& lower : candidates) {
                    const double upper = lower.frequency * 2;
                    if (upper <= choice->frequency * 1.5 || upper > 900) continue;
                    const auto upper_it = std::find_if(
                        candidates.begin(), candidates.end(), [&](const Candidate& candidate) {
                            return cents_distance(candidate.frequency, upper) <= 55 &&
                                candidate.confidence >= lower.confidence - .05;
                        }
                    );
                    if (upper_it == candidates.end()) continue;
                    const double upper_energy = spectral_energy(samples, rate, upper_it->frequency);
                    if (upper_energy > spectral_energy(samples, rate, lower.frequency) * 3 &&
                        upper_energy > recovery_energy) {
                        recovery = *upper_it;
                        recovery_energy = upper_energy;
                    }
                }
                if (recovery) choice = recovery;
            }
            if (choice) {
                double energy_scale = 0;
                for (const float sample : samples) energy_scale += sample * sample;
                energy_scale *= static_cast<double>(samples.size());
                std::optional<Candidate> upper_recovery;
                double strongest_upper_energy = 0;
                for (const auto& candidate : candidates) {
                    const double candidate_energy = spectral_energy(
                        samples, rate, candidate.frequency
                    );
                    for (const double factor : {3.0, 2.0}) {
                        const double upper = candidate.frequency * factor;
                        if (upper <= std::max(900.0, choice->frequency) ||
                            upper > impl_->config.maximum_frequency_hz) continue;
                        const double upper_energy = spectral_energy(samples, rate, upper);
                        if (upper_energy > std::max(candidate_energy * 80, energy_scale * .008) &&
                            upper_energy > strongest_upper_energy) {
                            upper_recovery = Candidate{upper, candidate.confidence,
                                std::log(std::max(1e-6, candidate.confidence))};
                            strongest_upper_energy = upper_energy;
                        }
                    }
                }
                if (upper_recovery) choice = upper_recovery;
            }
            if (choice && impl_->last_yin &&
                choice->frequency < impl_->last_yin->frequency &&
                cents_distance(choice->frequency, impl_->last_yin->frequency) > 900) {
                if (impl_->pending_yin_jump &&
                    cents_distance(choice->frequency, impl_->pending_yin_jump->frequency) < 360) {
                    ++impl_->pending_yin_confirmations;
                    impl_->pending_yin_jump = choice;
                    if (impl_->pending_yin_confirmations < 3) return {};
                    impl_->pending_yin_jump.reset();
                    impl_->pending_yin_confirmations = 0;
                } else {
                    impl_->pending_yin_jump = choice;
                    impl_->pending_yin_confirmations = 1;
                    return {};
                }
            } else {
                impl_->pending_yin_jump.reset();
                impl_->pending_yin_confirmations = 0;
            }
            if (choice && !impl_->yin_release_active && !(choice->confidence < .90 &&
                rms < impl_->recent_yin_rms_peak * .35)) {
                publication = EngineFrame{source_time, choice->frequency, choice->confidence};
                impl_->last_yin = choice;
                impl_->silent_yin_estimates = 0;
            }
        }
        if (!publication) {
            ++impl_->silent_yin_estimates;
            if (impl_->silent_yin_estimates >= 30) {
                impl_->last_yin.reset();
                impl_->pending_yin_jump.reset();
                impl_->pending_yin_confirmations = 0;
                impl_->pending_gap.clear();
            }
        }
    } else if (impl_->id == PitchEngineId::vpm_like) {
        auto& diagnostic = impl_->vpm_diagnostic;
        diagnostic = {};
        diagnostic.input_time_seconds = source_time;
        diagnostic.rms = rms;
        diagnostic.signal_eligible = eligible;
        if (impl_->vpm_last_strong_contour) {
            diagnostic.last_strong_contour_hz =
                impl_->vpm_last_strong_contour->frequency_hz;
        }

        impl_->vpm_release_rms_peak = std::max(rms, impl_->vpm_release_rms_peak * .995);
        diagnostic.recent_rms_peak = impl_->vpm_release_rms_peak;
        diagnostic.rms_to_peak_ratio = impl_->vpm_release_rms_peak > 0
            ? rms / impl_->vpm_release_rms_peak : 0;
        if (impl_->previous_vpm_rms > 0 && rms < impl_->previous_vpm_rms * .85) {
            ++impl_->vpm_release_falls;
        } else if (!impl_->vpm_release_suspected &&
            (impl_->vpm_release_falls < 2 || diagnostic.rms_to_peak_ratio >= .60)) {
            impl_->vpm_release_falls = 0;
        }
        impl_->previous_vpm_rms = rms;

        std::optional<VPMLikePitch> weak_estimate;
        std::optional<VPMLikePitch> normal_estimate;
        if (eligible) {
            std::vector<double> copied(samples.begin(), samples.end());
            VPMLikeConfig weak_config;
            weak_config.minimum_frequency_hz = impl_->config.minimum_frequency_hz;
            weak_config.maximum_frequency_hz = std::max(1650.0, impl_->config.maximum_frequency_hz);
            weak_config.minimum_rms = impl_->config.minimum_rms;
            weak_config.minimum_output_confidence = .38;
            if (impl_->config.enable_vpm_diagnostics) {
                const auto estimator = diagnose_vpm_like_pitch(copied, rate, weak_config);
                diagnostic.strongest_periodicity = estimator.strongest_periodicity;
                weak_estimate = estimator.pitch;
            } else {
                weak_estimate = estimate_vpm_like_pitch(copied, rate, weak_config);
                diagnostic.strongest_periodicity = weak_estimate
                    ? weak_estimate->confidence : 0;
            }
            if (weak_estimate) {
                diagnostic.weak_estimate_hz = weak_estimate->frequency_hz;
                if (weak_estimate->confidence >= .80) {
                    normal_estimate = weak_estimate;
                    diagnostic.normal_estimate_hz = normal_estimate->frequency_hz;
                }
            }
        }

        double direct_support = 0;
        if (impl_->vpm_last_strong_contour &&
            impl_->vpm_last_strong_contour->frequency_hz) {
            direct_support = spectral_amplitude(
                samples, rate, *impl_->vpm_last_strong_contour->frequency_hz
            );
            impl_->vpm_direct_support_peak = std::max(
                direct_support, impl_->vpm_direct_support_peak * .995
            );
        }
        diagnostic.direct_fundamental_support = direct_support;
        diagnostic.recent_direct_support_peak = impl_->vpm_direct_support_peak;
        const bool direct_support_lost = impl_->vpm_last_strong_contour &&
            (direct_support < .005 ||
             (impl_->vpm_direct_support_peak > 0 &&
              direct_support < impl_->vpm_direct_support_peak * .35));
        if (impl_->vpm_last_strong_contour && impl_->vpm_release_falls >= 2 &&
            diagnostic.rms_to_peak_ratio < .35 && direct_support_lost) {
            impl_->vpm_release_suspected = true;
        }
        diagnostic.release_suspected = impl_->vpm_release_suspected;

        const auto clear_vpm_contour = [&] {
            impl_->vpm_pending_gap.clear();
            impl_->vpm_last_strong_contour.reset();
            impl_->vpm_release_suspected = false;
            impl_->vpm_release_falls = 0;
            impl_->vpm_direct_support_peak = 0;
            impl_->vpm_tracker.reset();
        };
        const auto queue_vpm_gap = [&] {
            if (!impl_->vpm_last_strong_contour ||
                impl_->vpm_pending_gap.size() >= kMaximumBridgeFrames) {
                clear_vpm_contour();
                impl_->vpm_waiting_for_attack = true;
                diagnostic.publication_reason = "gap_expired";
                return;
            }
            const auto& anchor = *impl_->vpm_last_strong_contour;
            impl_->vpm_pending_gap.push_back({
                source_time, anchor.frequency_hz, anchor.confidence
            });
            diagnostic.publication_reason = impl_->vpm_release_suspected
                ? "release_pending" : "dropout_pending";
        };

        if (!eligible) {
            // Crossing the fixed RMS gate is enough to end the current
            // anchor, but a gradual musical trough is not by itself release
            // evidence.  Require a recovered attack only when the causal
            // release detector (or an expired gap) had already armed it.
            const bool require_recovered_attack = impl_->vpm_release_suspected ||
                impl_->vpm_waiting_for_attack;
            clear_vpm_contour();
            impl_->vpm_waiting_for_attack = require_recovered_attack;
            diagnostic.publication_reason = "rms_gate_closed";
            diagnostic.pending_gap_frames = 0;
            return {};
        }

        if (impl_->vpm_waiting_for_attack) {
            if (!normal_estimate || diagnostic.rms_to_peak_ratio < .40) {
                diagnostic.publication_reason = "waiting_for_attack";
                return {};
            }
            impl_->vpm_waiting_for_attack = false;
            impl_->vpm_release_falls = 0;
            impl_->vpm_tracker.reset();
        }

        std::vector<EngineFrame> vpm_output;
        if (impl_->vpm_release_suspected) {
            const auto recovery = normal_estimate ? normal_estimate :
                (weak_estimate && weak_estimate->confidence >= .70
                    ? weak_estimate : std::nullopt);
            const bool envelope_recovered = diagnostic.rms_to_peak_ratio >= .40;
            if (envelope_recovered && recovery && impl_->vpm_last_strong_contour &&
                impl_->vpm_last_strong_contour->frequency_hz &&
                cents_distance(recovery->frequency_hz,
                    *impl_->vpm_last_strong_contour->frequency_hz) <= 90) {
                vpm_output = impl_->vpm_pending_gap;
                diagnostic.bridged_frames = vpm_output.size();
                impl_->vpm_pending_gap.clear();
                impl_->vpm_release_suspected = false;
                impl_->vpm_waiting_for_attack = false;
                impl_->vpm_release_falls = 0;
                impl_->vpm_tracker.reset();
                const auto decision = impl_->vpm_tracker.process(recovery);
                if (decision) {
                    publication = EngineFrame{
                        source_time, decision->frequency_hz, decision->confidence
                    };
                    vpm_output.push_back(*publication);
                }
                if (normal_estimate && publication) {
                    impl_->vpm_last_strong_contour = publication;
                    impl_->vpm_direct_support_peak = std::max(
                        spectral_amplitude(samples, rate, *publication->frequency_hz),
                        impl_->vpm_direct_support_peak * .995
                    );
                }
                diagnostic.publication_reason = "same_contour_recovery";
            } else if (envelope_recovered && normal_estimate &&
                impl_->vpm_last_strong_contour &&
                impl_->vpm_last_strong_contour->frequency_hz &&
                cents_distance(normal_estimate->frequency_hz,
                    *impl_->vpm_last_strong_contour->frequency_hz) > 90) {
                clear_vpm_contour();
                impl_->vpm_waiting_for_attack = false;
                const auto decision = impl_->vpm_tracker.process(normal_estimate);
                if (decision && decision->frequency_hz <= impl_->config.maximum_frequency_hz) {
                    publication = EngineFrame{
                        source_time, decision->frequency_hz, decision->confidence
                    };
                    vpm_output.push_back(*publication);
                    impl_->vpm_last_strong_contour = publication;
                    impl_->vpm_direct_support_peak = spectral_amplitude(
                        samples, rate, *publication->frequency_hz
                    );
                }
                diagnostic.publication_reason = "different_contour_attack";
            } else {
                impl_->vpm_tracker.reset();
                queue_vpm_gap();
            }
            diagnostic.release_suspected = impl_->vpm_release_suspected;
            diagnostic.pending_gap_frames = impl_->vpm_pending_gap.size();
            return vpm_output;
        }

        if (normal_estimate) {
            std::optional<double> upper_to_estimate_ratio;
            if (impl_->vpm_last_strong_contour &&
                impl_->vpm_last_strong_contour->frequency_hz &&
                normal_estimate->frequency_hz <
                    *impl_->vpm_last_strong_contour->frequency_hz &&
                cents_distance(normal_estimate->frequency_hz,
                    *impl_->vpm_last_strong_contour->frequency_hz) > 650) {
                const double lower_support = spectral_amplitude(
                    samples, rate, normal_estimate->frequency_hz
                );
                upper_to_estimate_ratio = direct_support /
                    std::max(1e-9, lower_support);
                diagnostic.established_upper_to_estimate_ratio =
                    upper_to_estimate_ratio;
            }
            const auto decision = impl_->vpm_tracker.process(
                normal_estimate, upper_to_estimate_ratio
            );
            if (decision && decision->frequency_hz <= impl_->config.maximum_frequency_hz) {
                publication = EngineFrame{
                    source_time, decision->frequency_hz, decision->confidence
                };
                diagnostic.harmonic_veto = cents_distance(
                    decision->frequency_hz, normal_estimate->frequency_hz
                ) > 90;
                if (!impl_->vpm_pending_gap.empty()) {
                    if (impl_->vpm_last_strong_contour &&
                        impl_->vpm_last_strong_contour->frequency_hz &&
                        cents_distance(decision->frequency_hz,
                            *impl_->vpm_last_strong_contour->frequency_hz) <= 90) {
                        vpm_output = impl_->vpm_pending_gap;
                        diagnostic.bridged_frames = vpm_output.size();
                    }
                    impl_->vpm_pending_gap.clear();
                }
                vpm_output.push_back(*publication);
                if (!diagnostic.harmonic_veto) {
                    impl_->vpm_last_strong_contour = publication;
                    impl_->vpm_direct_support_peak = std::max(
                        spectral_amplitude(samples, rate, *publication->frequency_hz),
                        impl_->vpm_direct_support_peak * .995
                    );
                }
                diagnostic.publication_reason = diagnostic.harmonic_veto
                    ? "harmonic_veto" :
                    (diagnostic.bridged_frames ? "dropout_bridged" : "normal_contour");
            }
        } else if (weak_estimate && impl_->vpm_last_strong_contour &&
            impl_->vpm_last_strong_contour->frequency_hz && direct_support >= .005 &&
            cents_distance(weak_estimate->frequency_hz,
                *impl_->vpm_last_strong_contour->frequency_hz) <= 90) {
            publication = EngineFrame{
                source_time,
                impl_->vpm_last_strong_contour->frequency_hz,
                weak_estimate->confidence,
            };
            impl_->vpm_pending_gap.clear();
            vpm_output.push_back(*publication);
            diagnostic.publication_reason = "weak_contour_hold";
        } else {
            impl_->vpm_tracker.process(std::nullopt);
            queue_vpm_gap();
        }
        diagnostic.pending_gap_frames = impl_->vpm_pending_gap.size();
        return vpm_output;
    }

    std::vector<EngineFrame> output;
    append_bridged(
        output, impl_->pending_gap, impl_->last_published, publication, eligible,
        static_cast<double>(impl_->config.hop_size) / rate,
        impl_->id == PitchEngineId::yin_v1 ? .55 : .70
    );
    return output;
}

std::vector<EngineFrame> ProductionPitchSession::finish() {
    if (impl_->finished) return {};
    impl_->finished = true;
    if (impl_->id != PitchEngineId::pitch_engine_v2) return {};
    std::vector<EngineFrame> output;
    for (const auto& frame : impl_->v2_session.finish()) {
        output.push_back({frame.time_seconds, frame.frequency_hz, frame.confidence});
    }
    return output;
}

const VPMSessionDiagnostic& ProductionPitchSession::last_vpm_diagnostic() const {
    return impl_->vpm_diagnostic;
}

void ProductionPitchSession::reset() {
    const auto id = impl_->id;
    const auto config = impl_->config;
    impl_ = std::make_unique<Impl>(id, config);
}

void ProductionPitchSession::set_minimum_rms(const double minimum_rms) {
    if (!std::isfinite(minimum_rms) || minimum_rms < 0) return;
    impl_->config.minimum_rms = minimum_rms;
    impl_->v2_session.set_minimum_rms(minimum_rms);
}

PitchEngine::PitchEngine(PitchEngineId id, PitchEngineProfile profile, PitchEngineConfig config) : id_(id), profile_(profile), config_(config) {}
void PitchEngine::reset() { buffered_samples_.clear(); sample_rate_ = 0; }
void PitchEngine::push(std::span<const float> mono_samples, double sample_rate) { if (sample_rate_ == 0) sample_rate_ = sample_rate; if (std::abs(sample_rate - sample_rate_) < 0.001) buffered_samples_.insert(buffered_samples_.end(), mono_samples.begin(), mono_samples.end()); }
std::vector<EngineFrame> PitchEngine::finish() { auto result = analyse(buffered_samples_, sample_rate_); reset(); return result; }
std::vector<EngineFrame> PitchEngine::analyse_causal(
    const std::span<const float> samples,
    const double rate
) {
    if (rate <= 0 || samples.size() < config_.window_size) return {};
    ProductionPitchSession session(id_, config_);
    std::vector<EngineFrame> output;
    for (std::size_t start = 0; start + config_.window_size <= samples.size(); start += config_.hop_size) {
        const double time = (static_cast<double>(start) + config_.window_size / 2.0) / rate;
        auto published = session.process_frame(samples.subspan(start, config_.window_size), rate, time);
        output.insert(output.end(), published.begin(), published.end());
    }
    auto final = session.finish();
    output.insert(output.end(), final.begin(), final.end());
    return output;
}

std::vector<EngineFrame> PitchEngine::analyse(
    const std::span<const float> samples,
    const double rate
) {
    auto baseline = analyse_causal(samples, rate);
    if (profile_ != PitchEngineProfile::offline_track || baseline.empty()) return baseline;

    return baseline;
}
}  // namespace klarivision::core
