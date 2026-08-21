#!/usr/bin/env python3
"""Generate the frozen acceptance holdout for perceptual error accounting.

This set was created only after the 30 ms/100-cent reporting policy was
chosen.  Its parameters and seed are intentionally independent of v2, which
is now development evidence for that policy.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

from generate_pitch_tournament_holdout_v1 import DEFAULT_OUTPUT, RATE, TRUTH_STEP, Holdout, add_interference, room_variant
from generate_pitch_tournament_holdout_v2 import constant, glide, vibrato


SEED = 20260809


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = Holdout()
    for frequency, seconds in ((941.8, .67), (1098.7, .73), (1298.4, .69), (1458.6, .64)):
        suite.add(f"accept_anchor_{frequency:.1f}", constant(frequency, seconds), kind="high_anchor")
        suite.silence(.091)
    suite.add("accept_rise", glide(768.9, 1486.2, 2.03, 1.18), kind="high_curved_glide")
    suite.silence(.067)
    suite.add("accept_fall", glide(1476.4, 826.7, 1.79, .79), kind="high_curved_glide")
    suite.silence(.083)
    for center, rate, depth in ((1017.2, 8.3, 27.0), (1327.9, 5.7, 35.0)):
        suite.add(
            f"accept_vibrato_{center:.1f}", vibrato(center, 1.47, rate, depth), kind="high_vibrato",
            harmonics=(.30, .63, .09, .24, .05, .11),
        )
        suite.silence(.077)
    values = glide(905.3, 1432.5, 1.93, 1.07)
    split = round(.81 * RATE)
    suite.add("accept_glide_gap_a", values[:split], kind="high_glide_gap")
    suite.silence(.043)
    suite.add("accept_glide_gap_b", values[split:], kind="high_glide_gap")
    suite.silence(.13)
    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_holdout(output: Path = DEFAULT_OUTPUT) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()
    room = room_variant(clean, np.random.default_rng(SEED), 24.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 14.0))
    peak = max(float(np.max(np.abs(clean))), float(np.max(np.abs(room))), float(np.max(np.abs(adverse))), 1e-12)
    variants = {
        "klarivision_pitch_tournament_holdout_clean_v3.wav": clean * .87 / peak,
        "klarivision_pitch_tournament_holdout_room_v3.wav": room * .87 / peak,
        "klarivision_pitch_tournament_holdout_adverse_v3.wav": adverse * .87 / peak,
    }
    hashes = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    step = round(TRUTH_STEP * RATE)
    manifest = {
        "schema": "klarivision-pitch-tournament-holdout-v3",
        "policy": "frozen-no-retuning-after-first-result",
        "sample_rate_hz": RATE,
        "truth_step_seconds": TRUTH_STEP,
        "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED,
        "variants": list(variants),
        "variant_conditions": {name: {"silence_guard_seconds": .150 if "clean" not in name else .016} for name in variants},
        "sha256": hashes,
        "sections": sections,
        "ground_truth": [
            {"time_seconds": round(index / RATE, 6), "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None}
            for index in range(0, len(truth), step)
        ],
    }
    (output / "klarivision_pitch_tournament_holdout_ground_truth_v3.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


if __name__ == "__main__":
    write_holdout()
