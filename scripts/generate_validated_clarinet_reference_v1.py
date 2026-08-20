#!/usr/bin/env python3
"""Generate a realistic, analytically known clarinet pitch reference.

Unlike the destructive stress fixture, this recording keeps the fundamental
audible and uses only plausible clarinet harmonics, attacks, vibrato and room
noise.  It is eligible as a correctness reference only after the accompanying
evaluator confirms that pYIN itself follows the analytic ground truth.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "data" / "benchmarks"
RATE = 48_000
SEED = 20260801


class Reference:
    def __init__(self) -> None:
        self.audio: list[np.ndarray] = []
        self.truth: list[np.ndarray] = []
        self.sections: list[dict[str, object]] = []
        self.time = 0.0

    def add(self, label: str, frequencies: np.ndarray, *, kind: str) -> None:
        count = len(frequencies)
        phase = 2 * np.pi * np.cumsum(frequencies) / RATE
        # A conservative clarinet-like spectrum.  The fundamental always
        # remains the dominant line, while odd harmonics still challenge YIN.
        signal = (
            np.sin(phase)
            + 0.07 * np.sin(2 * phase + 0.13)
            + 0.42 * np.sin(3 * phase + 0.21)
            + 0.19 * np.sin(5 * phase + 0.34)
            + 0.08 * np.sin(7 * phase + 0.48)
        )
        attack = min(round(0.018 * RATE), count // 5)
        release = min(round(0.025 * RATE), count // 5)
        envelope = np.ones(count)
        if attack:
            envelope[:attack] = np.sin(np.linspace(0, np.pi / 2, attack)) ** 2
        if release:
            envelope[-release:] = np.cos(np.linspace(0, np.pi / 2, release)) ** 2
        signal = 0.24 * envelope * np.tanh(signal) / np.tanh(1.0)
        start = self.time
        duration = count / RATE
        self.audio.append(signal.astype(np.float32))
        self.truth.append(frequencies.astype(np.float64))
        self.sections.append({
            "label": label,
            "kind": kind,
            "start_seconds": round(start, 6),
            "end_seconds": round(start + duration, 6),
        })
        self.time += duration

    def silence(self, seconds: float) -> None:
        count = round(seconds * RATE)
        self.audio.append(np.zeros(count, dtype=np.float32))
        self.truth.append(np.zeros(count, dtype=np.float64))
        self.sections.append({
            "label": "silence",
            "kind": "silence",
            "start_seconds": round(self.time, 6),
            "end_seconds": round(self.time + seconds, 6),
        })
        self.time += seconds


def constant(frequency: float, seconds: float) -> np.ndarray:
    return np.full(round(seconds * RATE), frequency, dtype=np.float64)


def vibrato(center: float, seconds: float, rate_hz: float, depth_cents: float) -> np.ndarray:
    time = np.arange(round(seconds * RATE)) / RATE
    return center * 2 ** (depth_cents * np.sin(2 * np.pi * rate_hz * time) / 1200)


def glide(start: float, finish: float, seconds: float) -> np.ndarray:
    position = np.linspace(0, 1, round(seconds * RATE), endpoint=False)
    return start * (finish / start) ** position


def add_room_variant(signal: np.ndarray) -> np.ndarray:
    generator = np.random.default_rng(SEED)
    impulse = np.zeros(round(0.095 * RATE))
    impulse[0] = 1
    impulse[round(0.021 * RATE)] = 0.13
    impulse[round(0.049 * RATE)] = 0.06
    room = np.convolve(signal, impulse, mode="full")[: len(signal)]
    active = room[np.abs(room) > 0.002]
    rms = np.sqrt(np.mean(active * active)) if len(active) else 0.1
    noise = generator.normal(0, rms / 10 ** (34 / 20), len(room))
    return room + noise


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    reference = Reference()

    # Stable notes spanning the useful live-monitor register.
    anchors = (110.0, 146.8324, 195.9977, 220.0, 246.9417, 293.6648,
               329.6276, 391.9954, 440.0, 523.2511, 587.3295, 659.2551,
               783.9909, 880.0, 987.7666, 1174.659)
    for frequency in anchors:
        reference.add(f"anchor_{frequency:.2f}", constant(frequency, 0.72), kind="anchor")
        reference.silence(0.10)

    # Direct register changes, deliberately long enough for both causal and
    # offline engines to settle before scoring.
    jumps = (146.8324, 293.6648, 146.8324, 440.0, 220.0, 659.2551,
             329.6276, 987.7666, 493.8833, 1174.659, 587.3295, 220.0)
    for index, frequency in enumerate(jumps):
        reference.add(f"jump_{index:02d}", constant(frequency, 0.55), kind="register_jump")
    reference.silence(0.18)

    # Vibrato resolution at several registers.  These are demanding but remain
    # inside a plausible instrumental range.
    for center in (146.8324, 220.0, 440.0, 880.0):
        for rate_hz, depth in ((4.0, 24.0), (6.5, 32.0), (9.0, 28.0)):
            reference.add(
                f"vibrato_{center:.2f}_{rate_hz:.1f}",
                vibrato(center, 1.35, rate_hz, depth),
                kind="vibrato",
            )
            reference.silence(0.10)

    for start, finish in ((110.0, 440.0), (440.0, 1174.659),
                          (1174.659, 293.6648), (293.6648, 146.8324)):
        reference.add(
            f"glide_{start:.2f}_{finish:.2f}", glide(start, finish, 1.55), kind="glide"
        )
        reference.silence(0.12)

    # Short but analysable grace attacks.
    for index, grace in enumerate((246.9417, 195.9977, 261.6256, 174.6141)):
        reference.add(f"grace_{index:02d}", constant(grace, 0.085), kind="grace")
        reference.add(f"target_{index:02d}", constant(220.0, 0.70), kind="target")
        reference.silence(0.10)

    signal = np.concatenate(reference.audio).astype(np.float64)
    truth = np.concatenate(reference.truth)
    room = add_room_variant(signal)
    peak = max(np.max(np.abs(signal)), np.max(np.abs(room)), 1e-9)
    signal *= 0.86 / peak
    room *= 0.86 / peak

    variants = {
        "klarivision_validated_clarinet_clean_v1.wav": signal,
        "klarivision_validated_clarinet_room_v1.wav": room,
    }
    for filename, samples in variants.items():
        sf.write(OUTPUT / filename, samples, RATE, subtype="PCM_16")

    step = round(0.010 * RATE)
    ground_truth = []
    for sample in range(0, len(truth), step):
        frequency = float(truth[min(sample, len(truth) - 1)])
        ground_truth.append({
            "time_seconds": round(sample / RATE, 6),
            "frequency_hz": round(frequency, 6) if frequency > 0 else None,
        })
    manifest = {
        "schema": "klarivision-validated-clarinet-reference-v1",
        "sample_rate": RATE,
        "duration_seconds": round(len(signal) / RATE, 6),
        "variants": list(variants),
        "sections": reference.sections,
        "ground_truth": ground_truth,
        "eligibility_rule": "pYIN must pass ground truth before live-engine results are valid",
    }
    (OUTPUT / "klarivision_validated_clarinet_ground_truth_v1.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"duration={manifest['duration_seconds']} sections={len(reference.sections)}")
    for filename in variants:
        print(OUTPUT / filename)


if __name__ == "__main__":
    main()
