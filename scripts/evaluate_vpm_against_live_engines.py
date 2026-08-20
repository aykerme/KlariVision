#!/usr/bin/env python3
"""Score KlariVision's two live pitch engines against an extracted VPM trace."""

from __future__ import annotations

import argparse
import html
import json
import math
import wave
from pathlib import Path

import numpy as np

from calibrate_vpm_reference import TIME_OFFSET_SECONDS, VPM_TRACE, cents, frequency_from_y
from compare_live_pitch_engines import estimate_autocorrelation, estimate_yin, run_engine


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AUDIO = Path("/private/tmp/gercek-klarnet-calimi.wav")
JSON_OUTPUT = ROOT / "outputs/vpm-canli-motor-karsilastirma-v01.json"
HTML_OUTPUT = ROOT / "outputs/vpm-canli-motor-karsilastirma-v01.html"
WINDOW = 4096
HOP = 512


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as stream:
        if stream.getnchannels() != 1 or stream.getsampwidth() != 2:
            raise RuntimeError("Karşılaştırma için 16-bit mono WAV gerekir.")
        samples = np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
        return samples, stream.getframerate()


def interpolate(frames: list[dict[str, float]], time: float) -> float | None:
    if not frames or time < frames[0]["time_seconds"] or time > frames[-1]["time_seconds"]:
        return None
    times = np.array([frame["time_seconds"] for frame in frames])
    values = np.array([frame["frequency"] for frame in frames])
    return float(2 ** np.interp(time, times, np.log2(values)))


def score(vpm_points: list[dict[str, float]], frames: list[dict[str, float]]) -> tuple[dict[str, object], list[dict[str, float]]]:
    points = []
    for point in vpm_points:
        value = interpolate(frames, point["source_seconds"])
        if value is None:
            continue
        delta = cents(value, point["vpm_frequency_hz"])
        if abs(delta) < 500:
            points.append({**point, "engine_frequency_hz": round(value, 4), "difference_cents": round(delta, 2)})
    absolute = [abs(point["difference_cents"]) for point in points]
    return {
        "points": len(points),
        "median_absolute_difference_cents": round(float(np.median(absolute)), 2) if absolute else None,
        "p95_absolute_difference_cents": round(float(np.percentile(absolute, 95)), 2) if absolute else None,
    }, points


def build_html(payload: dict[str, object]) -> None:
    data = json.dumps(payload, separators=(",", ":"))
    yin = payload["yin"]
    autocorrelation = payload["autocorrelation"]
    page = f"""<!doctype html><meta charset=\"utf-8\"><title>VPM / canlı motor karşılaştırması</title>
<style>body{{font:16px -apple-system,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:32px}}main{{max-width:1120px;margin:auto}}.cards{{display:flex;gap:14px;flex-wrap:wrap}}.card{{background:white;border-radius:14px;padding:18px 20px;min-width:230px}}canvas{{width:100%;height:440px;background:#0a0b0e;border-radius:14px;margin-top:18px}}small{{color:#6e6e73}}</style>
<main><h1>VPM / canlı pitch motoru</h1><div class=cards><div class=card><b>YIN</b><br>{yin['median_absolute_difference_cents']} cent medyan<br><small>{yin['points']} ortak örnek</small></div><div class=card><b>Öz-ilinti</b><br>{autocorrelation['median_absolute_difference_cents']} cent medyan<br><small>{autocorrelation['points']} ortak örnek</small></div></div><canvas id=c width=1120 height=440></canvas><p><small>Sarı: VPM ekran eğrisi · Mor: YIN · Turuncu: Öz-ilinti. Bu rapor yalnızca aynı gerçek klarnet kaydı için motor seçimini destekler; VPM ekran kalibrasyonu ayrıca görünür durumdadır.</small></p></main>
<script>const d={data},c=document.querySelector('#c'),x=c.getContext('2d'),p=38,W=c.width,H=c.height,a=d.yin.points_data,b=d.autocorrelation.points_data,q=[...a,...b],lo=Math.min(...q.map(z=>z.source_seconds)),hi=Math.max(...q.map(z=>z.source_seconds)),fl=Math.min(...q.flatMap(z=>[z.vpm_frequency_hz,z.engine_frequency_hz])),fh=Math.max(...q.flatMap(z=>[z.vpm_frequency_hz,z.engine_frequency_hz]));const px=t=>p+(W-2*p)*(t-lo)/(hi-lo),py=f=>H-p-(H-2*p)*(Math.log2(f)-Math.log2(fl))/(Math.log2(fh)-Math.log2(fl));for(let i=0;i<6;i++){{let y=p+(H-2*p)*i/5;x.strokeStyle='#30333b';x.beginPath();x.moveTo(p,y);x.lineTo(W-p,y);x.stroke()}}function draw(rows,key,color){{x.strokeStyle=color;x.lineWidth=1.6;x.beginPath();rows.forEach((r,i)=>i?x.lineTo(px(r.source_seconds),py(r[key])):x.moveTo(px(r.source_seconds),py(r[key])));x.stroke()}}draw(a,'vpm_frequency_hz','#f2df00');draw(a,'engine_frequency_hz','#b987ff');draw(b,'engine_frequency_hz','#ff9f43');</script>"""
    HTML_OUTPUT.write_text(page, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="VPM referansına karşı canlı motorları ölçer.")
    parser.add_argument("audio", nargs="?", type=Path, default=DEFAULT_AUDIO)
    args = parser.parse_args()
    audio, sample_rate = read_wav(args.audio)
    vpm = json.loads(VPM_TRACE.read_text(encoding="utf-8"))
    vpm_points = []
    for row in vpm["samples"]:
        y = row.get("live_y")
        if y is not None:
            vpm_points.append({
                "source_seconds": round(float(row["vpm_seconds"]) - TIME_OFFSET_SECONDS, 4),
                "vpm_frequency_hz": round(frequency_from_y(float(y)), 4),
            })
    yin_frames = run_engine(audio, sample_rate, estimate_yin, stabilize_yin=True)
    auto_frames = run_engine(audio, sample_rate, estimate_autocorrelation, stabilize_yin=False)
    yin_summary, yin_points = score(vpm_points, yin_frames)
    auto_summary, auto_points = score(vpm_points, auto_frames)
    payload = {
        "format": "klarivision-vpm-live-engine-score-v1",
        "audio": str(args.audio),
        "time_offset_seconds": TIME_OFFSET_SECONDS,
        "yin": {**yin_summary, "points_data": yin_points},
        "autocorrelation": {**auto_summary, "points_data": auto_points},
    }
    JSON_OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    build_html(payload)
    print(HTML_OUTPUT)


if __name__ == "__main__":
    main()
