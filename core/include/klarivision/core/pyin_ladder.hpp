#pragma once

#include "klarivision/core/frame_spectrum.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"

#include <cstddef>
#include <span>
#include <vector>

namespace klarivision::core {

/// One period hypothesis with the probability mass the threshold sweep gave it.
struct PyinCandidate {
    double frequency_hz{};
    /// Summed prior mass of every threshold this lag won under, in [0, 1].
    double period_probability{};
    /// d'(tau) at the refined lag: YIN's aperiodic-to-total power ratio.
    double cmnd_value{};
    /// Which window this hypothesis was measured through.
    AnalysisBand band{AnalysisBand::mid};
    /// True when the lag only won via the absolute-minimum fallback, which
    /// carries the small p_a prior rather than a threshold's own mass.
    bool from_absolute_minimum{false};
};

struct PyinLadderResult {
    /// Descending by period_probability. Never longer than
    /// unified::kMaximumCandidates.
    std::vector<PyinCandidate> candidates{};
    /// 1 - (probability mass left unassigned by the sweep). pYIN gets the
    /// voicing decision out of the same sweep rather than from a separate
    /// energy heuristic.
    double voiced_probability{};
    /// What single-threshold YIN at s = 0.10 would have answered. It is always
    /// present in `candidates` as well -- that property is why a candidate
    /// ladder can never score worse than the classic estimator it contains.
    double classic_yin_frequency_hz{};
};

struct PyinLadderConfig {
    double minimum_frequency_hz{unified::kEstimatorMinimumHz};
    double maximum_frequency_hz{unified::kEstimatorMaximumHz};
    /// YIN's step 6 ("best local estimate") searches this much time around the
    /// chosen lag for a better d', then re-runs the search restricted to
    /// +/- best_local_refine_fraction of it. In the YIN paper this one step
    /// removes about a third of the remaining errors, and it costs nothing:
    /// it only re-reads the d' array that was already computed.
    double best_local_window_seconds{0.025};
    double best_local_refine_fraction{0.20};
    /// Prior mass reserved for the absolute-minimum fallback used when no lag
    /// falls under any threshold.
    double absolute_minimum_prior{0.01};
    bool apply_high_pass{true};
};

/// Runs the threshold-distribution ladder over all three analysis bands.
///
/// The 100-threshold sweep does not need 100 YIN passes. d'(tau) is computed
/// once per band; its local minima are sorted by lag, the thresholds are
/// sorted ascending, and a single simultaneous walk assigns each threshold its
/// winner and accumulates that winner's prior. The bands cover disjoint lag
/// ranges, so the total work is only slightly more than one mid-window scan.
///
/// `history` must end on the newest sample and hold at least
/// unified::kHistorySamples entries.
[[nodiscard]] PyinLadderResult pyin_ladder(
    std::span<const float> history,
    double sample_rate,
    const PyinLadderConfig& config = {}
);

}  // namespace klarivision::core
