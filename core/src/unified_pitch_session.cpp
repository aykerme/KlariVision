#include "klarivision/core/unified_pitch_session.hpp"

#include "klarivision/core/frame_spectrum.hpp"
#include "klarivision/core/mpm.hpp"
#include "klarivision/core/pyin_ladder.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <deque>
#include <numeric>

namespace klarivision::core {
namespace {

/// Root-mean-square of the most recent hop, used only as a cheap eligibility
/// gate. Voicing itself comes out of the candidate ladder's leftover
/// probability mass, not from energy: a soft but perfectly periodic note is
/// voiced, and a loud but aperiodic breath is not.
double window_rms(const std::span<const float> samples) {
    if (samples.empty()) return 0.0;
    auto sum = 0.0;
    for (const auto sample : samples) sum += static_cast<double>(sample) * sample;
    return std::sqrt(sum / static_cast<double>(samples.size()));
}

bool inside_estimator_range(const double frequency_hz) {
    return frequency_hz >= unified::kEstimatorMinimumHz &&
           frequency_hz <= unified::kEstimatorMaximumHz;
}

/// Merge a frequency into an accumulating candidate list, keeping the stronger
/// probability when two proposals land within a few cents of one another.
void merge_candidate(
    std::vector<std::pair<double, double>>& merged,
    const double frequency_hz,
    const double probability
) {
    if (!inside_estimator_range(frequency_hz)) return;
    for (auto& [existing_hz, existing_probability] : merged) {
        const auto cents = std::abs(1200.0 * std::log2(frequency_hz / existing_hz));
        if (cents <= unified::kCandidateMergeCents) {
            existing_probability = std::max(existing_probability, probability);
            return;
        }
    }
    merged.emplace_back(frequency_hz, probability);
}

/// Emission score for one candidate, in log-probability units to match the
/// decoder's transition model.
///
/// Periodicity says a period fits; the spectral terms say whether anything is
/// actually sounding there. The two are combined as a product, not a sum, and
/// the difference is not cosmetic. Under a weighted sum, a harmonic relative
/// injected as a speculative competitor -- deliberately given only a small
/// share of its parent's periodicity -- can still reach nearly the parent's
/// score on spectral support alone, because for a harmonically rich tone the
/// relatives genuinely are well supported. Every frame then looks contested
/// and the engine abstains on all of them. A product keeps periodicity
/// decisive: a competitor holding a twentieth of the parent's period
/// probability scores a twentieth as well no matter how good the spectrum
/// looks at its frequency, and contest mass only becomes significant when the
/// evidence really is ambiguous.
double emission_for(const double period_probability, const HarmonicEvidence& evidence) {
    // Convex blend, so support stays in [0, 1] and the product's scale is the
    // periodicity's own.
    constexpr auto total_weight = unified::kSwipeWeight + unified::kTwmWeight;
    const auto support = (unified::kSwipeWeight * evidence.swipe_prime_support +
                          unified::kTwmWeight * evidence.twm_score) / total_weight;
    const auto base = period_probability * support * (1.0 - evidence.ghost_penalty);
    return std::log(std::max(base, 1e-6));
}

/// Fixed-capacity ring over the analysis history.
///
/// The window is only ever read once per hop, so shifting a 3072-sample vector
/// on every incoming sample -- which is what a plain vector erase/push_back
/// pair does -- would cost roughly 150 million moves per second of audio for
/// no benefit. Writing into a ring and linearising once per hop costs about
/// six moves per sample instead.
class HistoryRing {
public:
    HistoryRing() : samples_(unified::kHistorySamples, 0.0f),
                    linear_(unified::kHistorySamples, 0.0f) {}

    void push(const float sample) {
        samples_[write_index_] = sample;
        write_index_ = (write_index_ + 1) % samples_.size();
    }

    /// Oldest-to-newest view of the whole history. Valid until the next call.
    [[nodiscard]] std::span<const float> window() {
        const auto tail = samples_.size() - write_index_;
        std::copy(samples_.begin() + static_cast<std::ptrdiff_t>(write_index_),
                  samples_.end(), linear_.begin());
        std::copy(samples_.begin(),
                  samples_.begin() + static_cast<std::ptrdiff_t>(write_index_),
                  linear_.begin() + static_cast<std::ptrdiff_t>(tail));
        return linear_;
    }

