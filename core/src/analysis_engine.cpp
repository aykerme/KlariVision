#include "klarivision/core/analysis_engine.hpp"

#include "klarivision/core/harmonic_arbitration.hpp"
#include "klarivision/core/pitch_engine_v2_session.hpp"
#include "klarivision/core/vpm_like.hpp"
#include "klarivision/core/hapt.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <numbers>
#include <numeric>
#include <stdexcept>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace klarivision::core {
namespace {
struct Candidate { double frequency{}; double confidence{}; double emission{}; };  // emission = log-confidence, used as the Viterbi-style emission score in resolve_track
constexpr double kSilenceEmission = -0.80;       // emission score assigned to the "silence" state in resolve_track's path search
constexpr std::size_t kMaximumBridgeFrames = 7;  // longest gap append_bridged will paper over with a repeated pitch

// DC-removed root-mean-square loudness of a window; the shared silence/
// signal-eligibility gate for every engine in this file.
double centered_rms(std::span<const float> samples) {
    if (samples.empty()) return 0;
    const double mean = std::accumulate(samples.begin(), samples.end(), 0.0) / samples.size();  // DC offset
    double sum = 0;
    for (const float sample : samples) { const double x = sample - mean; sum += x * x; }  // accumulate squared, DC-free amplitude
    return std::sqrt(sum / samples.size());
}

// Single-frequency Hann-windowed spectral energy probe (same DFT-at-one-
// frequency technique used throughout the codebase), returning squared
// magnitude.
double spectral_energy(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8 || frequency <= 0) return 0;
    const double step = 2 * std::numbers::pi * frequency / rate;         // per-sample phase increment of the probe frequency
    const double denominator = static_cast<double>(samples.size() - 1);  // Hann window normaliser
    double cosine = 0;
    double sine = 0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double window = 0.5 - 0.5 * std::cos(2 * std::numbers::pi * index / denominator);  // Hann taper
        const double value = samples[index] * window;   // windowed sample
        const double phase = step * index;               // accumulated phase of the probe frequency
        cosine += value * std::cos(phase);
        sine += value * std::sin(phase);
    }
    return cosine * cosine + sine * sine;  // squared magnitude of the probe response
}

double spectral_amplitude(std::span<const float> samples, double rate, double frequency) {
    if (samples.size() <= 8) return 0;
    // `spectral_energy` uses the same Hann window. Its coherent window sum is
    // (N-1)/2, so this converts the complex magnitude to the normalized
    // amplitude used by the VPM-like estimator's 0.005 direct-support gate.
    return 4.0 * std::sqrt(spectral_energy(samples, rate, frequency)) /
        static_cast<double>(samples.size() - 1);
}

// Pitch distance between two frequencies, in cents, always non-negative.
double cents_distance(double a, double b) { return std::abs(1200.0 * std::log2(a / b)); }

// Dot product of two sample buffers, Accelerate-accelerated on Apple
// platforms (see pitch_engine_v2_session.cpp's identical helper).
float float_dot(const float* left, const float* right, const std::size_t count) {
#if defined(__APPLE__)
    float result = 0;
    vDSP_dotpr(left, 1, right, 1, &result, static_cast<vDSP_Length>(count));
    return result;
#else
    float result = 0;
    for (std::size_t index = 0; index < count; ++index) result += left[index] * right[index];
    return result;
#endif
}

// Stable "YIN v1" candidate generator: the classic CMND (cumulative mean
// normalised difference) algorithm -- same formula as
// pitch_engine_v2_session.cpp's yin_candidates -- returning every plausible
// local-minimum candidate, plus a narrow octave-recovery pass at the end.
std::vector<Candidate> yin_candidates(std::span<const float> samples, double rate, const PitchEngineConfig& config) {
    const int min_lag = std::max(2, static_cast<int>(rate / config.maximum_frequency_hz));  // shortest period to test (highest pitch)
    const int max_lag = std::min(static_cast<int>(samples.size() / 2), static_cast<int>(rate / config.minimum_frequency_hz));  // longest period (lowest pitch), capped at half the window
    if (min_lag + 2 >= max_lag) return {};  // range too narrow to hold a peak plus its neighbours
    // Prefix sum of squared samples for O(1) sub-range energy lookups.
    std::vector<float> energy(samples.size() + 1, 0);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        energy[index + 1] = energy[index] + samples[index] * samples[index];
    }
    // YIN's difference function, computed via the same energy-minus-2x-
    // correlation algebraic expansion as the V2 session's yin_candidates.
    std::vector<float> difference(static_cast<std::size_t>(max_lag + 1), 0);
    for (int lag = min_lag; lag <= max_lag; ++lag) {
        const auto count = samples.size() - static_cast<std::size_t>(lag);
        const float correlation = float_dot(samples.data(), samples.data() + lag, count);
        difference[static_cast<std::size_t>(lag)] = std::max(
            0.0F,  // clamp tiny negative floating-point error to zero
            energy[count] + (energy[samples.size()] - energy[static_cast<std::size_t>(lag)]) -
                2.0F * correlation
        );
    }
    // Cumulative Mean Normalised Difference: divide by the running average
    // difference up to this lag, scaled by the lag -- turns the raw
    // difference function into one that dips toward zero exactly at the
    // true period, directly comparable across lags.
    std::vector<float> cumulative(static_cast<std::size_t>(max_lag + 1), 1);
    float total = 0;
    for (int lag = 1; lag <= max_lag; ++lag) {
        total += difference[static_cast<std::size_t>(lag)];
        if (total > 0) cumulative[static_cast<std::size_t>(lag)] =
            difference[static_cast<std::size_t>(lag)] * static_cast<float>(lag) / total;
    }
    // Peak picking: a local minimum of the CMND curve below the standard
    // 0.50 threshold is a plausible period, refined via parabolic
    // interpolation to sub-sample accuracy.
    std::vector<Candidate> result;
    for (int lag = min_lag + 1; lag < max_lag; ++lag) {
        if (!(cumulative[lag] <= cumulative[lag - 1] && cumulative[lag] < cumulative[lag + 1] && cumulative[lag] < 0.50)) continue;  // not a dip below threshold
        const float denominator = cumulative[lag - 1] - 2.0F * cumulative[lag] + cumulative[lag + 1];  // parabola curvature term
        const float correction = std::abs(denominator) > 0.000001F
            ? std::clamp(0.5F * (cumulative[lag - 1] - cumulative[lag + 1]) / denominator, -0.5F, 0.5F)
            : 0;
        const double frequency = rate / (lag + correction);  // period -> frequency
        if (frequency >= config.minimum_frequency_hz && frequency <= config.maximum_frequency_hz) {
            const double confidence = std::clamp(static_cast<double>(1.0F - cumulative[lag]), 0.0, 1.0);  // dip depth -> confidence
            result.push_back({frequency, confidence, std::log(std::max(1e-6, confidence))});  // emission = log-confidence, floored to avoid log(0)
        }
    }
    std::sort(result.begin(), result.end(), [](const Candidate& a, const Candidate& b) { return a.confidence > b.confidence; });  // strongest first
    // Octave-recovery pass: for every candidate found so far, check whether
    // its exact 2x frequency carries dramatically more spectral energy
    // (>= 8x, and above 800 Hz). If so, add that frequency as its own
    // near-maximal-confidence candidate -- the CMND minimum alone may have
    // locked onto a lower sub-period while the true fundamental sits an
    // octave up.
    // Odd-harmonic occupancy, the one test that separates "this candidate is
    // a ghost subharmonic" from "this is a real clarinet fundamental whose
    // own first partial happens to be thin right now".  A clarinet is a
    // stopped cylinder: odd partials (3f, 5f) carry the tone and even ones
    // are physically weak.  So a true fundamental f always leaves energy at
    // 3f/5f, while a ghost at f -- where the real note is 2f -- leaves 3f and
    // 5f sitting between the real note's partials, on nothing.
    const auto odd_support = [&](const double frequency) {
        double total = 0;
        for (const double multiple : {3.0, 5.0}) {
            const double probe = frequency * multiple;
            if (probe < rate / 2) total += spectral_energy(samples, rate, probe);
        }
        return total;
    };
    const auto original_count = result.size();
    for (std::size_t index = 0; index < original_count; ++index) {
        const double upper = result[index].frequency * 2;
        if (upper <= 800 || upper > config.maximum_frequency_hz) continue;  // only in the high register
        if (spectral_energy(samples, rate, upper) <=
            spectral_energy(samples, rate, result[index].frequency) * 8) continue;  // not a decisive enough dominance
        // Raw 2x dominance alone was promoting real fundamentals: measured on
        // the Şükrü Tunar verdict set it produced 12 of YIN v1's 13 marked
        // octave errors, every one of them above 800 Hz.  Require the upper
        // line to also own the odd-harmonic pattern before believing the
        // lower candidate was never a real note.
        if (odd_support(upper) <= odd_support(result[index].frequency)) continue;
        // A narrow direct-spectrum recovery for an f/2 period choice.
        // The high confidence ensures the offline path resolver retains
        // this evidence instead of preferring the repeated lower period.
        result.push_back({upper, 0.99999, std::log(0.99999)});
    }
    std::sort(result.begin(), result.end(), [](const Candidate& a, const Candidate& b) { return a.confidence > b.confidence; });  // re-sort with the new candidate(s) included
    if (result.size() > 12) result.resize(12);  // cap the candidate list
    return result;
}

