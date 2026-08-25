#include "klarivision/core/swipe_prime.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <numbers>

namespace klarivision::core::v2 {
namespace {

// Trial-division primality test used to pick out the "prime harmonics" that
// SWIPE' trusts (see score_candidate below): harmonic numbers that are prime
// are far less likely to also be a harmonic of some *other*, lower
// fundamental, so they are cleaner evidence for the candidate under test.
bool is_prime(const int value) {
    if (value < 2) {
        return false;  // 0, 1 and negatives are not prime
    }
    for (auto divisor = 2; divisor * divisor <= value; ++divisor) {  // only need to test up to sqrt(value)
        if (value % divisor == 0) {
            return false;  // found a factor, so not prime
        }
    }
    return true;  // no factor found
}

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

// Reads the (precomputed, sqrt-magnitude) spectrum at an arbitrary
// frequency by linearly interpolating between the two nearest FFT bins.
// This lets score_candidate probe harmonics that don't land exactly on a
// bin centre.
double interpolated_value(
    const std::vector<double>& spectrum,
    const double sample_rate,
    const std::size_t fft_size,
    const double frequency
) {
    if (frequency <= 0.0 || frequency >= sample_rate / 2.0 || spectrum.empty()) {
        return 0.0;  // outside the representable (0, Nyquist) range
    }
    const auto position = frequency * static_cast<double>(fft_size) / sample_rate;  // frequency -> fractional FFT bin index
    const auto lower = static_cast<std::size_t>(std::floor(position));               // bin just below the target frequency
    if (lower + 1 >= spectrum.size()) {
        return 0.0;  // upper neighbour bin would be out of range
    }
    const auto fraction = position - static_cast<double>(lower);  // how far past `lower` the target frequency sits, in [0, 1)
    return spectrum[lower] * (1.0 - fraction) + spectrum[lower + 1] * fraction;  // linear interpolation between the two bins
}

// SWIPE'-style spectral matching score for one candidate fundamental
// frequency, in [0, 1]. For every harmonic multiple of the candidate up to
// the analysis ceiling:
//   - its spectral magnitude always contributes to `spectrum_norm_squared`
//     (the normalisation term), so louder/busier spectra don't
//     automatically score higher;
//   - only the 1st harmonic and *prime*-numbered harmonics contribute to
//     the actual `inner_product` "positive kernel" evidence, each peak
//     compared against the average of its two neighbouring valleys
//     (peak - average(left, right valley)) so a genuine narrow harmonic
//     peak scores higher than a flat/noisy spectral region;
//   - each harmonic's contribution is weighted by 1/sqrt(harmonic), so
//     lower (more audible/reliable) harmonics matter more.
// The final score is a normalised inner product (cosine-similarity-like),
// clamped to [0, 1].
double score_candidate(
    const std::vector<double>& spectrum,
    const double sample_rate,
    const std::size_t fft_size,
    const double candidate_frequency,
    const double maximum_analysis_frequency
) {
    if (!std::isfinite(candidate_frequency) || candidate_frequency <= 0.0) {
        return 0.0;  // not a usable frequency
    }
    const auto limit = std::min(maximum_analysis_frequency, sample_rate / 2.0 * 0.98);  // cap analysis just below Nyquist
    const auto maximum_harmonic = static_cast<int>(std::floor(limit / candidate_frequency));  // how many harmonics fit under the ceiling
    if (maximum_harmonic < 1) {
        return 0.0;  // candidate frequency itself is already above the ceiling
    }

    double inner_product = 0.0;                  // accumulates the weighted peak-vs-valley evidence ("positive kernel")
    double positive_kernel_norm_squared = 0.0;    // accumulates the kernel's own squared weight, for normalisation
    double spectrum_norm_squared = 0.0;           // accumulates total spectral energy at all harmonic locations
    for (auto harmonic = 1; harmonic <= maximum_harmonic; ++harmonic) {  // walk every harmonic multiple of the candidate
        const auto peak = interpolated_value(
            spectrum, sample_rate, fft_size, candidate_frequency * harmonic
        );  // spectral amplitude exactly at this harmonic's frequency
        spectrum_norm_squared += peak * peak;  // every harmonic (not just prime ones) counts toward the energy normaliser

        if (harmonic != 1 && !is_prime(harmonic)) {
            continue;  // only the fundamental (harmonic 1) and prime harmonics contribute positive evidence
        }
        const auto weight = 1.0 / std::sqrt(static_cast<double>(harmonic));  // lower harmonics are weighted more heavily
        const auto left_valley = interpolated_value(
            spectrum, sample_rate, fft_size, candidate_frequency * (harmonic - 0.5)
        );  // spectral amplitude half a harmonic below this peak
        const auto right_valley = interpolated_value(
            spectrum, sample_rate, fft_size, candidate_frequency * (harmonic + 0.5)
        );  // spectral amplitude half a harmonic above this peak
        inner_product += weight * (peak - 0.5 * (left_valley + right_valley));  // peak height relative to its local baseline, weighted
        positive_kernel_norm_squared += weight * weight;  // track the kernel's own norm so the final score can be normalised
    }

    const auto denominator = std::sqrt(
        positive_kernel_norm_squared * spectrum_norm_squared
    );  // normalising factor (product of the two norms, square-rooted)
    if (denominator <= 1e-12) {
        return 0.0;  // no usable energy anywhere near this candidate's harmonics
    }
    return std::clamp(inner_product / denominator, 0.0, 1.0);  // normalised score, clamped into [0, 1]
}

}  // namespace

std::vector<double> swipe_prime_harmonic_supports(
    const std::span<const float> samples,
    const double sample_rate,
    const std::span<const double> candidate_frequencies_hz,
    const double maximum_analysis_frequency_hz
) {
    std::vector<double> supports(candidate_frequencies_hz.size(), 0.0);  // one output score per input candidate, defaulting to 0
    if (samples.size() < 256 || sample_rate <= 0.0 || candidate_frequencies_hz.empty()) {
        return supports;  // not enough signal, or nothing to score
    }

    // Apply a Hann window (reduces spectral leakage from the finite analysis
    // window) and zero-pad up to the next power of two so the FFT above can
    // run. Samples beyond the window length stay at the buffer's
    // default-constructed zero.
    const auto fft_size = next_power_of_two(samples.size());  // FFT length, rounded up (zero-padded) to a power of two
    std::vector<std::complex<double>> spectrum_buffer(fft_size);  // zero-initialised; entries beyond samples.size() stay zero (the padding)
    const auto window_denominator = static_cast<double>(std::max<std::size_t>(1, samples.size() - 1));  // Hann window normaliser (N-1)
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / window_denominator
        );  // Hann window coefficient at this sample, tapering to 0 at both edges
        spectrum_buffer[index] = static_cast<double>(samples[index]) * window;  // windowed sample, ready for the FFT
    }
    fft(spectrum_buffer);  // transform in place: spectrum_buffer now holds complex frequency-domain bins

    // SWIPE' works on sqrt-magnitude (amplitude^0.5) rather than raw
    // magnitude or power; this compresses the dynamic range so that a
    // single very loud harmonic doesn't dominate the score. Only the first
    // half of the (conjugate-symmetric, real-input) spectrum is kept.
    std::vector<double> square_root_spectrum(fft_size / 2 + 1);  // only the non-redundant half of the spectrum, DC through Nyquist
    for (std::size_t index = 0; index < square_root_spectrum.size(); ++index) {
        square_root_spectrum[index] = std::sqrt(std::abs(spectrum_buffer[index]));  // |complex bin| -> magnitude, then sqrt-compressed
    }

    // Score every candidate frequency independently against the same
    // spectrum.
    for (std::size_t index = 0; index < candidate_frequencies_hz.size(); ++index) {
        supports[index] = score_candidate(
            square_root_spectrum,
            sample_rate,
            fft_size,
            candidate_frequencies_hz[index],
            maximum_analysis_frequency_hz
        );  // fill in this candidate's SWIPE'-style support score
    }
    return supports;
}

}  // namespace klarivision::core::v2
