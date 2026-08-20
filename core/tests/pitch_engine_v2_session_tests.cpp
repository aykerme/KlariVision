#include "klarivision/core/pitch_engine_v2_session.hpp"

#include <cassert>
#include <cmath>
#include <numbers>
#include <stdexcept>
#include <vector>

int main() {
    constexpr double rate = 48'000;
    constexpr std::size_t window_size = 1536;
    std::vector<float> window(window_size);
    klarivision::core::v2::PitchEngineV2Session session(0.015, 5);
    std::vector<klarivision::core::v2::PublishedPitchFrame> published;
    for (std::size_t frame = 0; frame < 12; ++frame) {
        for (std::size_t index = 0; index < window.size(); ++index) {
            window[index] = static_cast<float>(0.2 * std::sin(
                2 * std::numbers::pi * 440 * (frame * 512 + index) / rate
            ));
        }
        const auto output = session.process_frame(window, rate, frame * 512 / rate);
        published.insert(published.end(), output.begin(), output.end());
    }
    assert(!published.empty());
    for (const auto& frame : published) assert(std::abs(frame.frequency_hz - 440) < 2);
    const auto tail = session.finish();
    assert(!tail.empty());
    for (const auto& frame : tail) assert(std::abs(frame.frequency_hz - 440) < 2);
    assert(session.finish().empty());
    bool rejected_after_finish = false;
    try {
        (void)session.process_frame(window, rate, 1.0);
    } catch (const std::logic_error&) {
        rejected_after_finish = true;
    }
    assert(rejected_after_finish);
    session.reset();
    std::fill(window.begin(), window.end(), 0);
    for (std::size_t frame = 0; frame < 8; ++frame) {
        assert(session.process_frame(window, rate, frame * 512 / rate).empty());
    }
}
