"""Command-line bridge bundled inside the native macOS application."""

from __future__ import annotations

import argparse
from pathlib import Path

from klarivision.i18n import SUPPORTED_LANGUAGES, set_language, translate
from klarivision.local_app import PROJECT_ROOT, analyse_upload, reanalyse_existing_viewer, refresh_existing_viewer


def main() -> None:
    parser = argparse.ArgumentParser(description="KlariVision pitch analysis engine")
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--refresh-viewer", type=Path, metavar="HTML")
    parser.add_argument("--reanalyze-viewer", type=Path, metavar="HTML")
    parser.add_argument("--makam", default="huzzam")
    parser.add_argument("--karar", default="dugah")
    parser.add_argument(
        "--lang",
        choices=SUPPORTED_LANGUAGES,
        default="tr",
        help=(
            "İlerleme/hata mesajları ve grafik sayfası başlıkları için dil. "
            "Swift katmanı kullanıcının çözdüğü uygulama dilini verir."
        ),
    )
    parser.add_argument(
        "--wav",
        type=Path,
        metavar="WAV",
        help=(
            "Native Swift katmanının AVFoundation ile önceden ürettiği 48 kHz "
            "mono WAV. Verilirse ffmpeg hiç çalıştırılmaz."
        ),
    )
    parser.add_argument(
        # One engine since D-039. A command line still naming a removed engine
        # is rejected by argparse rather than silently analysed with another.
        "--engine", choices=("unified_v1",), default="unified_v1"
    )
    arguments = parser.parse_args()
    set_language(arguments.lang)

    if arguments.refresh_viewer:
        print(refresh_existing_viewer(arguments.refresh_viewer, lang=arguments.lang))
        return
    if arguments.reanalyze_viewer:
        print(reanalyse_existing_viewer(arguments.reanalyze_viewer, arguments.engine, lang=arguments.lang))
        return
    if arguments.source is None:
        parser.error(translate("cli-source-required", arguments.lang))
    viewer_url = analyse_upload(
        arguments.source.expanduser().resolve(),
        arguments.makam,
        arguments.karar,
        arguments.engine,
        precomputed_wav=arguments.wav.expanduser().resolve() if arguments.wav else None,
        lang=arguments.lang,
    )
    print((PROJECT_ROOT / viewer_url.lstrip("/")).resolve())


if __name__ == "__main__":
    main()
