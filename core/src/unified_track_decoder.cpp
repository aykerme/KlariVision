#include "klarivision/core/unified_track_decoder.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>

namespace klarivision::core {
namespace {

using unified::kHarmonicTargetCents;
using unified::kHarmonicToleranceCents;

constexpr double kNegativeInfinity = -std::numeric_limits<double>::infinity();

// Voicing chain, straight from the pYIN paper's HMM: staying in the current
// voicing state is overwhelmingly more likely than switching. This is what
// stops the decoder from punching one-frame holes into a sustained note, and
// equally from filling one-frame blips into a rest.
constexpr double kVoicingStayLogProbability = -0.010'050'335'853'501'441;   // log(0.99)
constexpr double kVoicingSwitchLogProbability = -4.605'170'185'988'091;     // log(0.01)

// Everything in this decoder is log-probability, so the transition model has
// to be one too. v2's tracker mixes a linear [0,1] emission score with small
// additive penalties around 0.18; carrying those magnitudes over here would
// make a one-frame octave slip cost about 0.3 nats while the slip's own
// emission advantage is easily twice that -- the slip would simply win.
//
// The shape is pYIN's: a triangular window over plausible per-frame motion,
// mixed with a small uniform floor. The floor is what keeps a genuine note
// change reachable at all. A leap pays the floor's cost once and then earns it
// back over the frames that follow, whereas a one-frame excursion pays it
// twice -- on the way out and on the way back -- and never recovers.
constexpr double kLeapFloorProbability = 0.002;

// Subharmonic locks move *down*: an estimator that mistakes a period for its
// double reports an octave or a twelfth below the truth, never above. Downward
// leaps therefore start from a harsher floor. Penalising upward motion equally
// would tax genuine register changes, which on a clarinet are upward twelfths
// and entirely ordinary.
constexpr double kDownwardLeapFloorProbability = 0.000'6;
constexpr double kLargeJumpCents = 850.0;

/// Numerically safe log(exp(a) + exp(b)).
double log_sum_exp(const double a, const double b) {
    if (a == kNegativeInfinity) return b;
    if (b == kNegativeInfinity) return a;
    const auto larger = std::max(a, b);
    const auto smaller = std::min(a, b);
    return larger + std::log1p(std::exp(smaller - larger));
}

double log_sum_exp(const std::span<const double> values) {
    auto total = kNegativeInfinity;
    for (const auto value : values) total = log_sum_exp(total, value);
    return total;
}

/// Log-probability of the pitch moving between two consecutive frames.
///
/// Not normalised over destinations: the candidate set differs frame to frame,
/// so an exact normaliser is not well defined. The omission shifts every
/// destination from a given source by the same constant, which is the usual
/// approximation for a sparse, data-dependent state space.
double pitch_transition_score(
    const double from_hz,
    const double to_hz,
    const double width_cents
) {
    if (!std::isfinite(from_hz) || !std::isfinite(to_hz) || from_hz <= 0.0 || to_hz <= 0.0) {
        return std::log(kDownwardLeapFloorProbability);
    }
    const auto signed_cents = 1200.0 * std::log2(to_hz / from_hz);
    const auto cents = std::abs(signed_cents);
    const auto triangular = std::max(0.0, 1.0 - cents / std::max(1.0, width_cents));
    const auto floor = (signed_cents < 0.0 && cents >= kLargeJumpCents)
        ? kDownwardLeapFloorProbability
        : kLeapFloorProbability;
    return std::log((1.0 - floor) * triangular + floor);
}

/// State layout for one frame: candidate i occupies index i, and the unvoiced
/// state occupies the final index. Keeping silence in the same state space as
/// the pitches is the whole point -- it lets the path decline to answer, and
/// lets that decision be scored against the alternatives instead of being
/// applied afterwards as a filter.
struct FrameStates {
    const UnifiedFrameEvidence* evidence{};
    std::size_t pitch_count{};
    [[nodiscard]] std::size_t size() const { return pitch_count + 1; }
    [[nodiscard]] std::size_t unvoiced_index() const { return pitch_count; }
    [[nodiscard]] bool is_unvoiced(const std::size_t index) const { return index == pitch_count; }
    [[nodiscard]] double frequency(const std::size_t index) const {
        return is_unvoiced(index) ? 0.0 : evidence->candidates[index].candidate.frequency_hz;
    }
    [[nodiscard]] double emission(const std::size_t index) const {
        return is_unvoiced(index) ? evidence->unvoiced_emission
                                  : evidence->candidates[index].emission_score;
    }
};

FrameStates make_states(const UnifiedFrameEvidence& evidence) {
    return FrameStates{&evidence, evidence.candidates.size()};
}

double transition(
    const FrameStates& from,
    const std::size_t from_index,
    const FrameStates& to,
    const std::size_t to_index,
    const double width_cents
) {
    const auto from_unvoiced = from.is_unvoiced(from_index);
    const auto to_unvoiced = to.is_unvoiced(to_index);
    if (from_unvoiced || to_unvoiced) {
        // Crossing the voicing boundary, or staying silent. No pitch distance
        // applies: a note that begins after a rest may begin anywhere, and
        // forcing it to continue the pitch before the rest is exactly the
        // continuity error a rest is supposed to break.
        return (from_unvoiced == to_unvoiced) ? kVoicingStayLogProbability
                                              : kVoicingSwitchLogProbability;
    }
    return kVoicingStayLogProbability + pitch_transition_score(
        from.frequency(from_index), to.frequency(to_index), width_cents
    );
}

/// One forward-backward and one Viterbi pass over a whole span of frames.
///
/// The Viterbi path says which state the best explanation runs through; it says
/// nothing about how much better that explanation is than the runner-up. For
/// the abstention rule that margin is the entire question, so the marginals are
/// computed properly rather than read off the path score. Both passes are
/// O(F * C^2) with C at most a dozen states, so running them together costs far
/// less than the candidate generation that produced the frames.
struct SequenceSolution {
    std::vector<std::vector<double>> posterior;  // per frame, normalised marginals
    std::vector<std::size_t> path;               // per frame, Viterbi state
    double path_score{};
};

SequenceSolution solve_sequence(
    const std::vector<FrameStates>& frames,
    const double width_cents
) {
    const auto count = frames.size();
    std::vector<std::vector<double>> alpha(count);
    std::vector<std::vector<double>> beta(count);
    std::vector<std::vector<double>> viterbi(count);
    std::vector<std::vector<std::size_t>> back(count);

    alpha[0].resize(frames[0].size());
    viterbi[0].resize(frames[0].size());
    for (std::size_t state = 0; state < frames[0].size(); ++state) {
        alpha[0][state] = frames[0].emission(state);
        viterbi[0][state] = alpha[0][state];
    }

    for (std::size_t frame = 1; frame < count; ++frame) {
        const auto width_here = frames[frame].size();
        alpha[frame].assign(width_here, kNegativeInfinity);
        viterbi[frame].assign(width_here, kNegativeInfinity);
        back[frame].assign(width_here, 0);
        for (std::size_t to = 0; to < width_here; ++to) {
            auto summed = kNegativeInfinity;
            auto best = kNegativeInfinity;
            std::size_t best_from = 0;
            for (std::size_t from = 0; from < frames[frame - 1].size(); ++from) {
                const auto step =
                    transition(frames[frame - 1], from, frames[frame], to, width_cents);
                summed = log_sum_exp(summed, alpha[frame - 1][from] + step);
                const auto candidate_score = viterbi[frame - 1][from] + step;
                if (candidate_score > best) {
                    best = candidate_score;
                    best_from = from;
                }
            }
            const auto emission = frames[frame].emission(to);
            alpha[frame][to] = summed + emission;
            viterbi[frame][to] = best + emission;
            back[frame][to] = best_from;
        }
    }

    beta[count - 1].assign(frames[count - 1].size(), 0.0);
    for (auto frame = count - 1; frame > 0; --frame) {
        beta[frame - 1].assign(frames[frame - 1].size(), kNegativeInfinity);
        for (std::size_t from = 0; from < frames[frame - 1].size(); ++from) {
            auto total = kNegativeInfinity;
            for (std::size_t to = 0; to < frames[frame].size(); ++to) {
                total = log_sum_exp(
                    total,
                    transition(frames[frame - 1], from, frames[frame], to, width_cents) +
                        frames[frame].emission(to) + beta[frame][to]
                );
            }
            beta[frame - 1][from] = total;
        }
    }

    SequenceSolution solution{};
    solution.posterior.resize(count);
    for (std::size_t frame = 0; frame < count; ++frame) {
        auto& marginals = solution.posterior[frame];
        marginals.resize(frames[frame].size());
        for (std::size_t state = 0; state < marginals.size(); ++state) {
            marginals[state] = alpha[frame][state] + beta[frame][state];
        }
        const auto normaliser = log_sum_exp(std::span<const double>(marginals));
        if (!std::isfinite(normaliser)) {
            // Degenerate frame: no path explains it at all. A flat posterior is
            // the honest reading, and it makes the abstention rule see maximal
            // contest and stay silent.
            std::fill(marginals.begin(), marginals.end(),
                      1.0 / static_cast<double>(marginals.size()));
            continue;
        }
        for (auto& value : marginals) value = std::exp(value - normaliser);
    }

    solution.path.assign(count, 0);
    const auto& last = viterbi[count - 1];
    auto selected = static_cast<std::size_t>(
        std::distance(last.begin(), std::max_element(last.begin(), last.end()))
    );
    solution.path_score = *std::max_element(last.begin(), last.end());
    solution.path[count - 1] = selected;
    for (auto frame = count - 1; frame > 0; --frame) {
        selected = back[frame][selected];
        solution.path[frame - 1] = selected;
    }
    return solution;
}

UnifiedDecodedFrame describe_frame(
    const FrameStates& states,
    const std::vector<double>& posterior,
    const std::size_t winner,
    const std::size_t frame_index,
    const double path_score
) {
    UnifiedDecodedFrame decoded{};
    decoded.frame_index = frame_index;
    decoded.path_score = path_score;
    decoded.winner_posterior = posterior[winner];
    decoded.voiced_posterior = 1.0 - posterior[states.unvoiced_index()];
    if (states.is_unvoiced(winner)) return decoded;

    decoded.candidate = states.evidence->candidates[winner].candidate;
    const auto winner_hz = decoded.candidate->frequency_hz;
    for (std::size_t state = 0; state < states.pitch_count; ++state) {
        if (state == winner) continue;
        const auto other_hz = states.frequency(state);
        if (other_hz <= 0.0 || winner_hz <= 0.0) continue;
        if (is_harmonic_relationship(1200.0 * std::log2(other_hz / winner_hz))) {
            decoded.harmonic_contest_mass += posterior[state];
        }
    }
    return decoded;
}

std::vector<FrameStates> build_states(const std::span<const UnifiedFrameEvidence> frames) {
    std::vector<FrameStates> states;
    states.reserve(frames.size());
    for (const auto& evidence : frames) states.push_back(make_states(evidence));
    return states;
}

}  // namespace

double UnifiedDecodedFrame::harmonic_dominance() const {
    const auto total = winner_posterior + harmonic_contest_mass;
    if (!(total > 0.0)) return 0.0;
    return winner_posterior / total;
}

UnifiedTrackDecoder::UnifiedTrackDecoder(
    const std::size_t lag_frames,
    const double transition_width_cents
) : lag_frames_(lag_frames),
    transition_width_cents_(std::max(1.0, transition_width_cents)) {}

std::optional<UnifiedDecodedFrame> UnifiedTrackDecoder::push(const UnifiedFrameEvidence& frame) {
    frames_.push_back(BufferedFrame{next_frame_index_++, frame});
    if (frames_.size() <= lag_frames_) return std::nullopt;
    return resolve_front();
}

std::optional<UnifiedDecodedFrame> UnifiedTrackDecoder::finish_next() {
    if (frames_.empty()) return std::nullopt;
    return resolve_front();
}

std::optional<UnifiedDecodedFrame> UnifiedTrackDecoder::resolve_front() {
    if (frames_.empty()) return std::nullopt;

    std::vector<UnifiedFrameEvidence> window;
    window.reserve(frames_.size());
    for (const auto& buffered : frames_) window.push_back(buffered.evidence);

    const auto states = build_states(window);
    const auto solution = solve_sequence(states, transition_width_cents_);
    // Only the oldest frame leaves the window; the rest were decoded purely as
    // look-ahead and will be decoded again, with more evidence, on later calls.
    const auto decoded = describe_frame(
        states[0], solution.posterior[0], solution.path[0],
        frames_.front().index, solution.path_score
    );
    frames_.pop_front();
    return decoded;
}

void UnifiedTrackDecoder::reset() {
    frames_.clear();
    next_frame_index_ = 0;
}

std::vector<UnifiedDecodedFrame> decode_unified_track_globally(
    const std::span<const UnifiedFrameEvidence> frames,
    const double transition_width_cents
) {
    std::vector<UnifiedDecodedFrame> decoded;
    decoded.reserve(frames.size());
    if (frames.empty()) return decoded;

    // Offline the whole sequence is available, so every frame is resolved with
    // the full remainder as look-ahead rather than a fixed window. The existing
    // offline refinement cannot do this: it may only reprice frames the causal
    // pass already published, so a frame the causal pass declined to answer is
    // permanently lost to it. Here, declining is itself a state on the path and
    // can be revisited.
    const auto states = build_states(frames);
    const auto solution = solve_sequence(states, std::max(1.0, transition_width_cents));
    for (std::size_t index = 0; index < frames.size(); ++index) {
        decoded.push_back(describe_frame(
            states[index], solution.posterior[index], solution.path[index],
            index, solution.path_score
        ));
    }
    return decoded;
}

std::optional<double> publishable_frequency(
    const UnifiedDecodedFrame& frame,
    const unified::AbstentionPolicy& policy,
    const double family_margin
) {
    if (!frame.candidate.has_value()) return std::nullopt;
    if (frame.voiced_posterior < policy.voiced_posterior_floor) return std::nullopt;
    if (frame.winner_posterior < policy.winner_posterior_floor) return std::nullopt;
    if (frame.harmonic_dominance() < policy.harmonic_dominance_floor) return std::nullopt;
    if (family_margin < policy.family_margin_floor) return std::nullopt;

    const auto frequency = frame.candidate->frequency_hz;
    // A decoded candidate outside the display range is treated as an abstention
    // rather than clamped. Clamping would report a frequency the estimator
    // never actually believed, which is precisely the failure the guard band
    // above the display range exists to avoid.
    if (frequency < unified::kDisplayMinimumHz || frequency > unified::kDisplayMaximumHz) {
        return std::nullopt;
    }
    return frequency;
}

}  // namespace klarivision::core
