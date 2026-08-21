#pragma once

#include <optional>
#include <vector>

namespace klarivision::core {

/// One time-aligned result produced by any pitch extractor.
/// A non-voiced frame has no frequency value.
struct PitchFrame {
    double time_seconds{};
    std::optional<double> frequency_hz{};
    bool voiced{};
    double confidence{};
};

using PitchTrack = std::vector<PitchFrame>;

/// The stable, platform-neutral display contract shared with the Python viewer.
struct DisplayFrame {
    double time_seconds{};
    double frequency_hz{};
};

}  // namespace klarivision::core
