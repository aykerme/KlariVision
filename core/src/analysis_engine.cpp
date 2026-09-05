#include "klarivision/core/analysis_engine.hpp"

#include "klarivision/core/unified_pitch_session.hpp"

#include "klarivision/core/harmonic_arbitration.hpp"
#include "klarivision/core/pitch_engine_v2_session.hpp"
#include "klarivision/core/vpm_like.hpp"
#include "klarivision/core/hapt.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
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

struct Candidate {
    double frequency{};
    double confidence{};
    double emission{};  // log-confidence; the Viterbi-style emission score used by resolve_track
};

// emission score assigned to the "silence" state in resolve_track's path search
constexpr double kSilenceEmission = -0.80;
// longest gap append_bridged will paper over with a repeated pitch
constexpr std::size_t kMaximumBridgeFrames = 7;

// DC-removed root-mean-square loudness of a window; the shared silence/
// signal-eligibility gate for every engine in this file.
double centered_rms(std::span<const float> samples) {
    if (samples.empty()) return 0;
    // DC offset
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) / samples.size();
    double sum = 0;
    for (const float sample : samples) {
        const double centered = sample - mean;  // DC-free amplitude
        sum += centered * centered;
    }
    return std::sqrt(sum / samples.size());
}

// Single-frequency Hann-windowed spectral energy probe (same DFT-at-one-
// frequency technique used throughout the codebase), returning squared
// magnitude.
double spectral_energy(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8 || frequency <= 0) return 0;
    // per-sample phase increment of the probe frequency
    const double step = 2 * std::numbers::pi * frequency / rate;
    const double denominator = static_cast<double>(samples.size() - 1);  // Hann window normaliser
    double cosine = 0;
    double sine = 0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        // Hann taper
        const double window = 0.5 - 0.5 * std::cos(2 * std::numbers::pi * index / denominator);
        const double value = samples[index] * window;  // windowed sample
        const double phase = step * index;              // accumulated phase of the probe frequency
        cosine += value * std::cos(phase);
        sine += value * std::sin(phase);
    }
    return cosine * cosine + sine * sine;  // squared magnitude of the probe response
}

double spectral_amplitude(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8) return 0;
    // `spectral_energy` uses the same Hann window. Its coherent window sum is
    // (N-1)/2, so this converts the complex magnitude to the normalized
    // amplitude used by the VPM-like estimator's 0.005 direct-support gate.
    return 4.0 * std::sqrt(spectral_energy(samples, rate, frequency)) /
        static_cast<double>(samples.size() - 1);
}

// Pitch distance between two frequencies, in cents, always non-negative.
double cents_distance(double a, double b) {
    return std::abs(1200.0 * std::log2(a / b));
}

// Dot product of two sample buffers, Accelerate-accelerated on Apple
// platforms (see pitch_engine_v2_session.cpp's identical helper).
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

// Prefix sum of squared samples, for O(1) sub-range energy lookups by
// `compute_yin_difference`.
std::vector<float> compute_prefix_energy(std::span<const float> samples) {
    std::vector<float> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        energy[index + 1] = energy[index] + samples[index] * samples[index];
    }
    return energy;
}

// YIN's difference function, computed via the same energy-minus-2x-
// correlation algebraic expansion as the V2 session's yin_candidates.
std::vector<float> compute_yin_difference(
    std::span<const float> samples, const std::vector<float>& prefix_energy, int min_lag,
    int max_lag
) {
    std::vector<float> difference(static_cast<std::size_t>(max_lag + 1), 0);
    for (int lag = min_lag; lag <= max_lag; ++lag) {
        const auto count = samples.size() - static_cast<std::size_t>(lag);
        const float correlation = float_dot(samples.data(), samples.data() + lag, count);
        difference[static_cast<std::size_t>(lag)] = std::max(
            0.0F,  // clamp tiny negative floating-point error to zero
            prefix_energy[count] +
                (prefix_energy[samples.size()] - prefix_energy[static_cast<std::size_t>(lag)]) -
                2.0F * correlation
        );
    }
    return difference;
}

// Cumulative Mean Normalised Difference: divide by the running average
// difference up to this lag, scaled by the lag -- turns the raw difference
// function into one that dips toward zero exactly at the true period,
// directly comparable across lags.
std::vector<float> compute_cumulative_mean_normalized_difference(
    const std::vector<float>& difference, int max_lag
) {
    std::vector<float> cumulative(static_cast<std::size_t>(max_lag + 1), 1);
    float total = 0;
    for (int lag = 1; lag <= max_lag; ++lag) {
        total += difference[static_cast<std::size_t>(lag)];
        if (total > 0) {
            cumulative[static_cast<std::size_t>(lag)] =
                difference[static_cast<std::size_t>(lag)] * static_cast<float>(lag) / total;
        }
    }
    return cumulative;
}

// standard YIN dip threshold below which a local minimum of the CMND curve
// is treated as a plausible period
constexpr float kYinCmndThreshold = 0.50F;
// minimum parabola curvature magnitude before trusting the sub-sample
// interpolation correction; below this the fit is numerically unstable
constexpr float kParabolicCurvatureFloor = 0.000001F;

// Peak picking: a local minimum of the CMND curve below the standard dip
// threshold is a plausible period, refined via parabolic interpolation to
// sub-sample accuracy.
std::vector<Candidate> pick_yin_peaks(
    const std::vector<float>& cumulative, double rate, int min_lag, int max_lag,
    const PitchEngineConfig& config
) {
    std::vector<Candidate> result;
    for (int lag = min_lag + 1; lag < max_lag; ++lag) {
        const bool is_dip_below_threshold = cumulative[lag] <= cumulative[lag - 1] &&
            cumulative[lag] < cumulative[lag + 1] && cumulative[lag] < kYinCmndThreshold;
        if (!is_dip_below_threshold) continue;
        // parabola curvature term
        const float denominator =
            cumulative[lag - 1] - 2.0F * cumulative[lag] + cumulative[lag + 1];
        const float correction = std::abs(denominator) > kParabolicCurvatureFloor
            ? std::clamp(
                  0.5F * (cumulative[lag - 1] - cumulative[lag + 1]) / denominator, -0.5F, 0.5F
              )
            : 0;
        const double frequency = rate / (lag + correction);  // period -> frequency
        if (frequency < config.minimum_frequency_hz ||
            frequency > config.maximum_frequency_hz) continue;
        // dip depth -> confidence
        const double confidence = std::clamp(static_cast<double>(1.0F - cumulative[lag]), 0.0, 1.0);
        // emission = log-confidence, floored to avoid log(0)
        result.push_back({frequency, confidence, std::log(std::max(1e-6, confidence))});
    }
    return result;
}

// Odd-harmonic occupancy, the one test that separates "this candidate is a
// ghost subharmonic" from "this is a real clarinet fundamental whose own
// first partial happens to be thin right now". A clarinet is a stopped
// cylinder: odd partials (3f, 5f) carry the tone and even ones are
// physically weak. So a true fundamental f always leaves energy at 3f/5f,
// while a ghost at f -- where the real note is 2f -- leaves 3f and 5f
// sitting between the real note's partials, on nothing.
double odd_harmonic_support(std::span<const float> samples, double rate, double frequency) {
    double total = 0;
    for (const double multiple : {3.0, 5.0}) {
        const double probe = frequency * multiple;
        if (probe < rate / 2) total += spectral_energy(samples, rate, probe);
    }
    return total;
}

// only apply octave recovery in the high register, above this frequency
constexpr double kOctaveRecoveryFloorHz = 800.0;
// required energy dominance of the 2x candidate over its lower octave-mate
// before it is treated as decisive
constexpr double kOctaveDominanceRatio = 8.0;
// near-maximal confidence assigned to a recovered upper octave, high enough
// that the offline path resolver retains this evidence instead of
// preferring the repeated lower period
constexpr double kOctaveRecoveryConfidence = 0.99999;

// Octave-recovery pass: for every candidate found so far, check whether its
// exact 2x frequency carries dramatically more spectral energy (>= the
// dominance ratio, and above the recovery floor). If so, add that frequency
// as its own near-maximal-confidence candidate -- the CMND minimum alone
// may have locked onto a lower sub-period while the true fundamental sits
// an octave up.
void add_octave_recovery_candidates(
    std::vector<Candidate>& result, std::span<const float> samples, double rate,
    const PitchEngineConfig& config
) {
    const auto original_count = result.size();
    for (std::size_t index = 0; index < original_count; ++index) {
        const double upper = result[index].frequency * 2;
        // only in the high register
        if (upper <= kOctaveRecoveryFloorHz || upper > config.maximum_frequency_hz) continue;
        // not a decisive enough dominance
        const bool is_upper_energy_dominant = spectral_energy(samples, rate, upper) >
            spectral_energy(samples, rate, result[index].frequency) * kOctaveDominanceRatio;
        if (!is_upper_energy_dominant) continue;
        // Raw 2x dominance alone was promoting real fundamentals: measured on
        // the Şükrü Tunar verdict set it produced 12 of YIN v1's 13 marked
        // octave errors, every one of them above 800 Hz. Require the upper
        // line to also own the odd-harmonic pattern before believing the
        // lower candidate was never a real note.
        if (odd_harmonic_support(samples, rate, upper) <=
            odd_harmonic_support(samples, rate, result[index].frequency)) continue;
        // A narrow direct-spectrum recovery for an f/2 period choice.
        result.push_back({upper, kOctaveRecoveryConfidence, std::log(kOctaveRecoveryConfidence)});
    }
}

// cap on the number of candidates returned per frame
constexpr std::size_t kMaximumYinCandidates = 12;

// Stable "YIN v1" candidate generator: the classic CMND (cumulative mean
// normalised difference) algorithm -- same formula as
// pitch_engine_v2_session.cpp's yin_candidates -- returning every plausible
// local-minimum candidate, plus a narrow octave-recovery pass at the end.
std::vector<Candidate> yin_candidates(
    std::span<const float> samples, double rate, const PitchEngineConfig& config
) {
    // shortest period to test (highest pitch)
    const int min_lag = std::max(2, static_cast<int>(rate / config.maximum_frequency_hz));
    const int max_lag = std::min(
        static_cast<int>(samples.size() / 2), static_cast<int>(rate / config.minimum_frequency_hz)
    );  // longest period (lowest pitch), capped at half the window
    if (min_lag + 2 >= max_lag) return {};  // range too narrow to hold a peak plus its neighbours

    const std::vector<float> prefix_energy = compute_prefix_energy(samples);
    const std::vector<float> difference =
        compute_yin_difference(samples, prefix_energy, min_lag, max_lag);
    const std::vector<float> cumulative =
        compute_cumulative_mean_normalized_difference(difference, max_lag);

    std::vector<Candidate> result = pick_yin_peaks(cumulative, rate, min_lag, max_lag, config);
    std::sort(result.begin(), result.end(), [](const Candidate& a, const Candidate& b) {
        return a.confidence > b.confidence;  // strongest first
    });
    add_octave_recovery_candidates(result, samples, rate, config);
    std::sort(result.begin(), result.end(), [](const Candidate& a, const Candidate& b) {
        return a.confidence > b.confidence;  // re-sort with the new candidate(s) included
    });
    // cap the candidate list
    if (result.size() > kMaximumYinCandidates) result.resize(kMaximumYinCandidates);
    return result;
}

// dominant-multiple ratio at which ghost severity starts scaling up from
// zero (below this the ghost is not flagged at all)
constexpr double kGhostRatioFloor = 6.0;
// ratio span over which severity scales linearly from 0 to 1
constexpr double kGhostRatioSpan = 20.0;
// maximum confidence penalty applied to a flagged ghost subharmonic
constexpr double kGhostMaxPenalty = 0.15;