// Score adjustment for a candidate whose own frequency is a spectral
// near-null next to a dominant 2x/3x multiple -- an autocorrelation ghost,
// not a real period. See `harmonic_arbitration.hpp` for why this pattern
// exists on closed-pipe clarinet tones and why the threshold is
// conservative. The penalty is graded, not a hard rejection: it must still
// lose fairly to continuity and to genuinely ambiguous candidates rather
// than overriding them outright.
double ghost_subharmonic_penalty(
    std::span<const float> samples, double sample_rate, double candidate_hz, double maximum_frequency_hz
) {
    const auto existence = spectral_existence(samples, sample_rate, candidate_hz, maximum_frequency_hz);  // real-spectrum ghost check
    if (!existence.is_ghost_subharmonic) return 0.0;  // not flagged as a ghost: no penalty
    const double severity = std::clamp((existence.dominant_multiple_ratio - 6.0) / 20.0, 0.0, 1.0);  // how far past the ghost threshold the dominance ratio sits
    return 0.15 * severity;  // graded penalty, up to 0.15, scaling with how decisive the ghost evidence is
}

std::optional<Candidate> causal_yin_choice(
    const std::vector<Candidate>& candidates,
    const std::optional<Candidate>& previous,
    std::span<const float> samples,
    double sample_rate,
    double maximum_frequency_hz
) {
    if (candidates.empty()) return std::nullopt;
    // `yin_candidates` grants this confidence only to a high-register line
    // whose directly measured spectrum exceeds its f/2 candidate by 8x.
    // Do not let continuity pull that explicit fundamental back to a stable
    // low sub-period.
    const auto direct_high = std::max_element(
        candidates.begin(), candidates.end(), [](const Candidate& left, const Candidate& right) {
            const bool left_is_direct_high = left.frequency > 800 && left.confidence >= .9999;   // is `left` the near-maximal-confidence octave-recovery candidate?
            const bool right_is_direct_high = right.frequency > 800 && right.confidence >= .9999;
            if (left_is_direct_high != right_is_direct_high) return !left_is_direct_high;  // an octave-recovery candidate always outranks a non-recovery one
            return left.frequency < right.frequency;  // among equals, prefer the higher frequency (max_element convention)
        }
    );
    if (direct_high != candidates.end() &&
        direct_high->frequency > 800 && direct_high->confidence >= .9999) return *direct_high;  // short-circuit: trust the explicit octave-recovery evidence outright

    // Real-spectrum ghost check and its graded confidence penalty, both
    // built on harmonic_arbitration.hpp's spectral_existence.
    const auto is_ghost = [&](const Candidate& candidate) {
        return spectral_existence(samples, sample_rate, candidate.frequency, maximum_frequency_hz)
            .is_ghost_subharmonic;
    };
    const auto adjusted_score = [&](const Candidate& candidate) {
        return candidate.confidence -
            ghost_subharmonic_penalty(samples, sample_rate, candidate.frequency, maximum_frequency_hz);
    };
    std::optional<Candidate> choice;
    if (!previous) {
        // With no continuity prior -- exactly the state right after an
        // articulation gap, where a weak-fundamental/strong-third-harmonic
        // note is most likely to hand autocorrelation a ghost subharmonic
        // as its top raw-confidence candidate -- bootstrap from the
        // ghost-adjusted ranking instead of raw confidence alone.
        const auto confident = std::max_element(
            candidates.begin(), candidates.end(),
            [&](const Candidate& left, const Candidate& right) {
                return adjusted_score(left) < adjusted_score(right);  // rank by ghost-penalised confidence, not raw confidence
            }
        );
        if (confident != candidates.end() && confident->confidence >= .76) choice = *confident;  // only bootstrap from a genuinely confident candidate
    }
    if (!choice) {
        // Normal (continuity-aware) path: pick the candidate with the best
        // ghost-adjusted score, further penalised by distance from the
        // previously tracked frequency (up to -0.30 at 700+ cents away).
        std::optional<Candidate> best;
        double best_score = -std::numeric_limits<double>::infinity();
        for (const auto& candidate : candidates) {
            if (candidate.confidence < .55) continue;  // too weak on its own terms to even consider
            double score = adjusted_score(candidate);
            if (previous) {
                const double distance = cents_distance(candidate.frequency, previous->frequency);  // distance from the tracked contour
                score -= .30 * std::min(distance / 700.0, 1.0);  // continuity penalty, capped at -0.30
            }
            if (score > best_score) { best = candidate; best_score = score; }  // track the running best
        }
        choice = best;
    }
    if (choice && is_ghost(*choice)) {
        // A closed-pipe clarinet tone's ambiguous, thinnest transient
        // frames can leave nothing in the ladder but ghost subharmonics --
        // no candidate with real acoustic energy of its own clears the
        // confidence floor at all. A ghost has no period-domain claim to be
        // published as a fundamental regardless of how it ranks against
        // its equally-unreliable neighbours; staying silent lets the
        // existing gap-bridging path (`append_bridged`) recover the frame
        // from its surrounding context instead of reporting a spurious
        // subharmonic.
        return std::nullopt;
    }
    return choice;
}

void append_bridged(
    std::vector<EngineFrame>& output,
    std::vector<EngineFrame>& pending_gap,
    std::optional<EngineFrame>& last,
    const std::optional<EngineFrame>& frame,
    bool signal_eligible,
    double hop_seconds,
    double minimum_endpoint_confidence,
    // The stronger endpoint must still clear `minimum_endpoint_confidence`;
    // this only relaxes the *weaker* one. A dropout's trailing edge is
    // exactly where a real engine's own confidence is most degraded by the
    // interruption itself, so requiring both endpoints to independently
    // clear the same bar under-bridges genuine short gaps. A negative value
    // (the default) keeps the original single-threshold, symmetric check.
    double minimum_weaker_endpoint_confidence = -1.0
) {
    if (!frame) {
        if (!signal_eligible) { pending_gap.clear(); last.reset(); }  // genuine silence: nothing to bridge, drop tracking
        else if (last && pending_gap.size() < kMaximumBridgeFrames) {
            // Signal present but this frame didn't publish: tentatively
            // repeat the last known pitch, timestamped as if it continued.
            pending_gap.push_back({last->time_seconds + (pending_gap.size() + 1) * hop_seconds, last->frequency_hz, last->confidence});
        } else { pending_gap.clear(); last.reset(); }  // gap grew too long, or nothing to repeat: give up bridging
        return;
    }
    const double weaker_floor = minimum_weaker_endpoint_confidence >= 0.0
        ? minimum_weaker_endpoint_confidence : minimum_endpoint_confidence;  // asymmetric floor for the weaker of the two endpoints, if configured
    if (!pending_gap.empty() && last && last->frequency_hz && frame->frequency_hz &&
        std::max(last->confidence, frame->confidence) >= minimum_endpoint_confidence &&  // the stronger endpoint must clear the normal bar
        std::min(last->confidence, frame->confidence) >= weaker_floor &&                  // the weaker endpoint only needs the (possibly relaxed) floor
        cents_distance(*last->frequency_hz, *frame->frequency_hz) <= 90) {                // both endpoints must agree on roughly the same pitch
        output.insert(output.end(), pending_gap.begin(), pending_gap.end());  // confirmed: release the whole buffered gap-filler run
    }
    pending_gap.clear();
    output.push_back(*frame); last = frame;  // always include this frame's own real publication
}

