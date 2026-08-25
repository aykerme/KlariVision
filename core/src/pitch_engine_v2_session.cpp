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

constexpr double kMinimumFrequency = 80.0;               // lowest fundamental this session will ever report
constexpr double kMaximumFrequency = 1500.0;             // highest fundamental this session will ever report
constexpr double kAnalysisMaximumFrequency = 1650.0;     // YIN's own search ceiling, slightly above the reporting ceiling for headroom

// Dot product of two sample buffers. On Apple platforms this delegates to
// Accelerate's vDSP (SIMD-optimised), which is what lets this session's
// per-lag autocorrelation loops below run fast enough for real-time,
// exact (non-approximated) candidate generation; the portable fallback is
// a plain scalar loop with identical results.
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

// DC-removed root-mean-square loudness of a window, used both as the
// signal-eligibility gate and as input to the release-detection state
// machine below.
double centered_rms(const std::span<const float> samples) {
    if (samples.empty()) return 0;
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());  // DC offset
    double sum = 0;
    for (const float sample : samples) {
        const double centered = static_cast<double>(sample) - mean;  // DC-free sample
        sum += centered * centered;                                   // accumulate squared amplitude
    }
    return std::sqrt(sum / static_cast<double>(samples.size()));
}

// Exact (non-fast) YIN pitch candidate generator: the classic
// difference-function + cumulative-mean-normalisation (CMND) algorithm,
// producing every plausible local-minimum candidate rather than collapsing
// to a single pitch, mirroring mpm_candidates' "return everything
// plausible" philosophy so downstream arbitration can combine evidence.
std::vector<PitchCandidate> yin_candidates(
    const std::span<const float> samples,
    const double sample_rate
) {
    if (samples.size() < 1024) return {};  // need a full analysis window
    const int minimum_lag = std::max(2, static_cast<int>(sample_rate / kAnalysisMaximumFrequency));  // shortest period to test (highest pitch)
    const int maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),                    // never past half the window
        static_cast<int>(sample_rate / kMinimumFrequency)         // longest period to test (lowest pitch)
    );
    if (minimum_lag + 2 >= maximum_lag) return {};  // range too narrow

    // Prefix sum of squared samples, giving O(1) lookup of any sub-range's
    // energy for the difference-function computation below.
    std::vector<float> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        energy[index + 1] = energy[index] + samples[index] * samples[index];
    }
    // YIN's difference function d(lag): sum of squared differences between
    // the signal and a lag-shifted copy of itself, expanded algebraically
    // as energy(leading) + energy(delayed) - 2*correlation(leading,
    // delayed) so it can be computed via a single dot product per lag
    // instead of an explicit subtraction loop.
    std::vector<float> difference(static_cast<std::size_t>(maximum_lag + 1), 0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {
        const auto count = samples.size() - static_cast<std::size_t>(lag);           // overlapping sample count at this lag
        const float correlation = float_dot(samples.data(), samples.data() + lag, count);  // cross-correlation term
        difference[static_cast<std::size_t>(lag)] = std::max(
            0.0F,  // clamp tiny negative values from floating-point error to zero
            energy[count] + (energy[samples.size()] - energy[static_cast<std::size_t>(lag)]) -
                2.0F * correlation
        );
    }
    // Cumulative Mean Normalised Difference (CMND): divide each raw
    // difference value by the running average of all difference values up
    // to that lag, scaled by the lag itself. This is YIN's key trick --
    // it turns the naturally-decreasing-toward-zero-at-lag-0 difference
    // function into one where a true period shows up as a *dip toward
    // zero* that is directly comparable across different lags.
    std::vector<float> normalized(static_cast<std::size_t>(maximum_lag + 1), 1);
    float cumulative = 0;
    for (int lag = 1; lag <= maximum_lag; ++lag) {
        cumulative += difference[static_cast<std::size_t>(lag)];
        if (cumulative > 0) {
            normalized[static_cast<std::size_t>(lag)] =
                difference[static_cast<std::size_t>(lag)] * static_cast<float>(lag) / cumulative;
        }
    }

    // Peak picking: a local minimum of the CMND curve below the standard
    // YIN threshold (0.50) is a plausible period. Note the comparison
    // direction is inverted relative to NSDF-style peak picking above,
    // since CMND dips toward zero at the true period instead of peaking
    // toward one.
    std::vector<PitchCandidate> result;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        const float previous = normalized[static_cast<std::size_t>(lag - 1)];
        const float current = normalized[static_cast<std::size_t>(lag)];
        const float following = normalized[static_cast<std::size_t>(lag + 1)];
        if (!(current <= previous && current < following && current < 0.50F)) continue;  // not a local dip below threshold
        // Parabolic interpolation for a sub-sample-accurate lag, same
        // technique used throughout the other engines.
        const float denominator = previous - 2.0F * current + following;
        const float correction = std::abs(denominator) > 0.000001F
            ? std::clamp(0.5F * (previous - following) / denominator, -0.5F, 0.5F)
            : 0.0F;
        const double frequency = sample_rate / (static_cast<double>(lag) + correction);  // period -> frequency
        if (std::isfinite(frequency) && frequency >= kMinimumFrequency &&
            frequency <= kAnalysisMaximumFrequency) {
            result.push_back(PitchCandidate{
                frequency,
                std::clamp(static_cast<double>(1.0F - current), 0.0, 1.0),  // CMND dip depth -> confidence (lower dip = higher confidence)
                0,
                CandidateSource::yin,
            });
        }
    }
    return result;
}

