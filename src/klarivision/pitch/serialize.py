"""Portable output helpers for PitchTrack results."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from .models import PitchTrack


def write_json(track: PitchTrack, output_path: Path) -> None:
    """Write one JSON object per analysis, retaining unvoiced frames as null."""

    frames = [
        {
            "time_seconds": round(float(time), 6),
            "frequency_hz": None if np.isnan(frequency) else round(float(frequency), 4),
            "voiced": bool(voiced),
            "confidence": round(float(confidence), 4),
        }
        for time, frequency, voiced, confidence in zip(
            track.time_seconds, track.frequency_hz, track.voiced, track.confidence
        )
    ]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps({"frames": frames}, ensure_ascii=False, indent=2))
