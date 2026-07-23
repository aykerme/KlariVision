"""Stable data models shared by all pitch-extraction algorithms."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numpy.typing import NDArray


@dataclass(frozen=True)
class AudioSource:
    """A local audio file and the sample rate requested for analysis."""

    path: Path
    target_sample_rate: int = 22_050


@dataclass(frozen=True)
class PitchTrack:
    """Frame-aligned pitch results."""

    time_seconds: NDArray[np.float64]
    frequency_hz: NDArray[np.float64]
    voiced: NDArray[np.bool_]
    confidence: NDArray[np.float64]

    def __post_init__(self) -> None:
        length = len(self.time_seconds)
        if any(
            len(series) != length
            for series in (self.frequency_hz, self.voiced, self.confidence)
        ):
            raise ValueError("All PitchTrack arrays must have the same length.")
