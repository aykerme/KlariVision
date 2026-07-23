"""Build an aligned A/B pitch-contour comparison for matched performances."""

from __future__ import annotations

import json
import math
from pathlib import Path

from .contour_viewer import LEVELS


def build_ab_viewer(
    control_pitch_json: Path,
    ornament_pitch_json: Path,
    control_video_relative_path: str,
    ornament_video_relative_path: str,
    control_annotations_json: Path,
    ornament_annotations_json: Path,
    output: Path,
) -> None:
    """Write one standalone A/B viewer; the slider fine-tunes the time alignment."""
    control = _pitch_data(control_pitch_json)
    ornament = _pitch_data(ornament_pitch_json)
    control_annotations = _annotations(control_annotations_json)
    ornament_annotations = _annotations(ornament_annotations_json)
    output.write_text(
        _html(
            control,
            ornament,
            control_annotations,
            ornament_annotations,
            control_video_relative_path,
            ornament_video_relative_path,
        ),
        encoding="utf-8",
    )


def _pitch_data(path: Path) -> list[list[float]]:
    frames = json.loads(path.read_text(encoding="utf-8"))["frames"]
    return [
        [
            round(float(frame["time_seconds"]), 3),
            round(1200 * math.log2(float(frame["frequency_hz"]) / 440), 1),
        ]
        for frame in frames
        if frame["frequency_hz"] is not None
    ]


def _annotations(path: Path) -> list[dict[str, object]]:
    return json.loads(path.read_text(encoding="utf-8"))["annotations"]


def _html(
    control: list[list[float]],
    ornament: list[list[float]],
    control_annotations: list[dict[str, object]],
    ornament_annotations: list[dict[str, object]],
    control_video: str,
    ornament_video: str,
) -> str:
    return f'''<!doctype html><meta charset="utf-8"><title>KlariVision A/B Karşılaştırma</title>
<style>
body{{font-family:system-ui;margin:24px;color:#1e1e1e}}.videos{{display:grid;grid-template-columns:1fr 1fr;gap:18px;align-items:start}}video{{width:100%;max-height:340px}}.label{{font-weight:650;margin:0 0 6px}}.controls{{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:16px 0}}button,input{{font:inherit}}canvas{{width:100%;border:1px solid #ddd}}.hint{{color:#666}}@media(max-width:800px){{.videos{{grid-template-columns:1fr}}video{{max-height:430px}}}}
</style>
<h1>Süsleme A/B Karşılaştırması</h1>
<div class="videos"><section><p class="label">Süslemesiz kontrol</p><video id="control-video" controls src="{control_video}"></video></section><section><p class="label">Süslemeli karşılık</p><video id="ornament-video" controls src="{ornament_video}"></video></section></div>
<div class="controls"><button id="play-both">İkisini oynat</button><label for="shift">Süslemeli zaman kaydırması:</label><input id="shift" type="range" min="-1.5" max="1.5" value="0" step="0.01"><output id="shift-value">0.00 sn</output></div>
<p class="hint">Siyah: süslemesiz eğri · Mavi: süslemeli eğri · Üst şeritler: insan tarafından işaretlenen vibrato ve çarpmalar. Kaydırma, aynı melodik noktaları görsel olarak hizalar.</p>
<canvas id="chart" width="1200" height="650"></canvas>
<script>
const plain={json.dumps(control,separators=(",",":"))},ornamented={json.dumps(ornament,separators=(",",":"))},plainMarks={json.dumps(control_annotations,separators=(",",":"))},ornamentMarks={json.dumps(ornament_annotations,separators=(",",":"))},levels={json.dumps(LEVELS,ensure_ascii=False,separators=(",",":"))};
const controlVideo=document.querySelector("#control-video"),ornamentVideo=document.querySelector("#ornament-video"),play=document.querySelector("#play-both"),shiftInput=document.querySelector("#shift"),shiftValue=document.querySelector("#shift-value"),canvas=document.querySelector("#chart"),ctx=canvas.getContext("2d"),L=180,R=20,T=42,B=38,D=Math.max(plain.at(-1)[0],ornamented.at(-1)[0]);let shift=0;
const X=time=>L+time/D*(canvas.width-L-R),Y=value=>T+(1300-value)/2600*(canvas.height-T-B);
function color(kind,alpha){{return kind==="vibrato"?"rgba(42,150,95,"+alpha+")":"rgba(205,80,75,"+alpha+")"}}
function marks(data,y){{data.forEach(mark=>{{const start=X(mark.start_seconds+shift*(y===18));const end=X(mark.end_seconds+shift*(y===18));ctx.fillStyle=color(mark.kind,.75);ctx.fillRect(start,y,Math.max(2,end-start),10)}})}}
function curve(data,color,offset){{ctx.strokeStyle=color;ctx.lineWidth=2;ctx.beginPath();let started=false;data.forEach(point=>{{const time=point[0]+offset;if(time<0||time>D)return;if(started)ctx.lineTo(X(time),Y(point[1]));else{{ctx.moveTo(X(time),Y(point[1]));started=true}}}});ctx.stroke()}}
function draw(){{ctx.clearRect(0,0,canvas.width,canvas.height);ctx.font="16px system-ui";levels.forEach(level=>{{const y=Y(level[0]);ctx.strokeStyle="#ddd";ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(L,y);ctx.lineTo(canvas.width-R,y);ctx.stroke();ctx.fillStyle="#1e1e1e";ctx.fillText(level[1],10,y+5)}});ctx.fillStyle="#1e1e1e";ctx.fillText("Kontrol etiketleri",L,T-24);ctx.fillText("Süslemeli etiketleri",L,T-8);marks(plainMarks,4);marks(ornamentMarks,18);curve(plain,"#111",0);curve(ornamented,"#2467c9",shift);ctx.strokeStyle="#7650c8";ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(X(controlVideo.currentTime),T);ctx.lineTo(X(controlVideo.currentTime),canvas.height-B);ctx.stroke();requestAnimationFrame(draw)}}
play.addEventListener("click",()=>{{if(controlVideo.paused){{ornamentVideo.currentTime=Math.max(0,controlVideo.currentTime-shift);controlVideo.play();ornamentVideo.play();play.textContent="Duraklat"}}else{{controlVideo.pause();ornamentVideo.pause();play.textContent="İkisini oynat"}}}});shiftInput.addEventListener("input",()=>{{shift=Number(shiftInput.value);shiftValue.textContent=shift.toFixed(2)+" sn"}});controlVideo.addEventListener("pause",()=>{{play.textContent="İkisini oynat"}});draw();
</script>'''
