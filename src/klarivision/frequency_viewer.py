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

VIEWER_VERSION = "0.3.3-preview"
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
<button id="vertical-out">− Dikey</button><button id="vertical-in">+ Dikey</button>
<label><input id="vertical-follow" type="checkbox"> Eğriyi dikey takip et</label>
<button id="reset">Başa dön</button><span class="legend">Tekerlek: imleç çevresinde zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır · sürükle: kayıtta gezin</span>
</div><canvas id="chart"></canvas><p class="note">Yatay çizgiler eşit aralıklı, ana nota frekanslarıdır. Çizgi kesintileri pYIN'in ses algılamadığı bölümleri gösterir.</p></section>
</main><script>
const frames={json.dumps(frames, ensure_ascii=False, separators=(',', ':'))};
const notes={json.dumps(NATURAL_NOTES, ensure_ascii=False, separators=(',', ':'))};
const media=document.getElementById('media'),canvas=document.getElementById('chart'),ctx=canvas.getContext('2d');
const winInput=document.getElementById('window');let windowSeconds=12,viewStart=-6,drag=null,followPlayback=true;
const verticalFollowInput=document.getElementById('vertical-follow');let verticalSpan=2400,verticalCenter=0,verticalReady=false;
const duration=Math.max(...frames.map(p=>p.t),0); const left=110,right=20,marginTop=22,bottom=34;
function cents(hz){{return 1200*Math.log2(hz/440)}}
function resize(){{const dpr=devicePixelRatio||1,w=canvas.clientWidth,h=canvas.clientHeight;canvas.width=w*dpr;canvas.height=h*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);draw()}}
function visibleValues(){{return frames.filter(p=>p.t>=viewStart&&p.t<=viewStart+windowSeconds).map(p=>cents(p.hz))}}
function middle(values){{if(!values.length)return 0;const ordered=[...values].sort((a,b)=>a-b),half=Math.floor(ordered.length/2);return ordered.length%2?ordered[half]:(ordered[half-1]+ordered[half])/2}}
function followValues(){{const time=media.currentTime||0;return frames.filter(p=>Math.abs(p.t-time)<=.25).map(p=>cents(p.hz))}}
function range(){{const values=visibleValues();if(!verticalReady){{verticalCenter=middle(values.length?values:frames.map(p=>cents(p.hz)));verticalReady=true}}const target=verticalFollowInput.checked?followValues():values;if(verticalFollowInput.checked&&target.length)verticalCenter+=((middle(target)-verticalCenter)*.14);return [verticalCenter-verticalSpan/2,verticalCenter+verticalSpan/2]}}
function draw(){{const w=canvas.clientWidth,h=canvas.clientHeight,cw=w-left-right,ch=h-marginTop-bottom,[lo,hi]=range();ctx.clearRect(0,0,w,h);const x=t=>left+(t-viewStart)/windowSeconds*cw,y=hz=>marginTop+(hi-cents(hz))/(hi-lo)*ch;
ctx.fillStyle='#fff';ctx.fillRect(0,0,w,h);ctx.strokeStyle='#e2e6eb';ctx.lineWidth=1;
for(const [name,hz] of notes){{const yy=y(hz);if(yy<marginTop-5||yy>h-bottom+5)continue;ctx.beginPath();ctx.moveTo(left,yy);ctx.lineTo(w-right,yy);ctx.stroke();ctx.fillStyle='#3d4854';ctx.textAlign='right';ctx.font='12px system-ui';ctx.fillText(`${{name}}  (${{hz.toFixed(2)}} Hz)`,left-9,yy+4)}}
for(let t=Math.max(0,Math.ceil(viewStart));t<=Math.min(duration,viewStart+windowSeconds);t++){{const xx=x(t);ctx.strokeStyle='#edf0f3';ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke();ctx.fillStyle='#687482';ctx.textAlign='center';ctx.fillText(`${{t}} sn`,xx,h-12)}}
ctx.save();ctx.beginPath();ctx.rect(left,marginTop,cw,ch);ctx.clip();ctx.strokeStyle='#111820';ctx.lineWidth=1.7;ctx.lineJoin='round';ctx.lineCap='round';ctx.beginPath();let previous=null;for(const p of frames){{if(p.t<viewStart-.05||p.t>viewStart+windowSeconds+.05)continue;const xx=x(p.t),yy=y(p.hz);if(!previous||p.t-previous.t>.030)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);previous=p}}ctx.stroke();
const current=media.currentTime||0;if(current>=viewStart&&current<=viewStart+windowSeconds){{const xx=x(current);ctx.strokeStyle='#7755b8';ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke()}}ctx.restore();ctx.strokeStyle='#aeb8c3';ctx.strokeRect(left,marginTop,cw,ch)}}
function clampStart(){{viewStart=Math.max(-windowSeconds/2,Math.min(viewStart,duration-windowSeconds/2))}}
function centerOnPlayhead(){{viewStart=(media.currentTime||0)-windowSeconds/2;clampStart()}}
function tick(){{if(followPlayback)centerOnPlayhead();draw();requestAnimationFrame(tick)}}
function setWindow(value){{windowSeconds=Math.max(2,Math.min(60,value));winInput.value=windowSeconds;centerOnPlayhead();draw()}}
function setVerticalSpan(value,anchor){{const previous=verticalSpan;verticalSpan=Math.max(200,Math.min(4800,value));if(anchor!==undefined){{const ratio=(verticalCenter+previous/2-anchor)/previous;verticalCenter=anchor+(ratio-.5)*verticalSpan}}draw()}}
document.getElementById('minus').onclick=()=>setWindow(windowSeconds*1.35);document.getElementById('plus').onclick=()=>setWindow(windowSeconds/1.35);document.getElementById('reset').onclick=()=>{{media.currentTime=0;followPlayback=true;centerOnPlayhead();draw()}};winInput.onchange=()=>setWindow(Number(winInput.value));
document.getElementById('vertical-out').onclick=()=>setVerticalSpan(verticalSpan*1.35);document.getElementById('vertical-in').onclick=()=>setVerticalSpan(verticalSpan/1.35);verticalFollowInput.onchange=()=>draw();
canvas.addEventListener('wheel',e=>{{e.preventDefault();const rect=canvas.getBoundingClientRect();if(e.shiftKey){{const ratio=(e.clientY-rect.top-marginTop)/(rect.height-marginTop-bottom),[lo,hi]=range(),anchor=hi-ratio*(hi-lo);setVerticalSpan(verticalSpan*(e.deltaY>0?1.2:1/1.2),anchor);return}}setWindow(windowSeconds*(e.deltaY>0?1.2:1/1.2));followPlayback=true;}},{{passive:false}});
canvas.addEventListener('pointerdown',e=>{{drag={{x:e.clientX,time:media.currentTime||0}};canvas.setPointerCapture(e.pointerId);followPlayback=true}});canvas.addEventListener('pointermove',e=>{{if(!drag)return;const change=(e.clientX-drag.x)/(canvas.clientWidth-left-right)*windowSeconds;media.currentTime=Math.max(0,Math.min(duration,drag.time-change));centerOnPlayhead();draw()}});canvas.addEventListener('pointerup',()=>drag=null);media.addEventListener('seeking',()=>{{followPlayback=true;centerOnPlayhead()}});addEventListener('resize',resize);centerOnPlayhead();resize();requestAnimationFrame(tick);
</script></html>""",
        encoding="utf-8",
    )
