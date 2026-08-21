#!/usr/bin/env python3
"""Generate the frozen acceptance holdout for the shared production session."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

from generate_pitch_tournament_holdout_v1 import RATE, TRUTH_STEP, Holdout, add_interference, room_variant
from generate_pitch_tournament_holdout_v2 import constant, glide, vibrato


DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "data" / "holdouts" / "v6"
SEED = 20260812


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = Holdout()
    # Frequencies and durations are intentionally new. The suite combines the
    # middle-register f/2 ambiguity, high-register entries, releases and short
    # returning gaps that motivated the shared-session architecture.
    for frequency, seconds in ((293.4, .67), (438.7, .83), (587.9, .56), (996.8, .71), (1294.3, .49)):
        suite.add(f"accept6_anchor_{frequency:.1f}", constant(frequency, seconds), kind="shared_anchor")
        suite.silence(.057)
    suite.add("accept6_mid_rise", glide(246.8, 624.1, 1.63, .88), kind="mid_curved_glide")
    suite.silence(.076)
    suite.add("accept6_high_fall", glide(1418.6, 531.7, 1.79, 1.09), kind="high_curved_glide")
    suite.silence(.044)
    suite.add("accept6_vibrato", vibrato(739.6, 1.31, 7.7, 31.0), kind="shared_vibrato",
              harmonics=(.41, .58, .19, .13, .08, .05))
    suite.silence(.103)
    returning = glide(352.6, 901.3, 1.71, .74)
    split = round(.86 * RATE)
    suite.add("accept6_gap_a", returning[:split], kind="returning_gap")
    suite.silence(.038)
    suite.add("accept6_gap_b", returning[split:], kind="returning_gap")
    suite.silence(.14)
    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_holdout(output: Path = DEFAULT_OUTPUT) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()
    room = room_variant(clean, np.random.default_rng(SEED), 17.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 9.5))
    peak = max(float(np.max(np.abs(clean))), float(np.max(np.abs(room))), float(np.max(np.abs(adverse))), 1e-12)
    variants = {
        f"klarivision_pitch_tournament_holdout_{condition}_v6.wav": samples * .87 / peak
        for condition, samples in (("clean", clean), ("room", room), ("adverse", adverse))
    }
    hashes: dict[str, str] = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    step = round(TRUTH_STEP * RATE)
    manifest = {
        "schema": "klarivision-pitch-tournament-holdout-v6",
        "policy": "frozen-no-retuning-after-first-result",
        "purpose": "shared-production-session-final-acceptance",
        "sample_rate_hz": RATE,
        "truth_step_seconds": TRUTH_STEP,
        "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED,
        "variants": list(variants),
        "variant_conditions": {
            name: {"silence_guard_seconds": .016 if "clean" in name else .150}
            for name in variants
        },
        "sha256": hashes,
        "sections": sections,
        "ground_truth": [
            {
                "time_seconds": round(index / RATE, 6),
                "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None,
            }
            for index in range(0, len(truth), step)
        ],
    }
    (output / "klarivision_pitch_tournament_holdout_ground_truth_v6.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


if __name__ == "__main__":
    write_holdout()
