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
    assert "KlariVision v0.6 Beta 1" in html
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
    assert "function updateVerticalFollow()" in html
    assert "edge=verticalSpan*.45,restingEdge=verticalSpan*.35" in html
    assert "verticalCenter+=((middle(target)-verticalCenter)*.14)" not in html
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
    assert "function makamLabel(name,octave,step,rootKoma)" in html
    assert "naturalKomaByPitchClass" in html
    assert "naturalKomaByName" in html
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
    assert 'value="hicaz"' in html
    assert ">Hicaz</option>" in html
    assert "function hicazNotes()" in html
    assert '"hicaz":[5,12,5,9,8,5,9]' in html
    assert 'value="kurdilihicazkar"' in html
    assert ">Kürdilihicazkâr</option>" in html
    assert "function kurdilihicazkarNotes()" in html
    assert '"kurdilihicazkar":[4,9,9,9,4,9,9]' in html
    assert 'value="hicazkar"' in html
    assert ">Hicazkâr</option>" in html
    assert "function hicazkarNotes()" in html
    assert '"hicazkar":[5,12,5,9,5,12,5]' in html
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
    assert 'id="playback-rate"' in html
    assert 'value="0.10"' in html
    assert 'value="0.15"' in html
    assert 'value="1.00" selected' in html
    assert "media.playbackRate" in html
    assert "function organisePracticeControls()" in html
    assert "contextStatus.id='context-status'" in html
    assert "deferredControls.forEach(control=>control.hidden=true)" in html
    assert "const left=140" in html
    assert "chartGrid.after(timeScroll)" in html
    assert "height:calc(var(--chart-height) + 130px)" in html
    assert "function setPlaybackRate(value)" in html
    assert "Math.min(2,Math.round(value*20)/20)" in html
    assert "media.defaultPlaybackRate=rate;media.playbackRate=rate" in html
    assert "speedStepper.append(speedDown,playbackRateStatus,speedUp)" in html
    assert "window.klariVisionStudyViewer" in html
    assert "snapshot()" in html
    assert "loopEnabled,loopA,loopB,theme:activeAppearance()" in html
    assert "value.type==='seek'" in html
    assert "nearest&&delta<=.15?nearest.hz:null" in html
    assert "if(value==='toggle')" in html
    assert "if(value==='follow')" in html
    assert "function installTooltips()" in html
    assert "klarivision-tooltip" in html
    assert "transport-more" not in html
    assert "graphAppearanceKey='klarivision-graph-appearance-v1'" in html
    assert "defaultGraphAppearance={pitchHex:'#0A84FF',noteGuideHex:'#8E8E93'}" in html
    assert "function setGraphAppearance(value" in html
    assert "setGraphAppearance," in html
    assert "settingsSnapshot()" in html
    assert "applySettings(value)" in html
    assert "localStorage.setItem(makamSettingsKey" in html
    assert "standaloneSettingsStyle" in html
    assert "max-height:calc(100vh - 28px);overflow-y:auto" in html
    assert "id='graph-pitch-color'" in html
    assert "id='graph-note-guide-color'" in html
    assert "Varsayılan renklere dön" in html
    assert "colorWithAlpha(palette.guide,.42)" in html
    assert "colorWithAlpha(palette.guide,.88)" in html
    assert "p.t-previous.t>.040" in html


def test_frequency_viewer_can_embed_video(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"
    build_frequency_viewer(pitch_json, "audio.wav", output, video_relative_path="video.mp4")

    assert '<video id="media" controls src="video.mp4"></video>' in output.read_text(encoding="utf-8")


def test_frequency_viewer_keeps_validation_data_off_the_pitch_graph(tmp_path) -> None:
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": []}), encoding="utf-8")
    output = tmp_path / "viewer.html"
    validation = {
        "reference_frames": [{"t": 0.0, "hz": 220.0}],
        "raw": {"serious_total_error_frames": 2},
        "display": {"serious_total_error_frames": 1, "serious_error_ranges": []},
    }
    build_frequency_viewer(pitch_json, "audio.wav", output, validation=validation)
    html = output.read_text(encoding="utf-8")
    assert "const validation=" in html
    assert 'id="show-measured"' not in html
    assert 'id="show-reference"' not in html
    assert "Matematiksel hedef" not in html
    assert "validation.display.serious_error_ranges" not in html
    assert "validation.reference_frames" not in html


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


def test_frequency_viewer_keeps_supported_low_register_pitch() -> None:
    result = prepare_display_frames({"frames": [
        {"time_seconds": 0.0, "frequency_hz": 82.4069, "voiced": True, "confidence": .9},
    ]})
    assert result == [{"t": 0.0, "hz": 82.4069}]
