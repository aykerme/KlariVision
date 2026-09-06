#include "klarivision/core/frame_spectrum.hpp"

#include "klarivision/core/harmonic_probe.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <numbers>

namespace klarivision::core {
namespace {

// next_power_of_two, fft and interpolated_value used to be duplicated in
// swipe_prime.cpp, which transformed the same history a second time. That
// fold happened: swipe_prime.cpp now takes a FrameSpectrum and this is the
// only transform in the frame. These helpers are private to this file
// because nothing else needs them.

// Smallest power of two that is >= value; the FFT below only supports
// power-of-two lengths.
std::size_t next_power_of_two(const std::size_t value) {
    auto result = std::size_t{1};
    while (result < value) {
        result <<= 1U;  // double result until it covers value
    }
    return result;
}

// In-place iterative radix-2 Cooley-Tukey FFT (decimation-in-time).
// `values.size()` must already be a power of two. Two phases:
//   1. Bit-reversal permutation, so the butterfly network below can work
//      in place without needing extra buffers.
//   2. log2(count) butterfly passes, each combining pairs of sub-transforms
//      of doubling length using precomputed twiddle factors
//      (`step` = e^{-2*pi*i/length}, walked forward via repeated multiply).
void fft(std::vector<std::complex<double>>& values) {
    const auto count = values.size();  // transform length (power of two)
    // Phase 1: bit-reversal permutation -- reorder `values` so index i ends
    // up where its bit-reversed index would be, in place, via pairwise swaps.
    for (std::size_t index = 1, reversed = 0; index < count; ++index) {
        auto bit = count >> 1U;              // start at the most-significant bit
        while ((reversed & bit) != 0U) {      // carry propagation for the bit-reversed counter
            reversed ^= bit;                  // clear this bit in the reversed counter
            bit >>= 1U;                       // move to the next lower bit
        }
        reversed ^= bit;                      // set the first unset bit found
        if (index < reversed) {
            std::swap(values[index], values[reversed]);  // swap into bit-reversed position
        }
    }

    // Phase 2: iterative butterfly passes. `length` doubles each pass,
    // combining pairs of already-transformed halves of size length/2 into a
    // transform of size `length` (classic Cooley-Tukey recombination, done
    // bottom-up instead of via recursion).
    for (auto length = std::size_t{2}; length <= count; length <<= 1U) {
        const auto angle = -2.0 * std::numbers::pi / static_cast<double>(length);  // twiddle base angle for this stage
        const auto step = std::complex<double>{std::cos(angle), std::sin(angle)};  // e^{-2*pi*i/length}, the per-butterfly rotation
        for (std::size_t start = 0; start < count; start += length) {  // one sub-transform block per iteration
            auto weight = std::complex<double>{1.0, 0.0};  // twiddle factor for this butterfly, starts at 1 and rotates by `step`
            for (std::size_t offset = 0; offset < length / 2; ++offset) {
                const auto even = values[start + offset];                          // "even" half element
                const auto odd = values[start + offset + length / 2] * weight;     // "odd" half element, phase-rotated
                values[start + offset] = even + odd;               // butterfly sum -> lower half output
                values[start + offset + length / 2] = even - odd;  // butterfly difference -> upper half output
                weight *= step;  // advance the twiddle factor to the next offset
            }
        }
    }
}

// Reads a magnitude spectrum at an arbitrary frequency by linearly
// interpolating between the two nearest FFT bins.
double interpolated_value(
    const std::vector<double>& spectrum,
    const double sample_rate,
    const std::size_t fft_size,
    const double frequency
) {
    if (frequency < 0.0 || sample_rate <= 0.0 || frequency > sample_rate / 2.0 ||
        spectrum.empty() || fft_size == 0) {
        return 0.0;  // outside the representable [0, Nyquist] range or nothing to read
    }
    const auto position = frequency * static_cast<double>(fft_size) / sample_rate;  // frequency -> fractional FFT bin index
    const auto lower = static_cast<std::size_t>(std::floor(position));               // bin just below the target frequency
    if (lower >= spectrum.size()) {
        return 0.0;  // at or past Nyquist itself
    }
    if (lower + 1 >= spectrum.size()) {
        return spectrum[lower];  // exactly on the last bin (Nyquist): nothing to interpolate towards
    }
    const auto fraction = position - static_cast<double>(lower);  // how far past `lower` the target frequency sits, in [0, 1)
    return spectrum[lower] * (1.0 - fraction) + spectrum[lower + 1] * fraction;  // linear interpolation between the two bins
}

// Copies `window` into a zero-padded, left-aligned buffer of exactly
// `window_size` samples, taking the *last* `window_size` entries of
// `window` so the result always ends on the newest sample. Shorter input is
// left-padded with silence -- the correct behaviour at capture start, and
// the only way every band can end on the same sample regardless of how much
// history has accumulated yet.
std::vector<float> right_aligned_window(std::span<const float> history, std::size_t window_size) {
    std::vector<float> result(window_size, 0.0F);  // zero-initialised; the left pad, if any, stays zero
    if (history.empty() || window_size == 0) {
        return result;
    }
    const auto take = std::min(window_size, history.size());  // how many real samples we actually have
    std::copy(history.end() - static_cast<std::ptrdiff_t>(take), history.end(), result.end() - static_cast<std::ptrdiff_t>(take));
    return result;
}

}  // namespace

double FrameSpectrum::amplitude_at(const double frequency_hz) const {
    return interpolated_value(magnitude, sample_rate, fft_size, frequency_hz);
}

double FrameSpectrum::resolution_half_width_hz() const {
    // The main-lobe half-width is a property of the window length alone, so
    // this reuses the same probe-resolution guard the HAPT engine's
    // inter-harmonic veto uses: two partials closer than this in a spectrum
    // built from `window_size` samples cannot be told apart and must not be
    // scored as independent evidence.
    return hann_main_lobe_half_width_hz(window_size, sample_rate);
}

const FrameSpectrum& MultiResolutionSpectra::for_frequency(const double frequency_hz) const {
    if (frequency_hz < unified::kLowBandMaximumHz) {
        return low;
    }
    if (frequency_hz < unified::kMidBandMaximumHz) {
        return mid;
    }
    return high;
}

namespace {

// True when `frequency_hz` sits within `unified::kBandBlendFraction` of
// `edge_hz` (a relative, not absolute, tolerance -- the 800 Hz edge needs a
// much wider absolute window than the 160 Hz one for the same proportional
// ambiguity).
bool near_edge(const double frequency_hz, const double edge_hz) {
    if (edge_hz <= 0.0) {
        return false;
    }
    return std::abs(frequency_hz - edge_hz) / edge_hz <= unified::kBandBlendFraction;
}

}  // namespace

bool MultiResolutionSpectra::is_band_edge(const double frequency_hz) const {
    return near_edge(frequency_hz, unified::kLowBandMaximumHz) ||
        near_edge(frequency_hz, unified::kMidBandMaximumHz);
}

const FrameSpectrum& MultiResolutionSpectra::blend_partner(const double frequency_hz) const {
    // Each of the two edges only ever borders the two bands either side of
    // it, so the partner is simply "the other one of that pair" -- whichever
    // side `for_frequency` did *not* already pick.
    if (near_edge(frequency_hz, unified::kLowBandMaximumHz)) {
        return (frequency_hz < unified::kLowBandMaximumHz) ? mid : low;
    }
    if (near_edge(frequency_hz, unified::kMidBandMaximumHz)) {
        return (frequency_hz < unified::kMidBandMaximumHz) ? high : mid;
    }
    return for_frequency(frequency_hz);  // not near an edge: no blending, same as for_frequency
}

FrameSpectrum compute_frame_spectrum(
    const std::span<const float> window,
    const double sample_rate,
    const AnalysisBand band
) {
    FrameSpectrum spectrum;
    spectrum.window_size = window.size();
    spectrum.sample_rate = sample_rate;
    spectrum.band = band;
    if (window.empty() || sample_rate <= 0.0) {
        return spectrum;  // fft_size stays 0, magnitude stays empty: amplitude_at reads 0 everywhere
    }

    // fft_size needs to be a power of two >= window_size (the FFT's own
    // requirement) and the contract asks for at least 2x zero-padding
    // beyond the window for interpolation headroom. In practice 2x is not
    // quite enough: measured against a pure 440 Hz tone through the mid
    // (1536-sample) window, 2x padding puts the two nearest bins 11.7 Hz
    // apart and linear interpolation between them mislocates the peak by a
    // full 5 Hz. 4x padding halves the bin spacing again and the measured
    // peak lands within 0.1 Hz of the true frequency -- comfortably inside
    // what harmonic-relationship scoring at kHarmonicToleranceCents (90c,
    // i.e. tens of Hz at these frequencies) needs, at a cost the frame
    // budget easily absorbs (see the wall-clock measurement in the PR
    // report).
    const auto fft_size = next_power_of_two(window.size() * 4);
    spectrum.fft_size = fft_size;

    std::vector<std::complex<double>> buffer(fft_size);  // zero-initialised; entries beyond window.size() stay zero (the padding)
    const auto window_denominator = static_cast<double>(std::max<std::size_t>(1, window.size() - 1));  // Hann window normaliser (N-1)
    for (std::size_t index = 0; index < window.size(); ++index) {
        const auto hann = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / window_denominator
        );  // Hann window coefficient at this sample, tapering to 0 at both edges
        buffer[index] = static_cast<double>(window[index]) * hann;  // windowed sample, ready for the FFT
    }
    fft(buffer);  // transform in place: buffer now holds complex frequency-domain bins

    // Keep only the non-redundant half (DC through Nyquist) of the
    // conjugate-symmetric, real-input spectrum, as raw magnitude -- unlike
    // swipe_prime.cpp's sqrt-compressed SWIPE' kernel, callers here (TWM,
    // fundamental presence) want linear amplitude ratios.
    spectrum.magnitude.resize(fft_size / 2 + 1);
    for (std::size_t index = 0; index < spectrum.magnitude.size(); ++index) {
        spectrum.magnitude[index] = std::abs(buffer[index]);
    }
    return spectrum;
}

MultiResolutionSpectra compute_multi_resolution_spectra(
    const std::span<const float> history,
    const double sample_rate
) {
    MultiResolutionSpectra spectra;
    spectra.low = compute_frame_spectrum(
        right_aligned_window(history, unified::kLowWindowSamples), sample_rate, AnalysisBand::low
    );
    spectra.mid = compute_frame_spectrum(
        right_aligned_window(history, unified::kMidWindowSamples), sample_rate, AnalysisBand::mid
    );
    spectra.high = compute_frame_spectrum(
        right_aligned_window(history, unified::kHighWindowSamples), sample_rate, AnalysisBand::high
    );
    return spectra;
}

}  // namespace klarivision::core
