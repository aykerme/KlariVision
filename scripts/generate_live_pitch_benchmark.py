#!/usr/bin/env python3
"""Generate a deterministic reference recording for live pitch engines.

The signal deliberately contains no recording-room noise.  Every sounding
section has a known frequency function, recorded beside the WAV as JSON.
"""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np


SAMPLE_RATE = 48_000
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "data" / "benchmarks"
WAV_PATH = OUTPUT_DIR / "canli_pitch_referans_v1.wav"
MANIFEST_PATH = OUTPUT_DIR / "canli_pitch_referans_v1.json"


def clarinet_tone(frequency: np.ndarray, amplitude: float = 0.38) -> np.ndarray:
    """A stable, synthetic clarinet-like tone with deterministic odd harmonics."""
    phase = 2 * math.pi * np.cumsum(frequency) / SAMPLE_RATE
    signal = np.zeros_like(phase)
    for harmonic, level in ((1, 1.0), (3, 0.42), (5, 0.23), (7, 0.12), (9, 0.07)):
        signal += level * np.sin(harmonic * phase)
    signal *= amplitude / sum((1.0, 0.42, 0.23, 0.12, 0.07))
    return signal


def fade(signal: np.ndarray, milliseconds: float = 12) -> np.ndarray:
    size = min(len(signal) // 2, int(SAMPLE_RATE * milliseconds / 1000))
    if size:
        ramp = np.linspace(0, 1, size, endpoint=False)
        signal[:size] *= ramp
        signal[-size:] *= ramp[::-1]
    return signal


def silence(seconds: float) -> np.ndarray:
    return np.zeros(round(seconds * SAMPLE_RATE))


def constant(frequency: float, seconds: float) -> np.ndarray:
    return fade(clarinet_tone(np.full(round(seconds * SAMPLE_RATE), frequency)))


def vibrato(frequency: float, cents: float, rate: float, seconds: float) -> np.ndarray:
    t = np.arange(round(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    instantaneous = frequency * np.power(2, (cents * np.sin(2 * math.pi * rate * t)) / 1200)
    return fade(clarinet_tone(instantaneous))


def glide(start_frequency: float, end_frequency: float, seconds: float) -> np.ndarray:
    t = np.linspace(0, 1, round(seconds * SAMPLE_RATE), endpoint=False)
    instantaneous = start_frequency * np.power(2, np.log2(end_frequency / start_frequency) * t)
    return fade(clarinet_tone(instantaneous))


def grace_note(grace_frequency: float, target_frequency: float, grace_seconds: float = 0.060, target_seconds: float = 0.940) -> np.ndarray:
    """A short, adjacent grace note leading directly into a held target note."""
    grace = clarinet_tone(np.full(round(grace_seconds * SAMPLE_RATE), grace_frequency))
    target = clarinet_tone(np.full(round(target_seconds * SAMPLE_RATE), target_frequency))
    return fade(np.concatenate((grace, target)), milliseconds=8)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    blocks: list[np.ndarray] = []
    sections: list[dict[str, object]] = []
    elapsed = 0.0

    def add_silence(seconds: float) -> None:
        nonlocal elapsed
        blocks.append(silence(seconds))
        elapsed += seconds

    def add(label: str, signal: np.ndarray, description: str, formula: str) -> None:
        nonlocal elapsed
        start = elapsed
        duration = len(signal) / SAMPLE_RATE
        blocks.append(signal)
        elapsed += duration
        sections.append({
            "label": label,
            "start_seconds": round(start, 3),
            "end_seconds": round(elapsed, 3),
            "description": description,
            "frequency_formula": formula,
        })

    add_silence(1.0)
    add("A3_sabit", constant(220.0, 2.0), "Sabit La3; temel doğruluk.", "220 Hz")
    add_silence(0.30)
    add("C4_sabit", constant(261.625565, 1.0), "Sabit Do4; nota geçişi.", "261.625565 Hz")
    add_silence(0.30)
    add("E4_sabit", constant(329.627557, 1.0), "Sabit Mi4; orta ses kontrolü.", "329.627557 Hz")
    add_silence(0.30)
    add("A4_sabit", constant(440.0, 1.0), "Sabit La4; üst oktav kontrolü.", "440 Hz")
    add_silence(0.30)
    add("A3_vibrato", vibrato(220.0, 30.0, 5.5, 2.4), "La3 üzerinde ±30 cent, 5.5 Hz vibrato.", "220 * 2^(30*sin(2π*5.5t)/1200)")
    add_silence(0.30)
    add("A3_C4_glissando", glide(220.0, 261.625565, 1.5), "La3'ten Do4'e sürekli glissando.", "220 * 2^(log2(261.625565/220)*t/1.5)")
    add_silence(0.30)
    add("C3_sabit", constant(130.812783, 1.0), "Sabit Do3; alt ses kontrolü.", "130.812783 Hz")
    add_silence(0.30)
    add("C4_ani_gecis", constant(261.625565, 1.0), "Do3'ten Do4'e ani oktav geçişinin ikinci notası.", "261.625565 Hz")
    add_silence(0.30)
    add("E4_vibrato", vibrato(329.627557, 22.0, 6.0, 2.2), "Mi4 üzerinde ±22 cent, 6 Hz vibrato.", "329.627557 * 2^(22*sin(2π*6t)/1200)")
    add_silence(0.30)
    add("G3_yukari_carpma", grace_note(220.0, 195.997718), "Sol3 öncesinde 60 ms yukarı çarpma: La3 → Sol3.", "0–60 ms: 220 Hz; sonra 195.997718 Hz")
    add_silence(0.30)
    add("G3_asagi_carpma", grace_note(174.614116, 195.997718), "Sol3 öncesinde 60 ms aşağı çarpma: Fa3 → Sol3.", "0–60 ms: 174.614116 Hz; sonra 195.997718 Hz")
    add_silence(0.30)
    add("A3_10cent_pes", constant(220.0 * 2 ** (-10 / 1200), 1.0), "La3, 10 cent pes.", "220 * 2^(-10/1200)")
    add_silence(0.20)
    add("A3_tam", constant(220.0, 1.0), "Tam La3.", "220 Hz")
    add_silence(0.20)
    add("A3_10cent_tiz", constant(220.0 * 2 ** (10 / 1200), 1.0), "La3, 10 cent tiz.", "220 * 2^(10/1200)")
    add_silence(1.0)

    audio = np.concatenate(blocks)
    pcm = np.clip(audio, -0.98, 0.98)
    pcm16 = (pcm * np.iinfo(np.int16).max).astype("<i2")
    with wave.open(str(WAV_PATH), "wb") as destination:
        destination.setnchannels(1)
        destination.setsampwidth(2)
        destination.setframerate(SAMPLE_RATE)
        destination.writeframes(pcm16.tobytes())

    MANIFEST_PATH.write_text(json.dumps({
        "format": "48 kHz, mono, 16-bit PCM WAV",
        "duration_seconds": round(len(audio) / SAMPLE_RATE, 3),
        "purpose": "Deterministic live pitch-engine comparison without room noise.",
        "sections": sections,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Created {WAV_PATH}")
    print(f"Created {MANIFEST_PATH}")


if __name__ == "__main__":
    main()
