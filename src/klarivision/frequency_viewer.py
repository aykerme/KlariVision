"""Stable, frequency-only pitch contour viewer.

This viewer intentionally has no makam, karar, transposition or ornament logic.
It is the verified reference layer for all later musical interpretations.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from statistics import median


SCALE_LABELS = {
    "major": {
        "0": ("Do", "Re", "Mi", "Fa", "Sol", "La", "Si"),
        "2": ("Re", "Mi", "Fa♯", "Sol", "La", "Si", "Do♯"),
        "4": ("Mi", "Fa♯", "Sol♯", "La", "Si", "Do♯", "Re♯"),
        "5": ("Fa", "Sol", "La", "Si♭", "Do", "Re", "Mi"),
        "7": ("Sol", "La", "Si", "Do", "Re", "Mi", "Fa♯"),
        "9": ("La", "Si", "Do♯", "Re", "Mi", "Fa♯", "Sol♯"),
        "11": ("Si", "Do♯", "Re♯", "Mi", "Fa♯", "Sol♯", "La♯"),
    },
    "minor": {
        "0": ("Do", "Re", "Mi♭", "Fa", "Sol", "La♭", "Si♭"),
        "2": ("Re", "Mi", "Fa", "Sol", "La", "Si♭", "Do"),
        "4": ("Mi", "Fa♯", "Sol", "La", "Si", "Do", "Re"),
        "5": ("Fa", "Sol", "La♭", "Si♭", "Do", "Re♭", "Mi♭"),
        "7": ("Sol", "La", "Si♭", "Do", "Re", "Mi♭", "Fa"),
        "9": ("La", "Si", "Do", "Re", "Mi", "Fa", "Sol"),
        "11": ("Si", "Do♯", "Re", "Mi", "Fa♯", "Sol", "La"),
    },
}

# Arel-Ezgi-Uzdilek 53-koma reference octave used in the video the user supplied.
# The reference is Neva (Re) = 220 Hz; frequency is 220 * 2 ** (koma / 53).
# Names and comma positions follow the source's one-octave frequency table.
TURKISH_53_COMMA_NOTES = (
    (0, "Nevâ", "Re", True),
    (4, "Nîm Hisar", "", False),
    (5, "Hisar", "", False),
    (8, "Dik Hisar", "", False),
    (9, "Hüseynî", "Mi", True),
    (13, "Acem", "Fa", True),
    (14, "Dik Acem", "", False),
    (17, "Eviç", "Fa♯", False),
    (18, "Mahur", "", False),
    (21, "Dik Mahur", "", False),
    (22, "Gerdâniye", "Sol", True),
    (26, "Nîm Şehnâz", "", False),
    (27, "Şehnâz", "", False),
    (30, "Dik Şehnâz", "", False),
    (31, "Muhayyer", "La", True),
    (35, "Sünbüle", "", False),
    (36, "Dik Sünbüle", "", False),
    (39, "Tiz Segâh", "", False),
    (40, "Tiz Bûselik", "Si", True),
    (44, "Tiz Çârgâh", "Do", True),
    (45, "Tiz Dik Çârgâh", "", False),
    (48, "Tiz Nîm Hicaz", "", False),
    (49, "Tiz Hicaz", "", False),
    (52, "Tiz Dik Hicaz", "", False),
    (53, "Tiz Nevâ", "Re", True),
)

VIEWER_VERSION = "0.3.10-preview"
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
:root{{color-scheme:light}}*{{box-sizing:border-box}}body{{margin:0;background:#f5f6f8;color:#17212b;font:14px system-ui,-apple-system,sans-serif}}main{{max-width:1180px;margin:auto;padding:22px}}h1{{font-size:21px;margin:0 0 4px}}p{{margin:0 0 16px;color:#56616e}}.media{{position:sticky;top:0;background:#f5f6f8;padding:10px 0 14px;z-index:2}}video,audio{{display:block;max-width:100%;width:660px;max-height:330px}}.panel{{background:#fff;border:1px solid #dbe0e6;border-radius:12px;padding:14px}}.tools{{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px}}button{{border:1px solid #b9c3cf;background:#fff;border-radius:7px;padding:6px 10px;font:inherit;cursor:pointer}}button:hover{{background:#eef5fb}}button[aria-pressed="true"]{{background:#dceefe;border-color:#4785be;color:#173d62;box-shadow:inset 0 0 0 1px #8bb7de}}input{{width:100px}}select{{font:inherit;padding:5px 7px;border:1px solid #b9c3cf;border-radius:7px;background:#fff}}.chart-scroll{{display:grid;grid-template-columns:minmax(0,1fr) 18px;grid-template-rows:580px 18px;gap:5px}}canvas{{display:block;width:100%;height:100%;border:1px solid #dbe0e6;border-radius:8px;touch-action:none}}#time-scroll{{grid-column:1;grid-row:2;width:100%;margin:0;accent-color:#7755b8}}#vertical-scroll{{grid-column:2;grid-row:1;width:18px;height:100%;margin:0;writing-mode:vertical-lr;direction:rtl;accent-color:#7755b8}}.note{{font-size:12px;color:#66717f}}.legend{{margin-left:auto;color:#56616e;font-size:12px}}@media(max-width:650px){{main{{padding:12px}}.chart-scroll{{grid-template-rows:470px 18px}}}}
</style><main>
<h1>KlariVision {VIEWER_VERSION} · Pitch konturu</h1>
<p>Pitch eğrisi pYIN'in ölçtüğü fiziksel frekanstır (Hz). Sol eksen yalnızca görsel bir başvurudur; frekans ölçümü transpoze edilmez.</p>
<div class="media">{media}</div>
<section class="panel"><div class="tools">
<button id="minus">− Zaman</button><button id="plus">+ Zaman</button>
<label>Görünür süre <input id="window" type="number" min="2" max="60" step="1" value="12"> sn</label>
<button id="vertical-out">− Dikey</button><button id="vertical-in">+ Dikey</button>
<label><input id="vertical-follow" type="checkbox"> Eğriyi dikey takip et</label>
<label>Eksen <select id="scale-mode"><option value="major">Majör</option><option value="minor">Minör</option><option value="turkish">Türk Müziği</option></select></label>
<label>Karar <select id="tonic"><option value="0">Do</option><option value="2">Re</option><option value="4">Mi</option><option value="5">Fa</option><option value="7">Sol</option><option value="9">La</option><option value="11">Si</option></select></label>
<label><input id="turkish-details" type="checkbox" disabled> Ara koma perdeleri</label>
<button id="set-a">A: 0.00 sn</button><button id="set-b">B: Son</button><button id="loop" aria-pressed="false">Loop</button><button id="reset">Başa dön</button><span class="legend">Tekerlek: imleç çevresinde zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır · sürükle: kayıtta gezin</span>
</div><div class="chart-scroll"><canvas id="chart"></canvas><input id="vertical-scroll" type="range" aria-label="Dikey grafiği kaydır"><input id="time-scroll" type="range" aria-label="Kayıtta gezin"><span></span></div><p class="note">Yatay çubuk kayıtta gezinir; sağdaki çubuk dikey merkezi değiştirir. Çizgi kesintileri pYIN'in ses algılamadığı bölümleri gösterir.</p></section>
</main><script>
const frames={json.dumps(frames, ensure_ascii=False, separators=(',', ':'))};
const scaleLabels={json.dumps(SCALE_LABELS, ensure_ascii=False, separators=(',', ':'))};
const turkishCommaNotes={json.dumps(TURKISH_53_COMMA_NOTES, ensure_ascii=False, separators=(',', ':'))};
const media=document.getElementById('media'),canvas=document.getElementById('chart'),ctx=canvas.getContext('2d'),timeScroll=document.getElementById('time-scroll'),verticalScroll=document.getElementById('vertical-scroll');
const setAButton=document.getElementById('set-a'),setBButton=document.getElementById('set-b'),loopButton=document.getElementById('loop');
const scaleMode=document.getElementById('scale-mode'),tonicInput=document.getElementById('tonic'),turkishDetailsInput=document.getElementById('turkish-details');
const winInput=document.getElementById('window');let windowSeconds=12,viewStart=-6,drag=null,followPlayback=true;
const verticalFollowInput=document.getElementById('vertical-follow');let verticalSpan=2400,verticalCenter=0,verticalReady=false;
let duration=Math.max(...frames.map(p=>p.t),0),loopA=0,loopB=duration,loopEnabled=false,loopBManual=false; const left=110,right=20,marginTop=22,bottom=34;
function cents(hz){{return 1200*Math.log2(hz/440)}}
function turkishNotes(){{const showDetails=turkishDetailsInput.checked;return turkishCommaNotes.filter(([, , ,primary])=>showDetails||primary).map(([koma,name,solfege])=>{{const label=showDetails?`${{name}}${{solfege?` (${{solfege}})`:''}} · ${{koma}} koma`:`${{name}}${{solfege?` (${{solfege}})`:''}}`;return [label,220*Math.pow(2,koma/53)]}})}}
function scaleNotes(){{if(scaleMode.value==='turkish')return turkishNotes();const tonic=Number(tonicInput.value),intervals=scaleMode.value==='major'?[0,2,4,5,7,9,11]:[0,2,3,5,7,8,10],names=scaleLabels[scaleMode.value][String(tonic)],namesByPitchClass=new Map(intervals.map((interval,index)=>[(tonic+interval)%12,names[index]])),result=[];for(let midi=24;midi<=108;midi++){{const name=namesByPitchClass.get(midi%12);if(!name)continue;const octave=Math.floor(midi/12)-1,hz=440*Math.pow(2,(midi-69)/12);result.push([`${{name}}${{octave}}`,hz])}}return result}}
function formatTime(time){{return `${{time.toFixed(2)}} sn`}}
function updateLoopButtons(){{setAButton.textContent=`A: ${{formatTime(loopA)}}`;setBButton.textContent=`B: ${{loopBManual?formatTime(loopB):'Son'}}`;loopButton.setAttribute('aria-pressed',String(loopEnabled));}}
function resize(){{const dpr=devicePixelRatio||1,w=canvas.clientWidth,h=canvas.clientHeight;canvas.width=w*dpr;canvas.height=h*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);draw()}}
function visibleValues(){{return frames.filter(p=>p.t>=viewStart&&p.t<=viewStart+windowSeconds).map(p=>cents(p.hz))}}
function middle(values){{if(!values.length)return 0;const ordered=[...values].sort((a,b)=>a-b),half=Math.floor(ordered.length/2);return ordered.length%2?ordered[half]:(ordered[half-1]+ordered[half])/2}}
function followValues(){{const time=media.currentTime||0;return frames.filter(p=>Math.abs(p.t-time)<=.25).map(p=>cents(p.hz))}}
function range(){{const values=visibleValues();if(!verticalReady){{verticalCenter=middle(values.length?values:frames.map(p=>cents(p.hz)));verticalReady=true}}const target=verticalFollowInput.checked?followValues():values;if(verticalFollowInput.checked&&target.length)verticalCenter+=((middle(target)-verticalCenter)*.14);return [verticalCenter-verticalSpan/2,verticalCenter+verticalSpan/2]}}
function updateScrollbars(){{timeScroll.min=0;timeScroll.max=Math.max(1,Math.round(duration*1000));timeScroll.value=Math.round((media.currentTime||0)*1000);const values=frames.map(p=>cents(p.hz));if(!values.length)return;verticalScroll.min=Math.floor(Math.min(...values)-verticalSpan/2);verticalScroll.max=Math.ceil(Math.max(...values)+verticalSpan/2);verticalScroll.value=Math.round(verticalCenter)}}
function draw(){{const w=canvas.clientWidth,h=canvas.clientHeight,cw=w-left-right,ch=h-marginTop-bottom,[lo,hi]=range();ctx.clearRect(0,0,w,h);const x=t=>left+(t-viewStart)/windowSeconds*cw,y=hz=>marginTop+(hi-cents(hz))/(hi-lo)*ch;
ctx.fillStyle='#fff';ctx.fillRect(0,0,w,h);ctx.strokeStyle='#e2e6eb';ctx.lineWidth=1;
for(const [name,hz] of scaleNotes()){{const yy=y(hz);if(yy<marginTop-5||yy>h-bottom+5)continue;ctx.beginPath();ctx.moveTo(left,yy);ctx.lineTo(w-right,yy);ctx.stroke();ctx.fillStyle='#3d4854';ctx.textAlign='right';ctx.font='12px system-ui';ctx.fillText(`${{name}}  (${{hz.toFixed(2)}} Hz)`,left-9,yy+4)}}
for(let t=Math.max(0,Math.ceil(viewStart));t<=Math.min(duration,viewStart+windowSeconds);t++){{const xx=x(t);ctx.strokeStyle='#edf0f3';ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke();ctx.fillStyle='#687482';ctx.textAlign='center';ctx.fillText(`${{t}} sn`,xx,h-12)}}
if(loopEnabled){{const start=Math.max(left,x(loopA)),end=Math.min(w-right,x(loopB));if(end>start){{ctx.fillStyle='rgba(112,181,235,.20)';ctx.fillRect(start,marginTop,end-start,ch)}}}}
ctx.save();ctx.beginPath();ctx.rect(left,marginTop,cw,ch);ctx.clip();ctx.strokeStyle='#111820';ctx.lineWidth=1.7;ctx.lineJoin='round';ctx.lineCap='round';ctx.beginPath();let previous=null;for(const p of frames){{if(p.t<viewStart-.05||p.t>viewStart+windowSeconds+.05)continue;const xx=x(p.t),yy=y(p.hz);if(!previous||p.t-previous.t>.030)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);previous=p}}ctx.stroke();
function marker(time,label,color){{if(time<viewStart||time>viewStart+windowSeconds)return;const xx=x(time);ctx.strokeStyle=color;ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke();ctx.fillStyle=color;ctx.font='bold 12px system-ui';ctx.textAlign='center';ctx.fillText(label,xx,marginTop+14)}}marker(loopA,'A','#157347');marker(loopB,'B','#bd5b00');const current=media.currentTime||0;if(current>=viewStart&&current<=viewStart+windowSeconds){{const xx=x(current);ctx.strokeStyle='#7755b8';ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(xx,marginTop);ctx.lineTo(xx,h-bottom);ctx.stroke()}}ctx.restore();ctx.strokeStyle='#aeb8c3';ctx.strokeRect(left,marginTop,cw,ch);updateScrollbars()}}
function clampStart(){{viewStart=Math.max(-windowSeconds/2,Math.min(viewStart,duration-windowSeconds/2))}}
function centerOnPlayhead(){{viewStart=(media.currentTime||0)-windowSeconds/2;clampStart()}}
function tick(){{if(loopEnabled&&!media.paused&&(media.currentTime||0)>=loopB){{media.currentTime=loopA}}if(followPlayback)centerOnPlayhead();draw();requestAnimationFrame(tick)}}
function setWindow(value){{windowSeconds=Math.max(2,Math.min(60,value));winInput.value=windowSeconds;centerOnPlayhead();draw()}}
function setVerticalSpan(value,anchor){{const previous=verticalSpan;verticalSpan=Math.max(200,Math.min(4800,value));if(anchor!==undefined){{const ratio=(verticalCenter+previous/2-anchor)/previous;verticalCenter=anchor+(ratio-.5)*verticalSpan}}draw()}}
document.getElementById('minus').onclick=()=>setWindow(windowSeconds*1.35);document.getElementById('plus').onclick=()=>setWindow(windowSeconds/1.35);document.getElementById('reset').onclick=()=>{{media.currentTime=0;followPlayback=true;centerOnPlayhead();draw()}};winInput.onchange=()=>setWindow(Number(winInput.value));
document.getElementById('vertical-out').onclick=()=>setVerticalSpan(verticalSpan*1.35);document.getElementById('vertical-in').onclick=()=>setVerticalSpan(verticalSpan/1.35);verticalFollowInput.onchange=()=>draw();
scaleMode.onchange=()=>{{const isTurkish=scaleMode.value==='turkish';tonicInput.disabled=isTurkish;turkishDetailsInput.disabled=!isTurkish;if(!isTurkish)turkishDetailsInput.checked=false;draw()}};tonicInput.onchange=()=>draw();turkishDetailsInput.onchange=()=>draw();
setAButton.onclick=()=>{{loopA=Math.min(media.currentTime||0,loopB);updateLoopButtons();draw()}};setBButton.onclick=()=>{{loopB=Math.max(media.currentTime||0,loopA);loopBManual=true;updateLoopButtons();draw()}};loopButton.onclick=()=>{{loopEnabled=!loopEnabled;if(loopEnabled){{if(loopB-loopA<.02){{loopA=0;loopB=duration;loopBManual=false}}media.currentTime=loopA;media.play()}}else if(media.currentTime<duration)media.play();updateLoopButtons();draw()}};
timeScroll.addEventListener('input',()=>{{media.currentTime=Number(timeScroll.value)/1000;followPlayback=true;centerOnPlayhead();draw()}});verticalScroll.addEventListener('input',()=>{{verticalCenter=Number(verticalScroll.value);verticalReady=true;verticalFollowInput.checked=false;draw()}});
canvas.addEventListener('wheel',e=>{{e.preventDefault();const rect=canvas.getBoundingClientRect();if(e.shiftKey){{const ratio=(e.clientY-rect.top-marginTop)/(rect.height-marginTop-bottom),[lo,hi]=range(),anchor=hi-ratio*(hi-lo);setVerticalSpan(verticalSpan*(e.deltaY>0?1.2:1/1.2),anchor);return}}setWindow(windowSeconds*(e.deltaY>0?1.2:1/1.2));followPlayback=true;}},{{passive:false}});
canvas.addEventListener('pointerdown',e=>{{drag={{x:e.clientX,time:media.currentTime||0,moved:false}};canvas.setPointerCapture(e.pointerId);followPlayback=true}});canvas.addEventListener('pointermove',e=>{{if(!drag)return;const change=(e.clientX-drag.x)/(canvas.clientWidth-left-right)*windowSeconds;if(!drag.moved&&Math.abs(e.clientX-drag.x)<4)return;drag.moved=true;media.currentTime=Math.max(0,Math.min(duration,drag.time-change));centerOnPlayhead();draw()}});canvas.addEventListener('pointerup',()=>{{if(drag&&!drag.moved){{if(media.paused)media.play().catch(()=>{{}});else media.pause()}}drag=null}});media.addEventListener('seeking',()=>{{followPlayback=true;centerOnPlayhead()}});media.addEventListener('loadedmetadata',()=>{{if(Number.isFinite(media.duration)){{duration=Math.max(duration,media.duration);if(!loopBManual)loopB=duration}}updateLoopButtons();centerOnPlayhead();draw()}});updateLoopButtons();addEventListener('resize',resize);centerOnPlayhead();resize();requestAnimationFrame(tick);
</script></html>""",
        encoding="utf-8",
    )
