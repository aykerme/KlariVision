#include "klarivision/core/pitch_engine_v2.hpp"

#include <algorithm>
#include <cmath>

namespace klarivision::core::v2 {
namespace {

double clamp01(const double value) {
    return std::clamp(value, 0.0, 1.0);  // keep a score inside the valid confidence range
}

// Combines a single candidate's own evidence (periodicity, harmonic support)
// with continuity against the previously selected pitch into one scalar
// score, so select_candidate below can just pick the maximum.
double candidate_score(const PitchCandidate& candidate, const SelectionContext& context) {
    if (!std::isfinite(candidate.frequency_hz) || candidate.frequency_hz <= 0.0) {
        return -1.0;  // sentinel: never selectable
    }

    // These weights only establish the replaceable V2 boundary. They are not
    // a final instrument model; later steps will supply measured SWIPE'/MPM
    // evidence and a short fixed-lag path score.
    double score = 0.65 * clamp01(candidate.periodicity) +       // how strongly the candidate's own period repeats
        0.35 * clamp01(candidate.harmonic_support);               // how well its harmonics are corroborated spectrally

    if (context.previous_frequency_hz && *context.previous_frequency_hz > 0.0) {
        const auto cents = std::abs(1200.0 * std::log2(
            candidate.frequency_hz / *context.previous_frequency_hz
        ));  // pitch distance from the previously selected frequency, in cents
        const auto width = std::max(1.0, context.continuity_width_cents);  // how many cents of jump is tolerated before full penalty
        score -= 0.25 * std::min(cents / width, 1.0);  // penalise large jumps from the previous frame, capped at a fixed maximum
    }
    return score;
}

}  // namespace

std::optional<SelectedPitch> select_candidate(
    const std::span<const PitchCandidate> candidates,
    const SelectionContext& context
) {
    std::optional<SelectedPitch> selected;  // best candidate found so far, if any
    for (const auto& candidate : candidates) {
        const auto score = candidate_score(candidate, context);
        if (score < 0.0) {
            continue;  // invalid candidate, skip it
        }
        if (!selected || score > selected->score) {
            selected = SelectedPitch{candidate, score};  // new best candidate
        }
    }
    return selected;
}

}  // namespace klarivision::core::v2
