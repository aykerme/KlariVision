import json

from klarivision.frequency_viewer import build_frequency_viewer, prepare_display_frames


def test_frequency_viewer_uses_physical_hertz_grid(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(
        json.dumps(
            {"frames": [{"time_seconds": 0.0, "frequency_hz": 123.47}]},
        ),
        encoding="utf-8",
    )
    output = tmp_path / "viewer.html"

    build_frequency_viewer(pitch_json, "audio.wav", output)

    html = output.read_text(encoding="utf-8")
    assert "Duyulan frekans" in html
    assert "KlariVision 0.3.1-preview" in html
    assert '"Si2",123.47' in html
    assert "makam, karar, Sol klarnet yazılı notası" in html
    assert "followPlayback" in html
    assert 'id="vertical-in"' in html
    assert 'id="vertical-out"' in html
    assert 'id="vertical-follow"' in html
    assert "verticalSpan" in html


def test_frequency_viewer_can_embed_video(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"

    build_frequency_viewer(pitch_json, "audio.wav", output, video_relative_path="video.mp4")

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
