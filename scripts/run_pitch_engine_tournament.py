#!/usr/bin/env python3
"""Run the YIN v1 / Pitch Engine v2 / VPM-like analytic tournament."""

from __future__ import annotations

import argparse
import bisect
import copy
import hashlib
import json
import math
import re
import subprocess
import wave
from collections import defaultdict
from pathlib import Path
from typing import Iterable

import numpy as np

from generate_pitch_tournament_holdout_v1 import write_holdout
from generate_pitch_tournament_holdout_v2 import write_holdout as write_holdout_v2
from generate_pitch_tournament_holdout_v3 import write_holdout as write_holdout_v3
from generate_pitch_tournament_holdout_v4 import write_holdout as write_holdout_v4
from generate_pitch_tournament_holdout_v5 import write_holdout as write_holdout_v5
from benchmark_live_pyin_alignment import DEFAULT_MINIMUM_RMS, centered_rms
from pitch_tournament_engines import EngineTrace, HOP, LIVE_WINDOW, run_engines
from pitch_error_metrics import ObservedFrame, ReferenceFrame, harmonic_relationship, score_frames


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data/benchmarks"
OUTPUT = ROOT / "outputs/pitch-engine-tournament-all-synthetic-2026-08-09.json"
MARKDOWN = ROOT / "outputs/pitch-engine-tournament-all-synthetic-2026-08-09.md"
SAMPLE_INDEX = ROOT / "outputs/pitch-engine-tournament-all-synthetic-sample-index-2026-08-09.md"
ENGINE_ORDER = ("yin_v1", "pitch_engine_v2", "vpm_like")
TRUTH_STEP_SECONDS = 0.01
REAL_RECORDING_PREFIX = "klarnet_gercek_"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        if source.getsampwidth() != 2:
            raise ValueError(f"16-bit PCM required: {path}")
        rate = source.getframerate()
        channels = source.getnchannels()
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    return audio, rate


def ensure_fixtures() -> None:
    stress = BENCHMARKS / "klarivision_stress_ground_truth_v2.json"
    if not stress.exists() or any(not (BENCHMARKS / name).exists() for name in json.loads(stress.read_text())["variants"]):
        subprocess.run([str(ROOT / ".venv/bin/python"), str(ROOT / "scripts/generate_pitch_stress_suite_v2.py")], check=True)
    validated = BENCHMARKS / "klarivision_validated_clarinet_ground_truth_v1.json"
    if not validated.exists() or any(not (BENCHMARKS / name).exists() for name in json.loads(validated.read_text())["variants"]):
        subprocess.run([str(ROOT / ".venv/bin/python"), str(ROOT / "scripts/generate_validated_clarinet_reference_v1.py")], check=True)
    holdout = BENCHMARKS / "klarivision_pitch_tournament_holdout_ground_truth_v1.json"
    if (
        not holdout.exists()
        or "variant_conditions" not in json.loads(holdout.read_text())
        or any(not (BENCHMARKS / name).exists() for name in json.loads(holdout.read_text())["variants"])
    ):
        write_holdout(BENCHMARKS)
    holdout_v2 = BENCHMARKS / "klarivision_pitch_tournament_holdout_ground_truth_v2.json"
    if not holdout_v2.exists() or any(not (BENCHMARKS / name).exists() for name in json.loads(holdout_v2.read_text())["variants"]):
        write_holdout_v2(BENCHMARKS)
    holdout_v3 = BENCHMARKS / "klarivision_pitch_tournament_holdout_ground_truth_v3.json"
    if not holdout_v3.exists() or any(not (BENCHMARKS / name).exists() for name in json.loads(holdout_v3.read_text())["variants"]):
        write_holdout_v3(BENCHMARKS)
    holdout_v4 = BENCHMARKS / "klarivision_pitch_tournament_holdout_ground_truth_v4.json"
    if not holdout_v4.exists() or any(not (BENCHMARKS / name).exists() for name in json.loads(holdout_v4.read_text())["variants"]):
        write_holdout_v4(BENCHMARKS)
    holdout_v5 = BENCHMARKS / "klarivision_pitch_tournament_holdout_ground_truth_v5.json"
    if not holdout_v5.exists() or any(not (BENCHMARKS / name).exists() for name in json.loads(holdout_v5.read_text())["variants"]):
        write_holdout_v5(BENCHMARKS)


