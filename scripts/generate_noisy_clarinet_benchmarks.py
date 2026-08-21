#!/usr/bin/env python3
"""Create deterministic clarinet-timbre and noise variants of the vibrato test.

All variants retain exactly the same musical time/frequency plan as the clean
fixture.  Only the spectral colour and noise floor change, allowing a direct
robustness comparison of a pitch engine.
"""

from __future__ import annotations

import json
import wave
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data" / "benchmarks"
SOURCE_WAV = BENCHMARKS / "vibrato_cozunurluk_referans_v1.wav"
SOURCE_MANIFEST = BENCHMARKS / "vibrato_cozunurluk_referans_v1.json"


def read_wav(path: Path) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as source:
        sample_rate = source.getframerate()
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
    return sample_rate, samples


def write_wav(path: Path, sample_rate: int, samples: np.ndarray) -> None:
    pcm = (np.clip(samples, -0.98, 0.98) * np.iinfo(np.int16).max).astype("<i2")
    with wave.open(str(path), "wb") as destination:
        destination.setnchannels(1)
        destination.setsampwidth(2)
        destination.setframerate(sample_rate)
        destination.writeframes(pcm.tobytes())


def clarinet_colour(clean: np.ndarray) -> np.ndarray:
    """Add small even partials and a gentle reed-like saturation.

    The base fixture already includes odd clarinet partials.  The quadratic
    term adds restrained even partials, as occur in real instruments and in a
    microphone/speaker path, without altering the known fundamental contour.
    """
    even_partials = clean * clean - np.mean(clean * clean)
    shaped = clean + 0.18 * even_partials
    return np.tanh(1.12 * shaped) / np.tanh(1.12)


def coloured_noise(length: int, seed: int) -> np.ndarray:
    generator = np.random.default_rng(seed)
    white = generator.normal(0, 1, length)
    # A short moving average contributes low-frequency breath/room colour;
    # white noise preserves the hiss component of a practical recording.
    kernel = np.ones(37) / 37
    low = np.convolve(white, kernel, mode="same")
    noise = 0.72 * white + 0.28 * low / max(np.std(low), 1e-12)
    return noise / max(np.std(noise), 1e-12)


def with_snr(signal: np.ndarray, snr_db: float, seed: int) -> np.ndarray:
    active_rms = np.sqrt(np.mean(signal * signal))
    target_noise_rms = active_rms / (10 ** (snr_db / 20))
    return signal + coloured_noise(len(signal), seed) * target_noise_rms


def write_manifest(path: Path, source_manifest: dict[str, object], variant: str, note: str) -> None:
    payload = dict(source_manifest)
    payload["variant"] = variant
    payload["signal_note"] = note
    payload["reference_frequency"] = "Identical to vibrato_cozunurluk_referans_v1; only timbre/noise differs."
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    if not SOURCE_WAV.exists():
        raise SystemExit(f"Missing clean fixture: {SOURCE_WAV}")
    sample_rate, clean = read_wav(SOURCE_WAV)
    source_manifest = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    coloured = clarinet_colour(clean)

    variants = {
        "vibrato_klarnet_harmonik_v1": (
            coloured,
            "Odd partials plus controlled even harmonics and gentle reed-like saturation; no added noise.",
        ),
        "vibrato_klarnet_hafif_gurultu_v1": (
            with_snr(coloured, 30.0, seed=20260730),
            "Clarinet-harmonic version plus deterministic 30 dB SNR breath/room noise.",
        ),
        "vibrato_klarnet_orta_gurultu_v1": (
            with_snr(coloured, 20.0, seed=20260731),
            "Clarinet-harmonic version plus deterministic 20 dB SNR noise; deliberate robustness test.",
        ),
    }
    for name, (samples, note) in variants.items():
        write_wav(BENCHMARKS / f"{name}.wav", sample_rate, samples)
        write_manifest(BENCHMARKS / f"{name}.json", source_manifest, name, note)
        print(BENCHMARKS / f"{name}.wav")


if __name__ == "__main__":
    main()