// Wraps the VPM-like estimator (vpm_like.cpp) as a single-candidate source
// for the generic Viterbi path resolver below, currently unused in favour
// of the dedicated, stateful VPM-like branch in process_frame further down.
[[maybe_unused]] std::vector<Candidate> vpm_candidates(std::span<const float> samples, double rate, const PitchEngineConfig& config) {
    std::vector<double> copied(samples.begin(), samples.end());  // VPM-like operates on double samples
    VPMLikeConfig vpm; vpm.minimum_frequency_hz = config.minimum_frequency_hz; vpm.maximum_frequency_hz = std::max(1650.0, config.maximum_frequency_hz); vpm.minimum_rms = config.minimum_rms;
    const auto diagnostic = diagnose_vpm_like_pitch(copied, rate, vpm);  // run the full estimator (spectral-relative correction included)
    // `diagnostic.pitch` is the VPM-like estimator's final spectrum-aware
    // decision. Feeding its raw ACF alternatives back into the generic path
    // resolver discarded that decision and repeatedly selected f/2 instead.
    if (diagnostic.pitch && diagnostic.pitch->confidence >= vpm.minimum_output_confidence &&
        diagnostic.pitch->frequency_hz <= config.maximum_frequency_hz) {
        return {{diagnostic.pitch->frequency_hz, diagnostic.pitch->confidence,
                 std::log(diagnostic.pitch->confidence)}};  // single candidate, emission = log-confidence
    }
    return {};
}

// Generic offline Viterbi path resolver over a whole pre-computed sequence
// of per-frame candidate lists: for each frame, adds a "silence" state plus
// one state per candidate, and finds the highest-scoring path through all
// frames (candidate's own emission score, plus a transition penalty for
// jumping frequency -- or switching to/from silence -- between consecutive
// frames). Currently unused (each engine below runs its own dedicated,
// causal/online tracking logic instead), kept as the shared non-causal
// alternative.
[[maybe_unused]] std::vector<EngineFrame> resolve_track(const std::vector<std::vector<Candidate>>& frames, double rate, const PitchEngineConfig& config, PitchEngineId id) {
    struct State { std::optional<Candidate> candidate; double score; int prior; };  // prior = index of the best-preceding state, for backtracking
    std::vector<std::vector<State>> layers;  // one layer of states per frame
    const double width = id == PitchEngineId::pitch_engine_v2 ? 700.0 : (id == PitchEngineId::vpm_like ? 420.0 : 500.0);  // per-engine transition-penalty width, in cents
    for (std::size_t frame = 0; frame < frames.size(); ++frame) {
        std::vector<State> current; current.push_back({std::nullopt, kSilenceEmission, -1});  // always include a "silence" state
        for (const auto& candidate : frames[frame]) current.push_back({candidate, candidate.emission, -1});  // one state per candidate this frame
        if (!layers.empty()) {  // not the first frame: run the Viterbi recursion against the previous layer
            for (auto& state : current) {
                double best = -std::numeric_limits<double>::infinity(); int prior = 0;
                for (std::size_t previous = 0; previous < layers.back().size(); ++previous) {
                    const auto& before = layers.back()[previous];
                    double transition = 0;
                    if (state.candidate && before.candidate) transition = -std::min(cents_distance(state.candidate->frequency, before.candidate->frequency) / width, 3.0);  // pitch-distance penalty between two voiced states
                    else if (state.candidate || before.candidate) transition = -0.55;  // fixed penalty for switching voiced <-> silence
                    const double score = before.score + state.score + transition;  // cumulative path score reaching this state via `previous`
                    if (score > best) { best = score; prior = static_cast<int>(previous); }  // track the best-scoring predecessor
                }
                state.score = best; state.prior = prior;
            }
        }
        layers.push_back(std::move(current));
    }
    std::vector<EngineFrame> output(frames.size());
    if (layers.empty()) return output;
    // Start from the best-scoring state in the final layer, then walk
    // backwards through each layer's stored `prior` pointer to recover the
    // whole winning path.
    int state = static_cast<int>(std::max_element(layers.back().begin(), layers.back().end(), [](const State& a, const State& b) { return a.score < b.score; }) - layers.back().begin());
    for (std::size_t index = layers.size(); index-- > 0;) {
        const auto& selected = layers[index][state];
        output[index].time_seconds = (static_cast<double>(index * config.hop_size + config.window_size / 2) / rate);  // frame's centre time
        if (selected.candidate) { output[index].frequency_hz = selected.candidate->frequency; output[index].confidence = selected.candidate->confidence; }  // voiced state: report the pitch
        state = selected.prior;  // step one frame back along the winning path
        if (state < 0 && index > 0) state = 0;  // guard against an unset prior pointer on the very first frame
    }
    return output;
}
}  // namespace

// Per-session mutable state for every supported engine. Only the fields for
// the currently-selected `id` are actually driven by process_frame, but
// they all live together so switching engines (or reset()) is just a matter
// of rebuilding this one struct.
struct ProductionPitchSession::Impl {
    PitchEngineId id;             // which engine this session runs (yin_v1, vpm_like, hapt_v1, pitch_engine_v2)
    PitchEngineConfig config;

    // --- YIN v1 state: continuity tracking + release/silence bookkeeping ---
    std::optional<Candidate> last_yin;              // last published YIN candidate, used for continuity scoring
    std::optional<Candidate> pending_yin_jump;       // a large downward jump awaiting confirmation
    int pending_yin_confirmations{};                 // how many consecutive frames have confirmed the pending jump
    int silent_yin_estimates{};                      // consecutive frames with no publication, used to fully reset stale state
    double recent_yin_rms_peak{};                    // fast-decaying RMS peak, used for the slow-fade gate
    double yin_release_rms_peak{};                    // slow-decaying RMS peak, used for release recovery detection
    double previous_yin_rms{};                       // previous frame's RMS, for the sharp-fall release detector
    int yin_release_falls{};                          // consecutive sharp RMS falls
    bool yin_release_active{};                        // whether a note release is currently suppressing output

    // --- VPM-like state: contour tracking + gap/attack bookkeeping ---
    std::optional<EngineFrame> vpm_last_strong_contour;  // last confidently-published VPM-like pitch
    std::vector<EngineFrame> vpm_pending_gap;            // buffered frames awaiting gap-bridging confirmation
    double vpm_release_rms_peak{};                       // slow-decaying RMS peak
    double vpm_direct_support_peak{};                    // slow-decaying peak of direct spectral support at the tracked contour
    double previous_vpm_rms{};                           // previous frame's RMS
    int vpm_release_falls{};                             // consecutive sharp RMS falls
    bool vpm_release_suspected{};                        // whether a release is currently suspected
    bool vpm_waiting_for_attack{};                        // whether the tracker is waiting for a fresh, recovered attack before resuming
    VPMSessionDiagnostic vpm_diagnostic;                  // most recent frame's full diagnostic record
    VPMLikeTracker vpm_tracker;                           // the downward-harmonic-jump hysteresis tracker itself

    v2::PitchEngineV2Session v2_session;   // the entire V2 engine's session state lives inside this one object

    // --- Shared gap-bridging state, used by yin_v1 and hapt_v1 via append_bridged ---
    std::vector<EngineFrame> pending_gap;
    std::optional<EngineFrame> last_published;
    bool finished{};

    // --- HAPT state ---
    HAPTConfig hapt_config;
    HAPTTracker hapt_tracker;

