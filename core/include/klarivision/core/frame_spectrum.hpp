#pragma once

#include <cstddef>
#include <span>
#include <vector>

namespace klarivision::core {

/// Which analysis window a frequency is measured through. One window cannot
/// serve 80 Hz and 1760 Hz at once, so each band carries its own.
enum class AnalysisBand { low, mid, high };

/// Magnitude spectrum of one analysis window, with O(1) lookup by frequency.
///
/// Existing callers probe the spectrum one frequency at a time in the time
/// domain, at O(N) per probe; with a dozen candidates and a dozen partials
/// each, that repeated work dominates. Computing the transform once per band
/// makes every subsequent harmonic query a bin interpolation.
struct FrameSpectrum {
    std::size_t fft_size{};
    std::size_t window_size{};
    double sample_rate{};
    AnalysisBand band{AnalysisBand::mid};
    /// Magnitude for bins [0, fft_size / 2], Hann-windowed.
    std::vector<double> magnitude{};

    /// Linear interpolation between neighbouring bins. Returns 0 for
    /// frequencies outside [0, Nyquist] or on an empty spectrum.
    [[nodiscard]] double amplitude_at(double frequency_hz) const;

    /// Half-width of the Hann main lobe for this window, in Hz. Two partials
    /// closer than this cannot be told apart and must not be scored as
    /// independent evidence.
    [[nodiscard]] double resolution_half_width_hz() const;
};

/// The three bands of one frame. All three end on the same, newest sample and
/// are built entirely from past samples, so none of them adds decision
/// latency relative to the mid window.
struct MultiResolutionSpectra {
    FrameSpectrum low{};
    FrameSpectrum mid{};
    FrameSpectrum high{};

    /// The band whose window is sized for this frequency.
    [[nodiscard]] const FrameSpectrum& for_frequency(double frequency_hz) const;

    /// True when `frequency_hz` sits within kBandBlendFraction of a band edge,
    /// meaning both adjacent bands should be scored and their evidence
    /// blended. Without this, notes shift as they cross a band boundary.
    [[nodiscard]] bool is_band_edge(double frequency_hz) const;

    /// The neighbouring band to blend with at an edge; equals
    /// for_frequency(frequency_hz) when the frequency is not near an edge.
    [[nodiscard]] const FrameSpectrum& blend_partner(double frequency_hz) const;
};

/// `history` must end on the newest sample and hold at least
/// unified::kHistorySamples entries; shorter input is left-padded with
/// silence, which is correct at capture start.
[[nodiscard]] MultiResolutionSpectra compute_multi_resolution_spectra(
    std::span<const float> history,
    double sample_rate
);

/// Single-band variant, for callers that need only one window.
[[nodiscard]] FrameSpectrum compute_frame_spectrum(
    std::span<const float> window,
    double sample_rate,
    AnalysisBand band = AnalysisBand::mid
);

}  // namespace klarivision::core
