#pragma once

#include <span>

namespace klarivision::core {

/// Verdict for whether a pitch candidate's own spectral line is real
/// acoustic content, or a ghost period produced purely by autocorrelation
/// symmetry when a much stronger harmonic multiple (2x or 3x) dominates the
/// analysis window.
///
/// A closed-pipe clarinet tone can carry a fundamental many times weaker
/// than its own third harmonic (the register's dominant partial), with no
/// energy at all at the second harmonic. Autocorrelation-family estimators
/// (YIN's CMND ladder, VPM-like's ACF ladder) then find a spuriously
/// competitive period at f/2 or f/3 -- a period with no corresponding
/// acoustic energy anywhere in the window. This check lets candidate
/// selection demote such a ghost so a real, already-present, merely-softer
/// candidate wins instead of being shadowed by it.
struct HarmonicExistence {
    bool is_ghost_subharmonic{false};
    double dominant_multiple_hz{};    // 0 if no dominant multiple was found
    double dominant_multiple_ratio{}; // amplitude(multiple) / amplitude(candidate)
};

/// Pure, stateless spectral check: does `candidate_hz` correspond to real
/// energy in `samples`, or is it dwarfed by its own 2x/3x multiple?
///
/// The threshold is deliberately conservative (many-fold amplitude
/// dominance) so an ordinary, legitimately soft fundamental -- ordinary
/// clarinet timbre routinely trails its own third harmonic by several times
/// -- is never mistaken for a ghost. Only a decisive, near-total absence of
/// energy at the candidate's own frequency, next to a clearly-present
/// harmonic multiple, is flagged.
HarmonicExistence spectral_existence(
    std::span<const float> samples,
    double sample_rate,
    double candidate_hz,
    double maximum_frequency_hz
);

}  // namespace klarivision::core
