#include "klarivision/core/hapt.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

namespace {

double centered_rms(const std::span<const float> samples) {
    if (samples.empty()) return 0.0;
    const auto mean = std::accumulate(
        samples.begin(), samples.end(), 0.0,
        [](const double sum, const float sample) { return sum + static_cast<double>(sample); }
    ) / static_cast<double>(samples.size());
    double sum = 0.0;
    for (const auto sample : samples) {
        const auto centered = static_cast<double>(sample) - mean;
        sum += centered * centered;
    }
    return std::sqrt(sum / static_cast<double>(samples.size()));
}

double number(const char* text, const char* label) {
    char* end = nullptr;
    const auto value = std::strtod(text, &end);
    if (end == text || *end != '\0') {
        std::cerr << "Invalid " << label << ": " << text << '\n';
        std::exit(2);
    }
    return value;
}

}  // namespace

/// CSV trace of the causal, stateful hapt_v1 publication path -- used by the
/// Python tournament adapter (scripts/pitch_tournament_engines.py) and by
/// threshold calibration against data/benchmarks/, mirroring
/// klarivision_vpm_like_trace's usage.
int main(int argc, char** argv) {
    if (argc != 6) {
        std::cerr << "usage: hapt_trace input.f32 sample_rate window hop minimum_rms\n";
        return 2;
    }

    const std::string input_path = argv[1];
    const auto sample_rate = number(argv[2], "sample rate");
    const auto window = static_cast<std::size_t>(number(argv[3], "window"));
    const auto hop = static_cast<std::size_t>(number(argv[4], "hop"));

    klarivision::core::HAPTConfig config;
    config.minimum_rms = number(argv[5], "minimum RMS");

    std::ifstream stream(input_path, std::ios::binary);
    if (!stream) {
        std::cerr << "Cannot open " << input_path << '\n';
        return 2;
    }
    stream.seekg(0, std::ios::end);
    const auto byte_count = static_cast<std::size_t>(stream.tellg());
    if (byte_count % sizeof(float) != 0) {
        std::cerr << "Input size is not a sequence of Float32 samples\n";
        return 2;
    }
    std::vector<float> samples(byte_count / sizeof(float));
    stream.seekg(0, std::ios::beg);
    stream.read(reinterpret_cast<char*>(samples.data()), static_cast<std::streamsize>(byte_count));

    std::cout << "time_seconds,frequency_hz,confidence\n" << std::fixed << std::setprecision(8);
    klarivision::core::HAPTTracker tracker(config);
    for (std::size_t end = window; end <= samples.size(); end += hop) {
        const std::span<const float> frame(samples.data() + end - window, window);
        const auto estimate = klarivision::core::estimate_hapt_pitch(
            frame, sample_rate, config, tracker.published_frequency_hz()
        );
        const auto pitch = tracker.process(estimate, centered_rms(frame));
        if (pitch) {
            std::cout << static_cast<double>(end) / sample_rate << ','
                      << pitch->frequency_hz << ',' << pitch->confidence << '\n';
        }
    }
    return 0;
}
