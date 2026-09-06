#pragma once

#include "klarivision/core/frame_spectrum.hpp"

#include <span>
#include <vector>

namespace klarivision::core::v2 {

/// Scores pitch candidates with a lightweight SWIPE'-inspired spectral
/// kernel. The first and prime harmonics receive positive support while all
/// integer harmonic locations contribute to the normalization term. This
/// makes subharmonic candidates explainably weaker without performing a full
/// dense SWIPE' pitch search.
///
/// Takes an already-computed FrameSpectrum rather than raw samples: this file
/// used to carry its own private copy of the window/FFT/interpolation code
/// (see the note that used to sit at the top of frame_spectrum.cpp), which
/// meant a second transform of the same history every frame. The kernel below
/// is unchanged; only where the amplitudes come from moved.
///
/// The caller picks the band. SWIPE' compares a candidate against its own
/// harmonics, so the window has to be long enough to resolve the *candidate*,
/// not its partials -- pass the band that would be chosen for the lowest
/// frequency being scored.
[[nodiscard]] std::vector<double> swipe_prime_harmonic_supports(
    const FrameSpectrum& spectrum,
    std::span<const double> candidate_frequencies_hz,
    double maximum_analysis_frequency_hz = 5'000.0
);

}  // namespace klarivision::core::v2
