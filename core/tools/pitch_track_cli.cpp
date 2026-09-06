#include "klarivision/core/analysis_engine.hpp"
#include "klarivision/core/analysis_engine_c.h"

#include <algorithm>
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
bool same_frame(const klarivision::core::EngineFrame& left, const klarivision::core::EngineFrame& right) {
    if (std::abs(left.time_seconds - right.time_seconds) > 0.000001 ||
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
    if(argc != 6 || std::string(argv[2]) != "--engine" || std::string(argv[4]) != "--output") { std::cerr << "Kullanım: pitch_track_cli INPUT.wav --engine unified_v1 --output OUTPUT.json\n"; return 2; }
    try {
        const auto wav = read_wav(argv[1]);
        const auto samples = resample(wav);
        klarivision::core::PitchEngine engine(
            parse_engine(argv[3]), klarivision::core::PitchEngineProfile::offline_track
        );
        const auto causal = engine.analyse_causal(samples, 48000);
        const auto frames = engine.analyse(samples, 48000);
        std::ofstream output(argv[5]);
        if (!output) throw std::runtime_error("Çıktı yazılamadı.");
        output << std::fixed << std::setprecision(6)
               << "{\n  \"engine\": \"" << argv[3]
               << "\",\n  \"profile\": \"offline_track_v1\","
               // NOTE: this string must match OFFLINE_TRACK_REVISION in
               // src/klarivision/pitch/cpp_engine.py exactly. There is no
               // compile-time link between the two.
               << "\n  \"implementation_revision\": \"offline-unified-path-r1\","
               << "\n  \"frames\": [\n";
        for (std::size_t index = 0; index < frames.size(); ++index) {
            const auto unchanged = std::any_of(causal.begin(), causal.end(), [&](const auto& item) {
                return same_frame(item, frames[index]);
            });
            // A frame the causal pass also produced, but at a different pitch,
            // was moved by the offline whole-track decode.  One that has no
            // causal counterpart at all came out of the fixed-lag tail.
            const auto same_time = std::any_of(causal.begin(), causal.end(), [&](const auto& item) {
                return std::abs(item.time_seconds - frames[index].time_seconds) < 1e-6;
            });
            const char* reason = unchanged ? "unchanged"
                : (same_time ? "offline_harmonic_path" : "fixed_lag_tail_flush");
            output << "    ";
            write_frame(output, frames[index], reason);
            output << (index + 1 == frames.size() ? "" : ",") << "\n";
        }
        output << "  ],\n  \"causal_baseline\": [\n";
        for (std::size_t index = 0; index < causal.size(); ++index) {
            output << "    "; write_frame(output, causal[index], "causal_baseline");
            output << (index + 1 == causal.size() ? "" : ",") << "\n";
        }
        output << "  ],\n  \"offline_changes\": [\n";
        bool first = true;
        for (const auto& baseline : causal) {
            const bool retained = std::any_of(frames.begin(), frames.end(), [&](const auto& item) {
                return same_frame(item, baseline);
            });
            if (retained) continue;
            if (!first) output << ",\n";
            output << "    {\"time_seconds\":" << baseline.time_seconds
                   << ",\"change_reason\":\""
                   << (baseline.confidence <= .55 ? "tracker_hold_suppressed" : "weak_release_suppressed")
                   << "\"}";
            first = false;
        }
        output << "\n  ]\n}\n";
    }
    catch(const std::exception& error) { std::cerr << error.what() << "\\n"; return 1; }
}
