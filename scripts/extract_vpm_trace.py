#!/usr/bin/env python3
"""Extract Vocal Pitch Monitor's yellow trace from a screen recording.

This deliberately does not infer a musical frequency from VPM pixels yet.
VPM's vertical grid can be zoomed or panned, so the first trustworthy shared
quantity is the trace itself: video time, the yellow line's screen position,
and how much of it was confidently visible.  A later calibration pass maps
those positions to Hz using labelled VPM grid lines.

The output is a local, reviewable reference.  It lets the pitch-engine test
pipeline compare timing, continuity, attacks and vibrato shape without asking
the musician to mark every frame manually.
"""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VIDEO = Path.home() / "Downloads/ScreenRecording_07-29-2026 17-56-41_1.MP4"
OUTPUT_JSON = ROOT / "outputs/vpm-gercek-klarnet-trace-v01.json"
OUTPUT_HTML = ROOT / "outputs/vpm-gercek-klarnet-trace-v01.html"


def yellow_mask(frame: np.ndarray) -> np.ndarray:
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    # VPM's trace is saturated yellow; the orange status dot is filtered out
    # later because it sits above the graph area.
    return cv2.inRange(hsv, np.array([20, 120, 130]), np.array([45, 255, 255]))


def trace_at_probe(mask: np.ndarray, x_center: int, half_width: int, top: int, bottom: int) -> tuple[float | None, int]:
    strip = mask[top:bottom, max(0, x_center - half_width):x_center + half_width + 1]
    ys, _ = np.where(strip > 0)
    if len(ys) == 0:
        return None, 0
    # Median avoids giving a thick anti-aliased line disproportionate weight.
    return float(np.median(ys + top)), int(len(ys))


def horizontal_profile(mask: np.ndarray, left: int, right: int, top: int, bottom: int) -> np.ndarray:
    """One yellow-line y value per x position, used to detect scrolling."""
    profile = np.full(right - left, np.nan)
    crop = mask[top:bottom, left:right]
    for index in range(crop.shape[1]):
        ys = np.flatnonzero(crop[:, index])
        if len(ys):
            profile[index] = float(np.median(ys + top))
    return profile


def profile_shift(previous: np.ndarray, current: np.ndarray) -> int | None:
    """Return the horizontal movement of the same trace between two frames."""
    candidates: list[tuple[float, int]] = []
    for shift in range(-24, 25):
        if shift < 0:
            left, right = -shift, len(current)
            before, after = previous[:right + shift], current[left:right]
        elif shift > 0:
            left, right = 0, len(current) - shift
            before, after = previous[shift:], current[left:right]
        else:
            before, after = previous, current
        valid = np.isfinite(before) & np.isfinite(after)
        if valid.sum() < 80:
            continue
        candidates.append((float(np.median(np.abs(before[valid] - after[valid]))), shift))
    return min(candidates)[1] if candidates else None


def extract(video_path: Path, sample_hz: float) -> dict[str, object]:
    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise RuntimeError(f"VPM videosu açılamadı: {video_path}")

    fps = float(capture.get(cv2.CAP_PROP_FPS))
    frame_count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = frame_count / fps if fps else 0.0
    step = max(1, round(fps / sample_hz))

    # The trace lives below VPM's tuner ruler and above its transport buttons.
    top, bottom = round(height * 0.16), round(height * 0.91)
    left, right = round(width * 0.07), round(width * 0.99)
    # VPM inserts fresh samples at the left boundary.  Keep the live probe
    # close to that boundary; a farther probe represents older history.
    probes = {"sol": 0.09, "orta": 0.50, "sag": 0.93}
    rows: list[dict[str, object]] = []
    shifts: list[int] = []
    previous_profile: np.ndarray | None = None

    frame_index = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        if frame_index % step:
            frame_index += 1
            continue
        mask = yellow_mask(frame)
        profile = horizontal_profile(mask, left, right, top, bottom)
        if previous_profile is not None:
            shift = profile_shift(previous_profile, profile)
            if shift is not None:
                shifts.append(shift)
        previous_profile = profile
        sample: dict[str, object] = {"vpm_seconds": round(frame_index / fps, 4)}
        visible = 0
        for name, fraction in probes.items():
            y, pixels = trace_at_probe(mask, round(width * fraction), max(3, round(width * 0.012)), top, bottom)
            sample[f"{name}_y"] = round(y, 2) if y is not None else None
            sample[f"{name}_pixels"] = pixels
            visible += pixels
        sample["visible_pixels"] = visible
        rows.append(sample)
        frame_index += 1

    capture.release()
    median_shift = float(np.median(shifts)) if shifts else 0.0
    # A trace moving right means new analysis points enter from the left;
    # moving left means they enter from the right.
    live_edge = "sol" if median_shift > 0 else "sag"
    for row in rows:
        row["live_y"] = row[f"{live_edge}_y"]
        row["live_pixels"] = row[f"{live_edge}_pixels"]
    return {
        "format": "klarivision-vpm-screen-trace-v1",
        "video": str(video_path),
        "fps": fps,
        "duration_seconds": round(duration, 4),
        "frame_size": {"width": width, "height": height},
        "graph_crop": {"top": top, "bottom": bottom},
        "scroll": {"median_shift_pixels_per_sample": median_shift, "live_edge": live_edge},
        "sample_hz": sample_hz,
        "note": "y büyüdükçe çizgi ekranda aşağıdadır; henüz Hz kalibrasyonu uygulanmamıştır.",
        "samples": rows,
    }


