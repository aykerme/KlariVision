from klarivision.local_app import _form_page, _safe_stem


def test_safe_stem_keeps_a_short_local_identifier() -> None:
    assert _safe_stem("Hüsnü Şenlendirici - Taksim.mp4") == "husnu-senlendirici-taksim"
    assert _safe_stem("...wav") == "icra"


def test_recording_picker_starts_analysis_after_file_selection() -> None:
    page = _form_page()

    assert 'id="analysis-form"' in page
    assert 'id="progress"' in page
    assert "function startAnalysis()" in page
    assert "recording.addEventListener('change'" in page
    assert "request.upload.onprogress" in page
    assert "window.location.assign(request.responseURL)" in page
    assert "Pitch analizini oluştur" not in page
