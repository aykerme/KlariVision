#!/usr/bin/env python3
"""Validate pYIN first, then score the causal live engine against truth."""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import librosa
import numpy as np

from run_pitch_regression_suite import HOP, PYIN_WINDOW, causal_yin_frames
from pitch_error_metrics import ObservedFrame, ReferenceFrame, score_frames


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data" / "benchmarks"
MANIFEST = BENCHMARKS / "klarivision_validated_clarinet_ground_truth_v1.json"
OUTPUT = ROOT / "outputs" / "validated-clarinet-reference-v1-results.json"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    return samples, rate


def cents(actual: float, expected: float) -> float:
    return 1200 * math.log2(actual / expected)


def pyin_frames(audio: np.ndarray, rate: int) -> list[tuple[float, float]]:
    f0, voiced, _ = librosa.pyin(
        audio.astype(np.float32), fmin=80, fmax=1500, sr=rate,
        frame_length=PYIN_WINDOW, hop_length=HOP, resolution=0.05,
        center=False, fill_na=np.nan,
    )
    return [
        ((index * HOP + PYIN_WINDOW / 2) / rate, float(frequency))
        for index, (frequency, is_voiced) in enumerate(zip(f0, voiced))
        if is_voiced and frequency is not None and np.isfinite(frequency)
    ]


def score(frames: list[tuple[float, float]], truth: list[dict[str, object]]) -> dict[str, object]:
    return score_frames(
        [ReferenceFrame(float(row["time_seconds"]), row["frequency_hz"]) for row in truth],
        [ObservedFrame(time, frequency) for time, frequency in frames],
        tolerance_seconds=0.55 * HOP / 48_000,
    )


def passes(result: dict[str, object], *, reference: bool) -> bool:
    return int(result["total_error_frames"]) == 0 and (result["correct_pitch_mean_absolute_cents"] or math.inf) <= 50


def main() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    cases = []
    for filename in manifest["variants"]:
        path = BENCHMARKS / filename
        audio, rate = read_wav(path)
        pyin = score(pyin_frames(audio, rate), manifest["ground_truth"])
        # The generated target curve is the authority. pYIN is retained only
        # as a diagnostic third trace; it must never veto or certify the live
        # engine when the exact synthesis frequency is already known.
        eligible = passes(pyin, reference=True)
        live = score(causal_yin_frames(audio, rate), manifest["ground_truth"])
        status = "geçti" if passes(live, reference=False) else "incelenecek"
        cases.append({
            "source": str(path.relative_to(ROOT)),
            "reference_mode": "analytic_ground_truth",
            "pyin_reference_eligible": eligible,
            "pyin_vs_ground_truth": pyin,
            "live_vs_ground_truth": live,
            "status": status,
        })
    payload = {"schema": "klarivision-validated-reference-results-v2", "cases": cases}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for case in cases:
        print(case["status"], Path(case["source"]).name)
        print("  pYIN", case["pyin_vs_ground_truth"])
        print("  live", case["live_vs_ground_truth"])
    print(OUTPUT)


if __name__ == "__main__":
    main()
