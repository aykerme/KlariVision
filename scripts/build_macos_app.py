"""Build a self-contained macOS KlariVision.app bundle with PyInstaller."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    resources = [
        (PROJECT_ROOT / "data" / "reference", "data/reference"),
        (PROJECT_ROOT / "tools" / "sonic-annotator", "tools/sonic-annotator"),
    ]
    command = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--windowed",
        "--name",
        "KlariVision",
        "--osx-bundle-identifier",
        "com.klarivision.app",
        "--paths",
        str(PROJECT_ROOT / "src"),
        "--collect-all",
        "webview",
        "--collect-all",
        "yt_dlp",
    ]
    for source, target in resources:
        command.extend(("--add-data", f"{source}:{target}"))
    command.append(str(PROJECT_ROOT / "src" / "klarivision" / "desktop_app.py"))
    subprocess.run(command, cwd=PROJECT_ROOT, check=True)


if __name__ == "__main__":
    main()
