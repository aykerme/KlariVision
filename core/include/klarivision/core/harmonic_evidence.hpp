#pragma once

#include "klarivision/core/frame_spectrum.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"

#include <cstddef>
#include <span>
#include <vector>

namespace klarivision::core {

/// Running estimate of the spectral parity of whatever is currently playing.
///
/// A stopped cylindrical pipe (clarinet in its chalumeau register) carries odd
/// partials and almost nothing at 2f; a sawtooth, a voice or a bowed string
/// carries the full integer series. Hard-coding the clarinet case would make
/// the engine instrument-specific and would start rejecting correct notes on
/// everything else, so parity is measured instead of assumed.
///
/// Crucially this is a property of the *committed track*, not of the candidate
/// under test. Measured at the candidate, an f/3 ghost would see the real
/// fundamental as its own third partial, look odd-rich, and manufacture its
/// own excuse for the missing even partials.
struct ParityEstimate {
    /// rho-hat in [-1, 1]: +1 odd partials only, 0 full integer series.
    double index{0.0};
    /// Committed frames folded in so far. Below unified::kParityWarmupFrames
    /// the estimate is held at 0, i.e. fully generic.
    std::size_t samples{0};

    /// The weight an even-indexed partial carries in the predicted-to-measured
    /// direction of the two-way mismatch. Odd partials always weigh 1.
    [[nodiscard]] double even_partial_weight() const;
    [[nodiscard]] bool warm() const;
};

struct HarmonicEvidence {
    /// SWIPE'-style support: first and prime harmonics contribute positively
    /// while every integer harmonic position contributes to the normalisation,
    /// which is what leaves a subharmonic explainably weak.
    double swipe_prime_support{};
    /// exp(-E_twm / kTwmScale) from the two-way mismatch. The
    /// predicted-to-measured direction is the one that kills octave errors: a
    /// candidate an octave below the truth explains every measured peak, but
    /// finds no peak for its own odd-indexed predictions.
    double twm_score{};
    /// A(f) / max(A(2f), A(3f)). Near zero means the candidate's own frequency
    /// carries no acoustic energy -- an autocorrelation ghost.
    double fundamental_presence{};
    /// 0..kGhostMaxPenalty, from the existing spectral existence check.
    double ghost_penalty{};
    /// score(f) minus the best score among f * {1/3, 1/2, 2, 3}. Negative
    /// means a harmonic relative explains the frame better than f does.
    double family_margin{};
    /// rho measured at this candidate. Diagnostic only -- never fed back into
    /// the ParityEstimate, for the reason given above.
    double parity_index{};
    /// True when the band-edge blend was applied to this candidate.
    bool band_blended{false};
};

/// Scores every candidate against the spectrum. Output is positionally
/// parallel to `candidate_frequencies_hz`.
[[nodiscard]] std::vector<HarmonicEvidence> score_harmonic_evidence(
    std::span<const float> history,
    const MultiResolutionSpectra& spectra,
    double sample_rate,
    std::span<const double> candidate_frequencies_hz,
    const ParityEstimate& parity,
    double maximum_analysis_frequency_hz = unified::kSpectralAnalysisMaximumHz
);

/// Folds one committed, high-posterior frame into the running parity estimate.
/// Call only when the decoder resolved the frame with a winner posterior of at
/// least unified::kParityTrustPosterior.
void update_parity_estimate(
    ParityEstimate& parity,
    const MultiResolutionSpectra& spectra,
    double committed_frequency_hz,
    double sample_rate
);

/// Decay the estimate back towards "generic" after a long silence; the
/// instrument may have changed.
void note_unvoiced_frame(ParityEstimate& parity);

/// Signed cents from `reference_hz` to `frequency_hz`.
[[nodiscard]] double cents_between(double reference_hz, double frequency_hz);

/// True when `signed_cents` lands within unified::kHarmonicToleranceCents of
/// any target in unified::kHarmonicTargetCents. Shared by the evidence layer
/// and the abstention rule so both speak the benchmark's units.
[[nodiscard]] bool is_harmonic_relationship(double signed_cents);

}  // namespace klarivision::core