def build_html(payload: dict[str, object], destination: Path) -> None:
    samples = payload["samples"]
    assert isinstance(samples, list)
    title = "VPM ekran eğrisi · v0.1"
    data = json.dumps(payload, separators=(",", ":"))
    page = f"""<!doctype html><meta charset=\"utf-8\"><title>{title}</title>
<style>body{{font:16px -apple-system,sans-serif;margin:32px;background:#f5f5f7;color:#1d1d1f}}main{{max-width:1120px;margin:auto}}canvas{{width:100%;height:430px;background:#090a0c;border-radius:14px}}.card{{padding:18px 20px;background:white;border-radius:14px;margin:16px 0}}small{{color:#6e6e73}}</style>
<main><h1>{title}</h1><p>Vocal Pitch Monitor ekran videosundaki sarı çizgi otomatik çıkarıldı. Bu ilk referans <b>zaman + ekran konumu</b> saklar; Hz kalibrasyonu sonraki adımdur.</p>
<div class=card><b>Kaynak:</b> {html.escape(str(payload['video']))}<br><small>{len(samples)} örnek · {payload['duration_seconds']} sn · {payload['sample_hz']} örnek/sn</small></div><canvas id=c width=1120 height=430></canvas><p><small>Sarı: VPM'nin sağ (anlık) ucu · Mavi: orta geçmiş · Gri: sol geçmiş. Boşluklar, VPM'nin o konumda görünür bir eğri vermediği anlardır.</small></p></main>
<script>const d={data},c=document.querySelector('#c'),x=c.getContext('2d'),W=c.width,H=c.height,p=38,rows=d.samples,maxY=d.graph_crop.bottom,minY=d.graph_crop.top;function draw(key,color){{x.beginPath();let active=false;for(const r of rows){{let y=r[key],px=p+(W-2*p)*r.vpm_seconds/d.duration_seconds;if(y===null){{active=false;continue}}let py=p+(H-2*p)*(y-minY)/(maxY-minY);if(!active){{x.moveTo(px,py);active=true}}else x.lineTo(px,py)}}x.strokeStyle=color;x.lineWidth=2;x.stroke()}}x.strokeStyle='#363942';x.lineWidth=1;for(let i=0;i<=8;i++){{let y=p+(H-2*p)*i/8;x.beginPath();x.moveTo(p,y);x.lineTo(W-p,y);x.stroke()}}draw('sol_y','#737782');draw('orta_y','#55b5e6');draw('sag_y','#f3df00');x.fillStyle='#d1d1d6';x.font='13px -apple-system';x.fillText('VPM zamanı (sn)',W/2-42,H-10);</script>"""
    destination.write_text(page, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="VPM ekran videosundan sarı pitch çizgisini çıkarır.")
    parser.add_argument("video", nargs="?", type=Path, default=DEFAULT_VIDEO)
    parser.add_argument("--sample-hz", type=float, default=10.0)
    parser.add_argument("--json", type=Path, default=OUTPUT_JSON)
    parser.add_argument("--html", type=Path, default=OUTPUT_HTML)
    args = parser.parse_args()
    payload = extract(args.video.expanduser(), args.sample_hz)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    build_html(payload, args.html)
    print(args.html)


if __name__ == "__main__":
    main()
