#!/usr/bin/env python3
"""Measure the experimental autocorrelation engine against the clean reference WAV.

This is intentionally an offline, deterministic diagnostic.  It exercises the
same window, hop and peak-selection rules as the Swift live engine but removes
microphone, loudspeaker and room effects from the measurement.
"""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
WAV_PATH = ROOT / "data/benchmarks/canli_pitch_referans_v1.wav"
MANIFEST_PATH = ROOT / "data/benchmarks/canli_pitch_referans_v1.json"
OUTPUT_PATH = ROOT / "outputs/live-pitch-benchmark-autocorrelation-v1.json"
WINDOW = 4096
HOP = 512


def cents(actual: float, expected: float) -> float:
    return 1200 * math.log2(actual / expected)


def estimate_autocorrelation(samples: np.ndarray, sample_rate: int) -> tuple[float, float] | None:
    rms = float(np.sqrt(np.mean(samples * samples)))
    if rms <= 0.006:
        return None
    min_lag = max(2, int(sample_rate / 1500))
    max_lag = min(len(samples) // 2, int(sample_rate / 80))
    energy = np.concatenate(([0.0], np.cumsum(samples * samples, dtype=np.float64)))
    correlation = np.zeros(max_lag + 1)
    for lag in range(min_lag, max_lag + 1):
        count = len(samples) - lag
        e1 = energy[count]
        e2 = energy[len(samples)] - energy[lag]
        correlation[lag] = np.dot(samples[:count], samples[lag:]) / max(1e-12, math.sqrt(e1 * e2))
    peaks = [lag for lag in range(min_lag + 1, max_lag) if correlation[lag] >= correlation[lag - 1] and correlation[lag] > correlation[lag + 1]]
    if not peaks:
        return None
    strongest = max(peaks, key=lambda lag: correlation[lag])
    if correlation[strongest] < 0.38:
        return None
    selected = next((lag for lag in peaks if correlation[lag] >= max(0.52, correlation[strongest] * 0.84)), strongest)
    previous, current, next_value = correlation[selected - 1], correlation[selected], correlation[selected + 1]
    denominator = previous - 2 * current + next_value
    correction = 0.5 * (previous - next_value) / denominator if abs(denominator) > 1e-6 else 0.0
    lag = selected + max(-0.5, min(0.5, correction))
    frequency = sample_rate / lag
    return (frequency, float(np.clip(current, 0, 1))) if 80 <= frequency <= 1500 else None


def expected_frequency(label: str, local_time: float) -> float:
    fixed = {
        "A3_sabit": 220.0,
        "C4_sabit": 261.625565,
        "E4_sabit": 329.627557,
        "A4_sabit": 440.0,
        "C3_sabit": 130.812783,
        "C4_ani_gecis": 261.625565,
        "A3_10cent_pes": 220.0 * 2 ** (-10 / 1200),
        "A3_tam": 220.0,
        "A3_10cent_tiz": 220.0 * 2 ** (10 / 1200),
    }
    if label in fixed:
        return fixed[label]
    if label == "A3_vibrato":
        return 220.0 * 2 ** (30 * math.sin(2 * math.pi * 5.5 * local_time) / 1200)
    if label == "E4_vibrato":
        return 329.627557 * 2 ** (22 * math.sin(2 * math.pi * 6.0 * local_time) / 1200)
    if label == "A3_C4_glissando":
        return 220.0 * 2 ** (math.log2(261.625565 / 220.0) * local_time / 1.5)
    if label == "G3_yukari_carpma":
        return 220.0 if local_time < 0.060 else 195.997718
    if label == "G3_asagi_carpma":
        return 174.614116 if local_time < 0.060 else 195.997718
    raise KeyError(label)


def main() -> None:
    with wave.open(str(WAV_PATH), "rb") as source:
        sample_rate = source.getframerate()
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    frames = []
    for end in range(WINDOW, len(audio) + 1, HOP):
        result = estimate_autocorrelation(audio[end - WINDOW:end], sample_rate)
        if result:
            # A windowed measurement describes the centre of its input window,
            # not its final sample.  This prevents a false phase error when
            # evaluating deliberately moving signals such as vibrato.
            frames.append({"time_seconds": (end - WINDOW / 2) / sample_rate, "frequency": result[0], "confidence": result[1]})

    sections = []
    for section in manifest["sections"]:
        start, end = section["start_seconds"], section["end_seconds"]
        # Ignore fade-in/out so the score evaluates the intended sounding body.
        matching = [frame for frame in frames if start + 0.08 <= frame["time_seconds"] <= end - 0.08]
        errors = [abs(cents(frame["frequency"], expected_frequency(section["label"], frame["time_seconds"] - start))) for frame in matching]
        sections.append({
            "label": section["label"],
            "frames": len(matching),
            "median_absolute_cent_error": round(float(np.median(errors)), 2) if errors else None,
            "p95_absolute_cent_error": round(float(np.percentile(errors, 95)), 2) if errors else None,
            "median_confidence": round(float(np.median([frame["confidence"] for frame in matching])), 3) if matching else None,
        })

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps({
        "engine": "experimental_autocorrelation",
        "sample_rate": sample_rate,
        "window": WINDOW,
        "hop": HOP,
        "frame_rate_hz": round(sample_rate / HOP, 2),
        "detected_frames": len(frames),
        "sections": sections,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
