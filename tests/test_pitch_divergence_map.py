"""Motor ayrışma haritasının saf mantığı — ses veya C++ ikilisi gerektirmez."""

from __future__ import annotations

import importlib.util
import math
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))

_spec = importlib.util.spec_from_file_location(
    "pitch_engine_divergence_map", ROOT / "scripts" / "pitch_engine_divergence_map.py"
)
dmap = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(dmap)


HOP = 512 / 48_000  # 10.667 ms — motorların ortak kare adımı


def _grid(count: int, start: float = 0.0) -> list[float]:
    return [round(start + index * HOP, dmap.TIME_DECIMALS) for index in range(count)]


def _flat(times: list[float], hz: float) -> dict[float, float]:
    return {time: hz for time in times}


def test_agreeing_engines_produce_no_events() -> None:
    times = _grid(40)
    tracks = {name: _flat(times, 220.0) for name in dmap.ENGINE_ORDER}
    events = dmap.build_events(tracks, [], cents_threshold=50.0)
    assert all(events[name] == [] for name in dmap.ENGINE_ORDER)


def test_octave_outlier_is_attributed_and_labelled() -> None:
    times = _grid(40)
    tracks = {name: _flat(times, 220.0) for name in dmap.ENGINE_ORDER}
    tracks["vpm_like"][times[20]] = 440.0

    events = dmap.build_events(tracks, [], cents_threshold=50.0)

    assert [event["time_seconds"] for event in events["vpm_like"]] == [round(times[20], 3)]
    only = events["vpm_like"][0]
    assert only["kind"] == "harmonik"
    assert only["harmonic_label"] == "2x"
    assert only["cents_from_consensus"] == pytest.approx(1200.0, abs=0.5)
    # Diğer motorlar suçlanmaz.
    assert all(events[name] == [] for name in dmap.ENGINE_ORDER if name != "vpm_like")


def test_two_engines_diverging_is_not_attributable() -> None:
    times = _grid(40)
    tracks = {name: _flat(times, 220.0) for name in dmap.ENGINE_ORDER}
    tracks["vpm_like"][times[20]] = 440.0
    tracks["hapt_v1"][times[20]] = 110.0

    events = dmap.build_events(tracks, [], cents_threshold=50.0)
    kinds = {name: [event["kind"] for event in events[name]] for name in dmap.ENGINE_ORDER}
    assert kinds["vpm_like"] == ["ortak"]
    assert kinds["hapt_v1"] == ["ortak"]


def test_small_deviation_in_a_fast_glide_is_classified_as_window_blur() -> None:
    # Hızlı bir glissando: kare başına ~13 sent, yani ~1250 sent/sn.
    times = _grid(40)
    tracks = {
        name: {time: 220.0 * 2 ** (index * 13 / 1200) for index, time in enumerate(times)}
        for name in dmap.ENGINE_ORDER
    }
    target = times[20]
    tracks["vpm_like"][target] *= 2 ** (-70 / 1200)

    events = dmap.build_events(tracks, [], cents_threshold=50.0)
    assert [event["kind"] for event in events["vpm_like"]] == ["gecis"]


def test_same_deviation_on_a_steady_pitch_is_suspicious() -> None:
    times = _grid(40)
    tracks = {name: _flat(times, 220.0) for name in dmap.ENGINE_ORDER}
    tracks["vpm_like"][times[20]] = 220.0 * 2 ** (-70 / 1200)

    events = dmap.build_events(tracks, [], cents_threshold=50.0)
    assert [event["kind"] for event in events["vpm_like"]] == ["sapma"]


def test_missing_frame_counts_as_a_lone_silence() -> None:
    times = _grid(40)
    tracks = {name: _flat(times, 220.0) for name in dmap.ENGINE_ORDER}
    del tracks["hapt_v1"][times[20]]

    events = dmap.build_events(tracks, [], cents_threshold=50.0)
    assert [event["kind"] for event in events["hapt_v1"]] == ["bosluk"]
    assert events["hapt_v1"][0]["consensus_hz"] == pytest.approx(220.0)


def test_lone_voiced_frame_counts_as_a_stray_point() -> None:
    times = _grid(40)
    tracks = {name: _flat(times, 220.0) for name in dmap.ENGINE_ORDER}
    stray = round(9.0, dmap.TIME_DECIMALS)
    tracks["yin_v1"][stray] = 300.0

    events = dmap.build_events(tracks, [], cents_threshold=50.0)
    assert [event["kind"] for event in events["yin_v1"]] == ["kacak"]


def test_episodes_merge_within_the_gap_and_split_beyond_it() -> None:
    def event(time: float, cents: float = 60.0) -> dict[str, object]:
        return {"time_seconds": time, "cents_from_consensus": cents, "kind": "sapma", "harmonic_label": ""}

    episodes = dmap.group_episodes(
        [event(1.00), event(1.20), event(1.60)], gap_seconds=0.25
    )
    assert [(item["start_seconds"], item["end_seconds"]) for item in episodes] == [(1.00, 1.20), (1.60, 1.60)]
    assert [item["frame_count"] for item in episodes] == [2, 1]
    assert [item["index"] for item in episodes] == [0, 1]


