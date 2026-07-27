"""Small local web app for choosing and analysing a performance recording."""

from __future__ import annotations

import argparse
import cgi
import html
import json
import mimetypes
import os
import re
import shutil
import subprocess
import unicodedata
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

import imageio_ffmpeg

from .contour_viewer import KARAR_TONES, MAKAM_PROFILES
from .frequency_viewer import build_frequency_viewer
from .pitch.models import AudioSource
from .pitch.pyin import PyinPitchExtractor
from .pitch.serialize import write_json
from .pitch.vamp_pyin import VampPyinPitchExtractor
from .runtime_paths import user_data_root


PROJECT_ROOT = user_data_root()
IMPORTS_DIR = PROJECT_ROOT / "data" / "imports"
AUDIO_DIR = PROJECT_ROOT / "data" / "audio"
OUTPUTS_DIR = PROJECT_ROOT / "outputs"
VIDEO_SUFFIXES = {".mp4", ".mov", ".m4v", ".webm"}
MEDIA_SUFFIXES = VIDEO_SUFFIXES | {".wav", ".mp3", ".m4a"}


def _safe_stem(filename: str) -> str:
    """Return a stable, filesystem-safe identifier for an uploaded recording."""
    stem = Path(filename).stem
    ascii_stem = unicodedata.normalize("NFKD", stem).encode("ascii", "ignore").decode()
    cleaned = re.sub(r"-+", "-", re.sub(r"[^a-zA-Z0-9_-]+", "-", ascii_stem)).strip("-").lower()
    return cleaned or "icra"


