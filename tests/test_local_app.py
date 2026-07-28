from pathlib import Path

import pytest

from klarivision.local_app import (
    analyse_upload,
    _analysis_stem,
    _file_signature,
    _form_page,
    _load_recent_analyses,
    _parse_byte_range,
    refresh_existing_viewer,
    _safe_stem,
    _store_recent_analysis,
)


def test_safe_stem_keeps_a_short_local_identifier() -> None:
    assert _safe_stem("Hüsnü Şenlendirici - Taksim.mp4") == "husnu-senlendirici-taksim"
    assert _safe_stem("...wav") == "icra"


def test_recording_picker_starts_analysis_after_file_selection() -> None:
    page = _form_page()

    assert 'id="analysis-form"' in page
    assert 'id="link-form"' in page
    assert 'id="media-url"' in page
    assert 'id="progress"' in page
    assert "function startAnalysis()" in page
    assert "function startLinkAnalysis()" in page
    assert "recording.addEventListener('change'" in page
    assert "linkForm.addEventListener('submit'" in page
    assert 'enctype="application/x-www-form-urlencoded"' in page
    assert "event.preventDefault();startLinkAnalysis()" not in page
    assert "mediaUrl.disabled=locked" not in page
    assert "request.upload.onprogress" in page
    assert "window.location.assign(request.responseURL)" in page
    assert "Pitch analizini oluştur" not in page


def test_file_signature_changes_when_source_changes(tmp_path) -> None:
    source = tmp_path / "icra.mp4"
    source.write_bytes(b"first")
    first_signature = _file_signature(source)

    source.write_bytes(b"second")

    assert _file_signature(source) != first_signature


def test_analysis_stem_ignores_temporary_import_ids() -> None:
    assert _analysis_stem(Path("icra-1234abcd.mp4")) == "icra"
    assert _analysis_stem(Path("link-1234abcd56.mp4")) == "link"


