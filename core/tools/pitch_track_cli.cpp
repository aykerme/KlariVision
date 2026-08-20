#include "klarivision/core/analysis_engine.hpp"
#include "klarivision/core/analysis_engine_c.h"
#include "klarivision/core/pitch_engine_v2_session.hpp"

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
klarivision::core::PitchEngineId parse_engine(const std::string& value) { if(value=="yin_v1") return klarivision::core::PitchEngineId::yin_v1; if(value=="pitch_engine_v2") return klarivision::core::PitchEngineId::pitch_engine_v2; if(value=="vpm_like") return klarivision::core::PitchEngineId::vpm_like; throw std::runtime_error("Geçersiz pitch motoru."); }
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
const char* candidate_source(const klarivision::core::v2::CandidateSource source) {
    using Source = klarivision::core::v2::CandidateSource;
    switch (source) {
        case Source::yin: return "yin";
        case Source::autocorrelation: return "autocorrelation";
        case Source::mpm: return "mpm";
        case Source::spectral: return "spectral";
    }
    return "unknown";
}
void write_candidate(std::ostream& output, const klarivision::core::v2::ScoredPitchCandidate& candidate) {
    output << "{\"source\":\"" << candidate_source(candidate.candidate.source)
           << "\",\"frequency_hz\":" << candidate.candidate.frequency_hz
           << ",\"periodicity\":" << candidate.candidate.periodicity
           << ",\"prime_harmonic_support\":" << candidate.candidate.harmonic_support
           << ",\"cross_estimator_agreement\":"
           << (candidate.candidate.agreement_support ? "true" : "false")
           << ",\"emission_score\":" << candidate.emission_score << "}";
}
void write_diagnostic(std::ostream& output, const klarivision::core::v2::FrameDiagnostic& diagnostic) {
    output << "{\"input_time_seconds\":" << diagnostic.input_time_seconds
           << ",\"rms\":" << diagnostic.rms
           << ",\"input_signal_eligible\":" << (diagnostic.input_signal_eligible ? "true" : "false")
           << ",\"input_release_active\":" << (diagnostic.input_release_active ? "true" : "false")
           << ",\"resolved\":" << (diagnostic.resolved ? "true" : "false");
    if (diagnostic.resolved) {
        output << ",\"resolved_time_seconds\":" << diagnostic.resolved_time_seconds
               << ",\"resolved_signal_eligible\":" << (diagnostic.resolved_signal_eligible ? "true" : "false")
               << ",\"resolved_release_active\":" << (diagnostic.resolved_release_active ? "true" : "false")
               << ",\"selected_emission_score\":" << diagnostic.selected_emission_score
               << ",\"selected_path_score\":" << diagnostic.selected_path_score;
        if (diagnostic.selected_candidate) {
            output << ",\"selected\":{\"source\":\"" << candidate_source(diagnostic.selected_candidate->source)
                   << "\",\"frequency_hz\":" << diagnostic.selected_candidate->frequency_hz
                   << ",\"periodicity\":" << diagnostic.selected_candidate->periodicity
                   << ",\"prime_harmonic_support\":" << diagnostic.selected_candidate->harmonic_support
                   << ",\"cross_estimator_agreement\":"
                   << (diagnostic.selected_candidate->agreement_support ? "true" : "false") << "}";
        }
    }
    output << ",\"publication_reason\":\"" << diagnostic.publication_reason
           << "\",\"bridged_frames\":" << diagnostic.bridged_frames
           << ",\"finalized\":" << (diagnostic.finalized ? "true" : "false")
           << ",\"candidates\":[";
    for (std::size_t index = 0; index < diagnostic.candidates.size(); ++index) {
        write_candidate(output, diagnostic.candidates[index]);
        if (index + 1 != diagnostic.candidates.size()) output << ',';
    }
    output << "]}";
}
void write_optional_number(std::ostream& output, const std::optional<double>& value) {
    if (value) output << *value; else output << "null";
}
void write_vpm_diagnostic(
    std::ostream& output,
    const klarivision::core::VPMSessionDiagnostic& diagnostic
) {
    output << "{\"input_time_seconds\":" << diagnostic.input_time_seconds
           << ",\"rms\":" << diagnostic.rms
           << ",\"recent_rms_peak\":" << diagnostic.recent_rms_peak
           << ",\"rms_to_peak_ratio\":" << diagnostic.rms_to_peak_ratio
           << ",\"strongest_periodicity\":" << diagnostic.strongest_periodicity
           << ",\"normal_estimate_hz\":";
    write_optional_number(output, diagnostic.normal_estimate_hz);
    output << ",\"weak_estimate_hz\":";
    write_optional_number(output, diagnostic.weak_estimate_hz);
    output << ",\"last_strong_contour_hz\":";
    write_optional_number(output, diagnostic.last_strong_contour_hz);
    output << ",\"direct_fundamental_support\":" << diagnostic.direct_fundamental_support
           << ",\"recent_direct_support_peak\":" << diagnostic.recent_direct_support_peak
           << ",\"established_upper_to_estimate_ratio\":";
    write_optional_number(output, diagnostic.established_upper_to_estimate_ratio);
    output << ",\"signal_eligible\":" << (diagnostic.signal_eligible ? "true" : "false")
           << ",\"release_suspected\":" << (diagnostic.release_suspected ? "true" : "false")
           << ",\"harmonic_veto\":" << (diagnostic.harmonic_veto ? "true" : "false")
           << ",\"pending_gap_frames\":" << diagnostic.pending_gap_frames
           << ",\"bridged_frames\":" << diagnostic.bridged_frames
           << ",\"publication_reason\":\"" << diagnostic.publication_reason << "\"}";
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
                  << ",\"engines\":[\"yin_v1\",\"pitch_engine_v2\",\"vpm_like\"]}\\n";
        return 0;
    }
    if((argc != 6 && argc != 8) || std::string(argv[2]) != "--engine" || std::string(argv[4]) != "--output" ||
       (argc == 8 && std::string(argv[6]) != "--diagnostic")) { std::cerr << "Kullanım: pitch_track_cli INPUT.wav --engine yin_v1|pitch_engine_v2|vpm_like --output OUTPUT.json [--diagnostic DIAG.json]\\n"; return 2; }
    try {
        const auto wav = read_wav(argv[1]);
        const auto samples = resample(wav);
        const bool diagnostic_requested = argc == 8;
        if (diagnostic_requested && std::string(argv[3]) != "pitch_engine_v2" &&
            std::string(argv[3]) != "vpm_like") {
            throw std::runtime_error("Tanı yalnız pitch_engine_v2 ve vpm_like için kullanılabilir.");
        }
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
               << "\n  \"implementation_revision\": \"shared-production-session-r5\","
               << "\n  \"frames\": [\n";
        for (std::size_t index = 0; index < frames.size(); ++index) {
            const auto unchanged = std::any_of(causal.begin(), causal.end(), [&](const auto& item) {
                return same_frame(item, frames[index]);
            });
            output << "    ";
            write_frame(output, frames[index], unchanged ? "unchanged" : "fixed_lag_tail_flush");
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
        if (diagnostic_requested) {
            std::ofstream diagnostic_output(argv[7]);
            if (!diagnostic_output) throw std::runtime_error("Tanı çıktısı yazılamadı.");
            diagnostic_output << std::fixed << std::setprecision(6)
                << "{\n  \"engine\": \"" << argv[3] << "\",\n  \"frames\": [\n";
            bool first_diagnostic = true;
            const auto separate = [&] {
                if (!first_diagnostic) diagnostic_output << ",\n";
                diagnostic_output << "    "; first_diagnostic = false;
            };
            if (std::string(argv[3]) == "pitch_engine_v2") {
                klarivision::core::v2::PitchEngineV2Session session;
                for (std::size_t start = 0; start + 1536 <= samples.size(); start += 512) {
                    const double time = (static_cast<double>(start) + 768) / 48000;
                    (void)session.process_frame(std::span<const float>(samples).subspan(start, 1536), 48000, time);
                    separate(); write_diagnostic(diagnostic_output, session.last_diagnostic());
                }
                (void)session.finish();
                separate(); write_diagnostic(diagnostic_output, session.last_diagnostic());
            } else {
                klarivision::core::ProductionPitchSession session(
                    klarivision::core::PitchEngineId::vpm_like,
                    klarivision::core::PitchEngineConfig{
                        .enable_vpm_diagnostics = true,
                    }
                );
                for (std::size_t start = 0; start + 1536 <= samples.size(); start += 512) {
                    const double time = (static_cast<double>(start) + 768) / 48000;
                    (void)session.process_frame(
                        std::span<const float>(samples).subspan(start, 1536), 48000, time
                    );
                    separate(); write_vpm_diagnostic(
                        diagnostic_output, session.last_vpm_diagnostic()
                    );
                }
            }
            diagnostic_output << "\n  ]\n}\n";
        }
    }
    catch(const std::exception& error) { std::cerr << error.what() << "\\n"; return 1; }
}
