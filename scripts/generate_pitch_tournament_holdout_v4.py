#!/usr/bin/env python3
"""Generate the post-tuning frozen acceptance holdout for live engines."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

from generate_pitch_tournament_holdout_v1 import DEFAULT_OUTPUT, RATE, TRUTH_STEP, Holdout, add_interference, room_variant
from generate_pitch_tournament_holdout_v2 import constant, glide, vibrato


SEED = 20260810


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = Holdout()
    # Kept separate from v1-v3 parameter families so this is an acceptance
    # fixture, not another calibration target.
    for frequency, seconds in ((972.4, .61), (1164.8, .77), (1376.2, .58), (1489.1, .66)):
        suite.add(f"accept4_anchor_{frequency:.1f}", constant(frequency, seconds), kind="high_anchor")
        suite.silence(.087)
    suite.add("accept4_rise", glide(814.6, 1492.1, 1.87, .91), kind="high_curved_glide")
    suite.silence(.059)
    suite.add("accept4_fall", glide(1482.3, 791.4, 2.11, 1.27), kind="high_curved_glide")
    suite.silence(.071)
    for center, rate, depth in ((1073.6, 7.1, 29.0), (1391.7, 10.2, 22.0)):
        suite.add(f"accept4_vibrato_{center:.1f}", vibrato(center, 1.39, rate, depth), kind="high_vibrato",
                  harmonics=(.28, .66, .08, .21, .05, .09))
        suite.silence(.073)
    values = glide(928.1, 1462.8, 2.08, .84)
    split = round(.94 * RATE)
    suite.add("accept4_gap_a", values[:split], kind="high_glide_gap")
    suite.silence(.049)
    suite.add("accept4_gap_b", values[split:], kind="high_glide_gap")
    suite.silence(.12)
    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_holdout(output: Path = DEFAULT_OUTPUT) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()
    room = room_variant(clean, np.random.default_rng(SEED), 21.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 12.0))
    peak = max(float(np.max(np.abs(clean))), float(np.max(np.abs(room))), float(np.max(np.abs(adverse))), 1e-12)
    variants = {f"klarivision_pitch_tournament_holdout_{condition}_v4.wav": samples * .87 / peak
                for condition, samples in (("clean", clean), ("room", room), ("adverse", adverse))}
    hashes = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    step = round(TRUTH_STEP * RATE)
    manifest = {
        "schema": "klarivision-pitch-tournament-holdout-v4", "policy": "frozen-no-retuning-after-first-result",
        "sample_rate_hz": RATE, "truth_step_seconds": TRUTH_STEP, "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED, "variants": list(variants), "variant_conditions": {
            name: {"silence_guard_seconds": .016 if "clean" in name else .150} for name in variants},
        "sha256": hashes, "sections": sections,
        "ground_truth": [{"time_seconds": round(index / RATE, 6), "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None}
                         for index in range(0, len(truth), step)],
    }
    (output / "klarivision_pitch_tournament_holdout_ground_truth_v4.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    write_holdout()
