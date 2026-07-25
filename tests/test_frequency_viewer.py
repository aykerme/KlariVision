import json

from klarivision.frequency_viewer import build_frequency_viewer, prepare_display_frames
from test_pitch_reference import write_reference_workbook


def test_frequency_viewer_uses_physical_hertz_grid(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(
        json.dumps(
            {"frames": [{"time_seconds": 0.0, "frequency_hz": 123.47}]},
        ),
        encoding="utf-8",
    )
    output = tmp_path / "viewer.html"
    reference_path = tmp_path / "perde-esleme.xlsx"
    write_reference_workbook(reference_path)

    build_frequency_viewer(
        pitch_json,
        "audio.wav",
        output,
        turkish_reference_path=reference_path,
    )

    html = output.read_text(encoding="utf-8")
    assert "Duyulan frekans" in html
    assert "KlariVision 0.3.13-preview" in html
    assert '"minor"' in html
    assert "frekans ölçümü transpoze edilmez" in html
    assert "followPlayback" in html
    assert 'id="vertical-in"' in html
    assert 'id="vertical-out"' in html
    assert 'id="vertical-follow"' in html
    assert "verticalSpan" in html
    assert "function followValues()" in html
    assert "function centerOnPlayhead()" in html
    assert "viewStart=-6" in html
    assert "loadedmetadata" in html
    assert 'id="time-scroll"' in html
    assert 'id="vertical-scroll"' in html
    assert "function updateScrollbars()" in html
    assert 'id="set-a"' in html
    assert 'id="set-b"' in html
    assert 'id="loop"' in html
    assert "loopEnabled" in html
    assert "function updateLoopButtons()" in html
    assert "media.paused" in html
    assert "drag.moved" in html
    assert 'id="scale-mode"' in html
    assert 'id="tonic"' in html
    assert "function scaleNotes()" in html
    assert 'value="turkish"' in html
    assert "function turkishNotes()" in html
    assert "turkishReferenceNotes" in html
    assert '"name":"Yegâh"' in html
    assert '"heard_hz":293.344891' in html
    assert "Duyulan Hz" in html
    assert 'value="nihavent"' in html
    assert "function nihaventNotes()" in html
    assert "Rast (karar)" in html


def test_frequency_viewer_can_embed_video(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"
    reference_path = tmp_path / "perde-esleme.xlsx"
    write_reference_workbook(reference_path)

    build_frequency_viewer(
        pitch_json,
        "audio.wav",
        output,
        video_relative_path="video.mp4",
        turkish_reference_path=reference_path,
    )

    assert '<video id="media" controls src="video.mp4"></video>' in output.read_text(encoding="utf-8")


def test_frequency_viewer_removes_weak_and_isolated_pitch_candidates() -> None:
    payload = {
        "frames": [
            {"time_seconds": 0.000, "frequency_hz": 220.0, "voiced": True, "confidence": 0.9},
            {"time_seconds": 0.005, "frequency_hz": 440.0, "voiced": True, "confidence": 0.9},
            {"time_seconds": 0.010, "frequency_hz": 220.0, "voiced": True, "confidence": 0.9},
            {"time_seconds": 0.015, "frequency_hz": 220.0, "voiced": True, "confidence": 0.1},
        ]
    }

    result = prepare_display_frames(payload)

    assert len(result) == 2
    assert all(point["hz"] == 220.0 for point in result)