    Impl(const PitchEngineId selected, const PitchEngineConfig selected_config)
        : id(selected), config(selected_config), v2_session(selected_config.minimum_rms, 5) {  // 5-frame fixed Viterbi lag for V2
        hapt_config.minimum_frequency_hz = selected_config.minimum_frequency_hz;
        hapt_config.maximum_frequency_hz = selected_config.maximum_frequency_hz;
        hapt_config.minimum_rms = selected_config.minimum_rms;
        hapt_tracker = HAPTTracker(hapt_config);
    }
};

ProductionPitchSession::ProductionPitchSession(
    const PitchEngineId id,
    const PitchEngineConfig config
) : impl_(std::make_unique<Impl>(id, config)) {}

ProductionPitchSession::~ProductionPitchSession() = default;
ProductionPitchSession::ProductionPitchSession(ProductionPitchSession&&) noexcept = default;
ProductionPitchSession& ProductionPitchSession::operator=(ProductionPitchSession&&) noexcept = default;

std::vector<EngineFrame> ProductionPitchSession::process_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time
) {
    if (rate <= 0 || samples.size() < impl_->config.window_size) return {};  // invalid input, or not enough samples for a full window
    if (impl_->finished) throw std::logic_error("Pitch session is finished; call reset before processing more frames");
    if (impl_->id == PitchEngineId::pitch_engine_v2) {
        // V2 has its own fully self-contained session (candidate
        // generation, Viterbi tracking, publication gating); just forward
        // to it and translate its frame type.
        std::vector<EngineFrame> output;
        for (const auto& frame : impl_->v2_session.process_frame(samples, rate, source_time)) {
            output.push_back({frame.time_seconds, frame.frequency_hz, frame.confidence});
        }
        return output;
    }

    const double rms = centered_rms(samples);              // this window's loudness
    const bool eligible = rms >= impl_->config.minimum_rms; // shared silence/signal-eligibility gate
    std::optional<EngineFrame> publication;
    if (impl_->id == PitchEngineId::yin_v1) {
        // A note release falls much faster than the intentional, slow fades
        // used in musical phrasing.  Preserve that distinction causally: two
        // sharp RMS falls arm a release until a new attack has recovered.
        if (impl_->previous_yin_rms > 0 && rms < impl_->previous_yin_rms * .80) {
            ++impl_->yin_release_falls;  // sharp frame-to-frame drop
        } else if (!impl_->yin_release_active) {
            impl_->yin_release_falls = 0;  // no sharp drop (and not already releasing): reset the counter
        }
        impl_->recent_yin_rms_peak = std::max(rms, impl_->recent_yin_rms_peak * .85);   // fast-decaying peak (slow-fade gate)
        impl_->yin_release_rms_peak = std::max(rms, impl_->yin_release_rms_peak * .995); // slow-decaying peak (release recovery threshold)
        if (impl_->yin_release_falls >= 2) impl_->yin_release_active = true;  // two sharp consecutive falls: arm release suppression
        if (impl_->yin_release_active && rms >= impl_->yin_release_rms_peak * .40) {
            impl_->yin_release_active = false;  // signal recovered enough: this was a false alarm
            impl_->yin_release_falls = 0;
        }
        impl_->previous_yin_rms = rms;
        if (impl_->yin_release_active) {
            // Release suppression fully clears continuity state so the next
            // real attack starts fresh rather than continuing a stale
            // contour.
            impl_->last_yin.reset();
            impl_->pending_yin_jump.reset();
            impl_->pending_yin_confirmations = 0;
        }
        if (eligible) {
            const auto candidates = yin_candidates(samples, rate, impl_->config);  // gather every plausible CMND-minimum candidate
            auto choice = causal_yin_choice(
                candidates, impl_->last_yin, samples, rate, impl_->config.maximum_frequency_hz
            );  // pick the best candidate, ghost-aware and continuity-aware
            // The same narrow ambiguity repair exists in the established
            // live YIN path: 2f must be a real YIN minimum with almost equal
            // periodicity and at least three times the measured line energy.
            if (choice) {
                std::optional<Candidate> recovery;
                double recovery_energy = 0;
                for (const auto& lower : candidates) {  // scan every candidate as a potential "lower" (sub-period) anchor
                    const double upper = lower.frequency * 2;  // its octave-up frequency
                    if (upper <= choice->frequency * 1.5 || upper > 900) continue;  // only relevant well above the current choice, and below 900 Hz
                    const auto upper_it = std::find_if(
                        candidates.begin(), candidates.end(), [&](const Candidate& candidate) {
                            return cents_distance(candidate.frequency, upper) <= 55 &&    // must be a genuine CMND-minimum candidate near the octave-up frequency
                                candidate.confidence >= lower.confidence - .05;             // ...with comparable confidence to the lower candidate
                        }
                    );
                    if (upper_it == candidates.end()) continue;  // no real candidate exists at the octave-up frequency
                    const double upper_energy = spectral_energy(samples, rate, upper_it->frequency);
                    if (upper_energy > spectral_energy(samples, rate, lower.frequency) * 3 &&  // decisively louder than the lower candidate
                        upper_energy > recovery_energy) {                                       // and the strongest such recovery found so far
                        recovery = *upper_it;
                        recovery_energy = upper_energy;
                    }
                }
                if (recovery) choice = recovery;  // adopt the recovered octave-up candidate, if one was found
            }
            if (choice) {
                // Promote to a genuine higher-register candidate only when a
                // real candidate exists there. The previous unconditional
                // form invented a synthetic candidate at
                // `candidate.frequency * factor` from bare spectral energy
                // alone, disconnected from anything YIN's own difference
                // function had actually found -- on a closed-pipe clarinet
                // tone the dominant spectral partial can be the third
                // harmonic of a note whose fundamental is still the correct,
                // quieter answer, so comparing that partial's absolute
                // energy against the fundamental's is not evidence the
                // partial is itself a fundamental. Require it to already be
                // a scored YIN candidate (i.e. a genuine CMND minimum)
                // before treating it as one.
                std::optional<Candidate> upper_recovery;
                double strongest_upper_energy = 0;
                for (const auto& candidate : candidates) {  // every candidate is a potential lower anchor to check for a dominant harmonic
                    const double candidate_energy = spectral_energy(
                        samples, rate, candidate.frequency
                    );
                    for (const double factor : {3.0, 2.0}) {  // check the 3rd harmonic before the 2nd (clarinet's dominant closed-pipe partial)
                        const double upper = candidate.frequency * factor;
                        if (upper <= std::max(900.0, choice->frequency) ||
                            upper > impl_->config.maximum_frequency_hz) continue;  // must be well above the current choice and in range
                        const auto upper_it = std::find_if(
                            candidates.begin(), candidates.end(), [&](const Candidate& other) {
                                return cents_distance(other.frequency, upper) <= 55;  // must be a genuine CMND-minimum candidate
                            }
                        );
                        if (upper_it == candidates.end()) continue;  // no real candidate at that harmonic frequency
                        const double upper_energy = spectral_energy(samples, rate, upper_it->frequency);
                        if (upper_energy > candidate_energy * 8 && upper_energy > strongest_upper_energy) {  // decisively dominant, and strongest found so far
                            upper_recovery = *upper_it;
                            strongest_upper_energy = upper_energy;
                        }
                    }
                }
                if (upper_recovery) choice = upper_recovery;  // adopt the recovered higher-harmonic candidate, if one was found
            }
            // Downward-jump hysteresis: a candidate more than 900 cents
            // (nearly an octave and a half) below the last published pitch
            // is held back and requires 3 consecutive confirming frames
            // (each within 360 cents of the pending candidate) before being
            // trusted -- the same defensive pattern as VPMLikeTracker and
            // HAPTTracker, applied here to the legacy YIN v1 path.
            if (choice && impl_->last_yin &&
                choice->frequency < impl_->last_yin->frequency &&
                cents_distance(choice->frequency, impl_->last_yin->frequency) > 900) {
                if (impl_->pending_yin_jump &&
                    cents_distance(choice->frequency, impl_->pending_yin_jump->frequency) < 360) {
                    ++impl_->pending_yin_confirmations;  // same pending drop seen again
                    impl_->pending_yin_jump = choice;
                    if (impl_->pending_yin_confirmations < 3) return {};  // not confirmed enough yet: publish nothing this frame
                    impl_->pending_yin_jump.reset();
                    impl_->pending_yin_confirmations = 0;
                    // fall through: confirmed, `choice` will be published below
                } else {
                    impl_->pending_yin_jump = choice;      // new (or first) pending candidate drop
                    impl_->pending_yin_confirmations = 1;
                    return {};  // not confirmed at all yet: publish nothing this frame
                }
            } else {
                impl_->pending_yin_jump.reset();          // ordinary movement: clear any pending-jump state
                impl_->pending_yin_confirmations = 0;
            }
            // Final publication gate: suppress a below-confidence candidate
            // during what looks like a slow, non-release fade-out (RMS well
            // under its recent peak) -- the same "trailing reverb, not a
            // real note" reasoning as the V2 session's scored_candidates.
            if (choice && !impl_->yin_release_active && !(choice->confidence < .90 &&
                rms < impl_->recent_yin_rms_peak * .35)) {
                publication = EngineFrame{source_time, choice->frequency, choice->confidence};
                impl_->last_yin = choice;          // becomes the new continuity anchor
                impl_->silent_yin_estimates = 0;   // reset the "stale state" counter
            }
        }
        if (!publication) {
            ++impl_->silent_yin_estimates;  // count consecutive non-publishing frames
            if (impl_->silent_yin_estimates >= 30) {
                // Long enough silence/uncertainty that the tracked contour
                // is no longer meaningful: fully reset continuity state.
                impl_->last_yin.reset();
                impl_->pending_yin_jump.reset();
                impl_->pending_yin_confirmations = 0;
                impl_->pending_gap.clear();
            }
        }
    } else if (impl_->id == PitchEngineId::vpm_like) {
        auto& diagnostic = impl_->vpm_diagnostic;
        diagnostic = {};  // start a fresh diagnostic record for this frame
        diagnostic.input_time_seconds = source_time;
        diagnostic.rms = rms;
        diagnostic.signal_eligible = eligible;
        if (impl_->vpm_last_strong_contour) {
            diagnostic.last_strong_contour_hz =
                impl_->vpm_last_strong_contour->frequency_hz;
        }

        // Release/decay detection, same pattern as the YIN branch: a slow-
        // decaying RMS peak sets the recovery bar, and consecutive sharp
        // falls (unless the envelope is still close to that peak) arm
        // suspicion of a release.
        impl_->vpm_release_rms_peak = std::max(rms, impl_->vpm_release_rms_peak * .995);
        diagnostic.recent_rms_peak = impl_->vpm_release_rms_peak;
        diagnostic.rms_to_peak_ratio = impl_->vpm_release_rms_peak > 0
            ? rms / impl_->vpm_release_rms_peak : 0;
        if (impl_->previous_vpm_rms > 0 && rms < impl_->previous_vpm_rms * .85) {
            ++impl_->vpm_release_falls;  // sharp frame-to-frame drop
        } else if (!impl_->vpm_release_suspected &&
            (impl_->vpm_release_falls < 2 || diagnostic.rms_to_peak_ratio >= .60)) {
            impl_->vpm_release_falls = 0;  // no sharp drop, and not close to arming release suspicion: reset the counter
        }
        impl_->previous_vpm_rms = rms;

        // Two confidence tiers: `weak_estimate` uses a looser confidence
        // floor (0.38) purely to feed the diagnostic/contour-hold logic
        // below; `normal_estimate` requires a much higher bar (0.80) before
        // being treated as trustworthy enough to actually publish or update
        // the tracked contour.
        std::optional<VPMLikePitch> weak_estimate;
        std::optional<VPMLikePitch> normal_estimate;
        if (eligible) {
            std::vector<double> copied(samples.begin(), samples.end());  // VPM-like operates on double samples
            VPMLikeConfig weak_config;
            weak_config.minimum_frequency_hz = impl_->config.minimum_frequency_hz;
            weak_config.maximum_frequency_hz = std::max(1650.0, impl_->config.maximum_frequency_hz);
            weak_config.minimum_rms = impl_->config.minimum_rms;
            weak_config.minimum_output_confidence = .38;
            if (impl_->config.enable_vpm_diagnostics) {
                const auto estimator = diagnose_vpm_like_pitch(copied, rate, weak_config);  // full diagnostic run, more expensive
                diagnostic.strongest_periodicity = estimator.strongest_periodicity;
                weak_estimate = estimator.pitch;
            } else {
                weak_estimate = estimate_vpm_like_pitch(copied, rate, weak_config);  // fast path, no diagnostic bookkeeping
                diagnostic.strongest_periodicity = weak_estimate
                    ? weak_estimate->confidence : 0;
            }
            if (weak_estimate) {
                diagnostic.weak_estimate_hz = weak_estimate->frequency_hz;
                if (weak_estimate->confidence >= .80) {
                    normal_estimate = weak_estimate;  // promote to the trustworthy tier
                    diagnostic.normal_estimate_hz = normal_estimate->frequency_hz;
                }
            }
        }

        // Direct spectral support at the *currently tracked contour's own
        // frequency*: this is what actually detects a release, distinct
        // from the RMS-based falls above -- the overall envelope can stay
        // loud (room reverb, other instruments) even after the tracked
        // note's own fundamental has genuinely disappeared from the
        // spectrum.
        double direct_support = 0;
        if (impl_->vpm_last_strong_contour &&
            impl_->vpm_last_strong_contour->frequency_hz) {
            direct_support = spectral_amplitude(
                samples, rate, *impl_->vpm_last_strong_contour->frequency_hz
            );
            impl_->vpm_direct_support_peak = std::max(
                direct_support, impl_->vpm_direct_support_peak * .995
            );  // slow-decaying peak of that support, used as the "lost" comparison baseline
        }
        diagnostic.direct_fundamental_support = direct_support;
        diagnostic.recent_direct_support_peak = impl_->vpm_direct_support_peak;
        const bool direct_support_lost = impl_->vpm_last_strong_contour &&
            (direct_support < .005 ||                                            // essentially no energy left at the tracked frequency, or
             (impl_->vpm_direct_support_peak > 0 &&
              direct_support < impl_->vpm_direct_support_peak * .35));            // it has decayed well below its own recent peak
        if (impl_->vpm_last_strong_contour && impl_->vpm_release_falls >= 2 &&
            diagnostic.rms_to_peak_ratio < .35 && direct_support_lost) {
            impl_->vpm_release_suspected = true;  // all three signals agree: this looks like a genuine release
        }
        diagnostic.release_suspected = impl_->vpm_release_suspected;

        // Fully clears the tracked contour and every piece of associated
        // state -- used both when a release is confirmed and when the
        // signal drops out entirely.
        const auto clear_vpm_contour = [&] {
            impl_->vpm_pending_gap.clear();
            impl_->vpm_last_strong_contour.reset();
            impl_->vpm_release_suspected = false;
            impl_->vpm_release_falls = 0;
            impl_->vpm_direct_support_peak = 0;
            impl_->vpm_tracker.reset();
        };
        // Buffers a tentative "repeat the last known pitch" frame for a
        // short dropout, or gives up and clears the contour once the gap
        // has run too long (or there is nothing to bridge from).
        const auto queue_vpm_gap = [&] {
            if (!impl_->vpm_last_strong_contour ||
                impl_->vpm_pending_gap.size() >= kMaximumBridgeFrames) {
                clear_vpm_contour();
                impl_->vpm_waiting_for_attack = true;  // require a fresh, recovered attack before resuming
                diagnostic.publication_reason = "gap_expired";
                return;
            }
            const auto& anchor = *impl_->vpm_last_strong_contour;
            impl_->vpm_pending_gap.push_back({
                source_time, anchor.frequency_hz, anchor.confidence
            });
            diagnostic.publication_reason = impl_->vpm_release_suspected
                ? "release_pending" : "dropout_pending";
        };

        if (!eligible) {
            // Crossing the fixed RMS gate is enough to end the current
            // anchor, but a gradual musical trough is not by itself release
            // evidence.  Require a recovered attack only when the causal
            // release detector (or an expired gap) had already armed it.
            const bool require_recovered_attack = impl_->vpm_release_suspected ||
                impl_->vpm_waiting_for_attack;
            clear_vpm_contour();
            impl_->vpm_waiting_for_attack = require_recovered_attack;
            diagnostic.publication_reason = "rms_gate_closed";
            diagnostic.pending_gap_frames = 0;
            return {};
        }

        if (impl_->vpm_waiting_for_attack) {
            // Held in this state until a confident estimate arrives *and*
            // the envelope has climbed back to at least 40% of its recent
            // peak -- both signals must agree a genuine new attack, not
            // just a noisy blip, has started.
            if (!normal_estimate || diagnostic.rms_to_peak_ratio < .40) {
                diagnostic.publication_reason = "waiting_for_attack";
                return {};
            }
            impl_->vpm_waiting_for_attack = false;
            impl_->vpm_release_falls = 0;
            impl_->vpm_tracker.reset();  // fresh attack: don't let the tracker's old hysteresis state leak into it
        }

        std::vector<EngineFrame> vpm_output;
        if (impl_->vpm_release_suspected) {
            // While a release is suspected, only two outcomes are possible
            // this frame: the envelope recovers back onto the *same*
            // contour (a false alarm -- e.g. a brief dip in a sustained
            // note), or it recovers onto a genuinely *different* contour
            // (a new attack right after the old note actually ended).
            // Anything else keeps queuing the gap/waiting.
            const auto recovery = normal_estimate ? normal_estimate :
                (weak_estimate && weak_estimate->confidence >= .70
                    ? weak_estimate : std::nullopt);  // accept a slightly weaker estimate for same-contour recovery specifically
            const bool envelope_recovered = diagnostic.rms_to_peak_ratio >= .40;
            if (envelope_recovered && recovery && impl_->vpm_last_strong_contour &&
                impl_->vpm_last_strong_contour->frequency_hz &&
                cents_distance(recovery->frequency_hz,
                    *impl_->vpm_last_strong_contour->frequency_hz) <= 90) {
                // False alarm: same contour recovered. Release the whole
                // buffered gap run and resume tracking from a clean state.
                vpm_output = impl_->vpm_pending_gap;
                diagnostic.bridged_frames = vpm_output.size();
                impl_->vpm_pending_gap.clear();
                impl_->vpm_release_suspected = false;
                impl_->vpm_waiting_for_attack = false;
                impl_->vpm_release_falls = 0;
                impl_->vpm_tracker.reset();
                const auto decision = impl_->vpm_tracker.process(recovery);
                if (decision) {
                    publication = EngineFrame{
                        source_time, decision->frequency_hz, decision->confidence
                    };
                    vpm_output.push_back(*publication);
                }
                if (normal_estimate && publication) {
                    impl_->vpm_last_strong_contour = publication;
                    impl_->vpm_direct_support_peak = std::max(
                        spectral_amplitude(samples, rate, *publication->frequency_hz),
                        impl_->vpm_direct_support_peak * .995
                    );
                }
                diagnostic.publication_reason = "same_contour_recovery";
            } else if (envelope_recovered && normal_estimate &&
                impl_->vpm_last_strong_contour &&
                impl_->vpm_last_strong_contour->frequency_hz &&
                cents_distance(normal_estimate->frequency_hz,
                    *impl_->vpm_last_strong_contour->frequency_hz) > 90) {
                // Genuine new attack on a different pitch: the old note
                // really did end. Clear the old contour and start fresh
                // rather than trying to bridge across it.
                clear_vpm_contour();
                impl_->vpm_waiting_for_attack = false;
                const auto decision = impl_->vpm_tracker.process(normal_estimate);
                if (decision && decision->frequency_hz <= impl_->config.maximum_frequency_hz) {
                    publication = EngineFrame{
                        source_time, decision->frequency_hz, decision->confidence
                    };
                    vpm_output.push_back(*publication);
                    impl_->vpm_last_strong_contour = publication;
                    impl_->vpm_direct_support_peak = spectral_amplitude(
                        samples, rate, *publication->frequency_hz
                    );
                }
                diagnostic.publication_reason = "different_contour_attack";
            } else {
                // Neither recovery pattern matched yet: keep waiting,
                // buffering a tentative gap-filler frame.
                impl_->vpm_tracker.reset();
                queue_vpm_gap();
            }
            diagnostic.release_suspected = impl_->vpm_release_suspected;
            diagnostic.pending_gap_frames = impl_->vpm_pending_gap.size();
            return vpm_output;
        }

        if (normal_estimate) {
            // If the new estimate drops far (>650 cents) below the
            // currently tracked contour, compute how much stronger the old
            // (upper) contour's own direct spectral support still is
            // relative to the new, lower estimate -- this is exactly the
            // veto signal VPMLikeTracker::process uses to decide whether to
            // trust the drop immediately or hold it back for confirmation.
            std::optional<double> upper_to_estimate_ratio;
            if (impl_->vpm_last_strong_contour &&
                impl_->vpm_last_strong_contour->frequency_hz &&
                normal_estimate->frequency_hz <
                    *impl_->vpm_last_strong_contour->frequency_hz &&
                cents_distance(normal_estimate->frequency_hz,
                    *impl_->vpm_last_strong_contour->frequency_hz) > 650) {
                const double lower_support = spectral_amplitude(
                    samples, rate, normal_estimate->frequency_hz
                );
                upper_to_estimate_ratio = direct_support /
                    std::max(1e-9, lower_support);
                diagnostic.established_upper_to_estimate_ratio =
                    upper_to_estimate_ratio;
            }
            const auto decision = impl_->vpm_tracker.process(
                normal_estimate, upper_to_estimate_ratio
            );  // apply the downward-harmonic-jump hysteresis
            if (decision && decision->frequency_hz <= impl_->config.maximum_frequency_hz) {
                publication = EngineFrame{
                    source_time, decision->frequency_hz, decision->confidence
                };
                diagnostic.harmonic_veto = cents_distance(
                    decision->frequency_hz, normal_estimate->frequency_hz
                ) > 90;  // the tracker overrode the raw estimate: this frame was vetoed/held back
                if (!impl_->vpm_pending_gap.empty()) {
                    if (impl_->vpm_last_strong_contour &&
                        impl_->vpm_last_strong_contour->frequency_hz &&
                        cents_distance(decision->frequency_hz,
                            *impl_->vpm_last_strong_contour->frequency_hz) <= 90) {
                        vpm_output = impl_->vpm_pending_gap;  // same contour as before the gap: release the buffered gap-fill frames
                        diagnostic.bridged_frames = vpm_output.size();
                    }
                    impl_->vpm_pending_gap.clear();
                }
                vpm_output.push_back(*publication);
                if (!diagnostic.harmonic_veto) {
                    // Only a genuinely trusted (non-vetoed) publication
                    // updates the tracked contour and its support peak.
                    impl_->vpm_last_strong_contour = publication;
                    impl_->vpm_direct_support_peak = std::max(
                        spectral_amplitude(samples, rate, *publication->frequency_hz),
                        impl_->vpm_direct_support_peak * .995
                    );
                }
                diagnostic.publication_reason = diagnostic.harmonic_veto
                    ? "harmonic_veto" :
                    (diagnostic.bridged_frames ? "dropout_bridged" : "normal_contour");
            }
        } else if (weak_estimate && impl_->vpm_last_strong_contour &&
            impl_->vpm_last_strong_contour->frequency_hz && direct_support >= .005 &&
            cents_distance(weak_estimate->frequency_hz,
                *impl_->vpm_last_strong_contour->frequency_hz) <= 90) {
            // No confident new estimate, but a weak one agrees with the
            // still-supported tracked contour: republish the tracked
            // contour's own frequency rather than following the noisier
            // weak estimate.
            publication = EngineFrame{
                source_time,
                impl_->vpm_last_strong_contour->frequency_hz,
                weak_estimate->confidence,
            };
            impl_->vpm_pending_gap.clear();
            vpm_output.push_back(*publication);
            diagnostic.publication_reason = "weak_contour_hold";
        } else {
            // No usable estimate at all this frame: buffer a gap-filler
            // (or give up and clear the contour if the gap has run too
            // long).
            impl_->vpm_tracker.process(std::nullopt);
            queue_vpm_gap();
        }
        diagnostic.pending_gap_frames = impl_->vpm_pending_gap.size();
        return vpm_output;
    } else if (impl_->id == PitchEngineId::hapt_v1) {
        // HAPT's own onset/decay recovery and inter-harmonic veto live in the
        // stateless estimator; HAPTTracker owns the RMS release detector and
        // the downward-harmonic-jump confirmation delay (the one piece of
        // state shared verbatim with the offline/tournament trace tool, so
        // both see identical release behaviour). Below the hard minimum_rms
        // floor there is no signal at all, so a full reset is simpler than
        // feeding the tracker a sub-floor RMS value.
        // HAPT's own onset/decay recovery and inter-harmonic veto live
        // inside estimate_hapt_pitch (hapt.cpp); HAPTTracker layers the RMS
        // release detector and downward-harmonic-jump confirmation delay
        // on top of that per-frame estimate.
        if (eligible) {
            const auto estimate = estimate_hapt_pitch(
                samples, rate, impl_->hapt_config, impl_->hapt_tracker.published_frequency_hz()
            );  // stateless per-frame HAPT estimate, given the tracker's current published pitch as continuity context
            const auto tracked = impl_->hapt_tracker.process(estimate, rms);  // apply release detection + jump hysteresis
            if (tracked) {
                publication = EngineFrame{source_time, tracked->frequency_hz, tracked->confidence};
            }
        } else {
            impl_->hapt_tracker.reset();  // below the hard RMS floor: full reset rather than feeding a sub-floor RMS
        }
    }

    // Shared gap-bridging tail for the yin_v1 and hapt_v1 engines (VPM-like
    // and V2 already returned above, using their own dedicated bridging
    // logic): buffers/repeats the last published pitch across short
    // dropouts, with an engine-specific confidence bar.
    std::vector<EngineFrame> output;
    append_bridged(
        output, impl_->pending_gap, impl_->last_published, publication, eligible,
        static_cast<double>(impl_->config.hop_size) / rate,
        impl_->id == PitchEngineId::yin_v1 ? .55 :
            (impl_->id == PitchEngineId::hapt_v1 ? .60 : .70),  // engine-specific publication confidence floor
        impl_->id == PitchEngineId::hapt_v1 ? .30 : -1.0        // HAPT alone relaxes the weaker gap endpoint's floor
    );
    return output;
}