def verify_holdout(manifest: dict[str, object]) -> None:
    if manifest.get("policy") != "frozen-no-retuning-after-first-result":
        raise ValueError("Holdout policy marker is missing")
    expected_hashes = manifest.get("sha256", {})
    for filename in manifest["variants"]:
        digest = hashlib.sha256((BENCHMARKS / filename).read_bytes()).hexdigest()
        if digest != expected_hashes.get(filename):
            raise ValueError(f"Frozen holdout hash mismatch: {filename}")


def percentile(values: list[float], level: float) -> float | None:
    return round(float(np.percentile(values, level)), 3) if values else None


def harmonic_class(error_cents: float) -> str | None:
    return harmonic_relationship(error_cents)


def nearest_frame(
    times: list[float], frames: list[tuple[float, float, float]], target: float, tolerance: float
) -> tuple[float, float, float] | None:
    index = bisect.bisect_left(times, target)
    choices = [candidate for candidate in (index - 1, index) if 0 <= candidate < len(frames)]
    if not choices:
        return None
    nearest = min(choices, key=lambda candidate: abs(times[candidate] - target))
    return frames[nearest] if abs(times[nearest] - target) <= tolerance else None


def transition_settling_ms(
    frames: list[tuple[float, float, float]], section: dict[str, object], tolerance_cents: float = 50.0
) -> float | None:
    start, finish = float(section["start_seconds"]), float(section["end_seconds"])
    expected = section.get("frequency_hz")
    if expected is None:
        return None
    target = float(expected)
    candidates = [frame for frame in frames if start <= frame[0] <= finish]
    for index in range(max(0, len(candidates) - 2)):
        window = candidates[index:index + 3]
        if len(window) == 3 and all(abs(1200 * math.log2(frame[1] / target)) <= tolerance_cents for frame in window):
            return round(max(0.0, (window[0][0] - start) * 1_000), 3)
    return None


def enrich_section_targets(manifest: dict[str, object]) -> None:
    truth = manifest["ground_truth"]
    for section in manifest["sections"]:
        if (
            section["kind"] == "silence"
            or "frequency_hz" in section
            or section["kind"] not in {"rapid_transition", "short_attack", "attack_target"}
        ):
            continue
        middle = (float(section["start_seconds"]) + float(section["end_seconds"])) / 2
        row = min(truth, key=lambda item: abs(float(item["time_seconds"]) - middle))
        if row["frequency_hz"] is not None:
            section["frequency_hz"] = row["frequency_hz"]


def _formula_frequency(formula: str, local_time: float) -> float:
    """Evaluate only the fixed formula forms emitted by legacy fixture writers."""
    constant = re.fullmatch(r"([0-9.]+) Hz", formula)
    if constant:
        return float(constant.group(1))
    detuned = re.fullmatch(r"([0-9.]+) \* 2\^\((-?[0-9.]+)/1200\)", formula)
    if detuned:
        return float(detuned.group(1)) * 2 ** (float(detuned.group(2)) / 1200)
    vibrato = re.fullmatch(
        r"([0-9.]+) \* 2\^\(([0-9.]+)\*sin\(2π\*([0-9.]+)t\)/1200\)", formula
    )
    if vibrato:
        base, cents, rate = (float(value) for value in vibrato.groups())
        return base * 2 ** (cents * math.sin(2 * math.pi * rate * local_time) / 1200)
    glide = re.fullmatch(r"([0-9.]+) \* 2\^\(log2\(([0-9.]+)/([0-9.]+)\)\*t/([0-9.]+)\)", formula)
    if glide:
        start, end, denominator, seconds = (float(value) for value in glide.groups())
        if not math.isclose(start, denominator, rel_tol=0, abs_tol=1e-6):
            raise ValueError(f"Unexpected glide denominator: {formula}")
        return start * 2 ** (math.log2(end / start) * local_time / seconds)
    grace = re.fullmatch(r"0–([0-9.]+) ms: ([0-9.]+) Hz; sonra ([0-9.]+) Hz", formula)
    if grace:
        milliseconds, grace_hz, target_hz = (float(value) for value in grace.groups())
        return grace_hz if local_time < milliseconds / 1_000 else target_hz
    raise ValueError(f"Unsupported legacy fixture formula: {formula}")


