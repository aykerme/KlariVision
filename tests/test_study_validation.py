import json
from pathlib import Path

import pytest

from klarivision.frequency_viewer import prepare_display_frames
from klarivision.study_validation import _manifest_for, _score


def test_synthetic_manifest_mapping_accepts_study_cache_signature() -> None:
    resolved = _manifest_for("canli_pitch_referans_v1-aabbccddeeff0011")
    assert resolved is not None
    assert resolved[1] == "canli_pitch_referans_v1.json"


def test_every_synthetic_wav_has_one_truth_mapping() -> None:
    sources = [path for path in Path("data/benchmarks").glob("*.wav") if not path.name.startswith("klarnet_gercek_")]
    if len(sources) != 26:
        pytest.skip(
            "Yerel sentetik WAV corpus'u eksik; çalışma eşleme denetimi atlandı "
            f"({len(sources)}/26 dosya mevcut)."
        )
    assert len(sources) == 26
    assert all(_manifest_for(source.name) is not None for source in sources)


def test_study_score_marks_persistent_display_error() -> None:
    truth = [{"time_seconds": index * .01, "frequency_hz": 220.0} for index in range(4)]
    observed = [{"time_seconds": index * .01, "frequency_hz": 440.0} for index in range(4)]
    result = _score(truth, observed, (), 48_000)
    assert result["harmonic_error_frames"] == 4
    assert result["serious_total_error_frames"] == 4


def test_display_preparation_is_the_viewer_surface() -> None:
    payload = {"frames": [{"time_seconds": 0, "frequency_hz": 220, "voiced": True, "confidence": .9}]}
    assert prepare_display_frames(json.loads(json.dumps(payload))) == [{"t": 0.0, "hz": 220.0}]
