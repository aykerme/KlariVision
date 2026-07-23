from pathlib import Path

from klarivision.contour_viewer import build_viewer

root = Path(__file__).resolve().parents[1]
build_viewer(
    root / "outputs/husnu-senlendirici-huzzam-taksim-closeup.pyin.json",
    "../data/audio/husnu-senlendirici-huzzam-taksim-closeup.wav",
    root / "outputs/husnu-senlendirici-huzzam-taksim-closeup.html",
)
