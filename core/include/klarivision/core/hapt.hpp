#pragma once

#include <optional>
#include <span>
#include <string>
#include <vector>

namespace klarivision::core {

/// Fourth, independently designed pitch engine: Harmonic-Adaptive Phase-
/// locked Tracker ("Harmonik-Faz (HAPT)" in the product UI, id `hapt_v1`).
/// A peer of yin_v1, pitch_engine_v2 and vpm_like -- not a replacement or a
/// recommendation.
///
/// Two ideas not present in the other three engines (see
/// docs/HAPTPitchEngine.md for the full derivation, citations and known
/// limits):
///
///  1. A resolution-aware inter-harmonic veto. Each NSDF peak hypothesis is
///     scored against half- and third-period evidence (spectral when the
///     window can resolve it, time-domain NSDF ratios otherwise) while even
///     harmonics are left completely unconstrained -- the rule that is
///     actually correct for a cylindrical, reed-driven bore that overblows
///     at the twelfth (3x) rather than the octave (2x).
///  2. A phase-locked instantaneous-frequency refinement computed from two
///     half-overlapped sub-windows of the *same* analysis frame, giving
///     sub-cent accuracy with no inter-frame state.
///
/// The frame estimator is deliberately stateless (mirrors
/// estimate_vpm_like_pitch); HAPTTracker holds the small amount of
/// cross-frame state needed for a downward harmonic-jump confirmation delay.
struct HAPTConfig {
    double minimum_frequency_hz{80.0};
    double maximum_frequency_hz{1500.0};
    double minimum_rms{0.015};

    // Stage: inter-harmonic veto (odd-harmonic occupancy + half/third grid).
    int harmonics_considered{5};
    double odd_harmonic_relative_threshold{0.10};

    // Stage: phase-locked instantaneous-frequency refinement.
    double if_lock_periodicity_threshold{0.75};
    double if_lock_max_cents_correction{40.0};
    double if_lock_max_amplitude_ratio_db{6.0};

    // Stage: onset/decay recovery and two-threshold hysteresis. A fresh or
    // distant contour needs `onset_periodicity_threshold`; an estimate
    // within `sustain_max_cents_from_contour` of `previous_frequency_hz`
    // only needs `sustain_periodicity_threshold`.
    double onset_periodicity_threshold{0.55};
    double sustain_periodicity_threshold{0.32};
    double sustain_max_cents_from_contour{180.0};

    // Stage (session use, via HAPTTracker): downward harmonic-jump guard.
    double downward_harmonic_jump_ratio_cents_tolerance{30.0};
    int downward_harmonic_confirmations{2};

    // Stage (session use, via HAPTTracker): RMS release detector. A note
    // release falls much faster than ordinary musical phrasing, so two
    // consecutive sharp falls arm it; a reverberant room tail instead decays
    // gently but still crosses well below its own recent peak, so a direct
    // ratio-to-peak arms it too. Held until the envelope recovers back above
    // `release_recovery_ratio` of that peak. This exists because the
    // sustain-level continuation threshold above is deliberately permissive
    // (by design, to avoid the missing-voiced-frame problem the other three
    // engines have) and a decaying tail can otherwise still clear it.
    double release_fall_ratio{0.80};
    double release_decayed_ratio{0.35};
    double release_recovery_ratio{0.40};
};

struct HAPTPitch {
    double frequency_hz{};
    double confidence{};
};

/// One NSDF-peak hypothesis and the evidence used to score or veto it.
/// Diagnostic-only; production callers use estimate_hapt_pitch.
struct HAPTHypothesisDiagnostic {
    double frequency_hz{};
    double periodicity{};
    double odd_harmonic_occupancy{};
    double half_grid_veto{};
    double third_grid_veto{};
    bool half_grid_spectrally_resolvable{};
    bool third_grid_spectrally_resolvable{};
    double continuity_bonus{};
    double score{};
    bool selected{};
};

struct HAPTFrameDiagnostic {
    double rms{};
    bool signal_eligible{};
    std::vector<HAPTHypothesisDiagnostic> hypotheses;
    bool onset_recovery_attempted{};
    bool onset_recovery_used{};
    bool decay_recovery_attempted{};
    bool decay_recovery_used{};
    bool if_lock_attempted{};
    bool if_lock_applied{};
    int if_lock_harmonic{};
    double pre_if_lock_frequency_hz{};
    std::optional<HAPTPitch> pitch;
    std::string decision;
};

/// Stateless frame estimator (mirrors estimate_vpm_like_pitch): given one
/// complete analysis window (>= 512 samples), produce zero or one pitch
/// hypothesis. `previous_frequency_hz`, when given, is the caller's current
/// published contour: it both nudges hypothesis scoring (a small continuity
/// bonus) and sets which of the two hysteresis thresholds applies. Onset and
/// decay recovery are attempted internally against the trailing/leading 768
/// samples when the full window does not clear the onset threshold, so this
/// also works directly on shorter spans for diagnostics or bespoke recovery
/// windows (the phase-locked refinement needs >= 1536 samples and is skipped
/// below that).
std::optional<HAPTPitch> estimate_hapt_pitch(
    std::span<const float> samples,
    double sample_rate,
    const HAPTConfig& config = {},
    std::optional<double> previous_frequency_hz = std::nullopt
);

HAPTFrameDiagnostic diagnose_hapt_pitch(
    std::span<const float> samples,
    double sample_rate,
    const HAPTConfig& config = {},
    std::optional<double> previous_frequency_hz = std::nullopt
);

/// Causal publication guard, holding two kinds of cross-frame state:
///  - An RMS release detector (see HAPTConfig's release_* fields) that stops
///    publication once a note has genuinely ended, even through a decaying
///    room-reverb tail the frame-local sustain threshold alone would not
///    catch.
///  - A confirmation delay on a downward 1/2 or 1/3 harmonic jump from an
///    established contour, mirroring the role VPMLikeTracker plays for
///    vpm_like.
/// The onset/sustain hysteresis itself lives in the stateless estimator (via
/// `previous_frequency_hz`); callers should feed this tracker's currently
/// published frequency back into the next estimate_hapt_pitch call, and this
/// tracker's `process` the resulting estimate alongside that same frame's
/// RMS. This is the one piece of state shared between the production
/// session and the offline/tournament trace tool, so both see identical
/// release behaviour.
class HAPTTracker {
public:
    explicit HAPTTracker(const HAPTConfig& config = {});

    std::optional<HAPTPitch> process(std::optional<HAPTPitch> estimate, double rms);
    void reset();

    [[nodiscard]] std::optional<double> published_frequency_hz() const {
        return published_ ? std::optional<double>(published_->frequency_hz) : std::nullopt;
    }

private:
    HAPTConfig config_;
    std::optional<HAPTPitch> published_;
    std::optional<HAPTPitch> pending_;
    int pending_confirmations_{};
    double previous_rms_{};
    double release_rms_peak_{};
    int release_falls_{};
    bool release_active_{};
};

}  // namespace klarivision::core
