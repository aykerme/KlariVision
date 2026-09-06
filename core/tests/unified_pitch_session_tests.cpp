#include "klarivision/core/unified_pitch_session.hpp"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <numbers>
#include <vector>

using klarivision::core::EngineFrame;
using klarivision::core::UnifiedPitchSession;

namespace unified = klarivision::core::unified;

namespace {

constexpr double kRate = unified::kContractSampleRateHz;

/// A stopped-pipe timbre: odd partials only, and a fundamental far weaker than
/// its own third harmonic. This is the shape the research report singles out as
/// the hard case, and the shape a naive "the fundamental must be strong"
/// heuristic silently rejects.
std::vector<float> stopped_pipe_tone(const double f0, const double seconds) {
    std::vector<float> out(static_cast<std::size_t>(seconds * kRate));
    for (std::size_t index = 0; index < out.size(); ++index) {
        const auto t = static_cast<double>(index) / kRate;
        const auto value =
            0.10 * std::sin(2.0 * std::numbers::pi * f0 * t) +
            1.00 * std::sin(2.0 * std::numbers::pi * 3.0 * f0 * t) +
            0.45 * std::sin(2.0 * std::numbers::pi * 5.0 * f0 * t) +
            0.20 * std::sin(2.0 * std::numbers::pi * 7.0 * f0 * t);
        out[index] = static_cast<float>(0.25 * value);
    }
    return out;
}

/// A full integer harmonic series, the ordinary case the engine must not
/// regress on while it is being made safe for the hard one.
std::vector<float> sawtooth_tone(const double f0, const double seconds) {
    std::vector<float> out(static_cast<std::size_t>(seconds * kRate));
    for (std::size_t index = 0; index < out.size(); ++index) {
        const auto t = static_cast<double>(index) / kRate;
        auto value = 0.0;
        for (int k = 1; k <= 8; ++k) {
            value += (1.0 / k) * std::sin(2.0 * std::numbers::pi * k * f0 * t);
        }
        out[index] = static_cast<float>(0.25 * value);
    }
    return out;
}

std::vector<float> silence(const double seconds) {
    return std::vector<float>(static_cast<std::size_t>(seconds * kRate), 0.0F);
}

struct Score {
    std::size_t frames{};
    std::size_t voiced{};
    std::size_t correct{};
    std::size_t harmonic{};
    std::size_t other{};
    [[nodiscard]] double coverage() const {
        return frames == 0 ? 0.0 : static_cast<double>(voiced) / static_cast<double>(frames);
    }
};

/// Drives the session exactly as production does: a window_size window slid
/// forward by hop_size, so consecutive calls overlap. Feeding disjoint windows
/// instead would hand the session three times the audio and hide any mistake
/// in how it accounts for the overlap.
std::vector<EngineFrame> drive(UnifiedPitchSession& session, const std::vector<float>& samples) {
    std::vector<EngineFrame> frames;
    constexpr auto kWindow = unified::kMidWindowSamples;
    for (std::size_t start = 0; start + kWindow <= samples.size(); start += unified::kHopSamples) {
        const auto centre = (static_cast<double>(start) + kWindow / 2.0) / kRate;
        auto produced = session.process_frame({samples.data() + start, kWindow}, kRate, centre);
        frames.insert(frames.end(), produced.begin(), produced.end());
    }
    auto tail = session.finish();
    frames.insert(frames.end(), tail.begin(), tail.end());
    return frames;
}

Score run(const std::vector<float>& samples, const double truth) {
    UnifiedPitchSession session;
    const auto frames = drive(session, samples);

    Score score{};
    score.frames = frames.size();
    // One frame per hop, no more: a session that mistook overlapping windows
    // for fresh audio would emit several times this many.
    const auto expected =
        (samples.size() - unified::kMidWindowSamples) / unified::kHopSamples + 1;
    assert(score.frames <= expected + 1 && score.frames + 1 >= expected);
    for (const auto& frame : frames) {
        if (!frame.frequency_hz) continue;
        ++score.voiced;
        const auto cents = 1200.0 * std::log2(*frame.frequency_hz / truth);
        if (std::abs(cents) <= 50.0) {
            ++score.correct;
            continue;
        }
        auto is_harmonic = false;
        for (const auto target : unified::kHarmonicTargetCents) {
            if (std::abs(cents - target) <= unified::kHarmonicToleranceCents) is_harmonic = true;
        }
        if (is_harmonic) ++score.harmonic; else ++score.other;
    }
    return score;
}

void expect_clean(const char* label, const Score& score, const double minimum_coverage) {
    std::printf(
        "  %-28s coverage=%.0f%% correct=%zu harmonic=%zu other=%zu\n",
        label, 100.0 * score.coverage(), score.correct, score.harmonic, score.other
    );
    // The whole point of the engine: never a harmonic error, ever.
    assert(score.harmonic == 0);
    assert(score.other == 0);
    // And silence must not be how that is achieved. Without a coverage floor,
    // an engine that abstains on everything would pass the line above.
    assert(score.coverage() >= minimum_coverage);
}

}  // namespace

int main() {
    // Zero harmonic errors across the full published range, on both timbres.
    // The lower cases are the ones that matter: an engine that assumes a
    // strong fundamental goes completely silent on them.
    expect_clean("stopped pipe 294 Hz", run(stopped_pipe_tone(294.0, 2.0), 294.0), 0.90);
    expect_clean("stopped pipe 147 Hz", run(stopped_pipe_tone(147.0, 2.0), 147.0), 0.90);
    expect_clean("stopped pipe 98 Hz", run(stopped_pipe_tone(98.0, 2.0), 98.0), 0.90);
    expect_clean("sawtooth 82 Hz", run(sawtooth_tone(82.0, 2.0), 82.0), 0.90);
    expect_clean("sawtooth 294 Hz", run(sawtooth_tone(294.0, 2.0), 294.0), 0.90);
    expect_clean("sawtooth 880 Hz", run(sawtooth_tone(880.0, 2.0), 880.0), 0.90);
    // The extremes of the range the range was drawn to include. A boundary
    // check without tolerance silences these while every metric still looks
    // perfect, because a silent frame is not a wrong frame.
    expect_clean("sawtooth 1760 Hz", run(sawtooth_tone(1760.0, 2.0), 1760.0), 0.90);

    // Silence is reported as silence, not filled in.
    {
        const auto score = run(silence(1.0), 440.0);
        assert(score.voiced == 0);
    }

    // Repeated capture through one session must not depend on history left by
    // the previous one -- reset has to clear the ring, the parity estimate and
    // the decoder's retained window together.
    {
        UnifiedPitchSession session;
        (void)drive(session, sawtooth_tone(294.0, 0.6));
        session.reset();
        const auto frames = drive(session, sawtooth_tone(880.0, 0.6));
        std::size_t voiced = 0;
        for (const auto& frame : frames) {
            if (!frame.frequency_hz) continue;
            ++voiced;
            assert(std::abs(1200.0 * std::log2(*frame.frequency_hz / 880.0)) <= 50.0);
        }
        assert(voiced > 0);
    }

    std::cout << "KlariVision unified pitch session tests passed.\n";
}
