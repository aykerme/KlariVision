"""Arel-style reference locations used by the contour display."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Perde:
    name: str
    western_note: str
    cents_from_dugah: float


HICAZ_UŞŞAK_REFERENCE = (
    Perde("Yegâh", "Re", -701.9),
    Perde("Hüseynî Aşiran", "Mi", -498.1),
    Perde("Irak", "Fa", -317.0),
    Perde("Rast", "Sol", -203.8),
    Perde("Dügâh", "La", 0),
    Perde("Segâh", "Si", 181),
    Perde("Çârgâh", "Do", 294),
    Perde("Neva", "Re", 498),
    Perde("Hüseynî", "Mi", 700),
    Perde("Acem", "Fa", 800),
    Perde("Gerdâniye", "Sol", 1000),
    Perde("Muhayyer", "La", 1200),
)
