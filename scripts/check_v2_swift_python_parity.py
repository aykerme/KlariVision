#!/usr/bin/env python3
"""Compare the Pitch Engine v2 Python benchmark mirror to shipped Swift."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import wave
from dataclasses import asdict
from pathlib import Path

import numpy as np


SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from benchmark_live_pyin_alignment import DEFAULT_MINIMUM_RMS
from check_vpm_swift_cpp_parity import TraceFrame, compare_traces
from pitch_tournament_engines import HOP, LIVE_WINDOW, v2_cpp_frames, v2_frames


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data/benchmarks"
DEFAULT_SOURCES = tuple(sorted(
    path for path in BENCHMARKS.glob("*.wav")
    if not path.name.startswith("klarnet_gercek_")
))


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2:
            raise ValueError(f"expected mono PCM16 WAV: {path}")
        rate = source.getframerate()
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2")
    return samples.astype(np.float64) / 32768.0, rate


def export_swift_traces(jobs: list[dict[str, object]]) -> None:
    manifest = Path(str(jobs[0]["output"])).parent / "swift-v2-parity-jobs.json"
    manifest.write_text(json.dumps(jobs, indent=2) + "\n", encoding="utf-8")
    environment = os.environ.copy()
    environment["KLARIVISION_V2_PARITY_JOBS"] = str(manifest)
    environment.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/klarivision-swift-module-cache")
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", "/private/tmp/klarivision-swift-module-cache")
    subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", "PitchEngineV2ParityTraceExportTests"],
        cwd=ROOT / "macos/KlariVision", env=environment, check=True,
    )


def markdown_report(report: dict[str, object]) -> str:
    left = "C++" if report.get("left_implementation") == "cpp" else "Python"
    lines = [
        f"# Pitch Engine v2 {left} / Swift kare-iz paritesi",
        "",
        f"Durum: **{'GEÇTİ' if report['verified'] else 'KALDI'}**",
        "",
        str(report.get(
            "comparison",
            "Geçiş kanıtı: Python benchmark aynası ile uygulamanın gerçek Swift yayın yolu.",
        )),
        "",
        "Ölçüt: sesli/sessiz kararları aynı; eşleşen sesli karelerde frekans "
        f"farkı ≤ {report['frequency_tolerance_cents']} sent ve güven farkı "
        f"≤ {report['confidence_tolerance']}.",
        "",
        f"| Kaynak | {left} kare | Swift kare | Ayrışma | İlk ayrışma |",
        "|---|---:|---:|---:|---|",
    ]
    for case in report["cases"]:
        first = case["first_difference"]
        first_text = "—" if first is None else f"{first['time']:.6f} sn · {first['kind']}"
        lines.append(
            f"| {case['source']} | {case['python_frames']} | {case['swift_frames']} | "
            f"{case['difference_count']} | {first_text} |"
        )
    lines.extend(["", "Zaman damgaları kaynak analiz penceresinin merkezidir; karar gecikmesi izden çıkarılmaz.", ""])
    return "\n".join(lines)


def run(
    sources: list[Path], output: Path, *, include_candidate_diagnostics: bool = False,
    left_implementation: str = "python",
) -> dict[str, object]:
    output.parent.mkdir(parents=True, exist_ok=True)
    cases: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="klarivision-v2-parity-") as temporary:
        temporary_root = Path(temporary)
        jobs: list[dict[str, object]] = []
        prepared: list[tuple[Path, np.ndarray, int, Path]] = []
        for index, source in enumerate(sources):
            audio, rate = read_wav(source)
            # Core Audio hands production Swift Float32 samples. Quantising
            # once makes threshold-edge comparisons input-identical.
            shared_audio = np.asarray(audio, dtype=np.float32)
            float_input = temporary_root / f"input-{index}.f32"
            swift_output = temporary_root / f"swift-{index}.json"
            shared_audio.tofile(float_input)
            jobs.append({
                "input": str(float_input), "output": str(swift_output),
                "sampleRate": float(rate), "windowSize": LIVE_WINDOW,
                "hopSize": HOP, "minimumRMS": DEFAULT_MINIMUM_RMS,
                "exportDiagnostics": include_candidate_diagnostics,
            })
            prepared.append((source, shared_audio.astype(np.float64), rate, swift_output))
        export_swift_traces(jobs)

        for source, audio, rate, swift_output in prepared:
            python_diagnostics: list[dict[str, object]] | None = (
                [] if include_candidate_diagnostics else None
            )
            if left_implementation == "cpp":
                python = [TraceFrame(*frame) for frame in v2_cpp_frames(
                    audio, rate, LIVE_WINDOW, HOP, DEFAULT_MINIMUM_RMS,
                )]
            else:
                python = [TraceFrame(*frame) for frame in v2_frames(
                    audio, rate, LIVE_WINDOW, HOP, DEFAULT_MINIMUM_RMS,
                    diagnostics=python_diagnostics,
                )]
            swift = [TraceFrame(**item) for item in json.loads(swift_output.read_text())]
            swift_diagnostics = json.loads(
                Path(str(swift_output) + ".diagnostics.json").read_text()
            ) if include_candidate_diagnostics else []
            differences = compare_traces(python, swift)
            first_time = differences[0].time if differences else None
            radius = 10 * HOP / rate
            context = None if first_time is None else {
                "python": [asdict(frame) for frame in python if abs(frame.time - first_time) <= radius],
                "swift": [asdict(frame) for frame in swift if abs(frame.time - first_time) <= radius],
                "python_candidates": [
                    row for row in (python_diagnostics or [])
                    if row.get("resolvedTime") is not None
                    and abs(float(row["resolvedTime"]) - first_time) <= radius
                ],
                "swift_candidates": [
                    row for row in swift_diagnostics
                    if row.get("resolvedTime") is not None
                    and abs(float(row["resolvedTime"]) - first_time) <= radius
                ],
            }
            cases.append({
                "source": source.name,
                "python_frames": len(python), "swift_frames": len(swift),
                "difference_count": len(differences),
                "difference_kinds": {
                    kind: sum(item.kind == kind for item in differences)
                    for kind in ("voicing", "frequency", "confidence")
                },
                "differences": [asdict(item) for item in differences],
                "first_difference": asdict(differences[0]) if differences else None,
                "first_difference_context": context,
            })

    report: dict[str, object] = {
        "schema": f"klarivision-v2-{left_implementation}-swift-trace-parity-v1",
        "verified": all(case["difference_count"] == 0 for case in cases),
        "left_implementation": left_implementation,
        "comparison": (
            "Üretim paritesi: ortak C++ V2 motoru ile uygulamanın Swift referans yayın izi."
            if left_implementation == "cpp" else
            "Geçiş kanıtı: Python benchmark aynası ile uygulamanın gerçek Swift yayın yolu."
        ),
        "window_samples": LIVE_WINDOW, "hop_samples": HOP,
        "minimum_rms": DEFAULT_MINIMUM_RMS,
        "frequency_tolerance_cents": 1.0, "confidence_tolerance": 0.01,
        "cases": cases,
    }
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output.with_suffix(".md").write_text(markdown_report(report), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="*", type=Path, default=list(DEFAULT_SOURCES))
    parser.add_argument("--output", type=Path, default=ROOT / "outputs/v2-python-swift-trace-parity.json")
    parser.add_argument("--candidate-diagnostics", action="store_true")
    parser.add_argument("--cpp", action="store_true", help="compare shared C++ V2 to Swift")
    arguments = parser.parse_args()
    missing = [source for source in arguments.sources if not source.exists()]
    if missing:
        parser.error("missing source(s): " + ", ".join(map(str, missing)))
    report = run(
        arguments.sources,
        arguments.output,
        include_candidate_diagnostics=arguments.candidate_diagnostics,
        left_implementation="cpp" if arguments.cpp else "python",
    )
    print(markdown_report(report))
    return 0 if report["verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
