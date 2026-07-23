from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from klarivision.pitch import AudioSource, PyinPitchExtractor
from klarivision.pitch.pyin import PyinSettings


def test_pyin_tracks_a_440_hz_tone(tmp_path: Path) -> None:
    sample_rate = 22_050
    times = np.arange(int(sample_rate * 0.5)) / sample_rate
    path = tmp_path / "a4.wav"
    sf.write(path, 0.4 * np.sin(2 * np.pi * 440 * times), sample_rate)

    track = PyinPitchExtractor().extract(AudioSource(path))

    detected = track.frequency_hz[track.voiced]
    assert len(detected) > 0
    assert np.median(detected) == pytest.approx(440, abs=4)


def test_pyin_stitches_chunked_analysis_without_duplicate_times(tmp_path: Path) -> None:
    sample_rate = 22_050
    times = np.arange(int(sample_rate * 0.8)) / sample_rate
    path = tmp_path / "a4.wav"
    sf.write(path, 0.4 * np.sin(2 * np.pi * 440 * times), sample_rate)

    extractor = PyinPitchExtractor(PyinSettings(analysis_chunk_seconds=0.2))
    track = extractor.extract(AudioSource(path))

    assert np.all(np.diff(track.time_seconds) > 0)
    assert np.median(track.frequency_hz[track.voiced]) == pytest.approx(440, abs=4)