def legacy_manifest_with_truth(manifest_path: Path) -> dict[str, object]:
    """Return a canonical 10 ms truth manifest for one legacy synthetic WAV."""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    sections = list(manifest["sections"])
    duration = float(manifest.get("duration_seconds", max(float(item["end_seconds"]) for item in sections)))
    is_full_range = manifest.get("schema") == "klarivision-full-range-pitch-benchmark-v1"
    truth = []
    for index in range(round(duration / TRUTH_STEP_SECONDS)):
        time = round(index * TRUTH_STEP_SECONDS, 6)
        section = next((item for item in sections if float(item["start_seconds"]) <= time < float(item["end_seconds"])), None)
        frequency: float | None = None
        if section:
            local_time = time - float(section["start_seconds"])
            if is_full_range and "frequency_hz" in section:
                frequency = float(section["frequency_hz"]) * 2 ** (
                    float(section.get("vibrato_cents", 0.0)) * math.sin(2 * math.pi * 4 * local_time) / 1200
                )
            elif is_full_range and section.get("type") == "logarithmic_glide":
                length = float(section["end_seconds"]) - float(section["start_seconds"])
                start, end = float(section["start_frequency_hz"]), float(section["end_frequency_hz"])
                frequency = start * (end / start) ** (local_time / length)
            else:
                frequency = _formula_frequency(str(section["frequency_formula"]), local_time)
        truth.append({"time_seconds": time, "frequency_hz": round(frequency, 6) if frequency else None})
    canonical_sections = []
    for item in sections:
        copied = dict(item)
        copied.setdefault("kind", "legacy_fixture")
        canonical_sections.append(copied)
    return {
        "schema": "klarivision-legacy-synthetic-truth-v1",
        "duration_seconds": duration,
        "truth_step_seconds": TRUTH_STEP_SECONDS,
        "ground_truth": truth,
        "sections": canonical_sections,
        "variants": [f"{manifest_path.stem}.wav"],
    }


def tournament_groups() -> list[tuple[str, list[Path], bool]]:
    return [
        ("legacy_diagnostics", [
            BENCHMARKS / "canli_pitch_referans_v1.json",
            BENCHMARKS / "clarinet_full_range_pitch_benchmark_v1.json",
            BENCHMARKS / "vibrato_cozunurluk_referans_v1.json",
            BENCHMARKS / "vibrato_klarnet_harmonik_v1.json",
            BENCHMARKS / "vibrato_klarnet_hafif_gurultu_v1.json",
            BENCHMARKS / "vibrato_klarnet_orta_gurultu_v1.json",
        ], False),
        ("development", [
            BENCHMARKS / "klarivision_stress_ground_truth_v2.json",
            BENCHMARKS / "klarivision_validated_clarinet_ground_truth_v1.json",
        ], False),
        *[(f"frozen_holdout_v{version}", [BENCHMARKS / f"klarivision_pitch_tournament_holdout_ground_truth_v{version}.json"], True)
          for version in range(1, 6)],
    ]


def verify_inventory(used_sources: Iterable[str]) -> dict[str, list[str]]:
    used = sorted(used_sources)
    if len(used) != len(set(used)):
        raise ValueError("Synthetic tournament inventory contains duplicate WAVs")
    all_wavs = sorted(path.relative_to(ROOT).as_posix() for path in BENCHMARKS.glob("*.wav"))
    excluded = [path for path in all_wavs if Path(path).name.startswith(REAL_RECORDING_PREFIX)]
    synthetic = [path for path in all_wavs if path not in excluded]
    if used != synthetic:
        missing, unexpected = sorted(set(synthetic) - set(used)), sorted(set(used) - set(synthetic))
        raise ValueError(f"Synthetic tournament inventory mismatch: missing={missing}, unexpected={unexpected}")
    return {"used_synthetic_wavs": used, "excluded_real_wavs": excluded}


