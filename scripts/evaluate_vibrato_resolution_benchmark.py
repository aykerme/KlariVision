#!/usr/bin/env python3
"""Evaluate live pitch JSON against the known synthetic test signal.

Unlike pYIN, this report uses the exact frequency function that created the
benchmark WAV.  It is therefore the authoritative score for this synthetic
test fixture.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "data" / "benchmarks" / "vibrato_cozunurluk_referans_v1.json"


def cents(actual: float, expected: float) -> float:
    return 1200 * math.log2(actual / expected)


def expected_frequency(label: str, local_time: float, duration: float) -> float:
    if label == "A3_sabit":
        return 220.0
    if label.startswith("A3_vibrato_"):
        if label == "A3_vibrato_dar":
            width, rate = 10.0, 5.5
        elif label == "A3_vibrato_genis":
            width, rate = 60.0, 5.5
        else:
            rate = float(label.removeprefix("A3_vibrato_").removesuffix("Hz").replace("_", "."))
            width = 35.0
        return 220.0 * 2 ** (width * math.sin(2 * math.pi * rate * local_time) / 1200)
    if label == "A3_C4_glissando":
        return 220.0 * 2 ** (math.log2(261.625565 / 220.0) * local_time / duration)
    if label == "G3_yukari_carpma":
        return 220.0 if local_time < 0.070 else 195.997718
    raise KeyError(label)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("live_json", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "outputs" / "vibrato-canli-motor-dogrulama-v1.json")
    args = parser.parse_args()

    payload = json.loads(args.live_json.read_text(encoding="utf-8"))
    frames = payload["frames"]
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    sections = []

    for section in manifest["sections"]:
        label = section["label"]
        start, end = section["start_seconds"], section["end_seconds"]
        # Ignore attack/fade boundaries: they intentionally do not represent
        # the steady frequency formula.
        margin = min(0.12, (end - start) / 4)
        selected = [frame for frame in frames if start + margin <= frame["time_seconds"] <= end - margin]
        if not selected:
            continue
        expected = np.array([expected_frequency(label, f["time_seconds"] - start, end - start) for f in selected])
        observed = np.array([f["frequency_hz"] for f in selected])
        errors = np.abs(1200 * np.log2(observed / expected))
        observed_cents = 1200 * np.log2(observed / 220.0)
        expected_cents = 1200 * np.log2(expected / 220.0)
        sections.append({
            "label": label,
            "frames": len(selected),
            "point_rate_hz": round(len(selected) / max(0.001, end - start - 2 * margin), 2),
            "median_absolute_cent_error": round(float(np.median(errors)), 2),
            "p95_absolute_cent_error": round(float(np.percentile(errors, 95)), 2),
            "observed_p5_p95_span_cents": round(float(np.percentile(observed_cents, 95) - np.percentile(observed_cents, 5)), 2),
            "expected_p5_p95_span_cents": round(float(np.percentile(expected_cents, 95) - np.percentile(expected_cents, 5)), 2),
        })

    first, last = frames[0]["time_seconds"], frames[-1]["time_seconds"]
    report = {
        "schema": "klarivision-vibrato-resolution-report-v1",
        "source": payload.get("source_name"),
        "frames": len(frames),
        "overall_point_rate_hz": round(len(frames) / max(0.001, last - first), 2),
        "reference": "Mathematical pitch function used to synthesize the WAV; no pYIN data is used.",
        "sections": sections,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
