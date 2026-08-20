#include "klarivision/core/pitch_engine_v2_session.hpp"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 7) {
        std::cerr << "usage: pitch_engine_v2_trace INPUT.f32 RATE WINDOW HOP MINIMUM_RMS START_TIME\n";
        return 2;
    }
    std::ifstream input(argv[1], std::ios::binary);
    if (!input) return 3;
    input.seekg(0, std::ios::end);
    const auto byte_count = input.tellg();
    input.seekg(0, std::ios::beg);
    std::vector<float> samples(static_cast<std::size_t>(byte_count) / sizeof(float));
    input.read(reinterpret_cast<char*>(samples.data()), byte_count);
    const double rate = std::stod(argv[2]);
    const auto window = static_cast<std::size_t>(std::stoull(argv[3]));
    const auto hop = static_cast<std::size_t>(std::stoull(argv[4]));
    const double minimum_rms = std::stod(argv[5]);
    const double start_time = std::stod(argv[6]);
    klarivision::core::v2::PitchEngineV2Session session(minimum_rms, 5);
    std::cout << "time,frequency,confidence\n" << std::setprecision(17);
    for (std::size_t end = window; end <= samples.size(); end += hop) {
        const double source_time = start_time +
            (static_cast<double>(end) - static_cast<double>(window) / 2) / rate;
        const auto frames = session.process_frame(
            std::span<const float>(samples.data() + end - window, window), rate, source_time
        );
        for (const auto& frame : frames) {
            std::cout << frame.time_seconds << ',' << frame.frequency_hz << ','
                      << frame.confidence << '\n';
        }
    }
    for (const auto& frame : session.finish()) {
        std::cout << frame.time_seconds << ',' << frame.frequency_hz << ','
                  << frame.confidence << '\n';
    }
}
