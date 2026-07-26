"""Human-readable quality-control report for Turkish microtonal notation."""

from __future__ import annotations

import html
from pathlib import Path

from klarivision.pitch_reference import extend_reference_octaves, load_turkish_pitch_reference


def build_pitch_reference_report(workbook_path: Path, output_path: Path) -> None:
    """Render source rows plus generated lower and upper octaves as HTML."""
    source_records = load_turkish_pitch_reference(workbook_path)
    records = extend_reference_octaves(source_records)

    def esc(value: object) -> str:
        return html.escape("" if value is None else str(value))

    table_rows = "".join(
        f"""<tr><td>{record.frequency_hz:.2f}</td><td>{esc(record.turkish_name)}</td>
        <td>{esc(record.sol_clarinet_note)}</td><td>{esc(record.piano_note)}</td>
        <td>{esc(record.display_notation)}</td><td>{esc(record.koma_description)}</td>
        <td>{esc(record.octave_label)}</td></tr>"""
        for record in records
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        f"""<!doctype html><html lang=tr><meta charset=utf-8><title>KlariVision · Türk müziği perde kontrolü</title>
        <style>body{{font:15px system-ui,-apple-system,sans-serif;margin:0;background:#f5f7fa;color:#1e2936}}main{{max-width:1280px;margin:auto;padding:32px}}h1{{margin:0 0 8px}}p{{line-height:1.55}}.notice{{background:#e8f2fd;border:1px solid #a9c9ea;padding:14px 16px;border-radius:10px}}table{{width:100%;border-collapse:collapse;background:#fff;font-size:13px}}th{{text-align:left;background:#244d78;color:#fff}}th,td{{padding:8px;border-bottom:1px solid #e5e9ee;white-space:nowrap}}.scroll{{overflow:auto;border:1px solid #dce3eb;border-radius:10px}}.muted{{color:#596775;font-size:13px}}</style>
        <main><h1>KlariVision · Türk müziği perde ve mikrotonal notasyon kontrolü</h1>
        <p class=muted>Kaynak: <code>{esc(workbook_path)}</code> · Kaynak oktav + bir alt ve bir üst oktav</p>
        <p class=notice>Bu sayfa kaynak tablodaki koma miktarını taşınabilir metin biçiminde gösterir: ör. Re ♭5 ve Fa ♯1. Alt ve üst oktav frekansları kaynak satırların sırasıyla ×½ ve ×2 değerleridir; kaynak Excel dosyası değiştirilmez.</p>
        <div class=scroll><table><thead><tr><th>Frekans (Hz)</th><th>Türk nota ismi</th><th>TM notası<br>(Sol klarnet)</th><th>Batı notası<br>(Piyano)</th><th>Koma gösterimi</th><th>Koma açıklaması</th><th>Oktav</th></tr></thead><tbody>{table_rows}</tbody></table></div></main></html>""",
        encoding="utf-8",
    )
