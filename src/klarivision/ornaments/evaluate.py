"""Compare automatic ornament candidates with human-confirmed intervals."""

from __future__ import annotations

from collections.abc import Sequence


def interval_iou(left: dict[str, object], right: dict[str, object]) -> float:
    """Return intersection-over-union for two timestamp intervals."""
    left_start = float(left["start_seconds"])
    left_end = float(left["end_seconds"])
    right_start = float(right["start_seconds"])
    right_end = float(right["end_seconds"])
    intersection = max(0.0, min(left_end, right_end) - max(left_start, right_start))
    union = (left_end - left_start) + (right_end - right_start) - intersection
    return 0.0 if union == 0 else intersection / union


def evaluate_candidates(
    annotations: Sequence[dict[str, object]],
    candidates: Sequence[dict[str, object]],
    *,
    kind: str,
    minimum_iou: float = 0.25,
) -> dict[str, object]:
    """Greedily match the best non-overlapping human and automatic intervals."""
    human = [annotation for annotation in annotations if annotation["kind"] == kind]
    automatic = [candidate for candidate in candidates if candidate["kind"] == kind]
    possible_matches = sorted(
        (
            (interval_iou(annotation, candidate), human_index, candidate_index)
            for human_index, annotation in enumerate(human)
            for candidate_index, candidate in enumerate(automatic)
        ),
        reverse=True,
    )
    matched_human: set[int] = set()
    matched_automatic: set[int] = set()
    matches: list[dict[str, object]] = []
    for score, human_index, candidate_index in possible_matches:
        if score < minimum_iou:
            break
        if human_index in matched_human or candidate_index in matched_automatic:
            continue
        matched_human.add(human_index)
        matched_automatic.add(candidate_index)
        matches.append(
            {
                "annotation": human[human_index],
                "candidate": automatic[candidate_index],
                "iou": round(score, 3),
            }
        )

    precision = len(matches) / len(automatic) if automatic else 0.0
    recall = len(matches) / len(human) if human else 0.0
    return {
        "kind": kind,
        "minimum_iou": minimum_iou,
        "manual_count": len(human),
        "automatic_count": len(automatic),
        "matched_count": len(matches),
        "precision": round(precision, 3),
        "recall": round(recall, 3),
        "mean_iou": round(sum(match["iou"] for match in matches) / len(matches), 3)
        if matches
        else 0.0,
        "matches": matches,
        "missed_annotations": [
            annotation for index, annotation in enumerate(human) if index not in matched_human
        ],
        "unmatched_candidates": [
            candidate
            for index, candidate in enumerate(automatic)
            if index not in matched_automatic
        ],
    }


def evaluate_technique_spans(
    annotations: Sequence[dict[str, object]],
    candidates: Sequence[dict[str, object]],
    *,
    kind: str,
    minimum_overlap_seconds: float = 0.10,
) -> dict[str, object]:
    """Evaluate whether candidates occur inside long, human-labelled technique spans.

    Teaching videos often label an entire exercise phrase as “vibrato active”.
    In that case a short detected pulse should not be penalised for having a
    low IoU with the much longer phrase.  This report therefore asks two
    distinct questions: did the detector find *something* in each exercise
    span, and how many of its candidates actually fell inside such a span?
    """
    spans = [annotation for annotation in annotations if annotation["kind"] == kind]
    automatic = [candidate for candidate in candidates if candidate["kind"] == kind]
    detected_spans: list[dict[str, object]] = []
    inside_candidates: list[dict[str, object]] = []
    for span in spans:
        matching = [
            candidate
            for candidate in automatic
            if _overlap_seconds(span, candidate) >= minimum_overlap_seconds
        ]
        if matching:
            detected_spans.append({"annotation": span, "candidates": matching})
    for candidate in automatic:
        if any(_overlap_seconds(span, candidate) >= minimum_overlap_seconds for span in spans):
            inside_candidates.append(candidate)

    span_recall = len(detected_spans) / len(spans) if spans else 0.0
    candidate_precision = len(inside_candidates) / len(automatic) if automatic else 0.0
    return {
        "kind": kind,
        "evaluation_mode": "technique_span",
        "minimum_overlap_seconds": minimum_overlap_seconds,
        "manual_span_count": len(spans),
        "automatic_candidate_count": len(automatic),
        "detected_span_count": len(detected_spans),
        "span_recall": round(span_recall, 3),
        "candidates_inside_span_count": len(inside_candidates),
        "candidate_precision": round(candidate_precision, 3),
        "detected_spans": detected_spans,
        "missed_spans": [
            span for span in spans if not any(item["annotation"] == span for item in detected_spans)
        ],
        "outside_candidates": [candidate for candidate in automatic if candidate not in inside_candidates],
    }


def _overlap_seconds(left: dict[str, object], right: dict[str, object]) -> float:
    return max(
        0.0,
        min(float(left["end_seconds"]), float(right["end_seconds"]))
        - max(float(left["start_seconds"]), float(right["start_seconds"])),
    )
