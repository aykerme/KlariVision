from openpyxl import Workbook

from klarivision.pitch_reference import load_turkish_pitch_reference


def write_reference_workbook(path) -> None:
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Perde Eşleme"
    sheet.append(["KlariVision referansı"])
    sheet.append(
        [
            "Koma",
            "Türk müziği perdesi",
            "Parantez içi nota",
            "Etiket / oktav notu",
            "Sent (Dügâh=0)",
            "Duyulan Hz",
            "Sol klarnet yazılı Hz",
        ]
    )
    sheet.append([9, "Yegâh", "Re", "", 0, 293.344891, 220.0])
    sheet.append([40, "Dügâh", "La", "", 0, 440.0, 329.986999])
    workbook.save(path)
    workbook.close()


def test_loads_editable_turkish_pitch_reference(tmp_path) -> None:
    workbook_path = tmp_path / "perde-esleme.xlsx"
    write_reference_workbook(workbook_path)

    records = load_turkish_pitch_reference(workbook_path)

    assert [(record.name, record.solfege, record.heard_hz) for record in records] == [
        ("Yegâh", "Re", 293.344891),
        ("Dügâh", "La", 440.0),
    ]
    assert records[0].clarinet_written_hz == 220.0
