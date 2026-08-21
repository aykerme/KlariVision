#!/usr/bin/env python3
"""Generate deterministic clean, clarinet and adverse pitch stress fixtures.

The suite concentrates on failure modes observed while developing the live
KlariVision engine.  Every 10 ms receives a known target frequency in the
shared manifest, so changes can be scored without treating pYIN as ground
truth.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "data" / "benchmarks"
RATE = 48_000
TRUTH_STEP = 0.010
SEED = 20260801


class Suite:
    def __init__(self) -> None:
        self.clean: list[np.ndarray] = []
        self.clarinet: list[np.ndarray] = []
        self.frequency: list[np.ndarray] = []
        self.sections: list[dict[str, object]] = []
        self.time = 0.0

    def append(
        self,
        label: str,
        frequencies: np.ndarray | None,
        *,
        kind: str,
        amplitude: np.ndarray | float = 0.20,
        harmonic_morph: bool = False,
        details: dict[str, object] | None = None,
    ) -> None:
        count = len(frequencies) if frequencies is not None else round(float(amplitude) * RATE)
        if frequencies is None:
            signal_clean = np.zeros(count, dtype=np.float64)
            signal_clarinet = signal_clean.copy()
            truth = np.zeros(count, dtype=np.float64)
        else:
            truth = frequencies.astype(np.float64)
            phase = 2 * np.pi * np.cumsum(truth) / RATE
            amp = np.full(count, amplitude, dtype=np.float64) if np.isscalar(amplitude) else np.asarray(amplitude)
            edge = min(round(0.018 * RATE), count // 5)
            envelope = np.ones(count)
            if edge:
                envelope[:edge] = np.linspace(0, 1, edge, endpoint=False)
                envelope[-edge:] = np.linspace(1, 0, edge, endpoint=True)
            signal_clean = amp * envelope * (
                np.sin(phase) + 0.08 * np.sin(2 * phase) + 0.06 * np.sin(3 * phase)
            )
            if harmonic_morph:
                position = np.linspace(0, 1, count)
                # Hide and restore the fundamental while 2× and 3× remain
                # strong. This reproduces the octave/subharmonic ambiguity
                # found in real Şükrü Tunar passages.
                fundamental = 0.05 + 0.95 * np.abs(np.cos(np.pi * position))
                second = 0.70 + 0.20 * np.sin(2 * np.pi * position) ** 2
                third = 0.82 - 0.10 * np.cos(2 * np.pi * position)
            else:
                fundamental = np.ones(count)
                second = np.full(count, 0.15)
                third = np.full(count, 0.58)
            reed = (
                fundamental * np.sin(phase)
                + second * np.sin(2 * phase + 0.12)
                + third * np.sin(3 * phase + 0.21)
                + 0.30 * np.sin(5 * phase)
                + 0.14 * np.sin(7 * phase)
            )
            signal_clarinet = amp * envelope * np.tanh(1.15 * reed) / np.tanh(1.15)
        start = self.time
        duration = count / RATE
        self.clean.append(signal_clean.astype(np.float32))
        self.clarinet.append(signal_clarinet.astype(np.float32))
        self.frequency.append(truth)
        self.sections.append({
            "label": label,
            "kind": kind,
            "start_seconds": round(start, 6),
            "end_seconds": round(start + duration, 6),
            **(details or {}),
        })
        self.time += duration

    def silence(self, seconds: float = 0.14) -> None:
        self.append("silence", None, kind="silence", amplitude=seconds)

    def tone(self, label: str, frequency: float, seconds: float, **kwargs: object) -> None:
        self.append(
            label,
            np.full(round(seconds * RATE), frequency),
            kind=str(kwargs.pop("kind", "steady")),
            details={"frequency_hz": round(frequency, 6), **dict(kwargs.pop("details", {}))},
            **kwargs,
        )


def vibrato(center: float, seconds: float, rate_hz: float, depth_cents: float) -> np.ndarray:
    time = np.arange(round(seconds * RATE)) / RATE
    return center * 2 ** (depth_cents * np.sin(2 * np.pi * rate_hz * time) / 1200)


def glide(start: float, finish: float, seconds: float) -> np.ndarray:
    position = np.linspace(0, 1, round(seconds * RATE), endpoint=False)
    return start * (finish / start) ** position


def coloured_noise(count: int, generator: np.random.Generator) -> np.ndarray:
    white = generator.normal(0, 1, count)
    low = np.convolve(white, np.ones(53) / 53, mode="same")
    value = 0.65 * white + 0.35 * low / max(np.std(low), 1e-12)
    return value / max(np.std(value), 1e-12)


def make_adverse(signal: np.ndarray) -> np.ndarray:
    generator = np.random.default_rng(SEED)
    impulse = np.zeros(round(0.18 * RATE))
    impulse[0] = 1
    impulse[round(0.027 * RATE)] = 0.26
    impulse[round(0.061 * RATE)] = 0.14
    impulse[round(0.123 * RATE)] = 0.07
    reverberant = np.convolve(signal, impulse, mode="full")[: len(signal)]
    active = signal[np.abs(signal) > 0.002]
    active_rms = np.sqrt(np.mean(active * active)) if len(active) else 0.1
    result = reverberant + coloured_noise(len(signal), generator) * active_rms / 10 ** (22 / 20)
    # Deterministic voice-like intrusions test whether an unrelated nearby
    # sound can permanently steal the clarinet contour.
    for start, fundamental in ((12.4, 178.0), (37.2, 205.0), (58.5, 154.0)):
        begin = round(start * RATE)
        count = min(round(0.75 * RATE), len(result) - begin)
        if count <= 0:
            continue
        time = np.arange(count) / RATE
        envelope = np.sin(np.pi * np.arange(count) / max(1, count - 1)) ** 2
        intrusion = 0.055 * envelope * (
            np.sin(2 * np.pi * fundamental * time)
            + 0.45 * np.sin(2 * np.pi * 2 * fundamental * time)
        )
        result[begin:begin + count] += intrusion
    return result


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    suite = Suite()

    # Stable anchors across the practical clarinet range.
    for frequency in (82.4069, 110.0, 146.8324, 220.0, 440.0, 880.0, 1174.659, 1318.510):
        suite.tone(f"anchor_{frequency:.2f}", frequency, 1.0)
        suite.silence()

    # Low fundamentals with deliberately dominant 2× and 3× components.
    for frequency in (92.4986, 110.0, 123.4708, 146.8324, 164.8138):
        suite.tone(
            f"harmonic_morph_{frequency:.2f}", frequency, 1.8,
            kind="harmonic_morph", harmonic_morph=True,
        )
        suite.silence(0.10)

    # Abrupt octave, twelfth and reverse-register transitions.
    jump_frequencies = (110, 220, 110, 330, 165, 495, 247.5, 742.5, 371.25, 1113.75, 556.875, 278.4375)
    for index, frequency in enumerate(jump_frequencies):
        suite.tone(f"register_jump_{index:02d}", frequency, 0.48, kind="register_jump")
        suite.silence(0.035)
    suite.silence(0.20)

    # Resolution ladder: same pitch/depth, increasing vibrato frequency.
    for rate_hz in (2, 4, 6, 8, 10, 12):
        values = vibrato(220.0, 1.65, rate_hz, 34.0)
        suite.append(
            f"vibrato_A3_{rate_hz}Hz", values, kind="vibrato",
            details={"center_hz": 220.0, "rate_hz": rate_hz, "depth_cents": 34.0},
        )
        suite.silence(0.12)

    # High-register vibrato previously produced half/third-frequency locks.
    for center, rate_hz, depth in ((880, 4, 28), (880, 9, 28), (990, 7, 32), (1174.659, 5, 26), (1174.659, 10, 26), (1318.510, 7, 24)):
        values = vibrato(center, 1.55, rate_hz, depth)
        suite.append(
            f"high_vibrato_{center:.2f}_{rate_hz}Hz", values, kind="high_vibrato",
            harmonic_morph=True,
            details={"center_hz": center, "rate_hz": rate_hz, "depth_cents": depth},
        )
        suite.silence(0.12)

    suite.append("glide_up_E2_E6", glide(82.4069, 1318.510, 4.0), kind="glide")
    suite.silence(0.16)
    suite.append("glide_down_E6_E2", glide(1318.510, 82.4069, 4.0), kind="glide")
    suite.silence(0.18)

    # Short grace-note attacks followed by a stable target.
    for index, grace in enumerate((246.9417, 195.9977, 261.6256, 174.6141) * 2):
        suite.tone(f"grace_{index:02d}", grace, 0.060, kind="grace")
        suite.tone(f"grace_target_{index:02d}", 220.0, 0.52, kind="grace_target")
        suite.silence(0.055)
    suite.silence(0.15)

    # Fade through the live gate and brief dropouts inside a sustained note.
    seconds = 4.0
    count = round(seconds * RATE)
    position = np.linspace(0, 1, count)
    amplitude = 0.22 * (0.035 + 0.965 * np.abs(2 * position - 1))
    suite.append(
        "fade_down_up_Re3", np.full(count, 146.8324), kind="amplitude_fade",
        amplitude=amplitude, details={"frequency_hz": 146.8324},
    )
    suite.silence(0.18)

    dropout_frequency = np.full(round(3.0 * RATE), 293.6648)
    dropout_amplitude = np.full(len(dropout_frequency), 0.20)
    for start in (0.72, 1.46, 2.18):
        dropout_amplitude[round(start * RATE):round((start + 0.045) * RATE)] = 0
    suite.append(
        "brief_dropouts_Re4", dropout_frequency, kind="dropouts",
        amplitude=dropout_amplitude, details={"frequency_hz": 293.6648},
    )

    clean = np.concatenate(suite.clean).astype(np.float64)
    clarinet = np.concatenate(suite.clarinet).astype(np.float64)
    truth = np.concatenate(suite.frequency)
    adverse = make_adverse(clarinet)
    peak = max(np.max(np.abs(clean)), np.max(np.abs(clarinet)), np.max(np.abs(adverse)), 1e-9)
    scale = 0.88 / peak
    variants = {
        "klarivision_stress_clean_v2.wav": clean * scale,
        "klarivision_stress_clarinet_v2.wav": clarinet * scale,
        "klarivision_stress_adverse_v2.wav": adverse * scale,
    }
    for filename, samples in variants.items():
        sf.write(OUTPUT / filename, samples, RATE, subtype="PCM_16")

    frame_indices = np.arange(0, len(truth), round(TRUTH_STEP * RATE))
    frames = [
        {
            "time_seconds": round(index / RATE, 3),
            "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None,
        }
        for index in frame_indices
    ]
    manifest = {
        "schema": "klarivision-pitch-stress-suite-v2",
        "sample_rate_hz": RATE,
        "duration_seconds": round(len(truth) / RATE, 6),
        "truth_step_seconds": TRUTH_STEP,
        "random_seed": SEED,
        "variants": list(variants),
        "sections": suite.sections,
        "ground_truth": frames,
    }
    manifest_path = OUTPUT / "klarivision_stress_ground_truth_v2.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for filename in variants:
        print(OUTPUT / filename)
    print(manifest_path)


if __name__ == "__main__":
    main()
