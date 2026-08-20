#!/usr/bin/env python3
"""Summarize direct-source live YIN ↔ offline pYIN validation history.

The macOS app writes one tiny JSON file per source test to
``outputs/validation-reports``.  Those files contain derived pitch metrics
only—not microphone samples or source audio.  This script turns the history
into a readable HTML/JSON regression report.
"""

from __future__ import annotations

import argparse
import html
import json
from datetime import datetime
from pathlib import Path
from statistics import median


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "outputs" / "validation-reports"
DEFAULT_OUTPUT = ROOT / "outputs" / "live-pitch-regression-report.html"


def number(value: object) -> float:
    return float(value) if isinstance(value, (int, float)) else float("nan")


def display(value: float, suffix: str = "") -> str:
    return "—" if value != value else f"{value:.1f}{suffix}"


def parse_reports(folder: Path) -> list[dict[str, object]]:
    reports: list[dict[str, object]] = []
    for path in sorted(folder.glob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if payload.get("schema") != "klarivision-direct-source-validation-v1":
            continue
        # A source can finish pYIN preparation before its direct YIN replay.
        # Older app builds wrote a small interim report at that moment. It is
        # useful on screen, but not a completed regression run.
        if number(payload.get("matched_points")) < 500:
            continue
        payload["_file"] = path.name
        reports.append(payload)
    return sorted(reports, key=lambda report: str(report.get("created_at", "")), reverse=True)


def render(reports: list[dict[str, object]]) -> str:
    p95s = [number(report.get("p95_absolute_cent_error")) for report in reports]
    medians = [number(report.get("median_absolute_cent_error")) for report in reports]
    p95s = [value for value in p95s if value == value]
    medians = [value for value in medians if value == value]
    persistent = sum(len(report.get("persistent_divergences", [])) for report in reports)

    rows: list[str] = []
    for report in reports:
        ranges = report.get("persistent_divergences", [])
        interval_text = "Yok"
        if isinstance(ranges, list) and ranges:
            interval_text = "<br>".join(
                f"{number(item.get('start_seconds')):.2f}–{number(item.get('end_seconds')):.2f} sn · {number(item.get('peak_cents')):.0f} cent"
                for item in ranges[:3]
                if isinstance(item, dict)
            )
        rows.append(
            "<tr>"
            f"<td>{html.escape(str(report.get('created_at', '—')))}</td>"
            f"<td>{html.escape(str(report.get('source_name', '—')))}</td>"
            f"<td>{int(number(report.get('matched_points'))):d}</td>"
            f"<td>{display(number(report.get('median_absolute_cent_error')), ' cent')}</td>"
            f"<td>{display(number(report.get('p95_absolute_cent_error')), ' cent')}</td>"
            f"<td>{interval_text}</td>"
            f"<td>{html.escape(str(report.get('_file', '—')))}</td>"
            "</tr>"
        )

    summary = (
        f"{len(reports)} kaynak testi · ortanca hata medyanı: {display(median(medians) if medians else float('nan'), ' cent')}"
        f" · p95 medyanı: {display(median(p95s) if p95s else float('nan'), ' cent')}"
        f" · kalıcı sapma aralığı: {persistent}"
    )
    return f"""<!doctype html>
<html lang=\"tr\"><head><meta charset=\"utf-8\"><title>KlariVision · Canlı Pitch Regresyonu</title>
<style>
body {{ font: 14px -apple-system, BlinkMacSystemFont, sans-serif; max-width: 1260px; margin: 36px auto; color: #172033; }}
h1 {{ margin-bottom: 6px; }} .summary {{ color: #53627b; margin-bottom: 24px; }}
table {{ border-collapse: collapse; width: 100%; box-shadow: 0 1px 4px #dce2ee; }}
th {{ background: #eef4ff; text-align: left; }} th, td {{ padding: 10px; border: 1px solid #dce2ee; vertical-align: top; }}
td:nth-child(4), td:nth-child(5) {{ font-variant-numeric: tabular-nums; white-space: nowrap; }}
.note {{ color: #667085; margin-top: 18px; line-height: 1.5; }}
</style></head><body>
<h1>KlariVision · Canlı Pitch Regresyon Raporu</h1>
<p class=\"summary\">{summary}</p>
<table><thead><tr><th>Tarih</th><th>Kaynak</th><th>Eşleşme</th><th>Ortanca</th><th>P95</th><th>Kalıcı sapma</th><th>Rapor</th></tr></thead>
<tbody>{''.join(rows) or '<tr><td colspan="7">Henüz doğrulama raporu yok.</td></tr>'}</tbody></table>
<p class=\"note\">Bu rapor, aynı kaynak dosyasında gerçek zamanlı YIN ile çevrimdışı pYIN eğrisini karşılaştırır.\nSes kaydı içermez. Sayılar görsel incelemenin yerine geçmez; kalıcı sapma aralıkları hangi bölümlerin dinlenip inceleneceğini işaret eder.</p>
</body></html>"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    reports = parse_reports(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(reports), encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
