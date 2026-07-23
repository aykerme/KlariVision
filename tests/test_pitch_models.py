import numpy as np
import pytest

from klarivision.pitch import PitchTrack


def test_pitch_track_rejects_misaligned_arrays() -> None:
    with pytest.raises(ValueError, match="same length"):
        PitchTrack(
            time_seconds=np.array([0.0, 0.01]),
            frequency_hz=np.array([440.0]),
            voiced=np.array([True, True]),
            confidence=np.array([0.9, 0.9]),
        )
