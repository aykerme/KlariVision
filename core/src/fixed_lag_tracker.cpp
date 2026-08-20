#include "klarivision/core/fixed_lag_tracker.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace klarivision::core::v2 {
namespace {

double transition_score(
    const double from_hz,
    const double to_hz,
    const double width_cents
) {
    if (!std::isfinite(from_hz) || !std::isfinite(to_hz) ||
        from_hz <= 0.0 || to_hz <= 0.0) {
        return -1.0;
    }
    const auto cents = std::abs(1200.0 * std::log2(to_hz / from_hz));
    auto penalty = 0.18 * std::min(cents / std::max(1.0, width_cents), 1.0);

    // A one-frame octave or twelfth is a common clarinet harmonic error.
    // The surcharge is deliberately modest: a sustained register change can
    // still win through emission evidence in the following five frames.
    if (cents >= 850.0) {
        penalty += 0.12;
    }
    return -penalty;
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
        next_frame_index_++,
        std::vector<ScoredPitchCandidate>(candidates.begin(), candidates.end()),
    });
    if (frames_.size() <= lag_frames_) {
        return std::nullopt;
    }

    return resolve_front();
}

std::optional<TrackedPitchFrame> FixedLagPitchTracker::finish_next() {
    if (frames_.empty()) return std::nullopt;
    return resolve_front();
}

std::optional<TrackedPitchFrame> FixedLagPitchTracker::resolve_front() {
    if (frames_.empty()) return std::nullopt;

    const auto oldest_index = frames_.front().index;
    if (frames_.front().candidates.empty()) {
        frames_.pop_front();
        return TrackedPitchFrame{oldest_index, std::nullopt, 0.0, 0.0};
    }

    // A silence breaks musical continuity. Only the contiguous voiced prefix
    // beginning at the frame being resolved may influence its decision.
    std::size_t voiced_count = 0;
    while (voiced_count < frames_.size() && !frames_[voiced_count].candidates.empty()) {
        ++voiced_count;
    }

    std::vector<double> previous;
    previous.reserve(frames_.front().candidates.size());
    for (const auto& candidate : frames_.front().candidates) {
        previous.push_back(candidate.emission_score);
    }
    std::vector<std::vector<std::size_t>> back_pointers;

    for (std::size_t frame = 1; frame < voiced_count; ++frame) {
        const auto& current_candidates = frames_[frame].candidates;
        const auto& prior_candidates = frames_[frame - 1].candidates;
        std::vector<double> current(current_candidates.size(), -std::numeric_limits<double>::infinity());
        std::vector<std::size_t> back(current_candidates.size(), 0);
        for (std::size_t current_index = 0; current_index < current_candidates.size(); ++current_index) {
            for (std::size_t prior_index = 0; prior_index < prior_candidates.size(); ++prior_index) {
                const auto path_score = previous[prior_index] + transition_score(
                    prior_candidates[prior_index].candidate.frequency_hz,
                    current_candidates[current_index].candidate.frequency_hz,
                    transition_width_cents_
                );
                if (path_score > current[current_index]) {
                    current[current_index] = path_score;
                    back[current_index] = prior_index;
                }
            }
            current[current_index] += current_candidates[current_index].emission_score;
        }
        previous = std::move(current);
        back_pointers.push_back(std::move(back));
    }

    auto selected_index = static_cast<std::size_t>(std::distance(
        previous.begin(), std::max_element(previous.begin(), previous.end())
    ));
    for (auto frame = back_pointers.size(); frame > 0; --frame) {
        selected_index = back_pointers[frame - 1][selected_index];
    }

    const auto selected = frames_.front().candidates[selected_index];
    const double path_score = *std::max_element(previous.begin(), previous.end());
    frames_.pop_front();
    return TrackedPitchFrame{
        oldest_index,
        selected.candidate,
        std::clamp(selected.emission_score, 0.0, 1.0),
        path_score,
    };
}

void FixedLagPitchTracker::reset() {
    frames_.clear();
    next_frame_index_ = 0;
}

}  // namespace klarivision::core::v2
