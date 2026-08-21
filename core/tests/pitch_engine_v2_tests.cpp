#include "klarivision/core/pitch_engine_v2.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <iostream>

using klarivision::core::v2::CandidateSource;
using klarivision::core::v2::PitchCandidate;
using klarivision::core::v2::SelectionContext;
using klarivision::core::v2::select_candidate;

int main() {
    const std::array<PitchCandidate, 0> empty{};
    assert(!select_candidate(empty));

    const std::array initial{
        PitchCandidate{220.0, 0.80, 0.40, CandidateSource::yin},
        PitchCandidate{440.0, 0.70, 0.90, CandidateSource::spectral},
    };
    const auto strongest = select_candidate(initial);
    assert(strongest);
    assert(std::abs(strongest->candidate.frequency_hz - 440.0) < 0.001);

    // A nearby candidate wins when the raw evidence is almost equal. This is
    // only a causal V2 starting point; the later fixed-lag tracker will replace
    // the one-frame continuity term without changing the public contract.
    const std::array continuity{
        PitchCandidate{220.0, 0.82, 0.70, CandidateSource::yin},
        PitchCandidate{440.0, 0.88, 0.72, CandidateSource::autocorrelation},
    };
    const auto continued = select_candidate(continuity, SelectionContext{220.0, 700.0});
    assert(continued);
    assert(std::abs(continued->candidate.frequency_hz - 220.0) < 0.001);

    // Invalid candidates never leak into a platform graph.
    const std::array invalid{
        PitchCandidate{-1.0, 1.0, 1.0, CandidateSource::yin},
        PitchCandidate{330.0, 0.75, 0.75, CandidateSource::mpm},
    };
    const auto valid = select_candidate(invalid);
    assert(valid);
    assert(std::abs(valid->candidate.frequency_hz - 330.0) < 0.001);

    std::cout << "KlariVision Core Pitch Engine v2 tests passed.\n";
}
