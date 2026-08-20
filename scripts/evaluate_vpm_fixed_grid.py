#!/usr/bin/env python3
"""Evaluate live engines against a fixed-grid Vocal Pitch Monitor recording."""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np

from compare_live_pitch_engines import estimate_autocorrelation, estimate_yin, run_engine


ROOT = Path(__file__).resolve().parents[1]
TRACE = ROOT / "outputs/vpm-gercek-klarnet-trace-v02.json"
PYIN = ROOT / "outputs/gercek-klarnet-calimi.vamp-pyin.json"
AUDIO = Path("/private/tmp/gercek-klarnet-calimi.wav")
JSON_OUTPUT = ROOT / "outputs/vpm-sabit-eksen-motor-karsilastirma-v02.json"
HTML_OUTPUT = ROOT / "outputs/vpm-sabit-eksen-motor-karsilastirma-v02.html"

# Detected from the unchanged VPM grid in the supplied v02 capture.
GRID_D3_Y = 2187.0
GRID_D3_HZ = 146.8324
PIXELS_PER_SEMITONE = 134.0
TIME_OFFSET_SECONDS = 4.58


def vpm_frequency(y: float) -> float:
    return GRID_D3_HZ * 2 ** ((GRID_D3_Y - y) / (12 * PIXELS_PER_SEMITONE))


def cents(left: float, right: float) -> float:
    return 1200 * math.log2(left / right)


def read_wav() -> tuple[np.ndarray, int]:
    with wave.open(str(AUDIO), "rb") as stream:
        return np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").astype(np.float64) / 32768.0, stream.getframerate()


def interpolate(frames: list[dict[str, float]], time: float) -> float | None:
    if not frames or time < frames[0]["time_seconds"] or time > frames[-1]["time_seconds"]:
        return None
    times = np.array([frame["time_seconds"] for frame in frames])
    values = np.array([frame.get("frequency", frame.get("frequency_hz")) for frame in frames])
    return float(2 ** np.interp(time, times, np.log2(values)))


def evaluate(reference: list[dict[str, float]], frames: list[dict[str, float]]) -> dict[str, object]:
    points = []
    for item in reference:
        estimate = interpolate(frames, item["source_seconds"])
        if estimate is None:
            continue
        difference = cents(estimate, item["vpm_frequency_hz"])
        if abs(difference) < 500:
            points.append({**item, "engine_frequency_hz": round(estimate, 4), "difference_cents": round(difference, 2)})
    absolute = [abs(item["difference_cents"]) for item in points]
    return {
        "points": len(points),
        "median_absolute_difference_cents": round(float(np.median(absolute)), 2),
        "p95_absolute_difference_cents": round(float(np.percentile(absolute, 95)), 2),
        "points_data": points,
    }


def write_html(payload: dict[str, object]) -> None:
    data = json.dumps(payload, separators=(",", ":"))
    cards = "".join(
        f"<div class=card><b>{name}</b><br><strong>{entry['median_absolute_difference_cents']} cent</strong><br><small>{entry['points']} örnek · %95: {entry['p95_absolute_difference_cents']} cent</small></div>"
        for name, entry in (("VPM / pYIN", payload["pyin"]), ("VPM / canlı YIN", payload["yin"]), ("VPM / öz-ilinti", payload["autocorrelation"]))
    )
    page = f"""<!doctype html><meta charset=\"utf-8\"><title>VPM sabit eksen motor karşılaştırması</title>
<style>body{{font:16px -apple-system,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:32px}}main{{max-width:1120px;margin:auto}}.cards{{display:flex;gap:14px;flex-wrap:wrap}}.card{{background:white;border-radius:14px;padding:18px 20px;min-width:220px}}strong{{font-size:1.25em}}canvas{{width:100%;height:440px;background:#0a0b0e;border-radius:14px;margin-top:18px}}small{{color:#6e6e73}}</style>
<main><h1>VPM sabit eksen / gerçek klarnet</h1><p>VPM grafiğinin dikey nota çizgileri video boyunca sabit tutuldu. Bu yüzden ekran eğrisi doğrudan Hz/cents referansına dönüştürüldü.</p><div class=cards>{cards}</div><canvas id=c width=1120 height=440></canvas><p><small>Sarı: VPM · Mavi: offline pYIN · Mor: canlı YIN · Turuncu: canlı öz-ilinti. Büyük sıçramalar %95 değerinde görünür; medyan değer sabit tonlardaki tipik yakınlığı gösterir.</small></p></main>
<script>const d={data},c=document.querySelector('#c'),x=c.getContext('2d'),p=38,W=c.width,H=c.height,sets=[['pyin','#55b7f5'],['yin','#bf8cff'],['autocorrelation','#ff9f43']],q=d.pyin.points_data,lo=Math.min(...q.map(a=>a.source_seconds)),hi=Math.max(...q.map(a=>a.source_seconds)),all=sets.flatMap(([k])=>d[k].points_data.flatMap(a=>[a.vpm_frequency_hz,a.engine_frequency_hz])),fl=Math.min(...all),fh=Math.max(...all),px=t=>p+(W-2*p)*(t-lo)/(hi-lo),py=f=>H-p-(H-2*p)*(Math.log2(f)-Math.log2(fl))/(Math.log2(fh)-Math.log2(fl));for(let i=0;i<6;i++){{let y=p+(H-2*p)*i/5;x.strokeStyle='#30333b';x.beginPath();x.moveTo(p,y);x.lineTo(W-p,y);x.stroke()}}function draw(rows,key,color){{x.strokeStyle=color;x.lineWidth=1.5;x.beginPath();rows.forEach((r,i)=>i?x.lineTo(px(r.source_seconds),py(r[key])):x.moveTo(px(r.source_seconds),py(r[key])));x.stroke()}}draw(q,'vpm_frequency_hz','#f2df00');sets.forEach(([key,color])=>draw(d[key].points_data,'engine_frequency_hz',color));</script>"""
    HTML_OUTPUT.write_text(page, encoding="utf-8")


def main() -> None:
    trace = json.loads(TRACE.read_text(encoding="utf-8"))["samples"]
    reference = [
        {"source_seconds": round(float(row["vpm_seconds"]) - TIME_OFFSET_SECONDS, 4), "vpm_frequency_hz": round(vpm_frequency(float(row["live_y"])), 4)}
        for row in trace if row.get("live_y") is not None
    ]
    audio, sample_rate = read_wav()
    pyin = json.loads(PYIN.read_text(encoding="utf-8"))["frames"]
    pyin = [frame for frame in pyin if frame.get("voiced")]
    yin = run_engine(audio, sample_rate, estimate_yin, stabilize_yin=True)
    autocorrelation = run_engine(audio, sample_rate, estimate_autocorrelation, stabilize_yin=False)
    payload = {
        "format": "klarivision-vpm-fixed-grid-score-v2",
        "calibration": {"d3_y": GRID_D3_Y, "d3_hz": GRID_D3_HZ, "pixels_per_semitone": PIXELS_PER_SEMITONE, "time_offset_seconds": TIME_OFFSET_SECONDS},
        "pyin": evaluate(reference, pyin),
        "yin": evaluate(reference, yin),
        "autocorrelation": evaluate(reference, autocorrelation),
    }
    JSON_OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    write_html(payload)
    print(HTML_OUTPUT)


if __name__ == "__main__":
    main()
