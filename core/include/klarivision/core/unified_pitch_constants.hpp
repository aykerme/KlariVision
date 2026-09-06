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

// A(f) relative to its strongest low multiple, below which a low candidate is
// dropped outright. The bar has to be low: a stopped-pipe fundamental in its
// bottom register is routinely many times weaker than its own third harmonic,
// and a bar set where "a real fundamental is a third as loud as its harmonic"
// rejects ordinary, correct low notes. What this catches is the other case
// entirely -- an autocorrelation ghost, whose own frequency carries essentially
// no energy at all. Graded demotion of merely-soft fundamentals is
// spectral_existence's job, not this gate's.
inline constexpr double kLowFundamentalPresenceFloor = 0.05;
inline constexpr std::size_t kLowRegisterConfirmFrames = 3;
inline constexpr double kHighPassCutoffHz = 55.0;

// Below this fraction of the RMS gate a frame is treated as certainly silent
// and skips analysis entirely. Between here and the gate the frame is analysed
// normally but its unvoiced hypothesis is biased upward in proportion to how
// quiet it is, so the decoder decides rather than a threshold.
//
// A hard energy gate cannot tell a rest from the quiet middle of a sustained
// note, and cutting candidate generation at the gate punches holes in held
// notes that no later stage can fill. Handing the decision to the path instead
// bridges a brief dip -- staying voiced is cheap, switching is not -- while a
// real rest still resolves to silence, because every frame across it agrees.
inline constexpr double kHardSilenceRatio = 0.35;

// Voicing is decided from the normalised square difference function's clarity,
// not from the threshold sweep's probability mass.
//
// d'(T) is the aperiodic power fraction, so the sweep is asking how absolutely
// clean a frame is -- a question about the recording's noise floor as much as
// about the note. A perfectly clear tone measured at 6 dB SNR reads d' = 0.2,
// fails nearly every threshold the prior puts mass on, and is discarded even
// though its pitch is correct to within three cents. Clarity is a normalised
// correlation and moves with the note rather than the noise floor: measured
// across the same sweep it reads 0.76 for that frame, 0.09 for noise alone,
// 0.00 for silence, and 1.00 for a clean tone whose fundamental is a twentieth
// of its own third harmonic.
//
// Which period is correct is still decided by the sweep, whose sharpness is
// what keeps the engine off the third harmonic. Only "is anything sounding" is
// answered here.
inline constexpr double kVoicingClarityFloor = 0.60;
inline constexpr double kVoicingClarityCeiling = 0.90;

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
    // Guards against a pathologically flat frame where nothing fits, and
    // nothing more. It sits far below an even split across a dozen states
    // because a dozen states is what this engine produces on purpose: posterior
    // share is diluted by design, and a bar anywhere near uniform punishes
    // exactly the behaviour the architecture exists to create. Measured, every
    // frame it withheld above this level was withheld for nothing -- raising it
    // from a sixtieth to a tenth cost 664 correct frames across the frozen
    // holdouts and prevented not one harmonic error. Harmonic ambiguity is
    // priced by the dominance floor below, which is the rule that carries the
    // requirement.
    double winner_posterior_floor{};
    double harmonic_dominance_floor{};
    // The winner must merely not be *beaten* by one of its own harmonic
    // relatives on spectral evidence. Demanding a positive margin on top of
    // that withholds a large number of perfectly ordinary frames on real
    // recordings, where the margin is small and noisy even when the answer is
    // right, and it buys nothing: harmonic ambiguity is already priced by the
    // dominance floor above.
    double family_margin_floor{};
};

// Realtime abstains harder: with look-ahead bounded, a genuine register change
// and a one-frame octave slip can look alike, and a silent frame is preferred
// over a harmonic error. Offline decodes the whole file, so a contest that
// survives global decoding is real evidence rather than a look-ahead shortage;
// abstaining as hard there would only manufacture dropouts.
inline constexpr AbstentionPolicy kRealtimeAbstention{0.40, 0.015, 0.90, 0.00};
inline constexpr AbstentionPolicy kOfflineAbstention{0.50, 0.010, 0.75, 0.00};

// Applied only after a frame was withheld for *harmonic* ambiguity, never
// after an ordinary quiet or low-confidence one. Flicker between silence and a
// disputed pitch is worth suppressing; charging every withheld frame two more
// silent ones triples the cost of ordinary silence for no benefit at all.
// How strong the best harmonic relative's evidence must be, relative to the
// winner's, before a split posterior counts as a genuine contest. Below this
// the rival is simply a partial of the note being played, drawing mass because
// it is really there -- which is evidence for the winner, not against it.
inline constexpr double kHarmonicContestEvidenceRatio = 0.40;

inline constexpr std::size_t kAbstainRecoveryFrames = 2;

// Publication tolerance around the display range. A note written at the very
// top or bottom of the instrument's range lands a few cents either side of the
// nominal frequency, and refusing it because it missed the boundary by a cent
// would silence the extremes of the range the range was drawn to include.
// A semitone is wide enough for tuning and vibrato, and far too narrow to let
// a harmonic relative through.
inline constexpr double kDisplayRangeToleranceCents = 100.0;

// ---------------------------------------------------------------------------
// Emission weights (starting points; tuned in the measurement phase)
// ---------------------------------------------------------------------------
//
// A candidate's score is (periodicity) x (spectral support), following the
// research report's own formulation. These two weights only set the blend
// *within* the spectral term; periodicity multiplies the result rather than
// being averaged into it, so a speculative harmonic competitor cannot buy its
// way back to the fundamental's score on spectral evidence alone.
inline constexpr double kSwipeWeight = 0.45;
inline constexpr double kTwmWeight = 0.55;

// ---------------------------------------------------------------------------
// Spectral parity (adaptive odd/even harmonic tolerance)
// ---------------------------------------------------------------------------
inline constexpr double kParityTrustPosterior = 0.90;
inline constexpr double kParityEmaAlpha = 0.15;
inline constexpr std::size_t kParityWarmupFrames = 8;
inline constexpr std::size_t kParitySilenceResetFrames = 40;
inline constexpr double kMinimumEvenWeight = 0.15;

// How heavily a *missing first harmonic* counts against a candidate in the
// predicted-to-measured direction.
//
// The fundamental is the one partial that is routinely absent while the pitch
// it defines is still plainly heard: a stopped pipe in its bottom register, a
// voice over a telephone band, any source whose lowest partial is filtered
// away. Hermes built subharmonic summation around exactly this, and tested it
// on speech high-passed above 300 Hz, where the fundamental is physically
// gone. Requiring it is therefore not a test of whether the pitch is right; it
// is a test of whether the instrument happens to radiate its own fundamental.
//
// Forgiving it does not open the door to subharmonics, which is the reason the
// requirement looked useful in the first place. An f/2 or f/3 ghost is refused
// by its *other* odd partials: a ghost at f/3 predicts energy at 5f/3 and 7f/3,
// where a real signal has none, and those carry full weight.
inline constexpr double kFundamentalPartialWeight = 0.25;

inline constexpr double kTwmMeasuredWeight = 0.5;
inline constexpr double kTwmPredictedWeight = 0.5;
inline constexpr double kTwmScale = 0.35;

// Above this frequency one lag sample spans more than a few cents, so
// candidates are refined from the windowed phase instead of the lag grid.
inline constexpr double kPhaseRefineFloorHz = 1000.0;

}  // namespace klarivision::core::unified
