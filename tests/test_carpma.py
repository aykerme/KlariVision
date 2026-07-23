import numpy as np

from klarivision.ornaments import detect_carpma
from klarivision.pitch.models import PitchTrack


def test_detect_carpma_in_a_short_returning_excursion() -> None:
    times = np.arange(0, 1.0, 0.01)
    cents = 95 * np.exp(-((times - 0.5) / 0.045) ** 2)
    track = PitchTrack(
        time_seconds=times,
        frequency_hz=440 * 2 ** (cents / 1200),
        voiced=np.ones_like(times, dtype=bool),
        confidence=np.ones_like(times),
    )
    candidates = detect_carpma(track)
    assert candidates
    assert candidates[0].kind == "carpma"
    assert candidates[0].start_seconds < 0.5 < candidates[0].end_seconds


def test_detect_carpma_rejects_a_long_melodic_slope() -> None:
    times = np.arange(0, 1.0, 0.01)
    track = PitchTrack(
        time_seconds=times,
        frequency_hz=440 * 2 ** ((times * 300) / 1200),
        voiced=np.ones_like(times, dtype=bool),
        confidence=np.ones_like(times),
    )
    assert detect_carpma(track) == []
