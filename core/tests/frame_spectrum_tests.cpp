#include "klarivision/core/frame_spectrum.hpp"
#include "klarivision/core/unified_pitch_constants.hpp"

#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <vector>

using klarivision::core::AnalysisBand;
using klarivision::core::compute_frame_spectrum;
using klarivision::core::compute_multi_resolution_spectra;

namespace {

std::vector<float> sine_tone(const double frequency_hz, const double sample_rate, const std::size_t count) {
    std::vector<float> samples(count);
    for (std::size_t index = 0; index < count; ++index) {
        samples[index] = static_cast<float>(
            std::sin(2.0 * std::numbers::pi * frequency_hz * static_cast<double>(index) / sample_rate)
        );
    }
    return samples;
}

}  // namespace

int main() {
    constexpr double sample_rate = 48'000.0;

    // 1. A pure 440 Hz tone: amplitude_at(440) must dominate a 200-2000 Hz
    // sweep and dwarf the neighbouring 660 Hz bin, which carries only leakage.
    {
        const auto samples = sine_tone(440.0, sample_rate, klarivision::core::unified::kMidWindowSamples);
        const auto spectrum = compute_frame_spectrum(samples, sample_rate, AnalysisBand::mid);

        double peak_amplitude = 0.0;
        double peak_frequency = 0.0;
        for (double hz = 200.0; hz <= 2000.0; hz += 1.0) {
            const auto amplitude = spectrum.amplitude_at(hz);
            if (amplitude > peak_amplitude) {
                peak_amplitude = amplitude;
                peak_frequency = hz;
            }
        }
        assert(std::abs(peak_frequency - 440.0) < 2.0);
        const auto amplitude_440 = spectrum.amplitude_at(440.0);
        const auto amplitude_660 = spectrum.amplitude_at(660.0);
        assert(amplitude_440 >= peak_amplitude - 1e-9);
        assert(amplitude_440 >= 20.0 * amplitude_660);
    }

    // 2. for_frequency picks low/mid/high at 100/400/1200 Hz.
    {
        const auto samples = sine_tone(300.0, sample_rate, klarivision::core::unified::kHistorySamples);
        const auto spectra = compute_multi_resolution_spectra(samples, sample_rate);
        assert(&spectra.for_frequency(100.0) == &spectra.low);
        assert(&spectra.for_frequency(400.0) == &spectra.mid);
        assert(&spectra.for_frequency(1200.0) == &spectra.high);
    }

    // 3. is_band_edge: true within 15% of 160/800 Hz, false well inside a band.
    {
        const auto samples = sine_tone(300.0, sample_rate, klarivision::core::unified::kHistorySamples);
        const auto spectra = compute_multi_resolution_spectra(samples, sample_rate);
        assert(spectra.is_band_edge(150.0));
        assert(spectra.is_band_edge(170.0));
        assert(!spectra.is_band_edge(300.0));
    }

    // 4. Short history is left-padded, not truncated or overrun: must not
    // crash and must still end on the newest sample (so a tone right at the
    // end of a short buffer is still visible).
    {
        const auto short_history = sine_tone(440.0, sample_rate, 100);
        const auto spectra = compute_multi_resolution_spectra(short_history, sample_rate);
        assert(spectra.low.window_size == klarivision::core::unified::kLowWindowSamples);
        assert(spectra.mid.window_size == klarivision::core::unified::kMidWindowSamples);
        assert(spectra.high.window_size == klarivision::core::unified::kHighWindowSamples);
        // Some energy near 440 Hz must have survived the padding.
        assert(spectra.mid.amplitude_at(440.0) > 0.0);

        // Degenerate/empty input must not crash and must read back as silence.
        const std::vector<float> empty_history;
        const auto empty_spectra = compute_multi_resolution_spectra(empty_history, sample_rate);
        assert(empty_spectra.mid.amplitude_at(440.0) == 0.0);
    }

    // 5. Shorter windows have coarser (larger) frequency resolution.
    {
        const auto samples = sine_tone(300.0, sample_rate, klarivision::core::unified::kHistorySamples);
        const auto spectra = compute_multi_resolution_spectra(samples, sample_rate);
        assert(spectra.high.resolution_half_width_hz() > spectra.low.resolution_half_width_hz());
    }

    std::cout << "KlariVision Core frame spectrum tests passed.\n";
}
