#include "klarivision/core/swipe_prime.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <numbers>

namespace klarivision::core::v2 {
namespace {

bool is_prime(const int value) {
    if (value < 2) {
        return false;
    }
    for (auto divisor = 2; divisor * divisor <= value; ++divisor) {
        if (value % divisor == 0) {
            return false;
        }
    }
    return true;
}

std::size_t next_power_of_two(const std::size_t value) {
    auto result = std::size_t{1};
    while (result < value) {
        result <<= 1U;
    }
    return result;
}

void fft(std::vector<std::complex<double>>& values) {
    const auto count = values.size();
    for (std::size_t index = 1, reversed = 0; index < count; ++index) {
        auto bit = count >> 1U;
        while ((reversed & bit) != 0U) {
            reversed ^= bit;
            bit >>= 1U;
        }
        reversed ^= bit;
        if (index < reversed) {
            std::swap(values[index], values[reversed]);
        }
    }

    for (auto length = std::size_t{2}; length <= count; length <<= 1U) {
        const auto angle = -2.0 * std::numbers::pi / static_cast<double>(length);
        const auto step = std::complex<double>{std::cos(angle), std::sin(angle)};
        for (std::size_t start = 0; start < count; start += length) {
            auto weight = std::complex<double>{1.0, 0.0};
            for (std::size_t offset = 0; offset < length / 2; ++offset) {
                const auto even = values[start + offset];
                const auto odd = values[start + offset + length / 2] * weight;
                values[start + offset] = even + odd;
                values[start + offset + length / 2] = even - odd;
                weight *= step;
            }
        }
    }
}

double interpolated_value(
    const std::vector<double>& spectrum,
    const double sample_rate,
    const std::size_t fft_size,
    const double frequency
) {
    if (frequency <= 0.0 || frequency >= sample_rate / 2.0 || spectrum.empty()) {
        return 0.0;
    }
    const auto position = frequency * static_cast<double>(fft_size) / sample_rate;
    const auto lower = static_cast<std::size_t>(std::floor(position));
    if (lower + 1 >= spectrum.size()) {
        return 0.0;
    }
    const auto fraction = position - static_cast<double>(lower);
    return spectrum[lower] * (1.0 - fraction) + spectrum[lower + 1] * fraction;
}

double score_candidate(
    const std::vector<double>& spectrum,
    const double sample_rate,
    const std::size_t fft_size,
    const double candidate_frequency,
    const double maximum_analysis_frequency
) {
    if (!std::isfinite(candidate_frequency) || candidate_frequency <= 0.0) {
        return 0.0;
    }
    const auto limit = std::min(maximum_analysis_frequency, sample_rate / 2.0 * 0.98);
    const auto maximum_harmonic = static_cast<int>(std::floor(limit / candidate_frequency));
    if (maximum_harmonic < 1) {
        return 0.0;
    }

    double inner_product = 0.0;
    double positive_kernel_norm_squared = 0.0;
    double spectrum_norm_squared = 0.0;
    for (auto harmonic = 1; harmonic <= maximum_harmonic; ++harmonic) {
        const auto peak = interpolated_value(
            spectrum, sample_rate, fft_size, candidate_frequency * harmonic
        );
        spectrum_norm_squared += peak * peak;

        if (harmonic != 1 && !is_prime(harmonic)) {
            continue;
        }
        const auto weight = 1.0 / std::sqrt(static_cast<double>(harmonic));
        const auto left_valley = interpolated_value(
            spectrum, sample_rate, fft_size, candidate_frequency * (harmonic - 0.5)
        );
        const auto right_valley = interpolated_value(
            spectrum, sample_rate, fft_size, candidate_frequency * (harmonic + 0.5)
        );
        inner_product += weight * (peak - 0.5 * (left_valley + right_valley));
        positive_kernel_norm_squared += weight * weight;
    }

    const auto denominator = std::sqrt(
        positive_kernel_norm_squared * spectrum_norm_squared
    );
    if (denominator <= 1e-12) {
        return 0.0;
    }
    return std::clamp(inner_product / denominator, 0.0, 1.0);
}

}  // namespace

std::vector<double> swipe_prime_harmonic_supports(
    const std::span<const float> samples,
    const double sample_rate,
    const std::span<const double> candidate_frequencies_hz,
    const double maximum_analysis_frequency_hz
) {
    std::vector<double> supports(candidate_frequencies_hz.size(), 0.0);
    if (samples.size() < 256 || sample_rate <= 0.0 || candidate_frequencies_hz.empty()) {
        return supports;
    }

    const auto fft_size = next_power_of_two(samples.size());
    std::vector<std::complex<double>> spectrum_buffer(fft_size);
    const auto window_denominator = static_cast<double>(std::max<std::size_t>(1, samples.size() - 1));
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / window_denominator
        );
        spectrum_buffer[index] = static_cast<double>(samples[index]) * window;
    }
    fft(spectrum_buffer);

    std::vector<double> square_root_spectrum(fft_size / 2 + 1);
    for (std::size_t index = 0; index < square_root_spectrum.size(); ++index) {
        square_root_spectrum[index] = std::sqrt(std::abs(spectrum_buffer[index]));
    }

    for (std::size_t index = 0; index < candidate_frequencies_hz.size(); ++index) {
        supports[index] = score_candidate(
            square_root_spectrum,
            sample_rate,
            fft_size,
            candidate_frequencies_hz[index],
            maximum_analysis_frequency_hz
        );
    }
    return supports;
}

}  // namespace klarivision::core::v2
