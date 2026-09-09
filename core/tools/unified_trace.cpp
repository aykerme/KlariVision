#include "klarivision/core/unified_pitch_session.hpp"

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

void write_diagnostic(const klarivision::core::UnifiedFrameDiagnostic& diagnostic) {
    // One row per *input* frame, published or not. The publication decision is
    // fixed-lag, so this row describes the frame that was just measured rather
    // than the frame that was just emitted -- which is what an attribution
    // question ("why is this note missing?") actually needs.
    std::cout << diagnostic.input_time_seconds << ',' << diagnostic.rms << ','
              << (diagnostic.signal_eligible ? 1 : 0) << ','
              << diagnostic.candidate_count << ',' << diagnostic.winner_posterior << ','
              << diagnostic.voiced_posterior << ',' << diagnostic.harmonic_dominance << ','
              << diagnostic.harmonic_evidence_ratio << ',' << diagnostic.family_margin << ','
              << diagnostic.parity_index << ',' << diagnostic.publication_reason << '\n';
}

void write_frame(const klarivision::core::EngineFrame& frame) {
    // Mirror hapt_trace.cpp: only a published (voiced) frame gets a row. A
    // withheld frame -- unified_v1's central mechanism, not a gap to bridge --
    // leaves no row, and the Python adapter must not paper over that with the
    // legacy bridging helpers built for the other engines' gap-filling.
    if (!frame.frequency_hz) return;
    std::cout << frame.time_seconds << ',' << *frame.frequency_hz << ',' << frame.confidence << '\n';
}

}  // namespace

/// CSV trace of the causal, stateful unified_v1 publication path -- used by
/// the Python tournament adapter (scripts/pitch_tournament_engines.py),
/// mirroring hapt_trace's usage. process_frame() takes one window_size window
/// per call, slid forward by hop_size between calls (exactly as
/// core/tests/unified_pitch_session_tests.cpp's drive() helper does) -- it is
/// NOT a call-once-with-the-whole-buffer API. window must equal
/// unified::kMidWindowSamples (1536) and hop must equal
/// unified::kHopSamples/kv_unified_lag_frames's own hop (512); both are
/// accepted as CLI arguments only for shape parity with the other *_trace
/// tools, not because any other value is supported here.
int main(int argc, char** argv) {
    // Optional trailing --diagnostic switches the output from "published
    // frames" to "every frame, with the reason it was published or withheld".
    // Kept as a mode of this tool rather than a second binary so both views
    // are guaranteed to come from the same session and the same constants.
    bool diagnostic_mode = false;
    if (argc > 1 && std::string(argv[argc - 1]) == "--diagnostic") {
        diagnostic_mode = true;
        --argc;
    }
    if (argc != 6 && argc != 7) {
        std::cerr << "usage: unified_trace input.f32 sample_rate window hop minimum_rms [lag_frames] [--diagnostic]\n";
        return 2;
    }

    const std::string input_path = argv[1];
    const auto sample_rate = number(argv[2], "sample rate");
    const auto window = static_cast<std::size_t>(number(argv[3], "window"));
    const auto hop = static_cast<std::size_t>(number(argv[4], "hop"));

    klarivision::core::PitchEngineConfig config;
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

    klarivision::core::UnifiedPitchSession session(config);
    if (argc == 7) {
        session.set_lag_frames(static_cast<std::size_t>(number(argv[6], "lag frames")));
    }

    std::cout << std::fixed << std::setprecision(8);
    if (diagnostic_mode) {
        std::cout << "time_seconds,rms,signal_eligible,candidate_count,winner_posterior,"
                     "voiced_posterior,harmonic_dominance,harmonic_evidence_ratio,"
                     "family_margin,parity_index,publication_reason\n";
    } else {
        std::cout << "time_seconds,frequency_hz,confidence\n";
    }
    for (std::size_t start = 0; start + window <= samples.size(); start += hop) {
        const double centre = (static_cast<double>(start) + static_cast<double>(window) / 2.0) / sample_rate;
        const auto published = session.process_frame({samples.data() + start, window}, sample_rate, centre);
        if (diagnostic_mode) {
            write_diagnostic(session.last_diagnostic());
            continue;
        }
        for (const auto& frame : published) {
            write_frame(frame);
        }
    }
    if (!diagnostic_mode) {
        for (const auto& frame : session.finish()) {
            write_frame(frame);
        }
    }
    return 0;
}