def effective_manifest_for_signal(
    manifest: dict[str, object],
    audio: np.ndarray,
    rate: int,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
    window: int = LIVE_WINDOW,
) -> dict[str, object]:
    """Blank analytic targets whose centred source window is below the live gate."""
    effective = copy.deepcopy(manifest)
    half = window // 2
    blanked = 0
    for row in effective["ground_truth"]:
        if row["frequency_hz"] is None:
            continue
        centre = int(round(float(row["time_seconds"]) * rate))
        start, finish = max(0, centre - half), min(len(audio), centre - half + window)
        rms = centered_rms(audio[start:finish])
        if rms < minimum_rms:
            row["frequency_hz"] = None
            blanked += 1
    effective["signal_gate"] = {
        "minimum_rms": minimum_rms,
        "minimum_dbfs": 20 * math.log10(max(minimum_rms, 1e-12)),
        "window_samples": window,
        "definition": "DC-removed centred-window RMS; values strictly below threshold are silent",
        "blanked_reference_frames": blanked,
    }
    return effective


def score_trace(
    trace: EngineTrace,
    manifest: dict[str, object],
    rate: int,
    *,
    silence_guard_seconds: float = 0.0,
) -> dict[str, object]:
    tolerance = HOP / rate * 0.55
    reference = [ReferenceFrame(float(row["time_seconds"]), row["frequency_hz"]) for row in manifest["ground_truth"]]
    observed = [ObservedFrame(time, frequency) for time, frequency, _ in trace.frames]
    # Section boundaries are explicit target-regime transitions.  They protect
    # short analysis-window blending at attacks, releases and note changes,
    # while a glide/vibrato remains unprotected inside its own section.
    transition_times = sorted({
        round(float(section[edge]), 9)
        for section in manifest.get("sections", [])
        for edge in ("start_seconds", "end_seconds")
    })
    result = score_frames(reference, observed, tolerance_seconds=tolerance, transition_times=transition_times)
    # Make serious ranges actionable without changing their accounting. The
    # section is source truth context, never an engine-side tuning input.
    for error_range in result["serious_error_ranges"]:
        middle = (float(error_range["start_seconds"]) + float(error_range["end_seconds"])) / 2
        section = next((item for item in manifest.get("sections", [])
                        if float(item["start_seconds"]) <= middle <= float(item["end_seconds"])), None)
        if section:
            error_range["section_label"] = section.get("label")
            error_range["section_kind"] = section.get("kind")
    result.update({
        "engine": trace.engine,
        "implementation": trace.implementation,
        "latency": {"analysis_half_window_ms": round(trace.analysis_half_window_ms, 3), "fixed_lag_ms": round(trace.fixed_lag_ms, 3), "decision_latency_ms": round(trace.decision_latency_ms, 3)},
        "performance": {"cpu_seconds": round(trace.runtime_seconds, 4), "audio_seconds": round(trace.audio_seconds, 4), "cpu_realtime_factor": round(trace.realtime_factor, 5), "cpu_realtime_capable": trace.realtime_factor < 1.0},
        "sections": [
            {
                "label": str(section.get("label", section.get("type", "section"))),
                "kind": str(section.get("kind", "legacy_fixture")),
                "start_seconds": float(section["start_seconds"]),
                "end_seconds": float(section["end_seconds"]),
                "expected_frequency_hz": section.get("frequency_hz"),
            }
            for section in manifest.get("sections", [])
        ],
    })
    return result