// Score adjustment for a candidate whose own frequency is a spectral
// near-null next to a dominant 2x/3x multiple -- an autocorrelation ghost,
// not a real period. See `harmonic_arbitration.hpp` for why this pattern
// exists on closed-pipe clarinet tones and why the threshold is
// conservative. The penalty is graded, not a hard rejection: it must still
// lose fairly to continuity and to genuinely ambiguous candidates rather
// than overriding them outright.
double ghost_subharmonic_penalty(
    std::span<const float> samples, double sample_rate, double candidate_hz,
    double maximum_frequency_hz
) {
    // real-spectrum ghost check
    const auto existence =
        spectral_existence(samples, sample_rate, candidate_hz, maximum_frequency_hz);
    if (!existence.is_ghost_subharmonic) return 0.0;  // not flagged as a ghost: no penalty
    // how far past the ghost threshold the dominance ratio sits
    const double severity = std::clamp(
        (existence.dominant_multiple_ratio - kGhostRatioFloor) / kGhostRatioSpan, 0.0, 1.0
    );
    // graded penalty, scaling with how decisive the ghost evidence is
    return kGhostMaxPenalty * severity;
}

// confidence threshold identifying an explicit octave-recovery candidate
constexpr double kDirectOctaveConfidenceFloor = 0.9999;
// frequency threshold identifying the high register where octave recovery
// applies
constexpr double kDirectOctaveFrequencyFloor = 800.0;
// minimum ghost-adjusted confidence required to bootstrap a choice with no
// continuity prior available
constexpr double kBootstrapConfidenceFloor = 0.76;
// candidates below this raw confidence are not considered at all
constexpr double kMinimumCandidateConfidence = 0.55;
// maximum continuity penalty, reached once a candidate sits
// kContinuityPenaltyCentsSpan or more cents from the tracked frequency
constexpr double kContinuityPenaltyWeight = 0.30;
// cents distance at which the continuity penalty reaches its maximum
constexpr double kContinuityPenaltyCentsSpan = 700.0;

// Is `candidate` the near-maximal-confidence octave-recovery candidate that
// `yin_candidates` grants only to a high-register line whose directly
// measured spectrum exceeds its f/2 candidate by a decisive ratio?
bool is_direct_high_octave_candidate(const Candidate& candidate) {
    return candidate.frequency > kDirectOctaveFrequencyFloor &&
        candidate.confidence >= kDirectOctaveConfidenceFloor;
}

// Do not let continuity pull an explicit octave-recovery fundamental back
// to a stable low sub-period: if one is present, it short-circuits every
// other consideration below.
std::optional<Candidate> pick_direct_high_octave_candidate(
    const std::vector<Candidate>& candidates
) {
    const auto direct_high = std::max_element(
        candidates.begin(), candidates.end(), [](const Candidate& left, const Candidate& right) {
            const bool left_is_direct_high = is_direct_high_octave_candidate(left);
            const bool right_is_direct_high = is_direct_high_octave_candidate(right);
            if (left_is_direct_high != right_is_direct_high) {
                // an octave-recovery candidate always outranks a non-recovery one
                return !left_is_direct_high;
            }
            // among equals, prefer the higher frequency (max_element convention)
            return left.frequency < right.frequency;
        }
    );
    const bool found_direct_high =
        direct_high != candidates.end() && is_direct_high_octave_candidate(*direct_high);
    if (found_direct_high) return *direct_high;
    return std::nullopt;
}

// Real-spectrum ghost check, built on harmonic_arbitration.hpp's
// spectral_existence.
bool is_spectral_ghost(
    const Candidate& candidate, std::span<const float> samples, double sample_rate,
    double maximum_frequency_hz
) {
    return spectral_existence(samples, sample_rate, candidate.frequency, maximum_frequency_hz)
        .is_ghost_subharmonic;
}

// Raw confidence, graded down by the ghost-subharmonic penalty.
double ghost_adjusted_score(
    const Candidate& candidate, std::span<const float> samples, double sample_rate,
    double maximum_frequency_hz
) {
    return candidate.confidence -
        ghost_subharmonic_penalty(samples, sample_rate, candidate.frequency, maximum_frequency_hz);
}

// With no continuity prior -- exactly the state right after an
// articulation gap, where a weak-fundamental/strong-third-harmonic note is
// most likely to hand autocorrelation a ghost subharmonic as its top
// raw-confidence candidate -- bootstrap from the ghost-adjusted ranking
// instead of raw confidence alone.
std::optional<Candidate> bootstrap_from_ghost_adjusted_ranking(
    const std::vector<Candidate>& candidates, std::span<const float> samples, double sample_rate,
    double maximum_frequency_hz
) {
    // rank by ghost-penalised confidence, not raw confidence
    const auto confident = std::max_element(
        candidates.begin(), candidates.end(),
        [&](const Candidate& left, const Candidate& right) {
            return ghost_adjusted_score(left, samples, sample_rate, maximum_frequency_hz) <
                ghost_adjusted_score(right, samples, sample_rate, maximum_frequency_hz);
        }
    );
    const bool is_genuinely_confident =
        confident != candidates.end() && confident->confidence >= kBootstrapConfidenceFloor;
    if (is_genuinely_confident) return *confident;
    return std::nullopt;
}

// Normal (continuity-aware) path: pick the candidate with the best
// ghost-adjusted score, further penalised by distance from the previously
// tracked frequency (up to the continuity penalty cap at 700+ cents away).
std::optional<Candidate> pick_continuity_aware_candidate(
    const std::vector<Candidate>& candidates, const std::optional<Candidate>& previous,
    std::span<const float> samples, double sample_rate, double maximum_frequency_hz
) {
    std::optional<Candidate> best;
    double best_score = -std::numeric_limits<double>::infinity();
    for (const auto& candidate : candidates) {
        // too weak on its own terms to even consider
        if (candidate.confidence < kMinimumCandidateConfidence) continue;
        double score = ghost_adjusted_score(candidate, samples, sample_rate, maximum_frequency_hz);
        if (previous) {
            // distance from the tracked contour
            const double distance = cents_distance(candidate.frequency, previous->frequency);
            // continuity penalty, capped
            score -=
                kContinuityPenaltyWeight * std::min(distance / kContinuityPenaltyCentsSpan, 1.0);
        }
        if (score > best_score) {
            best = candidate;  // track the running best
            best_score = score;
        }
    }
    return best;
}

std::optional<Candidate> causal_yin_choice(
    const std::vector<Candidate>& candidates,
    const std::optional<Candidate>& previous,
    std::span<const float> samples,
    double sample_rate,
    double maximum_frequency_hz
) {
    if (candidates.empty()) return std::nullopt;

    const auto direct_high = pick_direct_high_octave_candidate(candidates);
    // short-circuit: trust the explicit octave-recovery evidence outright
    if (direct_high) return *direct_high;

    std::optional<Candidate> choice;
    if (!previous) {
        choice = bootstrap_from_ghost_adjusted_ranking(
            candidates, samples, sample_rate, maximum_frequency_hz
        );
    }
    if (!choice) {
        choice = pick_continuity_aware_candidate(
            candidates, previous, samples, sample_rate, maximum_frequency_hz
        );
    }
    if (choice && is_spectral_ghost(*choice, samples, sample_rate, maximum_frequency_hz)) {
        // A closed-pipe clarinet tone's ambiguous, thinnest transient
        // frames can leave nothing in the ladder but ghost subharmonics --
        // no candidate with real acoustic energy of its own clears the
        // confidence floor at all. A ghost has no period-domain claim to be
        // published as a fundamental regardless of how it ranks against
        // its equally-unreliable neighbours; staying silent lets the
        // existing gap-bridging path (`append_bridged`) recover the frame
        // from its surrounding context instead of reporting a spurious
        // subharmonic.
        return std::nullopt;
    }
    return choice;
}

// max pitch difference, in cents, allowed between the two endpoints of a
// bridged gap before append_bridged treats them as the same note
constexpr double kGapBridgeCentsTolerance = 90.0;

void append_bridged(
    std::vector<EngineFrame>& output,
    std::vector<EngineFrame>& pending_gap,
    std::optional<EngineFrame>& last,
    const std::optional<EngineFrame>& frame,
    bool signal_eligible,
    double hop_seconds,
    double minimum_endpoint_confidence,
    // The stronger endpoint must still clear `minimum_endpoint_confidence`;
    // this only relaxes the *weaker* one. A dropout's trailing edge is
    // exactly where a real engine's own confidence is most degraded by the
    // interruption itself, so requiring both endpoints to independently
    // clear the same bar under-bridges genuine short gaps. A negative value
    // (the default) keeps the original single-threshold, symmetric check.
    double minimum_weaker_endpoint_confidence = -1.0
) {
    if (!frame) {
        if (!signal_eligible) {
            // genuine silence: nothing to bridge, drop tracking
            pending_gap.clear();
            last.reset();
        } else if (last && pending_gap.size() < kMaximumBridgeFrames) {
            // Signal present but this frame didn't publish: tentatively
            // repeat the last known pitch, timestamped as if it continued.
            pending_gap.push_back({
                last->time_seconds + (pending_gap.size() + 1) * hop_seconds,
                last->frequency_hz,
                last->confidence
            });
        } else {
            // gap grew too long, or nothing to repeat: give up bridging
            pending_gap.clear();
            last.reset();
        }
        return;
    }
    // asymmetric floor for the weaker of the two endpoints, if configured
    const double weaker_floor = minimum_weaker_endpoint_confidence >= 0.0
        ? minimum_weaker_endpoint_confidence
        : minimum_endpoint_confidence;
    const bool have_both_endpoints =
        !pending_gap.empty() && last && last->frequency_hz && frame->frequency_hz;
    // Guard first: only dereference `last`/`frame`'s pitch fields once both
    // endpoints are known to actually have one.
    if (have_both_endpoints) {
        // the stronger endpoint must clear the normal bar
        const bool stronger_endpoint_clears_bar =
            std::max(last->confidence, frame->confidence) >= minimum_endpoint_confidence;
        // the weaker endpoint only needs the (possibly relaxed) floor
        const bool weaker_endpoint_clears_floor =
            std::min(last->confidence, frame->confidence) >= weaker_floor;
        // both endpoints must agree on roughly the same pitch
        const bool endpoints_agree_on_pitch =
            cents_distance(*last->frequency_hz, *frame->frequency_hz) <= kGapBridgeCentsTolerance;
        const bool is_gap_bridge_confirmed = stronger_endpoint_clears_bar &&
            weaker_endpoint_clears_floor && endpoints_agree_on_pitch;
        if (is_gap_bridge_confirmed) {
            // confirmed: release the whole buffered gap-filler run
            output.insert(output.end(), pending_gap.begin(), pending_gap.end());
        }
    }
    pending_gap.clear();
    output.push_back(*frame);  // always include this frame's own real publication
    last = frame;
}

// floor applied to the VPM-like estimator's own maximum-frequency search
// range, regardless of the caller's configured maximum
constexpr double kVpmDefaultMaximumFrequencyHz = 1650.0;

