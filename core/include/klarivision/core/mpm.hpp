#pragma once

#include "klarivision/core/pitch_engine_v2.hpp"

#include <span>
#include <vector>

namespace klarivision::core::v2 {

/// McLeod Pitch Method candidate generator. It exposes the useful NSDF peaks
/// instead of collapsing them to one pitch, allowing the V2 path selector to
/// combine MPM with YIN and later spectral evidence.
std::vector<PitchCandidate> mpm_candidates(
    std::span<const float> samples,
    double sample_rate,
    double minimum_frequency_hz = 80.0,
    double maximum_frequency_hz = 1500.0,
    double minimum_clarity = 0.55
);

}  // namespace klarivision::core::v2
