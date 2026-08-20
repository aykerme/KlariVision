#pragma once

#include <optional>
#include <span>
#include <string>
#include <vector>

namespace klarivision::core {

/// Public, independently implemented estimator based on the method Tadao
/// Yamaoka describes for Vocal Pitch Monitor: normalized autocorrelation,
/// higher-period lag refinement and spectrum-based harmonic correction.
///
/// The application and its thresholds are not published, so this is a
/// "VPM-like" implementation rather than a copy of Vocal Pitch Monitor.
struct VPMLikePitch {
    double frequency_hz{};
    double confidence{};
};

/// Causal publication guard for the VPM-like estimator.  The frame estimator
/// intentionally remains stateless for diagnostics; live callers keep this
/// small tracker for the same behaviour across Swift, C++ and tournament
/// traces.  It only delays a downward harmonic jump from an established
/// contour and never smooths ordinary pitch movement.
class VPMLikeTracker {
public:
    explicit VPMLikeTracker(int downward_harmonic_confirmations = 3);

    std::optional<VPMLikePitch> process(
        std::optional<VPMLikePitch> estimate,
        // Ratio of the established contour's direct spectral line to the
        // current lower estimate's line.  It is evidence for retaining an
        // existing contour, never an upward candidate promotion.
        std::optional<double> established_upper_to_estimate_ratio = std::nullopt
    );
    void reset();

private:
    int required_confirmations_;
    std::optional<VPMLikePitch> published_;
    std::optional<VPMLikePitch> pending_;
    int pending_confirmations_{};
};

struct VPMLikeConfig {
    double minimum_frequency_hz{80.0};
    double minimum_rms{0.015};
    // Keep a small estimator-only guard band above the 1500 Hz display range:
    // a true boundary note must be considered before its f/2 period wins.
    double maximum_frequency_hz{1650.0};
    double minimum_periodicity{0.38};
    double minimum_output_confidence{0.80};
    double near_strongest_ratio{0.90};
    double minimum_relative_spectral_amplitude{0.080};
    double minimum_absolute_spectral_amplitude{0.005};
    int maximum_period_multiple{6};
    bool allow_spectral_promotion{false};
};

struct VPMLikeAutocorrelationCandidateDiagnostic {
    int lag_samples{};
    double frequency_hz{};
    double periodicity{};
    bool strongest{};
    bool near_strongest_accepted{};
    bool selected{};
};

struct VPMLikeSpectralCandidateDiagnostic {
    double multiplier{};
    double frequency_hz{};
    double periodicity{};
    double amplitude{};
    double base_amplitude{};
    double relative_amplitude{};
    double left_amplitude{};
    double right_amplitude{};
    bool in_range{};
    bool local_peak{};
    bool absolute_support{};
    bool relative_support{};
    bool selected{};
    std::string decision;
};

/// Exact decision trace for developer diagnostics. Production callers should
/// keep using estimate_vpm_like_pitch so live analysis does not allocate the
/// candidate vectors below.
struct VPMLikeFrameDiagnostic {
    double rms{};
    double strongest_periodicity{};
    double acceptance_periodicity{};
    double autocorrelation_frequency_hz{};
    std::vector<VPMLikeAutocorrelationCandidateDiagnostic> autocorrelation_candidates;
    std::vector<VPMLikeSpectralCandidateDiagnostic> spectral_candidates;
    std::optional<VPMLikePitch> pitch;
    std::string decision;
};

std::optional<VPMLikePitch> estimate_vpm_like_pitch(
    std::span<const double> samples,
    double sample_rate,
    const VPMLikeConfig& config = {}
);

VPMLikeFrameDiagnostic diagnose_vpm_like_pitch(
    std::span<const double> samples,
    double sample_rate,
    const VPMLikeConfig& config = {}
);

}  // namespace klarivision::core
