"""Small local web app for choosing and analysing a performance recording."""

from __future__ import annotations

import argparse
import cgi
import hashlib
import html
import json
import mimetypes
import os
import re
import shutil
import subprocess
from datetime import datetime
import unicodedata
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

import imageio_ffmpeg

from .contour_viewer import KARAR_TONES, MAKAM_PROFILES
from .frequency_viewer import build_frequency_viewer, prepare_display_frames
from .pitch.cpp_engine import ENGINES as CPP_ENGINES, OFFLINE_TRACK_REVISION, extract as extract_cpp_pitch
from .pitch.models import AudioSource
from .pitch.serialize import write_json
from .pitch.vamp_pyin import VampPyinPitchExtractor
from .runtime_paths import user_data_root
from .study_validation import validation_for_study


PROJECT_ROOT = user_data_root()
IMPORTS_DIR = PROJECT_ROOT / "data" / "imports"
AUDIO_DIR = PROJECT_ROOT / "data" / "audio"
OUTPUTS_DIR = PROJECT_ROOT / "outputs"
RECENTS_PATH = PROJECT_ROOT / "data" / "recent_analyses.json"
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


def _file_signature(path: Path) -> str:
    """Return a stable content signature for deciding whether pitch can be reused."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()[:16]


def _analysis_stem(source: Path) -> str:
    """Return a readable stem without the temporary import id."""
    stem = _safe_stem(source.name)
    stem = re.sub(r"-[0-9a-f]{8,16}$", "", stem)
    if re.fullmatch(r"link(?:-[0-9a-f]{8,16})?", stem):
        return "link"
    return stem or "icra"


def _load_recent_analyses() -> list[dict[str, object]]:
    """Return usable recent analyses, discarding stale or malformed entries."""
    try:
        entries = json.loads(RECENTS_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        entries = []
    if not isinstance(entries, list):
        entries = []
    usable: list[dict[str, object]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        viewer_url = entry.get("viewer_url")
        if not isinstance(viewer_url, str) or not viewer_url.startswith("/outputs/"):
            continue
        if (PROJECT_ROOT / viewer_url.lstrip("/")).is_file():
            usable.append(entry)
    known_urls = {str(entry["viewer_url"]) for entry in usable}
    if OUTPUTS_DIR.is_dir():
        for viewer in sorted(OUTPUTS_DIR.glob("*.html"), key=lambda path: path.stat().st_mtime, reverse=True):
            viewer_url = "/outputs/" + quote(viewer.name)
            if viewer_url in known_urls:
                continue
            try:
                if "<title>KlariVision" not in viewer.read_text(encoding="utf-8")[:500]:
                    continue
            except OSError:
                continue
            usable.append(
                {
                    "viewer_url": viewer_url,
                    "label": viewer.stem.replace("-", " "),
                    "analysed_at": datetime.fromtimestamp(viewer.stat().st_mtime).astimezone().strftime("%d.%m.%Y %H:%M"),
                    "cache_hit": True,
                }
            )
            known_urls.add(viewer_url)
    return usable[:12]


def _store_recent_analysis(source: Path, viewer_url: str, *, cache_hit: bool) -> None:
    """Persist a compact list of analyses that can be reopened from the start page."""
    RECENTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "viewer_url": viewer_url,
        "label": source.name,
        "analysed_at": datetime.now().astimezone().strftime("%d.%m.%Y %H:%M"),
        "cache_hit": cache_hit,
    }
    entries = [item for item in _load_recent_analyses() if item.get("viewer_url") != viewer_url]
    temporary = RECENTS_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps([entry, *entries][:12], ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(RECENTS_PATH)


def _to_wav(source: Path, destination: Path) -> None:
    """Extract portable mono 48 kHz PCM for the production C++ engines."""
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
            "48000",
            str(destination),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def _import_from_url(url: str) -> Path:
    """Download one user-supplied web video into the local imports folder."""
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("Geçerli bir internet bağlantısı gir.")
    try:
        from yt_dlp import YoutubeDL
    except ImportError as error:  # pragma: no cover - depends on the packaged app environment.
        raise RuntimeError(
            "Linkten açma için yt-dlp bileşeni gerekli. Uygulamayı bu bileşenle paketlemeliyiz."
        ) from error

    IMPORTS_DIR.mkdir(parents=True, exist_ok=True)
    output_template = str(IMPORTS_DIR / "link-%(id)s.%(ext)s")
    options = {
        "format": "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/best",
        "merge_output_format": "mp4",
        "noplaylist": True,
        "outtmpl": output_template,
        "ffmpeg_location": imageio_ffmpeg.get_ffmpeg_exe(),
        "quiet": True,
        "noprogress": True,
        "no_warnings": True,
    }
    downloaded: Path | None = None
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            with YoutubeDL(options) as downloader:
                info = downloader.extract_info(url, download=True)
                downloaded = Path(downloader.prepare_filename(info))
            break
        except Exception as error:  # YouTube occasionally rejects a first extraction attempt.
            last_error = error
            if attempt:
                raise RuntimeError(f"Bağlantıdan medya alınamadı: {error}") from error
    if downloaded is None:
        raise RuntimeError(f"Bağlantıdan medya alınamadı: {last_error}")
    merged = downloaded.with_suffix(".mp4")
    if merged.is_file():
        return merged
    if downloaded.is_file():
        return downloaded
    raise RuntimeError("Bağlantıdan medya alınamadı.")


def _persist_video_source(source: Path, analysis_id: str) -> Path:
    """Keep locally selected videos inside the app data folder.

    The native viewer can reliably read files below Application Support.  A
    video selected from Downloads/Desktop therefore needs a local copy, while
    audio is already represented by the extracted WAV cache.
    """
    if source.suffix.lower() not in VIDEO_SUFFIXES:
        return source
    IMPORTS_DIR.mkdir(parents=True, exist_ok=True)
    if source.parent.resolve() == IMPORTS_DIR.resolve():
        return source
    destination = IMPORTS_DIR / f"{analysis_id}{source.suffix.lower()}"
    if not destination.is_file():
        shutil.copy2(source, destination)
    return destination


def analyse_upload(source: Path, makam: str, karar: str, engine: str = "vamp") -> str:
    """Analyse one local media file and return its project-relative viewer URL."""
    if makam not in MAKAM_PROFILES or karar not in KARAR_TONES:
        raise ValueError("Geçersiz makam veya karar sesi seçimi.")

    signature = _file_signature(source)
    analysis_id = f"{_analysis_stem(source)}-{signature}"
    media_source = _persist_video_source(source, analysis_id)
    wav = AUDIO_DIR / f"{analysis_id}.wav"
    if engine not in {"vamp", "python", *CPP_ENGINES}:
        raise ValueError("Geçersiz pitch motoru seçimi.")
    profile = f".offline_track_v1.{OFFLINE_TRACK_REVISION}" if engine in CPP_ENGINES else ""
    pitch_json = OUTPUTS_DIR / f"{analysis_id}.{engine}{profile}.json"
    viewer = OUTPUTS_DIR / f"{analysis_id}.html"
    if not wav.is_file():
        _to_wav(media_source, wav)
    cache_hit = pitch_json.is_file()
    if not cache_hit:
        if engine in CPP_ENGINES:
            extract_cpp_pitch(wav, engine, pitch_json)
        else:
            if engine == "vamp":
                extractor = VampPyinPitchExtractor()
            else:
                # Kept only for development comparisons; packaged production
                # analysis always routes through one of the C++ engines.
                from .pitch.pyin import PyinPitchExtractor

                extractor = PyinPitchExtractor()
            track = extractor.extract(AudioSource(wav))
            write_json(track, pitch_json)
    build_frequency_viewer(
        pitch_json,
        os.path.relpath(wav, start=viewer.parent).replace(os.sep, "/"),
        viewer,
        video_relative_path=(
            os.path.relpath(media_source, start=viewer.parent).replace(os.sep, "/")
            if media_source.suffix.lower() in VIDEO_SUFFIXES
            else None
        ),
        analysis_status=(
            "Önceki pitch analizi kullanıldı." if cache_hit else "Yeni pitch analizi oluşturuldu."
        ),
        validation=validation_for_study(source.name, wav, pitch_json, engine, prepare_display_frames),
    )
    viewer_url = "/" + quote(viewer.relative_to(PROJECT_ROOT).as_posix())
    _store_recent_analysis(source, viewer_url, cache_hit=cache_hit)
    return viewer_url


def refresh_existing_viewer(viewer: Path) -> Path:
    """Refresh a saved HTML viewer without running pitch analysis again."""
    viewer = viewer.expanduser().resolve()
    if viewer.parent != OUTPUTS_DIR.resolve() or viewer.suffix.lower() != ".html":
        raise ValueError("Geçersiz kayıt görünümü.")
    if not viewer.is_file():
        raise FileNotFoundError("Kaydedilmiş çalışma bulunamadı.")

    pitch_candidates = sorted(
        viewer.parent.glob(f"{viewer.stem}.*.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not pitch_candidates:
        raise FileNotFoundError("Bu çalışma için pitch verisi bulunamadı.")
    wav = AUDIO_DIR / f"{viewer.stem}.wav"
    if not wav.is_file():
        raise FileNotFoundError("Bu çalışma için ses önbelleği bulunamadı.")

    previous_html = viewer.read_text(encoding="utf-8")
    video_match = re.search(r'<video[^>]*\bsrc="([^"]+)"', previous_html, re.IGNORECASE)
    video_relative_path = html.unescape(video_match.group(1)) if video_match else None
    build_frequency_viewer(
        pitch_candidates[0],
        os.path.relpath(wav, start=viewer.parent).replace(os.sep, "/"),
        viewer,
        video_relative_path=video_relative_path,
        analysis_status="Önceki pitch analizi kullanıldı. Arayüz güncellendi.",
        validation=validation_for_study(viewer.stem, wav, pitch_candidates[0], "cached", prepare_display_frames),
    )
    return viewer


def reanalyse_existing_viewer(viewer: Path, engine: str) -> Path:
    """Create or reuse the selected portable C++ track for one saved study."""
    viewer = viewer.expanduser().resolve()
    if viewer.parent != OUTPUTS_DIR.resolve() or viewer.suffix.lower() != ".html":
        raise ValueError("Geçersiz kayıt görünümü.")
    if engine not in CPP_ENGINES:
        raise ValueError("Çalışma için taşınabilir bir C++ motor seç.")
    wav = AUDIO_DIR / f"{viewer.stem}.wav"
    if not wav.is_file():
        raise FileNotFoundError("Bu çalışma için ses önbelleği bulunamadı.")
    pitch_json = OUTPUTS_DIR / f"{viewer.stem}.{engine}.offline_track_v1.{OFFLINE_TRACK_REVISION}.json"
    if not pitch_json.is_file():
        extract_cpp_pitch(wav, engine, pitch_json)
    previous_html = viewer.read_text(encoding="utf-8")
    video_match = re.search(r'<video[^>]*\bsrc="([^"]+)"', previous_html, re.IGNORECASE)
    video_relative_path = html.unescape(video_match.group(1)) if video_match else None
    build_frequency_viewer(
        pitch_json,
        os.path.relpath(wav, start=viewer.parent).replace(os.sep, "/"),
        viewer,
        video_relative_path=video_relative_path,
        analysis_status=f"{engine} C++ çalışma eğrisi kullanılıyor.",
        validation=validation_for_study(viewer.stem, wav, pitch_json, engine, prepare_display_frames),
    )
    return viewer


def _form_page(message: str = "") -> str:
    makam_options = "".join(
        f'<option value="{key}">{label}</option>' for key, label in MAKAM_PROFILES.items()
    )
    karar_options = "".join(
        f'<option value="{key}">{value["name"]}</option>'
        for key, value in KARAR_TONES.items()
    )
    notice = f'<p class="notice">{html.escape(message)}</p>' if message else ""
    recent_items = "".join(
        "<a class=\"recent-item\" href=\"{url}\"><strong>{label}</strong>"
        "<span>{when} · {cache}</span></a>".format(
            url=html.escape(str(entry["viewer_url"]), quote=True),
            label=html.escape(str(entry.get("label", "İsimsiz kayıt"))),
            when=html.escape(str(entry.get("analysed_at", ""))),
            cache="Pitch hazır" if entry.get("cache_hit") else "Yeni analiz",
        )
        for entry in _load_recent_analyses()
    )
    recent_section = (
        '<section class="recent"><h2>Son kullanılanlar</h2>' + recent_items + "</section>"
        if recent_items
        else ""
    )
    return f"""<!doctype html><meta charset="utf-8"><title>KlariVision</title>
