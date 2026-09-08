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

// A candidate is scored on how well its predicted harmonic series explains the
// spectrum, so how many of its partials are visible decides how much evidence
// it can possibly carry. A fixed ceiling spends that budget unevenly: at 294 Hz
// an 8 kHz limit shows 27 partials, at 1460 Hz it shows five. Thin evidence is
// what lets a subharmonic rival look comparable, and the top of the range is
// exactly where those rivals -- a note's own half and third -- fall into
// well-supported parts of the spectrum. The limit therefore scales with the
// candidate, so every candidate is judged on a similar number of partials.
inline constexpr std::size_t kMinimumScoredPartials = 10;
inline constexpr double kSpectralAnalysisHeadroom = 0.90;  // fraction of Nyquist

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
// Sub-sample refinement runs on its own window, separate from the band window
// that chose the lag.
//
// Which lag is right and where exactly it falls are different questions. The
// first needs a window matched to the register -- short in the top octave so
// vibrato and glissando are followed rather than averaged. The second needs
// only the shape of the curve either side of a minimum already chosen, and
// measures it better on a longer, quieter window. Splitting them buys the
// accuracy of a long window without the smearing: mean error in the top
// register falls from 4.0 cents to 1.6, matching the shipping engine, with no
// coverage given up.
//
// Longer is not better without limit. At 2048 the error climbs back to 2.7 and
// at 3072 to 5.8, because by then the window spans enough of a moving note to
// bias the minimum it is trying to locate.
inline constexpr std::size_t kRefinementWindowSamples = 1536;

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

// 8 hops at 512 samples / 48 kHz = 85.3 ms of constant decision latency.
//
// This was 15 (160 ms) until the lag sweep in docs/TEST_BASELINE.md measured
// what the longer window actually buys. The original argument -- octave errors
// last a median of 2 frames and at most 9, so a 5-frame window cannot see the
// end of most of them -- did not survive the measurement: serious harmonic
// errors are zero at every lag from 5 to 25, and cent accuracy is identical to
// three decimals. The only thing 160 ms bought was trap-suite coverage
// (2171 vs 1696 published frames), paid for with 107 ms of live latency. The
// product decision (D-037) was to take the responsiveness, landing on 5
// (53 ms).
//
// D-042 (docs/DECISIONS.md) partially reverses that: 8 was picked not for
// Viterbi smoothing -- the sweep above already showed 5 to 25 are
// interchangeable for that -- but because 8 hops is exactly
// kSeriesCoherenceLookaheadSamples (4096 samples). The live path's own
// audio stream, arriving while a frame sits in the fixed-lag decoder's
// buffer, is reused as that frame's series-coherence look-ahead once it
// resolves (see UnifiedPitchSession's lookahead buffer in
// unified_pitch_session.cpp) -- the one piece of offline-only evidence that
// needs genuine future samples, not merely more decoding patience.
//
// Measured on the sukru-tunar-ussak-taksim holdout at 164.55-164.90s: 53 ms
// leaves 6 wrong frames (after the evidence-ratio ceiling above already cut
// 9 to 6), 85 ms leaves 4. The remaining 4 are the earliest frames of the
// affected run and are not a look-ahead shortfall -- a bit-identical
// standalone check against the same 4096-sample span offline would use
// also reads them as coherent; offline's own 0-wrong result on this holdout
// comes from its *global* Viterbi pass letting a handful of later, clearly-
// vetoed frames pull the whole path away from the ghost, a propagation the
// fixed-lag decoder's necessarily local window (bounded by this same
// lag_frames) cannot reproduce without more total latency than the user
// approved. The user chose the correctness this constant does buy over the
// extra 32 ms; the honest remainder is reported, not hidden.
inline constexpr std::size_t kDefaultLagFrames = 8;
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