    void clear() {
        std::fill(samples_.begin(), samples_.end(), 0.0f);
        write_index_ = 0;
    }

private:
    std::vector<float> samples_;
    std::vector<float> linear_;
    std::size_t write_index_{0};
};

}  // namespace

UnifiedFrameEvidence unified_frame_evidence(
    const std::span<const float> history,
    const double sample_rate,
    const double source_time_seconds,
    const PitchEngineConfig& config,
    const ParityEstimate& parity,
    const std::span<const float> lookahead_samples
) {
    UnifiedFrameEvidence frame{};
    frame.time_seconds = source_time_seconds;
    frame.parity_index = parity.index;

    const auto mid_window = history.size() >= unified::kMidWindowSamples
        ? history.last(unified::kMidWindowSamples)
        : history;
    frame.rms = window_rms(mid_window);
    frame.signal_eligible = frame.rms >= config.minimum_rms;

    const auto gate = std::max(config.minimum_rms, 1e-9);
    const auto loudness = frame.rms / gate;
    if (loudness < unified::kHardSilenceRatio) {
        // Far below the gate there is genuinely nothing to explain, and saying
        // so confidently costs nothing.
        frame.unvoiced_emission = std::log(0.99);
        return frame;
    }
    // Between the hard-silence floor and the gate the frame is analysed like
    // any other, but its silence hypothesis is weighted by how quiet it is.
    // The decoder then bridges the quiet middle of a held note, while a true
    // rest still wins because every frame across it agrees on silence.
    const auto quietness_bias = std::clamp(1.0 - loudness, 0.0, 1.0);

    PyinLadderConfig ladder_config{};
    ladder_config.minimum_frequency_hz =
        std::min(config.minimum_frequency_hz, unified::kEstimatorMinimumHz);
    ladder_config.maximum_frequency_hz =
        std::max(config.maximum_frequency_hz, unified::kEstimatorMaximumHz);
    const auto ladder = pyin_ladder(history, sample_rate, ladder_config);

    std::vector<std::pair<double, double>> merged;
    merged.reserve(unified::kMaximumCandidates * 2);
    for (const auto& candidate : ladder.candidates) {
        merge_candidate(merged, candidate.frequency_hz, candidate.period_probability);
    }

    // The McLeod peaks serve twice over. As candidates they are a second
    // opinion from a different periodicity measure: where they agree with the
    // ladder the merge keeps the stronger score, and where they disagree the
    // extra hypothesis costs one state and gives the path decoder something to
    // reject explicitly. The clarity of the strongest peak, taken unfiltered,
    // is also this frame's voicing evidence -- see kVoicingClarityFloor.
    const auto mpm = v2::mpm_candidates(
        mid_window, sample_rate, unified::kEstimatorMinimumHz,
        unified::kEstimatorMaximumHz, 0.0
    );
    auto clarity = 0.0;
    for (const auto& candidate : mpm) {
        clarity = std::max(clarity, candidate.periodicity);
        if (candidate.periodicity < 0.55) continue;
        merge_candidate(merged, candidate.frequency_hz, candidate.periodicity * 0.5);
    }

    // Harmonic relatives enter as explicit competitors rather than being left
    // implicit. A ghost that is never proposed cannot be scored, and cannot
    // produce the contest mass the abstention rule reads; it can only win
    // silently in some later frame where it happens to be the only proposal.
    const auto proposed = merged.size();
    for (std::size_t index = 0; index < proposed; ++index) {
        const auto [frequency_hz, probability] = merged[index];
        for (const auto ratio : unified::kHarmonicFamilyRatios) {
            merge_candidate(merged, frequency_hz * ratio, probability * 0.05);
        }
    }

    std::sort(merged.begin(), merged.end(), [](const auto& left, const auto& right) {
        return left.second > right.second;
    });
    if (merged.size() > unified::kMaximumCandidates) merged.resize(unified::kMaximumCandidates);

    std::vector<double> frequencies;
    frequencies.reserve(merged.size());
    for (const auto& [frequency_hz, probability] : merged) frequencies.push_back(frequency_hz);

    const auto spectra = compute_multi_resolution_spectra(history, sample_rate);
    frame.evidence = score_harmonic_evidence(
        history, spectra, sample_rate, frequencies, parity,
        unified::kSpectralAnalysisMaximumHz, lookahead_samples
    );

    frame.candidates.reserve(merged.size());
    std::vector<HarmonicEvidence> kept_evidence;
    kept_evidence.reserve(merged.size());
    for (std::size_t index = 0; index < merged.size(); ++index) {
        const auto [frequency_hz, probability] = merged[index];
        const auto& evidence = frame.evidence[index];

        // A real fundamental down here carries measurable energy at its own
        // frequency; an autocorrelation ghost carries essentially none. The
        // older engines imposed no spectral existence requirement on low
        // candidates at all, which is why lowering the search floor used to
        // cost octave errors.
        //
        // Presence is not the only way to be real, though: a fundamental that
        // is simply not radiated has no energy of its own and a perfectly
        // intact harmonic series. A candidate that explains the spectrum well
        // is admitted on that evidence instead -- see
        // kHiddenFundamentalTwmFloor for why this does not readmit ghosts.
        if (frequency_hz < unified::kLowRegisterHz &&
            evidence.fundamental_presence < unified::kLowFundamentalPresenceFloor &&
            evidence.twm_score < unified::kHiddenFundamentalTwmFloor) {
            continue;
        }

        // A candidate whose own predicted series has a multi-partial hole
        // and then real energy again further up is not a single physical
        // source -- see kSeriesCoherenceMinimumGapRun for the measured
        // common-subharmonic-ghost case this drops. Vetoed here rather than
        // merely discounted downstream, the same way the low-register check
        // above removes rather than discounts: a candidate this internally
        // inconsistent should not be able to win a frame at all, whatever
        // periodicity mass it happens to be carrying.
        if (evidence.series_incoherent) {
            continue;
        }

        v2::PitchCandidate candidate{};
        candidate.frequency_hz = frequency_hz;
        candidate.periodicity = probability;
        candidate.harmonic_support = evidence.swipe_prime_support;
        candidate.source = v2::CandidateSource::yin;
        frame.candidates.push_back(v2::ScoredPitchCandidate{
            candidate, emission_for(probability, evidence)
        });
        kept_evidence.push_back(evidence);
    }
    frame.evidence = std::move(kept_evidence);

    // Whatever probability mass the ladder could not assign to any lag is the
    // unvoiced hypothesis. pYIN gets the voicing decision out of the same
    // sweep that produced the candidates, which is why it needs no separate
    // voicing heuristic to argue with.
    // Voicing from clarity, which tracks the note rather than the noise floor.
    // The sweep's own estimate is kept as a floor: on clean material both
    // agree, and where the sweep is confident there is no reason to overrule
    // it. Neither can override the quietness bias, which is what keeps a true
    // rest silent.
    const auto clarity_voiced = std::clamp(
        (clarity - unified::kVoicingClarityFloor) /
            (unified::kVoicingClarityCeiling - unified::kVoicingClarityFloor),
        0.0, 1.0
    );
    const auto voiced = std::max(clarity_voiced, ladder.voiced_probability);
    const auto unvoiced = std::clamp(
        std::max(1.0 - voiced, quietness_bias), 1e-4, 1.0 - 1e-4
    );
    frame.unvoiced_emission = std::log(unvoiced);
    return frame;
}

struct UnifiedPitchSession::Impl {
    PitchEngineConfig config{};
    UnifiedTrackDecoder decoder{unified::kDefaultLagFrames, unified::kTransitionWidthCents};
    ParityEstimate parity{};
    UnifiedFrameDiagnostic diagnostic{};