def aggregate(results: Iterable[dict[str, object]], engine: str) -> dict[str, float | int | None]:
    rows = [result for result in results if result["engine"] == engine]
    correct = sum(int(row["correct_pitch_frames"]) for row in rows)
    absolute_sum = sum(float(row["correct_pitch_absolute_cents_sum"]) for row in rows)
    summary = {
        **{key: sum(int(row[key]) for row in rows) for key in (
            "reference_voiced_frames", "reference_silent_frames", "false_voiced_frames", "missing_voiced_frames",
            "correct_pitch_frames", "harmonic_error_frames", "non_harmonic_error_frames", "total_error_frames",
        )},
        **{key: sum(int(row.get(key, 0)) for row in rows) for key in (
            "near_pitch_frames", "serious_false_voiced_frames", "serious_missing_voiced_frames",
            "serious_harmonic_error_frames", "serious_non_harmonic_error_frames", "serious_total_error_frames",
            "transition_tolerated_frames", "transient_tolerated_frames",
        )},
        "correct_pitch_absolute_cents_sum": round(absolute_sum, 6),
        "correct_pitch_mean_absolute_cents": round(absolute_sum / correct, 6) if correct else None,
        "decision_latency_ms": rows[0]["latency"]["decision_latency_ms"],
        "maximum_cpu_realtime_factor": max(float(row["performance"]["cpu_realtime_factor"]) for row in rows),
    }
    summary["non_serious_error_frames"] = int(summary["total_error_frames"]) - int(summary["serious_total_error_frames"])
    return summary


def selection(all_results: list[dict[str, object]], safety_results: list[dict[str, object]] | None = None) -> dict[str, object]:
    """Rank all synthetic fixtures; safety gates remain separate from ranking."""
    summaries = {engine: aggregate(all_results, engine) for engine in ENGINE_ORDER}
    baseline = summaries["yin_v1"]
    safety_results = safety_results if safety_results is not None else all_results
    parity = {
        "yin_v1": {"verified": True, "evidence": "protected production baseline"},
        "pitch_engine_v2": {"verified": False, "evidence": "benchmark mirror; C++/Swift trace parity not yet proven"},
        "vpm_like": {"verified": False, "evidence": "production C++ trace; duplicated Swift trace parity not yet proven"},
    }
    decisions = {"yin_v1": {"eligible": True, "significant_gain": False, "vetoes": [], "parity": parity["yin_v1"]}}
    contenders = []
    for engine in ENGINE_ORDER[1:]:
        summary = summaries[engine]
        vetoes = []
        for result in [row for row in safety_results if row["engine"] == engine]:
            baseline_row = next(
                row for row in safety_results
                if row["engine"] == "yin_v1" and row["source"] == result["source"]
            )
            for key, denominator in (
                ("serious_false_voiced_frames", "reference_silent_frames"),
                ("serious_missing_voiced_frames", "reference_voiced_frames"),
                ("serious_harmonic_error_frames", "reference_voiced_frames"),
                ("serious_non_harmonic_error_frames", "reference_voiced_frames"),
            ):
                candidate_count = int(result.get(key, result.get(key.removeprefix("serious_"), 0)))
                baseline_count = int(baseline_row.get(key, baseline_row.get(key.removeprefix("serious_"), 0)))
                frames = max(1, int(baseline_row[denominator]))
                if (candidate_count - baseline_count) / frames > 0.005:
                    vetoes.append(f"{result['source']}: {key} exceeds YIN v1 by >0.5pp")
        significant = ranking_key(summary) < ranking_key(baseline)
        decisions[engine] = {
            "eligible": not vetoes,
            "significant_gain": significant,
            "vetoes": vetoes,
            "parity": parity[engine],
        }
        if not vetoes and significant:
            contenders.append(engine)
    benchmark_winner = min(ENGINE_ORDER, key=lambda name: ranking_key(summaries[name]))
    winner_decision = decisions[benchmark_winner]
    promotion_ready = (
        benchmark_winner != "yin_v1"
        and bool(winner_decision["eligible"])
        and bool(winner_decision["significant_gain"])
        and bool(parity[benchmark_winner]["verified"])
    )
    default_engine = benchmark_winner if promotion_ready else "yin_v1"
    if benchmark_winner == "yin_v1":
        outcome = "keep_yin_v1"
    elif promotion_ready:
        outcome = "promote_candidate"
    elif not winner_decision["eligible"]:
        outcome = "candidate_vetoed_keep_yin_v1"
    else:
        outcome = "candidate_requires_parity"
    return {
        "outcome": outcome,
        "benchmark_winner": benchmark_winner,
        "default_engine": default_engine,
        "policy": {
            "ranking": ["serious_total_error_frames", "non_serious_error_frames", "correct_pitch_mean_absolute_cents", "decision_latency_ms"],
            "winner": "All synthetic WAVs are ranked by serious errors, then non-serious raw errors, correct-pitch mean absolute cents, and latency.",
            "veto": "No serious class rate may exceed YIN v1 by more than 0.5 percentage points for an individual frozen holdout case; this gate never changes benchmark_winner.",
        },
        "summaries": summaries,
        "decisions": decisions,
    }


