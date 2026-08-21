"""Shared deterministic five-way pitch-error accounting for synthetic truth."""

from __future__ import annotations

import bisect
import math
from dataclasses import dataclass
from typing import Iterable

HARMONIC_TARGETS = {
    "1/3x": 1200 * math.log2(1 / 3),
    "1/2x": -1200.0,
    "2x": 1200.0,
    "3x": 1200 * math.log2(3),
}

# These values are deliberately shared with the Swift source-verification
# overlay.  Raw five-way accounting remains exhaustive; this policy only
# decides which raw discrepancies are perceptually meaningful enough to be
# highlighted and used for tournament selection.
CORRECT_PITCH_CENTS = 50.0
NEAR_PITCH_CENTS = 100.0
HARMONIC_TOLERANCE_CENTS = 90.0
PERSISTENT_ERROR_FRAMES = 3
PERSISTENT_FRAME_GAP_SECONDS = 0.015
TRANSITION_GRACE_SECONDS = 0.030


@dataclass(frozen=True)
class ReferenceFrame:
    time_seconds: float
    frequency_hz: float | None


@dataclass(frozen=True)
class ObservedFrame:
    time_seconds: float
    frequency_hz: float


def harmonic_relationship(signed_cents: float) -> str | None:
    label = min(HARMONIC_TARGETS, key=lambda item: abs(signed_cents - HARMONIC_TARGETS[item]))
    return label if abs(signed_cents - HARMONIC_TARGETS[label]) <= HARMONIC_TOLERANCE_CENTS else None


def _empty() -> dict[str, object]:
    return {
        "reference_voiced_frames": 0,
        "reference_silent_frames": 0,
        "correct_silent_frames": 0,
        "false_voiced_frames": 0,
        "missing_voiced_frames": 0,
        "correct_pitch_frames": 0,
        "correct_pitch_absolute_cents_sum": 0.0,
        "correct_pitch_mean_absolute_cents": None,
        "harmonic_error_frames": 0,
        "non_harmonic_error_frames": 0,
        "total_error_frames": 0,
        "near_pitch_frames": 0,
        "serious_false_voiced_frames": 0,
        "serious_missing_voiced_frames": 0,
        "serious_harmonic_error_frames": 0,
        "serious_non_harmonic_error_frames": 0,
        "serious_total_error_frames": 0,
        "transition_tolerated_frames": 0,
        "transient_tolerated_frames": 0,
        "serious_error_ranges": [],
        "error_examples": [],
    }


