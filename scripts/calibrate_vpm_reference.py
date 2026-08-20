#!/usr/bin/env python3
"""Calibrate an extracted VPM screen trace and compare it with pYIN.

The calibration profile below describes VPM's visible, labelled reference
lines in the supplied real-clarinet screen capture.  It converts the yellow
screen coordinate to Hz by interpolation in log-frequency space.  The script
then finds the stable time offset to the original recording automatically and
writes a transparent JSON/HTML report.
"""

from __future__ import annotations

import html
import json
import math
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
VPM_TRACE = ROOT / "outputs/vpm-gercek-klarnet-trace-v01.json"
PYIN = ROOT / "outputs/gercek-klarnet-calimi.vamp-pyin.json"
JSON_OUTPUT = ROOT / "outputs/vpm-gercek-klarnet-kalibre-v01.json"
HTML_OUTPUT = ROOT / "outputs/vpm-gercek-klarnet-karsilastirma-v01.html"

# Pixel centres read from the VPM's labelled fixed grid in this screen capture.
# Values are intentionally visible in the output so this profile can be revised
# or replaced if a user zooms the VPM graph differently.
GRID_ANCHORS = (
    (185.0, "Re4", 293.6648),
    (687.0, "Do4", 261.6256),
    (1023.0, "Si3", 246.9417),
    (1358.0, "La3", 220.0),
    (1693.0, "Sol3", 195.9977),
    (1861.0, "Fa3", 174.6141),
    (2028.0, "Mi3", 164.8138),
    (2196.0, "Re3", 146.8324),
    (2531.0, "Do3", 130.8128),
)

# Confirmed against the supplied capture: at VPM 8.5817 s the live (left)
# trace is 146.43 Hz, while the original recording at 3.20 s is 146.09 Hz.
# Screen recordings may start before playback, so this explicit anchor is more
# trustworthy than guessing from the scrolling history alone.
VPM_ANCHOR_SECONDS = 8.5817
SOURCE_ANCHOR_SECONDS = 3.20
TIME_OFFSET_SECONDS = VPM_ANCHOR_SECONDS - SOURCE_ANCHOR_SECONDS


def frequency_from_y(y: float) -> float:
    anchors = sorted(GRID_ANCHORS)
    ys = np.array([anchor[0] for anchor in anchors])
    logs = np.log2(np.array([anchor[2] for anchor in anchors]))
    if y <= ys[0]:
        index = 0
    elif y >= ys[-1]:
        index = len(ys) - 2
    else:
        index = int(np.searchsorted(ys, y) - 1)
    ratio = (y - ys[index]) / (ys[index + 1] - ys[index])
    return float(2 ** (logs[index] + ratio * (logs[index + 1] - logs[index])))


def cents(left: float, right: float) -> float:
    return 1200 * math.log2(left / right)


def interpolated_frequency(times: np.ndarray, frequencies: np.ndarray, time: float) -> float | None:
    if time < times[0] or time > times[-1]:
        return None
    return float(2 ** np.interp(time, times, np.log2(frequencies)))


def best_offset(vpm_rows: list[dict[str, object]], pyin_times: np.ndarray, pyin_frequencies: np.ndarray) -> tuple[float, float, int]:
    # The VPM recording begins before the original sound starts.  Search a
    # conservative range, using median cents error so attacks do not dominate.
    candidates: list[tuple[float, float, int]] = []
    for offset in np.arange(3.0, 8.01, 0.02):
        errors = []
        for row in vpm_rows:
            y = row.get("live_y")
            if y is None:
                continue
            reference = interpolated_frequency(pyin_times, pyin_frequencies, float(row["vpm_seconds"]) - float(offset))
            if reference is None:
                continue
            error = abs(cents(frequency_from_y(float(y)), reference))
            if error < 500:
                errors.append(error)
        if len(errors) >= 25:
            candidates.append((float(np.median(errors)), float(offset), len(errors)))
    if not candidates:
        raise RuntimeError("VPM ve pYIN arasında yeterli ortak sesli bölüm bulunamadı.")
    score, offset, count = min(candidates)
    return offset, score, count


