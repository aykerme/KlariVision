#include "klarivision/core/pitch_engine_v2.hpp"

#include <algorithm>
#include <cmath>

namespace klarivision::core::v2 {
namespace {

double clamp01(const double value) {
    return std::clamp(value, 0.0, 1.0);
}

double candidate_score(const PitchCandidate& candidate, const SelectionContext& context) {
    if (!std::isfinite(candidate.frequency_hz) || candidate.frequency_hz <= 0.0) {
        return -1.0;
    }

    // These weights only establish the replaceable V2 boundary. They are not
    // a final instrument model; later steps will supply measured SWIPE'/MPM
    // evidence and a short fixed-lag path score.
    double score = 0.65 * clamp01(candidate.periodicity) +
        0.35 * clamp01(candidate.harmonic_support);

    if (context.previous_frequency_hz && *context.previous_frequency_hz > 0.0) {
        const auto cents = std::abs(1200.0 * std::log2(
            candidate.frequency_hz / *context.previous_frequency_hz
        ));
        const auto width = std::max(1.0, context.continuity_width_cents);
        score -= 0.25 * std::min(cents / width, 1.0);
    }
    return score;
}

}  // namespace

std::optional<SelectedPitch> select_candidate(
    const std::span<const PitchCandidate> candidates,
    const SelectionContext& context
) {
    std::optional<SelectedPitch> selected;
    for (const auto& candidate : candidates) {
        const auto score = candidate_score(candidate, context);
        if (score < 0.0) {
            continue;
        }
        if (!selected || score > selected->score) {
            selected = SelectedPitch{candidate, score};
        }
    }
    return selected;
}

}  // namespace klarivision::core::v2
