#pragma once

#include <optional>
#include <span>

namespace klarivision::core::v2 {

/// Identifies the independent estimator that proposed a pitch candidate.
/// V2 keeps this provenance instead of collapsing every observation into one
/// early YIN decision.
enum class CandidateSource {
    yin,
    autocorrelation,
    mpm,
    spectral,
};

struct PitchCandidate {
    double frequency_hz{};
    double periodicity{};
    double harmonic_support{};
    CandidateSource source{CandidateSource::yin};
    bool agreement_support{};
};

struct SelectionContext {
    std::optional<double> previous_frequency_hz{};
    double continuity_width_cents{700.0};
};

struct SelectedPitch {
    PitchCandidate candidate{};
    double score{};
};

/// Initial, deliberately small V2 selection boundary. Candidate generation,
/// prime-harmonic scoring and the fixed-lag path tracker can evolve behind
/// this interface without changing the stable V1 engine or platform UIs.
std::optional<SelectedPitch> select_candidate(
    std::span<const PitchCandidate> candidates,
    const SelectionContext& context = {}
);

}  // namespace klarivision::core::v2
