#!/usr/bin/env python3
"""Score KlariVision's causal live engine against stress-suite ground truth."""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np

from run_pitch_regression_suite import causal_yin_frames
from pitch_error_metrics import ObservedFrame, ReferenceFrame, score_frames


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data" / "benchmarks"
MANIFEST = BENCHMARKS / "klarivision_stress_ground_truth_v2.json"
OUTPUT = ROOT / "outputs" / "pitch-stress-suite-v2-results.json"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    return samples, rate


def cents(actual: float, expected: float) -> float:
    return 1200 * math.log2(actual / expected)


HARMONIC_CENT_DISTANCES = [1200 * math.log2(order) for order in range(2, 8)]


def is_harmonic_error(error: float) -> bool:
    return min(abs(error - distance) for distance in HARMONIC_CENT_DISTANCES) <= 90


def error_ranges(items: list[tuple[float, float]]) -> list[dict[str, float | int]]:
    ranges: list[dict[str, float | int]] = []
    active: dict[str, float | int] | None = None
    for time, error in items:
        if error < 100:
            continue
        if active is not None and time - float(active["end_seconds"]) <= 0.05:
            active["end_seconds"] = time
            active["peak_cents"] = max(float(active["peak_cents"]), error)
            active["points"] = int(active["points"]) + 1
        else:
            if active is not None:
                ranges.append(active)
            active = {"start_seconds": time, "end_seconds": time, "peak_cents": error, "points": 1}
    if active is not None:
        ranges.append(active)
    return ranges


def score_variant(path: Path, manifest: dict[str, object]) -> dict[str, object]:
    audio, rate = read_wav(path)
    live = causal_yin_frames(audio, rate)
    summary = score_frames(
        [ReferenceFrame(float(row["time_seconds"]), row["frequency_hz"]) for row in manifest["ground_truth"]],
        [ObservedFrame(time, frequency) for time, frequency in live],
        tolerance_seconds=0.55 * 512 / rate,
    )
    section_results = []
    for section in manifest["sections"]:
        start = float(section["start_seconds"])
        finish = float(section["end_seconds"])
        truth_rows = [
            row for row in manifest["ground_truth"] if start <= float(row["time_seconds"]) <= finish
        ]
        section_summary = score_frames(
            [ReferenceFrame(float(row["time_seconds"]), row["frequency_hz"]) for row in truth_rows],
            [ObservedFrame(time, frequency) for time, frequency in live],
            tolerance_seconds=0.55 * 512 / rate,
        )
        section_results.append({
            "label": section["label"],
            "kind": section["kind"],
            **section_summary,
        })
    return {
        "source": str(path.relative_to(ROOT)),
        **summary,
        "status": "geçti" if int(summary["total_error_frames"]) == 0 else "incelenecek",
        "sections": section_results,
    }


def main() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    results = [score_variant(BENCHMARKS / filename, manifest) for filename in manifest["variants"]]
    payload = {"schema": "klarivision-pitch-stress-results-v3", "cases": results}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for result in results:
        print(
            f"{result['status']:12s} {Path(result['source']).name:40s} "
            f"errors={result['total_error_frames']:4d} correct={result['correct_pitch_frames']:4d} "
            f"correct_mean={result['correct_pitch_mean_absolute_cents']}"
        )
    print(OUTPUT)


if __name__ == "__main__":
    main()
