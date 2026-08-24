#pragma once

#include <cstddef>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace klarivision::core {

enum class PitchEngineId { yin_v1, pitch_engine_v2, vpm_like, hapt_v1 };
enum class PitchEngineProfile { realtime, offline_track };

struct PitchEngineConfig {
    double minimum_frequency_hz{80.0};
    double maximum_frequency_hz{1500.0};
    double minimum_rms{0.015};
    std::size_t window_size{1536};
    std::size_t hop_size{512};
    bool enable_vpm_diagnostics{false};
};

struct EngineFrame {
    double time_seconds{};
    std::optional<double> frequency_hz{};
    double confidence{};
};

/// Test/CLI-only trace of the VPM-like publication state machine.  This is
/// deliberately separate from the offline_track_v1 JSON contract.
struct VPMSessionDiagnostic {
    double input_time_seconds{};
    double rms{};
    double recent_rms_peak{};
    double rms_to_peak_ratio{};
    double strongest_periodicity{};
    std::optional<double> normal_estimate_hz;
    std::optional<double> weak_estimate_hz;
    std::optional<double> last_strong_contour_hz;
    double direct_fundamental_support{};
    double recent_direct_support_peak{};
    std::optional<double> established_upper_to_estimate_ratio;
    bool signal_eligible{};
    bool release_suspected{};
    bool harmonic_veto{};
    std::size_t pending_gap_frames{};
    std::size_t bridged_frames{};
    std::string publication_reason;
};

/// Canonical frame-at-a-time production boundary shared by microphone and
/// file analysis. It owns every causal publication decision for the selected
/// engine; offline-only look-ahead is deliberately applied after this trace.
class ProductionPitchSession {
public:
    ProductionPitchSession(PitchEngineId id, PitchEngineConfig config = {});
    ~ProductionPitchSession();
    ProductionPitchSession(ProductionPitchSession&&) noexcept;
    ProductionPitchSession& operator=(ProductionPitchSession&&) noexcept;
    ProductionPitchSession(const ProductionPitchSession&) = delete;
    ProductionPitchSession& operator=(const ProductionPitchSession&) = delete;

    [[nodiscard]] std::vector<EngineFrame> process_frame(
        std::span<const float> samples,
        double sample_rate,
        double source_time_seconds
    );
    /// Complete a capture without inventing more input frames.  It is
    /// idempotent; reset() is required before accepting more input.
    [[nodiscard]] std::vector<EngineFrame> finish();
    [[nodiscard]] const VPMSessionDiagnostic& last_vpm_diagnostic() const;
    void reset();
    void set_minimum_rms(double minimum_rms);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/// Portable, allocation-contained analysis boundary. Realtime callers feed
/// chunks then read available frames; offline callers use analyse() to obtain
/// a whole-track, future-aware path. No file, UI or platform APIs live here.
class PitchEngine {
public:
    PitchEngine(PitchEngineId id, PitchEngineProfile profile, PitchEngineConfig config = {});
    void reset();
    void push(std::span<const float> mono_samples, double sample_rate);
    [[nodiscard]] std::vector<EngineFrame> finish();
    [[nodiscard]] std::vector<EngineFrame> analyse(
        std::span<const float> mono_samples,
        double sample_rate
    );
    /// Exact shared live trace before any file-only refinement or tail flush.
    [[nodiscard]] std::vector<EngineFrame> analyse_causal(
        std::span<const float> mono_samples,
        double sample_rate
    );

private:
    PitchEngineId id_;
    PitchEngineProfile profile_;
    PitchEngineConfig config_;
    std::vector<float> buffered_samples_;
    double sample_rate_{};
};

}  // namespace klarivision::core
