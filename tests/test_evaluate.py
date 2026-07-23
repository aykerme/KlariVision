from klarivision.ornaments.evaluate import evaluate_candidates, evaluate_technique_spans


def test_evaluation_matches_overlapping_intervals() -> None:
    report = evaluate_candidates(
        [{"kind": "vibrato", "start_seconds": 1.0, "end_seconds": 2.0}],
        [{"kind": "vibrato", "start_seconds": 1.1, "end_seconds": 2.1}],
        kind="vibrato",
    )

    assert report["matched_count"] == 1
    assert report["precision"] == 1.0
    assert report["recall"] == 1.0


def test_technique_span_evaluation_accepts_short_candidates_inside_long_phrase() -> None:
    report = evaluate_technique_spans(
        [{"kind": "vibrato", "start_seconds": 10.0, "end_seconds": 20.0}],
        [
            {"kind": "vibrato", "start_seconds": 12.0, "end_seconds": 12.5},
            {"kind": "vibrato", "start_seconds": 25.0, "end_seconds": 25.5},
        ],
        kind="vibrato",
    )

    assert report["detected_span_count"] == 1
    assert report["span_recall"] == 1.0
    assert report["candidate_precision"] == 0.5
