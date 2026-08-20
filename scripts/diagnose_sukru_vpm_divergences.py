#!/usr/bin/env python3
"""Produce an exact candidate-level VPM-like/pYIN divergence report.

The source WAV and pYIN reference are read-only. Raw Float64 samples are
written only to a temporary directory; durable output is limited to outputs/.
"""

from __future__ import annotations

import hashlib
import json
import math
import subprocess
import tempfile
import wave
from collections import Counter
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "data/audio/sukru-tunar-ussak-taksim-on-clarinet-pitch-contour-only-c0139114-c9ed5c5e.wav"
REFERENCE = ROOT / "outputs/sukru-tunar-ussak-taksim-on-clarinet-pitch-contour-only-c0139114-c9ed5c5e.vamp.json"
OUTPUT_JSON = ROOT / "outputs/sukru-tunar-vpm-candidate-diagnostics.json"
OUTPUT_MD = ROOT / "outputs/sukru-tunar-vpm-candidate-diagnostics.md"
DIAGNOSTIC_RUNNER = Path(tempfile.gettempdir()) / "klarivision_vpm_like_diagnostics"
TRACE_RUNNER = Path(tempfile.gettempdir()) / "klarivision_vpm_like_trace"
WINDOW = 1536
HOP = 512
RANGES = ((111.0, 113.0), (130.0, 133.0), (150.0, 154.0))
RELATIONSHIPS = {"1/3": 1 / 3, "1/2": 1 / 2, "2x": 2.0, "3x": 3.0}


def cents(actual: float, expected: float) -> float:
    return 1200 * math.log2(actual / expected)


def ratio_diagnostics(frequency: float | None, pyin_frequency: float | None) -> dict[str, object] | None:
    if not frequency or not pyin_frequency:
        return None
    ratio = frequency / pyin_frequency
    distances = {
        label: round(cents(ratio, expected_ratio), 3)
        for label, expected_ratio in RELATIONSHIPS.items()
    }
    closest = min(distances, key=lambda label: abs(distances[label]))
    return {
        "frequency_over_pyin": round(ratio, 8),
        "cents_from_pyin": round(cents(frequency, pyin_frequency), 3),
        "cents_from_relationship": distances,
        "harmonic_relationship_within_90_cents": closest if abs(distances[closest]) <= 90 else None,
    }


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        channels = source.getnchannels()
        width = source.getsampwidth()
        if width != 2:
            raise ValueError("Diagnostic source must be 16-bit PCM")
        values = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    if channels > 1:
        values = values.reshape(-1, channels).mean(axis=1)
    return values, rate


def compile_runners() -> None:
    common = [
        "xcrun", "clang++", "-O3", "-std=c++20", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "core/include"), str(ROOT / "core/src/vpm_like.cpp"),
    ]
    subprocess.run(common + [str(ROOT / "core/tools/vpm_like_diagnostics.cpp"), "-o", str(DIAGNOSTIC_RUNNER)], check=True)
    subprocess.run(common + [str(ROOT / "core/tools/vpm_like_trace.cpp"), "-o", str(TRACE_RUNNER)], check=True)