// Wraps the VPM-like estimator (vpm_like.cpp) as a single-candidate source
// for the generic Viterbi path resolver below, currently unused in favour
// of the dedicated, stateful VPM-like branch in process_frame further down.
[[maybe_unused]] std::vector<Candidate> vpm_candidates(
    std::span<const float> samples, double rate, const PitchEngineConfig& config
) {
    // VPM-like operates on double samples
    const std::vector<double> copied(samples.begin(), samples.end());
    VPMLikeConfig vpm;
    vpm.minimum_frequency_hz = config.minimum_frequency_hz;
    vpm.maximum_frequency_hz = std::max(kVpmDefaultMaximumFrequencyHz, config.maximum_frequency_hz);
    vpm.minimum_rms = config.minimum_rms;
    // run the full estimator (spectral-relative correction included)
    const auto diagnostic = diagnose_vpm_like_pitch(copied, rate, vpm);
    // `diagnostic.pitch` is the VPM-like estimator's final spectrum-aware
    // decision. Feeding its raw ACF alternatives back into the generic path
    // resolver discarded that decision and repeatedly selected f/2 instead.
    const bool has_usable_pitch = diagnostic.pitch &&
        diagnostic.pitch->confidence >= vpm.minimum_output_confidence &&
        diagnostic.pitch->frequency_hz <= config.maximum_frequency_hz;
    if (has_usable_pitch) {
        // single candidate, emission = log-confidence
        return {{diagnostic.pitch->frequency_hz, diagnostic.pitch->confidence,
                 std::log(diagnostic.pitch->confidence)}};
    }
    return {};
}

struct ViterbiState {
    std::optional<Candidate> candidate;
    double score;
    int prior;  // index of the best-preceding state, for backtracking
};

// pitch_engine_v2's transition-penalty width, in cents
constexpr double kV2TransitionWidthCents = 700.0;
// vpm_like's transition-penalty width, in cents
constexpr double kVpmTransitionWidthCents = 420.0;
// transition-penalty width, in cents, for every other engine
constexpr double kDefaultTransitionWidthCents = 500.0;
// fixed score penalty for switching voiced <-> silence
constexpr double kSilenceTransitionPenalty = 0.55;
// cap on the pitch-distance transition penalty
constexpr double kMaximumTransitionPenalty = 3.0;

// Per-engine transition-penalty width, in cents, used by build_viterbi_layer.
double transition_width_cents(PitchEngineId id) {
    if (id == PitchEngineId::pitch_engine_v2) return kV2TransitionWidthCents;
    if (id == PitchEngineId::vpm_like) return kVpmTransitionWidthCents;
    return kDefaultTransitionWidthCents;
}

// Builds one frame's layer of Viterbi states: a "silence" state plus one
// state per candidate, each scored against every state of the previous
// layer (candidate's own emission score, plus a transition penalty for
// jumping frequency -- or switching to/from silence -- between consecutive
// frames).
std::vector<ViterbiState> build_viterbi_layer(
    const std::vector<Candidate>& frame_candidates, const std::vector<ViterbiState>& previous_layer,
    double width
) {
    std::vector<ViterbiState> current;
    current.push_back({std::nullopt, kSilenceEmission, -1});  // always include a "silence" state
    for (const auto& candidate : frame_candidates) {
        // one state per candidate this frame
        current.push_back({candidate, candidate.emission, -1});
    }
    if (previous_layer.empty()) return current;  // first frame: no transition scoring yet
    for (auto& state : current) {
        double best = -std::numeric_limits<double>::infinity();
        int prior = 0;
        for (std::size_t previous = 0; previous < previous_layer.size(); ++previous) {
            const auto& before = previous_layer[previous];
            double transition = 0;
            if (state.candidate && before.candidate) {
                const double distance =
                    cents_distance(state.candidate->frequency, before.candidate->frequency);
                // pitch-distance penalty between two voiced states
                transition = -std::min(distance / width, kMaximumTransitionPenalty);
            } else if (state.candidate || before.candidate) {
                // fixed penalty for switching voiced <-> silence
                transition = -kSilenceTransitionPenalty;
            }
            // cumulative path score reaching this state via `previous`
            const double score = before.score + state.score + transition;
            if (score > best) {
                best = score;
                prior = static_cast<int>(previous);  // track the best-scoring predecessor
            }
        }
        state.score = best;
        state.prior = prior;
    }
    return current;
}

// Starts from the best-scoring state in the final layer, then walks
// backwards through each layer's stored `prior` pointer to recover the
// whole winning path.
std::vector<EngineFrame> backtrack_viterbi_path(
    const std::vector<std::vector<ViterbiState>>& layers, double rate,
    const PitchEngineConfig& config
) {
    std::vector<EngineFrame> output(layers.size());
    int state = static_cast<int>(
        std::max_element(
            layers.back().begin(), layers.back().end(),
            [](const ViterbiState& a, const ViterbiState& b) { return a.score < b.score; }
        ) - layers.back().begin()
    );
    for (std::size_t index = layers.size(); index-- > 0;) {
        const auto& selected = layers[index][state];
        // frame's centre time
        output[index].time_seconds =
            static_cast<double>(index * config.hop_size + config.window_size / 2) / rate;
        if (selected.candidate) {
            // voiced state: report the pitch
            output[index].frequency_hz = selected.candidate->frequency;
            output[index].confidence = selected.candidate->confidence;
        }
        state = selected.prior;  // step one frame back along the winning path
        // guard against an unset prior pointer on the very first frame
        if (state < 0 && index > 0) state = 0;
    }
    return output;
}

// Generic offline Viterbi path resolver over a whole pre-computed sequence
// of per-frame candidate lists: for each frame, adds a "silence" state plus
// one state per candidate, and finds the highest-scoring path through all
// frames. Currently unused (each engine below runs its own dedicated,
// causal/online tracking logic instead), kept as the shared non-causal
// alternative.
[[maybe_unused]] std::vector<EngineFrame> resolve_track(
    const std::vector<std::vector<Candidate>>& frames, double rate, const PitchEngineConfig& config,
    PitchEngineId id
) {
    std::vector<std::vector<ViterbiState>> layers;  // one layer of states per frame
    const double width = transition_width_cents(id);
    for (std::size_t frame = 0; frame < frames.size(); ++frame) {
        std::vector<ViterbiState> current = layers.empty()
            ? build_viterbi_layer(frames[frame], {}, width)
            : build_viterbi_layer(frames[frame], layers.back(), width);
        layers.push_back(std::move(current));
    }
    if (layers.empty()) return std::vector<EngineFrame>(frames.size());
    return backtrack_viterbi_path(layers, rate, config);
}
}  // namespace


// Per-session mutable state for every supported engine. Only the fields for
// the currently-selected `id` are actually driven by process_frame, but
// they all live together so switching engines (or reset()) is just a matter
// of rebuilding this one struct.
struct ProductionPitchSession::Impl {
    // Only constructed for unified_v1. The legacy engines keep their existing
    // state layout untouched, so adding a fifth engine cannot perturb the
    // baseline the fifth engine is measured against.
    std::unique_ptr<UnifiedPitchSession> unified{};

    PitchEngineId id;             // which engine this session runs (yin_v1, vpm_like, hapt_v1, pitch_engine_v2)
    PitchEngineConfig config;

    // --- YIN v1 state: continuity tracking + release/silence bookkeeping ---
    std::optional<Candidate> last_yin;              // last published YIN candidate, used for continuity scoring
    std::optional<Candidate> pending_yin_jump;       // a large downward jump awaiting confirmation
    int pending_yin_confirmations{};                 // how many consecutive frames have confirmed the pending jump
    int silent_yin_estimates{};                      // consecutive frames with no publication, used to fully reset stale state
    double recent_yin_rms_peak{};                    // fast-decaying RMS peak, used for the slow-fade gate
    double yin_release_rms_peak{};                    // slow-decaying RMS peak, used for release recovery detection
    double previous_yin_rms{};                       // previous frame's RMS, for the sharp-fall release detector
    int yin_release_falls{};                          // consecutive sharp RMS falls
    bool yin_release_active{};                        // whether a note release is currently suppressing output

    // --- VPM-like state: contour tracking + gap/attack bookkeeping ---
    std::optional<EngineFrame> vpm_last_strong_contour;  // last confidently-published VPM-like pitch
    std::vector<EngineFrame> vpm_pending_gap;            // buffered frames awaiting gap-bridging confirmation
    double vpm_release_rms_peak{};                       // slow-decaying RMS peak
    double vpm_direct_support_peak{};                    // slow-decaying peak of direct spectral support at the tracked contour
    double previous_vpm_rms{};                           // previous frame's RMS
    int vpm_release_falls{};                             // consecutive sharp RMS falls
    bool vpm_release_suspected{};                        // whether a release is currently suspected
    bool vpm_waiting_for_attack{};                        // whether the tracker is waiting for a fresh, recovered attack before resuming
    VPMSessionDiagnostic vpm_diagnostic;                  // most recent frame's full diagnostic record
    VPMLikeTracker vpm_tracker;                           // the downward-harmonic-jump hysteresis tracker itself

    v2::PitchEngineV2Session v2_session;   // the entire V2 engine's session state lives inside this one object

    // --- Shared gap-bridging state, used by yin_v1 and hapt_v1 via append_bridged ---
    std::vector<EngineFrame> pending_gap;
    std::optional<EngineFrame> last_published;
    bool finished{};

    // --- HAPT state ---
    HAPTConfig hapt_config;
    HAPTTracker hapt_tracker;

    // How many frames V2's fixed-lag Viterbi tracker buffers before it will
    // commit to a decision.
    static constexpr int kV2ViterbiLagFrames = 5;

    Impl(const PitchEngineId selected, const PitchEngineConfig selected_config)
        : id(selected), config(selected_config),
          v2_session(selected_config.minimum_rms, kV2ViterbiLagFrames) {
        hapt_config.minimum_frequency_hz = selected_config.minimum_frequency_hz;
        hapt_config.maximum_frequency_hz = selected_config.maximum_frequency_hz;
        hapt_config.minimum_rms = selected_config.minimum_rms;
        hapt_tracker = HAPTTracker(hapt_config);
    }

    // --- Per-engine frame processing, extracted from process_frame -------
    // Each of these mirrors one of the four engine branches process_frame
    // used to hold inline. yin_v1 and vpm_like additionally need to signal
    // "return this exact vector from process_frame right now" without
    // falling through to the shared gap-bridging tail below; they do that
    // by returning a populated std::optional.
    std::vector<EngineFrame> process_v2_frame(
        std::span<const float> samples, double rate, double source_time
    );
    std::optional<std::vector<EngineFrame>> process_yin_frame(
        std::span<const float> samples, double rate, double source_time,
        double rms, bool eligible, std::optional<EngineFrame>& publication
    );
    std::vector<EngineFrame> process_vpm_frame(
        std::span<const float> samples, double rate, double source_time,
        double rms, bool eligible
    );
    std::optional<EngineFrame> process_hapt_frame(
        std::span<const float> samples, double rate, double source_time,
        double rms, bool eligible
    );
    // Shared gap-bridging tail used by yin_v1 and hapt_v1 only.
    std::vector<EngineFrame> build_bridged_output(
        double rate, bool eligible, const std::optional<EngineFrame>& publication
    );

    // --- YIN v1 sub-steps --------------------------------------------------
    void update_yin_release_state(double rms);
    std::optional<std::vector<EngineFrame>> compute_yin_publication(
        std::span<const float> samples, double rate, double source_time,
        double rms, std::optional<EngineFrame>& publication
    );
    std::optional<Candidate> recover_octave_up_yin_candidate(
        const std::vector<Candidate>& candidates, const Candidate& choice,
        std::span<const float> samples, double rate
    ) const;
    std::optional<Candidate> recover_dominant_harmonic_yin_candidate(
        const std::vector<Candidate>& candidates, const Candidate& choice,
        std::span<const float> samples, double rate
    ) const;
    bool apply_yin_jump_hysteresis(const std::optional<Candidate>& choice);
    bool should_publish_yin_candidate(const Candidate& choice, double rms) const;
    void track_yin_silence();

