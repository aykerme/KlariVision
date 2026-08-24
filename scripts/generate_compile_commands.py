#!/usr/bin/env python3
"""core/ altındaki C++ dosyaları için clangd derleme veritabanı üretir.

Proje CMake ile değil `scripts/test_core.sh` içindeki doğrudan clang++
çağrılarıyla doğrulanıyor. Bu betik aynı bayrakları kullanarak
`core/compile_commands.json` üretir; clangd böylece tanıma gitme, çağıran
arama ve tip bilgisi verebilir. Çıktı yereldir, Git'e girmez.

Kullanım:
    python3 scripts/generate_compile_commands.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CORE = PROJECT_ROOT / "core"
SOURCE_DIRS = ("src", "tests", "tools")


def macos_sdk_path() -> str | None:
    """Accelerate gibi sistem framework başlıkları için SDK kökü."""
    if shutil.which("xcrun") is None:
        return None
    try:
        result = subprocess.run(
            ["xcrun", "--show-sdk-path"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError):
        return None
    return result.stdout.strip() or None


def build_arguments(source: Path, sdk: str | None) -> list[str]:
    arguments = [
        "clang++",
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-I",
        str(CORE / "include"),
    ]
    if sdk:
        arguments += ["-isysroot", sdk]
    arguments += ["-c", str(source), "-o", "/dev/null"]
    return arguments


def main() -> int:
    sdk = macos_sdk_path()
    entries = []
    for directory in SOURCE_DIRS:
        for source in sorted((CORE / directory).glob("*.cpp")):
            entries.append(
                {
                    "directory": str(PROJECT_ROOT),
                    "file": str(source),
                    "arguments": build_arguments(source, sdk),
                }
            )

    destination = CORE / "compile_commands.json"
    destination.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
    print(f"{len(entries)} çeviri birimi yazıldı -> {destination}")
    if sdk is None:
        print("Uyarı: xcrun bulunamadı; sistem framework başlıkları eksik olabilir.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
