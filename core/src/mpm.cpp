#include "klarivision/core/mpm.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace klarivision::core::v2 {

std::vector<PitchCandidate> mpm_candidates(
    const std::span<const float> samples,
    const double sample_rate,
    const double minimum_frequency_hz,
    const double maximum_frequency_hz,
    const double minimum_clarity
) {
    if (samples.size() < 1024 || sample_rate <= 0.0 ||
        minimum_frequency_hz <= 0.0 || maximum_frequency_hz <= minimum_frequency_hz) {
        return {};
    }

    const auto mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
        static_cast<double>(samples.size());
    std::vector<double> centred(samples.size());
    double energy = 0.0;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        centred[index] = static_cast<double>(samples[index]) - mean;
        energy += centred[index] * centred[index];
    }
    const auto rms = std::sqrt(energy / static_cast<double>(samples.size()));
    if (rms <= 0.0001) {
        return {};
    }

    const auto minimum_lag = std::max(2, static_cast<int>(sample_rate / maximum_frequency_hz));
    const auto maximum_lag = std::min(
        static_cast<int>(samples.size() / 2),
        static_cast<int>(sample_rate / minimum_frequency_hz)
    );
    if (minimum_lag + 2 >= maximum_lag) {
        return {};
    }

    std::vector<double> nsdf(static_cast<std::size_t>(maximum_lag + 1), 0.0);
    for (auto lag = minimum_lag; lag <= maximum_lag; ++lag) {
        double correlation = 0.0;
        double normalisation = 0.0;
        const auto count = static_cast<int>(centred.size()) - lag;
        for (auto index = 0; index < count; ++index) {
            const auto leading = centred[static_cast<std::size_t>(index)];
            const auto delayed = centred[static_cast<std::size_t>(index + lag)];
            correlation += leading * delayed;
            normalisation += leading * leading + delayed * delayed;
        }
        if (normalisation > 1e-12) {
            nsdf[static_cast<std::size_t>(lag)] = 2.0 * correlation / normalisation;
        }
    }

    std::vector<PitchCandidate> candidates;
    for (auto lag = minimum_lag + 1; lag < maximum_lag; ++lag) {
        const auto previous = nsdf[static_cast<std::size_t>(lag - 1)];
        const auto current = nsdf[static_cast<std::size_t>(lag)];
        const auto next = nsdf[static_cast<std::size_t>(lag + 1)];
        if (current < minimum_clarity || current < previous || current <= next) {
            continue;
        }

        const auto denominator = previous - 2.0 * current + next;
        const auto correction = std::abs(denominator) > 1e-9
            ? std::clamp(0.5 * (previous - next) / denominator, -0.5, 0.5)
            : 0.0;
        const auto refined_lag = static_cast<double>(lag) + correction;
        const auto frequency = sample_rate / refined_lag;
        if (!std::isfinite(frequency) || frequency < minimum_frequency_hz ||
            frequency > maximum_frequency_hz) {
            continue;
        }
        candidates.push_back(PitchCandidate{
            frequency,
            std::clamp(current, 0.0, 1.0),
            0.0,
            CandidateSource::mpm,
        });
    }

    std::sort(candidates.begin(), candidates.end(), [](const auto& left, const auto& right) {
        return left.periodicity > right.periodicity;
    });
    if (candidates.size() > 12) {
        candidates.resize(12);
    }
    return candidates;
}

}  // namespace klarivision::core::v2
