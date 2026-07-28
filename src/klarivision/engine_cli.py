"""Command-line bridge bundled inside the native macOS application."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from klarivision.local_app import PROJECT_ROOT, analyse_upload, refresh_existing_viewer
from klarivision.runtime_paths import resource_root


def configure_bundled_vamp() -> None:
    """Point the packaged engine at its own fast pYIN components."""
    resources = resource_root()
    sonic = resources / "tools" / "sonic-annotator" / "sonic-annotator"
    vamp_plugins = resources / "Vamp"
    if sonic.is_file():
        os.environ["KLARIVISION_SONIC_ANNOTATOR"] = str(sonic)
    if vamp_plugins.is_dir():
        os.environ["VAMP_PATH"] = str(vamp_plugins)


def main() -> None:
    configure_bundled_vamp()
    parser = argparse.ArgumentParser(description="KlariVision pitch analysis engine")
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--refresh-viewer", type=Path, metavar="HTML")
    parser.add_argument("--makam", default="huzzam")
    parser.add_argument("--karar", default="dugah")
    parser.add_argument("--engine", choices=("python", "vamp"), default="python")
    arguments = parser.parse_args()

    if arguments.refresh_viewer:
        print(refresh_existing_viewer(arguments.refresh_viewer))
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
