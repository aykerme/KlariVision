#!/usr/bin/env python3
"""Prepare repeatable real-clarinet clips for live-engine validation."""

from pathlib import Path

import librosa
import soundfile as sf


SOURCE = Path(
    "/Users/aydinkoyuncu/Library/Containers/com.apple.VoiceMemos/Data/tmp/"
    ".com.apple.uikit.itemprovider.temporary.hBirim/Klarnet çalımı.m4a"
)
OUTPUT = Path(__file__).resolve().parents[1] / "data" / "benchmarks"

# These ranges come from the first inspection of the recording:
# - a long, steady Re3 for stability/intonation
# - natural note changes and vibrato for responsiveness
CLIPS = {
    "klarnet_gercek_sabit_re3_v1.wav": (4.0, 14.0),
    "klarnet_gercek_gecis_vibrato_v1.wav": (20.0, 29.0),
}


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Source recording not found: {SOURCE}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    samples, sample_rate = librosa.load(SOURCE, sr=48_000, mono=True)
    for name, (start, end) in CLIPS.items():
        clip = samples[int(start * sample_rate):int(end * sample_rate)]
        destination = OUTPUT / name
        sf.write(destination, clip, sample_rate, subtype="PCM_16")
        print(f"{destination}  {end - start:.1f}s")


if __name__ == "__main__":
    main()
