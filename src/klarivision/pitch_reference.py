"""Editable Turkish music pitch-reference workbook support.

The workbook is deliberately the source of truth: musicians can adjust the
reference in Numbers or Excel without changing Python code.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from openpyxl import load_workbook


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REFERENCE_PATH = PROJECT_ROOT / "data" / "reference" / "perde-esleme.xlsx"


@dataclass(frozen=True)
class TurkishPitchReference:
    """One pitch line shown in the Turkish music reference grid."""

    koma: int
    name: str
    solfege: str
    heard_hz: float
    clarinet_written_hz: float


def load_turkish_pitch_reference(
    path: Path = DEFAULT_REFERENCE_PATH,
) -> tuple[TurkishPitchReference, ...]:
    """Load usable pitch rows from the editable ``Perde Eşleme`` worksheet.

    pYIN measures sounding frequency, so the viewer uses the ``Duyulan Hz``
    column as its vertical grid.  ``Sol klarnet yazılı Hz`` is retained for
    future notation views but must not alter the measured contour.
    """
    workbook = load_workbook(path, data_only=True, read_only=True)
    try:
        sheet = workbook["Perde Eşleme"]
        headers = {
            str(value).strip(): index
            for index, value in enumerate(next(sheet.iter_rows(min_row=2, max_row=2, values_only=True)))
            if value is not None
        }
        required = {
            "Koma",
            "Türk müziği perdesi",
            "Parantez içi nota",
            "Duyulan Hz",
            "Sol klarnet yazılı Hz",
        }
        missing = required - headers.keys()
        if missing:
            missing_text = ", ".join(sorted(missing))
            raise ValueError(f"Perde Eşleme sayfasında eksik sütunlar var: {missing_text}")

        records: list[TurkishPitchReference] = []
        for row in sheet.iter_rows(min_row=3, values_only=True):
            name = row[headers["Türk müziği perdesi"]]
            heard_hz = row[headers["Duyulan Hz"]]
            if name is None or heard_hz is None:
                continue
            records.append(
                TurkishPitchReference(
                    koma=int(row[headers["Koma"]]),
                    name=str(name).strip(),
                    solfege=str(row[headers["Parantez içi nota"]] or "").strip(),
                    heard_hz=float(heard_hz),
                    clarinet_written_hz=float(row[headers["Sol klarnet yazılı Hz"]]),
                )
            )
    finally:
        workbook.close()

    if not records:
        raise ValueError("Perde Eşleme sayfasında kullanılabilir bir perde satırı bulunamadı.")
    return tuple(records)