// Flushes any engine-specific end-of-stream state. Only V2 needs this (its
// fixed-lag Viterbi tracker buffers several frames of look-ahead that must
// be drained); the other engines are already fully causal frame-by-frame.
std::vector<EngineFrame> ProductionPitchSession::finish() {
    if (impl_->finished) return {};
    impl_->finished = true;
    if (impl_->id != PitchEngineId::pitch_engine_v2) return {};
    std::vector<EngineFrame> output;
    for (const auto& frame : impl_->v2_session.finish()) {
        output.push_back({frame.time_seconds, frame.frequency_hz, frame.confidence});
    }
    return output;
}

const VPMSessionDiagnostic& ProductionPitchSession::last_vpm_diagnostic() const {
    return impl_->vpm_diagnostic;
}

void ProductionPitchSession::reset() {
    const auto id = impl_->id;
    const auto config = impl_->config;
    impl_ = std::make_unique<Impl>(id, config);  // rebuild from scratch, preserving only the engine choice and configuration
}

void ProductionPitchSession::set_minimum_rms(const double minimum_rms) {
    if (!std::isfinite(minimum_rms) || minimum_rms < 0) return;  // reject a nonsensical value
    impl_->config.minimum_rms = minimum_rms;
    impl_->v2_session.set_minimum_rms(minimum_rms);  // keep V2's own copy in sync
    impl_->hapt_config.minimum_rms = minimum_rms;     // keep HAPT's own copy in sync
}

