#include "klarivision/core/fixed_lag_tracker.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <optional>
#include <vector>

using klarivision::core::v2::CandidateSource;
using klarivision::core::v2::FixedLagPitchTracker;
using klarivision::core::v2::PitchCandidate;
using klarivision::core::v2::ScoredPitchCandidate;

namespace {

ScoredPitchCandidate candidate(const double frequency, const double score) {
    return {
        PitchCandidate{frequency, score, score, CandidateSource::yin},
        score,
    };
}

}  // namespace

int main() {
    FixedLagPitchTracker tracker(5);
    std::vector<double> resolved;

    // The locally stronger 2f candidate appears for one frame. Five future
    // frames reveal that 220 Hz is the coherent path.
    for (int frame = 0; frame < 12; ++frame) {
        const auto distractor_score = frame == 3 ? 0.94 : 0.30;
        const auto fundamental_score = frame == 3 ? 0.72 : 0.86;
        const std::array candidates{
            candidate(220.0, fundamental_score),
            candidate(440.0, distractor_score),
        };
        const auto output = tracker.push(candidates);
        if (frame < 5) {
            assert(!output);
        } else {
            assert(output && output->candidate);
            resolved.push_back(output->candidate->frequency_hz);
            assert(output->frame_index == static_cast<std::size_t>(frame - 5));
        }
    }
    for (const auto frequency : resolved) {
        assert(std::abs(frequency - 220.0) < 0.001);
    }

    // A real, sustained note change must not be flattened by continuity.
    tracker.reset();
    resolved.clear();
    for (int frame = 0; frame < 16; ++frame) {
        const bool changed = frame >= 6;
        const std::array candidates{
            candidate(220.0, changed ? 0.30 : 0.90),
            candidate(293.6648, changed ? 0.90 : 0.30),
        };
        if (const auto output = tracker.push(candidates); output && output->candidate) {
            resolved.push_back(output->candidate->frequency_hz);
        }
    }
    assert(resolved.size() == 11);
    assert(std::abs(resolved.front() - 220.0) < 0.001);
    assert(std::abs(resolved.back() - 293.6648) < 0.001);

    // Silence is emitted as silence and prevents two voiced regions from
    // borrowing continuity from one another.
    tracker.reset();
    const std::array voiced{candidate(220.0, 0.90)};
    const std::array<ScoredPitchCandidate, 0> silence{};
    for (int frame = 0; frame < 5; ++frame) {
        assert(!tracker.push(voiced));
    }
    auto first = tracker.push(silence);
    assert(first && first->candidate);
    for (int frame = 0; frame < 5; ++frame) {
        const auto delayed = tracker.push(silence);
        assert(delayed);
    }
    const auto silent_output = tracker.push(voiced);
    assert(silent_output && !silent_output->candidate);

    std::cout << "KlariVision fixed-lag tracker tests passed.\n";
}
