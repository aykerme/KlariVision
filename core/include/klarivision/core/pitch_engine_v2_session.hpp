#pragma once

#include "klarivision/core/fixed_lag_tracker.hpp"

#include <cstddef>
#include <deque>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace klarivision::core::v2 {

struct PublishedPitchFrame {
    double time_seconds{};
    double frequency_hz{};
    double confidence{};
};

/// Opt-in, per-input-frame evidence for the V2 diagnosis CLI.  Production
/// callers do not need to read or serialize this object.
struct FrameDiagnostic {
    double input_time_seconds{};
    double rms{};
    bool input_signal_eligible{};
    bool input_release_active{};
    std::vector<ScoredPitchCandidate> candidates{};
    bool resolved{};
    double resolved_time_seconds{};
    bool resolved_signal_eligible{};
    bool resolved_release_active{};
    std::optional<PitchCandidate> selected_candidate{};
    double selected_emission_score{};
    double selected_path_score{};
    std::string publication_reason{};
    std::size_t bridged_frames{};
    bool finalized{};
};

/// Canonical stateful V2 production engine. Each call consumes one complete
/// analysis window and may publish zero or more source-timestamped frames.
class PitchEngineV2Session {
public:
    explicit PitchEngineV2Session(
        double minimum_rms = 0.015,
        std::size_t fixed_lag_frames = 5
    );

    [[nodiscard]] std::vector<PublishedPitchFrame> process_frame(
        std::span<const float> samples,
        double sample_rate,
        double source_time_seconds
    );
    /// Explicitly drain the fixed-lag suffix.  Once finished, the session is
    /// terminal until reset(), matching a live capture that has stopped.
    [[nodiscard]] std::vector<PublishedPitchFrame> finish();
    [[nodiscard]] const FrameDiagnostic& last_diagnostic() const noexcept {
        return last_diagnostic_;
    }
    void reset();
    void set_minimum_rms(double minimum_rms);

private:
    struct PendingPitch {
        double frequency{};
        double confidence{};
        int confirmations{};
    };

    [[nodiscard]] std::optional<PublishedPitchFrame> harmonic_filter(
        const PublishedPitchFrame& frame
    );
    [[nodiscard]] std::vector<PublishedPitchFrame> bridge_gap(
        const std::optional<PublishedPitchFrame>& frame,
        double source_time_seconds,
        bool source_signal_eligible
    );
    [[nodiscard]] std::vector<PublishedPitchFrame> bridge_startup(
        const std::optional<PublishedPitchFrame>& publication,
        const std::optional<PublishedPitchFrame>& tentative
    );

    double minimum_rms_{};
    double recent_rms_peak_{};
    double release_rms_peak_{};
    double previous_rms_{};
    int release_falls_{};
    bool release_active_{};
    FixedLagPitchTracker tracker_;
    std::deque<double> source_times_;
    std::deque<bool> source_signal_eligible_;
    std::deque<bool> source_release_active_;
    bool finished_{};
    std::optional<double> published_frequency_;
    std::optional<PendingPitch> pending_harmonic_;
    std::optional<PublishedPitchFrame> last_published_;
    std::vector<PublishedPitchFrame> pending_gap_;
    std::vector<PublishedPitchFrame> pending_startup_;
    bool has_published_{};
    FrameDiagnostic last_diagnostic_{};
};

}  // namespace klarivision::core::v2
