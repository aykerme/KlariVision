from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import pytest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from generate_pitch_tournament_holdout_v1 import write_holdout  # noqa: E402
from generate_pitch_tournament_holdout_v2 import write_holdout as write_holdout_v2  # noqa: E402
from generate_pitch_tournament_holdout_v3 import write_holdout as write_holdout_v3  # noqa: E402
from generate_pitch_tournament_holdout_v4 import write_holdout as write_holdout_v4  # noqa: E402
from generate_pitch_tournament_holdout_v5 import write_holdout as write_holdout_v5  # noqa: E402
from benchmark_live_pyin_alignment import centered_rms, signal_is_eligible  # noqa: E402
from pitch_tournament_engines import (  # noqa: E402
    EngineTrace,
    _bridge_short_v2_gaps,
    _v2_is_publishable,
    hapt_frames,
    v2_frames,
    vpm_frames,
)
from run_pitch_engine_tournament import (  # noqa: E402
    deterministic_fingerprint,
    effective_manifest_for_signal,
    harmonic_class,
    legacy_manifest_with_truth,
    read_wav,
    score_trace,
    selection,
    tournament_groups,
    verify_inventory,
)
from pitch_error_metrics import ObservedFrame, ReferenceFrame, score_frames  # noqa: E402
from run_pitch_regression_suite import LIVE_WINDOW, causal_yin_frames  # noqa: E402