PitchEngine::PitchEngine(PitchEngineId id, PitchEngineProfile profile, PitchEngineConfig config) : id_(id), profile_(profile), config_(config) {}
void PitchEngine::reset() { buffered_samples_.clear(); sample_rate_ = 0; }
// Accumulates mono samples for later offline analysis; samples at a
// different sample rate than the first push are silently dropped (a
// session is expected to be single-sample-rate).
void PitchEngine::push(std::span<const float> mono_samples, double sample_rate) { if (sample_rate_ == 0) sample_rate_ = sample_rate; if (std::abs(sample_rate - sample_rate_) < 0.001) buffered_samples_.insert(buffered_samples_.end(), mono_samples.begin(), mono_samples.end()); }
std::vector<EngineFrame> PitchEngine::finish() { auto result = analyse(buffered_samples_, sample_rate_); reset(); return result; }
// Runs a fresh ProductionPitchSession over the whole buffer, frame by frame
// (as if streaming live), collecting every published frame plus the final
// flush from session.finish().
namespace {

// Per-engine transition width for the offline path refinement, in cents.
// Calibrated against the Şükrü Tunar listener verdicts: a narrower width
// suppresses isolated jumps harder, but too narrow also fights genuine fast
// runs.  Pitch Engine v2 already carries a five-frame Viterbi of its own, so
// it needs (and tolerates) a looser width than the causal engines.
double offline_transition_width_cents(const PitchEngineId id) {
    return id == PitchEngineId::pitch_engine_v2 ? 250.0 : 150.0;
}

// Spectral evidence sets an alternative's *price*, it does not gate admission.
// Gating was wrong: on the frames that actually needed repair the correct
// fundamental often measures below 2% of the family's strongest member -- that
// is precisely why the causal engine got them wrong, and precisely the case
// where only the path carries the information.  So every harmonic alternative
// stays available, and one with no spectral backing simply costs more.
constexpr double kOfflineUnsupportedFloor = 0.30;
// Alternatives enter the path search below the causal decision's own score, so
// a frame only moves when path continuity -- not local evidence -- demands it.
constexpr double kOfflineAlternativeDiscount = 0.72;
// Published frames further apart than this are treated as separate runs: no
// continuity is implied across an articulation gap.
constexpr double kOfflineSegmentGapSeconds = 0.030;
// Transition cost is quadratic in cents so that a single 1200-cent excursion
// pays far more than the many small steps of a real run.  Capped so one wild
// frame cannot dominate the whole path score.
constexpr double kOfflineMaximumTransition = 12.0;

// A published run this short, with silence on both sides and no better
// evidence than this, is a stray point rather than a note.
constexpr std::size_t kOfflineStrayMaximumFrames = 7;
// Silence required on *both* sides.  This is what keeps the rule off real
// ornaments: a çarpma is attached to the note it decorates, not marooned in
// silence, so it never clears this test.
constexpr double kOfflineStrayIsolationSeconds = 0.040;
// VPM-like's own publication bar.  On every stray point the listener marked,
// VPM-like was the engine that correctly stayed quiet, and the runs the others
// published peaked at 0.66-0.81 confidence.  Holding a short isolated run to
// that same bar is the rule; it is not a number fitted to those frames.
constexpr double kOfflineStrayConfidence = 0.80;

// Drops short, isolated, low-confidence runs from an offline track.
std::vector<EngineFrame> drop_offline_stray_runs(const std::vector<EngineFrame>& track) {
    std::vector<std::pair<std::size_t, std::size_t>> runs;  // [first, last] over voiced frames
    std::vector<std::size_t> voiced;
    for (std::size_t index = 0; index < track.size(); ++index) {
        if (track[index].frequency_hz && *track[index].frequency_hz > 0) voiced.push_back(index);
    }
    if (voiced.size() < 2) return track;
    std::size_t begin = 0;
    for (std::size_t position = 1; position <= voiced.size(); ++position) {
        const bool split = position == voiced.size() ||
            track[voiced[position]].time_seconds - track[voiced[position - 1]].time_seconds > 0.012;
        if (split) { runs.push_back({begin, position - 1}); begin = position; }
    }
    std::vector<bool> drop(track.size(), false);
    for (std::size_t run = 0; run < runs.size(); ++run) {
        const auto [first, last] = runs[run];
        if (last - first + 1 > kOfflineStrayMaximumFrames) continue;
        const double before = run == 0 ? std::numeric_limits<double>::infinity()
            : track[voiced[first]].time_seconds - track[voiced[runs[run - 1].second]].time_seconds;
        const double after = run + 1 == runs.size() ? std::numeric_limits<double>::infinity()
            : track[voiced[runs[run + 1].first]].time_seconds - track[voiced[last]].time_seconds;
        if (before < kOfflineStrayIsolationSeconds || after < kOfflineStrayIsolationSeconds) continue;
        double peak = 0;
        for (std::size_t position = first; position <= last; ++position) {
            peak = std::max(peak, track[voiced[position]].confidence);
        }
        if (peak >= kOfflineStrayConfidence) continue;
        for (std::size_t position = first; position <= last; ++position) drop[voiced[position]] = true;
    }
    std::vector<EngineFrame> kept;
    kept.reserve(track.size());
    for (std::size_t index = 0; index < track.size(); ++index) {
        if (!drop[index]) kept.push_back(track[index]);
    }
    return kept;
}

// Offline (non-causal) harmonic path refinement over the causal baseline.
//
// This is the piece `PitchEngineProfile::offline_track` was reserved for.  The
// causal engines must decide each frame with no future context, and that is
// exactly where they lose: measured on the listener verdicts, 33 of 47 marked
// octave errors last only 1-3 frames (median 2, longest 9) in the middle of
// otherwise correct tracking.  pYIN does not make those errors because it
// decodes a path over the whole recording, where an isolated 1200-cent
// excursion can never repay its transition cost.
//
// The live path is untouched: `analyse_causal` and every `ProductionPitchSession`
// keep their latency contract.  Only the Study/offline entry point refines.
//
// `resolve_track` above is the generic resolver, but it assumes one candidate
// layer per hop and reconstructs frame times from the hop index.  A published
// track is sparse -- gated, bridged and flushed frames only -- so this pass
// runs its own search over exactly the frames that were published, preserving
// their times and their voiced/unvoiced decisions untouched.
std::vector<EngineFrame> refine_offline_harmonics(
    const std::vector<EngineFrame>& baseline,
    const std::span<const float> samples,
    const double rate,
    const PitchEngineConfig& config,
    const PitchEngineId id
) {
    struct Alternative { double frequency; double confidence; double emission; };
    struct Layer { std::size_t index; std::vector<Alternative> options; };

    const double width = offline_transition_width_cents(id);
    const auto window = static_cast<std::int64_t>(config.window_size);

    std::vector<Layer> layers;
    for (std::size_t index = 0; index < baseline.size(); ++index) {
        const auto& frame = baseline[index];
        if (!frame.frequency_hz || *frame.frequency_hz <= 0) continue;  // voicing is not revisited here
        const double published = *frame.frequency_hz;
        const double confidence = std::max(frame.confidence, 1e-3);
        std::vector<Alternative> options{
            {published, confidence, std::log(confidence)}  // the causal decision always competes
        };
        // Locate this frame's own analysis window so alternatives are judged
        // against the audio the engine actually saw.
        const auto start = static_cast<std::int64_t>(std::llround(frame.time_seconds * rate)) - window / 2;
        if (start >= 0 && start + window <= static_cast<std::int64_t>(samples.size())) {
            const auto view = samples.subspan(static_cast<std::size_t>(start), config.window_size);
            // Measure the whole harmonic family first and judge each member
            // against the strongest of them, never against the published line.
            // The published line is the one under suspicion, and on a clarinet
            // a true fundamental is routinely weaker than its own third
            // harmonic -- gating on the published line's energy threw the
            // correct answer away exactly in the frames that needed it.
            struct Probe { double frequency; double energy; };
            std::vector<Probe> family{{published, spectral_energy(view, rate, published)}};
            for (const double ratio : {1.0 / 3.0, 0.5, 2.0, 3.0}) {
                const double alternative = published * ratio;
                if (alternative < config.minimum_frequency_hz ||
                    alternative > config.maximum_frequency_hz) continue;
                family.push_back({alternative, spectral_energy(view, rate, alternative)});
            }
            double strongest = 0;
            for (const auto& probe : family) strongest = std::max(strongest, probe.energy);
            for (std::size_t member = 1; member < family.size(); ++member) {
                const double support = strongest > 0 ? family[member].energy / strongest : 0.0;
                const double backing = kOfflineUnsupportedFloor +
                    (1.0 - kOfflineUnsupportedFloor) * std::clamp(support, 0.0, 1.0);
                const double scaled = confidence * kOfflineAlternativeDiscount * backing;
                options.push_back({family[member].frequency, scaled, std::log(std::max(scaled, 1e-6))});
            }
        }
        layers.push_back({index, std::move(options)});
    }
    if (layers.size() < 3) return baseline;  // nothing a path can say

    std::vector<std::vector<double>> score(layers.size());
    std::vector<std::vector<int>> prior(layers.size());
    for (std::size_t layer = 0; layer < layers.size(); ++layer) {
        const auto& options = layers[layer].options;
        score[layer].assign(options.size(), 0.0);
        prior[layer].assign(options.size(), -1);
        if (layer == 0) {
            for (std::size_t option = 0; option < options.size(); ++option) {
                score[layer][option] = options[option].emission;
            }
            continue;
        }
        const double elapsed =
            baseline[layers[layer].index].time_seconds - baseline[layers[layer - 1].index].time_seconds;
        const bool continuous = elapsed <= kOfflineSegmentGapSeconds;
        const auto& before = layers[layer - 1].options;
        for (std::size_t option = 0; option < options.size(); ++option) {
            double best = -std::numeric_limits<double>::infinity();
            int chosen = 0;
            for (std::size_t previous = 0; previous < before.size(); ++previous) {
                double transition = 0.0;
                if (continuous) {
                    const double distance =
                        cents_distance(options[option].frequency, before[previous].frequency) / width;
                    transition = -std::min(distance * distance, kOfflineMaximumTransition);
                }
                const double total = score[layer - 1][previous] + transition;
                if (total > best) { best = total; chosen = static_cast<int>(previous); }
            }
            score[layer][option] = best + options[option].emission;
            prior[layer][option] = chosen;
        }
    }

    auto refined = baseline;
    auto cursor = static_cast<int>(std::max_element(score.back().begin(), score.back().end()) - score.back().begin());
    for (std::size_t layer = layers.size(); layer-- > 0;) {
        const auto& option = layers[layer].options[static_cast<std::size_t>(cursor)];
        auto& frame = refined[layers[layer].index];
        frame.frequency_hz = option.frequency;
        frame.confidence = option.confidence;
        cursor = prior[layer][static_cast<std::size_t>(cursor)];
        if (cursor < 0 && layer > 0) cursor = 0;
    }
    return refined;
}

}  // namespace

