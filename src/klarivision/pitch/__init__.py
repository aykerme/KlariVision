"""Pitch analysis primitives for KlariVision."""

from .extractor import PitchExtractor
from .models import AudioSource, PitchTrack
from .vamp_pyin import VampPyinPitchExtractor

__all__ = [
    "AudioSource",
    "PitchExtractor",
    "PitchTrack",
    "PyinPitchExtractor",
    "PyinSettings",
    "VampPyinPitchExtractor",
    "YinPitchExtractor",
    "YinSettings",
]


def __getattr__(name: str) -> object:
    """Load the optional pure-Python pYIN implementation only on demand.

    The macOS beta uses the faster native Vamp pYIN engine, so importing a
    basic pitch model must not also require librosa and soundfile.
    """
    if name in {"PyinPitchExtractor", "PyinSettings"}:
        from .pyin import PyinPitchExtractor, PyinSettings

        return {"PyinPitchExtractor": PyinPitchExtractor, "PyinSettings": PyinSettings}[name]
    if name in {"YinPitchExtractor", "YinSettings"}:
        from .yin import YinPitchExtractor, YinSettings

        return {"YinPitchExtractor": YinPitchExtractor, "YinSettings": YinSettings}[name]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