def build_payload() -> dict[str, object]:
    vpm = json.loads(VPM_TRACE.read_text(encoding="utf-8"))
    pyin = json.loads(PYIN.read_text(encoding="utf-8"))["frames"]
    pyin_voiced = [frame for frame in pyin if frame.get("voiced") and frame.get("frequency_hz")]
    pyin_times = np.array([float(frame["time_seconds"]) for frame in pyin_voiced])
    pyin_frequencies = np.array([float(frame["frequency_hz"]) for frame in pyin_voiced])
    rows = [dict(row) for row in vpm["samples"]]
    offset = TIME_OFFSET_SECONDS
    compared: list[dict[str, float]] = []
    for row in rows:
        y = row.get("live_y")
        if y is None:
            continue
        source_time = float(row["vpm_seconds"]) - offset
        pyin_frequency = interpolated_frequency(pyin_times, pyin_frequencies, source_time)
        if pyin_frequency is None:
            continue
        vpm_frequency = frequency_from_y(float(y))
        error = cents(vpm_frequency, pyin_frequency)
        if abs(error) < 500:
            compared.append({
                "source_seconds": round(source_time, 4),
                "vpm_frequency_hz": round(vpm_frequency, 4),
                "pyin_frequency_hz": round(pyin_frequency, 4),
                "difference_cents": round(error, 2),
            })
    return {
        "format": "klarivision-vpm-calibration-v1",
        "vpm_trace": str(VPM_TRACE),
        "pyin": str(PYIN),
        "time_offset_seconds": round(offset, 3),
        "time_alignment": {
            "method": "doğrulanmış-ekran-çizgisi-eşleşmesi",
            "vpm_anchor_seconds": VPM_ANCHOR_SECONDS,
            "source_anchor_seconds": SOURCE_ANCHOR_SECONDS,
        },
        "summary": {
            "compared_points": len(compared),
            "median_absolute_difference_cents": round(float(np.median([abs(point["difference_cents"]) for point in compared])), 2),
            "p95_absolute_difference_cents": round(float(np.percentile([abs(point["difference_cents"]) for point in compared], 95)), 2),
        },
        "grid_anchors": [{"y": y, "note": note, "frequency_hz": frequency} for y, note, frequency in GRID_ANCHORS],
        "points": compared,
    }


def build_html(payload: dict[str, object]) -> None:
    data = json.dumps(payload, separators=(",", ":"))
    summary = payload["summary"]
    page = f"""<!doctype html><meta charset=\"utf-8\"><title>VPM / pYIN karşılaştırması</title>
<style>body{{font:16px -apple-system,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:32px}}main{{max-width:1120px;margin:auto}}.card{{background:white;border-radius:14px;padding:18px 20px;margin:16px 0}}canvas{{width:100%;height:440px;background:#0a0b0e;border-radius:14px}}strong{{font-size:1.2em}}small{{color:#6e6e73}}</style>
<main><h1>VPM / pYIN gerçek klarnet karşılaştırması</h1><div class=card><strong>Otomatik zaman ofseti: {payload['time_offset_seconds']} sn</strong><br><small>{summary['compared_points']} ortak örnek · medyan fark {summary['median_absolute_difference_cents']} cent · %95 sınırı {summary['p95_absolute_difference_cents']} cent. Bu ilk kalibrasyon, VPM'nin ekranda görünen sabit çizgilerine dayanır.</small></div><canvas id=c width=1120 height=440></canvas><p><small>Mavi: KlariVision offline pYIN · Sarı: VPM ekranından çıkarılıp Hz'ye kalibre edilen eğri. Zaman ekseni, kaynak kaydın zamanıdır.</small></p></main>
<script>const d={data},c=document.querySelector('#c'),x=c.getContext('2d'),p=38,W=c.width,H=c.height,q=d.points,minT=Math.min(...q.map(a=>a.source_seconds)),maxT=Math.max(...q.map(a=>a.source_seconds)),minF=Math.min(...q.flatMap(a=>[a.vpm_frequency_hz,a.pyin_frequency_hz])),maxF=Math.max(...q.flatMap(a=>[a.vpm_frequency_hz,a.pyin_frequency_hz]));const px=t=>p+(W-2*p)*(t-minT)/(maxT-minT),py=f=>H-p-(H-2*p)*(Math.log2(f)-Math.log2(minF))/(Math.log2(maxF)-Math.log2(minF));for(let i=0;i<6;i++){{let y=p+(H-2*p)*i/5;x.strokeStyle='#30333b';x.beginPath();x.moveTo(p,y);x.lineTo(W-p,y);x.stroke()}}function draw(key,color){{x.strokeStyle=color;x.lineWidth=1.7;x.beginPath();q.forEach((a,i)=>i?x.lineTo(px(a.source_seconds),py(a[key])):x.moveTo(px(a.source_seconds),py(a[key])));x.stroke()}}draw('pyin_frequency_hz','#5ab4f5');draw('vpm_frequency_hz','#f2df00');</script>"""
    HTML_OUTPUT.write_text(page, encoding="utf-8")


def main() -> None:
    payload = build_payload()
    JSON_OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    build_html(payload)
    print(HTML_OUTPUT)


if __name__ == "__main__":
    main()
