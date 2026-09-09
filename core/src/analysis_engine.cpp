#include "klarivision/core/analysis_engine.hpp"

#include "klarivision/core/unified_pitch_session.hpp"

#include <algorithm>
#include <chrono>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

// Production pitch boundary. Since D-039 this file dispatches to exactly one
// engine -- unified_v1 -- so it is a thin shell: session lifecycle, the
// windowing loop that turns a buffer into frames, and the one offline
// post-pass (stray-run removal) that is not part of the engine itself.
//
// Everything that decides a pitch now lives in unified_pitch_session.cpp and
// unified_track_decoder.cpp. The four engines that used to be selected here
// each carried their own candidate generation, continuity state and
// publication gating in this file; all of that is gone. Reserved engine ids
// 0-3 are rejected at construction rather than mapped onto the survivor,
// because a caller naming a removed engine is asking for behaviour this build
// cannot honour, and silently substituting another engine's output would be
// the one failure mode that is invisible in the result.

namespace klarivision::core {
namespace {

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
// Frames further apart than this are treated as separate voiced runs when
// grouping the track for stray-run detection, in seconds.
constexpr double kOfflineRunSplitGapSeconds = 0.012;

// Returns the indices of every voiced (frequency-bearing) frame in the track,
// in order. Stray-run detection only ever reasons about voiced frames.
std::vector<std::size_t> collect_voiced_frame_indices(const std::vector<EngineFrame>& track) {
    std::vector<std::size_t> voiced;
    for (std::size_t index = 0; index < track.size(); ++index) {
        if (track[index].frequency_hz && *track[index].frequency_hz > 0) {
            voiced.push_back(index);
        }
    }
    return voiced;
}

// Groups the voiced frames into contiguous runs, splitting wherever two
// neighbouring voiced frames are more than kOfflineRunSplitGapSeconds apart.
// Each returned pair is [first, last] as positions into `voiced`, not as
// indices into `track`.
std::vector<std::pair<std::size_t, std::size_t>> split_into_voiced_runs(
    const std::vector<EngineFrame>& track,
    const std::vector<std::size_t>& voiced
) {
    std::vector<std::pair<std::size_t, std::size_t>> runs;
    std::size_t begin = 0;
    for (std::size_t position = 1; position <= voiced.size(); ++position) {
        const bool split = position == voiced.size() ||
            track[voiced[position]].time_seconds - track[voiced[position - 1]].time_seconds >
                kOfflineRunSplitGapSeconds;
        if (split) {
            runs.push_back({begin, position - 1});
            begin = position;
        }
    }
    return runs;
}

// A run qualifies for removal only when it is short, silence-isolated on
// both sides, and never rose above VPM-like's own publication bar. Any one
// of those failing means it is treated as a real note or ornament.
bool is_stray_run(
    const std::vector<EngineFrame>& track,
    const std::vector<std::size_t>& voiced,
    const std::vector<std::pair<std::size_t, std::size_t>>& runs,
    const std::size_t run
) {
    const auto [first, last] = runs[run];
    if (last - first + 1 > kOfflineStrayMaximumFrames) {
        return false;
    }
    const double before = run == 0 ? std::numeric_limits<double>::infinity()
        : track[voiced[first]].time_seconds - track[voiced[runs[run - 1].second]].time_seconds;
    const double after = run + 1 == runs.size() ? std::numeric_limits<double>::infinity()
        : track[voiced[runs[run + 1].first]].time_seconds - track[voiced[last]].time_seconds;
    if (before < kOfflineStrayIsolationSeconds || after < kOfflineStrayIsolationSeconds) {
        return false;
    }
    double peak = 0;
    for (std::size_t position = first; position <= last; ++position) {
        peak = std::max(peak, track[voiced[position]].confidence);
    }
    return peak < kOfflineStrayConfidence;
}

// Drops short, isolated, low-confidence runs from an offline track.
std::vector<EngineFrame> drop_offline_stray_runs(const std::vector<EngineFrame>& track) {
    const std::vector<std::size_t> voiced = collect_voiced_frame_indices(track);
    if (voiced.size() < 2) {
        return track;
    }
    const std::vector<std::pair<std::size_t, std::size_t>> runs =
        split_into_voiced_runs(track, voiced);

    std::vector<bool> drop(track.size(), false);
    for (std::size_t run = 0; run < runs.size(); ++run) {
        if (!is_stray_run(track, voiced, runs, run)) {
            continue;
        }
        const auto [first, last] = runs[run];
        for (std::size_t position = first; position <= last; ++position) {
            drop[voiced[position]] = true;
        }
    }

    std::vector<EngineFrame> kept;
    kept.reserve(track.size());
    for (std::size_t index = 0; index < track.size(); ++index) {
        if (!drop[index]) {
            kept.push_back(track[index]);
        }
    }
    return kept;
}

}  // namespace

// Per-session state. The unified session owns every pitch decision; this
// struct only holds it, the configuration it was built from, and the
// end-of-stream latch.
struct ProductionPitchSession::Impl {
    std::unique_ptr<UnifiedPitchSession> unified{};
    PitchEngineConfig config;
    bool finished{false};

