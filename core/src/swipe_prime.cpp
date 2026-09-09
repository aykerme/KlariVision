#include "klarivision/core/swipe_prime.hpp"

#include <algorithm>
#include <cmath>

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

// Reads the sqrt-compressed spectrum at an arbitrary frequency by linearly
// interpolating between the two nearest bins, so score_candidate can probe
// harmonics that don't land exactly on a bin centre.
//
// Deliberately interpolates in the sqrt domain rather than calling
// FrameSpectrum::amplitude_at() and taking the root afterwards: SWIPE'
// compresses first and the peak-minus-valley term below is a difference of
// compressed values, so doing it the other way round changes the kernel, not
// just the arithmetic order.
double interpolated_value(
    const std::vector<double>& square_root_spectrum,
    const double sample_rate,
    const std::size_t fft_size,
    const double frequency
) {
    if (frequency <= 0.0 || frequency >= sample_rate / 2.0 || square_root_spectrum.empty()) {
        return 0.0;  // outside the representable (0, Nyquist) range
    }
    const auto position = frequency * static_cast<double>(fft_size) / sample_rate;  // frequency -> fractional FFT bin index
    const auto lower = static_cast<std::size_t>(std::floor(position));               // bin just below the target frequency
    if (lower + 1 >= square_root_spectrum.size()) {
        return 0.0;  // upper neighbour bin would be out of range
    }
    const auto fraction = position - static_cast<double>(lower);  // how far past `lower` the target frequency sits, in [0, 1)
    return square_root_spectrum[lower] * (1.0 - fraction) + square_root_spectrum[lower + 1] * fraction;  // linear interpolation
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
    const FrameSpectrum& spectrum,
    const std::span<const double> candidate_frequencies_hz,
    const double maximum_analysis_frequency_hz
) {
    std::vector<double> supports(candidate_frequencies_hz.size(), 0.0);  // one output score per input candidate, defaulting to 0
    if (spectrum.magnitude.empty() || spectrum.fft_size == 0 ||
        spectrum.sample_rate <= 0.0 || candidate_frequencies_hz.empty()) {
        return supports;  // no spectrum, or nothing to score
    }

    // SWIPE' works on sqrt-magnitude (amplitude^0.5) rather than raw
    // magnitude or power; this compresses the dynamic range so that a single
    // very loud harmonic doesn't dominate the score. FrameSpectrum stores raw
    // magnitude because its other callers (TWM, fundamental presence) want
    // linear amplitude ratios, so the compression happens here, once per
    // frame rather than once per probe.
    std::vector<double> square_root_spectrum(spectrum.magnitude.size());
    for (std::size_t index = 0; index < square_root_spectrum.size(); ++index) {
        square_root_spectrum[index] = std::sqrt(spectrum.magnitude[index]);
    }

    // Score every candidate frequency independently against the same
    // spectrum.
    for (std::size_t index = 0; index < candidate_frequencies_hz.size(); ++index) {
        supports[index] = score_candidate(
            square_root_spectrum,
            spectrum.sample_rate,
            spectrum.fft_size,
            candidate_frequencies_hz[index],
            maximum_analysis_frequency_hz
        );  // fill in this candidate's SWIPE'-style support score
    }
    return supports;
}

}  // namespace klarivision::core::v2
