from pathlib import Path

from klarivision.comparison_viewer import build_ab_viewer


root = Path(__file__).resolve().parents[1]
build_ab_viewer(
    root / "outputs/suslemesiz-kontrol.pyin.json",
    root / "outputs/suslemeli-karsilik.pyin.json",
    "../data/video/suslemesiz-kontrol.mp4",
    "../data/video/suslemeli-karsilik.mp4",
    root / "data/annotations/suslemesiz-kontrol.manual.v1.json",
    root / "data/annotations/suslemeli-karsilik.manual.v1.json",
    root / "outputs/susleme-ab-karsilastirma.html",
)