// Classic normalised-autocorrelation single-candidate estimator (same
// family as vpm_like.cpp's ACF, but returning only the one selected
// candidate): prefers the shortest lag that is "close enough" to the
// globally strongest peak, to avoid locking onto a sub-multiple ghost.
std::optional<PitchCandidate> autocorrelation_candidate(
    const std::span<const float> samples,
    const double sample_rate
) {
    if (samples.size() < 1024) return std::nullopt;  // need a full analysis window
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());  // DC offset
    std::vector<float> centered(samples.size());
    std::vector<double> energy(samples.size() + 1, 0);  // prefix sum of squared amplitudes, for O(1) sub-range energy lookups
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centered[index] = static_cast<float>(static_cast<double>(samples[index]) - mean);  // DC-free sample
        const double value = centered[index];
        energy[index + 1] = energy[index] + value * value;
    }
    const int minimum_lag = std::max(2, static_cast<int>(sample_rate / kMaximumFrequency));  // shortest period (highest pitch)
    const int maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / kMinimumFrequency)  // longest period (lowest pitch)
    );
    if (minimum_lag + 2 >= maximum_lag) return std::nullopt;  // range too narrow
    std::vector<double> correlation(static_cast<std::size_t>(maximum_lag + 1), 0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {          // normalised ACF over the candidate lag range
        const auto count = centered.size() - static_cast<std::size_t>(lag);
        const double denominator = std::sqrt(std::max(
            1e-12,
            energy[count] * (energy[centered.size()] - energy[static_cast<std::size_t>(lag)])
        ));  // geometric-mean energy normaliser, floored to avoid division by ~0
        correlation[static_cast<std::size_t>(lag)] =
            static_cast<double>(float_dot(centered.data(), centered.data() + lag, count)) /
            denominator;
    }
    // Local maxima of the ACF are the plausible periods.
    std::vector<int> peaks;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        if (correlation[static_cast<std::size_t>(lag)] >= correlation[static_cast<std::size_t>(lag - 1)] &&
            correlation[static_cast<std::size_t>(lag)] > correlation[static_cast<std::size_t>(lag + 1)]) {
            peaks.push_back(lag);
        }
    }
    if (peaks.empty()) return std::nullopt;  // no periodicity evidence
    const int strongest = *std::max_element(peaks.begin(), peaks.end(), [&](const int left, const int right) {
        return correlation[static_cast<std::size_t>(left)] < correlation[static_cast<std::size_t>(right)];
    });  // lag of the tallest peak
    if (correlation[static_cast<std::size_t>(strongest)] < 0.38) return std::nullopt;  // even the best peak too weak to trust
    // Prefer the shortest lag that clears a threshold close to the
    // strongest peak's height (same "avoid sub-multiple ghosts" strategy
    // as vpm_like.cpp's `acceptance` logic).
    const double acceptance = std::max(0.52, correlation[static_cast<std::size_t>(strongest)] * 0.84);
    const auto accepted = std::find_if(peaks.begin(), peaks.end(), [&](const int lag) {
        return correlation[static_cast<std::size_t>(lag)] >= acceptance;
    });  // first (shortest-lag) peak clearing the acceptance bar
    const int selected = accepted == peaks.end() ? strongest : *accepted;  // fall back to the strongest peak if none cleared it
    // Parabolic interpolation for sub-sample-accurate lag.
    const double previous = correlation[static_cast<std::size_t>(selected - 1)];
    const double current = correlation[static_cast<std::size_t>(selected)];
    const double following = correlation[static_cast<std::size_t>(selected + 1)];
    const double denominator = previous - 2 * current + following;
    const double correction = std::abs(denominator) > 1e-6
        ? std::clamp(0.5 * (previous - following) / denominator, -0.5, 0.5) : 0;
    const double frequency = sample_rate / (static_cast<double>(selected) + correction);  // period -> frequency
    if (frequency < kMinimumFrequency || frequency > kMaximumFrequency) return std::nullopt;  // outside the reporting band
    return PitchCandidate{frequency, std::clamp(current, 0.0, 1.0), 0, CandidateSource::autocorrelation};
}

