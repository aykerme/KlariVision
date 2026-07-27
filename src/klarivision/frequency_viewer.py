"""Stable, frequency-only pitch contour viewer.

This viewer intentionally has no makam, karar, transposition or ornament logic.
It is the verified reference layer for all later musical interpretations.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from statistics import median

from klarivision.pitch_reference import extend_reference_octaves, load_turkish_pitch_reference


SCALE_LABELS = {
    "major": {
        "0": ("Do", "Re", "Mi", "Fa", "Sol", "La", "Si"),
        "2": ("Re", "Mi", "Fa♯", "Sol", "La", "Si", "Do♯"),
        "4": ("Mi", "Fa♯", "Sol♯", "La", "Si", "Do♯", "Re♯"),
        "5": ("Fa", "Sol", "La", "Si♭", "Do", "Re", "Mi"),
        "7": ("Sol", "La", "Si", "Do", "Re", "Mi", "Fa♯"),
        "9": ("La", "Si", "Do♯", "Re", "Mi", "Fa♯", "Sol♯"),
        "10": ("Si♭", "Do", "Re", "Mi♭", "Fa", "Sol", "La"),
        "11": ("Si", "Do♯", "Re♯", "Mi", "Fa♯", "Sol♯", "La♯"),
        "6": ("Fa♯", "Sol♯", "La♯", "Si", "Do♯", "Re♯", "Mi♯"),
    },
    "minor": {
        "0": ("Do", "Re", "Mi♭", "Fa", "Sol", "La♭", "Si♭"),
        "2": ("Re", "Mi", "Fa", "Sol", "La", "Si♭", "Do"),
        "4": ("Mi", "Fa♯", "Sol", "La", "Si", "Do", "Re"),
        "5": ("Fa", "Sol", "La♭", "Si♭", "Do", "Re♭", "Mi♭"),
        "7": ("Sol", "La", "Si♭", "Do", "Re", "Mi♭", "Fa"),
        "9": ("La", "Si", "Do", "Re", "Mi", "Fa", "Sol"),
        "10": ("Si♭", "Do", "Re♭", "Mi♭", "Fa", "Sol♭", "La♭"),
        "11": ("Si", "Do♯", "Re", "Mi", "Fa♯", "Sol", "La"),
        "6": ("Fa♯", "Sol♯", "La", "Si", "Do♯", "Re", "Mi"),
    },
    "nihavent": {
        "0": ("Do", "Re", "Mi♭", "Fa", "Sol", "La♭", "Si"),
        "2": ("Re", "Mi", "Fa", "Sol", "La", "Si♭", "Do♯"),
        "4": ("Mi", "Fa♯", "Sol", "La", "Si", "Do", "Re♯"),
        "5": ("Fa", "Sol", "La♭", "Si♭", "Do", "Re♭", "Mi"),
        "7": ("Sol", "La", "Si♭", "Do", "Re", "Mi♭", "Fa♯"),
        "9": ("La", "Si", "Do", "Re", "Mi", "Fa", "Sol♯"),
        "10": ("Si♭", "Do", "Re♭", "Mi♭", "Fa", "Sol♭", "La"),
        "11": ("Si", "Do♯", "Re", "Mi", "Fa♯", "Sol", "La♯"),
        "6": ("Fa♯", "Sol♯", "La", "Si", "Do♯", "Re", "Mi♯"),
    },
    "kurdi": {
        "0": ("Do", "Re♭", "Mi♭", "Fa", "Sol", "La♭", "Si♭"),
        "2": ("Re", "Mi♭", "Fa", "Sol", "La", "Si♭", "Do"),
        "4": ("Mi", "Fa", "Sol", "La", "Si", "Do", "Re"),
        "5": ("Fa", "Sol♭", "La♭", "Si♭", "Do", "Re♭", "Mi♭"),
        "7": ("Sol", "La♭", "Si♭", "Do", "Re", "Mi♭", "Fa"),
        "9": ("La", "Si♭", "Do", "Re", "Mi", "Fa", "Sol"),
        "10": ("Si♭", "Do♭", "Re♭", "Mi♭", "Fa", "Sol♭", "La♭"),
        "11": ("Si", "Do", "Re", "Mi", "Fa♯", "Sol", "La"),
        "6": ("Fa♯", "Sol", "La", "Si", "Do♯", "Re", "Mi"),
    },
    "ussak": {
        "0": ("Do", "Re", "Mi♭", "Fa", "Sol", "La", "Si♭"),
        "2": ("Re", "Mi", "Fa", "Sol", "La", "Si", "Do"),
        "4": ("Mi", "Fa♯", "Sol", "La", "Si", "Do♯", "Re"),
        "5": ("Fa", "Sol", "La♭", "Si♭", "Do", "Re", "Mi♭"),
        "7": ("Sol", "La ♭1", "Si ♭5", "Do", "Re", "Mi ♭5", "Fa"),
        "9": ("La", "Si ♭1", "Do", "Re", "Mi", "Fa", "Sol"),
        "10": ("Si♭", "Do", "Re♭", "Mi♭", "Fa", "Sol", "La♭"),
        "11": ("Si", "Do♯", "Re", "Mi", "Fa♯", "Sol♯", "La"),
        "6": ("Fa♯", "Sol♯", "La", "Si", "Do♯", "Re♯", "Mi"),
    },
}

MAKAM_DEFAULT_INTERVALS = {
    "nihavent": (9, 4, 9, 9, 4, 9, 9),
    "kurdi": (4, 9, 9, 9, 4, 9, 9),
    "ussak": (8, 5, 9, 9, 4, 9, 9),
    "hicaz": (5, 12, 5, 9, 8, 5, 9),
    "kurdilihicazkar": (4, 9, 9, 9, 4, 9, 9),
    "hicazkar": (5, 12, 5, 9, 5, 12, 5),
}
"""AEU theoretical interval sequences; users may tune these in the viewer."""

VIEWER_VERSION = "v0.5 Stable"
"""Stable local pitch viewer foundation with media-synchronised playback."""

MINIMUM_CONFIDENCE = 0.20
"""Suppress pYIN candidates with weak periodicity evidence."""


def _cents(frequency_hz: float) -> float:
    return 1200 * math.log2(frequency_hz / 440)


def prepare_display_frames(payload: dict[str, object]) -> list[dict[str, float]]:
    """Clean only clearly unreliable single-frame pitch candidates for display.

    The original pYIN JSON remains untouched.  A candidate must be voiced and
    reasonably confident; isolated jumps that immediately return to the same
    pitch are omitted rather than being mistaken for a musical ornament.
    """
    raw_frames = payload.get("frames", [])
    candidates = [
        {"t": float(frame["time_seconds"]), "hz": float(frame["frequency_hz"])}
        for frame in raw_frames
        if isinstance(frame, dict)
        and frame.get("voiced")
        and frame.get("frequency_hz") is not None
        and float(frame["frequency_hz"]) > 112
        and float(frame.get("confidence", 0)) >= MINIMUM_CONFIDENCE
    ]
    kept: list[dict[str, float]] = []
    for index, frame in enumerate(candidates):
        if 0 < index < len(candidates) - 1:
            before, after = candidates[index - 1], candidates[index + 1]
            nearby = after["t"] - before["t"] <= 0.025
            jump = abs(_cents(frame["hz"]) - _cents(before["hz"])) > 110
            returns = abs(_cents(after["hz"]) - _cents(before["hz"])) < 35
            if nearby and jump and returns:
                continue
        kept.append(frame)

    smoothed: list[dict[str, float]] = []
    for index, frame in enumerate(kept):
        neighbourhood = kept[max(0, index - 1) : index + 2]
        contiguous = neighbourhood[-1]["t"] - neighbourhood[0]["t"] <= 0.025
        if len(neighbourhood) == 3 and contiguous:
            values = [_cents(point["hz"]) for point in neighbourhood]
            frame = {"t": frame["t"], "hz": 440 * 2 ** (median(values) / 1200)}
        smoothed.append(frame)
    return smoothed


def build_frequency_viewer(
    pitch_json_path: Path,
    audio_relative_path: str,
    output_path: Path,
    *,
    video_relative_path: str | None = None,
    analysis_status: str | None = None,
) -> None:
    """Write a self-contained viewer of the measured, sounding frequency."""
    payload = json.loads(pitch_json_path.read_text(encoding="utf-8"))
    frames = prepare_display_frames(payload)
    turkish_reference = extend_reference_octaves(load_turkish_pitch_reference())
    is_audio_only = video_relative_path is None
    media = (
        f'<video id="media" controls src="{video_relative_path}"></video>'
        if video_relative_path
        else f'<div class="audio-content"><strong>Ses kaydı</strong><audio id="media" controls src="{audio_relative_path}"></audio></div>'
    )
    media_handles = (
        '<span class="resize-handle resize-right" data-resize="right"></span>'
        '<span class="resize-handle resize-bottom" data-resize="bottom"></span>'
        '<span class="resize-handle resize-corner" data-resize="corner"></span>'
        if not is_audio_only
        else ""
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    status = f'<span class="analysis-status">{analysis_status}</span>' if analysis_status else ""
    output_path.write_text(
        f"""<!doctype html><html lang="tr"><meta charset="utf-8">
