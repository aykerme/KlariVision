import json

from klarivision.frequency_viewer import build_frequency_viewer


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
    assert "duyulan frekans" in html
    assert '"Si2",123.47' in html
    assert "Makam, karar, Sol klarnet yazılı notası" in html
    assert "followPlayback" in html


def test_frequency_viewer_can_embed_video(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"

    build_frequency_viewer(pitch_json, "audio.wav", output, video_relative_path="video.mp4")

    assert '<video id="media" controls src="video.mp4"></video>' in output.read_text(encoding="utf-8")
