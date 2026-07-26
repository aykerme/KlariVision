"""Small local web app for choosing and analysing a performance recording."""

from __future__ import annotations

import argparse
import cgi
import html
import json
import os
import re
import shutil
import subprocess
import unicodedata
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

import imageio_ffmpeg

from .contour_viewer import KARAR_TONES, MAKAM_PROFILES
from .frequency_viewer import build_frequency_viewer
from .pitch.models import AudioSource
from .pitch.pyin import PyinPitchExtractor
from .pitch.serialize import write_json
from .pitch.vamp_pyin import VampPyinPitchExtractor


PROJECT_ROOT = Path(__file__).resolve().parents[2]
IMPORTS_DIR = PROJECT_ROOT / "data" / "imports"
AUDIO_DIR = PROJECT_ROOT / "data" / "audio"
OUTPUTS_DIR = PROJECT_ROOT / "outputs"
VIDEO_SUFFIXES = {".mp4", ".mov", ".m4v", ".webm"}


def _safe_stem(filename: str) -> str:
    """Return a stable, filesystem-safe identifier for an uploaded recording."""
    stem = Path(filename).stem
    ascii_stem = unicodedata.normalize("NFKD", stem).encode("ascii", "ignore").decode()
    cleaned = re.sub(r"-+", "-", re.sub(r"[^a-zA-Z0-9_-]+", "-", ascii_stem)).strip("-").lower()
    return cleaned or "icra"


def _to_wav(source: Path, destination: Path) -> None:
    """Extract mono, 22.05 kHz WAV audio required by the pYIN extractor."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            imageio_ffmpeg.get_ffmpeg_exe(),
            "-y",
            "-i",
            str(source),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "22050",
            str(destination),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def analyse_upload(source: Path, makam: str, karar: str, engine: str = "vamp") -> str:
    """Analyse one local media file and return its project-relative viewer URL."""
    if makam not in MAKAM_PROFILES or karar not in KARAR_TONES:
        raise ValueError("Geçersiz makam veya karar sesi seçimi.")

    analysis_id = f"{_safe_stem(source.name)}-{uuid.uuid4().hex[:8]}"
    wav = AUDIO_DIR / f"{analysis_id}.wav"
    if engine not in {"vamp", "python"}:
        raise ValueError("Geçersiz pitch motoru seçimi.")
    pitch_json = OUTPUTS_DIR / f"{analysis_id}.{engine}.json"
    viewer = OUTPUTS_DIR / f"{analysis_id}.html"
    _to_wav(source, wav)
    extractor = VampPyinPitchExtractor() if engine == "vamp" else PyinPitchExtractor()
    track = extractor.extract(AudioSource(wav))
    write_json(track, pitch_json)
    build_frequency_viewer(
        pitch_json,
        os.path.relpath(wav, start=viewer.parent).replace(os.sep, "/"),
        viewer,
        video_relative_path=(
            os.path.relpath(source, start=viewer.parent).replace(os.sep, "/")
            if source.suffix.lower() in VIDEO_SUFFIXES
            else None
        ),
    )
    return "/" + quote(viewer.relative_to(PROJECT_ROOT).as_posix())


def _form_page(message: str = "") -> str:
    makam_options = "".join(
        f'<option value="{key}">{label}</option>' for key, label in MAKAM_PROFILES.items()
    )
    karar_options = "".join(
        f'<option value="{key}">{value["name"]}</option>'
        for key, value in KARAR_TONES.items()
    )
    notice = f'<p class="notice">{html.escape(message)}</p>' if message else ""
    return f"""<!doctype html><meta charset="utf-8"><title>KlariVision</title>
<style>
body{{font-family:system-ui;max-width:720px;margin:56px auto;padding:0 20px;color:#1e1e1e}}
h1{{margin-bottom:6px}}p{{line-height:1.5}}form{{margin-top:24px;padding:24px;border:1px solid #ddd;border-radius:12px;background:#fafafa}}input,select,button{{font:inherit}}.file-input{{position:absolute;width:1px;height:1px;opacity:0}}.file-button{{display:inline-block;margin-top:8px;padding:12px 16px;background:#1d5fa7;color:#fff;border-radius:8px;font-weight:650;cursor:pointer}}.file-name{{display:block;margin-top:12px;color:#596775}}button{{margin-top:22px;padding:10px 14px;background:#1d5fa7;color:white;border:0;border-radius:7px;cursor:pointer}}.notice{{padding:10px;background:#fff1f1;border-radius:7px;color:#8b2222}}
</style>
<h1>KlariVision</h1><p>Yeni bir çalışma için video veya ses dosyası seç. Analiz tamamlanana kadar burada grafik ya da video gösterilmez.</p>{notice}
<form method="post" action="/analyse" enctype="multipart/form-data">
<input id="recording" class="file-input" name="recording" type="file" accept="video/*,audio/*,.wav,.mp3,.m4a" required><label class="file-button" for="recording">Video veya ses seç</label><span id="file-name" class="file-name">Henüz dosya seçilmedi</span>
<input type="hidden" name="makam" value="huzzam"><input type="hidden" name="karar" value="dugah"><input type="hidden" name="engine" value="vamp">
<button type="submit">Pitch analizini oluştur</button>
</form><script>document.getElementById('recording').addEventListener('change',event=>{{document.getElementById('file-name').textContent=event.target.files[0]?.name||'Henüz dosya seçilmedi'}})</script>"""


class KlariVisionHandler(SimpleHTTPRequestHandler):
    """Serve project files and accept one local recording upload at a time."""

    _PUBLIC_PATH_PREFIXES = ("/outputs/", "/data/audio/", "/data/imports/")

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, directory=str(PROJECT_ROOT), **kwargs)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in {"/", "/index.html"}:
            self._send_html(_form_page())
            return
        if not self.path.startswith(self._PUBLIC_PATH_PREFIXES):
            self.send_error(404)
            return
        super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/analyse":
            self.send_error(404)
            return
        try:
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": self.headers["Content-Type"]},
            )
            recording = form["recording"]
            if not getattr(recording, "filename", None):
                raise ValueError("Lütfen bir video veya ses dosyası seç.")
            suffix = Path(recording.filename).suffix.lower()
            if not suffix:
                raise ValueError("Dosyanın uzantısı tanınamadı.")
            IMPORTS_DIR.mkdir(parents=True, exist_ok=True)
            saved = IMPORTS_DIR / f"{_safe_stem(recording.filename)}-{uuid.uuid4().hex[:8]}{suffix}"
            with saved.open("wb") as target:
                shutil.copyfileobj(recording.file, target)
            result_url = analyse_upload(
                saved,
                form.getfirst("makam", "huzzam"),
                form.getfirst("karar", "dugah"),
                form.getfirst("engine", "vamp"),
            )
        except Exception as error:  # User-facing local app; preserve the server process after an error.
            self._send_html(_form_page(f"Analiz oluşturulamadı: {error}"), status=400)
            return
        self.send_response(303)
        self.send_header("Location", result_url)
        self.end_headers()

    def _send_html(self, page: str, status: int = 200) -> None:
        encoded = page.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local KlariVision recording picker.")
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), KlariVisionHandler)
    print(f"KlariVision hazır: http://127.0.0.1:{arguments.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
