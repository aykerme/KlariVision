#include "klarivision/core/vpm_like.hpp"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <span>
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

void boolean(const bool value) {
    std::cout << (value ? "true" : "false");
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 9) {
        std::cerr << "usage: vpm_like_diagnostics input.f64 sample_rate window hop start end "
                  << "absolute_spectrum allow_spectral_promotion\n";
        return 2;
    }
    const std::string input_path = argv[1];
    const auto sample_rate = number(argv[2], "sample rate");
    const auto window = static_cast<std::size_t>(number(argv[3], "window"));
    const auto hop = static_cast<std::size_t>(number(argv[4], "hop"));
    const auto start_seconds = number(argv[5], "start seconds");
    const auto end_seconds = number(argv[6], "end seconds");
    klarivision::core::VPMLikeConfig config;
    config.minimum_absolute_spectral_amplitude = number(argv[7], "absolute spectrum");
    config.allow_spectral_promotion = number(argv[8], "allow spectral promotion") != 0.0;

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

    std::cout << std::fixed << std::setprecision(10);
    for (std::size_t end = window; end <= samples.size(); end += hop) {
        const auto time_seconds = static_cast<double>(end) / sample_rate;
        if (time_seconds < start_seconds || time_seconds > end_seconds) {
            continue;
        }
        const std::span<const double> frame(samples.data() + end - window, window);
        const auto diagnostic = klarivision::core::diagnose_vpm_like_pitch(frame, sample_rate, config);
        std::cout << "{\"time_seconds\":" << time_seconds
                  << ",\"rms\":" << diagnostic.rms
                  << ",\"strongest_periodicity\":" << diagnostic.strongest_periodicity
                  << ",\"acceptance_periodicity\":" << diagnostic.acceptance_periodicity
                  << ",\"autocorrelation_frequency_hz\":"
                  << diagnostic.autocorrelation_frequency_hz
                  << ",\"decision\":\"" << diagnostic.decision << "\"";
        if (diagnostic.pitch) {
            std::cout << ",\"frequency_hz\":" << diagnostic.pitch->frequency_hz
                      << ",\"confidence\":" << diagnostic.pitch->confidence;
        } else {
            std::cout << ",\"frequency_hz\":null,\"confidence\":null";
        }
        std::cout << ",\"autocorrelation_candidates\":[";
        for (std::size_t index = 0; index < diagnostic.autocorrelation_candidates.size(); ++index) {
            const auto& candidate = diagnostic.autocorrelation_candidates[index];
            if (index) std::cout << ',';
            std::cout << "{\"lag_samples\":" << candidate.lag_samples
                      << ",\"frequency_hz\":" << candidate.frequency_hz
                      << ",\"periodicity\":" << candidate.periodicity
                      << ",\"strongest\":";
            boolean(candidate.strongest);
            std::cout << ",\"near_strongest_accepted\":";
            boolean(candidate.near_strongest_accepted);
            std::cout << ",\"selected\":";
            boolean(candidate.selected);
            std::cout << '}';
        }
        std::cout << "],\"spectral_candidates\":[";
        for (std::size_t index = 0; index < diagnostic.spectral_candidates.size(); ++index) {
            const auto& candidate = diagnostic.spectral_candidates[index];
            if (index) std::cout << ',';
            std::cout << "{\"multiplier\":" << candidate.multiplier
                      << ",\"frequency_hz\":" << candidate.frequency_hz
                      << ",\"periodicity\":" << candidate.periodicity
                      << ",\"amplitude\":" << candidate.amplitude
                      << ",\"base_amplitude\":" << candidate.base_amplitude
                      << ",\"relative_amplitude\":" << candidate.relative_amplitude
                      << ",\"left_amplitude\":" << candidate.left_amplitude
                      << ",\"right_amplitude\":" << candidate.right_amplitude
                      << ",\"in_range\":";
            boolean(candidate.in_range);
            std::cout << ",\"local_peak\":";
            boolean(candidate.local_peak);
            std::cout << ",\"absolute_support\":";
            boolean(candidate.absolute_support);
            std::cout << ",\"relative_support\":";
            boolean(candidate.relative_support);
            std::cout << ",\"selected\":";
            boolean(candidate.selected);
            std::cout << ",\"decision\":\"" << candidate.decision << "\"}";
        }
        std::cout << "]}\n";
    }
}