// Second way past the low-register gate, for a fundamental that is genuinely
// there but not radiated.
//
// The gate above asks whether a candidate's own frequency carries energy, and
// a hidden fundamental answers no -- so the correct pitch was being struck off
// the list before anything could weigh it, and the frame settled on a harmonic
// instead. Every hidden-fundamental error measured on the frozen holdouts was
// of that kind: 96.3 Hz reported as 288.9. The section of the same fixture an
// octave up, at 171.4 Hz, sits above the gate and produced no errors at all,
// which is the gate confessing.
//
// Presence is not the only evidence a low candidate can offer. A note whose
// fundamental is filtered away still has its harmonic series intact, and the
// two-way mismatch already measures exactly that: whether the candidate's
// predicted partials are present and whether it explains the peaks that are.
// A ghost fails it -- a candidate at f/3 predicts energy at 5f/3 and 7f/3
// where a real signal has none, and those partials carry full weight -- while
// a hidden fundamental passes it comfortably. Requiring either presence or a
// series that holds up keeps the gate's protection and stops it deleting the
// answer.
inline constexpr double kHiddenFundamentalTwmFloor = 0.55;
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
    // Independent of the dominance floor above, which is read from the
    // *posterior* -- a quantity the path can carry forward as inertia from
    // frames the winner legitimately won. A GCD ghost of two overlapping real
    // notes can inherit enough posterior mass from its neighbours to clear the
    // dominance floor for several frames running while its own *raw* emission
    // evidence is, every one of those frames, worse than the harmonic relative
    // it beat. `harmonic_evidence_ratio` is exactly that raw comparison and
    // carries no such inertia, so it is the gate that catches what dominance
    // misses. See `kHarmonicEvidenceRatioAbstainCeiling` for where the line
    // sits and why.
    double harmonic_evidence_ratio_ceiling{};
};

// The line for the independent evidence-ratio gate above: past this, the best
// harmonic relative's own raw emission is at least as strong as the winner's,
// not merely comparable to it. Measured on a GCD trap where a fifth's two
// notes (3:2) overlap and their common subharmonic wins the path for 17
// frames (the sukru-tunar-ussak-taksim holdout, 164.63-164.80s): the true
// note's emission beat the GCD ghost's by a factor of 1.32-1.85 on every one
// of those frames, while `harmonic_dominance` stayed above the 0.75 offline
// floor throughout on inherited posterior mass. 1.0 is the natural line
// because it asks the one question dominance cannot: whose raw evidence is
// actually better. Below 1.0 a rival's evidence can still be real -- a
// missing-fundamental partial routinely runs at a fraction of the winner's --
// which is exactly what `kHarmonicContestEvidenceRatio` at 0.40 already prices
// as a contest rather than a veto; this ceiling is deliberately steeper
// because crossing it means the *decoder itself* would have preferred the
// rival on the evidence alone.
inline constexpr double kHarmonicEvidenceRatioAbstainCeiling = 1.0;

// Realtime abstains harder: with look-ahead bounded, a genuine register change
// and a one-frame octave slip can look alike, and a silent frame is preferred
// over a harmonic error. Offline decodes the whole file, so a contest that
// survives global decoding is real evidence rather than a look-ahead shortage;
// abstaining as hard there would only manufacture dropouts.
//
// D-042 (docs/DECISIONS.md): the evidence-ratio ceiling used to be the
// exception to "offline abstains less readily", left at +infinity on the
// realtime profile because `low_register_confirmations` was believed to
// already cover this failure and opening the gate live was out of scope for
// the fix that added it. Measured directly on the live sukru-tunar trace
// (unified_trace, 164.63-164.80s): `low_register_confirmations` does not, in
// fact, cover it -- the ghost holds its confirmation window too. Setting
// this to the same finite ceiling as offline cut the target window from 9
// wrong frames to 6 at a cost of 20 voiced frames out of 14337 on that trace
// (0.14%); the remaining 6 needed the series-coherence veto below, not this
// gate. Cheap and partial, so it stays on rather than being reserved for
// offline alone.
inline constexpr AbstentionPolicy kRealtimeAbstention{
    0.40, 0.015, 0.90, 0.00, kHarmonicEvidenceRatioAbstainCeiling
};
inline constexpr AbstentionPolicy kOfflineAbstention{
    0.50, 0.010, 0.75, 0.00, kHarmonicEvidenceRatioAbstainCeiling
};

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
//
// The balance between the two matters far more than its size suggests, and the
// measured curve is steep on one side. Serious missing-voiced frames across the
// frozen holdouts, at otherwise identical settings:
//
//     60:40 -> 31, but 23 harmonic errors appear on the octave traps
//     55:45 -> 40, no harmonic errors anywhere        <- here
//     50:50 -> 47
//     45:55 -> 114
//     40:60 -> 281, and harmonic errors return
//
// The two terms disagree about subharmonics in opposite directions: the
// prime-harmonic kernel is what refuses them, the mismatch is what tolerates a
// partial that is merely absent. Leaning too far toward the kernel starts
// refusing real notes with weak fundamentals; too far toward the mismatch and
// subharmonic rivals stop looking wrong, contests multiply, and the engine
// declines frames it had measured correctly. Both failures show up as lost
// coverage, which is why the curve has a floor rather than a slope.
inline constexpr double kSwipeWeight = 0.55;
inline constexpr double kTwmWeight = 0.45;

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

