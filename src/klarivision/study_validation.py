"""Synthetic ground-truth support for the production Study viewer.

This module deliberately operates on the JSON emitted by ``offline_track_v1``.
It is therefore a check of the path the user sees, rather than of a separate
live-engine benchmark adapter.
"""

from __future__ import annotations

import bisect
import json
import math
import re
import wave
from pathlib import Path
from typing import Iterable

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
BENCHMARKS = ROOT / "data" / "benchmarks"
HOLDOUTS = ROOT / "data" / "holdouts"
TRUTH_STEP_SECONDS = 0.01
WINDOW_SAMPLES = 1536
HOP_SAMPLES = 512
MINIMUM_RMS = 0.015


def _formula_frequency(formula: str, local_time: float) -> float:
    constant = re.fullmatch(r"([0-9.]+) Hz", formula)
    if constant:
        return float(constant.group(1))
    detuned = re.fullmatch(r"([0-9.]+) \* 2\^\((-?[0-9.]+)/1200\)", formula)
    if detuned:
        return float(detuned.group(1)) * 2 ** (float(detuned.group(2)) / 1200)
    vibrato = re.fullmatch(r"([0-9.]+) \* 2\^\(([0-9.]+)\*sin\(2π\*([0-9.]+)t\)/1200\)", formula)
    if vibrato:
        base, cents, rate = (float(value) for value in vibrato.groups())
        return base * 2 ** (cents * math.sin(2 * math.pi * rate * local_time) / 1200)
    glide = re.fullmatch(r"([0-9.]+) \* 2\^\(log2\(([0-9.]+)/([0-9.]+)\)\*t/([0-9.]+)\)", formula)
    if glide:
        start, end, denominator, seconds = (float(value) for value in glide.groups())
        if not math.isclose(start, denominator, abs_tol=1e-6):
            raise ValueError(f"Unexpected glide denominator: {formula}")
        return start * (end / start) ** (local_time / seconds)
    grace = re.fullmatch(r"0–([0-9.]+) ms: ([0-9.]+) Hz; sonra ([0-9.]+) Hz", formula)
    if grace:
        milliseconds, grace_hz, target_hz = (float(value) for value in grace.groups())
        return grace_hz if local_time < milliseconds / 1_000 else target_hz
    raise ValueError(f"Unsupported legacy fixture formula: {formula}")


def _legacy_truth(manifest: dict[str, object]) -> list[dict[str, float | None]]:
    sections = list(manifest["sections"])
    duration = float(manifest.get("duration_seconds", max(float(item["end_seconds"]) for item in sections)))
    full_range = manifest.get("schema") == "klarivision-full-range-pitch-benchmark-v1"
    truth: list[dict[str, float | None]] = []
    for index in range(round(duration / TRUTH_STEP_SECONDS)):
        time = round(index * TRUTH_STEP_SECONDS, 6)
        section = next((item for item in sections if float(item["start_seconds"]) <= time < float(item["end_seconds"])), None)
        frequency: float | None = None
        if section:
            local_time = time - float(section["start_seconds"])
            if full_range and "frequency_hz" in section:
                frequency = float(section["frequency_hz"]) * 2 ** (float(section.get("vibrato_cents", 0)) * math.sin(2 * math.pi * 4 * local_time) / 1200)
            elif full_range and section.get("type") == "logarithmic_glide":
                length = float(section["end_seconds"]) - float(section["start_seconds"])
                frequency = float(section["start_frequency_hz"]) * (float(section["end_frequency_hz"]) / float(section["start_frequency_hz"])) ** (local_time / length)
            else:
                frequency = _formula_frequency(str(section["frequency_formula"]), local_time)
        truth.append({"time_seconds": time, "frequency_hz": round(frequency, 6) if frequency else None})
    return truth


def _source_stem(name: str) -> str:
    # Study imports add a source-content signature. Keep ordinary benchmark
    # hyphens intact and remove only the terminal 8–16 digit digest.
    return re.sub(r"-[0-9a-f]{8,16}$", "", Path(name).stem.lower())


def _manifest_for(source_name: str) -> tuple[dict[str, object], str] | None:
    wanted = _source_stem(source_name) + ".wav"
    legacy = {
        "canli_pitch_referans_v1.json", "clarinet_full_range_pitch_benchmark_v1.json",
        "vibrato_cozunurluk_referans_v1.json", "vibrato_klarnet_harmonik_v1.json",
        "vibrato_klarnet_hafif_gurultu_v1.json", "vibrato_klarnet_orta_gurultu_v1.json",
    }
    manifests = [*BENCHMARKS.glob("*.json"), *HOLDOUTS.glob("**/*.json")]
    for path in sorted(manifests):
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        variants = manifest.get("variants", [])
        if path.name in legacy and wanted == path.with_suffix(".wav").name:
            return manifest | {"ground_truth": _legacy_truth(manifest)}, path.name
        if wanted in variants:
            return manifest, path.name
    return None


def _effective_truth(truth: Iterable[dict[str, float | None]], wav: Path) -> list[dict[str, float | None]]:
    with wave.open(str(wav), "rb") as source:
        if source.getsampwidth() != 2:
            return list(truth)
        rate = source.getframerate()
        channels = source.getnchannels()
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    result = []
    half = WINDOW_SAMPLES // 2
    for row in truth:
        copied = dict(row)
        if copied["frequency_hz"] is not None:
            centre = int(round(float(copied["time_seconds"]) * rate))
            window = samples[max(0, centre - half):min(len(samples), centre - half + WINDOW_SAMPLES)]
            if len(window):
                centered = window - float(np.mean(window))
                if float(np.sqrt(np.mean(centered * centered))) < MINIMUM_RMS:
                    copied["frequency_hz"] = None
        result.append(copied)
    return result