def _parse_byte_range(value: str | None, size: int) -> tuple[int, int] | None:
    """Return one RFC 7233 byte range, or ``None`` when no range was sent."""
    if not value:
        return None
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
    if match is None or size <= 0:
        raise ValueError("Geçersiz byte aralığı.")
    first, last = match.groups()
    if not first and not last:
        raise ValueError("Geçersiz byte aralığı.")
    if not first:
        length = int(last)
        if length <= 0:
            raise ValueError("Geçersiz byte aralığı.")
        return max(0, size - length), size - 1
    start = int(first)
    end = int(last) if last else size - 1
    if start >= size or end < start:
        raise ValueError("Karşılanamayan byte aralığı.")
    return start, min(end, size - 1)


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
h1{{margin-bottom:6px}}p{{line-height:1.5}}form{{margin-top:24px;padding:24px;border:1px solid #ddd;border-radius:12px;background:#fafafa}}input,select,button{{font:inherit}}.file-input{{position:absolute;width:1px;height:1px;opacity:0}}.file-button{{display:inline-block;margin-top:8px;padding:12px 16px;background:#1d5fa7;color:#fff;border-radius:8px;font-weight:650;cursor:pointer}}.file-button[aria-disabled="true"]{{opacity:.55;pointer-events:none}}.file-name{{display:block;margin-top:12px;color:#596775}}.progress{{display:none;margin-top:22px}}.progress.visible{{display:block}}.progress-track{{height:12px;background:#e2e8ef;border-radius:99px;overflow:hidden}}.progress-value{{height:100%;width:0;background:linear-gradient(90deg,#1d5fa7,#58a6e8);transition:width .25s ease}}.progress-label{{display:block;margin-top:9px;color:#405465;font-size:.94rem}}.notice{{padding:10px;background:#fff1f1;border-radius:7px;color:#8b2222}}
</style>
<h1>KlariVision</h1><p>Yeni bir çalışma için video veya ses dosyası seç. Analiz tamamlanana kadar burada grafik ya da video gösterilmez.</p>{notice}
<form id="analysis-form" method="post" action="/analyse" enctype="multipart/form-data">
<input id="recording" class="file-input" name="recording" type="file" accept="video/*,audio/*,.wav,.mp3,.m4a" required><label class="file-button" for="recording">Video veya ses seç</label><span id="file-name" class="file-name">Henüz dosya seçilmedi</span>
<input type="hidden" name="makam" value="huzzam"><input type="hidden" name="karar" value="dugah"><input type="hidden" name="engine" value="vamp">
<div id="progress" class="progress" aria-live="polite"><div class="progress-track"><div id="progress-value" class="progress-value"></div></div><span id="progress-label" class="progress-label">Dosya hazırlanıyor…</span></div>
</form><script>
const form=document.getElementById('analysis-form'),recording=document.getElementById('recording'),fileName=document.getElementById('file-name'),fileButton=document.querySelector('.file-button'),progress=document.getElementById('progress'),progressValue=document.getElementById('progress-value'),progressLabel=document.getElementById('progress-label');
let analysisStarted=false,shownProgress=0,analysisTimer=null;
function showProgress(value,label){{shownProgress=Math.max(shownProgress,Math.min(100,value));progressValue.style.width=`${{shownProgress}}%`;progressLabel.textContent=label}}
function startAnalysis(){{if(analysisStarted||!recording.files.length)return;analysisStarted=true;fileButton.setAttribute('aria-disabled','true');progress.classList.add('visible');showProgress(1,'Dosya yükleniyor…');const request=new XMLHttpRequest();request.open('POST','/analyse');request.upload.onprogress=event=>{{if(event.lengthComputable)showProgress(4+(event.loaded/event.total)*26,'Dosya yükleniyor…')}};request.upload.onload=()=>{{showProgress(32,'Pitch analizi yapılıyor…');analysisTimer=setInterval(()=>showProgress(Math.min(94,shownProgress+Math.max(.4,(94-shownProgress)*.06)),'Pitch analizi yapılıyor…'),350)}};request.onload=()=>{{if(analysisTimer)clearInterval(analysisTimer);if(request.status>=200&&request.status<400){{showProgress(100,'Analiz tamamlandı. Grafik hazırlanıyor…');setTimeout(()=>{{window.location.assign(request.responseURL)}},220)}}else{{analysisStarted=false;fileButton.setAttribute('aria-disabled','false');progressLabel.textContent='Analiz oluşturulamadı. Lütfen tekrar dene.'}}}};request.onerror=()=>{{if(analysisTimer)clearInterval(analysisTimer);analysisStarted=false;fileButton.setAttribute('aria-disabled','false');progressLabel.textContent='Analiz oluşturulamadı. Lütfen tekrar dene.'}};request.send(new FormData(form))}}
recording.addEventListener('change',event=>{{const file=event.target.files[0];fileName.textContent=file?.name||'Henüz dosya seçilmedi';if(file)startAnalysis()}});form.addEventListener('submit',event=>{{event.preventDefault();startAnalysis()}});
</script>"""


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
        media_path = self._media_path()
        if media_path is not None:
            self._serve_media(media_path)
            return
        super().do_GET()

    def do_HEAD(self) -> None:  # noqa: N802
        if not self.path.startswith(self._PUBLIC_PATH_PREFIXES):
            self.send_error(404)
            return
        media_path = self._media_path()
        if media_path is not None:
            self._serve_media(media_path, head_only=True)
            return
        super().do_HEAD()

    def _media_path(self) -> Path | None:
        requested = unquote(urlparse(self.path).path).lstrip("/")
        candidate = (PROJECT_ROOT / requested).resolve()
        if PROJECT_ROOT not in candidate.parents or not candidate.is_file():
            return None
        return candidate if candidate.suffix.lower() in MEDIA_SUFFIXES else None

    def _serve_media(self, path: Path, *, head_only: bool = False) -> None:
        size = path.stat().st_size
        try:
            byte_range = _parse_byte_range(self.headers.get("Range"), size)
        except ValueError:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return

        start, end = byte_range if byte_range is not None else (0, size - 1)
        length = end - start + 1
        content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self.send_response(206 if byte_range is not None else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if byte_range is not None:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return
        with path.open("rb") as source:
            source.seek(start)
            remaining = length
            while remaining:
                chunk = source.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

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


def create_server(port: int = 8765) -> ThreadingHTTPServer:
    """Create the local service used by both the browser and desktop app."""
    return ThreadingHTTPServer(("127.0.0.1", port), KlariVisionHandler)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local KlariVision recording picker.")
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()
    server = create_server(arguments.port)
    print(f"KlariVision hazır: http://127.0.0.1:{arguments.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
