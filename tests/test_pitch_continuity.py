"""The gate that can see a hole.

`score_frames` prices frames; this file prices the *line*. The distinction is
not academic. Until it existed the tournament's hard requirement was
`serious_harmonic_error_frames == 0`, and falling silent is not a harmonic
error -- so on the octave trap suite, which was built specifically to make the
engine choose wrongly, `unified_v1` scored a clean sheet by declining to
answer four whole sections. Measured on the offline (Dinleme Modu) path:
S04/S05/S06 (weak or absent fundamental) and S11 (third harmonic dominant)
publish nothing at all in every variant, ~1.1 s of continuous silence each,
while the frames themselves sit at RMS ~0.25 -- 24 dB above the gate -- with
eleven candidates apiece. The reason recorded per frame is `contested`:
`harmonic_dominance` never reaches its floor when the fundamental is weak, so
the engine cannot prove its winner is not a subharmonic ghost and withholds.

That behaviour may well be correct. What was wrong is that it was invisible.
The numbers below are asserted at their measured values, in the same spirit as
`ACCEPTED_VETO_MISSING_VOICED_FRAMES` in test_pitch_engine_tournament.py: a
change that buys coverage back must move them, and a change that quietly
spends more coverage cannot hide.

These figures are the *displayed* line, not the engine's published track --
see DISPLAY_MINIMUM_HZ below for why the distinction cost a round. Raising
`kHarmonicContestEvidenceRatio` from 0.40 to 0.75 moved exactly one section
that a reader can see: S08 on the adverse variant, 0.10 -> 0.72. It also took
S04 from 0 to 45 published frames on clean, every one of which the viewer
discards for confidence, so the screen there is unchanged and this table says
so. S05, S06 and S11 barely moved at any setting and stay open.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

sys.path.insert(0, str(ROOT / "src"))

from generate_octave_trap_suite_v1 import write_suite  # noqa: E402
from pitch_error_metrics import (  # noqa: E402
    ObservedFrame,
    ReferenceFrame,
    score_continuity,
)
from pitch_tournament_engines import unified_offline_frames  # noqa: E402
from run_pitch_engine_tournament import read_wav  # noqa: E402

from klarivision.frequency_viewer import MINIMUM_CONFIDENCE  # noqa: E402


# One analysis hop at 48 kHz, the same tolerance the tournament matches
# reference frames to observed ones with.
TOLERANCE_SECONDS = 512 / 48_000

# The engine's published track is not the line the user sees. Between them
# sits frequency_viewer's own filter, which drops any frame below
# MINIMUM_CONFIDENCE before drawing. Scoring the raw track therefore measures
# a curve nobody looks at -- and did, once: a change that took S04 from 0 to
# 45 published frames moved this file's numbers and changed nothing on screen,
# because all 45 carried confidence 0.010-0.151 against a 0.20 floor. The
# constant is imported rather than repeated so the gate cannot drift away from
# the viewer it claims to speak for.
DISPLAY_MINIMUM_HZ = 80.0


def _ref(*pairs: tuple[float, float | None]) -> list[ReferenceFrame]:
    return [ReferenceFrame(time, hz) for time, hz in pairs]


def _obs(*times: float) -> list[ObservedFrame]:
    return [ObservedFrame(time, 294.0) for time in times]


# ---------------------------------------------------------------------------
# The measurer, measured
# ---------------------------------------------------------------------------
#
# Three separate grid bugs in the external benchmark looked exactly like engine
# faults before anyone scored the scorer (docs/TEST_BASELINE.md). These pin the
# distinctions this metric exists to draw, so a regression in the metric cannot
# masquerade as a regression -- or an improvement -- in the engine.


def test_a_gap_between_two_answered_frames_is_a_break() -> None:
    result = score_continuity(
        _ref((0.0, 294.0), (0.01, 294.0), (0.02, 294.0)),
        _obs(0.0, 0.02),
        tolerance_seconds=0.005,
    )
    assert result["breaks"] == 1
    assert result["broken_regions"] == 1
    assert result["unanswered_regions"] == 0
    assert result["coverage"] == pytest.approx(2 / 3)


def test_a_late_start_and_an_early_end_are_not_breaks() -> None:
    """Attack and release are not holes; charging them would flag every note."""
    result = score_continuity(
        _ref((0.0, 294.0), (0.01, 294.0), (0.02, 294.0), (0.03, 294.0)),
        _obs(0.01, 0.02),
        tolerance_seconds=0.005,
    )
    assert result["breaks"] == 0
    assert result["broken_regions"] == 0
    assert result["coverage"] == pytest.approx(0.5)


def test_an_entirely_unanswered_note_is_one_break_not_zero() -> None:
    """The case the harmonic-error gate is structurally blind to."""
    result = score_continuity(
        _ref((0.0, 294.0), (0.01, 294.0), (0.02, 294.0)),
        [],
        tolerance_seconds=0.005,
    )
    assert result["unanswered_regions"] == 1
    assert result["breaks"] == 1
    assert result["break_ranges"][0]["whole_region"] is True
    assert result["coverage"] == 0.0


def test_silence_ends_a_region_so_a_rest_is_not_a_break() -> None:
    result = score_continuity(
        _ref((0.0, 294.0), (0.01, None), (0.02, 294.0)),
        _obs(0.0, 0.02),
        tolerance_seconds=0.005,
    )
    assert result["voiced_regions"] == 2
    assert result["breaks"] == 0
    assert result["coverage"] == 1.0


def test_coverage_ignores_whether_the_published_pitch_was_right() -> None:
    """Deliberate: a coverage gate must not be satisfiable by wrong notes.

    Publishing an octave error still counts as answering the frame here, and
    score_frames is what fails it. Merging the two would let a change trade a
    hole for a harmonic error and show no movement anywhere.
    """
    wrong = [ObservedFrame(0.0, 147.0), ObservedFrame(0.01, 147.0)]
    result = score_continuity(
        _ref((0.0, 294.0), (0.01, 294.0)), wrong, tolerance_seconds=0.005
    )
    assert result["coverage"] == 1.0
    assert result["breaks"] == 0


# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------
#
# Per-section coverage of unified_v1 on the offline path, measured 8 September
# 2026 on the suite as generated by scripts/generate_octave_trap_suite_v1.py.
# A section is listed only if it is not essentially fully covered; everything
# absent from this table is asserted against FLOOR below.
#
# `beklenen_hata` in the suite's own manifest says what error each trap was
# built to provoke. Read next to it, this table says the engine answers the
# trap with silence rather than with the wrong note: S04/S05/S06/S11 expect
# `1/3x` and produce no frames instead.
FLOOR = 0.90

MEASURED_COVERAGE: dict[str, dict[str, float]] = {
    "clean": {
        "S04": 0.000, "S05": 0.000, "S06": 0.000, "S11": 0.000, "S14": 0.672,
    },
    "room": {
        "S04": 0.118, "S05": 0.027, "S06": 0.036, "S11": 0.000,
    },
    "adverse": {
        "S04": 0.000, "S05": 0.000, "S06": 0.000, "S07": 0.000, "S08": 0.723,
        "S09": 0.817, "S11": 0.000, "S12": 0.900, "S13": 0.879, "S14": 0.626,
    },
}

# Absolute slack on a recorded coverage figure. Wide enough that a rebuild or
# a one-frame boundary shift does not turn the gate red, narrow enough that a
# section moving by more than two frames of its ~110 does.
TOLERANCE = 0.03


def test_the_gate_scores_the_drawn_line_not_the_published_track() -> None:
    """The bug that cost a round, pinned.

    A frame the viewer will discard must not count as coverage here, or this
    file reports a recovery the user cannot see -- which is precisely what
    happened when S04 went from 0 to 45 published frames at confidence 0.035.
    """
    manifest = {
        "ground_truth": [
            {"time_seconds": 0.0, "frequency_hz": 294.0},
            {"time_seconds": 0.01, "frequency_hz": 294.0},
        ],
        "sections": [{
            "kind": "weak_fundamental", "label": "stub",
            "start_seconds": 0.0, "end_seconds": 1.0,
            "trap": {"id": "S00", "beklenen_hata": "yok"},
        }],
    }
    believed = [(0.0, 294.0, 0.9), (0.01, 294.0, 0.9)]
    barely = [(0.0, 294.0, MINIMUM_CONFIDENCE / 2), (0.01, 294.0, MINIMUM_CONFIDENCE / 2)]
    assert _section_coverage(manifest, believed)["S00"] == 1.0
    assert _section_coverage(manifest, barely)["S00"] == 0.0


@pytest.fixture(scope="module")
def suite(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, dict[str, object]]:
    directory = tmp_path_factory.mktemp("octave-trap-suite")
    manifest = write_suite(directory)
    return directory, manifest


def _section_coverage(
    manifest: dict[str, object],
    frames: list[tuple[float, float, float]],
) -> dict[str, float]:
    truth = manifest["ground_truth"]  # type: ignore[index]
    observed = [
        ObservedFrame(time, hz)
        for time, hz, confidence in frames
        if confidence >= MINIMUM_CONFIDENCE and hz >= DISPLAY_MINIMUM_HZ
    ]
    coverage: dict[str, float] = {}
    for section in manifest["sections"]:  # type: ignore[union-attr]
        trap = section.get("trap")
        if trap is None:
            continue
        reference = [
            ReferenceFrame(row["time_seconds"], row.get("frequency_hz"))
            for row in truth
            if section["start_seconds"] <= row["time_seconds"] < section["end_seconds"]
        ]
        if not any(item.frequency_hz for item in reference):
            continue
        result = score_continuity(
            reference, observed, tolerance_seconds=TOLERANCE_SECONDS
        )
        coverage[trap["id"]] = float(result["coverage"])
    return coverage


@pytest.mark.parametrize("variant", ["clean", "room", "adverse"])
def test_octave_trap_coverage_holds_at_its_measured_value(
    suite: tuple[Path, dict[str, object]],
    variant: str,
) -> None:
    """Every trap section is pinned: the covered ones and the silent ones alike.

    Sections in MEASURED_COVERAGE are held to their recorded figure in both
    directions -- a section that recovers must be re-recorded here, which is
    the point. Every other trap section must stay above FLOOR, so coverage
    cannot be spent somewhere new without this failing.
    """
    directory, manifest = suite
    filename = f"klarivision_octave_trap_suite_{variant}_v1.wav"
    audio, rate = read_wav(directory / filename)
    coverage = _section_coverage(manifest, unified_offline_frames(audio, rate))
    recorded = MEASURED_COVERAGE[variant]

    for section_id, measured in recorded.items():
        assert section_id in coverage, (variant, section_id)
        assert coverage[section_id] == pytest.approx(measured, abs=TOLERANCE), (
            variant, section_id, coverage[section_id], measured
        )

    for section_id, value in sorted(coverage.items()):
        if section_id in recorded:
            continue
        assert value >= FLOOR, (variant, section_id, value)


def test_the_suite_still_expects_a_harmonic_error_where_the_engine_is_silent(
    suite: tuple[Path, dict[str, object]],
) -> None:
    """Guards the reading, not the engine.

    The four fully-silent sections are worth pinning only while the suite
    still says a harmonic error is what belongs there. If the suite is ever
    retuned so those traps expect a dropout, silence stops being a finding and
    this gate's comment above becomes wrong -- so the claim is asserted rather
    than left in prose.
    """
    _, manifest = suite
    expected = {
        section["trap"]["id"]: section["trap"]["beklenen_hata"]
        for section in manifest["sections"]  # type: ignore[union-attr]
        if "trap" in section
    }
    for section_id in ("S04", "S05", "S06", "S11"):
        assert expected[section_id] == "1/3x", (section_id, expected[section_id])
