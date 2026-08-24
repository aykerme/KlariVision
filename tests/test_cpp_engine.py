from pathlib import Path
import json

from klarivision.pitch import cpp_engine


def _executable(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"test")
    path.chmod(0o755)
    return path


def test_finds_packaged_pitch_track_cli(monkeypatch, tmp_path: Path) -> None:
    expected = _executable(tmp_path / "tools" / "klarivision-pitch-track-cli")
    monkeypatch.delenv("KLARIVISION_PITCH_TRACK_CLI", raising=False)
    monkeypatch.setattr(cpp_engine, "resource_root", lambda: tmp_path)

    assert cpp_engine.executable() == expected


def test_finds_beta_build_3_nested_pitch_track_cli(monkeypatch, tmp_path: Path) -> None:
    expected = _executable(
        tmp_path
        / "tools"
        / "klarivision-pitch-track-cli"
        / "klarivision-pitch-track-cli"
    )
    monkeypatch.delenv("KLARIVISION_PITCH_TRACK_CLI", raising=False)
    monkeypatch.setattr(cpp_engine, "resource_root", lambda: tmp_path)

    assert cpp_engine.executable() == expected


def test_reads_the_v1_cli_contract(monkeypatch, tmp_path: Path) -> None:
    binary = _executable(tmp_path / "klarivision-pitch-track-cli")
    payload = {
        "abi_version": 1,
        "profile": "offline_track_v1",
        "sample_rate_hz": 48000,
        "window_size": 1536,
        "hop_size": 512,
        "engines": ["yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1"],
    }

    class Completed:
        stdout = json.dumps(payload)

    monkeypatch.setattr(cpp_engine, "executable", lambda: binary)
    monkeypatch.setattr(cpp_engine.subprocess, "run", lambda *args, **kwargs: Completed())
    assert cpp_engine.contract() == payload
