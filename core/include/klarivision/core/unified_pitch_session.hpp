#pragma once

#include "klarivision/core/analysis_engine.hpp"
#include "klarivision/core/harmonic_evidence.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"
#include "klarivision/core/unified_track_decoder.hpp"

#include <cstddef>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace klarivision::core {

/// Why one frame was published or withheld. Test and trace only; deliberately
/// separate from the offline_track_v1 JSON contract.
struct UnifiedFrameDiagnostic {
    double input_time_seconds{};
    double rms{};
    bool signal_eligible{};
    std::size_t candidate_count{};
    double winner_posterior{};
    double voiced_posterior{};
    double harmonic_dominance{};
    double harmonic_evidence_ratio{};
    double family_margin{};
    double parity_index{};
    std::string publication_reason{};
};

/// Builds one frame's worth of evidence: candidates from the ladder, spectral
/// support for each, and the harmonic family members that compete with them.
///
/// Profile-independent on purpose. The live decoder and the offline decoder
/// consume exactly the same records and differ only in how much of the
/// sequence they are allowed to look at -- never in what they are looking at.
///
/// `lookahead_samples` is that difference made concrete: samples
/// immediately after `history`'s newest one, used only by the series-
/// coherence veto (see kSeriesCoherenceLookaheadSamples) to tell a
/// common-subharmonic ghost from a real low-register fundamental. Live
/// callers have no future samples yet and pass the default empty span,
/// which leaves every candidate's `series_incoherent` false -- identical to
/// this function's behaviour before that veto existed. Only
/// `collect_unified_evidence`, which already holds the whole track, passes
/// a real one.
[[nodiscard]] UnifiedFrameEvidence unified_frame_evidence(
    std::span<const float> history,
    double sample_rate,
    double source_time_seconds,
    const PitchEngineConfig& config,
    const ParityEstimate& parity,
    std::span<const float> lookahead_samples = {}
);

/// Causal, frame-at-a-time driver for the live path.
class UnifiedPitchSession {
public:
    explicit UnifiedPitchSession(PitchEngineConfig config = {});
    ~UnifiedPitchSession();
    UnifiedPitchSession(UnifiedPitchSession&&) noexcept;
    UnifiedPitchSession& operator=(UnifiedPitchSession&&) noexcept;
    UnifiedPitchSession(const UnifiedPitchSession&) = delete;
    UnifiedPitchSession& operator=(const UnifiedPitchSession&) = delete;

    [[nodiscard]] std::vector<EngineFrame> process_frame(
        std::span<const float> samples,
        double sample_rate,
        double source_time_seconds
    );
    /// Drain the decoder's retained window without inventing further input.
    [[nodiscard]] std::vector<EngineFrame> finish();
    [[nodiscard]] const UnifiedFrameDiagnostic& last_diagnostic() const;
    void reset();
    void set_minimum_rms(double minimum_rms);
    void set_lag_frames(std::size_t lag_frames);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/// Offline: collect every frame's evidence first, then decode the whole
/// sequence at once. Kept as two steps so the evidence can be inspected, and
/// so an arbitration layer can be inserted between them later.
[[nodiscard]] std::vector<UnifiedFrameEvidence> collect_unified_evidence(
    std::span<const float> mono_samples,
    double sample_rate,
    const PitchEngineConfig& config,
    PitchProgressCallback on_progress = {}
);

[[nodiscard]] std::vector<EngineFrame> decode_unified_offline_track(
    std::span<const UnifiedFrameEvidence> evidence,
    const PitchEngineConfig& config,
    PitchProgressCallback on_progress = {}
);

}  // namespace klarivision::core
