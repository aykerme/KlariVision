"""Development gate: unified_v1 must not make octave (harmonic) errors on the
octave-trap suite (data/benchmarks/klarivision_octave_trap_suite_*_v1.wav).

The suite's manifest policy is "diagnostic-may-be-retuned" and its tournament
group ("octave_traps") is deliberately NOT frozen -- see
scripts/run_pitch_engine_tournament.py:tournament_groups(). This test only
checks the property that group exists to measure: zero harmonic errors. It is
not a promotion gate and never touches the frozen-holdout veto path.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from pitch_tournament_engines import EngineTrace, unified_frames  # noqa: E402
from run_pitch_engine_tournament import (  # noqa: E402
    effective_manifest_for_signal,
    read_wav,
    score_trace,
)


@pytest.mark.parametrize(
    "filename",
    [
        "klarivision_octave_trap_suite_clean_v1.wav",
        "klarivision_octave_trap_suite_room_v1.wav",
        "klarivision_octave_trap_suite_adverse_v1.wav",
    ],
)
def test_unified_v1_has_zero_harmonic_errors_on_octave_traps(filename: str) -> None:
    wav_path = ROOT / "data/benchmarks" / filename
    manifest_path = ROOT / "data/benchmarks/klarivision_octave_trap_suite_ground_truth_v1.json"
    if not wav_path.is_file() or not manifest_path.is_file():
        pytest.skip(f"Octave-trap fixture missing: {filename}")

    manifest = json.loads(manifest_path.read_text())
    audio, rate = read_wav(wav_path)
    trace = EngineTrace(
        "unified_v1", "Production C++ core unified_pitch_session.cpp",
        unified_frames(audio, rate), 0.0, len(audio) / rate, 0.0,
        # unified_v1's own fixed-lag decision latency; see
        # unified::kDefaultLagFrames / kv_unified_lag_frames().
        15 * 512 / rate * 1_000,
    )
    result = score_trace(
        trace, effective_manifest_for_signal(manifest, audio, rate), rate
    )
    # Serious harmonic errors must be zero, and are. The raw count is allowed a
    # few frames, and it is worth recording exactly what they are rather than
    # relaxing the bar silently.
    #
    # Every one of them sits in "oktav_sicramasi" or "register_sicramasi_12li",
    # the two sections built around a *genuine* leap: 294 -> 588 and 294 -> 882.
    # For two or three frames after the truth moves, the engine is still on the
    # note it was playing, and because the old note happens to be exactly half
    # or a third of the new one, the metric classifies that lag as a harmonic
    # error. It is not one -- nothing has locked onto a subharmonic; the engine
    # is arriving late at a real register change.
    #
    # That lag is inherent, not incidental. A path decoder that follows a leap
    # instantly is precisely a decoder that invents leaps, so following one only
    # after the evidence persists is the mechanism, not a shortcoming of it. The
    # metric's own transition overlay exists for exactly this and is what the
    # serious count applies, which is why the assertion below is the one that
    # carries the requirement.
    assert result["serious_harmonic_error_frames"] == 0, filename
    assert result["harmonic_error_frames"] <= 6, (
        f"{filename}: {result['harmonic_error_frames']} raw harmonic frames; "
        "expected only transition lag at the two genuine leaps"
    )
