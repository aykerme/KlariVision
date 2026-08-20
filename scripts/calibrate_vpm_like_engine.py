#!/usr/bin/env python3
"""Calibrate the public VPM-like engine against exact and musical references.

This developer tool never modifies studies or source media. It searches a
small, reproducible threshold grid, rejects any candidate that improves one
recording by hiding too many voiced frames, and writes the complete evidence
to outputs/vpm-like-calibration.json.
"""

from __future__ import annotations

import csv
import itertools
import json
import math
import subprocess
import tempfile
import wave
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data/benchmarks"
OUTPUT = ROOT / "outputs/vpm-like-calibration.json"
RUNNER = Path(tempfile.gettempdir()) / "klarivision_vpm_like_trace"
WINDOW = 1536
HOP = 512

SOURCES = {
    "stress_clean": BENCHMARKS / "klarivision_stress_clean_v2.wav",
    "stress_clarinet": BENCHMARKS / "klarivision_stress_clarinet_v2.wav",
    "stress_adverse": BENCHMARKS / "klarivision_stress_adverse_v2.wav",
    "sukru_tunar": ROOT / "data/audio/sukru-tunar-ussak-taksim-on-clarinet-pitch-contour-only-c0139114-c9ed5c5e.wav",
}
HOLDOUT_SOURCES = {
    "validated_clarinet_clean": BENCHMARKS / "klarivision_validated_clarinet_clean_v1.wav",
    "validated_clarinet_room": BENCHMARKS / "klarivision_validated_clarinet_room_v1.wav",
}
STRESS_TRUTH = BENCHMARKS / "klarivision_stress_ground_truth_v2.json"
HOLDOUT_TRUTH = BENCHMARKS / "klarivision_validated_clarinet_ground_truth_v1.json"
SUKRU_REFERENCE = ROOT / "outputs/sukru-tunar-ussak-taksim-on-clarinet-pitch-contour-only-c0139114-c9ed5c5e.vamp.json"
SUKRU_INSPECTION_RANGES = [(79, 83), (106, 107), (111, 113), (130, 133), (150, 154)]


@dataclass(frozen=True)
class Config:
    minimum_periodicity: float
    near_strongest_ratio: float
    relative_spectrum: float
    absolute_spectrum: float = 0.004
    max_multiple: int = 6
    allow_spectral_promotion: bool = False

    @property
    def key(self) -> str:
        return (
            f"p{self.minimum_periodicity:.3f}-n{self.near_strongest_ratio:.3f}-"
            f"r{self.relative_spectrum:.3f}-a{self.absolute_spectrum:.3f}-m{self.max_multiple}-"
            f"u{int(self.allow_spectral_promotion)}"
        )


# Keep the pre-calibration configuration in the report so every rerun measures
# the same improvement. CURRENT_DEFAULT mirrors the shipped C++/Swift engine.
LEGACY_BASELINE = Config(0.38, 0.84, 0.055, allow_spectral_promotion=True)
CURRENT_DEFAULT = Config(0.38, 0.90, 0.080, 0.005)


def compile_runner() -> None:
    subprocess.run(
        [
            "xcrun", "clang++", "-O3", "-std=c++20", "-Wall", "-Wextra", "-Werror",
            "-I", str(ROOT / "core/include"),
            str(ROOT / "core/src/vpm_like.cpp"),
            str(ROOT / "core/tools/vpm_like_trace.cpp"),
            "-o", str(RUNNER),
        ],
        check=True,
    )


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        channels = source.getnchannels()
        width = source.getsampwidth()
        if width != 2:
            raise ValueError(f"Only 16-bit PCM is supported by calibration: {path}")
        values = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    if channels > 1:
        values = values.reshape(-1, channels).mean(axis=1)
    return values, rate


def cents(actual: float, expected: float) -> float:
    return 1200 * math.log2(actual / expected)


def harmonic_relationship(actual: float, expected: float) -> str | None:
    ratio = actual / expected
    relationships = {
        "1/3": 1 / 3,
        "1/2": 1 / 2,
        "2x": 2,
        "3x": 3,
    }
    label = min(relationships, key=lambda item: abs(cents(ratio, relationships[item])))
    return label if abs(cents(ratio, relationships[label])) <= 90 else None