<title>KlariVision {VIEWER_VERSION} — Duyulan frekans</title>
<style>
:root{{color-scheme:light}}*{{box-sizing:border-box}}body{{margin:0;background:#f5f6f8;color:#17212b;font:14px system-ui,-apple-system,sans-serif}}main{{max-width:1320px;margin:auto;padding:22px}}h1{{font-size:21px;margin:0 0 4px}}p{{margin:0 0 16px;color:#56616e}}.new-recording{{display:inline-block;border:1px solid #4785be;background:#e7f2fc;border-radius:7px;padding:7px 11px;color:#173d62;text-decoration:none;font-weight:650}}.layout-tools{{display:flex;align-items:center;gap:12px;margin:0 0 14px}}.workspace{{--media-width:660px;--media-height:360px;--chart-height:580px;display:grid;gap:16px;overflow-x:auto}}.workspace.side{{grid-template-columns:minmax(320px,var(--media-width)) minmax(320px,1fr);align-items:start}}.workspace.side-right{{grid-template-columns:minmax(320px,1fr) minmax(320px,var(--media-width))}}.workspace.side-right .media{{order:2}}.media{{position:relative;width:var(--media-width);height:var(--media-height);background:#f5f6f8;padding:10px 0 14px}}video,audio{{display:block;max-width:100%;width:100%;height:100%;max-height:100%;object-fit:contain}}audio{{height:auto;margin-top:calc((var(--media-height) - 54px)/2)}}body.audio-only .layout-tools{{display:none}}.workspace.audio-only .media{{width:100%;height:auto;min-height:74px;background:#fff;border:1px solid #dbe0e6;border-radius:12px;padding:12px 14px}}.audio-content{{display:flex;align-items:center;gap:16px}}.audio-content strong{{white-space:nowrap;color:#405465}}.audio-content audio{{margin:0;height:32px;flex:1}}.workspace.audio-only .panel{{width:100%}}.panel{{position:relative;justify-self:start;display:flex;flex-direction:column;min-width:320px;height:calc(var(--chart-height) + 92px);background:#fff;border:1px solid #dbe0e6;border-radius:12px;padding:14px;overflow:hidden}}.workspace.stacked .panel{{width:100%}}.workspace.side .panel{{width:100%}}.tools{{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px;flex:0 0 auto}}button{{border:1px solid #b9c3cf;background:#fff;border-radius:7px;padding:6px 10px;font:inherit;cursor:pointer}}button:hover{{background:#eef5fb}}button[aria-pressed="true"]{{background:#dceefe;border-color:#4785be;color:#173d62;box-shadow:inset 0 0 0 1px #8bb7de}}input{{width:100px}}select{{font:inherit;padding:5px 7px;border:1px solid #b9c3cf;border-radius:7px;background:#fff}}.countdown-status{{min-width:76px;color:#7755b8;font-weight:700}}.chart-scroll{{display:grid;grid-template-columns:minmax(0,1fr) 18px;grid-template-rows:minmax(0,1fr) 18px;gap:5px;min-height:220px;flex:1}}canvas{{display:block;width:100%;height:100%;border:1px solid #dbe0e6;border-radius:8px;touch-action:none}}#time-scroll{{grid-column:1;grid-row:2;width:100%;margin:0;accent-color:#7755b8}}#vertical-scroll{{grid-column:2;grid-row:1;width:18px;height:100%;margin:0;writing-mode:vertical-lr;direction:rtl;accent-color:#7755b8}}.note{{font-size:12px;color:#66717f;margin:8px 0 0;flex:0 0 auto}}.legend{{margin-left:auto;color:#56616e;font-size:12px}}.interval-guide{{position:absolute;z-index:4;right:18px;bottom:38px;font-size:11px;color:#34414e}}.interval-guide summary{{cursor:pointer;list-style:none;border:1px solid #c4d2df;background:rgba(255,255,255,.94);border-radius:999px;padding:5px 9px;box-shadow:0 1px 4px rgba(25,45,65,.12)}}.interval-guide summary::-webkit-details-marker{{display:none}}.interval-guide[open]{{width:286px;background:rgba(255,255,255,.97);border:1px solid #c4d2df;border-radius:9px;padding:9px;box-shadow:0 3px 13px rgba(25,45,65,.16)}}.interval-guide[open] summary{{border:0;padding:0 0 7px;font-weight:700}}.interval-guide table{{width:100%;border-collapse:collapse}}.interval-guide th,.interval-guide td{{padding:3px 2px;border-top:1px solid #e6ebef;text-align:left;white-space:nowrap}}.interval-guide th{{font-weight:650;color:#607080}}dialog{{width:min(630px,calc(100vw - 28px));border:0;border-radius:13px;box-shadow:0 18px 55px rgba(12,25,38,.35);padding:0;color:#17212b}}dialog::backdrop{{background:rgba(22,35,48,.36)}}.settings-form{{padding:20px}}.settings-form h2{{margin:0 0 6px;font-size:18px}}.settings-form p{{font-size:13px;margin-bottom:14px}}.settings-grid{{display:grid;grid-template-columns:repeat(7,minmax(68px,1fr));gap:8px;margin:14px 0}}.settings-grid label{{display:grid;gap:4px;font-size:11px;color:#506070}}.settings-grid select{{width:100%;padding:5px 3px;font-size:12px}}.settings-total{{font-weight:700;color:#1f5d36}}.settings-total.invalid{{color:#a33232}}.settings-actions{{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}}.resize-handle{{position:absolute;z-index:5;touch-action:none}}.resize-right{{right:0;top:0;width:16px;height:100%;cursor:ew-resize}}.resize-bottom{{left:0;bottom:0;width:100%;height:16px;cursor:ns-resize}}.resize-corner{{right:0;bottom:0;width:24px;height:24px;cursor:nwse-resize;background:linear-gradient(135deg,transparent 45%,#91a4b8 46%,#91a4b8 54%,transparent 55%)}}@media(max-width:650px){{main{{padding:12px}}.audio-content{{align-items:stretch;flex-direction:column;gap:7px}}.interval-guide{{right:14px;bottom:36px}}.settings-grid{{grid-template-columns:repeat(4,minmax(68px,1fr))}}}}
</style><style>
.app-context{{display:inline-block;margin:0 0 14px;color:#405465;font-size:13px;font-weight:650}}.analysis-status{{display:inline-block;margin:0 0 12px;padding:5px 9px;border-radius:999px;background:#e8f4ea;color:#23633a;font-size:12px;font-weight:700}}.settings-section{{display:grid;gap:10px;padding:13px 0;border-top:1px solid #e2e7ec}}.settings-section h3{{margin:0;font-size:14px}}.settings-row{{display:flex;align-items:center;gap:10px;flex-wrap:wrap}}.settings-actions input[type=checkbox]{{width:auto;margin:0 5px 0 0;vertical-align:middle}}.speed-stepper{{display:flex;align-items:center;gap:8px;margin:auto}}.speed-stepper span{{min-width:52px;text-align:center;font-weight:700}}#time-scroll{{display:block!important;visibility:visible!important;opacity:1!important}}.tools #makam-settings-open{{margin-left:auto}}@media(max-width:650px){{.tools #makam-settings-open{{margin-left:0}}}}
</style><body class="{'audio-only' if is_audio_only else ''}"><main>
<h1>KlariVision {VIEWER_VERSION} · Pitch konturu</h1><a id="new-recording" class="new-recording" href="/">Yeni video / ses seç</a>
<p>Pitch eğrisi pYIN'in ölçtüğü fiziksel frekanstır (Hz). Türk Müziği (Sol Klarnet) ekseni, koma miktarını taşınabilir biçimde gösterir: ör. Re ♭5, Fa ♯1. Ölçülen eğri değiştirilmez.</p>{status}
<div class="layout-tools"><label>Yerleşim <select id="layout-mode"><option value="stacked">Üst üste</option><option value="side">Video solda · yan yana</option><option value="side-right">Video sağda · yan yana</option></select></label></div>
<div id="workspace" class="workspace {'audio-only' if is_audio_only else ''}"><div id="media-panel" class="media">{media}{media_handles}</div>
<section class="panel"><div class="tools">
<button id="minus">− Zaman</button><button id="plus">+ Zaman</button>
<label>Görünür süre <input id="window" type="number" min="2" max="60" step="1" value="12"> sn</label>
<button id="vertical-out">− Dikey</button><button id="vertical-in">+ Dikey</button>
<label>Eksen <select id="scale-mode"><option value="major">Majör</option><option value="minor">Minör</option><option value="nihavent">Nihavend</option><option value="kurdi">Kürdi</option><option value="ussak">Uşşak</option><option value="hicaz">Hicaz</option><option value="kurdilihicazkar">Kürdilihicazkâr</option><option value="hicazkar">Hicazkâr</option><option value="turkish">Türk Müziği · Sol Klarnet</option></select></label><button id="makam-settings-open" type="button">Ayarlar</button><span id="makam-status" class="countdown-status"></span>
<label>Karar <select id="tonic"><option value="0">Do</option><option value="2">Re</option><option value="4">Mi</option><option value="5">Fa</option><option value="7">Sol</option><option value="9">La</option><option value="11">Si</option></select></label>
<label>Geri sayım <input id="countdown" type="number" min="0" max="60" step="1" value="0"> sn</label><button id="play-toggle">Oynat</button><span id="countdown-status" class="countdown-status" aria-live="polite"></span>
<button id="set-a" disabled>A: 0.00 sn</button><button id="set-b" disabled>B: Son</button><button id="loop" aria-pressed="false" disabled>Loop</button><button id="reset">Başa dön</button><span class="legend">Tekerlek: imleç çevresinde zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır · sürükle: kayıtta gezin</span>
</div><div id="chart-panel" class="chart-scroll"><canvas id="chart"></canvas><input id="vertical-scroll" type="range" aria-label="Dikey grafiği kaydır"><input id="time-scroll" type="range" aria-label="Kayıtta gezin"><span></span></div><p class="note">Yatay çubuk kayıtta gezinir; sağdaki çubuk dikey merkezi değiştirir.</p><details class="interval-guide"><summary>Koma rehberi</summary><table><thead><tr><th>Rumuz</th><th>Aralık</th><th>Koma</th><th>Gösterim</th></tr></thead><tbody><tr><td>F</td><td>Koma</td><td>1</td><td>♯1 / ♭1</td></tr><tr><td>E</td><td>Eksik bakiye</td><td>3</td><td>—</td></tr><tr><td>B</td><td>Bakiye</td><td>4</td><td>♯4 / ♭4</td></tr><tr><td>S</td><td>Küçük mücennep</td><td>5</td><td>♯5 / ♭5</td></tr><tr><td>K</td><td>Büyük mücennep</td><td>8</td><td>♯8 / ♭8</td></tr><tr><td>T</td><td>Tanini</td><td>9</td><td>♯9 / ♭9</td></tr><tr><td>A</td><td>Artık ikili</td><td>12–13</td><td>—</td></tr></tbody></table></details><span class="resize-handle resize-right" data-resize="right"></span><span class="resize-handle resize-bottom" data-resize="bottom"></span><span class="resize-handle resize-corner" data-resize="corner"></span></section></div><dialog id="makam-settings"><form method="dialog" class="settings-form"><h2>Ayarlar</h2><p>Makam aralıklarını, dikey eğri takibini ve çalma hızını buradan düzenleyebilirsin.</p><div class="settings-actions" style="justify-content:flex-start;margin-top:0"><label><input id="vertical-follow" type="checkbox"> Eğriyi dikey takip et</label><label>Çalma hızı <select id="playback-rate"><option value="0.10">0,10×</option><option value="0.15">0,15×</option><option value="0.20">0,20×</option><option value="0.25">0,25×</option><option value="0.30">0,30×</option><option value="0.35">0,35×</option><option value="0.40">0,40×</option><option value="0.45">0,45×</option><option value="0.50">0,50×</option><option value="0.55">0,55×</option><option value="0.60">0,60×</option><option value="0.65">0,65×</option><option value="0.70">0,70×</option><option value="0.75">0,75×</option><option value="0.80">0,80×</option><option value="0.85">0,85×</option><option value="0.90">0,90×</option><option value="0.95">0,95×</option><option value="1.00" selected>1,00×</option></select></label></div><label>Makam <select id="makam-settings-mode"><option value="nihavent">Nihavend</option><option value="kurdi">Kürdi</option><option value="ussak">Uşşak</option><option value="hicaz">Hicaz</option><option value="kurdilihicazkar">Kürdilihicazkâr</option><option value="hicazkar">Hicazkâr</option></select></label><div id="makam-settings-grid" class="settings-grid"></div><div id="makam-settings-total" class="settings-total"></div><div class="settings-actions"><button id="makam-settings-reset" type="button">Teoriye dön</button><button value="cancel">Vazgeç</button><button id="makam-settings-apply" type="button">Uygula</button></div></form></dialog></main><script>
const audioOnly={json.dumps(is_audio_only)};
const frames={json.dumps(frames, ensure_ascii=False, separators=(',', ':'))};
const scaleLabels={json.dumps(SCALE_LABELS, ensure_ascii=False, separators=(',', ':'))};
const turkishReference={json.dumps([record.__dict__ | {"display_notation": record.display_notation, "octave_label": record.octave_label} for record in turkish_reference], ensure_ascii=False, separators=(',', ':'))};
const makamDefaults={json.dumps(MAKAM_DEFAULT_INTERVALS, ensure_ascii=False, separators=(',', ':'))};
const media=document.getElementById('media'),canvas=document.getElementById('chart'),ctx=canvas.getContext('2d'),timeScroll=document.getElementById('time-scroll'),verticalScroll=document.getElementById('vertical-scroll');
const setAButton=document.getElementById('set-a'),setBButton=document.getElementById('set-b'),loopButton=document.getElementById('loop');
const scaleMode=document.getElementById('scale-mode'),tonicInput=document.getElementById('tonic');
const makamSettingsDialog=document.getElementById('makam-settings'),makamSettingsOpen=document.getElementById('makam-settings-open'),makamSettingsMode=document.getElementById('makam-settings-mode'),makamSettingsGrid=document.getElementById('makam-settings-grid'),makamSettingsTotal=document.getElementById('makam-settings-total'),makamSettingsApply=document.getElementById('makam-settings-apply'),makamSettingsReset=document.getElementById('makam-settings-reset'),playbackRateInput=document.getElementById('playback-rate');
const makamStatus=document.getElementById('makam-status');let contextStatus,playbackRateStatus;
const winInput=document.getElementById('window'),countdownInput=document.getElementById('countdown'),playToggle=document.getElementById('play-toggle'),countdownStatus=document.getElementById('countdown-status');let windowSeconds=12,viewStart=-6,drag=null,followPlayback=true,countdownTimer=null,countdownBypass=false;
const workspace=document.getElementById('workspace'),layoutMode=document.getElementById('layout-mode'),mediaPanel=document.getElementById('media-panel'),chartPanel=canvas.closest('.panel');let resizeAction=null;
// Keep the time scrubber on its own row.  It previously lived inside the
// chart grid, where the fixed-size panel could clip it out of view.
const chartGrid=document.getElementById('chart-panel');
chartGrid.after(timeScroll);
const timelineStyle=document.createElement('style');
timelineStyle.textContent='.panel{{height:calc(var(--chart-height) + 130px)}}.chart-scroll{{grid-template-rows:minmax(0,1fr)}}#time-scroll{{display:block!important;width:100%!important;height:18px!important;margin:7px 0 0!important;accent-color:#7755b8;flex:0 0 auto;visibility:visible!important;opacity:1!important}}';
document.head.append(timelineStyle);
const verticalFollowInput=document.getElementById('vertical-follow');let verticalSpan=2400,verticalCenter=0,verticalReady=false,mediaReady=false;
let duration=Math.max(...frames.map(p=>p.t),0),loopA=0,loopB=duration,loopEnabled=false,loopBManual=false; const left=140,right=20,marginTop=22,bottom=34;
const makamSettingsKey='klarivision-makam-intervals-v1';
const makamNames={{nihavent:'Nihavend',kurdi:'Kürdi',ussak:'Uşşak',hicaz:'Hicaz',kurdilihicazkar:'Kürdilihicazkâr',hicazkar:'Hicazkâr'}};
let makamIntervals=JSON.parse(JSON.stringify(makamDefaults)),pendingMakamIntervals=null;
try{{const stored=JSON.parse(localStorage.getItem(makamSettingsKey));if(stored&&Object.keys(makamDefaults).every(mode=>Array.isArray(stored[mode])&&stored[mode].length===7&&stored[mode].every(value=>Number.isInteger(value)&&value>=1&&value<=13)&&stored[mode].reduce((sum,value)=>sum+value,0)===53))makamIntervals=stored}}catch(_error){{}}
function cents(hz){{return 1200*Math.log2(hz/440)}}
function notesForMode(mode,intervals,labelTonic=Number(tonicInput.value),soundingTonic=Number(tonicInput.value)){{const names=scaleLabels[mode][String(labelTonic)],namesByPitchClass=new Map(intervals.map((interval,index)=>[(soundingTonic+interval)%12,names[index]])),result=[];for(let midi=24;midi<=108;midi++){{const name=namesByPitchClass.get(midi%12);if(!name)continue;const octave=Math.floor(midi/12)-1,hz=440*Math.pow(2,(midi-69)/12);result.push([`${{name}}${{octave}}`,hz])}}return result}}
const naturalKomaByPitchClass={{0:0,2:9,4:18,5:22,7:31,9:40,11:49}},naturalKomaByName={{Do:0,Re:9,Mi:18,Fa:22,Sol:31,La:40,Si:49}};
function makamLabel(name,octave,step,rootKoma){{const base=name.match(/^(Do|Re|Mi|Fa|Sol|La|Si)/)[1],naturalStep=(naturalKomaByName[base]-rootKoma+53)%53,adjustment=step-naturalStep;if(!adjustment)return `${{base}}${{octave}}`;return `${{base}}${{octave}} ${{adjustment<0?'♭':'♯'}}${{Math.abs(adjustment)}}`}}
function makamNotes(mode,labelMode){{const solClarinetTonic=Number(tonicInput.value),soundingTonic=(solClarinetTonic+7)%12,tonicMidi=60+soundingTonic,rootKoma=naturalKomaByPitchClass[solClarinetTonic],names=scaleLabels[labelMode][String(solClarinetTonic)],steps=[0];for(const interval of makamIntervals[mode])steps.push(steps.at(-1)+interval);const result=[];for(let octave=-3;octave<=3;octave++){{for(let degree=0;degree<7;degree++){{const hz=440*Math.pow(2,(tonicMidi-69)/12)*Math.pow(2,octave)*Math.pow(2,steps[degree]/53),label=makamLabel(names[degree],Math.floor(tonicMidi/12)-1+octave,steps[degree],rootKoma);result.push([label,hz])}}}}return result}}
function nihaventNotes(){{return makamNotes('nihavent','minor')}}
function kurdiNotes(){{return makamNotes('kurdi','kurdi')}}
function ussakNotes(){{return makamNotes('ussak','ussak')}}
function hicazNotes(){{return makamNotes('hicaz','minor')}}
function kurdilihicazkarNotes(){{return makamNotes('kurdilihicazkar','kurdi')}}
function hicazkarNotes(){{return makamNotes('hicazkar','minor')}}
function turkishNotes(){{return turkishReference.map(note=>[note.display_notation,note.frequency_hz])}}
function scaleNotes(){{if(scaleMode.value==='turkish')return turkishNotes();if(scaleMode.value==='nihavent')return nihaventNotes();if(scaleMode.value==='kurdi')return kurdiNotes();if(scaleMode.value==='ussak')return ussakNotes();if(scaleMode.value==='hicaz')return hicazNotes();if(scaleMode.value==='kurdilihicazkar')return kurdilihicazkarNotes();if(scaleMode.value==='hicazkar')return hicazkarNotes();return notesForMode(scaleMode.value,scaleMode.value==='major'?[0,2,4,5,7,9,11]:[0,2,3,5,7,8,10])}}
function komaOption(value){{const names={{1:'F · Koma',3:'E · Eksik bakiye',4:'B · Bakiye',5:'S · Küçük mücennep',8:'K · Büyük mücennep',9:'T · Tanini',12:'A · Artık ikili',13:'A · Artık ikili'}};return `${{value}} koma${{names[value]?` (${{names[value]}})`:''}}`}}
function updateMakamStatus(){{const axis=scaleMode.selectedOptions[0].textContent,karar=tonicInput.selectedOptions[0].textContent;if(contextStatus)contextStatus.textContent=scaleMode.value==='turkish'?axis:`${{axis}} · ${{karar}} karar`;if(!makamIntervals[scaleMode.value]){{makamStatus.textContent='';return}}makamStatus.textContent=`${{makamNames[scaleMode.value]}}: ${{makamIntervals[scaleMode.value].join('–')}} = 53 koma`}}
function renderMakamSettings(){{const mode=makamSettingsMode.value,values=pendingMakamIntervals[mode],total=values.reduce((sum,value)=>sum+Number(value),0);makamSettingsGrid.replaceChildren(...values.map((value,index)=>{{const label=document.createElement('label'),select=document.createElement('select');label.textContent=`Aralık ${{index+1}}`;select.dataset.intervalIndex=index;for(let koma=1;koma<=13;koma++){{const option=document.createElement('option');option.value=koma;option.textContent=komaOption(koma);option.selected=koma===Number(value);select.append(option)}}label.append(select);return label}}));makamSettingsTotal.textContent=`Toplam: ${{total}} / 53 koma`;makamSettingsTotal.classList.toggle('invalid',total!==53);makamSettingsApply.disabled=total!==53}}
function setPlaybackRate(value){{const rate=Math.max(.10,Math.min(1,Math.round(value*20)/20));playbackRateInput.value=rate.toFixed(2);media.playbackRate=rate;if(playbackRateStatus)playbackRateStatus.textContent=`${{rate.toFixed(2).replace('.',',')}}×`}}
function organisePracticeControls(){{const form=makamSettingsDialog.querySelector('.settings-form'),makamLabel=makamSettingsMode.closest('label'),speedRow=playbackRateInput.closest('.settings-actions'),speedLabel=playbackRateInput.closest('label'),practice=document.createElement('section'),practiceRow=document.createElement('div'),speedStepper=document.createElement('div'),speedDown=document.createElement('button'),speedUp=document.createElement('button'),title=document.querySelector('h1'),description=document.querySelector('main > p'),deferredControls=[document.getElementById('minus'),document.getElementById('plus'),winInput.closest('label'),document.getElementById('vertical-out'),document.getElementById('vertical-in')];practice.className='settings-section';practiceRow.className='settings-row';speedStepper.className='speed-stepper';speedDown.type='button';speedDown.textContent='−';speedUp.type='button';speedUp.textContent='+';playbackRateStatus=document.createElement('span');speedStepper.append(speedDown,playbackRateStatus,speedUp);speedLabel.hidden=true;speedRow.append(speedStepper);speedDown.onclick=()=>setPlaybackRate(Number(playbackRateInput.value)-.05);speedUp.onclick=()=>setPlaybackRate(Number(playbackRateInput.value)+.05);practice.innerHTML='<h3>Çalışma</h3>';practiceRow.append(layoutMode.closest('label'),scaleMode.closest('label'),tonicInput.closest('label'),countdownInput.closest('label'));practice.append(practiceRow);form.insertBefore(practice,speedRow);makamLabel.before(makamStatus);deferredControls.forEach(control=>control.hidden=true);document.querySelector('.layout-tools').remove();title.textContent='KlariVision';contextStatus=document.createElement('span');contextStatus.id='context-status';contextStatus.className='app-context';title.after(contextStatus);description.textContent='Pitch eğrisi duyulan fiziksel frekansı (Hz) gösterir.';setPlaybackRate(Number(playbackRateInput.value))}}
makamSettingsOpen.onclick=()=>{{pendingMakamIntervals=JSON.parse(JSON.stringify(makamIntervals));if(makamIntervals[scaleMode.value])makamSettingsMode.value=scaleMode.value;renderMakamSettings();makamSettingsDialog.showModal()}};makamSettingsMode.onchange=renderMakamSettings;makamSettingsGrid.onchange=event=>{{if(!event.target.matches('select[data-interval-index]'))return;pendingMakamIntervals[makamSettingsMode.value][Number(event.target.dataset.intervalIndex)]=Number(event.target.value);renderMakamSettings()}};makamSettingsReset.onclick=()=>{{pendingMakamIntervals[makamSettingsMode.value]=[...makamDefaults[makamSettingsMode.value]];renderMakamSettings()}};makamSettingsApply.onclick=()=>{{const values=pendingMakamIntervals[makamSettingsMode.value];if(values.reduce((sum,value)=>sum+Number(value),0)!==53)return;makamIntervals=pendingMakamIntervals;localStorage.setItem(makamSettingsKey,JSON.stringify(makamIntervals));makamSettingsDialog.close();updateMakamStatus();draw()}};
function formatTime(time){{return `${{time.toFixed(2)}} sn`}}
function updateLoopButtons(){{setAButton.textContent=`A: ${{formatTime(loopA)}}`;setBButton.textContent=`B: ${{loopBManual?formatTime(loopB):'Son'}}`;loopButton.setAttribute('aria-pressed',String(loopEnabled));}}
function setMediaReady(ready){{mediaReady=ready;setAButton.disabled=!ready;setBButton.disabled=!ready;loopButton.disabled=!ready;if(ready)countdownStatus.textContent=''}}
function resize(){{const dpr=devicePixelRatio||1,w=canvas.clientWidth,h=canvas.clientHeight;canvas.width=w*dpr;canvas.height=h*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);draw()}}
function visibleValues(){{return frames.filter(p=>p.t>=viewStart&&p.t<=viewStart+windowSeconds).map(p=>cents(p.hz))}}
function middle(values){{if(!values.length)return 0;const ordered=[...values].sort((a,b)=>a-b),half=Math.floor(ordered.length/2);return ordered.length%2?ordered[half]:(ordered[half-1]+ordered[half])/2}}
function followValues(){{const time=media.currentTime||0;return frames.filter(p=>Math.abs(p.t-time)<=.25).map(p=>cents(p.hz))}}
function range(){{const values=visibleValues();if(!verticalReady){{verticalCenter=middle(values.length?values:frames.map(p=>cents(p.hz)));verticalReady=true}}const target=verticalFollowInput.checked?followValues():values;if(verticalFollowInput.checked&&target.length)verticalCenter+=((middle(target)-verticalCenter)*.14);return [verticalCenter-verticalSpan/2,verticalCenter+verticalSpan/2]}}
function updateScrollbars(){{timeScroll.min=0;timeScroll.max=Math.max(1,Math.round(duration*1000));timeScroll.value=Math.round((media.currentTime||0)*1000);const values=frames.map(p=>cents(p.hz));if(!values.length)return;verticalScroll.min=Math.floor(Math.min(...values)-verticalSpan/2);verticalScroll.max=Math.ceil(Math.max(...values)+verticalSpan/2);verticalScroll.value=Math.round(verticalCenter)}}
function draw(){{const w=canvas.clientWidth,h=canvas.clientHeight,cw=w-left-right,ch=h-marginTop-bottom,[lo,hi]=range();ctx.clearRect(0,0,w,h);const x=t=>left+(t-viewStart)/windowSeconds*cw,y=hz=>marginTop+(hi-cents(hz))/(hi-lo)*ch;
ctx.fillStyle='#fff';ctx.fillRect(0,0,w,h);ctx.strokeStyle='#e2e6eb';ctx.lineWidth=1;
for(const [name,hz] of scaleNotes()){{const yy=y(hz);if(yy<marginTop-5||yy>h-bottom+5)continue;ctx.beginPath();ctx.moveTo(left,yy);ctx.lineTo(w-right,yy);ctx.stroke();ctx.fillStyle='#3d4854';ctx.textAlign='right';ctx.font='11px system-ui';ctx.fillText(`${{name}}  (${{hz.toFixed(2)}} Hz)`,left-9,yy+4)}}
for(let t=Math.max(0,Math.ceil(viewStart));t<=Math.min(duration,viewStart+windowSeconds);t++){{const xx=x(t);ctx.strokeStyle='#edf0f3';ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke();ctx.fillStyle='#687482';ctx.textAlign='center';ctx.fillText(`${{t}} sn`,xx,h-12)}}
if(loopEnabled){{const start=Math.max(left,x(loopA)),end=Math.min(w-right,x(loopB));if(end>start){{ctx.fillStyle='rgba(112,181,235,.20)';ctx.fillRect(start,marginTop,end-start,ch)}}}}
ctx.save();ctx.beginPath();ctx.rect(left,marginTop,cw,ch);ctx.clip();ctx.strokeStyle='#111820';ctx.lineWidth=1.7;ctx.lineJoin='round';ctx.lineCap='round';ctx.beginPath();let previous=null;for(const p of frames){{if(p.t<viewStart-.05||p.t>viewStart+windowSeconds+.05)continue;const xx=x(p.t),yy=y(p.hz);if(!previous||p.t-previous.t>.030)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);previous=p}}ctx.stroke();
function marker(time,label,color){{if(time<viewStart||time>viewStart+windowSeconds)return;const xx=x(time);ctx.strokeStyle=color;ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke();ctx.fillStyle=color;ctx.font='bold 12px system-ui';ctx.textAlign='center';ctx.fillText(label,xx,marginTop+14)}}marker(loopA,'A','#157347');marker(loopB,'B','#bd5b00');const current=media.currentTime||0;if(current>=viewStart&&current<=viewStart+windowSeconds){{const xx=x(current);ctx.strokeStyle='#7755b8';ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke()}}ctx.restore();ctx.strokeStyle='#aeb8c3';ctx.strokeRect(left,marginTop,cw,ch);updateScrollbars()}}
function clampStart(){{viewStart=Math.max(-windowSeconds/2,Math.min(viewStart,duration-windowSeconds/2))}}
function centerOnPlayhead(){{viewStart=(media.currentTime||0)-windowSeconds/2;clampStart()}}
function loopStart(){{return Math.max(0,Math.min(loopA,Math.max(0,duration-.001)))}}
function restartLoopAtA(){{media.currentTime=loopStart()}}
function playLoopFromA(){{const start=loopStart();media.play().then(()=>{{if(loopEnabled)media.currentTime=start}}).catch(()=>{{}})}}
function tick(){{if(loopEnabled&&!media.paused&&(media.currentTime||0)>=loopB)restartLoopAtA();if(followPlayback)centerOnPlayhead();draw();requestAnimationFrame(tick)}}
function setWindow(value){{windowSeconds=Math.max(2,Math.min(60,value));winInput.value=windowSeconds;centerOnPlayhead();draw()}}
function setVerticalSpan(value,anchor){{const previous=verticalSpan;verticalSpan=Math.max(200,Math.min(4800,value));if(anchor!==undefined){{const ratio=(verticalCenter+previous/2-anchor)/previous;verticalCenter=anchor+(ratio-.5)*verticalSpan}}draw()}}
function updatePlayButton(){{playToggle.textContent=countdownTimer?'İptal':(media.paused?'Oynat':'Duraklat')}}
function clearCountdown(){{if(countdownTimer){{clearInterval(countdownTimer);countdownTimer=null}}countdownStatus.textContent='';updatePlayButton()}}
function beginPlayback(){{if(!media.paused){{media.pause();return}}const seconds=Math.max(0,Math.floor(Number(countdownInput.value)||0));if(seconds===0){{countdownBypass=true;media.play().catch(()=>{{}});return}}let remaining=seconds;countdownStatus.textContent=`Başlıyor: ${{remaining}}`;updatePlayButton();countdownTimer=setInterval(()=>{{remaining-=1;if(remaining<=0){{clearCountdown();countdownBypass=true;media.play().catch(()=>{{}})}}else countdownStatus.textContent=`Başlıyor: ${{remaining}}`}},1000)}}
function applyLayout(){{workspace.className=`workspace ${{audioOnly?'audio-only ':''}}${{layoutMode.value}}`;requestAnimationFrame(resize)}}
function beginPanelResize(event,panel,mode){{event.preventDefault();const rect=panel.getBoundingClientRect();resizeAction={{panel,mode,startX:event.clientX,startY:event.clientY,width:rect.width,height:rect.height}};panel.setPointerCapture(event.pointerId)}}
function movePanelResize(event){{if(!resizeAction)return;const action=resizeAction,dx=event.clientX-action.startX,dy=event.clientY-action.startY;if(action.panel===mediaPanel){{if(action.mode==='right'||action.mode==='corner')workspace.style.setProperty('--media-width',`${{Math.max(320,action.width+dx)}}px`);if(action.mode==='bottom'||action.mode==='corner')workspace.style.setProperty('--media-height',`${{Math.max(180,action.height+dy)}}px`)}}else{{if(action.mode==='right'||action.mode==='corner')action.panel.style.width=`${{Math.max(420,action.width+dx)}}px`;if(action.mode==='bottom'||action.mode==='corner')workspace.style.setProperty('--chart-height',`${{Math.max(260,action.height+dy-92)}}px`)}}resize()}}
function endPanelResize(event){{if(!resizeAction)return;try{{resizeAction.panel.releasePointerCapture(event.pointerId)}}catch(_error){{}}resizeAction=null;resize()}}
function enablePanelResize(panel){{panel.querySelectorAll('[data-resize]').forEach(handle=>handle.addEventListener('pointerdown',event=>beginPanelResize(event,panel,handle.dataset.resize)));panel.addEventListener('pointermove',movePanelResize);panel.addEventListener('pointerup',endPanelResize);panel.addEventListener('pointercancel',endPanelResize)}}
organisePracticeControls();document.getElementById('minus').onclick=()=>setWindow(windowSeconds*1.35);document.getElementById('plus').onclick=()=>setWindow(windowSeconds/1.35);document.getElementById('reset').onclick=()=>{{media.currentTime=0;followPlayback=true;centerOnPlayhead();draw()}};winInput.onchange=()=>setWindow(Number(winInput.value));updateMakamStatus();
document.getElementById('vertical-out').onclick=()=>setVerticalSpan(verticalSpan*1.35);document.getElementById('vertical-in').onclick=()=>setVerticalSpan(verticalSpan/1.35);verticalFollowInput.onchange=()=>draw();
scaleMode.onchange=()=>{{tonicInput.disabled=scaleMode.value==='turkish';updateMakamStatus();draw()}};tonicInput.onchange=()=>{{updateMakamStatus();draw()}};playbackRateInput.onchange=()=>setPlaybackRate(Number(playbackRateInput.value));
setAButton.onclick=()=>{{if(!mediaReady)return;loopA=Math.max(0,Math.min(media.currentTime||0,duration));if(loopA>=loopB-.02){{loopB=duration;loopBManual=false}}updateLoopButtons();draw()}};setBButton.onclick=()=>{{if(!mediaReady)return;loopB=Math.max(loopA+.02,Math.min(media.currentTime||0,duration));loopBManual=true;updateLoopButtons();draw()}};loopButton.onclick=()=>{{if(!mediaReady){{countdownStatus.textContent='Video hazırlanıyor…';return}}if(!loopEnabled&&loopB-loopA<.02){{countdownStatus.textContent='Loop için A ile B arasında en az 0,02 sn olmalı.';return}}loopEnabled=!loopEnabled;if(loopEnabled){{countdownBypass=true;playLoopFromA()}}else if(media.currentTime<duration){{countdownBypass=true;media.play()}}updateLoopButtons();draw()}};
timeScroll.addEventListener('input',()=>{{media.currentTime=Number(timeScroll.value)/1000;followPlayback=true;centerOnPlayhead();draw()}});verticalScroll.addEventListener('input',()=>{{verticalCenter=Number(verticalScroll.value);verticalReady=true;verticalFollowInput.checked=false;draw()}});
canvas.addEventListener('wheel',e=>{{e.preventDefault();const rect=canvas.getBoundingClientRect();if(e.shiftKey){{const ratio=(e.clientY-rect.top-marginTop)/(rect.height-marginTop-bottom),[lo,hi]=range(),anchor=hi-ratio*(hi-lo);setVerticalSpan(verticalSpan*(e.deltaY>0?1.2:1/1.2),anchor);return}}setWindow(windowSeconds*(e.deltaY>0?1.2:1/1.2));followPlayback=true;}},{{passive:false}});
if(location.protocol==='file:')document.getElementById('new-recording').href='http://127.0.0.1:8765/';layoutMode.onchange=applyLayout;verticalFollowInput.onchange=()=>draw();playToggle.onclick=()=>{{if(countdownTimer)clearCountdown();else beginPlayback()}};canvas.addEventListener('pointerdown',e=>{{drag={{x:e.clientX,time:media.currentTime||0,moved:false}};canvas.setPointerCapture(e.pointerId);followPlayback=true}});canvas.addEventListener('pointermove',e=>{{if(!drag)return;const change=(e.clientX-drag.x)/(canvas.clientWidth-left-right)*windowSeconds;if(!drag.moved&&Math.abs(e.clientX-drag.x)<4)return;drag.moved=true;media.currentTime=Math.max(0,Math.min(duration,drag.time-change));centerOnPlayhead();draw()}});canvas.addEventListener('pointerup',()=>{{if(drag&&!drag.moved)beginPlayback();drag=null}});media.addEventListener('play',()=>{{if(countdownBypass){{countdownBypass=false;updatePlayButton();return}}if((Number(countdownInput.value)||0)>0){{media.pause();beginPlayback()}}else updatePlayButton()}});media.addEventListener('pause',()=>{{if(!countdownTimer)updatePlayButton()}});media.addEventListener('timeupdate',()=>{{if(loopEnabled&&(media.currentTime||0)>=loopB)restartLoopAtA()}});media.addEventListener('ended',()=>{{if(loopEnabled){{countdownBypass=true;playLoopFromA()}}}});media.addEventListener('seeking',()=>{{followPlayback=true;centerOnPlayhead()}});media.addEventListener('loadedmetadata',()=>{{setPlaybackRate(Number(playbackRateInput.value));if(Number.isFinite(media.duration)){{duration=Math.max(duration,media.duration);if(!loopBManual)loopB=duration}}updateLoopButtons();centerOnPlayhead();draw()}});media.addEventListener('canplay',()=>setMediaReady(true));if(media.readyState>=3)setMediaReady(true);enablePanelResize(mediaPanel);enablePanelResize(chartPanel);new ResizeObserver(()=>resize()).observe(chartPanel);updateLoopButtons();applyLayout();addEventListener('resize',resize);requestAnimationFrame(tick);
</script></main></body></html>""",
        encoding="utf-8",
    )