    // --- VPM-like sub-steps -------------------------------------------------
    struct VpmEstimatePair {
        std::optional<VPMLikePitch> weak;
        std::optional<VPMLikePitch> normal;
    };
    struct VpmDirectSupport {
        double amplitude{};
        bool lost{};
    };
    void begin_vpm_diagnostic(double source_time, double rms, bool eligible);
    void update_vpm_release_detection(double rms, VPMSessionDiagnostic& diagnostic);
    VpmEstimatePair compute_vpm_estimates(
        std::span<const float> samples, double rate, bool eligible,
        VPMSessionDiagnostic& diagnostic
    );
    VpmDirectSupport update_vpm_direct_support(
        std::span<const float> samples, double rate, VPMSessionDiagnostic& diagnostic
    );
    void clear_vpm_contour();
    void queue_vpm_gap(double source_time, VPMSessionDiagnostic& diagnostic);
    std::vector<EngineFrame> handle_vpm_signal_gate_closed(VPMSessionDiagnostic& diagnostic);
    std::optional<std::vector<EngineFrame>> handle_vpm_waiting_for_attack(
        const std::optional<VPMLikePitch>& normal_estimate, VPMSessionDiagnostic& diagnostic
    );
    std::vector<EngineFrame> handle_vpm_release_suspected(
        std::span<const float> samples, double rate, double source_time,
        const std::optional<VPMLikePitch>& weak_estimate,
        const std::optional<VPMLikePitch>& normal_estimate,
        VPMSessionDiagnostic& diagnostic
    );
    std::vector<EngineFrame> resolve_vpm_publication(
        std::span<const float> samples, double rate, double source_time,
        const std::optional<VPMLikePitch>& weak_estimate,
        const std::optional<VPMLikePitch>& normal_estimate,
        double direct_support, VPMSessionDiagnostic& diagnostic
    );
};

ProductionPitchSession::ProductionPitchSession(
    const PitchEngineId id,
    const PitchEngineConfig config
) : impl_(std::make_unique<Impl>(id, config)) {}

ProductionPitchSession::~ProductionPitchSession() = default;
ProductionPitchSession::ProductionPitchSession(ProductionPitchSession&&) noexcept = default;
ProductionPitchSession& ProductionPitchSession::operator=(ProductionPitchSession&&) noexcept = default;

// Advances every engine by one analysis window. Only yin_v1 and hapt_v1
// share the gap-bridging tail at the bottom; pitch_engine_v2 and vpm_like
// are each fully self-contained and return directly from their own branch.
std::vector<EngineFrame> ProductionPitchSession::process_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time
) {
    auto& session = *impl_;
    // invalid input, or not enough samples for a full window
    if (rate <= 0 || samples.size() < session.config.window_size) return {};
    if (session.finished) {
        throw std::logic_error(
            "Pitch session is finished; call reset before processing more frames"
        );
    }
    if (session.id == PitchEngineId::pitch_engine_v2) {
        return session.process_v2_frame(samples, rate, source_time);
    }
    if (session.id == PitchEngineId::unified_v1) {
        // Self-contained, like v2: it owns candidate generation, path decoding
        // and its own publication decision, including the decision to stay
        // silent. The shared gap-bridging tail below would only undo that.
        if (!session.unified) {
            session.unified = std::make_unique<UnifiedPitchSession>(session.config);
        }
        return session.unified->process_frame(samples, rate, source_time);
    }

    const double rms = centered_rms(samples);  // this window's loudness
    // Shared silence/signal-eligibility gate.
    const bool eligible = rms >= session.config.minimum_rms;
    std::optional<EngineFrame> publication;

    if (session.id == PitchEngineId::yin_v1) {
        if (const auto early_exit =
            session.process_yin_frame(samples, rate, source_time, rms, eligible, publication)) {
            return *early_exit;
        }
    } else if (session.id == PitchEngineId::vpm_like) {
        return session.process_vpm_frame(samples, rate, source_time, rms, eligible);
    } else if (session.id == PitchEngineId::hapt_v1) {
        publication = session.process_hapt_frame(samples, rate, source_time, rms, eligible);
    }

    return session.build_bridged_output(rate, eligible, publication);
}

// V2 has its own fully self-contained session (candidate generation,
// Viterbi tracking, publication gating); just forward to it and translate
// its frame type.
std::vector<EngineFrame> ProductionPitchSession::Impl::process_v2_frame(
    const std::span<const float> samples, const double rate, const double source_time
) {
    std::vector<EngineFrame> output;
    for (const auto& frame : v2_session.process_frame(samples, rate, source_time)) {
        output.push_back({frame.time_seconds, frame.frequency_hz, frame.confidence});
    }
    return output;
}

// Updates the release/decay detector from this frame's RMS and, if a
// release is now active, fully clears YIN's continuity state so the next
// real attack starts fresh instead of continuing a stale contour. A note
// release falls much faster than the intentional, slow fades used in
// musical phrasing; two sharp RMS falls arm a release until a new attack
// has recovered.
void ProductionPitchSession::Impl::update_yin_release_state(const double rms) {
    // frame-to-frame drop this sharp counts as a possible release
    constexpr double kSharpRmsDropRatio = 0.80;
    constexpr double kFastPeakDecay = 0.85;          // fast-decaying peak (slow-fade gate)
    // slow-decaying peak (release recovery threshold)
    constexpr double kSlowPeakDecay = 0.995;
    // consecutive sharp falls that arm release suppression
    constexpr int kReleaseFallThreshold = 2;
    // fraction of the slow peak that counts as "recovered"
    constexpr double kReleaseRecoveryRatio = 0.40;
    if (previous_yin_rms > 0 && rms < previous_yin_rms * kSharpRmsDropRatio) {
        ++yin_release_falls;  // sharp frame-to-frame drop
    } else if (!yin_release_active) {
        yin_release_falls = 0;  // no sharp drop (and not already releasing): reset the counter
    }
    recent_yin_rms_peak = std::max(rms, recent_yin_rms_peak * kFastPeakDecay);
    yin_release_rms_peak = std::max(rms, yin_release_rms_peak * kSlowPeakDecay);
    // arm release suppression
    if (yin_release_falls >= kReleaseFallThreshold) yin_release_active = true;
    if (yin_release_active && rms >= yin_release_rms_peak * kReleaseRecoveryRatio) {
        yin_release_active = false;  // signal recovered enough: this was a false alarm
        yin_release_falls = 0;
    }
    previous_yin_rms = rms;
    if (yin_release_active) {
        // Release suppression fully clears continuity state so the next
        // real attack starts fresh rather than continuing a stale
        // contour.
        last_yin.reset();
        pending_yin_jump.reset();
        pending_yin_confirmations = 0;
    }
}

// The same narrow ambiguity repair exists in the established live YIN
// path: 2f must be a real YIN minimum with almost equal periodicity and at
// least three times the measured line energy.
std::optional<Candidate> ProductionPitchSession::Impl::recover_octave_up_yin_candidate(
    const std::vector<Candidate>& candidates,
    const Candidate& choice,
    const std::span<const float> samples,
    const double rate
) const {
    // upper must be at least this far above the current choice
    constexpr double kOctaveUpMinimumRatio = 1.5;
    constexpr double kOctaveUpMaximumHz = 900.0;         // and still below this frequency
    // how close a real candidate must sit to the octave-up frequency
    constexpr double kCandidateCentsTolerance = 55.0;
    // how much lower the upper candidate's confidence may be
    constexpr double kOctaveUpConfidenceSlack = 0.05;
    // upper must be this many times louder than lower
    constexpr double kOctaveUpEnergyRatio = 3.0;
    std::optional<Candidate> recovery;
    double recovery_energy = 0;
    // scan every candidate as a potential "lower" (sub-period) anchor
    for (const auto& lower : candidates) {
        const double upper = lower.frequency * 2;  // its octave-up frequency
        if (upper <= choice.frequency * kOctaveUpMinimumRatio ||
            // only relevant well above the current choice, and below 900 Hz
            upper > kOctaveUpMaximumHz) continue;
        const auto upper_it = std::find_if(
            candidates.begin(), candidates.end(), [&](const Candidate& candidate) {
                // must be a genuine CMND-minimum candidate near the octave-up frequency
                return cents_distance(candidate.frequency, upper) <= kCandidateCentsTolerance &&
                    // ...with comparable confidence to the lower candidate
                    candidate.confidence >= lower.confidence - kOctaveUpConfidenceSlack;
            }
        );
        // no real candidate exists at the octave-up frequency
        if (upper_it == candidates.end()) continue;
        const double upper_energy = spectral_energy(samples, rate, upper_it->frequency);
        // decisively louder than the lower candidate
        if (upper_energy > spectral_energy(samples, rate, lower.frequency) * kOctaveUpEnergyRatio &&
            // and the strongest such recovery found so far
            upper_energy > recovery_energy) {
            recovery = *upper_it;
            recovery_energy = upper_energy;
        }
    }
    return recovery;
}

// Promote to a genuine higher-register candidate only when a real candidate
// exists there. The previous unconditional form invented a synthetic
// candidate at `candidate.frequency * factor` from bare spectral energy
// alone, disconnected from anything YIN's own difference function had
// actually found -- on a closed-pipe clarinet tone the dominant spectral
// partial can be the third harmonic of a note whose fundamental is still
// the correct, quieter answer, so comparing that partial's absolute energy
// against the fundamental's is not evidence the partial is itself a
// fundamental. Require it to already be a scored YIN candidate (i.e. a
// genuine CMND minimum) before treating it as one.
std::optional<Candidate> ProductionPitchSession::Impl::recover_dominant_harmonic_yin_candidate(
    const std::vector<Candidate>& candidates,
    const Candidate& choice,
    const std::span<const float> samples,
    const double rate
) const {
    // how close a real candidate must sit to the harmonic frequency
    constexpr double kCandidateCentsTolerance = 55.0;
    // harmonic must sit above this, and above the current choice
    constexpr double kMinimumUpperHz = 900.0;
    // harmonic must be this many times louder than its anchor
    constexpr double kDominantHarmonicEnergyRatio = 8.0;
    std::optional<Candidate> upper_recovery;
    double strongest_upper_energy = 0;
    // every candidate is a potential lower anchor to check for a dominant harmonic
    for (const auto& candidate : candidates) {
        const double candidate_energy = spectral_energy(samples, rate, candidate.frequency);
        // check the 3rd harmonic before the 2nd (clarinet's dominant closed-pipe partial)
        for (const double factor : {3.0, 2.0}) {
            const double upper = candidate.frequency * factor;
            if (upper <= std::max(kMinimumUpperHz, choice.frequency) ||
                // must be well above the current choice and in range
                upper > config.maximum_frequency_hz) continue;
            const auto upper_it = std::find_if(
                candidates.begin(), candidates.end(), [&](const Candidate& other) {
                    // must be a genuine CMND-minimum candidate
                    return cents_distance(other.frequency, upper) <= kCandidateCentsTolerance;
                }
            );
            // no real candidate at that harmonic frequency
            if (upper_it == candidates.end()) continue;
            const double upper_energy = spectral_energy(samples, rate, upper_it->frequency);
            // decisively dominant
            if (upper_energy > candidate_energy * kDominantHarmonicEnergyRatio &&
                // and strongest found so far
                upper_energy > strongest_upper_energy) {
                upper_recovery = *upper_it;
                strongest_upper_energy = upper_energy;
            }
        }
    }
    return upper_recovery;
}

