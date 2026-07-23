import numpy as np
import pytest

from klarivision.ornaments import detect_vibrato
from klarivision.pitch.models import PitchTrack


def test_detect_vibrato_in_regular_pitch_oscillation() -> None:
    times = np.arange(0, 1.2, 0.01)
    frequencies = 440 * 2 ** ((18 * np.sin(2 * np.pi * 5.5 * times)) / 1200)
    track = PitchTrack(
        time_seconds=times,
        frequency_hz=frequencies,
        voiced=np.ones_like(times, dtype=bool),
        confidence=np.ones_like(times),
    )

    candidates = detect_vibrato(track)

    assert candidates
    assert candidates[0].kind == "vibrato"
    assert candidates[0].rate_hz == pytest.approx(5.5, abs=1.0)