def _score(truth: list[dict[str, float | None]], observed: list[dict[str, float]], transitions: Iterable[float], rate: int) -> dict[str, object]:
    tolerance = HOP_SAMPLES / rate * .55
    times = [point["time_seconds"] for point in observed]
    used: set[int] = set()
    counts = {key: 0 for key in ("reference_voiced_frames", "reference_silent_frames", "correct_silent_frames", "false_voiced_frames", "missing_voiced_frames", "correct_pitch_frames", "harmonic_error_frames", "non_harmonic_error_frames")}
    errors: list[dict[str, object]] = []
    for target in truth:
        time = float(target["time_seconds"])
        at = bisect.bisect_left(times, time)
        candidates = [i for i in range(max(0, at - 2), min(len(observed), at + 3)) if i not in used and abs(float(observed[i]["time_seconds"]) - time) <= tolerance]
        match = min(candidates, key=lambda i: abs(float(observed[i]["time_seconds"]) - time), default=None)
        if match is not None:
            used.add(match)
        actual = observed[match] if match is not None else None
        if target["frequency_hz"] is None:
            counts["reference_silent_frames"] += 1
            if actual is None: counts["correct_silent_frames"] += 1
            else:
                counts["false_voiced_frames"] += 1; errors.append({"kind": "false_voiced", "time_seconds": time})
        else:
            counts["reference_voiced_frames"] += 1
            if actual is None:
                counts["missing_voiced_frames"] += 1; errors.append({"kind": "missing_voiced", "time_seconds": time})
            else:
                cents = 1200 * math.log2(float(actual["frequency_hz"]) / float(target["frequency_hz"]))
                if abs(cents) <= 50: counts["correct_pitch_frames"] += 1
                elif min(abs(cents - candidate) for candidate in (-1901.955, -1200.0, 1200.0, 1901.955)) <= 90:
                    counts["harmonic_error_frames"] += 1; errors.append({"kind": "harmonic_error", "time_seconds": time})
                else:
                    counts["non_harmonic_error_frames"] += 1; errors.append({"kind": "non_harmonic_error", "time_seconds": time})
    serious_ranges = []
    transition_set = list(transitions)
    for kind in ("false_voiced", "missing_voiced", "harmonic_error", "non_harmonic_error"):
        run: list[dict[str, object]] = []
        for error in [item for item in errors if item["kind"] == kind and not any(abs(float(item["time_seconds"]) - boundary) <= .03 for boundary in transition_set)]:
            if run and float(error["time_seconds"]) - float(run[-1]["time_seconds"]) > .015:
                if len(run) >= 3: serious_ranges.append({"kind": kind, "start_seconds": run[0]["time_seconds"], "end_seconds": run[-1]["time_seconds"], "frames": len(run)})
                run = []
            run.append(error)
        if len(run) >= 3: serious_ranges.append({"kind": kind, "start_seconds": run[0]["time_seconds"], "end_seconds": run[-1]["time_seconds"], "frames": len(run)})
    counts["total_error_frames"] = sum(counts[key] for key in ("false_voiced_frames", "missing_voiced_frames", "harmonic_error_frames", "non_harmonic_error_frames"))
    counts["serious_total_error_frames"] = sum(int(item["frames"]) for item in serious_ranges)
    return counts | {"serious_error_ranges": serious_ranges}


def validation_for_study(source_name: str, wav: Path, pitch_json: Path, engine: str, prepare_display_frames) -> dict[str, object] | None:
    """Return viewer-safe validation data, or ``None`` for user recordings."""
    resolved = _manifest_for(source_name)
    if resolved is None:
        return None
    manifest, manifest_name = resolved
    truth = _effective_truth(list(manifest["ground_truth"]), wav)
    payload = json.loads(pitch_json.read_text(encoding="utf-8"))
    raw = [{"time_seconds": float(item["time_seconds"]), "frequency_hz": float(item["frequency_hz"])} for item in payload.get("frames", []) if item.get("voiced") and item.get("frequency_hz")]
    display = [{"time_seconds": point["t"], "frequency_hz": point["hz"]} for point in prepare_display_frames(payload)]
    causal = [{"time_seconds": float(item["time_seconds"]), "frequency_hz": float(item["frequency_hz"])} for item in payload.get("causal_baseline", []) if item.get("voiced") and item.get("frequency_hz")]
    transitions = [float(section[edge]) for section in manifest.get("sections", []) for edge in ("start_seconds", "end_seconds")]
    rate = 48_000
    return {
        "schema": "klarivision-study-synthetic-validation-v1", "engine": engine, "profile": "offline_track_v1", "manifest": manifest_name,
        "reference_frames": [{"t": row["time_seconds"], "hz": row["frequency_hz"]} for row in truth if row["frequency_hz"] is not None],
        "causal_baseline": _score(truth, causal, transitions, rate),
        "raw": _score(truth, raw, transitions, rate), "display": _score(truth, display, transitions, rate),
        "offline_changes": payload.get("offline_changes", []),
    }
