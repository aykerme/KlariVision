"""Stable, frequency-only pitch contour viewer.

This viewer intentionally has no makam, karar, transposition or ornament logic.
It is the verified reference layer for all later musical interpretations.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from statistics import median


NATURAL_NOTES = (
    ("La2", 110.00), ("Si2", 123.47), ("Do3", 130.81), ("Re3", 146.83),
    ("Mi3", 164.81), ("Fa3", 174.61), ("Sol3", 196.00), ("La3", 220.00),
    ("Si3", 246.94), ("Do4", 261.63), ("Re4", 293.66), ("Mi4", 329.63),
    ("Fa4", 349.23), ("Sol4", 392.00), ("La4", 440.00), ("Si4", 493.88),
    ("Do5", 523.25), ("Re5", 587.33), ("Mi5", 659.25), ("Fa5", 698.46),
    ("Sol5", 783.99), ("La5", 880.00),
)

VIEWER_VERSION = "0.3.0-preview"
"""Higher-resolution pYIN preview with conservative display cleanup."""

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
) -> None:
    """Write a self-contained viewer of the measured, sounding frequency."""
    payload = json.loads(pitch_json_path.read_text(encoding="utf-8"))
    frames = prepare_display_frames(payload)
    media = (
        f'<video id="media" controls src="{video_relative_path}"></video>'
        if video_relative_path
        else f'<audio id="media" controls src="{audio_relative_path}"></audio>'
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        f"""<!doctype html><html lang="tr"><meta charset="utf-8">
<title>KlariVision {VIEWER_VERSION} — Duyulan frekans</title>
<style>
:root{{color-scheme:light}}*{{box-sizing:border-box}}body{{margin:0;background:#f5f6f8;color:#17212b;font:14px system-ui,-apple-system,sans-serif}}main{{max-width:1180px;margin:auto;padding:22px}}h1{{font-size:21px;margin:0 0 4px}}p{{margin:0 0 16px;color:#56616e}}.media{{position:sticky;top:0;background:#f5f6f8;padding:10px 0 14px;z-index:2}}video,audio{{display:block;max-width:100%;width:660px;max-height:330px}}.panel{{background:#fff;border:1px solid #dbe0e6;border-radius:12px;padding:14px}}.tools{{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px}}button{{border:1px solid #b9c3cf;background:#fff;border-radius:7px;padding:6px 10px;font:inherit;cursor:pointer}}button:hover{{background:#eef5fb}}input{{width:100px}}canvas{{display:block;width:100%;height:580px;border:1px solid #dbe0e6;border-radius:8px;touch-action:none}}.note{{font-size:12px;color:#66717f}}.legend{{margin-left:auto;color:#56616e;font-size:12px}}@media(max-width:650px){{main{{padding:12px}}canvas{{height:470px}}}}
</style><main>
<h1>KlariVision {VIEWER_VERSION} · Pitch konturu</h1>
<p>Bu ekran yalnızca pYIN'in ölçtüğü fiziksel frekansı (Hz) gösterir. Düşük güvenli ve tek-karelik hatalı adaylar gösterilmez; makam, karar, Sol klarnet yazılı notası ve süsleme katmanları kapalıdır.</p>
<div class="media">{media}</div>
<section class="panel"><div class="tools">
<button id="minus">− Zaman</button><button id="plus">+ Zaman</button>
<label>Görünür süre <input id="window" type="number" min="2" max="60" step="1" value="12"> sn</label>
<button id="reset">Başa dön</button><span class="legend">Tekerlek: zaman yakınlaştır · sürükle: zaman kaydır</span>
</div><canvas id="chart"></canvas><p class="note">Yatay çizgiler eşit aralıklı, ana nota frekanslarıdır. Çizgi kesintileri pYIN'in ses algılamadığı bölümleri gösterir.</p></section>
</main><script>
const frames={json.dumps(frames, ensure_ascii=False, separators=(',', ':'))};
const notes={json.dumps(NATURAL_NOTES, ensure_ascii=False, separators=(',', ':'))};
const media=document.getElementById('media'),canvas=document.getElementById('chart'),ctx=canvas.getContext('2d');
const winInput=document.getElementById('window');let windowSeconds=12,viewStart=0,drag=null,followPlayback=true;
const duration=Math.max(...frames.map(p=>p.t),0); const left=110,right=20,marginTop=22,bottom=34;
function cents(hz){{return 1200*Math.log2(hz/440)}}
function resize(){{const dpr=devicePixelRatio||1,w=canvas.clientWidth,h=canvas.clientHeight;canvas.width=w*dpr;canvas.height=h*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);draw()}}
function range(){{const visible=frames.filter(p=>p.t>=viewStart&&p.t<=viewStart+windowSeconds);const values=visible.map(p=>cents(p.hz));if(!values.length)return [cents(110),cents(880)];let lo=Math.min(...values)-190,hi=Math.max(...values)+190;return [Math.min(lo,cents(880)-300),Math.max(hi,cents(110)+300)]}}
function draw(){{const w=canvas.clientWidth,h=canvas.clientHeight,cw=w-left-right,ch=h-marginTop-bottom,[lo,hi]=range();ctx.clearRect(0,0,w,h);const x=t=>left+(t-viewStart)/windowSeconds*cw,y=hz=>marginTop+(hi-cents(hz))/(hi-lo)*ch;
ctx.fillStyle='#fff';ctx.fillRect(0,0,w,h);ctx.strokeStyle='#e2e6eb';ctx.lineWidth=1;
for(const [name,hz] of notes){{const yy=y(hz);if(yy<marginTop-5||yy>h-bottom+5)continue;ctx.beginPath();ctx.moveTo(left,yy);ctx.lineTo(w-right,yy);ctx.stroke();ctx.fillStyle='#3d4854';ctx.textAlign='right';ctx.font='12px system-ui';ctx.fillText(`${{name}}  (${{hz.toFixed(2)}} Hz)`,left-9,yy+4)}}
for(let t=Math.ceil(viewStart);t<=viewStart+windowSeconds;t++){{const xx=x(t);ctx.strokeStyle='#edf0f3';ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke();ctx.fillStyle='#687482';ctx.textAlign='center';ctx.fillText(`${{t}} sn`,xx,h-12)}}
ctx.save();ctx.beginPath();ctx.rect(left,marginTop,cw,ch);ctx.clip();ctx.strokeStyle='#111820';ctx.lineWidth=1.7;ctx.lineJoin='round';ctx.lineCap='round';ctx.beginPath();let previous=null;for(const p of frames){{if(p.t<viewStart-.05||p.t>viewStart+windowSeconds+.05)continue;const xx=x(p.t),yy=y(p.hz);if(!previous||p.t-previous.t>.030)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);previous=p}}ctx.stroke();
const current=media.currentTime||0;if(current>=viewStart&&current<=viewStart+windowSeconds){{const xx=x(current);ctx.strokeStyle='#7755b8';ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke()}}ctx.restore();ctx.strokeStyle='#aeb8c3';ctx.strokeRect(left,marginTop,cw,ch)}}
function clampStart(){{viewStart=Math.max(0,Math.min(viewStart,Math.max(0,duration-windowSeconds)))}}
function tick(){{if(!media.paused&&followPlayback){{const t=media.currentTime;if(t>viewStart+windowSeconds*.5)viewStart=t-windowSeconds*.5;if(t<viewStart)viewStart=t;clampStart()}}draw();requestAnimationFrame(tick)}}
function setWindow(value){{windowSeconds=Math.max(2,Math.min(60,value));winInput.value=windowSeconds;clampStart();draw()}}
document.getElementById('minus').onclick=()=>setWindow(windowSeconds*1.35);document.getElementById('plus').onclick=()=>setWindow(windowSeconds/1.35);document.getElementById('reset').onclick=()=>{{viewStart=0;media.currentTime=0;followPlayback=true;draw()}};winInput.onchange=()=>setWindow(Number(winInput.value));
canvas.addEventListener('wheel',e=>{{e.preventDefault();const rect=canvas.getBoundingClientRect(),ratio=(e.clientX-rect.left-left)/(rect.width-left-right),anchor=viewStart+ratio*windowSeconds;setWindow(windowSeconds*(e.deltaY>0?1.2:1/1.2));viewStart=anchor-ratio*windowSeconds;clampStart();followPlayback=false;draw()}},{{passive:false}});
canvas.addEventListener('pointerdown',e=>{{drag={{x:e.clientX,start:viewStart}};canvas.setPointerCapture(e.pointerId);followPlayback=false}});canvas.addEventListener('pointermove',e=>{{if(!drag)return;viewStart=drag.start-(e.clientX-drag.x)/(canvas.clientWidth-left-right)*windowSeconds;clampStart();draw()}});canvas.addEventListener('pointerup',()=>drag=null);media.addEventListener('seeking',()=>{{followPlayback=true}});addEventListener('resize',resize);resize();requestAnimationFrame(tick);
</script></html>""",
        encoding="utf-8",
    )
