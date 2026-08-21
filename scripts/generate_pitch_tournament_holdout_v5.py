#!/usr/bin/env python3
"""Generate an independent high-register acceptance holdout for live engines."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

from generate_pitch_tournament_holdout_v1 import DEFAULT_OUTPUT, RATE, TRUTH_STEP, Holdout, add_interference, room_variant
from generate_pitch_tournament_holdout_v2 import constant, glide, vibrato


SEED = 20260811


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = Holdout()
    # Deliberately distinct frequencies, durations and contour shapes from
    # prior holdouts. This fixture is written before the next V2 change.
    for frequency, seconds in ((941.3, .73), (1257.6, .54), (1433.8, .81), (1089.7, .47)):
        suite.add(f"accept5_anchor_{frequency:.1f}", constant(frequency, seconds), kind="high_anchor")
        suite.silence(.063)
    suite.add("accept5_rise", glide(864.2, 1451.6, 1.71, 1.12), kind="high_curved_glide")
    suite.silence(.084)
    suite.add("accept5_fall", glide(1466.9, 838.4, 1.94, .78), kind="high_curved_glide")
    suite.silence(.051)
    for center, rate, depth in ((1186.4, 8.4, 26.0), (1368.9, 5.9, 33.0)):
        suite.add(f"accept5_vibrato_{center:.1f}", vibrato(center, 1.27, rate, depth), kind="high_vibrato",
                  harmonics=(.35, .54, .16, .14, .07, .04))
        suite.silence(.092)
    values = glide(897.4, 1444.2, 1.83, .69)
    split = round(1.13 * RATE)
    suite.add("accept5_gap_a", values[:split], kind="high_glide_gap")
    suite.silence(.042)
    suite.add("accept5_gap_b", values[split:], kind="high_glide_gap")
    suite.silence(.11)
    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_holdout(output: Path = DEFAULT_OUTPUT) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()
    room = room_variant(clean, np.random.default_rng(SEED), 19.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 11.0))
    peak = max(float(np.max(np.abs(clean))), float(np.max(np.abs(room))), float(np.max(np.abs(adverse))), 1e-12)
    variants = {f"klarivision_pitch_tournament_holdout_{condition}_v5.wav": samples * .87 / peak
                for condition, samples in (("clean", clean), ("room", room), ("adverse", adverse))}
    hashes = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    step = round(TRUTH_STEP * RATE)
    manifest = {
        "schema": "klarivision-pitch-tournament-holdout-v5", "policy": "frozen-no-retuning-after-first-result",
        "sample_rate_hz": RATE, "truth_step_seconds": TRUTH_STEP, "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED, "variants": list(variants), "variant_conditions": {
            name: {"silence_guard_seconds": .016 if "clean" in name else .150} for name in variants},
        "sha256": hashes, "sections": sections,
        "ground_truth": [{"time_seconds": round(index / RATE, 6), "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None}
                         for index in range(0, len(truth), step)],
    }
    (output / "klarivision_pitch_tournament_holdout_ground_truth_v5.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    write_holdout()
