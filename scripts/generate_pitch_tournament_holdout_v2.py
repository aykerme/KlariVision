#!/usr/bin/env python3
"""Generate a separately frozen high-register holdout for pitch engine v2.

Unlike holdout v1 this suite deliberately concentrates on 900–1500 Hz
continuity, including glissando peaks and short analytic gaps inside a glide.
Its constants are not used by the development calibration.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

from generate_pitch_tournament_holdout_v1 import (
    DEFAULT_OUTPUT, RATE, TRUTH_STEP, Holdout, add_interference, room_variant,
)


SEED = 20260808


def glide(start: float, finish: float, seconds: float, exponent: float = 1.0) -> np.ndarray:
    position = np.linspace(0, 1, round(seconds * RATE), endpoint=False) ** exponent
    return start * (finish / start) ** position


def constant(frequency: float, seconds: float) -> np.ndarray:
    return np.full(round(seconds * RATE), frequency)


def vibrato(center: float, seconds: float, rate: float, depth: float) -> np.ndarray:
    timeline = np.arange(round(seconds * RATE)) / RATE
    return center * 2 ** (depth * np.sin(2 * np.pi * rate * timeline + 0.19) / 1200)


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = Holdout()
    for frequency in (917.3, 1046.6, 1211.9, 1388.4, 1472.1):
        suite.add(f"high_anchor_{frequency:.1f}", constant(frequency, 0.71), kind="high_anchor")
        suite.silence(0.079)
    for start, finish, exponent in ((734.2, 1468.7, 1.31), (1491.2, 862.4, 0.71)):
        suite.add(
            f"high_curved_glide_{start:.1f}_{finish:.1f}",
            glide(start, finish, 1.91, exponent), kind="high_curved_glide",
        )
        suite.silence(0.083)
    for center, rate, depth in ((988.7, 6.1, 23.0), (1263.4, 9.4, 31.0), (1438.8, 7.2, 19.0)):
        suite.add(
            f"high_vibrato_{center:.1f}", vibrato(center, 1.34, rate, depth), kind="high_vibrato",
            harmonics=(0.32, 0.67, 0.07, 0.25, 0.04, 0.10),
        )
        suite.silence(0.071)
    # Split one glide with explicit truth silences so missing-output scoring
    # never mistakes a deliberately silent gap for a detector failure.
    values = glide(883.6, 1447.2, 2.17, 1.16)
    first = round(0.48 * RATE)
    second = round(1.28 * RATE)
    suite.add("high_glide_gap_a", values[:first], kind="high_glide_gap")
    suite.silence(0.034)
    suite.add("high_glide_gap_b", values[first:second], kind="high_glide_gap")
    suite.silence(0.052)
    suite.add("high_glide_gap_c", values[second:], kind="high_glide_gap")
    suite.silence(0.14)
    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_holdout(output: Path = DEFAULT_OUTPUT) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()
    room = room_variant(clean, np.random.default_rng(SEED), 27.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 16.0))
    peak = max(float(np.max(np.abs(clean))), float(np.max(np.abs(room))), float(np.max(np.abs(adverse))), 1e-12)
    variants = {
        "klarivision_pitch_tournament_holdout_clean_v2.wav": clean * 0.87 / peak,
        "klarivision_pitch_tournament_holdout_room_v2.wav": room * 0.87 / peak,
        "klarivision_pitch_tournament_holdout_adverse_v2.wav": adverse * 0.87 / peak,
    }
    hashes = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    step = round(TRUTH_STEP * RATE)
    manifest = {
        "schema": "klarivision-pitch-tournament-holdout-v2",
        "policy": "frozen-no-retuning-after-first-result",
        "sample_rate_hz": RATE,
        "truth_step_seconds": TRUTH_STEP,
        "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED,
        "variants": list(variants),
        "variant_conditions": {name: {"silence_guard_seconds": 0.150 if "clean" not in name else 0.016} for name in variants},
        "sha256": hashes,
        "sections": sections,
        "ground_truth": [
            {"time_seconds": round(index / RATE, 6), "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None}
            for index in range(0, len(truth), step)
        ],
    }
    (output / "klarivision_pitch_tournament_holdout_ground_truth_v2.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


if __name__ == "__main__":
    write_holdout()
