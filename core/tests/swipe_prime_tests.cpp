#include "klarivision/core/swipe_prime.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <vector>

using klarivision::core::v2::swipe_prime_harmonic_supports;

namespace {

std::vector<float> harmonic_tone(const double fundamental) {
    constexpr double sample_rate = 44'100.0;
    std::vector<float> samples(4'096);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto phase = 2.0 * std::numbers::pi * fundamental *
            static_cast<double>(index) / sample_rate;
        double value = 0.0;
        for (const auto harmonic : {1, 3, 5, 7, 11}) {
            value += std::sin(phase * harmonic) / static_cast<double>(harmonic);
        }
        samples[index] = static_cast<float>(value * 0.55);
    }
    return samples;
}

}  // namespace

int main() {
    constexpr double fundamental = 220.0;
    const auto samples = harmonic_tone(fundamental);
    const std::array candidates{fundamental, fundamental / 2.0, fundamental * 2.0};
    const auto supports = swipe_prime_harmonic_supports(samples, 44'100.0, candidates);
    assert(supports.size() == candidates.size());
    assert(supports[0] > supports[1] + 0.10);
    assert(supports[0] > supports[2] + 0.10);
    assert(supports[0] > 0.50);

    // With a 330 Hz fundamental, both f/2 and f/3 are inside the live engine's
    // candidate range. Prime-only credit must keep both below the true pitch.
    constexpr double second_fundamental = 330.0;
    const auto second_samples = harmonic_tone(second_fundamental);
    const std::array subharmonics{
        second_fundamental,
        second_fundamental / 2.0,
        second_fundamental / 3.0,
    };
    const auto subharmonic_supports = swipe_prime_harmonic_supports(
        second_samples, 44'100.0, subharmonics
    );
    assert(subharmonic_supports[0] > subharmonic_supports[1] + 0.10);
    assert(subharmonic_supports[0] > subharmonic_supports[2] + 0.10);

    const std::vector<float> silence(4'096, 0.0F);
    const auto silent_support = swipe_prime_harmonic_supports(silence, 44'100.0, candidates);
    for (const auto support : silent_support) {
        assert(std::abs(support) < 1e-12);
    }

    std::cout << "KlariVision Core SWIPE'-like tests passed.\n";
}