// Accelerate-backed exact NSDF/MPM candidate generator -- algorithmically
// identical to mpm.cpp's mpm_candidates (same NSDF formula, same
// local-maximum-above-threshold peak picking, same parabolic
// interpolation), just using float_dot's vDSP acceleration and returning
// every peak (capped to 12) instead of a single winner.
std::vector<PitchCandidate> mpm_candidates_exact(
    const std::span<const float> samples,
    const double sample_rate
) {
    if (samples.size() < 1024) return {};  // need a full analysis window
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());  // DC offset
    std::vector<float> centered(samples.size());
    std::vector<float> energy(samples.size() + 1, 0);  // prefix sum of squared amplitudes
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centered[index] = static_cast<float>(static_cast<double>(samples[index]) - mean);  // DC-free sample
        energy[index + 1] = energy[index] + centered[index] * centered[index];
    }
    const int minimum_lag = std::max(2, static_cast<int>(sample_rate / kMaximumFrequency));  // shortest period (highest pitch)
    const int maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / kMinimumFrequency)  // longest period (lowest pitch)
    );
    std::vector<float> nsdf(static_cast<std::size_t>(maximum_lag + 1), 0);
    for (int lag = minimum_lag; lag <= maximum_lag; ++lag) {  // McLeod NSDF, same formula as mpm.cpp
        const auto count = centered.size() - static_cast<std::size_t>(lag);
        const float normalization = energy[count] +
            (energy[centered.size()] - energy[static_cast<std::size_t>(lag)]);  // combined energy of both compared windows
        if (normalization > 1e-9F) {
            nsdf[static_cast<std::size_t>(lag)] =
                2.0F * float_dot(centered.data(), centered.data() + lag, count) / normalization;  // NSDF normalisation
        }
    }
    std::vector<PitchCandidate> result;
    for (int lag = minimum_lag + 1; lag < maximum_lag; ++lag) {  // peak picking: local maxima above a clarity threshold
        const float previous = nsdf[static_cast<std::size_t>(lag - 1)];
        const float current = nsdf[static_cast<std::size_t>(lag)];
        const float following = nsdf[static_cast<std::size_t>(lag + 1)];
        if (current < 0.55F || current < previous || current <= following) continue;  // too weak, or not a local maximum
        const float denominator = previous - 2.0F * current + following;  // parabolic interpolation for sub-sample lag accuracy
        const float correction = std::abs(denominator) > 1e-6F
            ? std::clamp(0.5F * (previous - following) / denominator, -0.5F, 0.5F) : 0;
        const double frequency = sample_rate / (static_cast<double>(lag) + correction);  // period -> frequency
        if (frequency >= kMinimumFrequency && frequency <= kMaximumFrequency) {
            result.push_back(PitchCandidate{
                frequency, std::clamp(static_cast<double>(current), 0.0, 1.0), 0,  // NSDF height doubles as confidence
                CandidateSource::mpm,
            });
        }
    }
    std::stable_sort(result.begin(), result.end(), [](const auto& left, const auto& right) {
        return left.periodicity > right.periodicity;  // strongest peaks first
    });
    if (result.size() > 12) result.resize(12);  // cap the candidate list
    return result;
}

