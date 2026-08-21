#!/usr/bin/env python3
"""Create a deterministic full-range clarinet pitch benchmark.

The test is intended for the *live* microphone path: play it through the
speaker and inspect whether a known musical note is replaced by an octave or
subharmonic. Every expected target is also stored in the JSON manifest.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "data" / "benchmarks"
SAMPLE_RATE = 48_000
NOTE_DURATION = 0.62
GAP_DURATION = 0.10


def midi_frequency(midi: int) -> float:
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def clarinet_tone(frequency: float, seconds: float, vibrato_cents: float) -> np.ndarray:
    count = round(seconds * SAMPLE_RATE)
    time = np.arange(count) / SAMPLE_RATE
    # 4 Hz, ±16 cent vibrato: sufficiently visible without turning each
    # short chromatic step into a difficult vibrato-only test.
    instantaneous = frequency * 2.0 ** (
        vibrato_cents * np.sin(2 * np.pi * 4.0 * time) / 1200.0
    )
    phase = 2 * np.pi * np.cumsum(instantaneous) / SAMPLE_RATE
    signal = sum(
        amplitude * np.sin(partial * phase)
        for partial, amplitude in ((1, 1.0), (3, 0.48), (5, 0.24), (7, 0.12))
    )
    attack = min(round(0.018 * SAMPLE_RATE), count // 4)
    release = min(round(0.035 * SAMPLE_RATE), count // 3)
    envelope = np.ones(count)
    envelope[:attack] = np.linspace(0, 1, attack, endpoint=False)
    envelope[-release:] = np.linspace(1, 0, release, endpoint=True)
    return (0.17 * signal * envelope).astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(round(seconds * SAMPLE_RATE), dtype=np.float32)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    audio: list[np.ndarray] = []
    sections: list[dict[str, object]] = []
    time = 0.0

    # E2 (82.41 Hz) to E6 (1318.51 Hz): 49 chromatic pitch centres.
    # Low notes are repeated at the beginning because this is where room
    # rumble and subharmonics are most likely to be confused with a note.
    midi_values = [40, 41, 42, 43, 44] + list(range(40, 89))
    for index, midi in enumerate(midi_values):
        frequency = midi_frequency(midi)
        vibrato = 0.0 if index < 5 else 16.0
        note = clarinet_tone(frequency, NOTE_DURATION, vibrato)
        audio.append(note)
        sections.append(
            {
                "start_seconds": round(time, 4),
                "end_seconds": round(time + NOTE_DURATION, 4),
                "midi": midi,
                "frequency_hz": round(frequency, 4),
                "vibrato_cents": vibrato,
            }
        )
        time += NOTE_DURATION
        audio.append(silence(GAP_DURATION))
        time += GAP_DURATION

    # A continuous logarithmic glide finds regions where the candidate
    # selection changes octave between two chromatic test notes.
    glide_seconds = 4.0
    glide_time = np.arange(round(glide_seconds * SAMPLE_RATE)) / SAMPLE_RATE
    start_frequency = midi_frequency(40)
    end_frequency = midi_frequency(88)
    glide_frequency = start_frequency * (end_frequency / start_frequency) ** (glide_time / glide_seconds)
    glide_phase = 2 * np.pi * np.cumsum(glide_frequency) / SAMPLE_RATE
    glide = 0.14 * (
        np.sin(glide_phase)
        + 0.40 * np.sin(3 * glide_phase)
        + 0.18 * np.sin(5 * glide_phase)
    )
    edge = round(0.025 * SAMPLE_RATE)
    glide[:edge] *= np.linspace(0, 1, edge, endpoint=False)
    glide[-edge:] *= np.linspace(1, 0, edge, endpoint=True)
    audio.append(glide.astype(np.float32))
    sections.append(
        {
            "start_seconds": round(time, 4),
            "end_seconds": round(time + glide_seconds, 4),
            "type": "logarithmic_glide",
            "start_frequency_hz": round(start_frequency, 4),
            "end_frequency_hz": round(end_frequency, 4),
        }
    )

    output = OUTPUT / "clarinet_full_range_pitch_benchmark_v1.wav"
    manifest = OUTPUT / "clarinet_full_range_pitch_benchmark_v1.json"
    sf.write(output, np.concatenate(audio), SAMPLE_RATE, subtype="PCM_16")
    manifest.write_text(
        json.dumps(
            {
                "schema": "klarivision-full-range-pitch-benchmark-v1",
                "sample_rate_hz": SAMPLE_RATE,
                "note_duration_seconds": NOTE_DURATION,
                "gap_duration_seconds": GAP_DURATION,
                "description": "E2–E6 kromatik klarnet-benzeri tarama; düşük kayıt tekrarları ve logaritmik glide.",
                "sections": sections,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(output)
    print(manifest)


if __name__ == "__main__":
    main()