std::vector<EngineFrame> PitchEngine::analyse_causal(
    const std::span<const float> samples,
    const double rate
) {
    if (rate <= 0 || samples.size() < config_.window_size) return {};
    ProductionPitchSession session(id_, config_);
    std::vector<EngineFrame> output;
    for (std::size_t start = 0; start + config_.window_size <= samples.size(); start += config_.hop_size) {  // slide a fixed-size window across the buffer
        const double time = (static_cast<double>(start) + config_.window_size / 2.0) / rate;  // this window's centre time
        auto published = session.process_frame(samples.subspan(start, config_.window_size), rate, time);
        output.insert(output.end(), published.begin(), published.end());
    }
    auto final = session.finish();  // flush any buffered look-ahead (V2's Viterbi tail)
    output.insert(output.end(), final.begin(), final.end());
    return output;
}

// Public offline entry point. For the offline_track profile this runs the
// non-causal harmonic path refinement over the causal baseline; every other
// profile is returned unchanged, so the live contract is unaffected.
std::vector<EngineFrame> PitchEngine::analyse(
    const std::span<const float> samples,
    const double rate
) {
    auto baseline = analyse_causal(samples, rate);
    if (profile_ != PitchEngineProfile::offline_track || baseline.empty()) return baseline;

    return drop_offline_stray_runs(
        refine_offline_harmonics(baseline, samples, rate, config_, id_)
    );
}
}  // namespace klarivision::core
