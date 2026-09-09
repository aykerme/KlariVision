#include "klarivision/core/analysis_engine.hpp"
#include "klarivision/core/analysis_engine_c.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
std::uint16_t le16(const unsigned char* p) { return static_cast<std::uint16_t>(p[0] | (p[1] << 8)); }
std::uint32_t le32(const unsigned char* p) { return static_cast<std::uint32_t>(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24)); }
struct Wav { std::vector<float> samples; double rate{}; };
Wav read_wav(const std::string& path) {
    std::ifstream input(path, std::ios::binary); if (!input) throw std::runtime_error("WAV dosyası açılamadı.");
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(input)), {});
    if (bytes.size() < 44 || std::string(reinterpret_cast<char*>(bytes.data()), 4) != "RIFF" || std::string(reinterpret_cast<char*>(bytes.data()+8), 4) != "WAVE") throw std::runtime_error("Yalnız RIFF/WAV destekleniyor.");
    std::uint16_t format=0, channels=0, bits=0; std::uint32_t rate=0; std::size_t data_offset=0, data_size=0;
    for (std::size_t at=12; at+8<=bytes.size();) { const auto size=le32(bytes.data()+at+4); const std::string tag(reinterpret_cast<char*>(bytes.data()+at),4); at += 8; if(at+size>bytes.size()) break; if(tag=="fmt ") { format=le16(bytes.data()+at); channels=le16(bytes.data()+at+2); rate=le32(bytes.data()+at+4); bits=le16(bytes.data()+at+14); } else if(tag=="data") { data_offset=at; data_size=size; } at += size + (size & 1); }
    if(!data_offset || !channels || !rate || (format != 1 && format != 3)) throw std::runtime_error("Desteklenmeyen WAV biçimi.");
    const std::size_t width=bits/8; if(!width || data_size%(width*channels)) throw std::runtime_error("Geçersiz WAV örnekleri.");
    Wav wav; wav.rate=rate; const auto count=data_size/(width*channels); wav.samples.reserve(count);
    for(std::size_t i=0;i<count;++i) { double mixed=0; for(std::size_t c=0;c<channels;++c) { const auto* p=bytes.data()+data_offset+(i*channels+c)*width; if(format==3 && bits==32) { float x; std::memcpy(&x,p,sizeof(float)); mixed+=x; } else if(bits==16) mixed+=static_cast<std::int16_t>(le16(p))/32768.0; else if(bits==24) { int x=p[0]|(p[1]<<8)|(p[2]<<16); if(x&0x800000) x|=~0xffffff; mixed+=x/8388608.0; } else if(bits==32) mixed+=static_cast<std::int32_t>(le32(p))/2147483648.0; else throw std::runtime_error("Desteklenmeyen WAV bit derinliği."); } wav.samples.push_back(static_cast<float>(mixed/channels)); }
    return wav;
}
std::vector<float> resample(const Wav& source) { constexpr double target=48000; if(source.rate==target) return source.samples; const std::size_t size=static_cast<std::size_t>(source.samples.size()*target/source.rate); std::vector<float> output(size); for(std::size_t i=0;i<size;++i) { const double p=i*source.rate/target; const auto lo=static_cast<std::size_t>(p); const auto hi=std::min(lo+1,source.samples.size()-1); output[i]=static_cast<float>(source.samples[lo]+(source.samples[hi]-source.samples[lo])*(p-lo)); } return output; }
// Only unified_v1 is accepted. The four names that used to be valid here are
// rejected like any other unknown string: a caller asking for a removed
// engine must see an error, not another engine's track under that name.
klarivision::core::PitchEngineId parse_engine(const std::string& value) {
    if (value == "unified_v1") return klarivision::core::PitchEngineId::unified_v1;
    throw std::runtime_error("Geçersiz pitch motoru (yalnız unified_v1).");
}
// analyse_causal() (see analysis_engine.cpp) times each frame at the centre
// of its analysis window: (start + window_size/2)/rate. analyse()'s offline
// pass (collect_unified_evidence in unified_pitch_session.cpp) times each
// frame at the end of its hop: (index+1)/rate. With window_size=1536 and
// hop_size=512 those two grids are offset by exactly half a hop
// (window_size/2 - hop_size = 768 - 512 = 256 samples = 256/48000 s ≈
// 5.333 ms at 48 kHz) in the closest case, so no causal frame ever lands on
// an offline frame's exact timestamp -- comparing with an epsilon tighter
// than that half-hop offset can never find a match. This tolerance sits
// just above it.
constexpr double kOfflineCausalToleranceSeconds = 0.006; // > hop/2 (512/48000/2 ≈ 5.333 ms)
bool same_frame(const klarivision::core::EngineFrame& left, const klarivision::core::EngineFrame& right) {
    if (std::abs(left.time_seconds - right.time_seconds) > kOfflineCausalToleranceSeconds ||
        left.frequency_hz.has_value() != right.frequency_hz.has_value()) return false;
    return !left.frequency_hz || std::abs(*left.frequency_hz - *right.frequency_hz) < 0.000001;
}
void write_frame(std::ostream& output, const klarivision::core::EngineFrame& frame, const std::string& reason) {
    output << "{\"time_seconds\":" << frame.time_seconds << ",\"frequency_hz\":";
    if (frame.frequency_hz) output << *frame.frequency_hz; else output << "null";
    output << ",\"voiced\":" << (frame.frequency_hz ? "true" : "false")
           << ",\"confidence\":" << frame.confidence
           << ",\"change_reason\":\"" << reason << "\"}";
}

