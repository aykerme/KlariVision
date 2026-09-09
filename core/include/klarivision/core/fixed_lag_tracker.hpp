#pragma once

#include "klarivision/core/pitch_candidate.hpp"

#include <cstddef>
#include <deque>
#include <optional>
#include <span>
#include <vector>

namespace klarivision::core::v2 {

struct ScoredPitchCandidate {
    PitchCandidate candidate{};
    double emission_score{};
};

/// One resolved source frame. The outer optional returned by push() means the
/// fixed lag has not elapsed yet; candidate == nullopt represents an emitted
/// silence frame after the lag has elapsed.
struct TrackedPitchFrame {
    std::size_t frame_index{};
    std::optional<PitchCandidate> candidate{};
    double score{};
    double path_score{};
};

/// Short fixed-lag Viterbi tracker for the experimental pitch engine.
/// With lag_frames == 5 and a 512-sample hop at 48 kHz, the constant decision
/// latency is about 53 ms. Resolved frames keep their original frame index.
class FixedLagPitchTracker {
public:
    explicit FixedLagPitchTracker(
        std::size_t lag_frames = 5,
        double transition_width_cents = 700.0
    );

    [[nodiscard]] std::optional<TrackedPitchFrame> push(
        std::span<const ScoredPitchCandidate> candidates
    );
    /// Resolve every frame still retained by the fixed-lag window.  The final
    /// few source frames use the real, shorter suffix as look-ahead; this
    /// never manufactures a synthetic silence observation.
    [[nodiscard]] std::optional<TrackedPitchFrame> finish_next();
    [[nodiscard]] bool empty() const noexcept { return frames_.empty(); }
    void reset();

    [[nodiscard]] std::size_t lag_frames() const noexcept { return lag_frames_; }

private:
    struct BufferedFrame {
        std::size_t index{};
        std::vector<ScoredPitchCandidate> candidates{};
    };

    std::size_t lag_frames_{};
    double transition_width_cents_{};
    std::size_t next_frame_index_{};
    std::deque<BufferedFrame> frames_{};

    [[nodiscard]] std::optional<TrackedPitchFrame> resolve_front();
};

}  // namespace klarivision::core::v2
