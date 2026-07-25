from pathlib import Path

from openpyxl import Workbook

from klarivision.reference_report import build_pitch_reference_report


def test_reference_report_shows_source_numbers_without_mutating_them(tmp_path: Path) -> None:
    workbook_path = tmp_path / "perde-esleme.xlsx"
    workbook = Workbook()
    settings = workbook.active
    settings.title = "Ayarlar"
    settings.append(["Başlık"])
    settings.append([])
    settings.append(["Sol klarnet dönüşümü (koma)", -22])
    mapping = workbook.create_sheet("Perde Eşleme")
    mapping.append(["Başlık"])
    mapping.append(["Koma", "Türk müziği perdesi", "Parantez içi nota", "Etiket / oktav notu", "Sent (Dügâh=0)", "Duyulan Hz", "Sol klarnet yazılı Hz", "Onay", "Düzeltme notu", "Kaynak / gerekçe"])
    mapping.append([40, "Dügâh", "La", None, 0, 440.0, 329.9869987, "Kontrol bekliyor", None, None])
    workbook.save(workbook_path)
    workbook.close()

    output_path = tmp_path / "report.html"
    build_pitch_reference_report(workbook_path, output_path)

    report = output_path.read_text(encoding="utf-8")
    assert "440.00 Hz" in report
    assert "329.99 Hz" in report
    assert "Mi4" in report
    assert "hiçbir eşlemeyi değiştirmez" in report