// ---------------------------------------------------------------------------
// Series-internal coherence (common-subharmonic ghost defence)
// ---------------------------------------------------------------------------
//
// TWM and SWIPE'-prime both ask whether *a* candidate explains the measured
// peaks; neither asks whether the candidate's *own* predicted series holds
// together as one physical source. That gap is what lets a common
// subharmonic of two overlapping, harmonically-unrelated-to-it notes win: a
// perfect fifth (3:2) sitting at a boundary shares a subharmonic at 1/6th of
// the higher note (1/3 of a 3:2 pair reduces to a shared f/3, f/2 relative to
// each note respectively -- see docs/DECISIONS.md and the case measured
// below), and the combined spectrum really is periodic at that subharmonic,
// so ACF/pYIN are not wrong to find it. What they cannot see is that the
// ghost's own harmonic series is really two interleaved combs, each
// belonging to one of the real notes, with nothing of its own in between.
//
// Measured at 164.68s of
// data/audio/sukru-tunar-ussak-taksim-on-clarinet-pitch-contour-only-*.wav,
// where a fading 298.8 Hz note and an entering 448.2 Hz note (exact 3:2,
// common subharmonic 149.4 Hz) hand the frame to the 149.4 Hz ghost for 11
// frames (164.6293-164.7360s): a Hann-windowed DFT (N=8192) at the ghost's
// own predicted partials k=1..9 reads
//
//     k:      1        2        3        4        5        6        9
//     A(k*f): 0.00140  0.00210  0.00673  0.00027  0.00005  0.00049  0.00155
//
// -- present at 2 and 3 (the fading note's own fundamental and the entering
// note's fundamental), a silent stretch across 4-8, and partial 9 (an exact
// multiple of the *entering* note's own fundamental, 448.2 = 3*149.4) loud
// again. No stopped-pipe, string, or voice partial series does this: a
// register's weak partials (see ParityEstimate, ~15 lines up) are weak
// *everywhere* they occur in the series, never weak across a multi-partial
// stretch and then loud again higher up -- decay curves fold back on
// themselves in real resonators, they do not have holes with recoveries.
//
// Both design constraints from the false-positive side are load-bearing:
//
// - The gap has to span *several consecutive* partials before it counts.
//   A single missing partial is completely ordinary (any candidate can lose
//   one to a spectral null or measurement noise -- TWM already prices that),
//   and a clarinet's alternating odd/even series would otherwise trip this
//   on every note: present, absent, present, absent, ... is exactly what a
//   healthy odd-only series looks like one partial at a time. Only a run of
//   kSeriesCoherenceMinimumGapRun (2) or more consecutive silent partials
//   followed by a real one is treated as a hole with a recovery.
// - Presence is judged relative to the candidate's *own* loudest partial in
//   the checked window, not an absolute level, so the check works the same
//   whether the note is loud or soft, and a genuinely weak-but-real
//   fundamental (see kFundamentalPartialWeight, k = 1 is excluded from the
//   scan entirely) never enters into it.
inline constexpr std::size_t kSeriesCoherenceCheckPartials = 9;
inline constexpr double kSeriesCoherencePresenceRatio = 0.15;
inline constexpr std::size_t kSeriesCoherenceMinimumGapRun = 2;

// Second, independent condition on the same veto: the loudest partial in the
// checked window must exceed the candidate's OWN fundamental by this factor.
//
// The gap-then-return pattern alone proved far too broad on general material.
// Measured on the external development split (96 files): the veto with only
// that condition cost 1.5-3.2 points of voicing recall and, on those sets,
// made the octave error slightly WORSE rather than better -- overlapping
// sources put holes in almost every low candidate's series, so the pattern
// fires on innocent notes constantly.
//
// What actually distinguishes a GCD ghost is not the hole but where the energy
// sits: the ghost's "partials" are other real notes, so the loudest one dwarfs
// its nominal fundamental. On the measured trap (sukru-tunar-ussak-taksim,
// 164.63-164.80s) the ghost at 149.4 Hz carried 0.0014 at its fundamental and
// 0.0067 at k=3 -- the incoming 448.2 Hz note -- a ratio of 4.8. A genuine low
// note radiates most strongly at or near its own fundamental; a clarinet's
// third partial can rival the fundamental but does not tower over it, which is
// why the bar is set at 3.0 rather than just above 1.
inline constexpr double kSeriesCoherenceFundamentalDominanceRatio = 3.0;

