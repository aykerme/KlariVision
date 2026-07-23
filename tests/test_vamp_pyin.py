from pathlib import Path

import numpy as np

from klarivision.pitch.vamp_pyin import VampPyinPitchExtractor


def test_vamp_csv_parser_ignores_invalid_rows(tmp_path: Path) -> None:
    source = tmp_path / "pitch.csv"
    source.write_text("0.01,220.0\ninvalid,row\n0.02,221.5\n", encoding="utf-8")

    track = VampPyinPitchExtractor.from_csv(source)

    assert track.time_seconds.tolist() == [0.01, 0.02]
    assert track.frequency_hz.tolist() == [220.0, 221.5]
    assert np.all(track.voiced)
    assert np.all(track.confidence == 0.95)
