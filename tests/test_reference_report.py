from pathlib import Path

from openpyxl import Workbook

from klarivision.reference_report import build_pitch_reference_report


def test_reference_report_shows_source_numbers_without_mutating_them(tmp_path: Path) -> None:
    workbook_path = tmp_path / "perde-esleme.xlsx"
    workbook = Workbook()
    mapping = workbook.active
    mapping.title = "Türk Müziği Perdeleri"
    mapping.append(["Başlık"])
    mapping.append([])
    mapping.append([])
    mapping.append(["Frekans (Hz)", "Türk Nota İsmi", "TM Notası (Sol Klarnet)", "Batı Notası(Piyano)", "Koma Açıklaması"])
    mapping.append([220.0, "Yegâh", "Re", "La", "Re 𝄳 (1 Koma / Koma Bemol)"])
    mapping.append([440.0, "Neva", "Re", "La", "Re"])
    workbook.save(workbook_path)
    workbook.close()

    output_path = tmp_path / "report.html"
    build_pitch_reference_report(workbook_path, output_path)

    report = output_path.read_text(encoding="utf-8")
    assert "110.00" in report
    assert "880.00" in report
    assert "𝄳" in report
    assert "×½ ve ×2" in report
