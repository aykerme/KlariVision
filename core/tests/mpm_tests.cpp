#include "klarivision/core/mpm.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <vector>

using klarivision::core::v2::mpm_candidates;

namespace {

std::vector<float> tone(const double frequency, const bool clarinet_like = false) {
    constexpr double sample_rate = 44100.0;
    std::vector<float> samples(4096);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto phase = 2.0 * std::numbers::pi * frequency *
            static_cast<double>(index) / sample_rate;
        auto value = std::sin(phase);
        if (clarinet_like) {
            value = 0.35 * value + 0.80 * std::sin(3.0 * phase) +
                0.30 * std::sin(5.0 * phase);
        }
        samples[index] = static_cast<float>(value * 0.5);
    }
    return samples;
}

bool contains_near(const std::vector<klarivision::core::v2::PitchCandidate>& candidates,
                   const double expected,
                   const double cents = 15.0) {
    return std::any_of(candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return std::abs(1200.0 * std::log2(candidate.frequency_hz / expected)) <= cents;
    });
}

}  // namespace

int main() {
    const auto sine_candidates = mpm_candidates(tone(220.0), 44100.0);
    assert(contains_near(sine_candidates, 220.0));

    // The fundamental remains an explicit option even when the clarinet-like
    // third harmonic is much stronger than the first partial.
    const auto clarinet_candidates = mpm_candidates(tone(146.83, true), 44100.0);
    assert(contains_near(clarinet_candidates, 146.83));

    const std::vector<float> silence(4096, 0.0F);
    assert(mpm_candidates(silence, 44100.0).empty());

    std::cout << "KlariVision Core MPM/NSDF tests passed.\n";
}