    explicit Impl(const PitchEngineConfig& configuration) : config(configuration) {}
};

// Rejects a reserved (removed) engine id outright: see PitchEngineId. The C
// ABI layer checks first and returns a null handle, so this throw is the
// backstop for direct C++ callers.
ProductionPitchSession::ProductionPitchSession(
    const PitchEngineId id,
    const PitchEngineConfig config
) : impl_(std::make_unique<Impl>(config)) {
    if (!is_supported(id)) {
        throw std::invalid_argument(
            "Pitch engine id names an engine that was removed; only unified_v1 is available"
        );
    }
}

ProductionPitchSession::~ProductionPitchSession() = default;
ProductionPitchSession::ProductionPitchSession(ProductionPitchSession&&) noexcept = default;
ProductionPitchSession& ProductionPitchSession::operator=(ProductionPitchSession&&) noexcept = default;

// Advances the session by one analysis window. The unified engine is
// self-contained: it owns candidate generation, path decoding and its own
// publication decision, including the decision to stay silent.
std::vector<EngineFrame> ProductionPitchSession::process_frame(
    const std::span<const float> samples,
    const double rate,
    const double source_time
) {
    auto& session = *impl_;
    // invalid input, or not enough samples for a full window
    if (rate <= 0 || samples.size() < session.config.window_size) return {};
    if (session.finished) {
        throw std::logic_error(
            "Pitch session is finished; call reset before processing more frames"
        );
    }
    if (!session.unified) {
        session.unified = std::make_unique<UnifiedPitchSession>(session.config);
    }
    return session.unified->process_frame(samples, rate, source_time);
}

// Drains the fixed-lag window using the real remaining suffix as look-ahead.
// Dropping it would silently truncate the end of every recording.
std::vector<EngineFrame> ProductionPitchSession::finish() {
    if (impl_->finished) return {};
    impl_->finished = true;
    return impl_->unified ? impl_->unified->finish() : std::vector<EngineFrame>{};
}

void ProductionPitchSession::reset() {
    const auto config = impl_->config;
    // rebuild from scratch, preserving only the configuration
    impl_ = std::make_unique<Impl>(config);
}

void ProductionPitchSession::set_minimum_rms(const double minimum_rms) {
    if (!std::isfinite(minimum_rms) || minimum_rms < 0) return;  // reject a nonsensical value
    impl_->config.minimum_rms = minimum_rms;
    if (impl_->unified) impl_->unified->set_minimum_rms(minimum_rms);
}

PitchEngine::PitchEngine(PitchEngineId id, PitchEngineProfile profile, PitchEngineConfig config)
    : id_(id), profile_(profile), config_(config) {
    if (!is_supported(id)) {
        throw std::invalid_argument(
            "Pitch engine id names an engine that was removed; only unified_v1 is available"
        );
    }
}

void PitchEngine::reset() {
    buffered_samples_.clear();
    sample_rate_ = 0;
}

// Accumulates mono samples for later offline analysis; samples at a
// different sample rate than the first push are silently dropped (a
// session is expected to be single-sample-rate).
void PitchEngine::push(std::span<const float> mono_samples, double sample_rate) {
    if (sample_rate_ == 0) {
        sample_rate_ = sample_rate;
    }
    if (std::abs(sample_rate - sample_rate_) < 0.001) {
        buffered_samples_.insert(buffered_samples_.end(), mono_samples.begin(), mono_samples.end());
    }
}

std::vector<EngineFrame> PitchEngine::finish(PitchProgressCallback on_progress) {
    auto result = analyse(buffered_samples_, sample_rate_, std::move(on_progress));
    reset();
    return result;
}

// Runs a fresh ProductionPitchSession over the whole buffer, frame by frame
// (as if streaming live), collecting every published frame plus the final
// flush from session.finish().
std::vector<EngineFrame> PitchEngine::analyse_causal(
    const std::span<const float> samples,
    const double rate,
    const PitchProgressCallback on_progress
) {
    if (rate <= 0 || samples.size() < config_.window_size) {
        return {};
    }
    ProductionPitchSession session(id_, config_);
    std::vector<EngineFrame> output;
    // Total window count for this loop, known up front (unlike
    // collect_unified_evidence's hop count, which is why this can compute it
    // once here rather than re-deriving it per call).
    const std::size_t total_windows =
        (samples.size() - config_.window_size) / config_.hop_size + 1;
    std::size_t processed_windows = 0;
    // Same throttle as collect_unified_evidence and the CLI's own write loop:
    // ~1% of windows or 200ms, whichever comes first, so the callback never
    // costs more than a handful of calls even on a multi-minute recording.
    const std::size_t report_stride = std::max<std::size_t>(total_windows / 100, 1);
    auto last_report = std::chrono::steady_clock::now();
    // slide a fixed-size window across the buffer
    for (std::size_t start = 0;
         start + config_.window_size <= samples.size();
         start += config_.hop_size) {
        // this window's centre time
        const double time = (static_cast<double>(start) + config_.window_size / 2.0) / rate;
        auto published =
            session.process_frame(samples.subspan(start, config_.window_size), rate, time);
        output.insert(output.end(), published.begin(), published.end());
        ++processed_windows;
        if (on_progress) {
            const auto now = std::chrono::steady_clock::now();
            if (processed_windows % report_stride == 0 ||
                now - last_report >= std::chrono::milliseconds(200)) {
                on_progress(processed_windows, total_windows);
                last_report = now;
            }
        }
    }
    // flush the buffered fixed-lag look-ahead
    auto final = session.finish();
    output.insert(output.end(), final.begin(), final.end());
    if (on_progress) on_progress(total_windows, total_windows);
    return output;
}

// Public offline entry point. The realtime profile is the causal trace as
// published live; offline_track decodes the whole sequence instead.
std::vector<EngineFrame> PitchEngine::analyse(
    const std::span<const float> samples,
    const double rate,
    const PitchProgressCallback on_progress
) {
    if (profile_ != PitchEngineProfile::offline_track) return analyse_causal(samples, rate, on_progress);
    // Not a refinement of the causal trace. A refinement pass may only reprice
    // frames the causal pass already published, so a frame the causal pass
    // declined to answer is permanently lost to it -- and declining is the
    // engine's central mechanism. Decoding the whole sequence over the same
    // candidates can revisit voicing as well as pitch, which strictly
    // dominates.
    const auto evidence = collect_unified_evidence(samples, rate, config_, on_progress);
    return drop_offline_stray_runs(decode_unified_offline_track(evidence, config_, on_progress));
}
}  // namespace klarivision::core