    HistoryRing history{};
    double sample_rate{unified::kContractSampleRateHz};
    double next_frame_time_seconds{};
    bool has_frame_time{false};
    bool seeded{false};

    /// Frames still owed a clean confirmation before a low-register or
    /// post-abstention publication is allowed.
    std::size_t low_register_confirmations{0};
    std::size_t abstain_recovery{0};
    std::optional<double> last_published_hz{};

    std::deque<double> pending_family_margins{};
    std::deque<double> pending_frame_times{};
    /// The frame's own leading hypothesis (candidates[0], sorted by
    /// descending prior probability at evidence time) -- what the
    /// series-coherence veto actually polices offline, which is not always
    /// what the fixed-lag Viterbi eventually publishes. Carried through the
    /// lag window the same way family_margin is.
    std::deque<std::optional<double>> pending_leading_candidate_hz{};

    /// Raw audio that has arrived since the oldest frame still sitting in
    /// the decoder's fixed-lag buffer. Capped at kSeriesCoherenceLookaheadSamples,
    /// so once full it holds exactly the samples immediately after that
    /// oldest frame's own boundary -- real look-ahead, not fabricated, the
    /// same span collect_unified_evidence hands the offline profile. See
    /// `resolve_series_incoherent_veto` below for how it lines up with
    /// which frame the decoder is about to resolve.
    std::deque<float> lookahead_buffer{};

