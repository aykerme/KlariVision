#!/usr/bin/env python3
"""Compare the shipped Swift VPM-like trace with the canonical C++ trace."""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import wave
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np


SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from benchmark_live_pyin_alignment import DEFAULT_MINIMUM_RMS
from pitch_tournament_engines import HOP, LIVE_WINDOW, vpm_frames


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data/benchmarks"
DEFAULT_SOURCES = tuple(sorted(
    path for path in BENCHMARKS.glob("*.wav")
    if not path.name.startswith("klarnet_gercek_")
))


@dataclass(frozen=True)
class TraceFrame:
    time: float
    frequency: float
    confidence: float


@dataclass(frozen=True)
class TraceDifference:
    time: float
    kind: str
    cpp_frequency: float | None
    swift_frequency: float | None
    cents: float | None
    cpp_confidence: float | None
    swift_confidence: float | None


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2:
            raise ValueError(f"expected mono PCM16 WAV: {path}")
        rate = source.getframerate()
        samples = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2")
    return samples.astype(np.float64) / 32768.0, rate


def compare_traces(
    cpp: list[TraceFrame],
    swift: list[TraceFrame],
    *,
    frequency_tolerance_cents: float = 1.0,
    confidence_tolerance: float = 0.01,
) -> list[TraceDifference]:
    # The C++ trace is serialized as decimal CSV before its half-window is
    # removed. Microsecond keys discard only that text-rounding residue; one
    # 512-sample hop is more than 10,000 microseconds at supported rates.
    cpp_by_time = {round(frame.time, 6): frame for frame in cpp}
    swift_by_time = {round(frame.time, 6): frame for frame in swift}
    differences: list[TraceDifference] = []
    for time in sorted(cpp_by_time.keys() | swift_by_time.keys()):
        left, right = cpp_by_time.get(time), swift_by_time.get(time)
        if left is None or right is None:
            differences.append(TraceDifference(
                time, "voicing", left.frequency if left else None,
                right.frequency if right else None, None,
                left.confidence if left else None, right.confidence if right else None,
            ))
            continue
        cents = abs(1_200 * math.log2(right.frequency / left.frequency))
        if cents > frequency_tolerance_cents:
            differences.append(TraceDifference(
                time, "frequency", left.frequency, right.frequency, cents,
                left.confidence, right.confidence,
            ))
        elif abs(left.confidence - right.confidence) > confidence_tolerance:
            differences.append(TraceDifference(
                time, "confidence", left.frequency, right.frequency, cents,
                left.confidence, right.confidence,
            ))
    return differences


def export_swift_traces(jobs: list[dict[str, object]]) -> None:
    manifest = Path(jobs[0]["output"]).parent / "swift-parity-jobs.json"
    manifest.write_text(json.dumps(jobs, indent=2) + "\n", encoding="utf-8")
    environment = os.environ.copy()
    environment["KLARIVISION_VPM_PARITY_JOBS"] = str(manifest)
    environment.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/klarivision-swift-module-cache")
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", "/private/tmp/klarivision-swift-module-cache")
    subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", "VPMLikeParityTraceExportTests"],
        cwd=ROOT / "macos/KlariVision",
        env=environment,
        check=True,
    )


def markdown_report(report: dict[str, object]) -> str:
    lines = [
        "# VPM-benzeri C++ / Swift kare-iz paritesi",
        "",
        f"Durum: **{'GEÇTİ' if report['verified'] else 'KALDI'}**",
        "",
        "Ölçüt: sesli/sessiz kararları aynı; eşleşen sesli karelerde frekans "
        f"farkı ≤ {report['frequency_tolerance_cents']} sent ve güven farkı "
        f"≤ {report['confidence_tolerance']}.",
        "",
        "| Kaynak | C++ kare | Swift kare | Ayrışma | İlk ayrışma |",
        "|---|---:|---:|---:|---|",
    ]
    for case in report["cases"]:
        first = case["first_difference"]
        first_text = "—" if first is None else f"{first['time']:.6f} sn · {first['kind']}"
        lines.append(
            f"| {case['source']} | {case['cpp_frames']} | {case['swift_frames']} | "
            f"{case['difference_count']} | {first_text} |"
        )
    lines.extend(["", "Zaman damgaları kaynak analiz penceresinin merkezidir; izler sonradan kaydırılmaz.", ""])
    return "\n".join(lines)


def run(sources: list[Path], output: Path) -> dict[str, object]:
    output.parent.mkdir(parents=True, exist_ok=True)
    cases: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="klarivision-vpm-parity-") as temporary:
        temporary_root = Path(temporary)
        jobs: list[dict[str, object]] = []
        prepared: list[tuple[Path, np.ndarray, int, Path]] = []
        for index, source in enumerate(sources):
            audio, rate = read_wav(source)
            # AVAudioEngine supplies Float32 samples to the shipped Swift
            # path. Quantise once, then give those exact values to both sides;
            # otherwise a threshold-edge difference would be an input-format
            # difference rather than an implementation difference.
            shared_audio = np.asarray(audio, dtype=np.float32)
            float_input = temporary_root / f"input-{index}.f32"
            swift_output = temporary_root / f"swift-{index}.json"
            shared_audio.tofile(float_input)
            jobs.append({
                "input": str(float_input), "output": str(swift_output),
                "sampleRate": float(rate), "windowSize": LIVE_WINDOW,
                "hopSize": HOP, "minimumRMS": DEFAULT_MINIMUM_RMS,
            })
            prepared.append((source, shared_audio.astype(np.float64), rate, swift_output))
        export_swift_traces(jobs)

        for source, audio, rate, swift_output in prepared:
            cpp = [TraceFrame(*frame) for frame in vpm_frames(
                audio, rate, LIVE_WINDOW, HOP, DEFAULT_MINIMUM_RMS
            )]
            swift = [TraceFrame(**item) for item in json.loads(swift_output.read_text())]
            differences = compare_traces(cpp, swift)
            first_time = differences[0].time if differences else None
            context_radius = 10 * HOP / rate
            context = None if first_time is None else {
                "cpp": [asdict(frame) for frame in cpp if abs(frame.time - first_time) <= context_radius],
                "swift": [asdict(frame) for frame in swift if abs(frame.time - first_time) <= context_radius],
            }
            cases.append({
                "source": source.name,
                "cpp_frames": len(cpp),
                "swift_frames": len(swift),
                "difference_count": len(differences),
                "difference_kinds": {
                    kind: sum(item.kind == kind for item in differences)
                    for kind in ("voicing", "frequency", "confidence")
                },
                "first_difference": asdict(differences[0]) if differences else None,
                "first_difference_context": context,
            })

    report: dict[str, object] = {
        "schema": "klarivision-vpm-swift-cpp-trace-parity-v1",
        "verified": all(case["difference_count"] == 0 for case in cases),
        "window_samples": LIVE_WINDOW,
        "hop_samples": HOP,
        "minimum_rms": DEFAULT_MINIMUM_RMS,
        "frequency_tolerance_cents": 1.0,
        "confidence_tolerance": 0.01,
        "cases": cases,
    }
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output.with_suffix(".md").write_text(markdown_report(report), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="*", type=Path, default=list(DEFAULT_SOURCES))
    parser.add_argument(
        "--output", type=Path,
        default=ROOT / "outputs/vpm-swift-cpp-trace-parity.json",
    )
    arguments = parser.parse_args()
    missing = [source for source in arguments.sources if not source.exists()]
    if missing:
        parser.error("missing source(s): " + ", ".join(map(str, missing)))
    report = run(arguments.sources, arguments.output)
    print(markdown_report(report))
    return 0 if report["verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
