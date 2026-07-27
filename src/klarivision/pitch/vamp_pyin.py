"""Fast native pYIN extraction through Sonic Annotator and a Vamp plugin."""

from __future__ import annotations

import csv
import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from ..runtime_paths import resource_root
from .models import AudioSource, PitchTrack


PROJECT_ROOT = resource_root()
DEFAULT_BINARY = PROJECT_ROOT / "tools" / "sonic-annotator" / "sonic-annotator"
DEFAULT_TRANSFORM = PROJECT_ROOT / "data" / "reference" / "vamp-pyin-smoothedpitch.ttl"


class VampPyinPitchExtractor:
    """Run the native Vamp implementation of pYIN.

    Sonic Annotator is intentionally kept outside the Python environment.  It
    makes long recordings inexpensive to process while Python remains the
    application and visualisation layer.
    """

    def __init__(
        self,
        binary_path: Path | None = None,
        transform_path: Path = DEFAULT_TRANSFORM,
    ) -> None:
        configured = os.environ.get("KLARIVISION_SONIC_ANNOTATOR")
        self.binary_path = binary_path or (Path(configured) if configured else DEFAULT_BINARY)
        self.transform_path = transform_path

    def available(self) -> bool:
        return self.binary_path.is_file() and os.access(self.binary_path, os.X_OK)

    def extract(self, source: AudioSource) -> PitchTrack:
        if not self.available():
            raise RuntimeError(
                "Hızlı Vamp pYIN motoru kurulu değil. "
                "tools/sonic-annotator/sonic-annotator dosyasını kontrol et."
            )
        if not self.transform_path.is_file():
            raise RuntimeError("Vamp pYIN dönüşüm ayarı bulunamadı.")

        with tempfile.TemporaryDirectory(prefix="klarivision-vamp-") as directory:
            output = Path(directory) / "pitch.csv"
            subprocess.run(
                [
                    str(self.binary_path),
                    "-q",
                    "-t",
                    str(self.transform_path),
                    "-w",
                    "csv",
                    "--csv-one-file",
                    str(output),
                    "--csv-omit-filename",
                    "--csv-digits",
                    "8",
                    "--csv-force",
                    str(source.path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            return self.from_csv(output)

    @staticmethod
    def from_csv(path: Path) -> PitchTrack:
        """Parse timestamp/frequency rows produced by Sonic Annotator CSV."""
        times: list[float] = []
        frequencies: list[float] = []
        with path.open(newline="", encoding="utf-8") as handle:
            for row in csv.reader(handle):
                if len(row) < 2:
                    continue
                try:
                    time, frequency = float(row[0]), float(row[1])
                except ValueError:
                    continue
                if time >= 0 and frequency > 0:
                    times.append(time)
                    frequencies.append(frequency)
        if not times:
            raise RuntimeError("Vamp pYIN bu kayıtta sesli perde bulamadı.")
        size = len(times)
        return PitchTrack(
            time_seconds=np.asarray(times, dtype=np.float64),
            frequency_hz=np.asarray(frequencies, dtype=np.float64),
            voiced=np.ones(size, dtype=bool),
            confidence=np.full(size, 0.95, dtype=np.float64),
        )