    [[nodiscard]] std::optional<double> publish(
        const UnifiedDecodedFrame& decoded,
        double family_margin
    );
};

namespace {

/// Applies the series-coherence veto to an already-decoded live candidate,
/// using audio that has genuinely arrived since that frame's own instant.
///
/// The fixed-lag decoder resolves frame N only once `lag_frames` more hops'
/// evidence has been pushed after it -- i.e. exactly when the current hop is
/// N + lag_frames. `lookahead_buffer`, refreshed with this hop's fresh
/// samples immediately before this call, therefore holds precisely the
/// audio between N and N + lag_frames: real future relative to N, available
/// only because publication itself is delayed by the same lag. This is why
/// `kDefaultLagFrames` was raised to make lag_frames * kHopSamples equal
/// kSeriesCoherenceLookaheadSamples (see unified_pitch_constants.hpp) -- a
/// shorter or longer configured lag misaligns this and the veto degrades to
/// firing on stale audio or not firing at all, so callers reconfiguring lag
/// via set_lag_frames should keep that identity in mind.
///
/// Deliberately does not call unified_frame_evidence a second time: the
/// series-coherence spectrum is built from `lookahead_samples` alone (see
/// score_harmonic_evidence), so nothing about frame N's own history window
/// is needed to re-check its already-decoded winner, and re-running the
/// full candidate ladder and spectral scoring for one already-settled frame
/// would double the live path's per-hop cost for no new information.
bool decoded_candidate_is_series_incoherent(
    const std::optional<v2::PitchCandidate>& candidate,
    const std::optional<double>& leading_candidate_hz,
    const std::deque<float>& lookahead_buffer,
    const double sample_rate
) {
    if (!candidate || !leading_candidate_hz) return false;
    // Offline only ever checks candidates[0] -- this frame's own leading
    // hypothesis at evidence time (kSeriesCoherenceCandidateLimit) -- never
    // whatever the path decoder eventually settles on. The fixed-lag
    // decoder's winner is usually that same hypothesis (a GCD ghost wins on
    // inherited posterior, which is exactly what makes it the leading
    // proposal too), but is not guaranteed to be bit-identical to it, so the
    // check below runs against the leading hypothesis, and its result is
    // only applied if the winner is close enough to be the same candidate.
    const auto winner_hz = candidate->frequency_hz;
    const auto cents = std::abs(1200.0 * std::log2(winner_hz / *leading_candidate_hz));
    if (cents > unified::kCandidateMergeCents) return false;
    const auto check_hz = *leading_candidate_hz;
    if (check_hz >= unified::kLowRegisterHz) return false;
    if (lookahead_buffer.size() < unified::kSeriesCoherenceLookaheadSamples) {
        // Still filling (session start) or misconfigured lag: no genuine
        // look-ahead yet, so behave exactly like the empty-span default.
        return false;
    }
    const std::vector<float> lookahead(lookahead_buffer.begin(), lookahead_buffer.end());
    const auto spectrum = compute_frame_spectrum(lookahead, sample_rate, AnalysisBand::low);
    // Same per-candidate ceiling analysis_limit_for computes offline: at
    // least kMinimumScoredPartials partials of this candidate, never below
    // the shared floor, never above what the sample rate can resolve.
    const auto nyquist = 0.5 * sample_rate * unified::kSpectralAnalysisHeadroom;
    const auto wanted = check_hz * static_cast<double>(unified::kMinimumScoredPartials);
    const auto limit =
        std::min(std::max(unified::kSpectralAnalysisMaximumHz, wanted), nyquist);
    return has_series_incoherence(spectrum, check_hz, limit);
}

}  // namespace

std::optional<double> UnifiedPitchSession::Impl::publish(
    const UnifiedDecodedFrame& decoded,
    const double family_margin
) {
    const auto candidate =
        publishable_frequency(decoded, unified::kRealtimeAbstention, family_margin);
    if (!candidate) {
        // Only a genuinely contested frame gets the sticky treatment. A frame
        // withheld because it was quiet, or because nothing fit well, is
        // ordinary silence and the next frame deserves to be judged on its own
        // evidence; making every withheld frame cost two more turns ordinary
        // rests into long dropouts.
        const auto contested = decoded.candidate.has_value() &&
            decoded.harmonic_dominance() < unified::kRealtimeAbstention.harmonic_dominance_floor &&
            decoded.harmonic_evidence_ratio > unified::kHarmonicContestEvidenceRatio;
        diagnostic.publication_reason =
            !decoded.candidate ? "unvoiced" : (contested ? "contested" : "abstained");
        if (contested) {
            abstain_recovery = unified::kAbstainRecoveryFrames;
            low_register_confirmations = unified::kLowRegisterConfirmFrames;
        }
        last_published_hz.reset();
        return std::nullopt;
    }

    if (abstain_recovery > 0) {
        --abstain_recovery;
        diagnostic.publication_reason = "abstain-recovery";
        return std::nullopt;
    }

    if (*candidate < unified::kLowRegisterHz) {
        // The low register is where a widened search costs the most, so a note
        // there has to hold still for a few frames before it is believed.
        const auto continues = last_published_hz &&
            std::abs(1200.0 * std::log2(*candidate / *last_published_hz)) < 100.0;
        if (!continues && low_register_confirmations > 0) {
            --low_register_confirmations;
            diagnostic.publication_reason = "low-register-confirming";
            last_published_hz = *candidate;
            return std::nullopt;
        }
    }

    low_register_confirmations = 0;
    last_published_hz = *candidate;
    diagnostic.publication_reason = "published";
    return candidate;
}

UnifiedPitchSession::UnifiedPitchSession(PitchEngineConfig config)
    : impl_(std::make_unique<Impl>()) {
    impl_->config = config;
}

UnifiedPitchSession::~UnifiedPitchSession() = default;
UnifiedPitchSession::UnifiedPitchSession(UnifiedPitchSession&&) noexcept = default;
UnifiedPitchSession& UnifiedPitchSession::operator=(UnifiedPitchSession&&) noexcept = default;

void UnifiedPitchSession::set_minimum_rms(const double minimum_rms) {
    impl_->config.minimum_rms = minimum_rms;
}

void UnifiedPitchSession::set_lag_frames(const std::size_t lag_frames) {
    impl_->decoder = UnifiedTrackDecoder(lag_frames, unified::kTransitionWidthCents);
    // The look-ahead buffer's alignment with the decoder's own buffered
    // frames depends on lag_frames matching kSeriesCoherenceLookaheadSamples
    // / kHopSamples (see decoded_candidate_is_series_incoherent); reconfiguring
    // the decoder invalidates whatever partial window had accumulated.
    impl_->lookahead_buffer.clear();
}

const UnifiedFrameDiagnostic& UnifiedPitchSession::last_diagnostic() const {
    return impl_->diagnostic;
}

void UnifiedPitchSession::reset() {
    impl_->decoder.reset();
    impl_->parity = ParityEstimate{};
    impl_->history.clear();
    impl_->next_frame_time_seconds = 0.0;
    impl_->has_frame_time = false;
    impl_->seeded = false;
    impl_->low_register_confirmations = 0;
    impl_->abstain_recovery = 0;
    impl_->last_published_hz.reset();
    impl_->pending_family_margins.clear();
    impl_->pending_frame_times.clear();
    impl_->pending_leading_candidate_hz.clear();
    impl_->lookahead_buffer.clear();
}

std::vector<EngineFrame> UnifiedPitchSession::process_frame(
    const std::span<const float> samples,
    const double sample_rate,
    const double source_time_seconds
) {
    auto& impl = *impl_;
    impl.sample_rate = sample_rate > 0.0 ? sample_rate : unified::kContractSampleRateHz;
    if (samples.empty()) return {};

    // The shared production contract: one call carries one complete analysis
    // window, and consecutive windows overlap -- callers slide a window_size
    // window forward by hop_size. Only the trailing hop is new, so admitting
    // the whole window on every call would consume each sample three times
    // over and run the clock at three times real speed. The first call has no
    // predecessor to overlap with, so it seeds the ring with everything.
    const auto fresh_samples = impl.seeded
        ? samples.last(std::min(samples.size(), unified::kHopSamples))
        : samples;
    for (const auto sample : fresh_samples) impl.history.push(sample);
    impl.seeded = true;

    // Mirrors the fresh audio into a rolling look-ahead buffer for whichever
    // frame is currently the oldest one sitting in the decoder's fixed-lag
    // window -- see `decoded_candidate_is_series_incoherent` for why this is
    // real future audio rather than a fabricated one.
    for (const auto sample : fresh_samples) {
        impl.lookahead_buffer.push_back(sample);
    }
    while (impl.lookahead_buffer.size() > unified::kSeriesCoherenceLookaheadSamples) {
        impl.lookahead_buffer.pop_front();
    }

    const auto history = impl.history.window();
    const auto frame_time = source_time_seconds;
    impl.next_frame_time_seconds =
        source_time_seconds + static_cast<double>(unified::kHopSamples) / impl.sample_rate;

    auto evidence = unified_frame_evidence(
        history, impl.sample_rate, frame_time, impl.config, impl.parity
    );
    // The margin belongs to the frame that produced it, but the decoder will
    // not resolve that frame until the lag window has elapsed, so it travels
    // alongside the decoder's own buffer.
    auto best_margin = 0.0;
    if (!evidence.evidence.empty()) {
        best_margin = std::max_element(
            evidence.evidence.begin(), evidence.evidence.end(),
            [](const auto& left, const auto& right) {
                return left.family_margin < right.family_margin;
            }
        )->family_margin;
    }
    impl.pending_family_margins.push_back(best_margin);
    impl.pending_frame_times.push_back(frame_time);
    impl.pending_leading_candidate_hz.push_back(
        evidence.candidates.empty()
            ? std::nullopt
            : std::make_optional(evidence.candidates.front().candidate.frequency_hz)
    );

    const auto rms = evidence.rms;
    const auto candidate_count = evidence.candidates.size();
    const auto eligible = evidence.signal_eligible;
    auto decoded_optional = impl.decoder.push(evidence);
    if (!decoded_optional) return {};
    auto decoded = *decoded_optional;

    const auto leading_candidate_hz = impl.pending_leading_candidate_hz.front();
    impl.pending_leading_candidate_hz.pop_front();

    // The lookahead buffer was just refreshed with this hop's fresh samples
    // above, before the decoder resolved anything -- at this exact call it
    // holds precisely the audio between the resolved frame's own instant and
    // now (see `decoded_candidate_is_series_incoherent`). Retroactively
    // veto the winner the fixed-lag decoder already chose, the same way
    // candidate generation drops one offline, just lagged by necessity: this
    // is the one check in the whole evidence layer that needs samples which
    // did not exist yet when the frame was first evidenced.
    if (decoded_candidate_is_series_incoherent(
            decoded.candidate, leading_candidate_hz, impl.lookahead_buffer, impl.sample_rate)) {
        decoded.candidate.reset();
    }

    const auto margin = impl.pending_family_margins.front();
    impl.pending_family_margins.pop_front();
    const auto resolved_time = impl.pending_frame_times.front();
    impl.pending_frame_times.pop_front();

    impl.diagnostic = UnifiedFrameDiagnostic{
        resolved_time, rms, eligible, candidate_count,
        decoded.winner_posterior, decoded.voiced_posterior,
        decoded.harmonic_dominance(), decoded.harmonic_evidence_ratio,
        margin, impl.parity.index, {}
    };
    const auto frequency = impl.publish(decoded, margin);
    if (frequency && decoded.winner_posterior >= unified::kParityTrustPosterior) {
        update_parity_estimate(
            impl.parity, compute_multi_resolution_spectra(history, impl.sample_rate),
            *frequency, impl.sample_rate
        );
    } else if (!frequency) {
        note_unvoiced_frame(impl.parity);
    }

    return {EngineFrame{
        resolved_time,
        frequency,
        frequency ? decoded.winner_posterior : 0.0,
    }};
}

std::vector<EngineFrame> UnifiedPitchSession::finish() {
    auto& impl = *impl_;
    std::vector<EngineFrame> published;
    while (auto decoded_optional = impl.decoder.finish_next()) {
        auto decoded = *decoded_optional;
        // No more real audio arrives past end of stream, so the buffer
        // cannot grow here -- it can only shrink. Each successive frame
        // drained by finish_next() is one hop newer than the last, so its
        // true look-ahead is one hop shorter; the veto's own "still filling"
        // guard degrades it to a no-op once it runs out, matching
        // finish_next()'s "real, shorter suffix" rather than fabricating one.
        std::optional<double> leading_candidate_hz{};
        if (!impl.pending_leading_candidate_hz.empty()) {
            leading_candidate_hz = impl.pending_leading_candidate_hz.front();
            impl.pending_leading_candidate_hz.pop_front();
        }
        if (decoded_candidate_is_series_incoherent(
                decoded.candidate, leading_candidate_hz, impl.lookahead_buffer, impl.sample_rate)) {
            decoded.candidate.reset();
        }
        for (std::size_t i = 0; i < unified::kHopSamples && !impl.lookahead_buffer.empty(); ++i) {
            impl.lookahead_buffer.pop_front();
        }

        auto margin = 0.0;
        if (!impl.pending_family_margins.empty()) {
            margin = impl.pending_family_margins.front();
            impl.pending_family_margins.pop_front();
        }
        // Frame times are carried through the lag window rather than
        // recomputed, so the drained tail lands on the same timestamps the
        // caller supplied for those frames.
        auto frame_time = impl.next_frame_time_seconds;
        if (!impl.pending_frame_times.empty()) {
            frame_time = impl.pending_frame_times.front();
            impl.pending_frame_times.pop_front();
        }
        const auto frequency = impl.publish(decoded, margin);
        published.push_back(EngineFrame{
            frame_time,
            frequency,
            frequency ? decoded.winner_posterior : 0.0,
        });
    }
    return published;
}

std::vector<UnifiedFrameEvidence> collect_unified_evidence(
    const std::span<const float> mono_samples,
    const double sample_rate,
    const PitchEngineConfig& config,
    const PitchProgressCallback on_progress
) {
    std::vector<UnifiedFrameEvidence> frames;
    if (mono_samples.empty() || sample_rate <= 0.0) return frames;

    HistoryRing ring{};
    ParityEstimate parity{};
    const auto estimated_total = mono_samples.size() / unified::kHopSamples + 1;
    frames.reserve(estimated_total);

    // This loop is where nearly all of a whole-track offline pass's time
    // goes (the per-hop pYIN ladder + spectral evidence build dominates the
    // later global decode), so it is the one place a progress callback is
    // actually worth reporting from. Throttled the same way the CLI's own
    // write-progress loop is throttled (see pitch_track_cli.cpp): roughly
    // every 1% of the estimated frame count or every 200ms, whichever comes
    // first, so a three-minute recording's ~17,900 hops don't turn into
    // 17,900 callback invocations for no visible benefit.
    const std::size_t report_stride = std::max<std::size_t>(estimated_total / 100, 1);
    auto last_report = std::chrono::steady_clock::now();

    std::size_t consumed = 0;
    for (std::size_t index = 0; index < mono_samples.size(); ++index) {
        ring.push(mono_samples[index]);
        if (++consumed < unified::kHopSamples) continue;
        consumed = 0;

        const auto history = ring.window();

        const auto frame_time =
            static_cast<double>(index + 1) / sample_rate;
        // The one place this offline collector is allowed to differ from
        // the live path in what it hands unified_frame_evidence: samples
        // beyond the current instant, already sitting in `mono_samples`
        // because the whole track is loaded up front. See
        // kSeriesCoherenceLookaheadSamples for what this buys and why it is
        // capped rather than unbounded.
        const auto lookahead_begin = std::min(index + 1, mono_samples.size());
        const auto lookahead_end = std::min(
            lookahead_begin + unified::kSeriesCoherenceLookaheadSamples, mono_samples.size()
        );
        const auto lookahead = mono_samples.subspan(
            lookahead_begin, lookahead_end - lookahead_begin
        );
        auto evidence =
            unified_frame_evidence(history, sample_rate, frame_time, config, parity, lookahead);
        // Offline, parity is seeded from the strongest proposal of each frame
        // rather than from a committed decision, because no decision exists
        // yet. It converges to the same place: the estimate is an average over
        // many frames, and a wrong frame moves it by one EMA step.
        if (!evidence.candidates.empty() && evidence.signal_eligible) {
            const auto spectra = compute_multi_resolution_spectra(history, sample_rate);
            update_parity_estimate(
                parity, spectra, evidence.candidates.front().candidate.frequency_hz, sample_rate
            );
        } else {
            note_unvoiced_frame(parity);
        }
        frames.push_back(std::move(evidence));

        if (on_progress) {
            const auto now = std::chrono::steady_clock::now();
            if (frames.size() % report_stride == 0 ||
                now - last_report >= std::chrono::milliseconds(200)) {
                on_progress(frames.size(), estimated_total);
                last_report = now;
            }
        }
    }
    return frames;
}

namespace {

/// Offline equivalent of `UnifiedPitchSession::Impl::publish`'s
/// `low_register_confirmations` guard.
///
/// The live path cannot tell a genuine low note from a brief low-register
/// slip the instant it appears, so it withholds publication for
/// `kLowRegisterConfirmFrames` frames while waiting to see whether the pitch
/// holds -- confirmation arrives, if at all, strictly *after* the onset,
/// because that is the only direction a causal listener has.
///
/// Offline has already decoded every frame before anything is published, so
/// there is nothing left to wait for: whether an onset sustains is a fact
/// about the sequence, not something that has to arrive over time. This asks
/// the same question -- does this low-register onset hold for at least
/// `kLowRegisterConfirmFrames` frames -- by looking at the neighbourhood
/// directly, in one pass, rather than by delaying every candidate's
/// publication to find out. An onset that fails to sustain is withheld in
/// full (all of its unconfirmed frames go silent), matching what the live
/// path would have done to the frames it held back while waiting.
///
/// This is deliberately a low-register-only, run-length check and not an
/// attempt to catch a sustained wrong note: a GCD ghost that holds the path
/// for many frames running (the case this fix package's other steps target)
/// sustains for far longer than `kLowRegisterConfirmFrames` and passes this
/// guard exactly as a genuine low note would. This guard's job is the
/// narrower one the live path already does -- catching the brief slip -- not
/// the one the evidence-ratio ceiling in `publishable_frequency` does.
void suppress_unconfirmed_low_register_onsets(std::vector<std::optional<double>>& frequencies) {
    const auto count = frequencies.size();
    for (std::size_t index = 0; index < count; ++index) {
        if (!frequencies[index] || *frequencies[index] >= unified::kLowRegisterHz) continue;

        // Bridging from an already-confirmed low-register run continues
        // trusted, exactly like the live path's `continues` check.
        if (index > 0 && frequencies[index - 1] &&
            std::abs(1200.0 * std::log2(*frequencies[index] / *frequencies[index - 1])) < 100.0) {
            continue;
        }

        // How many of the next kLowRegisterConfirmFrames frames, starting
        // here, stay within a semitone of this onset.
        std::size_t run = 0;
        for (std::size_t offset = 0;
             offset < unified::kLowRegisterConfirmFrames && index + offset < count;
             ++offset) {
            const auto& candidate = frequencies[index + offset];
            if (!candidate) break;
            if (std::abs(1200.0 * std::log2(*candidate / *frequencies[index])) >= 100.0) break;
            ++run;
        }
        if (run < unified::kLowRegisterConfirmFrames) {
            for (std::size_t offset = 0; offset < run; ++offset) {
                frequencies[index + offset].reset();
            }
        }
    }
}

}  // namespace

std::vector<EngineFrame> decode_unified_offline_track(
    const std::span<const UnifiedFrameEvidence> evidence,
    const PitchEngineConfig& config,
    const PitchProgressCallback on_progress
) {
    (void)config;
    std::vector<EngineFrame> frames;
    frames.reserve(evidence.size());
    // The global Viterbi decode itself lives in unified_track_decoder.cpp and
    // has no progress hook of its own (a different fix package's territory),
    // so this stage cannot tick mid-decode -- only report its completion.
    // Deliberately not also reporting 0/total here: collect_unified_evidence
    // has already ticked this same callback up to (near) evidence.size(), and
    // this function runs strictly after it within one analyse() call, so an
    // extra 0/total here would read as the progress bar jumping backwards
    // for a step that is short next to the evidence collection pass anyway.
    const auto decoded =
        decode_unified_track_globally(evidence, unified::kTransitionWidthCents);
    if (on_progress) on_progress(evidence.size(), evidence.size());

    std::vector<std::optional<double>> frequencies(decoded.size());
    for (std::size_t index = 0; index < decoded.size(); ++index) {
        auto margin = 0.0;
        const auto& source = evidence[index];
        if (!source.evidence.empty()) {
            margin = std::max_element(
                source.evidence.begin(), source.evidence.end(),
                [](const auto& left, const auto& right) {
                    return left.family_margin < right.family_margin;
                }
            )->family_margin;
        }
        frequencies[index] =
            publishable_frequency(decoded[index], unified::kOfflineAbstention, margin);
    }
    suppress_unconfirmed_low_register_onsets(frequencies);

    for (std::size_t index = 0; index < decoded.size(); ++index) {
        frames.push_back(EngineFrame{
            evidence[index].time_seconds,
            frequencies[index],
            frequencies[index] ? decoded[index].winner_posterior : 0.0,
        });
    }
    return frames;
}

}  // namespace klarivision::core