// Downward-jump hysteresis: a candidate more than 900 cents (nearly an
// octave and a half) below the last published pitch is held back and
// requires 3 consecutive confirming frames (each within 360 cents of the
// pending candidate) before being trusted -- the same defensive pattern as
// VPMLikeTracker and HAPTTracker, applied here to the legacy YIN v1 path.
// Returns true when the caller must publish nothing this frame.
bool ProductionPitchSession::Impl::apply_yin_jump_hysteresis(
    const std::optional<Candidate>& choice
) {
    constexpr double kDownwardJumpCentsThreshold = 900.0;
    constexpr double kPendingJumpCentsTolerance = 360.0;
    constexpr int kPendingJumpConfirmations = 3;
    if (choice && last_yin &&
        choice->frequency < last_yin->frequency &&
        cents_distance(choice->frequency, last_yin->frequency) > kDownwardJumpCentsThreshold) {
        if (pending_yin_jump && cents_distance(
            choice->frequency, pending_yin_jump->frequency
        ) < kPendingJumpCentsTolerance) {
            ++pending_yin_confirmations;  // same pending drop seen again
            pending_yin_jump = choice;
            // not confirmed enough yet
            if (pending_yin_confirmations < kPendingJumpConfirmations) return true;
            pending_yin_jump.reset();
            pending_yin_confirmations = 0;
            return false;  // confirmed: `choice` will be published by the caller
        }
        pending_yin_jump = choice;      // new (or first) pending candidate drop
        pending_yin_confirmations = 1;
        return true;  // not confirmed at all yet: publish nothing this frame
    }
    pending_yin_jump.reset();          // ordinary movement: clear any pending-jump state
    pending_yin_confirmations = 0;
    return false;
}

// Final publication gate: suppress a below-confidence candidate during what
// looks like a slow, non-release fade-out (RMS well under its recent peak)
// -- the same "trailing reverb, not a real note" reasoning as the V2
// session's scored_candidates.
bool ProductionPitchSession::Impl::should_publish_yin_candidate(
    const Candidate& choice, const double rms
) const {
    constexpr double kLowConfidenceThreshold = 0.90;
    constexpr double kFadeRmsRatio = 0.35;
    return !yin_release_active &&
        !(choice.confidence < kLowConfidenceThreshold && rms < recent_yin_rms_peak * kFadeRmsRatio);
}

// Count consecutive non-publishing frames; once the tracked contour has
// been silent/uncertain for long enough, it is no longer meaningful, so
// fully reset continuity state.
void ProductionPitchSession::Impl::track_yin_silence() {
    constexpr int kSilentResetFrames = 30;
    ++silent_yin_estimates;  // count consecutive non-publishing frames
    if (silent_yin_estimates >= kSilentResetFrames) {
        last_yin.reset();
        pending_yin_jump.reset();
        pending_yin_confirmations = 0;
        pending_gap.clear();
    }
}

// Runs the whole eligible-frame YIN pipeline: candidate generation, the two
// harmonic-ambiguity repairs, the downward-jump hysteresis gate, and the
// final publication gate. Returns a populated vector only when the caller
// must return that exact vector (unconfirmed jump) instead of continuing.
std::optional<std::vector<EngineFrame>> ProductionPitchSession::Impl::compute_yin_publication(
    const std::span<const float> samples,
    const double rate,
    const double source_time,
    const double rms,
    std::optional<EngineFrame>& publication
) {
    // gather every plausible CMND-minimum candidate
    const auto candidates = yin_candidates(samples, rate, config);
    auto choice = causal_yin_choice(
        candidates, last_yin, samples, rate, config.maximum_frequency_hz
    );  // pick the best candidate, ghost-aware and continuity-aware
    if (choice) {
        if (const auto recovery =
            recover_octave_up_yin_candidate(candidates, *choice, samples, rate)) {
            choice = recovery;  // adopt the recovered octave-up candidate, if one was found
        }
    }
    if (choice) {
        if (const auto recovery =
            recover_dominant_harmonic_yin_candidate(candidates, *choice, samples, rate)) {
            choice = recovery;  // adopt the recovered higher-harmonic candidate, if one was found
        }
    }
    if (apply_yin_jump_hysteresis(choice)) return std::vector<EngineFrame>{};
    if (choice && should_publish_yin_candidate(*choice, rms)) {
        publication = EngineFrame{source_time, choice->frequency, choice->confidence};
        last_yin = choice;          // becomes the new continuity anchor
        silent_yin_estimates = 0;   // reset the "stale state" counter
    }
    return std::nullopt;
}

// Drives the entire yin_v1 branch: updates the release detector, runs the
// eligible-frame pipeline (which may demand an immediate early return), and
// otherwise tracks how long the session has gone without a publication.
std::optional<std::vector<EngineFrame>> ProductionPitchSession::Impl::process_yin_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time,
    const double rms,
    const bool eligible,
    std::optional<EngineFrame>& publication
) {
    update_yin_release_state(rms);
    if (eligible) {
        if (const auto early_exit =
            compute_yin_publication(samples, rate, source_time, rms, publication)) {
            return early_exit;
        }
    }
    if (!publication) track_yin_silence();
    return std::nullopt;
}

// Starts a fresh per-frame diagnostic record, seeded with this frame's
// basic loudness/eligibility facts and the previously tracked contour.
void ProductionPitchSession::Impl::begin_vpm_diagnostic(
    const double source_time, const double rms, const bool eligible
) {
    vpm_diagnostic = {};  // start a fresh diagnostic record for this frame
    vpm_diagnostic.input_time_seconds = source_time;
    vpm_diagnostic.rms = rms;
    vpm_diagnostic.signal_eligible = eligible;
    if (vpm_last_strong_contour) {
        vpm_diagnostic.last_strong_contour_hz = vpm_last_strong_contour->frequency_hz;
    }
}

// Release/decay detection, same pattern as the YIN branch: a slow-decaying
// RMS peak sets the recovery bar, and consecutive sharp falls (unless the
// envelope is still close to that peak) arm suspicion of a release.
void ProductionPitchSession::Impl::update_vpm_release_detection(
    const double rms, VPMSessionDiagnostic& diagnostic
) {
    constexpr double kReleasePeakDecay = 0.995;
    constexpr double kSharpRmsDropRatio = 0.85;
    constexpr int kReleaseFallThreshold = 2;
    constexpr double kReleaseArmRatioFloor = 0.60;
    vpm_release_rms_peak = std::max(rms, vpm_release_rms_peak * kReleasePeakDecay);
    diagnostic.recent_rms_peak = vpm_release_rms_peak;
    diagnostic.rms_to_peak_ratio = vpm_release_rms_peak > 0
        ? rms / vpm_release_rms_peak : 0;
    if (previous_vpm_rms > 0 && rms < previous_vpm_rms * kSharpRmsDropRatio) {
        ++vpm_release_falls;  // sharp frame-to-frame drop
    } else if (!vpm_release_suspected &&
        (vpm_release_falls < kReleaseFallThreshold ||
            diagnostic.rms_to_peak_ratio >= kReleaseArmRatioFloor)) {
        // no sharp drop, and not close to arming release suspicion: reset the counter
        vpm_release_falls = 0;
    }
    previous_vpm_rms = rms;
}

// Two confidence tiers: `weak` uses a looser confidence floor (0.38) purely
// to feed the diagnostic/contour-hold logic downstream; `normal` requires a
// much higher bar (0.80) before being treated as trustworthy enough to
// actually publish or update the tracked contour.
ProductionPitchSession::Impl::VpmEstimatePair ProductionPitchSession::Impl::compute_vpm_estimates(
    const std::span<const float> samples,
    const double rate,
    const bool eligible,
    VPMSessionDiagnostic& diagnostic
) {
    constexpr double kWeakConfidenceFloor = 0.38;
    constexpr double kWeakMaximumFrequencyFloorHz = 1650.0;
    constexpr double kNormalConfidenceFloor = 0.80;
    VpmEstimatePair result;
    if (!eligible) return result;
    // VPM-like operates on double samples
    const std::vector<double> copied(samples.begin(), samples.end());
    VPMLikeConfig weak_config;
    weak_config.minimum_frequency_hz = config.minimum_frequency_hz;
    weak_config.maximum_frequency_hz =
        std::max(kWeakMaximumFrequencyFloorHz, config.maximum_frequency_hz);
    weak_config.minimum_rms = config.minimum_rms;
    weak_config.minimum_output_confidence = kWeakConfidenceFloor;
    if (config.enable_vpm_diagnostics) {
        // full diagnostic run, more expensive
        const auto estimator = diagnose_vpm_like_pitch(copied, rate, weak_config);
        diagnostic.strongest_periodicity = estimator.strongest_periodicity;
        result.weak = estimator.pitch;
    } else {
        // fast path, no diagnostic bookkeeping
        result.weak = estimate_vpm_like_pitch(copied, rate, weak_config);
        diagnostic.strongest_periodicity = result.weak ? result.weak->confidence : 0;
    }
    if (result.weak) {
        diagnostic.weak_estimate_hz = result.weak->frequency_hz;
        if (result.weak->confidence >= kNormalConfidenceFloor) {
            result.normal = result.weak;  // promote to the trustworthy tier
            diagnostic.normal_estimate_hz = result.normal->frequency_hz;
        }
    }
    return result;
}

// Direct spectral support at the *currently tracked contour's own
// frequency*: this is what actually detects a release, distinct from the
// RMS-based falls above -- the overall envelope can stay loud (room
// reverb, other instruments) even after the tracked note's own fundamental
// has genuinely disappeared from the spectrum.
ProductionPitchSession::Impl::VpmDirectSupport
ProductionPitchSession::Impl::update_vpm_direct_support(
    const std::span<const float> samples,
    const double rate,
    VPMSessionDiagnostic& diagnostic
) {
    constexpr double kDirectSupportPeakDecay = 0.995;
    constexpr double kDirectSupportLostFloor = 0.005;
    constexpr double kDirectSupportLostRatio = 0.35;
    constexpr int kReleaseFallThreshold = 2;
    constexpr double kReleaseSuspectRmsRatio = 0.35;
    VpmDirectSupport result;
    if (vpm_last_strong_contour && vpm_last_strong_contour->frequency_hz) {
        result.amplitude =
            spectral_amplitude(samples, rate, *vpm_last_strong_contour->frequency_hz);
        vpm_direct_support_peak = std::max(
            result.amplitude, vpm_direct_support_peak * kDirectSupportPeakDecay
        );  // slow-decaying peak of that support, used as the "lost" comparison baseline
    }
    diagnostic.direct_fundamental_support = result.amplitude;
    diagnostic.recent_direct_support_peak = vpm_direct_support_peak;
    result.lost = vpm_last_strong_contour &&
        // essentially no energy left at the tracked frequency, or
        (result.amplitude < kDirectSupportLostFloor ||
         (vpm_direct_support_peak > 0 &&
          // it has decayed well below its own recent peak
          result.amplitude < vpm_direct_support_peak * kDirectSupportLostRatio));
    if (vpm_last_strong_contour && vpm_release_falls >= kReleaseFallThreshold &&
        diagnostic.rms_to_peak_ratio < kReleaseSuspectRmsRatio && result.lost) {
        vpm_release_suspected = true;  // all three signals agree: this looks like a genuine release
    }
    diagnostic.release_suspected = vpm_release_suspected;
    return result;
}

// Fully clears the tracked contour and every piece of associated state --
// used both when a release is confirmed and when the signal drops out
// entirely.
void ProductionPitchSession::Impl::clear_vpm_contour() {
    vpm_pending_gap.clear();
    vpm_last_strong_contour.reset();
    vpm_release_suspected = false;
    vpm_release_falls = 0;
    vpm_direct_support_peak = 0;
    vpm_tracker.reset();
}

