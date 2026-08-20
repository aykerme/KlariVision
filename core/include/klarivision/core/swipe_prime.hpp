#pragma once

#include <span>
#include <vector>

namespace klarivision::core::v2 {

/// Scores pitch candidates with a lightweight SWIPE'-inspired spectral
/// kernel. The first and prime harmonics receive positive support while all
/// integer harmonic locations contribute to the normalization term. This
/// makes subharmonic candidates explainably weaker without performing a full
/// dense SWIPE' pitch search.
std::vector<double> swipe_prime_harmonic_supports(
    std::span<const float> samples,
    double sample_rate,
    std::span<const double> candidate_frequencies_hz,
    double maximum_analysis_frequency_hz = 5'000.0
);

}  // namespace klarivision::core::v2
