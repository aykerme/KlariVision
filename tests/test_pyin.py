from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from klarivision.pitch import AudioSource, PyinPitchExtractor


def test_pyin_tracks_a_440_hz_tone(tmp_path: Path) -> None:
    sample_rate = 22_050
    times = np.arange(int(sample_rate * 0.5)) / sample_rate
    path = tmp_path / "a4.wav"
    sf.write(path, 0.4 * np.sin(2 * np.pi * 440 * times), sample_rate)

    track = PyinPitchExtractor().extract(AudioSource(path))

    detected = track.frequency_hz[track.voiced]
    assert len(detected) > 0
    assert np.median(detected) == pytest.approx(440, abs=4)
