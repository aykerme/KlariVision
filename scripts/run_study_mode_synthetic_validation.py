#!/usr/bin/env python3
"""Validate the exact offline Study pipeline against analytic synthetic truth."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from klarivision.frequency_viewer import prepare_display_frames
from klarivision.local_app import _to_wav
from klarivision.pitch.cpp_engine import ENGINES, OFFLINE_TRACK_REVISION, extract
from klarivision.study_validation import _manifest_for, validation_for_study


DEFAULT_JSON = ROOT / "outputs" / "study-mode-synthetic-validation.json"
DEFAULT_MARKDOWN = ROOT / "outputs" / "study-mode-synthetic-validation.md"


def _fingerprint(payload: dict[str, object]) -> str:
    stable = json.loads(json.dumps(payload))
    stable.pop("deterministic_fingerprint", None)
    for case in stable["cases"]:
        case.pop("runtime_seconds", None)
    return hashlib.sha256(json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _summary(rows: list[dict[str, object]]) -> dict[str, int]:
    keys = ("reference_voiced_frames", "reference_silent_frames", "false_voiced_frames", "missing_voiced_frames", "correct_pitch_frames", "harmonic_error_frames", "non_harmonic_error_frames", "total_error_frames", "serious_total_error_frames")
    return {key: sum(int(row[key]) for row in rows) for key in keys}


def run(output: Path = DEFAULT_JSON, markdown: Path = DEFAULT_MARKDOWN, source_names: set[str] | None = None, source_paths: list[Path] | None = None, selected_engines: set[str] | None = None) -> dict[str, object]:
    sources = sorted(path for path in (ROOT / "data" / "benchmarks").glob("*.wav") if not path.name.startswith("klarnet_gercek_"))
    if source_names is not None:
        sources = [path for path in sources if path.name in source_names]
    if source_paths:
        sources = sorted({*sources, *(path.resolve() for path in source_paths)})
    cases: list[dict[str, object]] = []
    summaries: dict[str, dict[str, list[dict[str, object]]]] = {engine: defaultdict(list) for engine in ENGINES}
    with tempfile.TemporaryDirectory(prefix="klarivision-study-validation-") as directory:
        temporary = Path(directory)
        for source in sources:
            print(f"running {source.name}", flush=True)
            if _manifest_for(source.name) is None:
                raise ValueError(f"Synthetic WAV has no analytic truth mapping: {source.name}")
            wav = temporary / f"{source.stem}.wav"
            _to_wav(source, wav)  # Identical 48 kHz conversion used by Study imports.
            for engine in sorted(selected_engines or ENGINES):
                track = temporary / f"{source.stem}.{engine}.offline_track_v1.json"
                started = time.monotonic()
                extract(wav, engine, track)  # Same bundled C++ CLI contract as Study.
                validation = validation_for_study(source.name, wav, track, engine, prepare_display_frames)
                assert validation is not None
                runtime = round(time.monotonic() - started, 4)
                for surface in ("causal_baseline", "raw", "display"):
                    summaries[engine][surface].append(validation[surface])
                cases.append({"source": str(source.relative_to(ROOT)), "engine": engine, "profile": "offline_track_v1", "implementation_revision": OFFLINE_TRACK_REVISION, "runtime_seconds": runtime, "causal_baseline": validation["causal_baseline"], "raw": validation["raw"], "display": validation["display"], "offline_changes": validation["offline_changes"]})
    payload = {
        "schema": "klarivision-study-mode-synthetic-validation-v1",
        "contract": {"pipeline": "ffmpeg mono/48kHz -> shared C++ causal session -> offline refinement -> Study JSON -> display preparation", "profile": "offline_track_v1", "implementation_revision": OFFLINE_TRACK_REVISION, "automatic_global_offset": False, "surfaces": ["causal_baseline", "raw", "display"], "engines": sorted(ENGINES)},
        "inventory": {"synthetic_wavs": [str(path.relative_to(ROOT)) for path in sources], "excluded_real_wavs": sorted(str(path.relative_to(ROOT)) for path in (ROOT / "data" / "benchmarks").glob("klarnet_gercek_*.wav"))},
        "cases": cases,
        "summaries": {engine: {surface: _summary(rows) for surface, rows in surfaces.items()} for engine, surfaces in summaries.items()},
    }
    payload["deterministic_fingerprint"] = _fingerprint(payload)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["# Çalışma modu sentetik doğrulaması", "", "Bu rapor, Çalışma'nın üretim C++ yolunu ham ve görünen eğri olarak ayrı puanlar.", "", "| Motor | Yüzey | Ciddi hata | Ham hata | Doğru perde |", "|---|---|---:|---:|---:|"]
    for engine, surfaces in payload["summaries"].items():
        for surface, row in surfaces.items():
            lines.append(f"| {engine} | {surface} | {row['serious_total_error_frames']} | {row['total_error_frames']} | {row['correct_pitch_frames']} |")
    lines.extend(["", f"Kapsam: {len(sources)} sentetik WAV; gerçek kayıtlar dışarıda.", f"Deterministik parmak izi: `{payload['deterministic_fingerprint']}`", ""])
    markdown.write_text("\n".join(lines), encoding="utf-8")
    return payload


def merge_reports(inputs: list[Path], output: Path = DEFAULT_JSON, markdown: Path = DEFAULT_MARKDOWN) -> dict[str, object]:
    """Merge bounded Study runs without changing their measured cases."""
    cases = []
    for path in inputs:
        cases.extend(json.loads(path.read_text(encoding="utf-8"))["cases"])
    if len({(case["source"], case["engine"]) for case in cases}) != len(cases):
        raise ValueError("Duplicate source/engine case while merging Study reports")
    sources = sorted({case["source"] for case in cases})
    by_engine: dict[str, dict[str, list[dict[str, object]]]] = {engine: defaultdict(list) for engine in ENGINES}
    for case in cases:
        for surface in ("causal_baseline", "raw", "display"):
            by_engine[case["engine"]][surface].append(case[surface])
    payload = {
        "schema": "klarivision-study-mode-synthetic-validation-v1",
        "contract": {"pipeline": "ffmpeg mono/48kHz -> shared C++ causal session -> offline refinement -> Study JSON -> display preparation", "profile": "offline_track_v1", "implementation_revision": OFFLINE_TRACK_REVISION, "automatic_global_offset": False, "surfaces": ["causal_baseline", "raw", "display"], "engines": sorted(ENGINES)},
        "inventory": {"synthetic_wavs": sources, "excluded_real_wavs": sorted(str(path.relative_to(ROOT)) for path in (ROOT / "data" / "benchmarks").glob("klarnet_gercek_*.wav"))},
        "cases": sorted(cases, key=lambda item: (item["source"], item["engine"])),
        "summaries": {engine: {surface: _summary(rows) for surface, rows in surfaces.items()} for engine, surfaces in by_engine.items()},
    }
    payload["deterministic_fingerprint"] = _fingerprint(payload)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["# Çalışma modu sentetik doğrulaması", "", "Üretim C++ Çalışma yolu; ham JSON ve görünen eğri ayrı puanlandı.", "", "| Motor | Yüzey | Ciddi hata | Ham hata | Doğru perde |", "|---|---|---:|---:|---:|"]
    for engine, surfaces in payload["summaries"].items():
        for surface, row in surfaces.items():
            lines.append(f"| {engine} | {surface} | {row['serious_total_error_frames']} | {row['total_error_frames']} | {row['correct_pitch_frames']} |")
    lines.extend(["", f"Kapsam: {len(sources)} sentetik WAV; gerçek kayıtlar dışarıda.", f"Deterministik parmak izi: `{payload['deterministic_fingerprint']}`", ""])
    markdown.write_text("\n".join(lines), encoding="utf-8")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--markdown", type=Path, default=DEFAULT_MARKDOWN)
    parser.add_argument("--source", action="append", help="Run one named synthetic WAV (repeatable).")
    parser.add_argument("--source-path", type=Path, action="append", help="Add an explicit frozen holdout WAV outside the 26-WAV development inventory.")
    parser.add_argument("--engine", choices=sorted(ENGINES), action="append", help="Measure only one engine (repeatable).")
    parser.add_argument("--merge", type=Path, action="append", help="Merge bounded JSON runs instead of measuring audio.")
    arguments = parser.parse_args()
    payload = merge_reports(arguments.merge, arguments.output, arguments.markdown) if arguments.merge else run(arguments.output, arguments.markdown, set(arguments.source) if arguments.source else (set() if arguments.source_path else None), arguments.source_path, set(arguments.engine) if arguments.engine else None)
    print(f"cases={len(payload['cases'])} fingerprint={payload['deterministic_fingerprint']}")


if __name__ == "__main__":
    main()
