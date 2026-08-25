#include "klarivision/core/pitch_display.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace klarivision::core {

double cents_from_hz(const double frequency_hz) {
    if (frequency_hz <= 0.0) {
        throw std::invalid_argument("Frequency must be positive.");  // cents are undefined for a non-positive frequency
    }
    return 1200.0 * std::log2(frequency_hz / 440.0);  // 1200 cents per octave, referenced to A4 = 440 Hz
}

double hz_from_cents(const double cents) {
    return 440.0 * std::pow(2.0, cents / 1200.0);  // inverse of cents_from_hz
}

std::vector<DisplayFrame> prepare_display_frames(
    const PitchTrack& track,
    const DisplayPreparationSettings& settings
) {
    // Pass 1: keep only frames the raw track marks as voiced, with a
    // frequency present, above a minimum pitch floor and confidence floor.
    // This drops obvious noise/unvoiced frames before any smoothing runs.
    std::vector<DisplayFrame> candidates;
    candidates.reserve(track.size());
    for (const auto& frame : track) {
        if (frame.voiced && frame.frequency_hz.has_value()
            && *frame.frequency_hz > settings.minimum_frequency_hz
            && frame.confidence >= settings.minimum_confidence) {
            candidates.push_back({frame.time_seconds, *frame.frequency_hz});
        }
    }

    // Pass 2: drop isolated single-frame spikes -- a frame that jumps far
    // from its predecessor (`jump`) but whose *successor* lands back close
    // to that same predecessor (`returns`), all within a short time window
    // (`nearby`). That pattern is the signature of a one-frame outlier
    // rather than a real, sustained pitch change, so the offending middle
    // frame is skipped entirely.
    std::vector<DisplayFrame> kept;
    kept.reserve(candidates.size());
    for (std::size_t index = 0; index < candidates.size(); ++index) {
        if (index > 0 && index + 1 < candidates.size()) {
            const auto& before = candidates[index - 1];  // frame just before the one being tested
            const auto& frame = candidates[index];        // frame under test
            const auto& after = candidates[index + 1];     // frame just after
            const bool nearby = after.time_seconds - before.time_seconds
                <= settings.isolated_frame_window_seconds;  // the three frames span only a short time
            const bool jump = std::abs(cents_from_hz(frame.frequency_hz)
                - cents_from_hz(before.frequency_hz)) > settings.isolated_jump_cents;  // frame jumped far from `before`
            const bool returns = std::abs(cents_from_hz(after.frequency_hz)
                - cents_from_hz(before.frequency_hz)) < settings.return_tolerance_cents;  // ...but `after` is back near `before`
            if (nearby && jump && returns) {
                continue;  // classic single-frame spike: drop it
            }
        }
        kept.push_back(candidates[index]);
    }

    // Pass 3: three-frame median smoothing (identical to the stable Mac
    // viewer's behaviour). For each frame, take the median of itself and its
    // immediate neighbours (in cents, so the median is musically meaningful)
    // -- this removes remaining single-frame noise while preserving genuine
    // sustained pitch movement, which survives across three frames.
    std::vector<DisplayFrame> smoothed;
    smoothed.reserve(kept.size());
    for (std::size_t index = 0; index < kept.size(); ++index) {
        const std::size_t first = index == 0 ? 0 : index - 1;              // left neighbour (or self, at the start of the track)
        const std::size_t last = std::min(index + 1, kept.size() - 1);      // right neighbour (or self, at the end of the track)
        const bool has_three_frames = last - first + 1 == 3;                // only smooth when a full 3-frame window exists
        const bool contiguous = kept[last].time_seconds - kept[first].time_seconds
            <= settings.isolated_frame_window_seconds;                     // the window must not span a gap/silence
        auto frame = kept[index];
        if (has_three_frames && contiguous) {
            double values[] = {
                cents_from_hz(kept[first].frequency_hz),
                cents_from_hz(kept[index].frequency_hz),
                cents_from_hz(kept[last].frequency_hz),
            };
            std::sort(std::begin(values), std::end(values));  // sort the three cent values to find the median
            frame.frequency_hz = hz_from_cents(values[1]);     // middle element after sorting = median
        }
        smoothed.push_back(frame);
    }
    return smoothed;
}

}  // namespace klarivision::core
