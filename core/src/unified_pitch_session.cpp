#include "klarivision/core/unified_pitch_session.hpp"

#include "klarivision/core/frame_spectrum.hpp"
#include "klarivision/core/mpm.hpp"
#include "klarivision/core/pyin_ladder.hpp"

#include <algorithm>
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
    const ParityEstimate& parity
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

    // The McLeod peaks are a second opinion from a different periodicity
    // measure. Where they agree with the ladder the merge simply keeps the
    // stronger score; where they disagree the extra hypothesis costs one more
    // state and gives the path decoder something to reject explicitly.
    const auto mpm = v2::mpm_candidates(
        mid_window, sample_rate, unified::kEstimatorMinimumHz, unified::kEstimatorMaximumHz
    );
    for (const auto& candidate : mpm) {
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
        history, spectra, sample_rate, frequencies, parity
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
        if (frequency_hz < unified::kLowRegisterHz &&
            evidence.fundamental_presence < unified::kLowFundamentalPresenceFloor) {
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
    const auto unvoiced = std::clamp(
        std::max(1.0 - ladder.voiced_probability, quietness_bias), 1e-4, 1.0 - 1e-4
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

    [[nodiscard]] std::optional<double> publish(
        const UnifiedDecodedFrame& decoded,
        double family_margin
    );
};

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
    if (!impl.seeded) {
        for (const auto sample : samples) impl.history.push(sample);
        impl.seeded = true;
    } else {
        const auto fresh = std::min(samples.size(), unified::kHopSamples);
        for (const auto sample : samples.last(fresh)) impl.history.push(sample);
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

    const auto rms = evidence.rms;
    const auto candidate_count = evidence.candidates.size();
    const auto eligible = evidence.signal_eligible;
    const auto decoded = impl.decoder.push(evidence);
    if (!decoded) return {};

    const auto margin = impl.pending_family_margins.front();
    impl.pending_family_margins.pop_front();
    const auto resolved_time = impl.pending_frame_times.front();
    impl.pending_frame_times.pop_front();

    impl.diagnostic = UnifiedFrameDiagnostic{
        resolved_time, rms, eligible, candidate_count,
        decoded->winner_posterior, decoded->voiced_posterior,
        decoded->harmonic_dominance(), decoded->harmonic_evidence_ratio,
        margin, impl.parity.index, {}
    };
    const auto frequency = impl.publish(*decoded, margin);
    if (frequency && decoded->winner_posterior >= unified::kParityTrustPosterior) {
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
        frequency ? decoded->winner_posterior : 0.0,
    }};
}

std::vector<EngineFrame> UnifiedPitchSession::finish() {
    auto& impl = *impl_;
    std::vector<EngineFrame> published;
    while (const auto decoded = impl.decoder.finish_next()) {
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
        const auto frequency = impl.publish(*decoded, margin);
        published.push_back(EngineFrame{
            frame_time,
            frequency,
            frequency ? decoded->winner_posterior : 0.0,
        });
    }
    return published;
}

std::vector<UnifiedFrameEvidence> collect_unified_evidence(
    const std::span<const float> mono_samples,
    const double sample_rate,
    const PitchEngineConfig& config
) {
    std::vector<UnifiedFrameEvidence> frames;
    if (mono_samples.empty() || sample_rate <= 0.0) return frames;

    HistoryRing ring{};
    ParityEstimate parity{};
    frames.reserve(mono_samples.size() / unified::kHopSamples + 1);

    std::size_t consumed = 0;
    for (std::size_t index = 0; index < mono_samples.size(); ++index) {
        ring.push(mono_samples[index]);
        if (++consumed < unified::kHopSamples) continue;
        consumed = 0;

        const auto history = ring.window();

        const auto frame_time =
            static_cast<double>(index + 1) / sample_rate;
        auto evidence =
            unified_frame_evidence(history, sample_rate, frame_time, config, parity);
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
    }
    return frames;
}

std::vector<EngineFrame> decode_unified_offline_track(
    const std::span<const UnifiedFrameEvidence> evidence,
    const PitchEngineConfig& config
) {
    (void)config;
    std::vector<EngineFrame> frames;
    frames.reserve(evidence.size());
    const auto decoded =
        decode_unified_track_globally(evidence, unified::kTransitionWidthCents);
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
        const auto frequency =
            publishable_frequency(decoded[index], unified::kOfflineAbstention, margin);
        frames.push_back(EngineFrame{
            source.time_seconds,
            frequency,
            frequency ? decoded[index].winner_posterior : 0.0,
        });
    }
    return frames;
}

}  // namespace klarivision::core