def test_analyse_upload_reuses_cached_pitch_when_import_name_changes(tmp_path, monkeypatch) -> None:
    first_source = tmp_path / "icra-1234abcd.mp4"
    second_source = tmp_path / "icra-5678abcd.mp4"
    first_source.write_bytes(b"same-media")
    second_source.write_bytes(b"same-media")
    monkeypatch.setattr("klarivision.local_app.PROJECT_ROOT", tmp_path)
    monkeypatch.setattr("klarivision.local_app.IMPORTS_DIR", tmp_path / "data" / "imports")
    monkeypatch.setattr("klarivision.local_app.AUDIO_DIR", tmp_path / "data" / "audio")
    monkeypatch.setattr("klarivision.local_app.OUTPUTS_DIR", tmp_path / "outputs")
    monkeypatch.setattr("klarivision.local_app.RECENTS_PATH", tmp_path / "data" / "recent_analyses.json")

    calls = {"to_wav": 0, "extract": 0}

    def fake_to_wav(_source, destination):
        calls["to_wav"] += 1
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"wav")

    class FakeExtractor:
        def extract(self, _audio_source):
            calls["extract"] += 1
            return object()

    def fake_write_json(_track, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text('{"frames":[]}', encoding="utf-8")

    def fake_build_frequency_viewer(_pitch_json, _audio_path, viewer, **_kwargs):
        viewer.parent.mkdir(parents=True, exist_ok=True)
        viewer.write_text("<html></html>", encoding="utf-8")

    monkeypatch.setattr("klarivision.local_app._to_wav", fake_to_wav)
    monkeypatch.setattr("klarivision.local_app.VampPyinPitchExtractor", FakeExtractor)
    monkeypatch.setattr("klarivision.local_app.write_json", fake_write_json)
    monkeypatch.setattr("klarivision.local_app.build_frequency_viewer", fake_build_frequency_viewer)

    first = analyse_upload(first_source, "huzzam", "dugah")
    second = analyse_upload(second_source, "huzzam", "dugah")

    assert first == second
    assert calls == {"to_wav": 1, "extract": 1}


def test_analyse_upload_keeps_selected_video_in_app_imports(tmp_path, monkeypatch) -> None:
    source = tmp_path / "Masaüstü Videosu.mp4"
    source.write_bytes(b"video-media")
    monkeypatch.setattr("klarivision.local_app.PROJECT_ROOT", tmp_path)
    monkeypatch.setattr("klarivision.local_app.IMPORTS_DIR", tmp_path / "data" / "imports")
    monkeypatch.setattr("klarivision.local_app.AUDIO_DIR", tmp_path / "data" / "audio")
    monkeypatch.setattr("klarivision.local_app.OUTPUTS_DIR", tmp_path / "outputs")
    monkeypatch.setattr("klarivision.local_app.RECENTS_PATH", tmp_path / "data" / "recent_analyses.json")

    captured: dict[str, str | None] = {}

    def fake_to_wav(_source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"wav")

    class FakeExtractor:
        def extract(self, _audio_source):
            return object()

    def fake_write_json(_track, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text('{"frames":[]}', encoding="utf-8")

    def fake_build_frequency_viewer(_pitch_json, _audio_path, viewer, **kwargs):
        captured["video_relative_path"] = kwargs["video_relative_path"]
        viewer.parent.mkdir(parents=True, exist_ok=True)
        viewer.write_text("<html></html>", encoding="utf-8")

    monkeypatch.setattr("klarivision.local_app._to_wav", fake_to_wav)
    monkeypatch.setattr("klarivision.local_app.VampPyinPitchExtractor", FakeExtractor)
    monkeypatch.setattr("klarivision.local_app.write_json", fake_write_json)
    monkeypatch.setattr("klarivision.local_app.build_frequency_viewer", fake_build_frequency_viewer)

    analyse_upload(source, "huzzam", "dugah")

    imported = tmp_path / "data" / "imports" / f"masaustu-videosu-{_file_signature(source)}.mp4"
    assert imported.is_file()
    assert captured["video_relative_path"] == f"../data/imports/{imported.name}"


def test_refresh_existing_viewer_preserves_video_tag(tmp_path, monkeypatch) -> None:
    outputs = tmp_path / "outputs"
    viewer = outputs / "ornek.html"
    audio = tmp_path / "data" / "audio" / "ornek.wav"
    pitch = outputs / "ornek.vamp.json"
    outputs.mkdir(parents=True)
    audio.parent.mkdir(parents=True)
    audio.write_bytes(b"wav")
    pitch.write_text('{"frames":[]}', encoding="utf-8")
    viewer.write_text('<video id="media" controls src="../data/imports/ornek.mp4"></video>', encoding="utf-8")
    monkeypatch.setattr("klarivision.local_app.OUTPUTS_DIR", outputs)
    monkeypatch.setattr("klarivision.local_app.AUDIO_DIR", audio.parent)
    captured: dict[str, str | None] = {}

    def fake_build_frequency_viewer(_pitch_json, _audio_path, _viewer, **kwargs):
        captured["video_relative_path"] = kwargs["video_relative_path"]

    monkeypatch.setattr("klarivision.local_app.build_frequency_viewer", fake_build_frequency_viewer)

    refresh_existing_viewer(viewer)

    assert captured["video_relative_path"] == "../data/imports/ornek.mp4"


def test_recent_analyses_only_lists_existing_viewers(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr("klarivision.local_app.PROJECT_ROOT", tmp_path)
    monkeypatch.setattr("klarivision.local_app.RECENTS_PATH", tmp_path / "data" / "recent_analyses.json")
    monkeypatch.setattr("klarivision.local_app.OUTPUTS_DIR", tmp_path / "outputs")
    viewer = tmp_path / "outputs" / "ornek.html"
    viewer.parent.mkdir(parents=True)
    viewer.write_text("<html></html>", encoding="utf-8")

    _store_recent_analysis(Path("/tmp/Örnek Çalım.mp4"), "/outputs/ornek.html", cache_hit=True)

    assert _load_recent_analyses() == [
        {
            "viewer_url": "/outputs/ornek.html",
            "label": "Örnek Çalım.mp4",
            "analysed_at": _load_recent_analyses()[0]["analysed_at"],
            "cache_hit": True,
        }
    ]


def test_parse_byte_range_supports_media_seeking() -> None:
    assert _parse_byte_range("bytes=0-1023", 10_000) == (0, 1023)
    assert _parse_byte_range("bytes=1024-", 10_000) == (1024, 9999)
    assert _parse_byte_range("bytes=-512", 10_000) == (9488, 9999)
    assert _parse_byte_range(None, 10_000) is None
    with pytest.raises(ValueError):
        _parse_byte_range("bytes=10000-", 10_000)
