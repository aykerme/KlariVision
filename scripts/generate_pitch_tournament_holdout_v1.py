#!/usr/bin/env python3
"""Generate the frozen, analytic holdout for the live pitch-engine tournament.

This suite is intentionally separate from the development fixtures. Its
parameters must not be used for threshold tuning. A failed tournament creates
a new development case; it does not mutate this v1 holdout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "data/benchmarks"
RATE = 48_000
TRUTH_STEP = 0.010
SEED = 20260803


class Holdout:
    def __init__(self) -> None:
        self.audio: list[np.ndarray] = []
        self.truth: list[np.ndarray] = []
        self.sections: list[dict[str, object]] = []
        self.time = 0.0

    def add(
        self,
        label: str,
        frequencies: np.ndarray,
        *,
        kind: str,
        fundamental: np.ndarray | float = 1.0,
        amplitude: np.ndarray | float = 0.22,
        harmonics: tuple[float, ...] = (0.18, 0.63, 0.08, 0.27, 0.05, 0.12),
    ) -> None:
        count = len(frequencies)
        phase = 2 * np.pi * np.cumsum(frequencies) / RATE
        fundamental_array = np.full(count, fundamental) if np.isscalar(fundamental) else fundamental
        amplitude_array = np.full(count, amplitude) if np.isscalar(amplitude) else amplitude
        attack = min(round(0.011 * RATE), count // 6)
        release = min(round(0.019 * RATE), count // 6)
        envelope = np.ones(count)
        if attack:
            envelope[:attack] = np.sin(np.linspace(0, np.pi / 2, attack)) ** 2
        if release:
            envelope[-release:] = np.cos(np.linspace(0, np.pi / 2, release)) ** 2
        signal = fundamental_array * np.sin(phase + 0.07)
        for order, strength in enumerate(harmonics, start=2):
            signal += strength * np.sin(order * phase + 0.11 * order)
        signal = amplitude_array * envelope * np.tanh(1.08 * signal) / np.tanh(1.08)
        duration = count / RATE
        self.audio.append(signal.astype(np.float64))
        self.truth.append(frequencies.astype(np.float64))
        self.sections.append({
            "label": label,
            "kind": kind,
            "start_seconds": round(self.time, 6),
            "end_seconds": round(self.time + duration, 6),
        })
        self.time += duration

    def silence(self, seconds: float) -> None:
        count = round(seconds * RATE)
        self.audio.append(np.zeros(count))
        self.truth.append(np.zeros(count))
        self.sections.append({
            "label": "silence",
            "kind": "silence",
            "start_seconds": round(self.time, 6),
            "end_seconds": round(self.time + seconds, 6),
        })
        self.time += seconds


def constant(frequency: float, seconds: float) -> np.ndarray:
    return np.full(round(seconds * RATE), frequency)


def vibrato(center: float, seconds: float, rate: float, depth: float) -> np.ndarray:
    timeline = np.arange(round(seconds * RATE)) / RATE
    return center * 2 ** (depth * np.sin(2 * np.pi * rate * timeline + 0.37) / 1200)


def curved_glide(start: float, finish: float, seconds: float, exponent: float) -> np.ndarray:
    position = np.linspace(0, 1, round(seconds * RATE), endpoint=False) ** exponent
    return start * (finish / start) ** position


def room_variant(signal: np.ndarray, rng: np.random.Generator, snr_db: float) -> np.ndarray:
    impulse = np.zeros(round(0.143 * RATE))
    impulse[0] = 1.0
    impulse[round(0.017 * RATE)] = 0.19
    impulse[round(0.043 * RATE)] = -0.09
    impulse[round(0.088 * RATE)] = 0.055
    reflected = np.convolve(signal, impulse, mode="full")[:len(signal)]
    active = reflected[np.abs(reflected) > 0.001]
    rms = math.sqrt(float(np.mean(active * active))) if len(active) else 0.1
    white = rng.normal(0, 1, len(signal))
    coloured = np.convolve(white, np.ones(31) / 31, mode="same")
    coloured /= max(float(np.std(coloured)), 1e-12)
    return reflected + coloured * rms / 10 ** (snr_db / 20)


def add_interference(signal: np.ndarray) -> np.ndarray:
    result = signal.copy()
    for start, frequency, duration in ((5.37, 184.0, 0.43), (13.91, 273.0, 0.61), (24.28, 121.0, 0.52)):
        begin = round(start * RATE)
        count = min(round(duration * RATE), len(result) - begin)
        if count <= 0:
            continue
        timeline = np.arange(count) / RATE
        envelope = np.sin(np.pi * np.arange(count) / max(1, count - 1)) ** 2
        result[begin:begin + count] += 0.045 * envelope * (
            np.sin(2 * np.pi * frequency * timeline) + 0.36 * np.sin(4 * np.pi * frequency * timeline)
        )
    return result


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = Holdout()
    # Detuned anchors avoid reusing the equal-tempered development frequencies.
    for frequency in (86.7, 103.4, 137.2, 183.6, 274.3, 411.7, 823.1, 1097.4, 1379.2):
        suite.add(f"detuned_anchor_{frequency:.1f}", constant(frequency, 0.63), kind="detuned_anchor")
        suite.silence(0.073)

    # Different suppression curves and durations from the development suite.
    for frequency, seconds in ((96.3, 1.27), (128.6, 1.41), (171.4, 1.19)):
        position = np.linspace(0, 1, round(seconds * RATE))
        fundamental = 0.025 + 0.975 * np.sin(np.pi * position) ** 4
        suite.add(
            f"hidden_fundamental_{frequency:.1f}", constant(frequency, seconds),
            kind="hidden_fundamental", fundamental=fundamental,
            harmonics=(0.74, 0.92, 0.11, 0.38, 0.06, 0.16),
        )
        suite.silence(0.081)

    for center, rate, depth in ((173.8, 5.3, 21.0), (347.1, 7.7, 37.0), (1041.3, 11.2, 19.0)):
        suite.add(
            f"asymmetric_vibrato_{center:.1f}_{rate:.1f}", vibrato(center, 1.21, rate, depth),
            kind="vibrato",
        )
        suite.silence(0.067)

    for start, finish, exponent in ((91.2, 703.5, 1.7), (1268.0, 154.7, 0.63)):
        suite.add(
            f"curved_glide_{start:.1f}_{finish:.1f}", curved_glide(start, finish, 1.73, exponent),
            kind="curved_glide",
        )
        suite.silence(0.089)

    # Direct transitions have no inserted silence, making settling measurable.
    for index, frequency in enumerate((118.9, 356.7, 178.4, 713.6, 237.9, 951.6, 475.8, 142.7)):
        suite.add(f"rapid_transition_{index:02d}", constant(frequency, 0.31), kind="rapid_transition")
    suite.silence(0.113)

    for index, grace in enumerate((207.3, 258.9, 164.2, 310.7)):
        suite.add(f"short_attack_{index:02d}", constant(grace, 0.047), kind="short_attack")
        suite.add(f"attack_target_{index:02d}", constant(232.6, 0.43), kind="attack_target")
        suite.silence(0.061)

    count = round(2.63 * RATE)
    amplitude = np.full(count, 0.21)
    for start, duration in ((0.38, 0.028), (0.97, 0.071), (1.74, 0.039), (2.31, 0.084)):
        amplitude[round(start * RATE):round((start + duration) * RATE)] = 0
    suite.add("irregular_dropouts", constant(319.4, count / RATE), kind="dropout", amplitude=amplitude)
    suite.silence(0.17)
    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_holdout(output: Path) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()
    rng = np.random.default_rng(SEED)
    room = room_variant(clean, rng, 29.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 17.0))
    peak = max(float(np.max(np.abs(clean))), float(np.max(np.abs(room))), float(np.max(np.abs(adverse))), 1e-12)
    variants = {
        "klarivision_pitch_tournament_holdout_clean_v1.wav": clean * 0.87 / peak,
        "klarivision_pitch_tournament_holdout_room_v1.wav": room * 0.87 / peak,
        "klarivision_pitch_tournament_holdout_adverse_v1.wav": adverse * 0.87 / peak,
    }
    hashes: dict[str, str] = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    step = round(TRUTH_STEP * RATE)
    rows = [
        {
            "time_seconds": round(index / RATE, 6),
            "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None,
        }
        for index in range(0, len(truth), step)
    ]
    manifest = {
        "schema": "klarivision-pitch-tournament-holdout-v1",
        "policy": "frozen-no-retuning-after-first-result",
        "sample_rate_hz": RATE,
        "truth_step_seconds": TRUTH_STEP,
        "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED,
        "variants": list(variants),
        "variant_conditions": {
            "klarivision_pitch_tournament_holdout_clean_v1.wav": {"silence_guard_seconds": 0.016},
            "klarivision_pitch_tournament_holdout_room_v1.wav": {"silence_guard_seconds": 0.150},
            "klarivision_pitch_tournament_holdout_adverse_v1.wav": {"silence_guard_seconds": 0.150},
        },
        "sha256": hashes,
        "sections": sections,
        "ground_truth": rows,
    }
    manifest_path = output / "klarivision_pitch_tournament_holdout_ground_truth_v1.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args()
    manifest = write_holdout(arguments.output_dir)
    print(f"holdout={arguments.output_dir} duration={manifest['duration_seconds']} variants={len(manifest['variants'])}")


if __name__ == "__main__":
    main()
