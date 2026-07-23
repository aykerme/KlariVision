import json

from klarivision.contour_viewer import build_viewer


def test_viewer_contains_selection_and_loop_controls(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(
        json.dumps({"frames": [{"time_seconds": 0.0, "frequency_hz": 440.0}]}),
        encoding="utf-8",
    )
    output = tmp_path / "viewer.html"

    build_viewer(pitch_json, "audio.wav", output)

    html = output.read_text(encoding="utf-8")
    assert 'id="play-selection"' in html
    assert 'id="loop-selection"' in html
    assert 'id="zoom-selection"' in html
    assert 'id="add-annotation"' in html
    assert 'id="export-annotations"' in html
    assert 'id="follow-playback"' in html
    assert 'id="window-seconds"' in html
    assert 'id="vertical-range"' in html
    assert 'value="kurdi">Kürdî' in html
    assert "Yegâh (Re)" in html
    assert "Nîm Hicaz" in html
    assert "makamDegrees" in html
    assert '"kurdi":[40,44,0,9,18,22,31]' in html
    assert "writtenOffset=-498.1" in html
    assert 'id="time-zoom-in"' in html
    assert 'id="pan-left"' in html
    assert 'id="ornament-tools" hidden' in html
    assert "function zoomToSelection()" in html
    assert "function followViewport(time)" in html
    assert "function followHorizontal(time)" in html
    assert "windowSeconds=width;if(followEnabled)" in html
    assert 'addEventListener("mousedown"' in html
    assert 'addEventListener("timeupdate"' in html
    assert "selectionPlaying=false" in html


def test_viewer_can_use_a_synchronised_video(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(
        json.dumps({"frames": [{"time_seconds": 0.0, "frequency_hz": 440.0}]}),
        encoding="utf-8",
    )
    output = tmp_path / "viewer.html"

    build_viewer(pitch_json, "audio.wav", output, video_relative_path="video.mp4")

    assert '<video id="a" controls src="video.mp4"></video>' in output.read_text(encoding="utf-8")
    assert 'class="workbench"' in output.read_text(encoding="utf-8")


def test_viewer_loads_existing_manual_annotations(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(
        json.dumps({"frames": [{"time_seconds": 0.0, "frequency_hz": 440.0}]}),
        encoding="utf-8",
    )
    output = tmp_path / "viewer.html"

    build_viewer(
        pitch_json,
        "audio.wav",
        output,
        manual_annotations=[{"kind": "vibrato", "start_seconds": 1.0, "end_seconds": 2.0}],
    )

    assert 'manualAnnotations=[{"kind":"vibrato","start_seconds":1.0,"end_seconds":2.0}]' in output.read_text(encoding="utf-8")


def test_viewer_expands_its_initial_pitch_range_for_low_register_audio(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(
        json.dumps({"frames": [{"time_seconds": 0.0, "frequency_hz": 113.0}]}),
        encoding="utf-8",
    )
    output = tmp_path / "viewer.html"

    build_viewer(pitch_json, "audio.wav", output)

    html = output.read_text(encoding="utf-8")
    assert "initialPitchLow=-2500" in html
    assert "Kaba Çârgâh" in html
    assert "Alt oktav ·" in html
    assert "Üst oktav ·" in html
