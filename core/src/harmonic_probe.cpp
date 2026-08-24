#include "klarivision/core/harmonic_probe.hpp"

#include <cmath>
#include <numbers>

namespace klarivision::core {

std::complex<double> hann_windowed_probe(
    const std::span<const float> samples,
    const double sample_rate,
    const double frequency_hz
) {
    if (samples.size() <= 8 || sample_rate <= 0.0 || frequency_hz <= 0.0) {
        return {};
    }
    const auto denominator = static_cast<double>(samples.size() - 1);
    const auto step = 2.0 * std::numbers::pi * frequency_hz / sample_rate;
    double real = 0.0;
    double imaginary = 0.0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) / denominator
        );
        const auto value = static_cast<double>(samples[index]) * window;
        const auto phase = step * static_cast<double>(index);
        real += value * std::cos(phase);
        imaginary += value * std::sin(phase);
    }
    return {real, imaginary};
}

double hann_main_lobe_half_width_hz(const std::size_t sample_count, const double sample_rate) {
    if (sample_count == 0 || sample_rate <= 0.0) {
        return 0.0;
    }
    // A Hann window's main lobe spans 4 DFT bins; half of that, in Hz, is
    // 2 * bin_width = 2 * sample_rate / sample_count.
    return 2.0 * sample_rate / static_cast<double>(sample_count);
}

}  // namespace klarivision::core
