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
    assert "KlariVision 0.4.6-dinamik-koma-etiketi" in html
    assert '"minor"' in html
    assert "Ölçülen eğri değiştirilmez" in html
    assert "followPlayback" in html
    assert 'id="vertical-in"' in html
    assert 'id="vertical-out"' in html
    assert 'id="vertical-follow"' in html
    assert 'id="countdown"' in html
    assert 'id="play-toggle"' in html
    assert "function beginPlayback()" in html
    assert 'id="layout-mode"' in html
    assert 'id="new-recording"' in html
    assert "function applyLayout()" in html
    assert "function beginPanelResize(" in html
    assert "function enablePanelResize(" in html
    assert ".workspace.side-right{grid-template-columns" in html
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
    assert "function restartLoopAtA()" in html
    assert "function playLoopFromA()" in html
    assert "function setMediaReady(ready)" in html
    assert "media.addEventListener('canplay'" in html
    assert "media.addEventListener('ended'" in html
    assert "media.paused" in html
    assert "drag.moved" in html
    assert 'id="scale-mode"' in html
    assert 'id="tonic"' in html
    assert 'id="sol-clarinet"' not in html
    assert "SOL_CLARINET_NOTE_OFFSET" not in html
    assert "yy=y(p.hz)" in html
    assert "function scaleNotes()" in html
    assert 'value="turkish"' in html
    assert "function turkishNotes()" in html
    assert "turkishReference" in html
    assert "display_notation" in html
    assert 'value="nihavent"' in html
    assert ">Nihavend</option>" in html
    assert "function nihaventNotes()" in html
    assert "function makamNotes(mode,labelMode)" in html
    assert "function makamLabel(name,octave,delta=0)" in html
    assert "steps[degree]-defaultSteps[degree]" in html
    assert '"nihavent":[9,4,9,9,4,9,9]' in html
    assert "const solClarinetTonic=Number(tonicInput.value),soundingTonic=(solClarinetTonic+7)%12" in html
    assert 'value="kurdi"' in html
    assert ">Kürdi</option>" in html
    assert "function kurdiNotes()" in html
    assert '"kurdi":[4,9,9,9,4,9,9]' in html
    assert 'value="ussak"' in html
    assert ">Uşşak</option>" in html
    assert "function ussakNotes()" in html
    assert '"ussak":[8,5,9,9,4,9,9]' in html
    assert "Rast (karar)" not in html
    assert 'class="interval-guide"' in html
    assert "Koma rehberi" in html
    assert "Küçük mücennep" in html
    assert "♯5 / ♭5" in html
    assert 'id="makam-settings-open"' in html
    assert 'id="makam-settings"' in html
    assert "Toplam: ${total} / 53 koma" in html
    assert "makamSettingsApply.disabled=total!==53" in html
    assert "localStorage.setItem(makamSettingsKey" in html
    assert 'id="makam-status"' in html
    assert "function updateMakamStatus()" in html


def test_frequency_viewer_can_embed_video(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"
    build_frequency_viewer(pitch_json, "audio.wav", output, video_relative_path="video.mp4")

    assert '<video id="media" controls src="video.mp4"></video>' in output.read_text(encoding="utf-8")


def test_frequency_viewer_uses_compact_audio_player(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"
    build_frequency_viewer(pitch_json, "audio.wav", output)

    html = output.read_text(encoding="utf-8")
    assert 'class="audio-content"' in html
    assert '<strong>Ses kaydı</strong>' in html
    assert 'const audioOnly=true;' in html
    assert 'workspace audio-only' in html


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