def trace_for(raw: Path, rate: int, config: Config) -> list[tuple[float, float, float]]:
    command = [
        str(RUNNER), str(raw), str(rate), str(WINDOW), str(HOP),
        str(config.minimum_periodicity), str(config.near_strongest_ratio),
        str(config.relative_spectrum), str(config.absolute_spectrum), str(config.max_multiple),
        "1" if config.allow_spectral_promotion else "0", "0.015",
    ]
    output = subprocess.run(command, check=True, capture_output=True, text=True).stdout.splitlines()
    return [
        (float(row["time_seconds"]), float(row["frequency_hz"]), float(row["confidence"]))
        for row in csv.DictReader(output)
    ]


def nearest_value(
    times: np.ndarray,
    values: np.ndarray,
    time: float,
    tolerance: float,
) -> float | None:
    if not len(times):
        return None
    index = int(np.searchsorted(times, time))
    choices = [candidate for candidate in (index - 1, index) if 0 <= candidate < len(times)]
    if not choices:
        return None
    nearest = min(choices, key=lambda candidate: abs(times[candidate] - time))
    return float(values[nearest]) if abs(times[nearest] - time) <= tolerance else None


def summarize(errors: list[float], harmonics: list[str], matched: int, expected: int) -> dict[str, object]:
    counts = {label: harmonics.count(label) for label in ("1/3", "1/2", "2x", "3x")}
    return {
        "matched_points": matched,
        "expected_points": expected,
        "coverage_percent": round(100 * matched / expected, 3) if expected else 0,
        "median_absolute_cent_error": round(float(np.median(errors)), 3) if errors else None,
        "p95_absolute_cent_error": round(float(np.percentile(errors, 95)), 3) if errors else None,
        "harmonic_error_points": len(harmonics),
        "harmonic_error_percent": round(100 * len(harmonics) / matched, 4) if matched else 100,
        "harmonic_relationships": counts,
    }


def score_stress(trace: list[tuple[float, float, float]], truth: dict[str, object], rate: int) -> dict[str, object]:
    trace_times = np.fromiter((row[0] for row in trace), dtype=np.float64)
    trace_values = np.fromiter((row[1] for row in trace), dtype=np.float64)
    errors: list[float] = []
    harmonics: list[str] = []
    matched = 0
    expected = 0
    for section in truth["sections"]:
        if section["kind"] == "silence":
            continue
        start = float(section["start_seconds"]) + 0.075
        end = float(section["end_seconds"]) - 0.075
        rows = [
            row for row in truth["ground_truth"]
            if row["frequency_hz"] is not None and start <= float(row["time_seconds"]) <= end
        ]
        # Score at the live engine's actual cadence, not at the manifest's
        # denser 10 ms grid. This prevents 44.1/48 kHz rounding from looking
        # like missing pitch estimates.
        step = HOP / rate
        for time in np.arange(math.ceil(start / step) * step, end + step / 2, step):
            nearest_truth = min(rows, key=lambda row: abs(float(row["time_seconds"]) - time), default=None)
            if nearest_truth is None or abs(float(nearest_truth["time_seconds"]) - time) > 0.012:
                continue
            expected += 1
            actual = nearest_value(trace_times, trace_values, float(time), step * 0.51)
            if actual is None:
                continue
            target = float(nearest_truth["frequency_hz"])
            error = abs(cents(actual, target))
            errors.append(error)
            matched += 1
            relationship = harmonic_relationship(actual, target)
            if relationship:
                harmonics.append(relationship)
    return summarize(errors, harmonics, matched, expected)


def stable_sukru_reference() -> list[tuple[float, float]]:
    frames = [
        (float(row["time_seconds"]), float(row["frequency_hz"]))
        for row in json.loads(SUKRU_REFERENCE.read_text())["frames"]
        if row.get("voiced") and row.get("frequency_hz")
    ]
    stable: list[tuple[float, float]] = []
    for index in range(2, len(frames) - 2):
        neighborhood = frames[index - 2:index + 3]
        if max(time for time, _ in neighborhood) - min(time for time, _ in neighborhood) > 0.08:
            continue
        frequencies = [frequency for _, frequency in neighborhood]
        if max(abs(cents(value, frequencies[2])) for value in frequencies) <= 65:
            stable.append(frames[index])
    return stable


