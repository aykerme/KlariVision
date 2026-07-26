import pytest

from klarivision.local_app import _form_page, _parse_byte_range, _safe_stem


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


def test_parse_byte_range_supports_media_seeking() -> None:
    assert _parse_byte_range("bytes=0-1023", 10_000) == (0, 1023)
    assert _parse_byte_range("bytes=1024-", 10_000) == (1024, 9999)
    assert _parse_byte_range("bytes=-512", 10_000) == (9488, 9999)
    assert _parse_byte_range(None, 10_000) is None
    with pytest.raises(ValueError):
        _parse_byte_range("bytes=10000-", 10_000)