<style>
body{{font-family:system-ui;max-width:720px;margin:56px auto;padding:0 20px;color:#1e1e1e}}
h1{{margin-bottom:6px}}p{{line-height:1.5}}form{{margin-top:24px;padding:24px;border:1px solid #ddd;border-radius:12px;background:#fafafa}}input,select,button{{font:inherit}}.file-input{{position:absolute;width:1px;height:1px;opacity:0}}.file-button{{display:inline-block;margin-top:8px;padding:12px 16px;background:#1d5fa7;color:#fff;border-radius:8px;font-weight:650;cursor:pointer}}.file-button[aria-disabled="true"],button[disabled]{{opacity:.55;pointer-events:none}}.file-name{{display:block;margin-top:12px;color:#596775}}.link-row{{display:flex;gap:8px;margin-top:18px}}.link-row input{{flex:1;min-width:0;padding:10px;border:1px solid #c9d4df;border-radius:8px}}.link-row button{{padding:10px 13px;border:0;border-radius:8px;background:#263746;color:white;font-weight:650;cursor:pointer}}.progress{{display:none;margin-top:22px}}.progress.visible{{display:block}}.progress-track{{height:12px;background:#e2e8ef;border-radius:99px;overflow:hidden}}.progress-value{{height:100%;width:0;background:linear-gradient(90deg,#1d5fa7,#58a6e8);transition:width .25s ease}}.progress-label{{display:block;margin-top:9px;color:#405465;font-size:.94rem}}.notice{{padding:10px;background:#fff1f1;border-radius:7px;color:#8b2222}}
.recent{{margin-top:22px;border-top:1px solid #e0e5ea;padding-top:18px}}.recent h2{{font-size:16px;margin:0 0 8px}}.recent-item{{display:flex;justify-content:space-between;gap:12px;padding:10px 11px;border:1px solid #dde4eb;border-radius:8px;margin-top:7px;color:#173d62;text-decoration:none}}.recent-item:hover{{background:#eef5fb}}.recent-item span{{color:#637384;font-size:12px;white-space:nowrap}}
</style>
<h1>KlariVision</h1><p>Yeni bir çalışma için video veya ses dosyası seç. Analiz tamamlanana kadar burada grafik ya da video gösterilmez.</p>{notice}
<form id="analysis-form" method="post" action="/analyse" enctype="multipart/form-data">
<input id="recording" class="file-input" name="recording" type="file" accept="video/*,audio/*,.wav,.mp3,.m4a" required><label class="file-button" for="recording">Video veya ses seç</label><span id="file-name" class="file-name">Henüz dosya seçilmedi</span>
<input type="hidden" name="makam" value="huzzam"><input type="hidden" name="karar" value="dugah"><input type="hidden" name="engine" value="vamp">
<div id="progress" class="progress" aria-live="polite"><div class="progress-track"><div id="progress-value" class="progress-value"></div></div><span id="progress-label" class="progress-label">Dosya hazırlanıyor…</span></div>
</form><form id="link-form" method="post" action="/analyse-link" enctype="application/x-www-form-urlencoded"><div class="link-row"><input id="media-url" name="url" type="text" inputmode="url" placeholder="YouTube veya video bağlantısı" required><button id="link-button" type="submit">Linkten aç</button></div><input type="hidden" name="makam" value="huzzam"><input type="hidden" name="karar" value="dugah"><input type="hidden" name="engine" value="vamp"></form><script>
const form=document.getElementById('analysis-form'),linkForm=document.getElementById('link-form'),recording=document.getElementById('recording'),fileName=document.getElementById('file-name'),fileButton=document.querySelector('.file-button'),linkButton=document.getElementById('link-button'),mediaUrl=document.getElementById('media-url'),progress=document.getElementById('progress'),progressValue=document.getElementById('progress-value'),progressLabel=document.getElementById('progress-label');
let analysisStarted=false,shownProgress=0,analysisTimer=null;
function showProgress(value,label){{shownProgress=Math.max(shownProgress,Math.min(100,value));progressValue.style.width=`${{shownProgress}}%`;progressLabel.textContent=label}}
function lockInputs(locked){{fileButton.setAttribute('aria-disabled',locked?'true':'false');linkButton.disabled=locked}}
function finishRequest(request){{if(analysisTimer)clearInterval(analysisTimer);if(request.status>=200&&request.status<400){{showProgress(100,'Analiz tamamlandı. Grafik hazırlanıyor…');setTimeout(()=>{{window.location.assign(request.responseURL)}},220)}}else{{analysisStarted=false;lockInputs(false);progressLabel.textContent=(request.responseText||'Analiz oluşturulamadı. Lütfen tekrar dene.').trim()}}}}
function failRequest(){{if(analysisTimer)clearInterval(analysisTimer);analysisStarted=false;lockInputs(false);progressLabel.textContent='Bağlantı kurulamadı. Lütfen tekrar dene.'}}
function startProgress(label){{analysisStarted=true;lockInputs(true);progress.classList.add('visible');showProgress(1,label)}}
function startPitchTimer(){{analysisTimer=setInterval(()=>showProgress(Math.min(94,shownProgress+Math.max(.4,(94-shownProgress)*.06)),'Pitch analizi yapılıyor veya cache kontrol ediliyor…'),350)}}
function startAnalysis(){{if(analysisStarted||!recording.files.length)return;startProgress('Dosya yükleniyor…');const request=new XMLHttpRequest();request.open('POST','/analyse');request.upload.onprogress=event=>{{if(event.lengthComputable)showProgress(4+(event.loaded/event.total)*26,'Dosya yükleniyor…')}};request.upload.onload=()=>{{showProgress(32,'Pitch analizi yapılıyor veya cache kontrol ediliyor…');startPitchTimer()}};request.onload=()=>finishRequest(request);request.onerror=failRequest;request.send(new FormData(form))}}
function startLinkAnalysis(){{if(analysisStarted||!mediaUrl.value.trim())return;startProgress('Bağlantıdan medya alınıyor…');showProgress(18,'Bağlantıdan medya alınıyor…');startPitchTimer()}}
recording.addEventListener('change',event=>{{const file=event.target.files[0];fileName.textContent=file?.name||'Henüz dosya seçilmedi';if(file)startAnalysis()}});form.addEventListener('submit',event=>{{event.preventDefault();startAnalysis()}});linkForm.addEventListener('submit',()=>startLinkAnalysis());
</script>{recent_section}"""


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
        if self.path == "/analyse-link":
            self._handle_link_import()
            return
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
            self._send_text(f"Analiz oluşturulamadı: {error}", status=400)
            return
        self.send_response(303)
        self.send_header("Location", result_url)
        self.end_headers()

    def _handle_link_import(self) -> None:
        try:
            # Link metadata is deliberately sent as URL-encoded text. This is
            # stable in both the embedded macOS WebKit view and regular browsers.
            length = int(self.headers.get("Content-Length", "0"))
            fields = parse_qs(self.rfile.read(length).decode("utf-8"), keep_blank_values=True)
            source = _import_from_url(fields.get("url", [""])[0])
            result_url = analyse_upload(
                source,
                fields.get("makam", ["huzzam"])[0],
                fields.get("karar", ["dugah"])[0],
                fields.get("engine", ["vamp"])[0],
            )
        except Exception as error:  # User-facing local app; preserve the server process after an error.
            self._send_text(f"Linkten analiz oluşturulamadı: {error}", status=400)
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

    def _send_text(self, message: str, status: int = 200) -> None:
        encoded = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
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
