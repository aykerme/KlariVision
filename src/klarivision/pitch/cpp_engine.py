"""Production bridge for the portable C++ pitch engines."""

from __future__ import annotations

import os
import json
import subprocess
from pathlib import Path

from ..runtime_paths import resource_root


ENGINES = frozenset({"yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1", "unified_v1"})
# Keep the public offline_track_v1 JSON contract stable while preventing a
# result made by an older decision pipeline from being reused after an engine
# behaviour change.
# NOTE: this string must match the hand-duplicated literal at
# core/tools/pitch_track_cli.cpp:~200 ("implementation_revision") exactly.
# There is no compile-time link between the two.
OFFLINE_TRACK_REVISION = "offline-unified-path-r1"
OFFLINE_TRACK_PROFILE = "offline_track_v1"
PITCH_C_ABI_VERSION = 1
PCM_SAMPLE_RATE_HZ = 48_000
PCM_WINDOW_SAMPLES = 1_536
PCM_HOP_SAMPLES = 512
# Mirrors kv_unified_lag_frames() from the C ABI — unified_v1's own decision
# latency, separate from kv_pitch_contract_v1.v2_fixed_lag_frames (v2 only).
UNIFIED_DEFAULT_LAG_FRAMES = 15


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


def extract(wav: Path, engine: str, output: Path) -> None:
    if engine not in ENGINES:
        raise ValueError("Geçersiz C++ pitch motoru seçimi.")
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(executable()), str(wav), "--engine", engine, "--output", str(output)],
        check=True,
        capture_output=True,
        text=True,
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
        raise RuntimeError("C++ pitch motoru üç kullanıcı motorunu sunmuyor.")
    # unified_v1's decision latency lives outside kv_pitch_contract_v1 (that
    # struct is frozen and its v2_fixed_lag_frames field describes v2 alone),
    # so it is mirrored here as its own value instead of the `expected` dict.
    if payload.get("unified_lag_frames") != UNIFIED_DEFAULT_LAG_FRAMES:
        raise RuntimeError("C++ pitch motoru unified_v1 gecikmesi beklenen değerle uyuşmuyor.")
    return payload
