#pragma once

#include <complex>
#include <cstddef>
#include <span>

namespace klarivision::core {

/// Single-frequency Hann-windowed spectral probe (a matched-filter/Goertzel
/// style correlator against cos/sin references at `frequency_hz`), shared by
/// the HAPT engine's inter-harmonic veto and its phase-locked instantaneous
/// frequency refinement. Unlike the analysis engine's existing
/// `spectral_energy`/`spectral_amplitude` helpers, this keeps phase.
///
/// For a real input near `frequency_hz`, `arg(result)` varies approximately
/// linearly with the deviation between the true frequency and the probe
/// frequency, referenced to the window's centre sample; see
/// docs/HAPTPitchEngine.md for the derivation used by the IF refinement.
std::complex<double> hann_windowed_probe(
    std::span<const float> samples,
    double sample_rate,
    double frequency_hz
);

/// Half-width in Hz of an N-sample Hann window's main spectral lobe -- the
/// smallest frequency spacing the window can directly resolve by probing.
/// Two spectral lines closer than ~1.5x this width are not reliably
/// separable; below that spacing callers should fall back to time-domain
/// evidence instead of a direct spectral probe.
double hann_main_lobe_half_width_hz(std::size_t sample_count, double sample_rate);

}  // namespace klarivision::core
