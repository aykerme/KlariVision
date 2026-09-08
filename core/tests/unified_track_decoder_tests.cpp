#include "klarivision/core/unified_track_decoder.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

using klarivision::core::UnifiedDecodedFrame;
using klarivision::core::UnifiedFrameEvidence;
using klarivision::core::UnifiedTrackDecoder;
using klarivision::core::decode_unified_track_globally;
using klarivision::core::publishable_frequency;
using klarivision::core::v2::CandidateSource;
using klarivision::core::v2::PitchCandidate;
using klarivision::core::v2::ScoredPitchCandidate;

namespace unified = klarivision::core::unified;

namespace {

// Emissions are log-domain, so a "probability" is passed through log() here to
// keep the tests readable in the units a caller actually thinks in.
ScoredPitchCandidate candidate(const double frequency, const double probability) {
    return {
        PitchCandidate{frequency, probability, probability, CandidateSource::yin},
        std::log(probability),
    };
}

UnifiedFrameEvidence frame(
    const std::vector<ScoredPitchCandidate>& candidates,
    const double unvoiced_probability
) {
    UnifiedFrameEvidence evidence{};
    evidence.rms = 0.1;
    evidence.signal_eligible = true;
    evidence.candidates = candidates;
    evidence.evidence.resize(candidates.size());
    evidence.unvoiced_emission = std::log(unvoiced_probability);
    return evidence;
}

bool close_to(const double value, const double expected, const double tolerance = 1e-6) {
    return std::abs(value - expected) < tolerance;
}

}  // namespace