// Buffers a tentative "repeat the last known pitch" frame for a short
// dropout, or gives up and clears the contour once the gap has run too
// long (or there is nothing to bridge from).
void ProductionPitchSession::Impl::queue_vpm_gap(
    const double source_time, VPMSessionDiagnostic& diagnostic
) {
    if (!vpm_last_strong_contour || vpm_pending_gap.size() >= kMaximumBridgeFrames) {
        clear_vpm_contour();
        vpm_waiting_for_attack = true;  // require a fresh, recovered attack before resuming
        diagnostic.publication_reason = "gap_expired";
        return;
    }
    const auto& anchor = *vpm_last_strong_contour;
    vpm_pending_gap.push_back({source_time, anchor.frequency_hz, anchor.confidence});
    diagnostic.publication_reason = vpm_release_suspected
        ? "release_pending" : "dropout_pending";
}

// Crossing the fixed RMS gate is enough to end the current anchor, but a
// gradual musical trough is not by itself release evidence. Require a
// recovered attack only when the causal release detector (or an expired
// gap) had already armed it.
std::vector<EngineFrame> ProductionPitchSession::Impl::handle_vpm_signal_gate_closed(
    VPMSessionDiagnostic& diagnostic
) {
    const bool require_recovered_attack = vpm_release_suspected || vpm_waiting_for_attack;
    clear_vpm_contour();
    vpm_waiting_for_attack = require_recovered_attack;
    diagnostic.publication_reason = "rms_gate_closed";
    diagnostic.pending_gap_frames = 0;
    return {};
}

// Held in this state until a confident estimate arrives *and* the envelope
// has climbed back to at least 40% of its recent peak -- both signals must
// agree a genuine new attack, not just a noisy blip, has started. Returns a
// populated vector only when the caller must return {} right now.
std::optional<std::vector<EngineFrame>> ProductionPitchSession::Impl::handle_vpm_waiting_for_attack(
    const std::optional<VPMLikePitch>& normal_estimate, VPMSessionDiagnostic& diagnostic
) {
    constexpr double kAttackRecoveryRmsRatio = 0.40;
    if (!normal_estimate || diagnostic.rms_to_peak_ratio < kAttackRecoveryRmsRatio) {
        diagnostic.publication_reason = "waiting_for_attack";
        return std::vector<EngineFrame>{};
    }
    vpm_waiting_for_attack = false;
    vpm_release_falls = 0;
    vpm_tracker.reset();  // fresh attack: don't let the tracker's old hysteresis state leak into it
    return std::nullopt;
}

// While a release is suspected, only two outcomes are possible this frame:
// the envelope recovers back onto the *same* contour (a false alarm --
// e.g. a brief dip in a sustained note), or it recovers onto a genuinely
// *different* contour (a new attack right after the old note actually
// ended). Anything else keeps queuing the gap/waiting.
std::vector<EngineFrame> ProductionPitchSession::Impl::handle_vpm_release_suspected(
    const std::span<const float> samples,
    const double rate,
    const double source_time,
    const std::optional<VPMLikePitch>& weak_estimate,
    const std::optional<VPMLikePitch>& normal_estimate,
    VPMSessionDiagnostic& diagnostic
) {
    // accept a slightly weaker estimate for same-contour recovery specifically
    constexpr double kWeakRecoveryConfidenceFloor = 0.70;
    constexpr double kEnvelopeRecoveredRmsRatio = 0.40;
    constexpr double kSameContourCentsTolerance = 90.0;
    constexpr double kDirectSupportPeakDecay = 0.995;
    const auto recovery = normal_estimate ? normal_estimate :
        (weak_estimate && weak_estimate->confidence >= kWeakRecoveryConfidenceFloor
            ? weak_estimate : std::nullopt);
    const bool envelope_recovered = diagnostic.rms_to_peak_ratio >= kEnvelopeRecoveredRmsRatio;

    std::vector<EngineFrame> vpm_output;
    std::optional<EngineFrame> publication;
    if (envelope_recovered && recovery && vpm_last_strong_contour &&
        vpm_last_strong_contour->frequency_hz &&
        cents_distance(recovery->frequency_hz,
            *vpm_last_strong_contour->frequency_hz) <= kSameContourCentsTolerance) {
        // False alarm: same contour recovered. Release the whole buffered
        // gap run and resume tracking from a clean state.
        vpm_output = vpm_pending_gap;
        diagnostic.bridged_frames = vpm_output.size();
        vpm_pending_gap.clear();
        vpm_release_suspected = false;
        vpm_waiting_for_attack = false;
        vpm_release_falls = 0;
        vpm_tracker.reset();
        const auto decision = vpm_tracker.process(recovery);
        if (decision) {
            publication = EngineFrame{source_time, decision->frequency_hz, decision->confidence};
            vpm_output.push_back(*publication);
        }
        if (normal_estimate && publication) {
            vpm_last_strong_contour = publication;
            vpm_direct_support_peak = std::max(
                spectral_amplitude(samples, rate, *publication->frequency_hz),
                vpm_direct_support_peak * kDirectSupportPeakDecay
            );
        }
        diagnostic.publication_reason = "same_contour_recovery";
    } else if (envelope_recovered && normal_estimate &&
        vpm_last_strong_contour && vpm_last_strong_contour->frequency_hz &&
        cents_distance(normal_estimate->frequency_hz,
            *vpm_last_strong_contour->frequency_hz) > kSameContourCentsTolerance) {
        // Genuine new attack on a different pitch: the old note really did
        // end. Clear the old contour and start fresh rather than trying to
        // bridge across it.
        clear_vpm_contour();
        vpm_waiting_for_attack = false;
        const auto decision = vpm_tracker.process(normal_estimate);
        if (decision && decision->frequency_hz <= config.maximum_frequency_hz) {
            publication = EngineFrame{source_time, decision->frequency_hz, decision->confidence};
            vpm_output.push_back(*publication);
            vpm_last_strong_contour = publication;
            vpm_direct_support_peak = spectral_amplitude(samples, rate, *publication->frequency_hz);
        }
        diagnostic.publication_reason = "different_contour_attack";
    } else {
        // Neither recovery pattern matched yet: keep waiting, buffering a
        // tentative gap-filler frame.
        vpm_tracker.reset();
        queue_vpm_gap(source_time, diagnostic);
    }
    diagnostic.release_suspected = vpm_release_suspected;
    diagnostic.pending_gap_frames = vpm_pending_gap.size();
    return vpm_output;
}

// The non-release-suspected path: either a confident new estimate arrives
// (fed through the downward-harmonic-jump hysteresis tracker), a weak
// estimate agrees with the still-supported tracked contour, or nothing
// usable arrived at all this frame.
std::vector<EngineFrame> ProductionPitchSession::Impl::resolve_vpm_publication(
    const std::span<const float> samples,
    const double rate,
    const double source_time,
    const std::optional<VPMLikePitch>& weak_estimate,
    const std::optional<VPMLikePitch>& normal_estimate,
    const double direct_support,
    VPMSessionDiagnostic& diagnostic
) {
    constexpr double kSameContourCentsTolerance = 90.0;
    constexpr double kLargeDropCentsThreshold = 650.0;
    constexpr double kMinimumDivisor = 1e-9;
    constexpr double kDirectSupportPeakDecay = 0.995;
    constexpr double kDirectSupportLostFloor = 0.005;
    std::optional<EngineFrame> publication;
    std::vector<EngineFrame> vpm_output;
    if (normal_estimate) {
        // If the new estimate drops far (>650 cents) below the currently
        // tracked contour, compute how much stronger the old (upper)
        // contour's own direct spectral support still is relative to the
        // new, lower estimate -- this is exactly the veto signal
        // VPMLikeTracker::process uses to decide whether to trust the drop
        // immediately or hold it back for confirmation.
        std::optional<double> upper_to_estimate_ratio;
        if (vpm_last_strong_contour && vpm_last_strong_contour->frequency_hz &&
            normal_estimate->frequency_hz < *vpm_last_strong_contour->frequency_hz &&
            cents_distance(normal_estimate->frequency_hz,
                *vpm_last_strong_contour->frequency_hz) > kLargeDropCentsThreshold) {
            const double lower_support =
                spectral_amplitude(samples, rate, normal_estimate->frequency_hz);
            upper_to_estimate_ratio = direct_support / std::max(kMinimumDivisor, lower_support);
            diagnostic.established_upper_to_estimate_ratio = upper_to_estimate_ratio;
        }
        const auto decision = vpm_tracker.process(
            normal_estimate, upper_to_estimate_ratio
        );  // apply the downward-harmonic-jump hysteresis
        if (decision && decision->frequency_hz <= config.maximum_frequency_hz) {
            publication = EngineFrame{source_time, decision->frequency_hz, decision->confidence};
            diagnostic.harmonic_veto = cents_distance(
                decision->frequency_hz, normal_estimate->frequency_hz
            // the tracker overrode the raw estimate: this frame was vetoed/held back
            ) > kSameContourCentsTolerance;
            if (!vpm_pending_gap.empty()) {
                if (vpm_last_strong_contour && vpm_last_strong_contour->frequency_hz &&
                    cents_distance(decision->frequency_hz,
                        *vpm_last_strong_contour->frequency_hz) <= kSameContourCentsTolerance) {
                    // same contour as before the gap: release the buffered gap-fill frames
                    vpm_output = vpm_pending_gap;
                    diagnostic.bridged_frames = vpm_output.size();
                }
                vpm_pending_gap.clear();
            }
            vpm_output.push_back(*publication);
            if (!diagnostic.harmonic_veto) {
                // Only a genuinely trusted (non-vetoed) publication updates
                // the tracked contour and its support peak.
                vpm_last_strong_contour = publication;
                vpm_direct_support_peak = std::max(
                    spectral_amplitude(samples, rate, *publication->frequency_hz),
                    vpm_direct_support_peak * kDirectSupportPeakDecay
                );
            }
            diagnostic.publication_reason = diagnostic.harmonic_veto
                ? "harmonic_veto" :
                (diagnostic.bridged_frames ? "dropout_bridged" : "normal_contour");
        }
    } else if (weak_estimate && vpm_last_strong_contour &&
        vpm_last_strong_contour->frequency_hz && direct_support >= kDirectSupportLostFloor &&
        cents_distance(weak_estimate->frequency_hz,
            *vpm_last_strong_contour->frequency_hz) <= kSameContourCentsTolerance) {
        // No confident new estimate, but a weak one agrees with the still-
        // supported tracked contour: republish the tracked contour's own
        // frequency rather than following the noisier weak estimate.
        publication = EngineFrame{
            source_time,
            vpm_last_strong_contour->frequency_hz,
            weak_estimate->confidence,
        };
        vpm_pending_gap.clear();
        vpm_output.push_back(*publication);
        diagnostic.publication_reason = "weak_contour_hold";
    } else {
        // No usable estimate at all this frame: buffer a gap-filler (or
        // give up and clear the contour if the gap has run too long).
        vpm_tracker.process(std::nullopt);
        queue_vpm_gap(source_time, diagnostic);
    }
    diagnostic.pending_gap_frames = vpm_pending_gap.size();
    return vpm_output;
}

