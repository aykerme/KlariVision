#pragma once

#include <optional>

// Shared candidate vocabulary for the unified engine.
//
// These types were introduced with pitch_engine_v2 and outlived it: when the
// four legacy engines were removed (D-039) the candidate/provenance structs
// were the only part of that header the unified engine still needed, so they
// moved here and `pitch_engine_v2.hpp` (its selection API) was deleted.
//
// The enclosing namespace is still `v2` on purpose. Renaming it would touch
// every unified source, tool and test in the same commit that removes four
// engines, which would make that removal much harder to review. The rename is
// a separate, mechanical follow-up; nothing here depends on the name.
namespace klarivision::core::v2 {

/// Identifies the independent estimator that proposed a pitch candidate.
/// Provenance is kept rather than collapsed into one early decision: the
/// unified engine's arbitration prices a candidate partly by where it came
/// from.
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

}  // namespace klarivision::core::v2