def test_episode_peak_points_at_the_worst_frame_not_the_midpoint() -> None:
    """Kısa epizotlarda orta nokta iki aykırı karenin arasına düşüp hatayı gizliyordu."""
    events = [
        {"time_seconds": 5.00, "cents_from_consensus": -60.0, "kind": "sapma", "harmonic_label": ""},
        {"time_seconds": 5.10, "cents_from_consensus": -1900.0, "kind": "harmonik", "harmonic_label": "1/3x"},
        {"time_seconds": 5.20, "cents_from_consensus": -55.0, "kind": "sapma", "harmonic_label": ""},
    ]
    episode = dmap.group_episodes(events, gap_seconds=0.25)[0]
    assert episode["peak_time_seconds"] == 5.10
    assert episode["peak_cents"] == -1900.0
    assert episode["harmonic_label"] == "1/3x"


def test_reference_lookup_respects_the_alignment_tolerance() -> None:
    reference = [(1.000, 220.0), (1.020, 221.0)]
    times = [item[0] for item in reference]
    assert dmap.reference_at(reference, times, 1.005) == pytest.approx(220.0)
    assert dmap.reference_at(reference, times, 1.500) is None


def test_fingerprint_is_stable_and_ignores_itself() -> None:
    payload = {"schema": dmap.SCHEMA, "episodes": {"vpm_like": [{"start_seconds": 1.0}]}}
    first = dmap.fingerprint(dict(payload))
    stamped = dict(payload)
    stamped["fingerprint"] = first
    assert dmap.fingerprint(stamped) == first


def test_classify_never_blames_a_single_engine_when_several_diverge() -> None:
    kind, label = dmap.classify(1200.0, 0.0, lone=False)
    assert (kind, label) == ("ortak", "")


def test_curve_is_expressed_in_cents_against_a440() -> None:
    assert dmap.curve({0.0: 440.0}) == [[0.0, 0.0]]
    assert dmap.curve({1.0: 880.0}) == [[1.0, 1200.0]]


# --------------------------------------------------------------------------
# quick_pitch_check — kullanıcı hükümlerine karşı hızlı regresyon denetimi
# --------------------------------------------------------------------------

_qspec = importlib.util.spec_from_file_location(
    "quick_pitch_check", ROOT / "scripts" / "quick_pitch_check.py"
)
qcheck = importlib.util.module_from_spec(_qspec)
assert _qspec.loader is not None
_qspec.loader.exec_module(qcheck)


def _voiced(times: list[float], hz: float) -> dict[float, float]:
    return {round(t, 4): hz for t in times}


def _row(**verdicts: str) -> dict:
    return {"index": 0, "start_seconds": 10.0, "end_seconds": 10.16, "verdicts": verdicts}


def _window_times(row: dict) -> list[float]:
    slots = qcheck.slot_count(row["start_seconds"], row["end_seconds"])
    return [round(row["start_seconds"] + i * qcheck.HOP_SECONDS, 4) for i in range(slots)]


def test_clip_starts_snap_to_the_hop_grid() -> None:
    """Hizalanmamış klip motorun bütün analiz pencerelerini kaydırır."""
    rows = [{"start_seconds": 10.0, "end_seconds": 10.2}]
    (start, _end), = qcheck.clip_blocks(rows, duration=60.0)
    samples = start * qcheck.SAMPLE_RATE_HZ
    assert samples == pytest.approx(round(samples))
    assert round(samples) % qcheck.HOP_SAMPLES == 0
    assert start <= 10.0 - qcheck.PREROLL_SECONDS + qcheck.HOP_SAMPLES / qcheck.SAMPLE_RATE_HZ


def test_clip_blocks_never_reach_past_the_source() -> None:
    rows = [{"start_seconds": 0.05, "end_seconds": 0.10}]
    (start, end), = qcheck.clip_blocks(rows, duration=1.0)
    assert start == 0.0
    assert end <= 1.0


def test_a_labelled_gap_counts_as_repaired_only_when_the_window_fills_in() -> None:
    row = _row(yin_v1="bosluk", vpm_like="yok")
    times = _window_times(row)
    still = qcheck.evaluate_row(
        row, {"yin_v1": _voiced(times[:3], 220.0), "vpm_like": _voiced(times, 220.0)},
        ["yin_v1", "vpm_like"],
    )
    assert still["yin_v1"]["state"] == "duruyor"

    fixed = qcheck.evaluate_row(
        row, {"yin_v1": _voiced(times, 220.0), "vpm_like": _voiced(times, 220.0)},
        ["yin_v1", "vpm_like"],
    )
    assert fixed["yin_v1"]["state"] == "gitti"