// Single-frequency Hann-windowed spectral energy probe (same DFT-at-one-
// frequency technique as harmonic_probe.cpp, but returning squared
// magnitude directly instead of the complex value or its magnitude).
double spectral_energy(
    const std::span<const float> samples,
    const double sample_rate,
    const double frequency
) {
    if (frequency <= 0 || samples.size() <= 8) return 0;
    const double angular_step = 2 * std::numbers::pi * frequency / sample_rate;  // per-sample phase increment of the probe frequency
    const double denominator = static_cast<double>(std::max<std::size_t>(1, samples.size() - 1));  // Hann window normaliser
    double cosine = 0;
    double sine = 0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double window = 0.5 - 0.5 * std::cos(
            2 * std::numbers::pi * static_cast<double>(index) / denominator
        );  // Hann taper for this sample
        const double phase = angular_step * static_cast<double>(index);
        const double value = static_cast<double>(samples[index]) * window;  // windowed sample
        cosine += value * std::cos(phase);
        sine += value * std::sin(phase);
    }
    return cosine * cosine + sine * sine;  // squared magnitude (energy, not amplitude) of the probe response
}

// Pitch distance between two frequencies, in cents, always non-negative.
double cents(const double first, const double second) {
    return std::abs(1200 * std::log2(first / second));
}

// The heart of the V2 candidate arbitration: runs all three time-domain
// estimators (YIN, plain autocorrelation, MPM), adds a spectral octave-up
// candidate where the evidence demands it, cross-checks every candidate
// against the SWIPE'-style spectral kernel, and combines each candidate's
// own periodicity with cross-estimator agreement and spectral support into
// one final per-candidate score for the fixed-lag Viterbi tracker to
// choose among.
std::vector<ScoredPitchCandidate> scored_candidates(
    const std::span<const float> samples,
    const double sample_rate,
    const double window_rms,
    const double recent_rms_peak,
    const bool preserve_slow_fade
) {
    auto candidates = yin_candidates(samples, sample_rate);  // gather YIN's candidate list first
    candidates.erase(std::remove_if(candidates.begin(), candidates.end(), [](const auto& item) {
        return item.periodicity < 0.50;  // drop YIN candidates too weak to be worth cross-checking
    }), candidates.end());
    if (const auto candidate = autocorrelation_candidate(samples, sample_rate)) {
        candidates.push_back(*candidate);  // add the single best autocorrelation candidate, if any
    }
    const auto mpm = mpm_candidates_exact(samples, sample_rate);
    candidates.insert(candidates.end(), mpm.begin(), mpm.end());  // add every MPM candidate

    // A slowly decaying/fading note can drop below the strongest estimator
    // agreement (0.90) while its RMS also drops well under its recent peak
    // (35%) -- that combination usually means "trailing room reverb", not a
    // real sustained note, so discard everything found this frame unless
    // the caller has explicitly asked to preserve slow fades (e.g. a
    // deliberate diminuendo exercise).
    const auto strongest = std::max_element(candidates.begin(), candidates.end(), [](const auto& left, const auto& right) {
        return left.periodicity < right.periodicity;
    });
    if (!preserve_slow_fade && strongest != candidates.end() && strongest->periodicity < 0.90 &&
        window_rms < recent_rms_peak * 0.35) {
        candidates.clear();
    }
    // Octave-correction pass: for every candidate found so far, check
    // whether its exact 2x frequency has dramatically more spectral energy
    // (>= 8x) than the candidate's own frequency. If so, the period-domain
    // estimators above may have locked onto a lower sub-harmonic while the
    // true fundamental sits an octave higher; add that octave-up frequency
    // as its own high-confidence "spectral" candidate rather than
    // overwriting the original.
    const auto original_count = candidates.size();
    for (std::size_t index = 0; index < original_count; ++index) {
        const double upper = candidates[index].frequency_hz * 2;
        if (upper <= 900 || upper > kAnalysisMaximumFrequency) continue;  // only apply this correction in the high register
        if (spectral_energy(samples, sample_rate, upper) >
            spectral_energy(samples, sample_rate, candidates[index].frequency_hz) * 8) {
            candidates.push_back(PitchCandidate{
                upper, std::max(0.92, candidates[index].periodicity), 0, CandidateSource::spectral,
            });
        }
    }
    if (candidates.empty()) return {};  // nothing to score

    // Cross-check every candidate frequency against the SWIPE'-style
    // spectral kernel, all in one batched FFT-based call.
    std::vector<double> frequencies;
    frequencies.reserve(candidates.size());
    for (const auto& candidate : candidates) frequencies.push_back(candidate.frequency_hz);
    const auto supports = swipe_prime_harmonic_supports(samples, sample_rate, frequencies);  // parallel array of SWIPE' scores, one per candidate

    std::vector<ScoredPitchCandidate> result;
    result.reserve(candidates.size());
    for (std::size_t index = 0; index < candidates.size(); ++index) {
        // Cross-estimator agreement: does some *other* estimator (a
        // different `source`) have a candidate within 55 cents of this
        // one? Independent estimators agreeing on nearly the same
        // frequency is strong evidence it is the real pitch.
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
        const double agreement = agrees ? 1.0 : 0.25;  // strong bonus for cross-estimator agreement, small credit otherwise
        double score = 0.40 * candidates[index].periodicity + 0.20 * agreement +
            0.40 * supports[index];  // weighted blend of the candidate's own periodicity, agreement, and spectral support
        // This candidate exists only when its exact 2× spectral bin is at
        // least eight times stronger than the lower-period candidate. That
        // is direct fundamental evidence, not a generic octave preference;
        // keep the tracker from discarding it merely because period-domain
        // estimators agree on the lower harmonic.
        if (candidates[index].source == CandidateSource::spectral) {
            score = std::max(score, 0.90);  // floor the score high, since this candidate only exists on strong direct evidence
        }
        result.push_back(ScoredPitchCandidate{candidates[index], score});
    }
    return result;
}

