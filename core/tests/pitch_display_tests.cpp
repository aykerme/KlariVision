#include "klarivision/core/pitch_display.hpp"

#include <cassert>
#include <cmath>
#include <iostream>

using klarivision::core::PitchFrame;
using klarivision::core::PitchTrack;
using klarivision::core::prepare_display_frames;

int main() {
    const PitchTrack track{
        {0.000, 220.0, true, 0.98},
        {0.010, 440.0, true, 0.98},  // isolated octave spike: must disappear
        {0.020, 220.0, true, 0.98},
        {0.030, 220.0, true, 0.10},  // weak confidence: must disappear
        {0.040, std::nullopt, false, 0.00},
    };

    const auto display = prepare_display_frames(track);
    assert(display.size() == 2);
    assert(std::abs(display[0].frequency_hz - 220.0) < 0.001);
    assert(std::abs(display[1].frequency_hz - 220.0) < 0.001);
    std::cout << "KlariVision Core pitch-display tests passed.\n";
}
