#include "klarivision/core/fixed_lag_tracker.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace klarivision::core::v2 {
namespace {

// Viterbi transition ("path") score between two candidate pitches in
// consecutive frames: how plausible is it that the true pitch moved from
// from_hz to to_hz in a single hop? Larger jumps are penalised more, so the
// dynamic program below prefers a smoothly connected sequence of candidates
// over one that jitters between unrelated frequencies frame to frame.
double transition_score(
    const double from_hz,
    const double to_hz,
    const double width_cents
) {
    if (!std::isfinite(from_hz) || !std::isfinite(to_hz) ||
        from_hz <= 0.0 || to_hz <= 0.0) {
        return -1.0;  // invalid frequencies: heavily discourage this transition
    }
    const auto cents = std::abs(1200.0 * std::log2(to_hz / from_hz));  // pitch distance between the two frequencies, in cents
    auto penalty = 0.18 * std::min(cents / std::max(1.0, width_cents), 1.0);  // linear penalty ramping up to a cap over `width_cents`

    // A one-frame octave or twelfth is a common clarinet harmonic error.
    // The surcharge is deliberately modest: a sustained register change can
    // still win through emission evidence in the following five frames.
    if (cents >= 850.0) {
        penalty += 0.12;  // extra surcharge for a near-octave-or-larger jump
    }
    return -penalty;  // Viterbi accumulates scores additively, so a "cost" becomes a negative score
}

}  // namespace

FixedLagPitchTracker::FixedLagPitchTracker(
    const std::size_t lag_frames,
    const double transition_width_cents
) : lag_frames_(lag_frames),
    transition_width_cents_(std::max(1.0, transition_width_cents)) {}

std::optional<TrackedPitchFrame> FixedLagPitchTracker::push(
    const std::span<const ScoredPitchCandidate> candidates
) {
    frames_.push_back(BufferedFrame{
        next_frame_index_++,                                                    // this frame's sequential index
        std::vector<ScoredPitchCandidate>(candidates.begin(), candidates.end()), // its scored pitch candidates
    });
    if (frames_.size() <= lag_frames_) {
        // Not enough look-ahead buffered yet to resolve the oldest frame.
        return std::nullopt;
    }

    return resolve_front();  // buffer is full: pop and decide the oldest frame now
}

std::optional<TrackedPitchFrame> FixedLagPitchTracker::finish_next() {
    if (frames_.empty()) return std::nullopt;
    return resolve_front();  // drain remaining buffered frames at end-of-stream, using whatever look-ahead is left
}

std::optional<TrackedPitchFrame> FixedLagPitchTracker::resolve_front() {
    if (frames_.empty()) return std::nullopt;

    const auto oldest_index = frames_.front().index;   // frame index being decided this call
    if (frames_.front().candidates.empty()) {
        // No pitch candidates at all in the oldest frame: it is silence,
        // and silence can't be part of a Viterbi path, so emit it directly.
        frames_.pop_front();
        return TrackedPitchFrame{oldest_index, std::nullopt, 0.0, 0.0};
    }

    // A silence breaks musical continuity. Only the contiguous voiced prefix
    // beginning at the frame being resolved may influence its decision.
    std::size_t voiced_count = 0;
    while (voiced_count < frames_.size() && !frames_[voiced_count].candidates.empty()) {
        ++voiced_count;  // count consecutive voiced (non-silent) frames starting at the front
    }

    // Standard Viterbi dynamic program over the voiced look-ahead window:
    // `previous[i]` holds the best cumulative path score of any sequence of
    // candidate choices ending at candidate i of the current frame.
    std::vector<double> previous;
    previous.reserve(frames_.front().candidates.size());
    for (const auto& candidate : frames_.front().candidates) {
        previous.push_back(candidate.emission_score);  // base case: frame 0's score is just its own emission evidence
    }
    std::vector<std::vector<std::size_t>> back_pointers;  // per later frame, which prior-frame candidate each path came from

    for (std::size_t frame = 1; frame < voiced_count; ++frame) {          // advance the DP one frame at a time
        const auto& current_candidates = frames_[frame].candidates;      // candidates being scored this step
        const auto& prior_candidates = frames_[frame - 1].candidates;    // candidates the DP is transitioning from
        std::vector<double> current(current_candidates.size(), -std::numeric_limits<double>::infinity());  // best score reaching each current candidate
        std::vector<std::size_t> back(current_candidates.size(), 0);      // best prior-candidate index for each current candidate
        for (std::size_t current_index = 0; current_index < current_candidates.size(); ++current_index) {
            for (std::size_t prior_index = 0; prior_index < prior_candidates.size(); ++prior_index) {
                const auto path_score = previous[prior_index] + transition_score(
                    prior_candidates[prior_index].candidate.frequency_hz,
                    current_candidates[current_index].candidate.frequency_hz,
                    transition_width_cents_
                );  // best-so-far score of reaching `prior_index`, plus the cost of hopping to `current_index`
                if (path_score > current[current_index]) {
                    current[current_index] = path_score;   // found a better path into this candidate...
                    back[current_index] = prior_index;      // ...remember which prior candidate it came from
                }
            }
            current[current_index] += current_candidates[current_index].emission_score;  // add this frame's own evidence for the candidate
        }
        previous = std::move(current);              // this frame's scores become "previous" for the next iteration
        back_pointers.push_back(std::move(back));    // keep the back-pointers so the best path can be replayed afterwards
    }

    // Pick the overall best-scoring path ending anywhere in the last voiced
    // frame of the look-ahead window, then walk the back-pointers backwards
    // to recover which candidate it selected in the *first* (oldest) frame
    // -- that is the only frame actually being resolved by this call.
    auto selected_index = static_cast<std::size_t>(std::distance(
        previous.begin(), std::max_element(previous.begin(), previous.end())
    ));  // index, in the last frame, of the best final path
    for (auto frame = back_pointers.size(); frame > 0; --frame) {
        selected_index = back_pointers[frame - 1][selected_index];  // step backwards through the chosen path
    }

    const auto selected = frames_.front().candidates[selected_index];  // the winning candidate for the oldest (front) frame
    const double path_score = *std::max_element(previous.begin(), previous.end());  // score of the whole winning path, for diagnostics
    frames_.pop_front();  // the oldest frame is now resolved and can leave the buffer
    return TrackedPitchFrame{
        oldest_index,
        selected.candidate,
        std::clamp(selected.emission_score, 0.0, 1.0),  // this frame's own confidence, clamped to a valid [0, 1] score
        path_score,
    };
}

void FixedLagPitchTracker::reset() {
    frames_.clear();          // drop any buffered, not-yet-resolved frames
    next_frame_index_ = 0;    // restart frame numbering from zero
}

}  // namespace klarivision::core::v2
