#!/usr/bin/env python3
"""Create a clean, deterministic vibrato-resolution reference recording.

This fixture is intentionally synthetic: its pitch at every instant is known,
so KlariVision and Vocal Pitch Monitor can be compared without room, speaker,
microphone or player variation.  It is a diagnostic recording, not intended
to imitate a finished clarinet performance.
"""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np


SAMPLE_RATE = 48_000
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "data" / "benchmarks"
WAV_PATH = OUTPUT_DIR / "vibrato_cozunurluk_referans_v1.wav"
MANIFEST_PATH = OUTPUT_DIR / "vibrato_cozunurluk_referans_v1.json"


def clarinet_tone(frequency: np.ndarray, amplitude: float = 0.38) -> np.ndarray:
    """Odd harmonics give a stable, clarinet-like synthetic test tone."""
    phase = 2 * math.pi * np.cumsum(frequency) / SAMPLE_RATE
    signal = np.zeros_like(phase)
    partials = ((1, 1.0), (3, 0.42), (5, 0.23), (7, 0.12), (9, 0.07))
    for harmonic, level in partials:
        signal += level * np.sin(harmonic * phase)
    return signal * amplitude / sum(level for _, level in partials)


def fade(signal: np.ndarray, milliseconds: float = 12) -> np.ndarray:
    count = min(len(signal) // 2, round(SAMPLE_RATE * milliseconds / 1000))
    if count:
        ramp = np.linspace(0, 1, count, endpoint=False)
        signal[:count] *= ramp
        signal[-count:] *= ramp[::-1]
    return signal


def silence(seconds: float) -> np.ndarray:
    return np.zeros(round(seconds * SAMPLE_RATE))


def constant(frequency: float, seconds: float) -> np.ndarray:
    return fade(clarinet_tone(np.full(round(seconds * SAMPLE_RATE), frequency)))


def vibrato(frequency: float, cents: float, rate: float, seconds: float) -> np.ndarray:
    time = np.arange(round(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    instantaneous = frequency * np.power(2, cents * np.sin(2 * math.pi * rate * time) / 1200)
    return fade(clarinet_tone(instantaneous))


def glide(start_frequency: float, end_frequency: float, seconds: float) -> np.ndarray:
    time = np.linspace(0, 1, round(seconds * SAMPLE_RATE), endpoint=False)
    instantaneous = start_frequency * np.power(2, np.log2(end_frequency / start_frequency) * time)
    return fade(clarinet_tone(instantaneous))


def grace_note(grace_frequency: float, target_frequency: float) -> np.ndarray:
    grace = clarinet_tone(np.full(round(0.070 * SAMPLE_RATE), grace_frequency))
    target = clarinet_tone(np.full(round(1.130 * SAMPLE_RATE), target_frequency))
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
        blocks.append(signal)
        elapsed += len(signal) / SAMPLE_RATE
        sections.append({
            "label": label,
            "start_seconds": round(start, 3),
            "end_seconds": round(elapsed, 3),
            "description": description,
            "frequency_formula": formula,
        })

    base = 220.0  # La3: the same carrier makes rate comparison unambiguous.
    add_silence(1.0)
    add("A3_sabit", constant(base, 2.0), "Sabit La3; temel çizgi ve gürültü kontrolü.", "220 Hz")
    add_silence(0.35)

    # Rates span slow musical vibrato through deliberately demanding motion.
    # All sections use ±35 cents so only the rate changes.
    for rate, duration in ((0.5, 8.0), (1.5, 5.0), (3.0, 4.0), (5.5, 3.5), (7.5, 3.5), (10.0, 3.5), (13.0, 3.5)):
        add(
            f"A3_vibrato_{str(rate).replace('.', '_')}Hz",
            vibrato(base, 35.0, rate, duration),
            f"La3 üzerinde ±35 cent, {rate:g} Hz vibrato.",
            f"220 * 2^(35*sin(2π*{rate:g}t)/1200)",
        )
        add_silence(0.35)

    add("A3_vibrato_dar", vibrato(base, 10.0, 5.5, 3.5), "La3 üzerinde dar (±10 cent), 5.5 Hz vibrato.", "220 * 2^(10*sin(2π*5.5t)/1200)")
    add_silence(0.35)
    add("A3_vibrato_genis", vibrato(base, 60.0, 5.5, 3.5), "La3 üzerinde geniş (±60 cent), 5.5 Hz vibrato.", "220 * 2^(60*sin(2π*5.5t)/1200)")
    add_silence(0.35)
    add("A3_C4_glissando", glide(base, 261.625565, 2.0), "La3'ten Do4'e sürekli glissando.", "220 * 2^(log2(261.625565/220)*t/2)")
    add_silence(0.35)
    add("G3_yukari_carpma", grace_note(220.0, 195.997718), "Sol3 öncesinde 70 ms yukarı çarpma: La3 → Sol3.", "0–70 ms: 220 Hz; sonra 195.997718 Hz")
    add_silence(1.0)

    audio = np.concatenate(blocks)
    pcm16 = (np.clip(audio, -0.98, 0.98) * np.iinfo(np.int16).max).astype("<i2")
    with wave.open(str(WAV_PATH), "wb") as destination:
        destination.setnchannels(1)
        destination.setsampwidth(2)
        destination.setframerate(SAMPLE_RATE)
        destination.writeframes(pcm16.tobytes())

    MANIFEST_PATH.write_text(json.dumps({
        "format": "48 kHz, mono, 16-bit PCM WAV",
        "duration_seconds": round(len(audio) / SAMPLE_RATE, 3),
        "purpose": "Vibrato rate and ornament resolution comparison for live pitch monitors.",
        "sections": sections,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(WAV_PATH)
    print(MANIFEST_PATH)


if __name__ == "__main__":
    main()
