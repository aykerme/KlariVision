#include "klarivision/core/pitch_display.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace klarivision::core {

double cents_from_hz(const double frequency_hz) {
    if (frequency_hz <= 0.0) {
        throw std::invalid_argument("Frequency must be positive.");
    }
    return 1200.0 * std::log2(frequency_hz / 440.0);
}

double hz_from_cents(const double cents) {
    return 440.0 * std::pow(2.0, cents / 1200.0);
}

std::vector<DisplayFrame> prepare_display_frames(
    const PitchTrack& track,
    const DisplayPreparationSettings& settings
) {
    std::vector<DisplayFrame> candidates;
    candidates.reserve(track.size());
    for (const auto& frame : track) {
        if (frame.voiced && frame.frequency_hz.has_value()
            && *frame.frequency_hz > settings.minimum_frequency_hz
            && frame.confidence >= settings.minimum_confidence) {
            candidates.push_back({frame.time_seconds, *frame.frequency_hz});
        }
    }

    std::vector<DisplayFrame> kept;
    kept.reserve(candidates.size());
    for (std::size_t index = 0; index < candidates.size(); ++index) {
        if (index > 0 && index + 1 < candidates.size()) {
            const auto& before = candidates[index - 1];
            const auto& frame = candidates[index];
            const auto& after = candidates[index + 1];
            const bool nearby = after.time_seconds - before.time_seconds
                <= settings.isolated_frame_window_seconds;
            const bool jump = std::abs(cents_from_hz(frame.frequency_hz)
                - cents_from_hz(before.frequency_hz)) > settings.isolated_jump_cents;
            const bool returns = std::abs(cents_from_hz(after.frequency_hz)
                - cents_from_hz(before.frequency_hz)) < settings.return_tolerance_cents;
            if (nearby && jump && returns) {
                continue;
            }
        }
        kept.push_back(candidates[index]);
    }

    std::vector<DisplayFrame> smoothed;
    smoothed.reserve(kept.size());
    for (std::size_t index = 0; index < kept.size(); ++index) {
        const std::size_t first = index == 0 ? 0 : index - 1;
        const std::size_t last = std::min(index + 1, kept.size() - 1);
        const bool has_three_frames = last - first + 1 == 3;
        const bool contiguous = kept[last].time_seconds - kept[first].time_seconds
            <= settings.isolated_frame_window_seconds;
        auto frame = kept[index];
        if (has_three_frames && contiguous) {
            double values[] = {
                cents_from_hz(kept[first].frequency_hz),
                cents_from_hz(kept[index].frequency_hz),
                cents_from_hz(kept[last].frequency_hz),
            };
            std::sort(std::begin(values), std::end(values));
            frame.frequency_hz = hz_from_cents(values[1]);
        }
        smoothed.push_back(frame);
    }
    return smoothed;
}

}  // namespace klarivision::core