def score_frames(
    reference: Iterable[ReferenceFrame],
    observed: Iterable[ObservedFrame],
    *,
    tolerance_seconds: float,
    transition_times: Iterable[float] = (),
    example_limit: int = 64,
) -> dict[str, object]:
    """Classify every reference frame once, consuming an observed frame at most once."""
    targets = sorted(reference, key=lambda item: item.time_seconds)
    outputs = sorted(observed, key=lambda item: item.time_seconds)
    output_times = [item.time_seconds for item in outputs]
    used: set[int] = set()
    summary = _empty()
    examples: list[dict[str, object]] = []
    absolute_sum = 0.0
    raw_errors: list[dict[str, object]] = []
    transitions = sorted(float(item) for item in transition_times)

    for target in targets:
        index = bisect.bisect_left(output_times, target.time_seconds)
        candidates: list[int] = []
        left, right = index - 1, index
        while left >= 0 and target.time_seconds - output_times[left] <= tolerance_seconds:
            if left not in used:
                candidates.append(left)
            left -= 1
        while right < len(outputs) and output_times[right] - target.time_seconds <= tolerance_seconds:
            if right not in used:
                candidates.append(right)
            right += 1
        match = min(candidates, key=lambda item: abs(outputs[item].time_seconds - target.time_seconds), default=None)
        if match is not None and abs(outputs[match].time_seconds - target.time_seconds) > tolerance_seconds:
            match = None
        actual = outputs[match] if match is not None else None
        if match is not None:
            used.add(match)

        if target.frequency_hz is None:
            summary["reference_silent_frames"] = int(summary["reference_silent_frames"]) + 1
            if actual is None:
                summary["correct_silent_frames"] = int(summary["correct_silent_frames"]) + 1
            else:
                summary["false_voiced_frames"] = int(summary["false_voiced_frames"]) + 1
                raw_errors.append({"kind": "false_voiced", "time_seconds": target.time_seconds})
                if len(examples) < example_limit:
                    examples.append({"kind": "false_voiced", "time_seconds": target.time_seconds, "actual_hz": actual.frequency_hz})
            continue

        summary["reference_voiced_frames"] = int(summary["reference_voiced_frames"]) + 1
        if actual is None:
            summary["missing_voiced_frames"] = int(summary["missing_voiced_frames"]) + 1
            raw_errors.append({"kind": "missing_voiced", "time_seconds": target.time_seconds})
            if len(examples) < example_limit:
                examples.append({"kind": "missing_voiced", "time_seconds": target.time_seconds, "expected_hz": target.frequency_hz})
            continue
        signed = 1200.0 * math.log2(actual.frequency_hz / target.frequency_hz)
        absolute = abs(signed)
        if absolute <= CORRECT_PITCH_CENTS + 1e-9:
            summary["correct_pitch_frames"] = int(summary["correct_pitch_frames"]) + 1
            absolute_sum += absolute
            continue
        relationship = harmonic_relationship(signed)
        key = "harmonic_error_frames" if relationship else "non_harmonic_error_frames"
        summary[key] = int(summary[key]) + 1
        near_pitch = absolute <= NEAR_PITCH_CENTS + 1e-9
        if near_pitch:
            summary["near_pitch_frames"] = int(summary["near_pitch_frames"]) + 1
        raw_errors.append({
            "kind": "harmonic_error" if relationship else "non_harmonic_error",
            "time_seconds": target.time_seconds,
            "near_pitch": near_pitch,
        })
        if len(examples) < example_limit:
            examples.append({
                "kind": "harmonic_error" if relationship else "non_harmonic_error",
                "time_seconds": target.time_seconds,
                "expected_hz": target.frequency_hz,
                "actual_hz": actual.frequency_hz,
                "signed_cents": signed,
                **({"harmonic_relationship": relationship} if relationship else {}),
            })

    correct = int(summary["correct_pitch_frames"])
    summary["correct_pitch_absolute_cents_sum"] = round(absolute_sum, 6)
    summary["correct_pitch_mean_absolute_cents"] = round(absolute_sum / correct, 6) if correct else None
    summary["total_error_frames"] = sum(int(summary[key]) for key in (
        "false_voiced_frames", "missing_voiced_frames", "harmonic_error_frames", "non_harmonic_error_frames",
    ))
    # Near pitch is deliberately a warning rather than a serious error.  All
    # remaining raw errors receive a short transition grace, then must persist
    # for three analytic frames before they influence the visible overlay or
    # tournament selection.
    candidates: list[dict[str, object]] = []
    for item in raw_errors:
        if bool(item.get("near_pitch")):
            continue
        time = float(item["time_seconds"])
        if any(abs(time - boundary) <= TRANSITION_GRACE_SECONDS + 1e-9 for boundary in transitions):
            summary["transition_tolerated_frames"] = int(summary["transition_tolerated_frames"]) + 1
        else:
            candidates.append(item)
    serious: list[dict[str, object]] = []
    ranges: list[dict[str, object]] = []
    for kind in ("false_voiced", "missing_voiced", "harmonic_error", "non_harmonic_error"):
        items = [item for item in candidates if item["kind"] == kind]
        active: list[dict[str, object]] = []
        for item in items:
            if active and float(item["time_seconds"]) - float(active[-1]["time_seconds"]) > PERSISTENT_FRAME_GAP_SECONDS:
                if len(active) >= PERSISTENT_ERROR_FRAMES:
                    serious.extend(active)
                    ranges.append({"kind": kind, "start_seconds": active[0]["time_seconds"], "end_seconds": active[-1]["time_seconds"], "frames": len(active)})
                else:
                    summary["transient_tolerated_frames"] = int(summary["transient_tolerated_frames"]) + len(active)
                active = []
            active.append(item)
        if active:
            if len(active) >= PERSISTENT_ERROR_FRAMES:
                serious.extend(active)
                ranges.append({"kind": kind, "start_seconds": active[0]["time_seconds"], "end_seconds": active[-1]["time_seconds"], "frames": len(active)})
            else:
                summary["transient_tolerated_frames"] = int(summary["transient_tolerated_frames"]) + len(active)
    serious_keys = {
        "false_voiced": "serious_false_voiced_frames",
        "missing_voiced": "serious_missing_voiced_frames",
        "harmonic_error": "serious_harmonic_error_frames",
        "non_harmonic_error": "serious_non_harmonic_error_frames",
    }
    for item in serious:
        key = serious_keys[str(item["kind"])]
        summary[key] = int(summary[key]) + 1
    summary["serious_total_error_frames"] = len(serious)
    summary["serious_error_ranges"] = ranges
    summary["error_examples"] = examples
    assert int(summary["reference_voiced_frames"]) == sum(int(summary[key]) for key in (
        "missing_voiced_frames", "correct_pitch_frames", "harmonic_error_frames", "non_harmonic_error_frames",
    ))
    assert int(summary["reference_silent_frames"]) == int(summary["correct_silent_frames"]) + int(summary["false_voiced_frames"])
    return summary