// --- KV-PROGRESS protocol (canonical definition; mirrored in
// src/klarivision/local_app.py) ---------------------------------------------
// A single line on stderr, never on stdout (stdout carries this CLI's only
// other output: --contract JSON, or nothing -- the track itself goes to the
// --output file):
//
//   KV-PROGRESS <stage> <processed>/<total>
//
// <stage> is one lowercase token, stable across releases so a UI can map it
// to display text without parsing anything else. Stages this CLI emits, in
// order:
//   decode  -- reading the WAV and resampling to 48 kHz.
//   causal  -- PitchEngine::analyse_causal(), only when --baseline was given.
//   pitch   -- PitchEngine::analyse(), the offline whole-track pass. This is
//              the slow step (tens of seconds on a multi-minute recording).
//              PitchEngine::analyse() takes an optional progress callback
//              (see core/include/klarivision/core/analysis_engine.hpp,
//              PitchProgressCallback) that this CLI wires to emit_progress
//              below, so this stage now ticks mid-pass instead of only being
//              bookended at 0/total and total/total.
//   write   -- serialising `frames` to the output JSON. This loop *is*
//              driven by the CLI itself, so it reports real, incrementally
//              advancing progress.
// <processed>/<total> are frame counts. For "decode"/"causal"/"pitch",
// <total> is an estimate (input samples / hop size) shared by all three
// stages so a UI can size one progress bar across them; for "write" it is
// the exact frames.size().
void emit_progress(const std::string& stage, std::size_t processed, std::size_t total) {
    std::cerr << "KV-PROGRESS " << stage << ' ' << processed << '/' << total << '\n';
    std::cerr.flush();
}
}
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--contract") {
        kv_pitch_contract_v1 contract{};
        if (!kv_pitch_contract_get_v1(&contract)) return 1;
        std::cout << "{\"abi_version\":" << contract.abi_version
                  << ",\"profile\":\"offline_track_v1\""
                  << ",\"sample_rate_hz\":" << contract.sample_rate_hz
                  << ",\"window_size\":" << contract.window_size
                  << ",\"hop_size\":" << contract.hop_size
                  << ",\"engines\":[\"unified_v1\"]"
                  // Separate from kv_pitch_contract_v1 on purpose: that
                  // struct is frozen and its v2_fixed_lag_frames field is a
                  // reserved leftover. See kv_unified_lag_frames() in
                  // analysis_engine_c.h.
                  << ",\"unified_lag_frames\":" << kv_unified_lag_frames()
                  << "}\n";
        return 0;
    }
    // --diagnostic is gone with the engines it served: every per-frame
    // diagnostic writer here belonged to pitch_engine_v2, vpm_like or hapt_v1.
    // The unified engine's own trace tool is core/tools/unified_trace.cpp.
    //
    // --baseline is optional and OFF by default: it is the only thing that
    // makes this CLI run analyse_causal() in addition to analyse(), and
    // analyse_causal() redoes the entire per-frame evidence computation
    // analyse() already did internally. Doubling that work is pointless for
    // every caller except the causal_baseline/offline_changes diagnostic
    // surfaces (src/klarivision/study_validation.py and
    // scripts/run_study_mode_synthetic_validation.py), so ordinary track
    // extraction (the Study/local_app.py path a real user's file goes
    // through) must not pay for it.
    bool baseline = false;
    int positional_argc = argc;
    if (argc == 7 && std::string(argv[6]) == "--baseline") {
        baseline = true;
        positional_argc = 6;
    }
    if (positional_argc != 6 || std::string(argv[2]) != "--engine" || std::string(argv[4]) != "--output") {
        std::cerr << "Kullanım: pitch_track_cli INPUT.wav --engine unified_v1 --output OUTPUT.json [--baseline]\n";
        return 2;
    }
    try {
        emit_progress("decode", 0, 1);
        const auto wav = read_wav(argv[1]);
        const auto samples = resample(wav);
        emit_progress("decode", 1, 1);

        // hop_size drives the estimated frame count shown for "causal" and
        // "pitch" below. It comes from the same C ABI struct --contract
        // reports, not a duplicated literal, so it tracks the engine's real
        // configuration even if the default ever changes.
        kv_pitch_contract_v1 contract{};
        const std::size_t hop_size = kv_pitch_contract_get_v1(&contract) && contract.hop_size
            ? static_cast<std::size_t>(contract.hop_size)
            : 512;
        const std::size_t estimated_frames = samples.empty() ? 0 : samples.size() / hop_size + 1;

        klarivision::core::PitchEngine engine(
            parse_engine(argv[3]), klarivision::core::PitchEngineProfile::offline_track
        );
        // Only computed when asked for -- see the --baseline comment above.
        // Both analyse_causal() and analyse() accept an optional progress
        // callback (PitchProgressCallback, in analysis_engine.hpp) that fires
        // from inside their own per-frame loops, already throttled to ~1%/
        // 200ms the same way this CLI's "write" stage throttles itself. The
        // engine's own `total` (an exact hop or window count computed inside
        // the call) is deliberately not forwarded here: the protocol's
        // <total> for "causal"/"pitch" is `estimated_frames`, shared with
        // "decode" so a UI can size one bar across all of them, and the
        // engine's count can differ from that estimate by a frame or two.
        // std::min guards against a processed count nudging past that shared
        // estimate and printing something like "17901/17900".
        const auto make_progress_reporter = [estimated_frames](const std::string& stage) {
            return [stage, estimated_frames](std::size_t done, std::size_t) {
                emit_progress(stage, std::min(done, estimated_frames), estimated_frames);
            };
        };

        std::vector<klarivision::core::EngineFrame> causal;
        if (baseline) {
            emit_progress("causal", 0, estimated_frames);
            causal = engine.analyse_causal(samples, 48000, make_progress_reporter("causal"));
            emit_progress("causal", estimated_frames, estimated_frames);
        }
        emit_progress("pitch", 0, estimated_frames);
        const auto frames = engine.analyse(samples, 48000, make_progress_reporter("pitch"));
        emit_progress("pitch", estimated_frames, estimated_frames);

        // For each offline frame, decide whether the causal pass produced
        // the same pitch nearby in time (unchanged), a different pitch
        // nearby in time (offline_harmonic_path, i.e. moved by the offline
        // whole-track decode), or nothing nearby at all (fixed_lag_tail_flush,
        // i.e. it only exists because of the fixed-lag tail flush). This is
        // done with a single forward sweep over both (already time-sorted)
        // vectors instead of the old O(frames*causal) any_of scans: the
        // window pointer into `causal` only ever advances, and at each
        // offline frame it only has to look at the handful of causal frames
        // within kOfflineCausalToleranceSeconds (bounded by the fixed hop
        // spacing), so the whole pass is O(frames + causal).
        std::vector<std::string> frame_reasons(frames.size());
        std::vector<char> causal_retained(causal.size(), 0);
        if (baseline) {
            std::size_t window_start = 0;
            for (std::size_t index = 0; index < frames.size(); ++index) {
                const double frame_time = frames[index].time_seconds;
                while (window_start < causal.size() &&
                       causal[window_start].time_seconds < frame_time - kOfflineCausalToleranceSeconds) {
                    ++window_start;
                }
                bool unchanged = false;
                bool same_time = false;
                for (std::size_t k = window_start;
                     k < causal.size() && causal[k].time_seconds <= frame_time + kOfflineCausalToleranceSeconds;
                     ++k) {
                    same_time = true;
                    if (same_frame(causal[k], frames[index])) {
                        unchanged = true;
                        causal_retained[k] = 1;
                    }
                }
                frame_reasons[index] = unchanged ? "unchanged"
                    : (same_time ? "offline_harmonic_path" : "fixed_lag_tail_flush");
            }
        } else {
            // No causal baseline was computed, so there is nothing to diff
            // an offline frame against. Every frame here still went through
            // the same offline whole-track harmonic-path decode
            // (unified_v1's analyse()), so "offline_harmonic_path" is the
            // one label that is actually true of all of them -- unlike
            // "unchanged" (would claim a causal comparison that never ran)
            // or "fixed_lag_tail_flush" (would claim a specific tail-flush
            // origin that was never checked).
            std::fill(frame_reasons.begin(), frame_reasons.end(), "offline_harmonic_path");
        }

        std::ofstream output(argv[5]);
        if (!output) throw std::runtime_error("Çıktı yazılamadı.");
        output << std::fixed << std::setprecision(6)
               << "{\n  \"engine\": \"" << argv[3]
               << "\",\n  \"profile\": \"offline_track_v1\","
               // NOTE: this string must match OFFLINE_TRACK_REVISION in
               // src/klarivision/pitch/cpp_engine.py exactly. There is no
               // compile-time link between the two, and it must not change
               // here just because --baseline was added: the engine's own
               // behaviour (and therefore the "frames" array) is identical
               // with or without it, so the cache key must stay identical too.
               << "\n  \"implementation_revision\": \"offline-unified-path-r3\","
               << "\n  \"frames\": [\n";
        // Real, per-frame progress: unlike "pitch" above, this loop runs in
        // the CLI, not inside the engine, so it can report exact counts. It
        // is still throttled -- one line per frame would be a real I/O cost
        // at ~17,900 frames for a three-minute recording -- to roughly every
        // 1% of frames or every 200ms, whichever comes first.
        const std::size_t total_frames = frames.size();
        const std::size_t report_stride = std::max<std::size_t>(total_frames / 100, 1);
        auto last_report = std::chrono::steady_clock::now();
        emit_progress("write", 0, total_frames);
        for (std::size_t index = 0; index < frames.size(); ++index) {
            output << "    ";
            write_frame(output, frames[index], frame_reasons[index]);
            output << (index + 1 == frames.size() ? "" : ",") << "\n";
            const auto now = std::chrono::steady_clock::now();
            const bool last = index + 1 == total_frames;
            if (last || index % report_stride == 0 || now - last_report >= std::chrono::milliseconds(200)) {
                emit_progress("write", index + 1, total_frames);
                last_report = now;
            }
        }
        // Both arrays below stay in the JSON (schema compatibility) but are
        // empty unless --baseline was given.
        output << "  ],\n  \"causal_baseline\": [\n";
        for (std::size_t index = 0; index < causal.size(); ++index) {
            output << "    "; write_frame(output, causal[index], "causal_baseline");
            output << (index + 1 == causal.size() ? "" : ",") << "\n";
        }
        output << "  ],\n  \"offline_changes\": [\n";
        bool first = true;
        for (std::size_t k = 0; k < causal.size(); ++k) {
            if (causal_retained[k]) continue;
            if (!first) output << ",\n";
            output << "    {\"time_seconds\":" << causal[k].time_seconds
                   << ",\"change_reason\":\""
                   << (causal[k].confidence <= .55 ? "tracker_hold_suppressed" : "weak_release_suppressed")
                   << "\"}";
            first = false;
        }
        output << "\n  ]\n}\n";
    }
    catch(const std::exception& error) { std::cerr << error.what() << "\\n"; return 1; }
}