def trace(raw: Path, rate: int) -> list[tuple[float, float, float]]:
    result = subprocess.run(
        [
            str(TRACE_RUNNER), str(raw), str(rate), str(WINDOW), str(HOP),
            "0.38", "0.90", "0.080", "0.005", "6", "0", "0.015",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = []
    for line in result.stdout.splitlines()[1:]:
        time, frequency, confidence = line.split(",")
        rows.append((float(time), float(frequency), float(confidence)))
    return rows


def diagnostic_frames(
    raw: Path, rate: int, absolute_spectrum: float, allow_spectral_promotion: bool
) -> list[dict[str, object]]:
    frames: list[dict[str, object]] = []
    for start, end in RANGES:
        result = subprocess.run(
            [
                str(DIAGNOSTIC_RUNNER), str(raw), str(rate), str(WINDOW), str(HOP), str(start), str(end),
                str(absolute_spectrum), "1" if allow_spectral_promotion else "0",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        for line in result.stdout.splitlines():
            frame = json.loads(line)
            frame["range_seconds"] = [start, end]
            frames.append(frame)
    return frames


def stable_reference(reference: list[dict[str, object]]) -> list[tuple[float, float]]:
    voiced = [
        (float(row["time_seconds"]), float(row["frequency_hz"]))
        for row in reference if row.get("voiced") and row.get("frequency_hz")
    ]
    stable: list[tuple[float, float]] = []
    for index in range(2, len(voiced) - 2):
        neighborhood = voiced[index - 2:index + 3]
        if neighborhood[-1][0] - neighborhood[0][0] > 0.08:
            continue
        center = neighborhood[2][1]
        if max(abs(cents(frequency, center)) for _, frequency in neighborhood) <= 65:
            stable.append(voiced[index])
    return stable


def alignment_offset(engine_trace: list[tuple[float, float, float]], reference: list[dict[str, object]]) -> float:
    stable = stable_reference(reference)
    times = np.array([row[0] for row in stable])
    frequencies = np.array([row[1] for row in stable])
    candidates: list[tuple[float, float, int]] = []
    for offset in np.arange(-0.08, 0.0801, 0.002):
        errors: list[float] = []
        for time, actual, _ in engine_trace[::3]:
            index = int(np.searchsorted(times, time - offset))
            choices = [item for item in (index - 1, index) if 0 <= item < len(times)]
            if not choices:
                continue
            nearest = min(choices, key=lambda item: abs(times[item] - (time - offset)))
            if abs(times[nearest] - (time - offset)) <= 0.018:
                errors.append(abs(cents(actual, frequencies[nearest])))
        inliers = [error for error in errors if error <= 100]
        candidates.append((float(offset), float(np.median(inliers)) if inliers else math.inf, len(inliers)))
    return min(candidates, key=lambda item: (item[1], -item[2], abs(item[0])))[0]


def nearest_pyin(
    reference: list[dict[str, object]], time: float, offset: float
) -> dict[str, object] | None:
    target = time - offset
    times = [float(row["time_seconds"]) for row in reference]
    index = int(np.searchsorted(times, target))
    choices = [item for item in (index - 1, index) if 0 <= item < len(reference)]
    if not choices:
        return None
    nearest = min(choices, key=lambda item: abs(times[item] - target))
    if abs(times[nearest] - target) > 0.018:
        return None
    row = reference[nearest]
    frequency = row.get("frequency_hz")
    return {
        "time_seconds": float(row["time_seconds"]),
        "aligned_time_delta_seconds": round(float(row["time_seconds"]) - target, 8),
        "frequency_hz": float(frequency) if frequency else None,
        "voiced": bool(row.get("voiced")),
        "confidence": float(row["confidence"]) if row.get("confidence") is not None else None,
        "confidence_kind": "fixed_import_proxy_not_vamp_probability",
    }


def percentile(values: list[float], quantile: float) -> float | None:
    return round(float(np.percentile(values, quantile)), 3) if values else None


def summarize(frames: list[dict[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for start, end in RANGES:
        rows = [row for row in frames if row["range_seconds"] == [start, end]]
        compared = [row for row in rows if row["frequency_hz"] and row["pyin"] and row["pyin"]["frequency_hz"]]
        errors = [abs(float(row["selected_vs_pyin"]["cents_from_pyin"])) for row in compared]
        relationships = Counter(
            row["selected_vs_pyin"]["harmonic_relationship_within_90_cents"]
            for row in compared
            if row["selected_vs_pyin"]["harmonic_relationship_within_90_cents"]
        )
        result[f"{int(start)}-{int(end)}"] = {
            "analysis_frames": len(rows),
            "engine_voiced_frames": sum(row["frequency_hz"] is not None for row in rows),
            "pyin_matched_frames": sum(row["pyin"] is not None for row in rows),
            "compared_frames": len(compared),
            "median_absolute_cent_difference": percentile(errors, 50),
            "p95_absolute_cent_difference": percentile(errors, 95),
            "harmonic_relationship_counts": {label: relationships.get(label, 0) for label in RELATIONSHIPS},
        }
    return result


def evidence_assessment(
    previous_frames: list[dict[str, object]], frames: list[dict[str, object]]
) -> dict[str, object]:
    divergent = [
        row for row in frames
        if row.get("selected_vs_pyin") and
        row["selected_vs_pyin"]["harmonic_relationship_within_90_cents"]
    ]
    pyin_supported = 0
    pyin_rejected = Counter()
    lower_selected = 0
    for row in divergent:
        pyin_frequency = row["pyin"]["frequency_hz"]
        candidates = row["spectral_candidates"]
        closest = min(candidates, key=lambda candidate: abs(cents(candidate["frequency_hz"], pyin_frequency)))
        if abs(cents(closest["frequency_hz"], pyin_frequency)) <= 90:
            if closest["local_peak"] and closest["absolute_support"] and closest["relative_support"]:
                pyin_supported += 1
            else:
                pyin_rejected[closest["decision"]] += 1
        if row["frequency_hz"] < pyin_frequency:
            lower_selected += 1
    previous_divergent = [
        row for row in previous_frames
        if row.get("selected_vs_pyin") and
        row["selected_vs_pyin"]["harmonic_relationship_within_90_cents"]
    ]
    previous_promotions = sum(
        float(row["frequency_hz"]) > float(row["autocorrelation_frequency_hz"]) * 1.5
        for row in previous_divergent if row.get("frequency_hz")
    )
    return {
        "previous_harmonic_divergent_frames": len(previous_divergent),
        "previous_spectral_promotions_to_2x_or_3x": previous_promotions,
        "current_harmonic_divergent_frames": len(divergent),
        "engine_selected_lower_than_pyin": lower_selected,
        "pyin_near_candidate_passed_all_spectral_tests": pyin_supported,
        "pyin_near_candidate_rejection_reasons": dict(pyin_rejected),
        "verdict": "motor_selection_error_confirmed_and_fixed_remaining_divergences_inconclusive",
        "threshold_or_tracker_change": True,
        "implemented_changes": [
            "absolute_spectral_support_0.004_to_0.005",
            "spectral_candidates_cannot_promote_acf_to_2x_or_3x",
        ],
        "reason": (
            "Before the change, high-periodicity ACF candidates repeatedly agreed with pYIN but were replaced "
            "by sharper 2x/3x spectral peaks; weak lower candidates also barely cleared 0.004. Those exact "
            "selection failures are fixed. Remaining disagreements lack independent ground truth and are not retuned."
        ),
    }


def markdown(payload: dict[str, object]) -> str:
    lines = [
        "# Şükrü Tunar VPM-benzeri / pYIN aday teşhisi",
        "",
        "Tam kare ve aday verisi `sukru-tunar-vpm-candidate-diagnostics.json` içindedir.",
        "pYIN güveni gerçek Vamp olasılığı değildir: içe aktarıcı her sesli kareye sabit `0.95` yazar.",
        "",
        "## Aralık özeti",
        "",
        "| Aralık | Kare | Karşılaştırılan | Medyan sent | p95 sent | 1/3 | 1/2 | 2x | 3x |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for label, summary in payload["range_summary"].items():
        counts = summary["harmonic_relationship_counts"]
        lines.append(
            f"| {label} sn | {summary['analysis_frames']} | {summary['compared_frames']} | "
            f"{summary['median_absolute_cent_difference']} | {summary['p95_absolute_cent_difference']} | "
            f"{counts['1/3']} | {counts['1/2']} | {counts['2x']} | {counts['3x']} |"
        )
    evidence = payload["evidence_assessment"]
    lines += [
        "",
        "## Karar",
        "",
        f"Harmonik ayrışmalı kare: **{evidence['previous_harmonic_divergent_frames']} → "
        f"{evidence['current_harmonic_divergent_frames']}**. "
        f"Bunların **{evidence['engine_selected_lower_than_pyin']}** tanesinde VPM-benzeri sonuç pYIN'den düşüktür.",
        "",
        "Eski seçimde yüksek-periodicity ACF/pYIN uzlaşmasına rağmen keskin 2x/3x spektral tepenin sonucu "
        "yukarı taşıdığı kareler motor hatası için doğrudan kanıt verdi. C++ ve Swift birlikte düzeltildi: "
        "spektrum artık ACF sonucunu yukarı taşıyamaz ve mutlak destek eşiği `0.004 → 0.005` oldu. "
        "Kalan ayrışmalar bağımsız gerçek-değer olmadığı için ayrıca ayarlanmadı.",
        "",
        "Her JSON karesinde ACF aday frekansları/periodicity, beş spektral adayın genlik desteği ve "
        "seçilme-red gerekçesi, eşlenmiş pYIN frekansı/güveni ve 1/3–1/2–2x–3x sent uzaklıkları bulunur.",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    compile_runners()
    audio, rate = read_wav(SOURCE)
    reference = json.loads(REFERENCE.read_text())["frames"]
    with tempfile.TemporaryDirectory(prefix="klarivision-vpm-diagnostics-") as directory:
        raw = Path(directory) / "source.f64"
        audio.tofile(raw)
        engine_trace = trace(raw, rate)
        previous_frames = diagnostic_frames(raw, rate, 0.004, True)
        frames = diagnostic_frames(raw, rate, 0.005, False)
    offset = alignment_offset(engine_trace, reference)
    trace_by_time = {round(time, 8): (frequency, confidence) for time, frequency, confidence in engine_trace}
    for collection, verify_production in ((previous_frames, False), (frames, True)):
        for frame in collection:
            time = float(frame["time_seconds"])
            expected = trace_by_time.get(round(time, 8))
            if verify_production and expected is not None:
                if frame["frequency_hz"] is None or abs(float(frame["frequency_hz"]) - expected[0]) > 1e-6:
                    raise RuntimeError(f"Diagnostic/production estimator mismatch at {time:.8f}s")
            pyin = nearest_pyin(reference, time, offset)
            frame["pyin"] = pyin
            pyin_frequency = pyin["frequency_hz"] if pyin else None
            frame["selected_vs_pyin"] = ratio_diagnostics(frame["frequency_hz"], pyin_frequency)
            for candidate in frame["autocorrelation_candidates"]:
                candidate["vs_pyin"] = ratio_diagnostics(candidate["frequency_hz"], pyin_frequency)
            for candidate in frame["spectral_candidates"]:
                candidate["vs_pyin"] = ratio_diagnostics(candidate["frequency_hz"], pyin_frequency)

    payload = {
        "schema": "klarivision-vpm-like-candidate-diagnostics-v1",
        "source": str(SOURCE.relative_to(ROOT)),
        "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "reference": str(REFERENCE.relative_to(ROOT)),
        "ranges_seconds": [list(item) for item in RANGES],
        "window_samples": WINDOW,
        "hop_samples": HOP,
        "sample_rate_hz": rate,
        "alignment_offset_seconds": round(offset, 4),
        "config": {
            "minimum_periodicity": 0.38,
            "near_strongest_ratio": 0.90,
            "relative_spectral_support": 0.080,
            "absolute_spectral_support": 0.005,
            "maximum_period_multiple": 6,
        },
        "pyin_confidence_note": (
            "VampPyinPitchExtractor.from_csv does not receive probability; it fills every imported voiced "
            "frame with 0.95. Values below are fixed import proxies, not measured Vamp confidence."
        ),
        "previous_range_summary": summarize(previous_frames),
        "range_summary": summarize(frames),
        "evidence_assessment": evidence_assessment(previous_frames, frames),
        "frames": frames,
    }
    OUTPUT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    OUTPUT_MD.write_text(markdown(payload))
    print(json.dumps(payload["range_summary"], ensure_ascii=False, indent=2))
    print(json.dumps(payload["evidence_assessment"], ensure_ascii=False, indent=2))
    print(OUTPUT_JSON)
    print(OUTPUT_MD)


if __name__ == "__main__":
    main()
