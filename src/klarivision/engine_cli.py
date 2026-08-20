"""Command-line bridge bundled inside the native macOS application."""

from __future__ import annotations

import argparse
from pathlib import Path

from klarivision.local_app import PROJECT_ROOT, analyse_upload, reanalyse_existing_viewer, refresh_existing_viewer


def main() -> None:
    parser = argparse.ArgumentParser(description="KlariVision pitch analysis engine")
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--refresh-viewer", type=Path, metavar="HTML")
    parser.add_argument("--reanalyze-viewer", type=Path, metavar="HTML")
    parser.add_argument("--makam", default="huzzam")
    parser.add_argument("--karar", default="dugah")
    parser.add_argument("--engine", choices=("yin_v1", "pitch_engine_v2", "vpm_like"), default="yin_v1")
    arguments = parser.parse_args()

    if arguments.refresh_viewer:
        print(refresh_existing_viewer(arguments.refresh_viewer))
        return
    if arguments.reanalyze_viewer:
        print(reanalyse_existing_viewer(arguments.reanalyze_viewer, arguments.engine))
        return
    if arguments.source is None:
        parser.error("Bir ses/video dosyası veya --refresh-viewer gerekli.")
    viewer_url = analyse_upload(
        arguments.source.expanduser().resolve(),
        arguments.makam,
        arguments.karar,
        arguments.engine,
    )
    print((PROJECT_ROOT / viewer_url.lstrip("/")).resolve())


if __name__ == "__main__":
    main()
