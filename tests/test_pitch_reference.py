from openpyxl import Workbook

from klarivision.pitch_reference import extend_reference_octaves, load_turkish_pitch_reference


def write_reference_workbook(path) -> None:
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Türk Müziği Perdeleri"
    sheet.append(["Başlık"])
    sheet.append([])
    sheet.append([])
    sheet.append(
        [
            "Frekans (Hz)",
            "Türk Nota İsmi",
            "TM Notası (Sol Klarnet)",
            "Batı Notası(Piyano)",
            "Koma Açıklaması",
        ]
    )
    sheet.append([220.0, "Yegâh", "Re", "La", "Re 𝄳 (1 Koma / Koma Bemol)"])
    sheet.append([440.0, "Neva", "Re", "La", "Re (üst oktav)"])
    workbook.save(path)
    workbook.close()


def test_loads_editable_turkish_pitch_reference(tmp_path) -> None:
    workbook_path = tmp_path / "perde-esleme.xlsx"
    write_reference_workbook(workbook_path)

    records = load_turkish_pitch_reference(workbook_path)

    assert [(record.turkish_name, record.sol_clarinet_note, record.frequency_hz) for record in records] == [
        ("Yegâh", "Re", 220.0),
        ("Neva", "Re", 440.0),
    ]
    assert records[0].piano_note == "La"
    assert records[0].display_notation == "Re ♭1"

    extended = extend_reference_octaves(records)
    assert extended[0].frequency_hz == 110.0
    assert extended[-1].frequency_hz == 880.0
