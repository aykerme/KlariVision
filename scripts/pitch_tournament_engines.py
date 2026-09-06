#!/usr/bin/env python3
"""Canonical benchmark adapter for KlariVision's live pitch engine.

Since D-039 there is one engine (unified_v1) and this module is its adapter.
The four legacy adapters -- the Python YIN mirror, the C++ v2 session, vpm_like
and hapt -- were removed with the engines themselves, along with the Swift/MPM
candidate mirrors and gap-bridging helpers that existed only to reproduce their
publication decisions.

All traces use the centre of the source analysis window as their timestamp.
Decision latency is metadata: it is never removed by shifting a trace.
"""

from __future__ import annotations

import csv
import resource
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from benchmark_live_pyin_alignment import DEFAULT_MINIMUM_RMS


ROOT = Path(__file__).resolve().parents[1]
# The shipped analysis geometry: 1536-sample window, 512-sample hop at 48 kHz,
# matching kv_pitch_contract_v1. These used to be imported from the live-YIN
# regression suite, which was removed with yin_v1 (D-039).
LIVE_WINDOW = 1_536
HOP = 512
# Mirrors kv_unified_lag_frames() / unified::kDefaultLagFrames: 5 hops x
# 512 / 48000 = 53 ms of fixed decision latency. This value SHADOWS the C++
# default -- unified_frames() always passes it explicitly -- so it must be
# changed together with unified::kDefaultLagFrames or the tournament will
# silently measure a different engine than the one that ships.
UNIFIED_DEFAULT_LAG_FRAMES = 5


@dataclass(frozen=True)
class EngineTrace:
    engine: str
    implementation: str
    frames: list[tuple[float, float, float]]
    runtime_seconds: float
    audio_seconds: float
    analysis_half_window_ms: float
    fixed_lag_ms: float

    @property
    def decision_latency_ms(self) -> float:
        return self.analysis_half_window_ms + self.fixed_lag_ms

    @property
    def realtime_factor(self) -> float:
        return self.runtime_seconds / max(self.audio_seconds, 1e-12)


def _compile_unified_runner(destination: Path) -> None:
    subprocess.run([
        "xcrun", "clang++", "-O3", "-std=c++20", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "core/include"),
        str(ROOT / "core/src/unified_pitch_session.cpp"),
        str(ROOT / "core/src/unified_track_decoder.cpp"),
        str(ROOT / "core/src/pyin_ladder.cpp"),
        str(ROOT / "core/src/frame_spectrum.cpp"),
        str(ROOT / "core/src/harmonic_evidence.cpp"),
        str(ROOT / "core/src/swipe_prime.cpp"),
        str(ROOT / "core/src/harmonic_arbitration.cpp"),
        str(ROOT / "core/src/harmonic_probe.cpp"),
        str(ROOT / "core/src/mpm.cpp"),
        str(ROOT / "core/tools/unified_trace.cpp"),
        "-framework", "Accelerate",
        "-o", str(destination),
    ], check=True)


def _unified_runner() -> Path:
    runner = Path(tempfile.gettempdir()) / "klarivision_unified_tournament_trace"
    sources = [
        ROOT / "core/include/klarivision/core/unified_pitch_session.hpp",
        ROOT / "core/include/klarivision/core/unified_track_decoder.hpp",
        ROOT / "core/include/klarivision/core/unified_pitch_constants.hpp",
        ROOT / "core/src/unified_pitch_session.cpp",
        ROOT / "core/src/unified_track_decoder.cpp",
        ROOT / "core/src/pyin_ladder.cpp",
        ROOT / "core/src/frame_spectrum.cpp",
        ROOT / "core/src/harmonic_evidence.cpp",
        ROOT / "core/src/swipe_prime.cpp",
        ROOT / "core/src/harmonic_arbitration.cpp",
        ROOT / "core/src/harmonic_probe.cpp",
        ROOT / "core/src/mpm.cpp",
        ROOT / "core/tools/unified_trace.cpp",
    ]
    if not runner.exists() or runner.stat().st_mtime < max(source.stat().st_mtime for source in sources):
        _compile_unified_runner(runner)
    return runner


def unified_frames(
    audio: np.ndarray,
    rate: int,
    window: int = LIVE_WINDOW,
    hop: int = HOP,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
    lag_frames: int = UNIFIED_DEFAULT_LAG_FRAMES,
) -> list[tuple[float, float, float]]:
    """Production adapter: run the canonical shared C++ unified_v1 session.

    Self-contained like v2: unified_trace already reports the correct
    (source-time) timestamp and its own decision to stay silent, so no
    half-window shift and no gap-bridging helper is applied here.
    """
    runner = _unified_runner()
    with tempfile.NamedTemporaryFile(suffix=".f32") as raw:
        np.asarray(audio, dtype=np.float32).tofile(raw.name)
        completed = subprocess.run([
            str(runner), raw.name, str(rate), str(window), str(hop),
            str(minimum_rms), str(lag_frames),
        ], check=True, capture_output=True, text=True)
    rows = csv.DictReader(completed.stdout.splitlines())
    return [
        (float(row["time_seconds"]), float(row["frequency_hz"]), float(row["confidence"]))
        for row in rows
    ]


def run_engines(
    audio: np.ndarray,
    rate: int,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
    unified_lag_frames: list[int] | None = None,
) -> dict[str, EngineTrace]:
    # Compilation is setup, not pitch-analysis CPU time.
    _unified_runner()
    audio_seconds = len(audio) / rate
    # (implementation, operation, fixed_lag_ms, analysis_half_window_ms)
    definitions: dict[str, tuple[str, object, float, float]] = {}
    # unified_v1's own fixed-lag decoder already IS its whole constant decision
    # latency (see unified::kDefaultLagFrames's doc comment): unlike the other
    # engines above, no separate half-window term is added on top, so
    # decision_latency_ms == lag_frames * HOP / rate * 1000 exactly (53.3 ms
    # for the production default of 5 hops).
    lags = unified_lag_frames if unified_lag_frames else [UNIFIED_DEFAULT_LAG_FRAMES]
    for lag in lags:
        key = "unified_v1" if len(lags) == 1 and unified_lag_frames is None else f"unified_v1@lag{lag}"
        definitions[key] = (
            "Production C++ core unified_pitch_session.cpp",
            (lambda lag=lag: unified_frames(audio, rate, minimum_rms=minimum_rms, lag_frames=lag)),
            lag * HOP / rate * 1_000,
            0.0,
        )
    traces: dict[str, EngineTrace] = {}
    for name, (implementation, operation, fixed_lag_ms, analysis_half_window_ms) in definitions.items():
        started = time.process_time()
        children_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        frames = operation()
        children_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        runtime = (
            time.process_time() - started
            + children_after.ru_utime - children_before.ru_utime
            + children_after.ru_stime - children_before.ru_stime
        )
        traces[name] = EngineTrace(
            name, implementation, frames, runtime, audio_seconds, analysis_half_window_ms, fixed_lag_ms
        )
    return traces
