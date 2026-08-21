#pragma once

#include "klarivision/core/pitch_track.hpp"

#include <vector>

namespace klarivision::core {

struct DisplayPreparationSettings {
    double minimum_frequency_hz{112.0};
    double minimum_confidence{0.20};
    double isolated_frame_window_seconds{0.025};
    double isolated_jump_cents{110.0};
    double return_tolerance_cents{35.0};
};

/// Converts Hz to cents relative to A4 = 440 Hz.
double cents_from_hz(double frequency_hz);

/// Converts cents relative to A4 = 440 Hz back to Hz.
double hz_from_cents(double cents);

/// Removes only clearly unreliable single-frame candidates, then applies the
/// same three-frame median smoothing currently used by the stable Mac viewer.
/// The input PitchTrack remains untouched.
std::vector<DisplayFrame> prepare_display_frames(
    const PitchTrack& track,
    const DisplayPreparationSettings& settings = {}
);

}  // namespace klarivision::core