// A candidate above 900 Hz is trusted only with either cross-estimator
// agreement, or strong-enough periodicity and spectral support on its own
// -- the high register is where octave/harmonic confusions are most
// common, so it needs a higher evidence bar than the rest of the range.
bool high_register_evidence(const PitchCandidate& candidate) {
    return candidate.agreement_support || (candidate.frequency_hz > 900 && candidate.periodicity >= 0.80 &&
        candidate.harmonic_support >= 0.75);
}

}  // namespace

PitchEngineV2Session::PitchEngineV2Session(
    const double minimum_rms,
    const std::size_t fixed_lag_frames
) : minimum_rms_(minimum_rms), tracker_(fixed_lag_frames, 700) {}  // 700-cent transition width for the Viterbi tracker

// Feeds one analysis window into the session: gathers scored candidates
// (or none, if too quiet/releasing), pushes them into the fixed-lag
// Viterbi tracker, and -- once the tracker resolves a source frame --
// applies the publication gates (confidence, harmonic-jump hysteresis,
// gap bridging) that decide what actually gets emitted to the caller.
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
        ++release_falls_;  // sharp frame-to-frame drop: one step toward "release" detection
    } else if (!release_active_) {
        release_falls_ = 0;  // no sharp drop (and not already releasing): reset the counter
    }
    release_rms_peak_ = std::max(rms, release_rms_peak_ * 0.995);  // slowly-decaying running loudness peak
    if (release_falls_ >= 2) release_active_ = true;  // two sharp consecutive falls: arm release suppression
    // Do not arm and immediately disarm on the second falling frame merely
    // because it is still near the long-lived peak.  Recovery is meaningful
    // only after a release had already been active for one source frame.
    if (was_release_active && rms >= release_rms_peak_ * 0.40) {
        release_active_ = false;  // signal recovered enough: this was a false alarm
        release_falls_ = 0;
    }
    previous_rms_ = rms;
    recent_rms_peak_ = std::max(rms, recent_rms_peak_ * 0.85);  // faster-decaying peak, used by scored_candidates' slow-fade gate
    const auto candidates = eligible
        ? scored_candidates(samples, sample_rate, rms, recent_rms_peak_, has_published_ && !release_active_)
        : std::vector<ScoredPitchCandidate>{};  // too quiet: no candidates this frame
    last_diagnostic_ = FrameDiagnostic{
        .input_time_seconds = source_time_seconds,
        .rms = rms,
        .input_signal_eligible = eligible,
        .input_release_active = release_active_,
        .candidates = candidates,
    };
    source_times_.push_back(source_time_seconds);          // remember this source frame's own timestamp...
    source_signal_eligible_.push_back(eligible);            // ...and its RMS-gate eligibility...
    source_release_active_.push_back(release_active_);      // ...and whether a release was active, all queued in source order
    const auto resolved = tracker_.push(candidates);  // feed into the fixed-lag Viterbi tracker
    if (!resolved) {
        last_diagnostic_.publication_reason = "fixed_lag_pending";
        return {};  // tracker's look-ahead window isn't full yet: nothing resolved this call
    }

    // The tracker resolved the *oldest* buffered source frame; pop its
    // matching metadata off the parallel queues (they always stay in sync
    // because every push above adds exactly one entry to each).
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
        // A "stable weak contour" frame -- one close to what was last
        // actually published -- is allowed to publish at a lower
        // confidence bar (0.55) than a fresh/uncertain one (0.70), since
        // continuity with the tracked contour is itself corroborating
        // evidence.
        const bool stable_weak_contour = last_published_ && tentative->confidence >= 0.55 &&
            cents(tentative->frequency_hz, last_published_->frequency_hz) <= 90;
        if (tentative->confidence >= 0.70 || stable_weak_contour) {
            publication = harmonic_filter(*tentative);  // apply the downward-harmonic-jump hysteresis before actually publishing
            last_diagnostic_.publication_reason = stable_weak_contour && tentative->confidence < 0.70
                ? "stable_weak_contour" : "published";
        }
    }
    if (last_diagnostic_.publication_reason.empty()) {
        last_diagnostic_.publication_reason = !resolved->candidate ? "no_candidate" :
            !source_eligible ? "rms_gate" : source_release_active ? "release" : "publication_gate";
    }
    auto output = bridge_startup(publication, tentative);  // handle the very first few frames of a new note specially
    if (!publication && !has_published_ && tentative) return output;  // still accumulating a tentative startup run, nothing more to do
    auto bridged = bridge_gap(publication, resolved_time, source_eligible);  // fill short silent/uncertain gaps between publications
    last_diagnostic_.bridged_frames = bridged.size() - (publication ? 1 : 0);
    output.insert(output.end(), bridged.begin(), bridged.end());
    if (publication) has_published_ = true;
    return output;
}