def test_frozen_holdout_is_byte_deterministic(tmp_path: Path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    manifest_a = write_holdout(first)
    manifest_b = write_holdout(second)
    assert manifest_a == manifest_b
    for filename in manifest_a["variants"]:
        assert (first / filename).read_bytes() == (second / filename).read_bytes()


def test_harmonic_classification_is_signed() -> None:
    assert harmonic_class(-1200.0) == "1/2x"
    assert harmonic_class(1200.0) == "2x"
    assert harmonic_class(1200 * np.log2(3)) == "3x"
    assert harmonic_class(35.0) is None


def test_five_way_accounting_is_exhaustive_and_consumes_frames_once() -> None:
    result = score_frames(
        [ReferenceFrame(0, None), ReferenceFrame(.01, 220), ReferenceFrame(.02, 220), ReferenceFrame(.03, 220)],
        [ObservedFrame(0, 220), ObservedFrame(.01, 220), ObservedFrame(.02, 440)],
        tolerance_seconds=.006,
    )
    assert result["false_voiced_frames"] == 1
    assert result["correct_pitch_frames"] == 1
    assert result["harmonic_error_frames"] == 1
    assert result["missing_voiced_frames"] == 1
    assert result["reference_voiced_frames"] == 3


def test_fifty_cent_boundary_is_correct() -> None:
    target = 220.0
    exact = target * 2 ** (50 / 1200)
    outside = target * 2 ** (50.001 / 1200)
    assert score_frames([ReferenceFrame(0, target)], [ObservedFrame(0, exact)], tolerance_seconds=.001)["correct_pitch_frames"] == 1
    assert score_frames([ReferenceFrame(0, target)], [ObservedFrame(0, outside)], tolerance_seconds=.001)["non_harmonic_error_frames"] == 1


def test_shared_rms_gate_is_strictly_below_threshold() -> None:
    below = np.array([0.0149, -0.0149] * 32)
    equal = np.array([0.015, -0.015] * 32)
    above = np.array([0.0151, -0.0151] * 32)
    assert centered_rms(equal) == pytest.approx(0.015)
    assert not signal_is_eligible(below)
    assert signal_is_eligible(equal)
    assert signal_is_eligible(above)


def test_low_signal_truth_is_blank_and_cannot_be_bridged() -> None:
    manifest = {
        "ground_truth": [
            {"time_seconds": 0.01, "frequency_hz": 220.0},
            {"time_seconds": 0.03, "frequency_hz": 220.0},
        ],
        "sections": [],
    }
    audio = np.array([0.2, -0.2] * 10 + [0.001, -0.001] * 10, dtype=np.float64)
    effective = effective_manifest_for_signal(
        manifest, audio, rate=1_000, minimum_rms=0.015, window=4
    )
    assert effective["ground_truth"][0]["frequency_hz"] == 220.0
    assert effective["ground_truth"][1]["frequency_hz"] is None
    bridged = _bridge_short_v2_gaps(
        [(0.0, 220.0, 0.8), (0.03, 220.0, 0.8)],
        0.01,
        {0.01},
    )
    assert [round(frame[0], 2) for frame in bridged] == [0.0, 0.02, 0.03]


def test_near_pitch_is_raw_non_harmonic_but_not_serious() -> None:
    target = 220.0
    near = target * 2 ** (75 / 1200)
    result = score_frames(
        [ReferenceFrame(index * .01, target) for index in range(3)],
        [ObservedFrame(index * .01, near) for index in range(3)],
        tolerance_seconds=.001,
    )
    assert result["non_harmonic_error_frames"] == 3
    assert result["near_pitch_frames"] == 3
    assert result["serious_total_error_frames"] == 0


def test_three_frame_error_is_serious_but_short_or_transition_error_is_tolerated() -> None:
    target = 220.0
    octave = target * 2
    serious = score_frames(
        [ReferenceFrame(index * .01, target) for index in range(3)],
        [ObservedFrame(index * .01, octave) for index in range(3)],
        tolerance_seconds=.001,
    )
    assert serious["serious_harmonic_error_frames"] == 3
    assert serious["serious_total_error_frames"] == 3
    transient = score_frames(
        [ReferenceFrame(index * .01, target) for index in range(2)],
        [ObservedFrame(index * .01, octave) for index in range(2)],
        tolerance_seconds=.001,
    )
    assert transient["transient_tolerated_frames"] == 2
    transition = score_frames(
        [ReferenceFrame(index * .01, target) for index in range(3)],
        [ObservedFrame(index * .01, octave) for index in range(3)],
        tolerance_seconds=.001,
        transition_times=[.01],
    )
    assert transition["transition_tolerated_frames"] == 3
    assert transition["serious_total_error_frames"] == 0


def test_mismatched_time_grids_do_not_create_serious_missing_voiced() -> None:
    result = score_frames(
        [ReferenceFrame(index * .01, 220.0) for index in range(100)],
        [ObservedFrame(index / 93.75, 220.0) for index in range(94)],
        tolerance_seconds=.006,
    )
    assert result["missing_voiced_frames"] > 0
    assert result["serious_missing_voiced_frames"] == 0


def test_scoring_does_not_search_for_a_global_time_offset() -> None:
    truth = [
        {"time_seconds": round(index * 0.01, 2), "frequency_hz": 220.0}
        for index in range(60)
    ]
    manifest = {
        "ground_truth": truth,
        "sections": [{
            "label": "anchor", "kind": "anchor", "frequency_hz": 220.0,
            "start_seconds": 0.0, "end_seconds": 0.6,
        }],
    }
    exact_frames = [(index * 512 / 48_000, 220.0, 1.0) for index in range(57)]
    shifted_frames = [(time + 0.08, frequency, confidence) for time, frequency, confidence in exact_frames]
    exact = EngineTrace("test", "test", exact_frames, 0.01, 0.6, 16.0, 0.0)
    shifted = EngineTrace("test", "test", shifted_frames, 0.01, 0.6, 16.0, 0.0)
    assert score_trace(exact, manifest, 48_000)["correct_pitch_frames"] > score_trace(shifted, manifest, 48_000)["correct_pitch_frames"]


def _result(engine: str, source: str, total: int) -> dict[str, object]:
    return {
        "engine": engine,
        "source": source,
        "reference_voiced_frames": 100,
        "reference_silent_frames": 20,
        "false_voiced_frames": 0,
        "missing_voiced_frames": total,
        "correct_pitch_frames": 100 - total,
        "correct_pitch_absolute_cents_sum": 10.0,
        "correct_pitch_mean_absolute_cents": 0.1,
        "harmonic_error_frames": 0,
        "non_harmonic_error_frames": 0,
        "total_error_frames": total,
        "latency": {"decision_latency_ms": 16.0},
        "performance": {"cpu_realtime_factor": 0.1},
    }


def test_selection_veto_keeps_yin_when_candidate_hides_voiced_frames() -> None:
    rows = [
        _result("yin_v1", "holdout.wav", 1),
        _result("pitch_engine_v2", "holdout.wav", 5),
        _result("vpm_like", "holdout.wav", 0),
        _result("hapt_v1", "holdout.wav", 0),
    ]
    decision = selection(rows)
    assert decision["default_engine"] == "yin_v1"
    assert decision["decisions"]["pitch_engine_v2"]["vetoes"]


def test_selection_ranks_serious_then_non_serious_without_veto_affecting_winner() -> None:
    rows = [
        _result("yin_v1", "holdout.wav", 8),
        _result("pitch_engine_v2", "holdout.wav", 9),
        _result("vpm_like", "holdout.wav", 10),
        _result("hapt_v1", "holdout.wav", 8),
    ]
    rows[0].update({"serious_total_error_frames": 3, "serious_missing_voiced_frames": 3})
    rows[1].update({"serious_total_error_frames": 2, "serious_missing_voiced_frames": 2})
    rows[2].update({
        "serious_total_error_frames": 2,
        "serious_missing_voiced_frames": 1,
        "serious_false_voiced_frames": 1,
        "false_voiced_frames": 1,
    })
    # VPM has the same serious total as V2 but fewer raw remainder errors.
    rows[2]["total_error_frames"] = 4
    rows[2]["missing_voiced_frames"] = 4
    # HAPT ties yin's worst-case serious total so it cannot outrank vpm_like.
    rows[3].update({"serious_total_error_frames": 3, "serious_missing_voiced_frames": 3})
    decision = selection(rows, rows)
    assert decision["benchmark_winner"] == "vpm_like"
    assert decision["decisions"]["vpm_like"]["vetoes"]
    assert decision["default_engine"] == "yin_v1"


def test_selection_uses_cents_then_latency_after_both_error_totals_tie() -> None:
    rows = [
        _result(engine, "holdout.wav", 2)
        for engine in ("yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1")
    ]
    for row in rows:
        row.update({"serious_total_error_frames": 1, "serious_missing_voiced_frames": 1})
    rows[0].update({"correct_pitch_mean_absolute_cents": 4.0, "correct_pitch_absolute_cents_sum": 392.0})
    rows[1].update({"correct_pitch_mean_absolute_cents": 3.0, "correct_pitch_absolute_cents_sum": 294.0})
    rows[2].update({"correct_pitch_mean_absolute_cents": 3.0, "correct_pitch_absolute_cents_sum": 294.0, "latency": {"decision_latency_ms": 8.0}})
    # HAPT sits out of contention here (worse serious total than the tied
    # three) so this stays a pure cents-then-latency tie-break test.
    rows[3].update({"serious_total_error_frames": 2})
    assert selection(rows, rows)["benchmark_winner"] == "vpm_like"


def test_legacy_truth_covers_silence_constant_vibrato_glide_and_grace() -> None:
    manifest = legacy_manifest_with_truth(ROOT / "data/benchmarks/canli_pitch_referans_v1.json")
    truth = {row["time_seconds"]: row["frequency_hz"] for row in manifest["ground_truth"]}
    assert truth[0.0] is None
    assert truth[1.0] == 220.0
    assert truth[7.25] != 220.0
    assert truth[9.9] == 220.0
    assert truth[16.8] == 220.0
    assert truth[16.87] == pytest.approx(195.997718, abs=1e-5)


def test_legacy_full_range_truth_covers_note_gap_and_glide() -> None:
    manifest = legacy_manifest_with_truth(ROOT / "data/benchmarks/clarinet_full_range_pitch_benchmark_v1.json")
    truth = {row["time_seconds"]: row["frequency_hz"] for row in manifest["ground_truth"]}
    assert truth[0.0] == pytest.approx(82.4069, abs=1e-5)
    assert truth[0.62] is None
    assert truth[38.88] == pytest.approx(82.4069, abs=1e-5)
    assert truth[42.87] > 1_300


def test_tournament_inventory_is_exactly_all_synthetic_wavs() -> None:
    sources: list[str] = []
    for group, manifests, _ in tournament_groups():
        for path in manifests:
            manifest = legacy_manifest_with_truth(path) if group == "legacy_diagnostics" else json.loads(path.read_text())
            sources.extend(f"data/benchmarks/{name}" for name in manifest["variants"])
    missing = [source for source in sources if not (ROOT / source).is_file()]
    if missing:
        pytest.skip(
            "Yerel sentetik WAV corpus'u eksik; fixture gerektiren turnuva denetimi atlandı "
            f"({len(missing)} dosya)."
        )
    inventory = verify_inventory(sources)
    assert len(inventory["used_synthetic_wavs"]) == 26
    assert inventory["excluded_real_wavs"] == [
        "data/benchmarks/klarnet_gercek_gecis_vibrato_v1.wav",
        "data/benchmarks/klarnet_gercek_sabit_re3_v1.wav",
    ]


def test_v5_holdout_is_byte_deterministic(tmp_path: Path) -> None:
    first, second = tmp_path / "first", tmp_path / "second"
    manifest_a, manifest_b = write_holdout_v5(first), write_holdout_v5(second)
    assert manifest_a == manifest_b
    for filename, digest in manifest_a["sha256"].items():
        assert hashlib.sha256((first / filename).read_bytes()).hexdigest() == digest
        assert (first / filename).read_bytes() == (second / filename).read_bytes()


def test_deterministic_fingerprint_ignores_runtime_observation() -> None:
    payload = {
        "benchmark_groups": [{"cases": [{"engines": [{"performance": {"cpu_seconds": 1.0}, "score": 4}]}]}],
        "selection": {"winner": "yin_v1"},
    }
    changed = copy.deepcopy(payload)
    changed["benchmark_groups"][0]["cases"][0]["engines"][0]["performance"]["cpu_seconds"] = 9.0
    assert deterministic_fingerprint(payload) == deterministic_fingerprint(changed)


def test_v2_high_register_publication_matches_swift_contract() -> None:
    assert _v2_is_publishable(880.0, 0.70, False)
    assert _v2_is_publishable(1100.0, 0.70, True)
    assert not _v2_is_publishable(1100.0, 0.70, False)
    assert not _v2_is_publishable(880.0, 0.699, True)


def test_yin_v1_has_no_serious_error_on_high_register_holdout_v2(tmp_path: Path) -> None:
    manifest = write_holdout_v2(tmp_path)
    for filename in manifest["variants"]:
        audio, rate = read_wav(tmp_path / filename)
        frames = [(*frame, 1.0) for frame in causal_yin_frames(audio, rate)]
        trace = EngineTrace(
            "yin_v1",
            "Python mirror of shipped Swift YIN v1",
            frames,
            0.0,
            len(audio) / rate,
            LIVE_WINDOW / (2 * rate) * 1_000,
            0.0,
        )
        result = score_trace(
            trace, effective_manifest_for_signal(manifest, audio, rate), rate
        )
        assert result["serious_false_voiced_frames"] == 0, filename
        assert result["serious_missing_voiced_frames"] == 0, filename
        assert result["serious_harmonic_error_frames"] == 0, filename
        assert result["serious_non_harmonic_error_frames"] == 0, filename
        assert result["serious_total_error_frames"] == 0, filename


@pytest.mark.parametrize(
    ("writer", "label"),
    [(write_holdout, "v1"), (write_holdout_v3, "v3")],
)
def test_yin_v1_has_no_serious_error_on_additional_holdouts(
    tmp_path: Path,
    writer: object,
    label: str,
) -> None:
    manifest = writer(tmp_path / label)  # type: ignore[operator]
    for filename in manifest["variants"]:
        audio, rate = read_wav(tmp_path / label / filename)
        frames = [(*frame, 1.0) for frame in causal_yin_frames(audio, rate)]
        trace = EngineTrace(
            "yin_v1", "Python mirror of shipped Swift YIN v1", frames,
            0.0, len(audio) / rate, LIVE_WINDOW / (2 * rate) * 1_000, 0.0,
        )
        result = score_trace(
            trace, effective_manifest_for_signal(manifest, audio, rate), rate
        )
        assert result["serious_total_error_frames"] == 0, filename


@pytest.mark.parametrize(
    ("writer", "label"),
    [(write_holdout, "v1"), (write_holdout_v2, "v2"), (write_holdout_v3, "v3")],
)
def test_v2_has_no_serious_error_on_yin_holdouts(
    tmp_path: Path,
    writer: object,
    label: str,
) -> None:
    manifest = writer(tmp_path / label)  # type: ignore[operator]
    for filename in manifest["variants"]:
        audio, rate = read_wav(tmp_path / label / filename)
        trace = EngineTrace(
            "pitch_engine_v2", "Python mirror of shipped Swift V2", v2_frames(audio, rate),
            0.0, len(audio) / rate, LIVE_WINDOW / (2 * rate) * 1_000, 5 * 512 / rate * 1_000,
        )
        result = score_trace(
            trace, effective_manifest_for_signal(manifest, audio, rate), rate
        )
        assert result["serious_total_error_frames"] == 0, filename


@pytest.mark.parametrize(
    ("writer", "label"),
    [
        (write_holdout, "v1"), (write_holdout_v2, "v2"), (write_holdout_v3, "v3"),
        (write_holdout_v4, "v4"), (write_holdout_v5, "v5"),
    ],
)
def test_hapt_has_no_serious_error_on_all_holdouts(
    tmp_path: Path,
    writer: object,
    label: str,
) -> None:
    manifest = writer(tmp_path / label)  # type: ignore[operator]
    for filename in manifest["variants"]:
        audio, rate = read_wav(tmp_path / label / filename)
        trace = EngineTrace(
            "hapt_v1", "Production C++ HAPT core", hapt_frames(audio, rate),
            0.0, len(audio) / rate, LIVE_WINDOW / (2 * rate) * 1_000, 0.0,
        )
        result = score_trace(
            trace, effective_manifest_for_signal(manifest, audio, rate), rate
        )
        assert result["serious_total_error_frames"] == 0, filename


@pytest.mark.parametrize(
    ("writer", "label"),
    [
        (write_holdout, "v1"), (write_holdout_v2, "v2"), (write_holdout_v3, "v3"),
        (write_holdout_v4, "v4"), (write_holdout_v5, "v5"),
    ],
)
def test_vpm_like_has_no_serious_error_on_all_holdouts(
    tmp_path: Path,
    writer: object,
    label: str,
) -> None:
    manifest = writer(tmp_path / label)  # type: ignore[operator]
    for filename in manifest["variants"]:
        audio, rate = read_wav(tmp_path / label / filename)
        trace = EngineTrace(
            "vpm_like", "Production C++ VPM-like core", vpm_frames(audio, rate),
            0.0, len(audio) / rate, LIVE_WINDOW / (2 * rate) * 1_000, 0.0,
        )
        result = score_trace(
            trace, effective_manifest_for_signal(manifest, audio, rate), rate
        )
        assert result["serious_total_error_frames"] == 0, filename