def test_a_shared_gap_is_still_measurable_when_every_engine_is_silent() -> None:
    """14 satırda dört motor birden susuyor; kıyas orada hiçbir şey söyleyemez."""
    engines = ["yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1"]
    row = _row(**{name: "bosluk" for name in engines})
    result = qcheck.evaluate_row(row, {name: {} for name in engines}, engines)
    assert all(result[name]["state"] == "duruyor" for name in engines)


def test_a_short_octave_spike_survives_the_window_median() -> None:
    """Pencere medyanı kullanmak 13 etiketli oktav hatasını gizliyordu."""
    row = _row(vpm_like="oktav", yin_v1="yok", pitch_engine_v2="yok")
    times = _window_times(row)
    spiked = dict(_voiced(times, 220.0))
    spiked[times[len(times) // 2]] = 440.0
    engines = ["vpm_like", "yin_v1", "pitch_engine_v2"]
    voiced = {"vpm_like": spiked, "yin_v1": _voiced(times, 220.0),
              "pitch_engine_v2": _voiced(times, 220.0)}
    reference = qcheck.build_reference(row, voiced, engines)
    result = qcheck.evaluate_row(row, voiced, engines, reference)
    assert result["vpm_like"]["state"] == "duruyor"
    assert result["vpm_like"]["worst_cents"] == pytest.approx(1200.0, abs=1.0)


def test_a_pitch_defect_is_reported_unmeasured_without_a_reference() -> None:
    """Ölçemediği yerde 'gitti' demek, aracın sahte başarı raporlaması demekti."""
    row = _row(vpm_like="oktav", yin_v1="yok")
    times = _window_times(row)
    result = qcheck.evaluate_row(
        row, {"vpm_like": _voiced(times, 440.0), "yin_v1": _voiced(times, 220.0)},
        ["vpm_like", "yin_v1"], {},
    )
    assert result["vpm_like"]["state"] == "ölçülemedi"


def test_the_reference_comes_only_from_engines_called_clean() -> None:
    row = _row(vpm_like="oktav", yin_v1="yok", pitch_engine_v2="yok")
    times = _window_times(row)
    reference = qcheck.build_reference(
        row,
        {"vpm_like": _voiced(times, 440.0), "yin_v1": _voiced(times, 220.0),
         "pitch_engine_v2": _voiced(times, 221.0)},
        ["vpm_like", "yin_v1", "pitch_engine_v2"],
    )
    assert reference
    assert all(219.0 <= hz <= 222.0 for hz in reference.values())


def test_a_clean_cell_is_not_tripped_by_a_single_missing_frame() -> None:
    """'Sorun yok' kusursuzluk beyanı değil; dar eşik sahte regresyon üretir."""
    engines = ["yin_v1", "pitch_engine_v2", "vpm_like"]
    row = _row(yin_v1="yok", pitch_engine_v2="yok", vpm_like="yok")
    times = _window_times(row)
    thin = {t: 220.0 for t in times if t != times[2]}
    result = qcheck.evaluate_row(
        row,
        {"yin_v1": thin, "pitch_engine_v2": _voiced(times, 220.0),
         "vpm_like": _voiced(times, 220.0)},
        engines,
    )
    assert result["yin_v1"]["role"] == "koruma"
    assert result["yin_v1"]["state"] == "korundu"


def test_a_clean_cell_trips_on_a_real_hole() -> None:
    engines = ["yin_v1", "pitch_engine_v2", "vpm_like"]
    row = _row(yin_v1="yok", pitch_engine_v2="yok", vpm_like="yok")
    times = _window_times(row)
    holed = {t: 220.0 for t in times[qcheck.GUARD_MISSING_RUN_FRAMES + 1:]}
    result = qcheck.evaluate_row(
        row,
        {"yin_v1": holed, "pitch_engine_v2": _voiced(times, 220.0),
         "vpm_like": _voiced(times, 220.0)},
        engines,
    )
    assert result["yin_v1"]["state"] == "bozuldu"
    assert "bosluk" in result["yin_v1"]["problems"]


def test_a_kacak_row_expects_silence_from_every_engine() -> None:
    engines = ["yin_v1", "vpm_like"]
    row = _row(yin_v1="kacak", vpm_like="yok")
    times = _window_times(row)
    assert qcheck.row_expectation(row["verdicts"]) == "silent"
    result = qcheck.evaluate_row(
        row, {"yin_v1": _voiced(times, 220.0), "vpm_like": {}}, engines
    )
    assert result["yin_v1"]["state"] == "duruyor"
    assert result["vpm_like"]["state"] == "korundu"


def test_jitter_is_reported_as_unmeasured_rather_than_guessed() -> None:
    row = _row(hapt_v1="titrek", yin_v1="yok")
    times = _window_times(row)
    result = qcheck.evaluate_row(
        row, {"hapt_v1": _voiced(times, 220.0), "yin_v1": _voiced(times, 220.0)},
        ["hapt_v1", "yin_v1"],
    )
    assert result["hapt_v1"]["state"] == "ölçülmedi"
