"""Interfaces for interchangeable pitch extraction implementations."""

from __future__ import annotations

from typing import Protocol

from .models import AudioSource, PitchTrack


class PitchExtractor(Protocol):
    """Extract the dominant melodic pitch contour from an audio source."""

    def extract(self, source: AudioSource) -> PitchTrack:
        """Return a frame-aligned pitch track."""
