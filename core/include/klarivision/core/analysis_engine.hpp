#pragma once

#include <cstddef>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace klarivision::core {

// Appended, never reordered: these values are the persisted C ABI enum, so
// 0-3 keep their meaning even after the engines behind them are removed.
//
// D-039 removed the four engines that used to occupy 0-3. Their slots stay
// reserved and are never reused or renumbered -- a stored selection or an
// older caller that still names one must be recognised as "an engine that
// existed once", not silently resolved to whatever engine now sits at that
// number. The names carry the `_removed` suffix so any code still trying to
// run one fails to compile instead of quietly changing meaning.
enum class PitchEngineId {
    yin_v1_removed = 0,
    pitch_engine_v2_removed = 1,
    vpm_like_removed = 2,
    hapt_v1_removed = 3,
    unified_v1 = 4,
};

/// True for the one engine this build can actually run. Every other value is
/// a reserved historical slot (see PitchEngineId).
[[nodiscard]] constexpr bool is_supported(const PitchEngineId id) {
    return id == PitchEngineId::unified_v1;
}
enum class PitchEngineProfile { realtime, offline_track };

struct PitchEngineConfig {
    // Lowest pitch the production session may hypothesise.  This is not a
    // display preference: it caps the autocorrelation lag search
    // (`rate / minimum_frequency_hz`), and an over-wide lag range is what lets
    // ACF lock onto a multiple of the true period and report a subharmonic.
    //
    // 80 Hz was far below anything the instrument can produce.  Measured on the
    // Şükrü Tunar verdict set, every downward octave error the listener marked
    // landed between 83 and 160 Hz, and no frame the engines agreed on fell
    // below 146 Hz.  Raising the floor to 120 Hz halved VPM-like's octave
    // errors (18 -> 9) with no engine getting worse.  That measurement was
    // made while four engines still shared this floor; the unified session
    // widens to its own 65 Hz estimator floor internally, so lowering this
    // default would move the baseline the unified engine was measured against.
    //
    // 120 Hz is chosen to clear the Turkish G clarinet ("sol klarnet"), whose
    // lowest sounding note is about 123.5 Hz -- a tighter floor would gain a
    // little more accuracy here but would clip real low notes on that
    // instrument.
    double minimum_frequency_hz{120.0};
    double maximum_frequency_hz{1500.0};
    double minimum_rms{0.015};
    std::size_t window_size{1536};
    std::size_t hop_size{512};
};

struct EngineFrame {
    double time_seconds{};
    std::optional<double> frequency_hz{};
    double confidence{};
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