// Drains every frame still buffered in the fixed-lag tracker at
// end-of-stream, applying the same publication gates as process_frame
// above (duplicated here rather than shared because finish_next's
// look-ahead window shrinks near the very end of the stream).
std::vector<PublishedPitchFrame> PitchEngineV2Session::finish() {
    if (finished_) return {};
    finished_ = true;
    std::vector<PublishedPitchFrame> output;
    while (const auto resolved = tracker_.finish_next()) {  // keep draining until the tracker's buffer is empty
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

// Before the very first real publication, tentative (below-confidence but
// plausible) frames are buffered rather than discarded: a genuine note
// onset often starts a little uncertain before periodicity firms up. If a
// real publication then arrives close in pitch to the buffered run, the
// whole buffered run is released retroactively so the note's true onset
// time is preserved instead of only starting once confidence crossed the
// bar.
std::vector<PublishedPitchFrame> PitchEngineV2Session::bridge_startup(
    const std::optional<PublishedPitchFrame>& publication,
    const std::optional<PublishedPitchFrame>& tentative
) {
    if (has_published_) return {};  // startup bridging only matters before the first real publication
    if (!publication) {
        if (!tentative || tentative->confidence < 0.55 || pending_startup_.size() >= 5) {
            pending_startup_.clear();  // too weak, or the tentative run grew too long: give up on this onset attempt
        } else if (pending_startup_.empty() ||
                   cents(tentative->frequency_hz, pending_startup_.back().frequency_hz) <= 90) {
            pending_startup_.push_back(*tentative);  // extend the tentative run, it stayed on roughly the same pitch
        } else {
            pending_startup_.clear();  // pitch jumped too far: this isn't a continuation of the same onset
        }
        return {};
    }
    std::vector<PublishedPitchFrame> result;
    if (!pending_startup_.empty() && publication->confidence >= 0.70 &&
        cents(publication->frequency_hz, pending_startup_.back().frequency_hz) <= 90) {
        result = pending_startup_;  // confirmed: release the whole buffered tentative run alongside this publication
    }
    pending_startup_.clear();
    return result;
}

// Downward-harmonic-jump hysteresis for the session-level published pitch
// (same pattern as VPMLikeTracker/HAPTTracker's hysteresis, applied here to
// the tracker's already-Viterbi-resolved output): a sudden drop to roughly
// 1/2 or 1/3 of the currently published frequency is held back and
// republished as the old pitch until it repeats for 2 consecutive frames.
std::optional<PublishedPitchFrame> PitchEngineV2Session::harmonic_filter(
    const PublishedPitchFrame& frame
) {
    if (!published_frequency_) {
        published_frequency_ = frame.frequency_hz;  // first-ever publication: nothing to compare against
        return frame;
    }
    const double previous = *published_frequency_;
    const double ratio = frame.frequency_hz / previous;
    const bool harmonic_jump = frame.frequency_hz < previous && cents(frame.frequency_hz, previous) >= 650 &&
        (cents(ratio, 1.0 / 3.0) <= 110 || cents(ratio, 0.5) <= 110 || cents(ratio, 2.0 / 3.0) <= 110);  // big drop landing near 1/3, 1/2 or 2/3
    if (!harmonic_jump) {
        pending_harmonic_.reset();
        published_frequency_ = frame.frequency_hz;  // ordinary movement: publish immediately
        return frame;
    }
    if (pending_harmonic_ && cents(frame.frequency_hz, pending_harmonic_->frequency) <= 180) {
        ++pending_harmonic_->confirmations;  // same pending drop seen again: one more confirmation
        if (pending_harmonic_->confirmations >= 2) {
            pending_harmonic_.reset();
            published_frequency_ = frame.frequency_hz;  // confirmed across 2 frames: trust the drop
            return frame;
        }
    } else {
        pending_harmonic_ = PendingPitch{frame.frequency_hz, frame.confidence, 1};  // new (or first) pending candidate drop
    }
    return PublishedPitchFrame{frame.time_seconds, previous, std::min(frame.confidence, 0.55)};  // not confirmed yet: keep republishing the old pitch
}

// Fills short gaps where no frame was published this call -- either the
// signal genuinely dropped out (in which case the gap is *not* bridged and
// tracking resets) or a short run of frames simply failed the publication
// bar while the signal stayed present, in which case the last published
// pitch is quietly repeated (up to 7 frames) until either a new publication
// confirms the same contour (releasing the buffered gap frames) or the
// signal drops, clearing it.
std::vector<PublishedPitchFrame> PitchEngineV2Session::bridge_gap(
    const std::optional<PublishedPitchFrame>& frame,
    const double source_time_seconds,
    const bool source_signal_eligible
) {
    if (!frame) {
        if (!source_signal_eligible) {
            pending_gap_.clear();       // genuine silence: nothing to bridge, drop the tracked pitch entirely
            last_published_.reset();
        } else if (last_published_ && pending_gap_.size() < 7) {
            pending_gap_.push_back(PublishedPitchFrame{
                source_time_seconds, last_published_->frequency_hz, last_published_->confidence,
            });  // signal present but this frame didn't publish: tentatively repeat the last known pitch
        } else {
            pending_gap_.clear();       // gap grew too long, or nothing to repeat: give up bridging
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
        result = pending_gap_;  // confirmed: release the whole buffered gap-filler run
    }
    pending_gap_.clear();
    result.push_back(*frame);  // always include this frame's own real publication
    last_published_ = frame;
    return result;
}

void PitchEngineV2Session::reset() {
    recent_rms_peak_ = 0;
    release_rms_peak_ = 0;
    previous_rms_ = 0;
    release_falls_ = 0;
    release_active_ = false;
    tracker_.reset();                       // clear the Viterbi tracker's buffered frames
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
    if (std::isfinite(minimum_rms) && minimum_rms >= 0) minimum_rms_ = minimum_rms;  // only accept a sane, non-negative value
}

}  // namespace klarivision::core::v2