def ranking_key(summary: dict[str, float | int | None]) -> tuple[int, int, float, float]:
    return (
        int(summary["serious_total_error_frames"]),
        int(summary["non_serious_error_frames"]),
        float(summary["correct_pitch_mean_absolute_cents"] or math.inf),
        float(summary["decision_latency_ms"]),
    )


def deterministic_fingerprint(payload: dict[str, object]) -> str:
    stable = json.loads(json.dumps(payload))
    stable.pop("deterministic_fingerprint", None)
    for group in stable["benchmark_groups"]:
        for case in group["cases"]:
            for engine in case["engines"]:
                engine.pop("performance", None)
    for summary in stable.get("selection", {}).get("summaries", {}).values():
        summary.pop("maximum_cpu_realtime_factor", None)
    encoded = json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def markdown_report(payload: dict[str, object]) -> str:
    lines = [
        "# Tüm sentetik dosyalarla Pitch Engine Tournament", "",
        f"Benchmark kazananı: **{payload['selection']['benchmark_winner']}** · "
        f"varsayılan: **{payload['selection']['default_engine']}** · `{payload['selection']['outcome']}`", "",
        "pYIN bu raporda gerçek-değer veya seçim metriği olarak kullanılmaz.",
        f"Ortak düşük-seviye kapısı: RMS **{payload['reference_policy']['minimum_rms']:.6f}** "
        f"(**{payload['reference_policy']['minimum_dbfs']:.1f} dBFS**); motor ve matematiksel hedef aynı kareleri boş bırakır.",
        "Ham beşli muhasebe korunur. Ciddi hata: geçiş payı dışında en az 3 ardışık kare; 50–100 sent yakın-perde uyarısıdır.", "",
        f"Kapsam: {len(payload['inventory']['used_synthetic_wavs'])} sentetik WAV; dışarıda: "
        f"{', '.join(Path(path).name for path in payload['inventory']['excluded_real_wavs'])}.", "",
        "## Genel sıralama", "",
        "| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi diğer | Ciddi toplam | Ciddi olmayan | Ham toplam | Doğru-kare ort. sent | Karar gecikmesi | Güvenlik kapısı |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for engine in ENGINE_ORDER:
        summary = payload["selection"]["summaries"][engine]
        decision = payload["selection"]["decisions"][engine]
        lines.append(
            f"| {engine} | {summary.get('serious_false_voiced_frames', 0)} | {summary.get('serious_missing_voiced_frames', 0)} | "
            f"{summary.get('serious_harmonic_error_frames', 0)} | {summary.get('serious_non_harmonic_error_frames', 0)} | "
            f"{summary.get('serious_total_error_frames', summary['total_error_frames'])} | {summary['non_serious_error_frames']} | {summary['total_error_frames']} | "
            f"{summary['correct_pitch_mean_absolute_cents']:.3f} | "
            f"{summary['decision_latency_ms']:.3f} ms | {'; '.join(decision['vetoes']) or '—'} |"
        )
    for group in payload["benchmark_groups"]:
        lines.extend(["", f"## {group['name']}", ""])
        for case in group["cases"]:
            lines.extend([
                f"### {Path(case['source']).name}", "",
                f"Referans: {case['engines'][0]['reference_voiced_frames']} sesli kare · {case['engines'][0]['reference_silent_frames']} sessiz kare · "
                f"seviye kapısıyla boşaltılan {case['signal_gate']['blanked_reference_frames']} kare", "",
                "| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi diğer | Ciddi toplam | Ciddi olmayan | Ham toplam | Gecikme | RTF |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            ])
            for row in case["engines"]:
                lines.append(
                    f"| {row['engine']} | {row.get('serious_false_voiced_frames', 0)} | {row.get('serious_missing_voiced_frames', 0)} | "
                    f"{row.get('serious_harmonic_error_frames', 0)} | {row.get('serious_non_harmonic_error_frames', 0)} | "
                    f"{row.get('serious_total_error_frames', row['total_error_frames'])} | "
                    f"{row['total_error_frames'] - row.get('serious_total_error_frames', 0)} | {row['total_error_frames']} | "
                    f"{row['latency']['decision_latency_ms']:.3f} ms | {row['performance']['cpu_realtime_factor']:.5f} |"
                )
                ranges = row.get("serious_error_ranges", [])
                if ranges:
                    lines.append("  - " + row["engine"] + ": " + "; ".join(
                        f"{item['kind']} {item['start_seconds']:.3f}–{item['end_seconds']:.3f} sn ({item['frames']} kare)"
                        for item in ranges
                    ))
    lines.extend(["", f"Deterministik ölçüm parmak izi: `{payload['deterministic_fingerprint']}`", ""])
    return "\n".join(lines)


def sample_index_report(payload: dict[str, object]) -> str:
    lines = [
        "# Tüm sentetik dosyalarla pitch turnuvası dinleme indeksi", "",
        "Bu dosya, turnuvada kullanılan WAV kayıtlarını kulakla kontrol etmek için hazırlanmıştır. "
        "Zamanlar ses dosyasının kendi eksenindedir; hedef frekans sentetik gerçek-değerdir.", "",
    ]
    descriptions = {
        "anchor": "kararlı perde",
        "steady": "kararlı perde",
        "detuned_anchor": "eşit tampere oturmayan kararlı perde",
        "harmonic_morph": "temeli zayıflayan, 2×/3× harmonikleri güçlenen perde",
        "hidden_fundamental": "farklı eğriyle bastırılan temel ses",
        "register_jump": "register sıçraması",
        "rapid_transition": "sessiz aralıksız hızlı geçiş",
        "vibrato": "vibrato çözünürlüğü",
        "high_vibrato": "üst register vibratosu",
        "glide": "sürekli perde kayması",
        "curved_glide": "doğrusal olmayan mikrotonal kayma",
        "grace": "kısa süsleme/attack",
        "short_attack": "47 ms kısa attack",
        "dropout": "düzensiz kısa sinyal kaybı",
        "dropouts": "kısa sinyal kayıpları",
        "silence": "sessizlik/yanlış sesli kontrolü",
    }
    for group in payload["benchmark_groups"]:
        lines.extend([f"## {group['name']}", ""])
        for case in group["cases"]:
            source = Path(case["source"])
            sections = case["engines"][0]["sections"]
            lines.extend([
                f"### [{source.name}](../{source.as_posix()})", "",
                "| Başlangıç | Bitiş | Test | Beklenen Hz | Dinleme amacı |",
                "|---:|---:|---|---:|---|",
            ])
            for section in sections:
                expected = section["expected_frequency_hz"]
                lines.append(
                    f"| {section['start_seconds']:.3f} sn | {section['end_seconds']:.3f} sn | "
                    f"{section['label']} | {float(expected):.3f} | {descriptions.get(section['kind'], section['kind'])} |"
                    if expected is not None else
                    f"| {section['start_seconds']:.3f} sn | {section['end_seconds']:.3f} sn | "
                    f"{section['label']} | — | {descriptions.get(section['kind'], section['kind'])} |"
                )
            lines.append("")
    return "\n".join(lines)


def run_tournament(
    output: Path = OUTPUT,
    markdown: Path = MARKDOWN,
    sample_index: Path = SAMPLE_INDEX,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
) -> dict[str, object]:
    if not 0 < minimum_rms <= 1:
        raise ValueError("minimum_rms must be in (0, 1]")
    ensure_fixtures()
    groups = tournament_groups()
    report_groups = []
    all_results = []
    safety_results = []
    used_sources = []
    for group_name, manifests, frozen in groups:
        cases = []
        for manifest_path in manifests:
            manifest = legacy_manifest_with_truth(manifest_path) if group_name == "legacy_diagnostics" else json.loads(manifest_path.read_text(encoding="utf-8"))
            if frozen:
                verify_holdout(manifest)
            enrich_section_targets(manifest)
            for filename in manifest["variants"]:
                source = BENCHMARKS / filename
                print(f"running {group_name}: {filename}", flush=True)
                audio, rate = read_wav(source)
                effective_manifest = effective_manifest_for_signal(
                    manifest, audio, rate, minimum_rms
                )
                engine_results = []
                conditions = manifest.get("variant_conditions", {}).get(filename, {})
                if not conditions and ("room" in filename or "adverse" in filename):
                    conditions = {"silence_guard_seconds": 0.150}
                for trace in run_engines(audio, rate, minimum_rms).values():
                    result = score_trace(
                        trace,
                        effective_manifest,
                        rate,
                        silence_guard_seconds=float(conditions.get("silence_guard_seconds", 0.0)),
                    )
                    result["source"] = str(source.relative_to(ROOT))
                    engine_results.append(result)
                    all_results.append(result)
                    if frozen:
                        safety_results.append(result)
                used_sources.append(str(source.relative_to(ROOT)))
                cases.append({
                    "source": str(source.relative_to(ROOT)),
                    "manifest": str(manifest_path.relative_to(ROOT)),
                    "sample_rate_hz": rate,
                    "signal_gate": effective_manifest["signal_gate"],
                    "engines": engine_results,
                })
                print(f"finished {group_name}: {filename}", flush=True)
        report_groups.append({"name": group_name, "cases": cases})
    payload = {
        "schema": "klarivision-pitch-engine-tournament-all-synthetic-v2",
        "time_contract": {
            "trace_timestamp": "centre of the source analysis window",
            "automatic_global_offset": False,
            "window_samples": LIVE_WINDOW,
            "hop_samples": HOP,
        },
        "reference_policy": {
            "selection_truth": "analytic synthetic ground truth only",
            "pyin_role": "diagnostic real-performance comparison only; absent from this report",
            "minimum_rms": minimum_rms,
            "minimum_dbfs": 20 * math.log10(minimum_rms),
            "low_signal_rule": "analytic target and every live engine are blank below the shared centred-window RMS gate",
        },
        "inventory": verify_inventory(used_sources),
        "benchmark_groups": report_groups,
        "selection": selection(all_results, safety_results),
    }
    payload["deterministic_fingerprint"] = deterministic_fingerprint(payload)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    markdown.write_text(markdown_report(payload), encoding="utf-8")
    sample_index.write_text(sample_index_report(payload), encoding="utf-8")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--markdown", type=Path, default=MARKDOWN)
    parser.add_argument("--sample-index", type=Path, default=SAMPLE_INDEX)
    parser.add_argument("--minimum-rms", type=float, default=DEFAULT_MINIMUM_RMS)
    arguments = parser.parse_args()
    payload = run_tournament(
        arguments.output, arguments.markdown, arguments.sample_index, arguments.minimum_rms
    )
    print(
        f"benchmark_winner={payload['selection']['benchmark_winner']} "
        f"default={payload['selection']['default_engine']} outcome={payload['selection']['outcome']}"
    )
    print(f"fingerprint={payload['deterministic_fingerprint']}")
    print(arguments.output)
    print(arguments.markdown)
    print(arguments.sample_index)


if __name__ == "__main__":
    main()
