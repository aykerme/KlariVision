"""Production bridge for the portable C++ pitch engines."""

from __future__ import annotations

import os
import json
import subprocess
import sys
from pathlib import Path

from ..runtime_paths import resource_root


# The engines this build can run. D-039 removed yin_v1, pitch_engine_v2,
# vpm_like and hapt_v1; their C ABI ids stay reserved but no longer resolve to
# anything, so naming one here (or on the CLI) is an error rather than a
# request that quietly gets served by unified_v1.
ENGINES = frozenset({"unified_v1"})
# Engine ids that may still appear in a stored study, a cached result or an
# older viewer. They are recognised for *reading* only.
REMOVED_ENGINES = frozenset({"yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1"})
# Every id whose cached result carries the offline_track_v1 filename shape,
# including the removed engines: an analysis produced before D-039 must stay
# readable, so the *naming* of past results has to outlive the engines that
# produced them. Use this to find a result; use ENGINES to decide what may
# still be run.
OFFLINE_TRACK_ENGINES = ENGINES | REMOVED_ENGINES
# Keep the public offline_track_v1 JSON contract stable while preventing a
# result made by an older decision pipeline from being reused after an engine
# behaviour change.
# NOTE: this string must match the hand-duplicated literal at
# core/tools/pitch_track_cli.cpp:~200 ("implementation_revision") exactly.
# There is no compile-time link between the two.
OFFLINE_TRACK_REVISION = "offline-unified-path-r3"
OFFLINE_TRACK_PROFILE = "offline_track_v1"
PITCH_C_ABI_VERSION = 1
PCM_SAMPLE_RATE_HZ = 48_000
PCM_WINDOW_SAMPLES = 1_536
PCM_HOP_SAMPLES = 512
# Mirrors kv_unified_lag_frames() from the C ABI — unified_v1's own decision
# latency, separate from kv_pitch_contract_v1.v2_fixed_lag_frames, which is a
# reserved leftover of the removed pitch_engine_v2.
# D-042 (docs/DECISIONS.md): raised from 5 (53 ms) to 8 (85.3 ms) so the live
# path's fixed-lag buffer doubles as the series-coherence veto's look-ahead
# window. Must match unified::kDefaultLagFrames in
# core/include/klarivision/core/unified_pitch_constants.hpp — the contract
# validation below fails loudly if this drifts from the C++ default.
UNIFIED_DEFAULT_LAG_FRAMES = 8


def executable() -> Path:
    configured = os.environ.get("KLARIVISION_PITCH_TRACK_CLI")
    candidates = [
        Path(configured) if configured else None,
        resource_root() / "tools" / "klarivision-pitch-track-cli",
        # PyInstaller interprets the --add-binary destination as a directory.
        # Beta build 3 accidentally used the executable name as that directory,
        # producing tools/<name>/<name>. Keep this lookup so those bundles can
        # still analyse media after the Python bridge is refreshed.
        resource_root() / "tools" / "klarivision-pitch-track-cli" / "klarivision-pitch-track-cli",
        resource_root() / "build" / "klarivision-pitch-track-cli",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError("Taşınabilir C++ pitch motoru bulunamadı. Beta paketi veya build/klarivision-pitch-track-cli dosyasını kontrol et.")


def extract(wav: Path, engine: str, output: Path, baseline: bool = False) -> None:
    """Run the portable C++ CLI to produce an offline_track_v1 JSON track.

    ``baseline`` mirrors the CLI's optional ``--baseline`` flag: it makes the
    CLI additionally run the causal pass and fill in ``causal_baseline`` /
    ``offline_changes``, roughly doubling the CLI's runtime. It defaults to
    False so the normal Study/local_app.py path (a real user's file) takes
    the fast, single-pass route; only synthetic-validation tooling that
    actually reads those two fields needs to opt in.
    """
    if engine in REMOVED_ENGINES:
        raise ValueError(
            f"{engine} motoru kaldırıldı (D-039); yalnız unified_v1 çalıştırılabilir."
        )
    if engine not in ENGINES:
        raise ValueError("Geçersiz C++ pitch motoru seçimi.")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [str(executable()), str(wav), "--engine", engine, "--output", str(output)]
    if baseline:
        command.append("--baseline")

    # The CLI reports KV-PROGRESS lines (see core/tools/pitch_track_cli.cpp)
    # on stderr as it runs. capture_output=True would buffer that entire
    # stream and only hand it back after the process exits -- exactly the
    # progress visibility this function needs to forward live. Stream stderr
    # line by line instead: KV-PROGRESS lines go straight to our own stderr
    # (so a parent process piping *our* stderr, like local_app.py running
    # under KlariVisionApp.swift, sees them immediately); every other line is
    # kept so a failure can still report the CLI's actual error text.
    process = subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    other_lines: list[str] = []
    assert process.stderr is not None
    for line in process.stderr:
        if line.startswith("KV-PROGRESS "):
            sys.stderr.write(line if line.endswith("\n") else line + "\n")
            sys.stderr.flush()
        else:
            other_lines.append(line)
    process.wait()
    if process.returncode != 0:
        raise subprocess.CalledProcessError(
            process.returncode, command, output=None, stderr="".join(other_lines)
        )


def contract() -> dict[str, object]:
    """Read and validate the C++ CLI projection of the stable C ABI v1."""
    completed = subprocess.run(
        [str(executable()), "--contract"], check=True, capture_output=True, text=True
    )
    payload = json.loads(completed.stdout)
    expected = {
        "abi_version": PITCH_C_ABI_VERSION,
        "profile": OFFLINE_TRACK_PROFILE,
        "sample_rate_hz": PCM_SAMPLE_RATE_HZ,
        "window_size": PCM_WINDOW_SAMPLES,
        "hop_size": PCM_HOP_SAMPLES,
    }
    if any(payload.get(key) != value for key, value in expected.items()):
        raise RuntimeError("C++ pitch motoru v1 sözleşmesiyle uyumlu değil.")
    if set(payload.get("engines", [])) != ENGINES:
        raise RuntimeError("C++ pitch motoru beklenen motor kümesini sunmuyor.")
    # unified_v1's decision latency lives outside kv_pitch_contract_v1 (that
    # struct is frozen and its v2_fixed_lag_frames field describes v2 alone),
    # so it is mirrored here as its own value instead of the `expected` dict.
    if payload.get("unified_lag_frames") != UNIFIED_DEFAULT_LAG_FRAMES:
        raise RuntimeError("C++ pitch motoru unified_v1 gecikmesi beklenen değerle uyuşmuyor.")
    return payload
