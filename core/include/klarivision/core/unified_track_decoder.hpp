#pragma once

#include "klarivision/core/fixed_lag_tracker.hpp"
#include "klarivision/core/harmonic_evidence.hpp"
#include "klarivision/core/pitch_engine_v2.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"

#include <cstddef>
#include <deque>
#include <optional>
#include <span>
#include <vector>

namespace klarivision::core {

/// Everything one frame contributes to the path decision, produced identically
/// for the live and the offline profile. The two decoders differ only in how
/// much of the sequence they look at, never in what they are looking at.
struct UnifiedFrameEvidence {
    double time_seconds{};
    double rms{};
    bool signal_eligible{};
    /// Positionally parallel with `evidence`.
    std::vector<v2::ScoredPitchCandidate> candidates{};
    std::vector<HarmonicEvidence> evidence{};
    /// log-domain emission for the explicit unvoiced state.
    double unvoiced_emission{};
    double parity_index{};
};

struct UnifiedDecodedFrame {
    std::size_t frame_index{};
    /// nullopt means the decoder resolved this frame as unvoiced.
    std::optional<v2::PitchCandidate> candidate{};
    /// Posterior of the winning state within this frame, in [0, 1].
    double winner_posterior{};
    /// 1 - P(unvoiced).
    double voiced_posterior{};
    /// Summed posterior of the states standing in an octave or twelfth
    /// relationship to the winner. This is what the abstention rule prices:
    /// when the frame cannot tell f from f/2, publishing either is a coin flip.
    double harmonic_contest_mass{};
    double path_score{};

    /// P(f*) / (P(f*) + harmonic_contest_mass); 1.0 when uncontested.
    [[nodiscard]] double harmonic_dominance() const;
};

/// Fixed-lag Viterbi with an explicit unvoiced state and a per-frame posterior.
///
/// This is deliberately a separate type from FixedLagPitchTracker rather than
/// an extension of it: that tracker carries pitch_engine_v2's measured
/// behaviour and sits on the compile line of several test binaries, so
/// changing it would put a v2 regression into the very baseline the new engine
/// is measured against.
///
/// Transition model, over the v2 shape:
///   - voicing self-transition 0.99, switch 0.01;
///   - an extra cost for large jumps, asymmetric downward, because
///     subharmonic errors move down and genuine register changes are rarer
///     than octave slips in that direction.
class UnifiedTrackDecoder {
public:
    explicit UnifiedTrackDecoder(
        std::size_t lag_frames = unified::kDefaultLagFrames,
        double transition_width_cents = unified::kTransitionWidthCents
    );

    /// nullopt while the lag window is still filling.
    [[nodiscard]] std::optional<UnifiedDecodedFrame> push(const UnifiedFrameEvidence& frame);
    /// Drain the retained window at end of capture, using the real remaining
    /// suffix as look-ahead rather than manufacturing silent observations.
    [[nodiscard]] std::optional<UnifiedDecodedFrame> finish_next();

    [[nodiscard]] bool empty() const noexcept { return frames_.empty(); }
    [[nodiscard]] std::size_t lag_frames() const noexcept { return lag_frames_; }
    void reset();

private:
    struct BufferedFrame {
        std::size_t index{};
        UnifiedFrameEvidence evidence{};
    };

    std::size_t lag_frames_{};
    double transition_width_cents_{};
    std::size_t next_frame_index_{};
    std::deque<BufferedFrame> frames_{};

    [[nodiscard]] std::optional<UnifiedDecodedFrame> resolve_front();
};

/// Whole-sequence Viterbi over the same states, for the offline profile. It
/// can revisit voicing, which the existing offline refinement cannot: that one
/// may only reprice frames the causal pass already published, so it can never
/// recover a frame the causal pass abstained on.
[[nodiscard]] std::vector<UnifiedDecodedFrame> decode_unified_track_globally(
    std::span<const UnifiedFrameEvidence> frames,
    double transition_width_cents = unified::kTransitionWidthCents
);

/// Applies an AbstentionPolicy to a decoded frame. Returns nullopt when the
/// frame must be published as silence.
///
/// This is a publication filter and never edits the path, so it cannot cap
/// recall the way smoothing a single-candidate output does.
[[nodiscard]] std::optional<double> publishable_frequency(
    const UnifiedDecodedFrame& frame,
    const unified::AbstentionPolicy& policy,
    double family_margin
);

}  // namespace klarivision::core