// The table above was read from a window *centred* on 164.68s -- half past,
// half future. Measured again from the causal low-band window the engine
// actually scores a candidate against (kLowWindowSamples, ending on the
// frame's own newest sample, nothing later), the same instant shows no such
// gap: the entering note has not yet grown loud enough within the last 64ms
// alone to stand out from ordinary leakage, so k = 3 and k = 9 read as noise
// next to k = 1 and k = 2 rather than as a second comb. The signature this
// check depends on is real, but it is not yet *visible* to a purely causal
// window at the frames where it matters most -- confirmed by re-deriving
// the table above from the causal window at the same timestamp and finding
// k = 3 buried under k = 1/k = 2 leakage instead of standing above the
// noise floor the way it does once the entering note has had another
// ~40-70 ms to develop.
//
// Offline already holds the whole track before this check ever runs
// (`collect_unified_evidence` receives it up front), so it can afford to
// look past the current instant the same way a human editing the track
// offline could -- something a live callback genuinely cannot do, since
// those samples have not arrived yet. This is the one piece of evidence in
// the whole harmonic-evidence layer that reaches past `history`'s newest
// sample, and it does so only for the offline profile: `unified_frame_
// evidence`'s `lookahead_samples` defaults to empty, which leaves `series_
// incoherent` false everywhere the live path calls it, identically to
// before this check existed. Only `collect_unified_evidence` passes a real
// span.
//
// 85 ms (4096 samples at 48 kHz) is enough to reach the point in this
// measured case (164.6293-164.736s) where every one of the 11 affected
// frames' own future already shows the gap-and-recovery pattern above the
// noise floor, averaged across the lookahead window as a whole -- the
// latest-starting frame in the run needs the least of it and the earliest
// needs the most, and 85 ms covers the earliest with headroom to spare
// without paying for a larger transform than this check needs. A longer
// window (128 ms, one FFT size class up) bought no additional frames fixed
// on the same holdout and cost measurably more of the whole-file decode
// budget, which is why this is the smaller of the two rather than the more
// cautious-looking round number.
inline constexpr std::size_t kSeriesCoherenceLookaheadSamples = 4096;

// The coherence spectrum above is deliberately not built for every
// low-register entry in a frame's candidate list. `kHarmonicFamilyRatios`
// alone puts a sub-160 Hz relative into most frames' candidate set (any
// proposal at or above 320 Hz spawns one at 0.2x or 0.25x), so checking
// every one of them measured at 73 s for the whole holdout file against a
// 48-50 s baseline -- an unbounded FFT-per-candidate cost this check has no
// business paying, because a family relative injected at a twentieth of its
// parent's periodicity (see unified_frame_evidence) essentially never wins
// a frame outright regardless of what its own series looks like. Only the
// first kSeriesCoherenceCandidateLimit entries of `candidate_frequencies_hz`
// are checked, relying on the one ordering guarantee `unified_frame_
// evidence` already provides its caller: candidates arrive sorted by
// descending prior probability, so index 0 is always the frame's actual
// leading hypothesis and this is exactly the candidate the veto exists to
// police. Measured at 1 on the same holdout: checking the runner-up too
// (limit 2) reclassified none of the file's frames beyond what checking
// only the leader already did, and cost enough of the whole-file decode
// budget on its own (50.6s -> 56.7s, against a 48-50s baseline) to matter,
// so the second slot bought nothing this measurement could find and is not
// spent.
inline constexpr std::size_t kSeriesCoherenceCandidateLimit = 1;

inline constexpr double kTwmMeasuredWeight = 0.5;
inline constexpr double kTwmPredictedWeight = 0.5;
inline constexpr double kTwmScale = 0.35;

// Above this frequency one lag sample spans more than a few cents, so
// candidates are refined from the windowed phase instead of the lag grid.
inline constexpr double kPhaseRefineFloorHz = 1000.0;

}  // namespace klarivision::core::unified