int main() {
    // A single-frame octave excursion between stable neighbours must not win.
    // This is the failure mode the whole engine exists to remove: one frame of
    // locally stronger evidence at f/2, surrounded by frames that agree on f.
    {
        UnifiedTrackDecoder decoder(5);
        std::vector<double> resolved;
        for (int index = 0; index < 14; ++index) {
            const auto slipping = index == 4;
            const std::vector<ScoredPitchCandidate> candidates{
                candidate(294.0, slipping ? 0.30 : 0.80),
                candidate(147.0, slipping ? 0.65 : 0.15),
            };
            if (const auto decoded = decoder.push(frame(candidates, 0.05))) {
                assert(decoded->candidate);
                resolved.push_back(decoded->candidate->frequency_hz);
            }
        }
        while (const auto decoded = decoder.finish_next()) {
            assert(decoded->candidate);
            resolved.push_back(decoded->candidate->frequency_hz);
        }
        assert(resolved.size() == 14);
        for (const auto frequency : resolved) assert(close_to(frequency, 294.0, 0.001));
    }

    // A sustained register change over five frames is a real note change and
    // must be followed. Without this the decoder would simply be a low-pass
    // filter on pitch, and genuine twelfths on a clarinet would be rejected.
    {
        UnifiedTrackDecoder decoder(5);
        std::vector<double> resolved;
        for (int index = 0; index < 20; ++index) {
            const auto high = index >= 8;
            const std::vector<ScoredPitchCandidate> candidates{
                candidate(294.0, high ? 0.10 : 0.85),
                candidate(882.0, high ? 0.85 : 0.10),
            };
            if (const auto decoded = decoder.push(frame(candidates, 0.05))) {
                resolved.push_back(decoded->candidate->frequency_hz);
            }
        }
        while (const auto decoded = decoder.finish_next()) {
            resolved.push_back(decoded->candidate->frequency_hz);
        }
        assert(resolved.size() == 20);
        assert(close_to(resolved.front(), 294.0, 0.001));
        assert(close_to(resolved.back(), 882.0, 0.001));
    }

    // Two candidates an octave apart with equal evidence: the winner carries no
    // margin over its own subharmonic, so the frame must be published as
    // silence rather than as a coin flip.
    {
        const std::vector<ScoredPitchCandidate> tied{
            candidate(294.0, 0.45),
            candidate(147.0, 0.45),
        };
        std::vector<UnifiedFrameEvidence> sequence(9, frame(tied, 0.10));
        const auto decoded = decode_unified_track_globally(sequence);
        assert(decoded.size() == sequence.size());
        for (const auto& resolved : decoded) {
            assert(resolved.candidate);
            assert(resolved.harmonic_contest_mass > 0.4);
            assert(resolved.harmonic_dominance() < 0.6);
            assert(!publishable_frequency(resolved, unified::kRealtimeAbstention, 0.5));
            assert(!publishable_frequency(resolved, unified::kOfflineAbstention, 0.5));
        }
    }

    // The same shape, but with the fundamental decisively better supported:
    // now the frame is publishable under both policies.
    {
        const std::vector<ScoredPitchCandidate> decisive{
            candidate(294.0, 0.90),
            candidate(147.0, 0.02),
        };
        std::vector<UnifiedFrameEvidence> sequence(9, frame(decisive, 0.02));
        const auto decoded = decode_unified_track_globally(sequence);
        for (const auto& resolved : decoded) {
            assert(resolved.harmonic_dominance() > unified::kRealtimeAbstention.harmonic_dominance_floor);
            const auto published =
                publishable_frequency(resolved, unified::kRealtimeAbstention, 0.5);
            assert(published && close_to(*published, 294.0, 0.001));
        }
    }

    // A candidate outside the display range is an abstention, never a clamp.
    // Reporting a clamped value would publish a frequency the estimator never
    // believed, which is exactly what the guard band above the display range
    // exists to avoid.
    {
        const std::vector<ScoredPitchCandidate> too_high{candidate(2200.0, 0.95)};
        std::vector<UnifiedFrameEvidence> sequence(9, frame(too_high, 0.02));
        const auto decoded = decode_unified_track_globally(sequence);
        assert(decoded.front().candidate);
        assert(!publishable_frequency(decoded.front(), unified::kRealtimeAbstention, 0.5));
    }

    // Silence is a state on the path, not a gap in it: a genuinely quiet
    // stretch resolves as unvoiced and does not borrow pitch continuity across
    // itself.
    {
        std::vector<UnifiedFrameEvidence> sequence;
        for (int index = 0; index < 12; ++index) {
            const auto quiet = index >= 4 && index < 8;
            if (quiet) {
                sequence.push_back(frame({}, 0.95));
            } else {
                sequence.push_back(frame({candidate(294.0, 0.85)}, 0.05));
            }
        }
        const auto decoded = decode_unified_track_globally(sequence);
        assert(!decoded[5].candidate);
        assert(decoded[5].voiced_posterior < 0.5);
        assert(decoded[1].candidate && decoded[10].candidate);
    }

    // Offline abstains less readily than realtime by construction: a contest
    // that survives whole-file decoding is evidence, not a look-ahead shortage.
    {
        UnifiedDecodedFrame contested{};
        contested.candidate = PitchCandidate{294.0, 0.6, 0.6, CandidateSource::yin};
        contested.winner_posterior = 0.60;
        contested.voiced_posterior = 0.80;
        contested.harmonic_contest_mass = 0.15;
        // The rival's evidence is comparable, so the split posterior means the
        // frame really is undecided.
        contested.harmonic_evidence_ratio = 0.80;
        assert(contested.harmonic_dominance() > 0.75);
        assert(contested.harmonic_dominance() < 0.90);
        assert(!publishable_frequency(contested, unified::kRealtimeAbstention, 0.10));
        assert(publishable_frequency(contested, unified::kOfflineAbstention, 0.10));
    }

    // The same split posterior, but the rival is merely a partial of the note
    // being played: its own evidence is a fraction of the winner's. A thin
    // posterior here means the frame is crowded, not undecided, and silencing
    // it would throw away a correct answer. This is the case a missing
    // fundamental produces -- the partials that define the pitch draw real
    // mass precisely because they are really there.
    {
        UnifiedDecodedFrame crowded{};
        crowded.candidate = PitchCandidate{294.0, 0.6, 0.6, CandidateSource::yin};
        crowded.winner_posterior = 0.60;
        crowded.voiced_posterior = 0.80;
        crowded.harmonic_contest_mass = 0.15;
        crowded.harmonic_evidence_ratio = 0.10;
        assert(crowded.harmonic_dominance() < 0.90);
        const auto published =
            publishable_frequency(crowded, unified::kRealtimeAbstention, 0.10);
        assert(published && close_to(*published, 294.0, 0.001));
    }

    // GCD trap: two notes a perfect fifth apart (3:2, 150 Hz and 450 Hz,
    // standing in the decoder's own twelfth relationship at 450 = 3 x 150)
    // overlap for four frames in the middle of an otherwise clean 150 Hz
    // stretch. The 450 Hz relative's own emission is stronger every one of
    // those frames (probability 0.55 against 150's 0.30), but the path stays
    // on 150 throughout because switching for only four frames costs the
    // leap floor twice and the posterior mass this hands 150 clears the
    // dominance floor by inertia -- exactly the mechanism measured on the
    // sukru-tunar-ussak-taksim holdout at 164.63-164.80s. Before the
    // evidence-ratio ceiling this shipped as a confident, wrong 150 Hz;
    // reverting `harmonic_evidence_ratio_ceiling` (or raising it back past
    // ~1.83) makes this assert fail.
    {
        std::vector<UnifiedFrameEvidence> sequence;
        for (int index = 0; index < 8; ++index) {
            sequence.push_back(frame({candidate(150.0, 0.90)}, 0.02));
        }
        for (int index = 0; index < 4; ++index) {
            sequence.push_back(
                frame({candidate(150.0, 0.30), candidate(450.0, 0.55)}, 0.02)
            );
        }
        for (int index = 0; index < 8; ++index) {
            sequence.push_back(frame({candidate(150.0, 0.90)}, 0.02));
        }
        const auto decoded = decode_unified_track_globally(sequence);
        for (int index = 8; index < 12; ++index) {
            const auto& resolved = decoded[static_cast<std::size_t>(index)];
            assert(resolved.candidate && close_to(resolved.candidate->frequency_hz, 150.0, 0.001));
            // The dominance floor alone is fooled: posterior inertia keeps it
            // well clear of the offline 0.75 floor even though the rival's
            // raw evidence is stronger.
            assert(resolved.harmonic_dominance() > unified::kOfflineAbstention.harmonic_dominance_floor);
            assert(resolved.harmonic_evidence_ratio > unified::kHarmonicEvidenceRatioAbstainCeiling);
            assert(!publishable_frequency(resolved, unified::kOfflineAbstention, 1.0));
        }
        // Outside the overlap the fundamental is uncontested and publishes
        // normally under the same policy.
        assert(publishable_frequency(decoded.front(), unified::kOfflineAbstention, 1.0));
        assert(publishable_frequency(decoded.back(), unified::kOfflineAbstention, 1.0));
    }

    std::cout << "KlariVision unified track decoder tests passed.\n";
}