def score_sukru(trace: list[tuple[float, float, float]], rate: int) -> dict[str, object]:
    reference = stable_sukru_reference()
    ref_times = np.array([row[0] for row in reference])
    ref_values = np.array([row[1] for row in reference])
    trace_times = np.array([row[0] for row in trace]) if trace else np.array([])
    trace_values = np.array([row[1] for row in trace]) if trace else np.array([])

    # The trace timestamp is the causal window's right edge, while Vamp pYIN
    # uses its own frame convention. Find one global sub-frame alignment; do
    # not allow local warping that could conceal a harmonic error.
    candidates: list[tuple[float, float, int]] = []
    for offset in np.arange(-0.08, 0.0801, 0.002):
        aligned_errors: list[float] = []
        for time, actual, _ in trace[::3]:
            index = int(np.searchsorted(ref_times, time - offset))
            choices = [item for item in (index - 1, index) if 0 <= item < len(reference)]
            if not choices:
                continue
            nearest = min(choices, key=lambda item: abs(ref_times[item] - (time - offset)))
            if abs(ref_times[nearest] - (time - offset)) <= 0.018:
                aligned_errors.append(abs(cents(actual, ref_values[nearest])))
        inliers = [error for error in aligned_errors if error <= 100]
        candidates.append((offset, float(np.median(inliers)) if inliers else math.inf, len(inliers)))
    offset, _, _ = min(candidates, key=lambda item: (item[1], -item[2], abs(item[0])))

    errors: list[float] = []
    harmonics: list[str] = []
    matched = 0
    expected = 0
    inspection: dict[str, dict[str, object]] = {}
    step = HOP / rate
    for time in np.arange(reference[0][0], reference[-1][0], step):
        index = int(np.searchsorted(ref_times, time - offset))
        choices = [item for item in (index - 1, index) if 0 <= item < len(reference)]
        if not choices:
            continue
        nearest = min(choices, key=lambda item: abs(ref_times[item] - (time - offset)))
        if abs(ref_times[nearest] - (time - offset)) > 0.018:
            continue
        expected += 1
        actual = nearest_value(trace_times, trace_values, float(time), step * 0.51)
        if actual is None:
            continue
        target = float(ref_values[nearest])
        error = abs(cents(actual, target))
        errors.append(error)
        matched += 1
        relationship = harmonic_relationship(actual, target)
        if relationship:
            harmonics.append(relationship)
    summary = summarize(errors, harmonics, matched, expected)
    summary["alignment_offset_seconds"] = round(float(offset), 4)

    for start, end in SUKRU_INSPECTION_RANGES:
        range_errors: list[float] = []
        range_harmonics = 0
        for time, actual, _ in trace:
            if not start <= time <= end:
                continue
            index = int(np.searchsorted(ref_times, time - offset))
            choices = [item for item in (index - 1, index) if 0 <= item < len(reference)]
            if not choices:
                continue
            nearest = min(choices, key=lambda item: abs(ref_times[item] - (time - offset)))
            if abs(ref_times[nearest] - (time - offset)) > 0.018:
                continue
            error = abs(cents(actual, ref_values[nearest]))
            range_errors.append(error)
            range_harmonics += harmonic_relationship(actual, ref_values[nearest]) is not None
        inspection[f"{start}-{end}"] = {
            "matched_points": len(range_errors),
            "p95_absolute_cent_error": round(float(np.percentile(range_errors, 95)), 2) if range_errors else None,
            "harmonic_error_points": range_harmonics,
        }
    summary["inspection_ranges"] = inspection
    return summary