// Drives the entire vpm_like branch: diagnostic setup, release detection,
// candidate estimation, direct-support tracking, then dispatches to the
// signal-gate/waiting-for-attack/release-suspected/normal paths, each of
// which returns its own final vector directly.
std::vector<EngineFrame> ProductionPitchSession::Impl::process_vpm_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time,
    const double rms,
    const bool eligible
) {
    begin_vpm_diagnostic(source_time, rms, eligible);
    auto& diagnostic = vpm_diagnostic;
    update_vpm_release_detection(rms, diagnostic);
    const auto estimates = compute_vpm_estimates(samples, rate, eligible, diagnostic);
    const auto support = update_vpm_direct_support(samples, rate, diagnostic);

    if (!eligible) return handle_vpm_signal_gate_closed(diagnostic);

    if (vpm_waiting_for_attack) {
        if (const auto early_exit = handle_vpm_waiting_for_attack(estimates.normal, diagnostic)) {
            return *early_exit;
        }
    }

    if (vpm_release_suspected) {
        return handle_vpm_release_suspected(
            samples, rate, source_time, estimates.weak, estimates.normal, diagnostic
        );
    }

    return resolve_vpm_publication(
        samples, rate, source_time, estimates.weak, estimates.normal, support.amplitude, diagnostic
    );
}

// HAPT's own onset/decay recovery and inter-harmonic veto live inside
// estimate_hapt_pitch (hapt.cpp); HAPTTracker layers the RMS release
// detector and downward-harmonic-jump confirmation delay on top of that
// per-frame estimate -- the one piece of state shared verbatim with the
// offline/tournament trace tool, so both see identical release behaviour.
// Below the hard minimum_rms floor there is no signal at all, so a full
// reset is simpler than feeding the tracker a sub-floor RMS value.
std::optional<EngineFrame> ProductionPitchSession::Impl::process_hapt_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time,
    const double rms,
    const bool eligible
) {
    if (!eligible) {
        // below the hard RMS floor: full reset rather than feeding a sub-floor RMS
        hapt_tracker.reset();
        return std::nullopt;
    }
    // Stateless per-frame HAPT estimate, given the tracker's current
    // published pitch as continuity context.
    const auto estimate = estimate_hapt_pitch(
        samples, rate, hapt_config, hapt_tracker.published_frequency_hz()
    );
    // apply release detection + jump hysteresis
    const auto tracked = hapt_tracker.process(estimate, rms);
    if (!tracked) return std::nullopt;
    return EngineFrame{source_time, tracked->frequency_hz, tracked->confidence};
}

// Shared gap-bridging tail for the yin_v1 and hapt_v1 engines (VPM-like and
// V2 already returned above, using their own dedicated bridging logic):
// buffers/repeats the last published pitch across short dropouts, with an
// engine-specific confidence bar.
std::vector<EngineFrame> ProductionPitchSession::Impl::build_bridged_output(
    const double rate, const bool eligible, const std::optional<EngineFrame>& publication
) {
    constexpr double kYinBridgeConfidenceFloor = 0.55;
    constexpr double kHaptBridgeConfidenceFloor = 0.60;
    constexpr double kDefaultBridgeConfidenceFloor = 0.70;
    // HAPT alone relaxes the weaker gap endpoint's floor
    constexpr double kHaptWeakerEndpointConfidenceFloor = 0.30;
    // keeps append_bridged's single, symmetric threshold
    constexpr double kNoWeakerEndpointRelaxation = -1.0;
    std::vector<EngineFrame> output;
    append_bridged(
        output, pending_gap, last_published, publication, eligible,
        static_cast<double>(config.hop_size) / rate,
        id == PitchEngineId::yin_v1 ? kYinBridgeConfidenceFloor :
            (id == PitchEngineId::hapt_v1
                ? kHaptBridgeConfidenceFloor : kDefaultBridgeConfidenceFloor),
        id == PitchEngineId::hapt_v1
            ? kHaptWeakerEndpointConfidenceFloor : kNoWeakerEndpointRelaxation
    );
    return output;
}

// Flushes any engine-specific end-of-stream state. Only V2 needs this (its
// fixed-lag Viterbi tracker buffers several frames of look-ahead that must
// be drained); the other engines are already fully causal frame-by-frame.
std::vector<EngineFrame> ProductionPitchSession::finish() {
    if (impl_->finished) return {};
    impl_->finished = true;
    if (impl_->id == PitchEngineId::unified_v1) {
        // Drain the fixed-lag window using the real remaining suffix as
        // look-ahead. At 15 hops this tail is 160 ms, and dropping it would
        // silently truncate the end of every recording.
        return impl_->unified ? impl_->unified->finish() : std::vector<EngineFrame>{};
    }
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
    // rebuild from scratch, preserving only the engine choice and configuration
    impl_ = std::make_unique<Impl>(id, config);
}

void ProductionPitchSession::set_minimum_rms(const double minimum_rms) {
    if (!std::isfinite(minimum_rms) || minimum_rms < 0) return;  // reject a nonsensical value
    impl_->config.minimum_rms = minimum_rms;
    impl_->v2_session.set_minimum_rms(minimum_rms);  // keep V2's own copy in sync
    impl_->hapt_config.minimum_rms = minimum_rms;     // keep HAPT's own copy in sync
}


PitchEngine::PitchEngine(PitchEngineId id, PitchEngineProfile profile, PitchEngineConfig config)
    : id_(id), profile_(profile), config_(config) {}

void PitchEngine::reset() {
    buffered_samples_.clear();
    sample_rate_ = 0;
}

// Accumulates mono samples for later offline analysis; samples at a
// different sample rate than the first push are silently dropped (a
// session is expected to be single-sample-rate).
void PitchEngine::push(std::span<const float> mono_samples, double sample_rate) {
    if (sample_rate_ == 0) {
        sample_rate_ = sample_rate;
    }
    if (std::abs(sample_rate - sample_rate_) < 0.001) {
        buffered_samples_.insert(buffered_samples_.end(), mono_samples.begin(), mono_samples.end());
    }
}

std::vector<EngineFrame> PitchEngine::finish() {
    auto result = analyse(buffered_samples_, sample_rate_);
    reset();
    return result;
}

