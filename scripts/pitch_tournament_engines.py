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
import json
import os
import resource
import subprocess
import tempfile
import time
import wave
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
# Mirrors kv_unified_lag_frames() / unified::kDefaultLagFrames: 8 hops x
# 512 / 48000 = 85.3 ms of fixed decision latency (raised from 5 / 53 ms by
# D-042, docs/DECISIONS.md, so the live fixed-lag buffer doubles as the
# series-coherence veto's look-ahead window). This value SHADOWS the C++
# default -- unified_frames() always passes it explicitly -- so it must be
# changed together with unified::kDefaultLagFrames or the tournament will
# silently measure a different engine than the one that ships.
UNIFIED_DEFAULT_LAG_FRAMES = 8


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


def unified_offline_frames(
    audio: np.ndarray,
    rate: int,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
) -> list[tuple[float, float, float]]:
    """Production adapter for the OFFLINE (Dinleme Modu) publication path.

    `unified_frames` above drives `UnifiedPitchSession::process_frame` -- the
    causal path, the one that ships in Çalma Modu. The offline profile is a
    different decoder over the same evidence (`PitchEngine::analyse` with
    PitchEngineProfile::offline_track), and measuring one tells you nothing
    about the other: an abstention rule keyed to `kOfflineAbstention`, or any
    evidence term that needs look-ahead, is structurally invisible to the
    causal trace. This adapter exists so the external claim gate can score the
    path Dinleme Modu actually uses.

    `minimum_rms` is accepted for signature parity with `unified_frames` but
    the offline CLI takes its gate from PitchEngineConfig's default; a
    non-default value is therefore rejected rather than silently ignored.

    The binary is `build/klarivision-pitch-track-cli`, overridable with
    KLARIVISION_PITCH_TRACK_CLI (the same variable cpp_engine.executable()
    honours) so a baseline build can be scored without touching the tree.
    """
    if minimum_rms != DEFAULT_MINIMUM_RMS:
        raise ValueError(
            "offline yol RMS kapısını CLI üzerinden almıyor; "
            "varsayılan dışında bir değer sessizce yok sayılırdı."
        )
    configured = os.environ.get("KLARIVISION_PITCH_TRACK_CLI")
    executable = Path(configured) if configured else ROOT / "build/klarivision-pitch-track-cli"
    if not executable.is_file():
        raise RuntimeError(f"Çevrimdışı motor bulunamadı: {executable}")

    with tempfile.TemporaryDirectory() as work:
        wav_path = Path(work) / "input.wav"
        json_path = Path(work) / "track.json"
        clipped = np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0)
        with wave.open(str(wav_path), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(rate)
            handle.writeframes((clipped * 32767.0).astype("<i2").tobytes())
        subprocess.run(
            [str(executable), str(wav_path), "--engine", "unified_v1", "--output", str(json_path)],
            check=True, capture_output=True, text=True,
        )
        payload = json.loads(json_path.read_text(encoding="utf-8"))

    return [
        (float(row["time_seconds"]), float(row["frequency_hz"]), float(row.get("confidence") or 0.0))
        for row in payload.get("frames", [])
        if row.get("voiced") and row.get("frequency_hz")
    ]


def run_engines(
    audio: np.ndarray,
    rate: int,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
    unified_lag_frames: list[int] | None = None,
    offline: bool = False,
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
    if offline:
        # The offline decoder has no fixed-lag publication delay to report:
        # it sees the whole file before publishing anything, so a decision
        # latency figure would be meaningless rather than zero-by-accident.
        definitions["unified_v1"] = (
            "Production C++ core offline_track profile (Dinleme Modu)",
            (lambda: unified_offline_frames(audio, rate, minimum_rms=minimum_rms)),
            0.0,
            0.0,
        )
        lags = []
    else:
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