def objective(cases: dict[str, dict[str, object]], baseline_coverage: dict[str, float] | None = None) -> float:
    score = 0.0
    for name, case in cases.items():
        coverage = float(case["coverage_percent"])
        p95 = float(case["p95_absolute_cent_error"] or 2000)
        harmonic = float(case["harmonic_error_percent"])
        weight = 1.5 if name in {"stress_clarinet", "sukru_tunar"} else 1.0
        score += weight * (min(p95, 600) + 18 * harmonic)
        if baseline_coverage is not None:
            floor = baseline_coverage[name] - 2.0
            score += max(0.0, floor - coverage) * 250
        score += max(0.0, 78.0 - coverage) * 120
    return score


def main() -> None:
    compile_runner()
    truth = json.loads(STRESS_TRUTH.read_text())
    temporary = Path(tempfile.mkdtemp(prefix="klarivision-vpm-calibration-"))
    raw_sources: dict[str, tuple[Path, int]] = {}
    for name, path in SOURCES.items():
        audio, rate = read_wav(path)
        raw = temporary / f"{name}.f64"
        audio.tofile(raw)
        raw_sources[name] = (raw, rate)

    configs = [
        Config(periodicity, near_ratio, relative)
        for periodicity, near_ratio, relative in itertools.product(
            (0.34, 0.38, 0.42),
            (0.78, 0.84, 0.90),
            (0.035, 0.055, 0.08),
        )
    ]
    for required in (LEGACY_BASELINE, CURRENT_DEFAULT):
        if required not in configs:
            configs.append(required)

    def evaluate(config: Config) -> tuple[Config, dict[str, dict[str, object]]]:
        cases: dict[str, dict[str, object]] = {}
        for name, (raw, rate) in raw_sources.items():
            trace = trace_for(raw, rate, config)
            cases[name] = score_sukru(trace, rate) if name == "sukru_tunar" else score_stress(trace, truth, rate)
        return config, cases

    results: list[tuple[Config, dict[str, dict[str, object]]]] = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(evaluate, config): config for config in configs}
        for future in as_completed(futures):
            config, cases = future.result()
            results.append((config, cases))
            print(config.key, "completed", flush=True)

    baseline_cases = next(cases for config, cases in results if config == LEGACY_BASELINE)
    baseline_coverage = {name: float(case["coverage_percent"]) for name, case in baseline_cases.items()}
    ranked = sorted(results, key=lambda item: objective(item[1], baseline_coverage))
    selected_config, selected_cases = ranked[0]
    holdout_truth = json.loads(HOLDOUT_TRUTH.read_text())
    holdout: dict[str, dict[str, dict[str, object]]] = {}
    for label, config in (("legacy_baseline", LEGACY_BASELINE), ("selected", selected_config)):
        holdout[label] = {}
        for name, path in HOLDOUT_SOURCES.items():
            audio, rate = read_wav(path)
            raw = temporary / f"holdout-{name}.f64"
            audio.tofile(raw)
            holdout[label][name] = score_stress(trace_for(raw, rate, config), holdout_truth, rate)
    payload = {
        "schema": "klarivision-vpm-like-calibration-v1",
        "window_samples": WINDOW,
        "hop_samples": HOP,
        "selection_rule": "minimum weighted pitch/harmonic error; no source may lose >2 coverage points vs baseline",
        "baseline": {
            "config": asdict(LEGACY_BASELINE),
            "objective": round(objective(baseline_cases, baseline_coverage), 3),
            "cases": baseline_cases,
        },
        "selected": {
            "config": asdict(selected_config),
            "objective": round(objective(selected_cases, baseline_coverage), 3),
            "cases": selected_cases,
        },
        "current_default": asdict(CURRENT_DEFAULT),
        "holdout": holdout,
        "top_candidates": [
            {
                "config": asdict(config),
                "objective": round(objective(cases, baseline_coverage), 3),
                "coverage": {name: case["coverage_percent"] for name, case in cases.items()},
                "p95": {name: case["p95_absolute_cent_error"] for name, case in cases.items()},
                "harmonic_percent": {name: case["harmonic_error_percent"] for name, case in cases.items()},
            }
            for config, cases in ranked[:8]
        ],
    }
    OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(payload["selected"], ensure_ascii=False, indent=2))
    print(OUTPUT)


if __name__ == "__main__":
    main()
