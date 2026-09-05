#pragma once

#include <cstddef>

/// Shared, frozen constants for the unified pitch engine.
///
/// These live in their own header, apart from `analysis_engine.hpp`, so the
/// candidate ladder, the harmonic evidence layer and the session can each be
/// developed without contending for one shared file. Nothing here depends on
/// any other KlariVision header.
namespace klarivision::core::unified {

// ---------------------------------------------------------------------------
// Frequency range
// ---------------------------------------------------------------------------
//
// The display range is what a user may see; the estimator range is deliberately
// wider. A candidate has to be representable before it can be rejected: to
// demote an 880 Hz subharmonic the engine must be able to score 1760 Hz, and a
// note sitting exactly at a range boundary must be evaluated before it wins its
// own f/2 period. Clamping the estimator to the display range instead pushes
// boundary notes systematically into the wrong octave.
//
// 80 Hz is the display floor (down from the 120 Hz production floor, which was
// clipping the Turkish G clarinet's low B2 at ~123.5 Hz). Widening the lag
// search is what previously let autocorrelation lock onto a multiple of the
// true period, so the engine compensates with a spectral presence requirement
// below `kLowRegisterHz` rather than with a narrow search.
//
// 1760 Hz (A6) is the highest sounding note of the Turkish G clarinet, written
// D7 -- the instrument sounds a perfect fourth below written pitch.
inline constexpr double kDisplayMinimumHz = 80.0;
inline constexpr double kEstimatorMinimumHz = 65.0;    // ~ -350 cents of guard
inline constexpr double kDisplayMaximumHz = 1760.0;
inline constexpr double kEstimatorMaximumHz = 2400.0;  // ~ +540 cents of guard

// Harmonic evidence has to reach several partials above the highest candidate
// or a high note looks unsupported and loses to its own subharmonic. At
// 1760 Hz a 5000 Hz analysis limit leaves only two partials.
inline constexpr double kSpectralAnalysisMaximumHz = 8000.0;

// ---------------------------------------------------------------------------
// Multi-resolution analysis bands
// ---------------------------------------------------------------------------
//
// One window cannot serve both ends of the range: 1536 samples is 2.5 periods
// at 80 Hz (below the "at least 2-3 periods" rule, with a noisy tail) and 118
// periods at 1760 Hz (long enough to smear vibrato and glissando). Each band
// gets a window sized to its own frequencies. Every band ends on the same,
// newest sample and is built purely from past samples, so none of them adds
// decision latency.
inline constexpr std::size_t kLowWindowSamples = 3072;   // 64 ms @ 48 kHz
inline constexpr std::size_t kMidWindowSamples = 1536;   // 32 ms
inline constexpr std::size_t kHighWindowSamples = 768;   // 16 ms
inline constexpr std::size_t kHistorySamples = kLowWindowSamples;

inline constexpr double kLowBandMaximumHz = 160.0;
inline constexpr double kMidBandMaximumHz = 800.0;

// Candidates within this fraction of a band edge are scored in both adjacent
// bands and the evidence is blended, so a note does not jump when it crosses.
inline constexpr double kBandBlendFraction = 0.15;

// ---------------------------------------------------------------------------
// Frame geometry (unchanged from the shared production contract)
// ---------------------------------------------------------------------------
inline constexpr double kContractSampleRateHz = 48'000.0;
inline constexpr std::size_t kHopSamples = 512;
inline constexpr double kDefaultMinimumRms = 0.015;

// 15 hops at 512 samples / 48 kHz = 160 ms of constant decision latency.
// Octave errors in this project's own measurements last a median of 2 frames
// and at most 9 (96 ms); a 5-frame window cannot see the end of most of them.
inline constexpr std::size_t kDefaultLagFrames = 15;
inline constexpr double kTransitionWidthCents = 700.0;

// ---------------------------------------------------------------------------
// Low-register defence
// ---------------------------------------------------------------------------
//
// A real 98-160 Hz fundamental carries measurable energy at its own frequency;
// an autocorrelation ghost carries essentially none. This is the single
// decisive difference from the older engines, which imposed no spectral
// existence requirement on low candidates at all.
inline constexpr double kLowRegisterHz = kLowBandMaximumHz;
inline constexpr double kLowFundamentalPresenceFloor = 0.30;
inline constexpr std::size_t kLowRegisterConfirmFrames = 3;
inline constexpr double kHighPassCutoffHz = 55.0;

// ---------------------------------------------------------------------------
// Harmonic family
// ---------------------------------------------------------------------------
//
// Promoted from the offline-only refinement to both profiles, so a ghost
// competes in the open and produces contest mass instead of winning silently.
// The 4x and 5x members earned their place empirically offline.
inline constexpr double kHarmonicFamilyRatios[] = {
    0.2, 0.25, 1.0 / 3.0, 0.5, 2.0, 3.0, 4.0, 5.0
};

inline constexpr std::size_t kMaximumCandidates = 12;
inline constexpr double kCandidateMergeCents = 25.0;

// ---------------------------------------------------------------------------
// Abstention
// ---------------------------------------------------------------------------
//
// These four targets and the tolerance are copied deliberately from
// scripts/pitch_error_metrics.py, so the engine's own abstain criterion is
// stated in exactly the units the benchmark scores harmonic errors in.
inline constexpr double kHarmonicTargetCents[] = {
    -1901.955, -1200.0, 1200.0, 1901.955
};
inline constexpr double kHarmonicToleranceCents = 90.0;

struct AbstentionPolicy {
    double voiced_posterior_floor{};
    double winner_posterior_floor{};
    double harmonic_dominance_floor{};
    double family_margin_floor{};
};

// Realtime abstains harder: with look-ahead bounded, a genuine register change
// and a one-frame octave slip can look alike, and a silent frame is preferred
// over a harmonic error. Offline decodes the whole file, so a contest that
// survives global decoding is real evidence rather than a look-ahead shortage;
// abstaining as hard there would only manufacture dropouts.
inline constexpr AbstentionPolicy kRealtimeAbstention{0.60, 0.55, 0.90, 0.05};
inline constexpr AbstentionPolicy kOfflineAbstention{0.50, 0.45, 0.75, 0.00};

inline constexpr std::size_t kAbstainRecoveryFrames = 2;

// ---------------------------------------------------------------------------
// Emission weights (starting points; tuned in the measurement phase)
// ---------------------------------------------------------------------------
inline constexpr double kPeriodWeight = 0.45;
inline constexpr double kSwipeWeight = 0.25;
inline constexpr double kTwmWeight = 0.30;

// ---------------------------------------------------------------------------
// Spectral parity (adaptive odd/even harmonic tolerance)
// ---------------------------------------------------------------------------
inline constexpr double kParityTrustPosterior = 0.90;
inline constexpr double kParityEmaAlpha = 0.15;
inline constexpr std::size_t kParityWarmupFrames = 8;
inline constexpr std::size_t kParitySilenceResetFrames = 40;
inline constexpr double kMinimumEvenWeight = 0.15;

inline constexpr double kTwmMeasuredWeight = 0.5;
inline constexpr double kTwmPredictedWeight = 0.5;
inline constexpr double kTwmScale = 0.35;

// Above this frequency one lag sample spans more than a few cents, so
// candidates are refined from the windowed phase instead of the lag grid.
inline constexpr double kPhaseRefineFloorHz = 1000.0;

}  // namespace klarivision::core::unified
