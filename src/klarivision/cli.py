"""Command-line entry point for the local pYIN-to-viewer workflow."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .contour_viewer import KARAR_TONES, MAKAM_PROFILES, build_viewer
from .ornaments import detect_carpma, detect_vibrato
from .ornaments.serialize import write_candidates
from .pitch.models import AudioSource
from .pitch.pyin import PyinPitchExtractor
from .pitch.serialize import write_json


def main() -> None:
    parser = argparse.ArgumentParser(description="Create a KlariVision pYIN contour viewer.")
    parser.add_argument("audio", type=Path, help="22,050 Hz WAV input")
    parser.add_argument("--output-dir", type=Path, default=Path("outputs"))
    parser.add_argument("--makam", choices=sorted(MAKAM_PROFILES), default="huzzam")
    parser.add_argument("--karar", choices=sorted(KARAR_TONES), default="dugah")
    parser.add_argument("--video", type=Path, help="Optional local video to synchronise with the contour")
    parser.add_argument("--annotations", type=Path, help="Optional human-confirmed annotation JSON")
    parser.add_argument(
        "--ornament-experiments",
        action="store_true",
        help="Show experimental ornament candidates and manual labelling tools.",
    )
    arguments = parser.parse_args()

    audio = arguments.audio.resolve()
    if not audio.is_file():
        parser.error(f"Audio file not found: {audio}")
    if audio.suffix.lower() != ".wav":
        parser.error("The first CLI version accepts 22,050 Hz WAV files only.")
    video = arguments.video.resolve() if arguments.video else None
    if video and not video.is_file():
        parser.error(f"Video file not found: {video}")
    annotations_path = arguments.annotations.resolve() if arguments.annotations else None
    if annotations_path and not annotations_path.is_file():
        parser.error(f"Annotation file not found: {annotations_path}")

    output_dir = arguments.output_dir.resolve()
    stem = audio.stem
    pitch_json = output_dir / f"{stem}.pyin.json"
    candidates_json = output_dir / f"{stem}.ornaments.json"
    viewer = output_dir / f"{stem}.html"
    track = PyinPitchExtractor().extract(AudioSource(audio))
    write_json(track, pitch_json)
    candidates = (
        sorted(
            [*detect_vibrato(track), *detect_carpma(track)],
            key=lambda candidate: candidate.start_seconds,
        )
        if arguments.ornament_experiments
        else []
    )
    write_candidates(candidates, candidates_json)
    audio_relative_path = os.path.relpath(audio, start=viewer.parent).replace(os.sep, "/")
    build_viewer(
        pitch_json,
        audio_relative_path,
        viewer,
        default_makam=arguments.makam,
        default_karar=arguments.karar,
        ornament_candidates=json.loads(candidates_json.read_text(encoding="utf-8"))["candidates"],
        video_relative_path=(
            os.path.relpath(video, start=viewer.parent).replace(os.sep, "/") if video else None
        ),
        manual_annotations=(
            json.loads(annotations_path.read_text(encoding="utf-8"))["annotations"]
            if annotations_path
            else None
        ),
        show_ornament_tools=arguments.ornament_experiments,
    )
    print(viewer)


if __name__ == "__main__":
    main()
