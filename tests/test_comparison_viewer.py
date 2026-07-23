import json

from klarivision.comparison_viewer import build_ab_viewer


def test_ab_viewer_contains_both_curves_and_annotations(tmp_path) -> None:
    pitch = tmp_path / "pitch.json"
    pitch.write_text(
        json.dumps({"frames": [{"time_seconds": 0.0, "frequency_hz": 440.0}]}),
        encoding="utf-8",
    )
    annotations = tmp_path / "annotations.json"
    annotations.write_text(
        json.dumps({"annotations": [{"kind": "vibrato", "start_seconds": 0.0, "end_seconds": 0.5}]}),
        encoding="utf-8",
    )
    output = tmp_path / "comparison.html"

    build_ab_viewer(pitch, pitch, "one.mp4", "two.mp4", annotations, annotations, output)

    html = output.read_text(encoding="utf-8")
    assert 'id="control-video"' in html
    assert 'id="ornament-video"' in html
    assert 'id="shift"' in html
    assert "curve(plain" in html