// Runs a fresh ProductionPitchSession over the whole buffer, frame by frame
// (as if streaming live), collecting every published frame plus the final
// flush from session.finish().
namespace {

// Converts a Viterbi cursor back into an option index. Kept as a single
// named helper because the backtrack loop below performs this exact
// int -> std::size_t conversion twice.
std::size_t to_index(const int value) {
    return static_cast<std::size_t>(value);
}

// Per-engine transition width for the offline path refinement, in cents.
// Calibrated against the Şükrü Tunar listener verdicts: a narrower width
// suppresses isolated jumps harder, but too narrow also fights genuine fast
// runs.  Pitch Engine v2 already carries a five-frame Viterbi of its own, so
// it needs (and tolerates) a looser width than the causal engines.
double offline_transition_width_cents(const PitchEngineId id) {
    return id == PitchEngineId::pitch_engine_v2 ? 250.0 : 150.0;
}

// Spectral evidence sets an alternative's *price*, it does not gate admission.
// Gating was wrong: on the frames that actually needed repair the correct
// fundamental often measures below 2% of the family's strongest member -- that
// is precisely why the causal engine got them wrong, and precisely the case
// where only the path carries the information.  So every harmonic alternative
// stays available, and one with no spectral backing simply costs more.
constexpr double kOfflineUnsupportedFloor = 0.30;
// Alternatives enter the path search below the causal decision's own score, so
// a frame only moves when path continuity -- not local evidence -- demands it.
constexpr double kOfflineAlternativeDiscount = 0.72;
// Published frames further apart than this are treated as separate runs: no
// continuity is implied across an articulation gap.
constexpr double kOfflineSegmentGapSeconds = 0.030;
// Transition cost is quadratic in cents so that a single 1200-cent excursion
// pays far more than the many small steps of a real run.  Capped so one wild
// frame cannot dominate the whole path score.
constexpr double kOfflineMaximumTransition = 12.0;

// A published run this short, with silence on both sides and no better
// evidence than this, is a stray point rather than a note.
constexpr std::size_t kOfflineStrayMaximumFrames = 7;
// Silence required on *both* sides.  This is what keeps the rule off real
// ornaments: a çarpma is attached to the note it decorates, not marooned in
// silence, so it never clears this test.
constexpr double kOfflineStrayIsolationSeconds = 0.040;
// VPM-like's own publication bar.  On every stray point the listener marked,
// VPM-like was the engine that correctly stayed quiet, and the runs the others
// published peaked at 0.66-0.81 confidence.  Holding a short isolated run to
// that same bar is the rule; it is not a number fitted to those frames.
constexpr double kOfflineStrayConfidence = 0.80;
// Frames further apart than this are treated as separate voiced runs when
// grouping the track for stray-run detection, in seconds.
constexpr double kOfflineRunSplitGapSeconds = 0.012;

// Returns the indices of every voiced (frequency-bearing) frame in the track,
// in order. Stray-run detection only ever reasons about voiced frames.
std::vector<std::size_t> collect_voiced_frame_indices(const std::vector<EngineFrame>& track) {
    std::vector<std::size_t> voiced;
    for (std::size_t index = 0; index < track.size(); ++index) {
        if (track[index].frequency_hz && *track[index].frequency_hz > 0) {
            voiced.push_back(index);
        }
    }
    return voiced;
}

// Groups the voiced frames into contiguous runs, splitting wherever two
// neighbouring voiced frames are more than kOfflineRunSplitGapSeconds apart.
// Each returned pair is [first, last] as positions into `voiced`, not as
// indices into `track`.
std::vector<std::pair<std::size_t, std::size_t>> split_into_voiced_runs(
    const std::vector<EngineFrame>& track,
    const std::vector<std::size_t>& voiced
) {
    std::vector<std::pair<std::size_t, std::size_t>> runs;
    std::size_t begin = 0;
    for (std::size_t position = 1; position <= voiced.size(); ++position) {
        const bool split = position == voiced.size() ||
            track[voiced[position]].time_seconds - track[voiced[position - 1]].time_seconds >
                kOfflineRunSplitGapSeconds;
        if (split) {
            runs.push_back({begin, position - 1});
            begin = position;
        }
    }
    return runs;
}

// A run qualifies for removal only when it is short, silence-isolated on
// both sides, and never rose above VPM-like's own publication bar. Any one
// of those failing means it is treated as a real note or ornament.
bool is_stray_run(
    const std::vector<EngineFrame>& track,
    const std::vector<std::size_t>& voiced,
    const std::vector<std::pair<std::size_t, std::size_t>>& runs,
    const std::size_t run
) {
    const auto [first, last] = runs[run];
    if (last - first + 1 > kOfflineStrayMaximumFrames) {
        return false;
    }
    const double before = run == 0 ? std::numeric_limits<double>::infinity()
        : track[voiced[first]].time_seconds - track[voiced[runs[run - 1].second]].time_seconds;
    const double after = run + 1 == runs.size() ? std::numeric_limits<double>::infinity()
        : track[voiced[runs[run + 1].first]].time_seconds - track[voiced[last]].time_seconds;
    if (before < kOfflineStrayIsolationSeconds || after < kOfflineStrayIsolationSeconds) {
        return false;
    }
    double peak = 0;
    for (std::size_t position = first; position <= last; ++position) {
        peak = std::max(peak, track[voiced[position]].confidence);
    }
    return peak < kOfflineStrayConfidence;
}

// Drops short, isolated, low-confidence runs from an offline track.
std::vector<EngineFrame> drop_offline_stray_runs(const std::vector<EngineFrame>& track) {
    const std::vector<std::size_t> voiced = collect_voiced_frame_indices(track);
    if (voiced.size() < 2) {
        return track;
    }
    const std::vector<std::pair<std::size_t, std::size_t>> runs =
        split_into_voiced_runs(track, voiced);

    std::vector<bool> drop(track.size(), false);
    for (std::size_t run = 0; run < runs.size(); ++run) {
        if (!is_stray_run(track, voiced, runs, run)) {
            continue;
        }
        const auto [first, last] = runs[run];
        for (std::size_t position = first; position <= last; ++position) {
            drop[voiced[position]] = true;
        }
    }

    std::vector<EngineFrame> kept;
    kept.reserve(track.size());
    for (std::size_t index = 0; index < track.size(); ++index) {
        if (!drop[index]) {
            kept.push_back(track[index]);
        }
    }
    return kept;
}

// Offline (non-causal) harmonic path refinement over the causal baseline.
//
// This is the piece `PitchEngineProfile::offline_track` was reserved for.  The
// causal engines must decide each frame with no future context, and that is
// exactly where they lose: measured on the listener verdicts, 33 of 47 marked
// octave errors last only 1-3 frames (median 2, longest 9) in the middle of
// otherwise correct tracking.  pYIN does not make those errors because it
// decodes a path over the whole recording, where an isolated 1200-cent
// excursion can never repay its transition cost.
//
// The live path is untouched: `analyse_causal` and every `ProductionPitchSession`
// keep their latency contract.  Only the Study/offline entry point refines.
//
// `resolve_track` above is the generic resolver, but it assumes one candidate
// layer per hop and reconstructs frame times from the hop index.  A published
// track is sparse -- gated, bridged and flushed frames only -- so this pass
// runs its own search over exactly the frames that were published, preserving
// their times and their voiced/unvoiced decisions untouched.

// One frame's worth of candidate frequencies in the offline path search: the
// causal decision plus every octave/harmonic alternative worth pricing.
struct Alternative {
    double frequency;
    double confidence;
    double emission;
};

// A published frame together with the alternatives it offers the path
// search, keyed back to its position in the causal baseline.
struct Layer {
    std::size_t index;
    std::vector<Alternative> options;
};

// One member of a harmonic family probed at a candidate frequency, with the
// spectral energy actually measured there.
struct Probe {
    double frequency;
    double energy;
};

// Measures the published frequency and its octave/harmonic relatives against
// the audio the causal engine actually saw, so each member can later be
// judged against the strongest of the family rather than against the
// (possibly wrong) published line.
//
// 4x/5x complete the ladder a stopped cylinder actually produces. Without
// them a frame published on its own 4th or 5th sub-period has no route back:
// at 116.379 s the causal pass published 121.25 Hz between a 695.63 Hz and a
// 604.50 Hz neighbour, and the true 604.5 Hz line is 5x of it, so the old
// {1/3,1/2,2,3} set could only offer 242.5 and 363.75 -- the path was
// choosing among wrong answers. Reaching further is safe *here*, unlike in
// the causal ghost checks, because the transition cost decides: a 5x
// alternative is only taken when the neighbouring frames already sit there,
// so a genuinely low note (112.29 s, where the correct line is the low one
// and its own 2x carries ten times the energy) keeps its published pitch.
std::vector<Probe> measure_harmonic_family(
    const double published,
    const std::span<const float> view,
    const double rate,
    const PitchEngineConfig& config
) {
    std::vector<Probe> family{{published, spectral_energy(view, rate, published)}};
    for (const double ratio : {0.2, 0.25, 1.0 / 3.0, 0.5, 2.0, 3.0, 4.0, 5.0}) {
        const double alternative = published * ratio;
        if (alternative < config.minimum_frequency_hz ||
            alternative > config.maximum_frequency_hz) {
            continue;
        }
        family.push_back({alternative, spectral_energy(view, rate, alternative)});
    }
    return family;
}

// Builds the alternative list for one published frame: the causal decision
// itself, plus every harmonic alternative found within this frame's own
// analysis window, priced by how much spectral support it has relative to
// the strongest member of its family. Spectral evidence sets price, not
// admission -- see the file-level comment above for why.
std::vector<Alternative> offline_alternative_options(
    const EngineFrame& frame,
    const std::span<const float> samples,
    const double rate,
    const PitchEngineConfig& config
) {
    const double published = *frame.frequency_hz;
    const double confidence = std::max(frame.confidence, 1e-3);
    std::vector<Alternative> options{
        {published, confidence, std::log(confidence)}  // the causal decision always competes
    };

    // Locate this frame's own analysis window so alternatives are judged
    // against the audio the engine actually saw.
    const auto window = static_cast<std::int64_t>(config.window_size);
    const auto start =
        static_cast<std::int64_t>(std::llround(frame.time_seconds * rate)) - window / 2;
    if (start < 0 || start + window > static_cast<std::int64_t>(samples.size())) {
        return options;
    }

    const auto view = samples.subspan(static_cast<std::size_t>(start), config.window_size);
    const std::vector<Probe> family = measure_harmonic_family(published, view, rate, config);
    double strongest = 0;
    for (const auto& probe : family) {
        strongest = std::max(strongest, probe.energy);
    }
    for (std::size_t member = 1; member < family.size(); ++member) {
        const double support = strongest > 0 ? family[member].energy / strongest : 0.0;
        const double backing = kOfflineUnsupportedFloor +
            (1.0 - kOfflineUnsupportedFloor) * std::clamp(support, 0.0, 1.0);
        const double scaled = confidence * kOfflineAlternativeDiscount * backing;
        options.push_back({family[member].frequency, scaled, std::log(std::max(scaled, 1e-6))});
    }
    return options;
}

// Builds one search layer per voiced baseline frame; voicing itself is not
// revisited here, only the frequency chosen for already-voiced frames.
std::vector<Layer> build_offline_layers(
    const std::vector<EngineFrame>& baseline,
    const std::span<const float> samples,
    const double rate,
    const PitchEngineConfig& config
) {
    std::vector<Layer> layers;
    for (std::size_t index = 0; index < baseline.size(); ++index) {
        const auto& frame = baseline[index];
        if (!frame.frequency_hz || *frame.frequency_hz <= 0) {
            continue;
        }
        auto options = offline_alternative_options(frame, samples, rate, config);
        layers.push_back({index, std::move(options)});
    }
    return layers;
}

// Runs the forward Viterbi pass over the search layers: for every option in
// every layer, finds the best-scoring predecessor option in the previous
// layer, given the transition cost between them. Returns the per-option
// running score and the chosen predecessor, one array per layer.
std::pair<std::vector<std::vector<double>>, std::vector<std::vector<int>>>
compute_offline_viterbi_scores(
    const std::vector<Layer>& layers,
    const std::vector<EngineFrame>& baseline,
    const double width
) {
    std::vector<std::vector<double>> score(layers.size());
    std::vector<std::vector<int>> prior(layers.size());
    for (std::size_t layer = 0; layer < layers.size(); ++layer) {
        const auto& options = layers[layer].options;
        score[layer].assign(options.size(), 0.0);
        prior[layer].assign(options.size(), -1);
        if (layer == 0) {
            for (std::size_t option = 0; option < options.size(); ++option) {
                score[layer][option] = options[option].emission;
            }
            continue;
        }
        const double elapsed = baseline[layers[layer].index].time_seconds -
            baseline[layers[layer - 1].index].time_seconds;
        const bool continuous = elapsed <= kOfflineSegmentGapSeconds;
        const auto& before = layers[layer - 1].options;
        for (std::size_t option = 0; option < options.size(); ++option) {
            double best = -std::numeric_limits<double>::infinity();
            int chosen = 0;
            for (std::size_t previous = 0; previous < before.size(); ++previous) {
                double transition = 0.0;
                if (continuous) {
                    const double distance = cents_distance(
                        options[option].frequency, before[previous].frequency
                    ) / width;
                    transition = -std::min(distance * distance, kOfflineMaximumTransition);
                }
                const double total = score[layer - 1][previous] + transition;
                if (total > best) {
                    best = total;
                    chosen = static_cast<int>(previous);
                }
            }
            score[layer][option] = best + options[option].emission;
            prior[layer][option] = chosen;
        }
    }
    return {score, prior};
}

// Walks the Viterbi back-pointers from the best-scoring final option back to
// the first layer, writing the chosen frequency and confidence into a copy
// of the baseline at each layer's original frame index.
std::vector<EngineFrame> backtrack_offline_viterbi_path(
    const std::vector<EngineFrame>& baseline,
    const std::vector<Layer>& layers,
    const std::vector<std::vector<double>>& score,
    const std::vector<std::vector<int>>& prior
) {
    auto refined = baseline;
    const auto best = std::max_element(score.back().begin(), score.back().end());
    auto cursor = static_cast<int>(best - score.back().begin());
    for (std::size_t layer = layers.size(); layer-- > 0;) {
        const auto& option = layers[layer].options[to_index(cursor)];
        auto& frame = refined[layers[layer].index];
        frame.frequency_hz = option.frequency;
        frame.confidence = option.confidence;
        cursor = prior[layer][to_index(cursor)];
        if (cursor < 0 && layer > 0) {
            cursor = 0;
        }
    }
    return refined;
}

// Offline (non-causal) harmonic path refinement over the causal baseline.
// Builds one search layer per voiced frame, runs a forward Viterbi pass with
// a cents-based transition cost, then backtracks the best path. See the
// block comment above this section for why this exists and what it fixes.
std::vector<EngineFrame> refine_offline_harmonics(
    const std::vector<EngineFrame>& baseline,
    const std::span<const float> samples,
    const double rate,
    const PitchEngineConfig& config,
    const PitchEngineId id
) {
    const double width = offline_transition_width_cents(id);
    const std::vector<Layer> layers = build_offline_layers(baseline, samples, rate, config);
    if (layers.size() < 3) {
        return baseline;  // nothing a path can say
    }

    const auto [score, prior] = compute_offline_viterbi_scores(layers, baseline, width);
    return backtrack_offline_viterbi_path(baseline, layers, score, prior);
}

}  // namespace

std::vector<EngineFrame> PitchEngine::analyse_causal(
    const std::span<const float> samples,
    const double rate
) {
    if (rate <= 0 || samples.size() < config_.window_size) {
        return {};
    }
    ProductionPitchSession session(id_, config_);
    std::vector<EngineFrame> output;
    // slide a fixed-size window across the buffer
    for (std::size_t start = 0;
         start + config_.window_size <= samples.size();
         start += config_.hop_size) {
        // this window's centre time
        const double time = (static_cast<double>(start) + config_.window_size / 2.0) / rate;
        auto published =
            session.process_frame(samples.subspan(start, config_.window_size), rate, time);
        output.insert(output.end(), published.begin(), published.end());
    }
    // flush any buffered look-ahead (V2's Viterbi tail)
    auto final = session.finish();
    output.insert(output.end(), final.begin(), final.end());
    return output;
}

// Public offline entry point. For the offline_track profile this runs the
// non-causal harmonic path refinement over the causal baseline; every other
// profile is returned unchanged, so the live contract is unaffected.
std::vector<EngineFrame> PitchEngine::analyse(
    const std::span<const float> samples,
    const double rate
) {
    if (id_ == PitchEngineId::unified_v1) {
        if (profile_ != PitchEngineProfile::offline_track) return analyse_causal(samples, rate);
        // Not a refinement of the causal trace. The existing offline path may
        // only reprice frames the causal pass already published, so a frame the
        // causal pass declined to answer is permanently lost to it -- and
        // declining is now the engine's central mechanism. Decoding the whole
        // sequence over the same candidates can revisit voicing as well as
        // pitch, which strictly dominates.
        const auto evidence = collect_unified_evidence(samples, rate, config_);
        return drop_offline_stray_runs(decode_unified_offline_track(evidence, config_));
    }

    auto baseline = analyse_causal(samples, rate);
    if (profile_ != PitchEngineProfile::offline_track || baseline.empty()) {
        return baseline;
    }

    return drop_offline_stray_runs(
        refine_offline_harmonics(baseline, samples, rate, config_, id_)
    );
}
}  // namespace klarivision::core
