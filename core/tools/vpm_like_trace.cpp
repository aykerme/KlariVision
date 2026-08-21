#include "klarivision/core/vpm_like.hpp"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

namespace {

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

int main(int argc, char** argv) {
    if (argc != 12) {
        std::cerr
            << "usage: vpm_like_trace input.f64 sample_rate window hop "
            << "minimum_periodicity near_ratio relative_spectrum absolute_spectrum "
            << "max_multiple allow_spectral_promotion minimum_rms\n";
        return 2;
    }

    const std::string input_path = argv[1];
    const auto sample_rate = number(argv[2], "sample rate");
    const auto window = static_cast<std::size_t>(number(argv[3], "window"));
    const auto hop = static_cast<std::size_t>(number(argv[4], "hop"));
    klarivision::core::VPMLikeConfig config;
    config.minimum_periodicity = number(argv[5], "minimum periodicity");
    config.near_strongest_ratio = number(argv[6], "near ratio");
    config.minimum_relative_spectral_amplitude = number(argv[7], "relative spectrum");
    config.minimum_absolute_spectral_amplitude = number(argv[8], "absolute spectrum");
    config.maximum_period_multiple = static_cast<int>(number(argv[9], "max multiple"));
    config.allow_spectral_promotion = number(argv[10], "allow spectral promotion") != 0.0;
    config.minimum_rms = number(argv[11], "minimum RMS");

    std::ifstream stream(input_path, std::ios::binary);
    if (!stream) {
        std::cerr << "Cannot open " << input_path << '\n';
        return 2;
    }
    stream.seekg(0, std::ios::end);
    const auto byte_count = static_cast<std::size_t>(stream.tellg());
    if (byte_count % sizeof(double) != 0) {
        std::cerr << "Input size is not a sequence of Float64 samples\n";
        return 2;
    }
    std::vector<double> samples(byte_count / sizeof(double));
    stream.seekg(0, std::ios::beg);
    stream.read(reinterpret_cast<char*>(samples.data()), static_cast<std::streamsize>(byte_count));

    std::cout << "time_seconds,frequency_hz,confidence\n" << std::fixed << std::setprecision(8);
    klarivision::core::VPMLikeTracker tracker;
    for (std::size_t end = window; end <= samples.size(); end += hop) {
        const std::span<const double> frame(samples.data() + end - window, window);
        const auto estimate = klarivision::core::estimate_vpm_like_pitch(frame, sample_rate, config);
        std::optional<double> established_support;
        if (estimate) {
            // Use the existing contour's spectral line only to veto a short
            // lower harmonic island; never to promote a new upper candidate.
            established_support = 0.005;
        }
        const auto pitch = tracker.process(estimate, established_support);
        if (pitch) {
            std::cout << static_cast<double>(end) / sample_rate << ','
                      << pitch->frequency_hz << ',' << pitch->confidence << '\n';
        }
    }
    return 0;
}
