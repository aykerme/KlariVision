from klarivision.local_app import _safe_stem


def test_safe_stem_keeps_a_short_local_identifier() -> None:
    assert _safe_stem("Hüsnü Şenlendirici - Taksim.mp4") == "husnu-senlendirici-taksim"
    assert _safe_stem("...wav") == "icra"
