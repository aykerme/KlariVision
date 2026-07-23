"""Probabilistic YIN adapter backed by librosa."""

from __future__ import annotations

from dataclasses import dataclass
import os
import tempfile

import numpy as np
import soundfile as sf

from .models import AudioSource, PitchTrack


@dataclass(frozen=True)
class PyinSettings:
    """Settings selected for the clarinet analysis baseline."""

    frame_length: int = 2_048
    hop_length: int = 110
    minimum_frequency_hz: float = 110.0
    maximum_frequency_hz: float = 2_000.0
    resolution_cents: float = 5.0
    analysis_chunk_seconds: float = 3.0


class PyinPitchExtractor:
    """Estimate pitch with probabilistic YIN and temporal Viterbi decoding."""

    def __init__(self, settings: PyinSettings | None = None) -> None:
        self.settings = settings or PyinSettings()

    def extract(self, source: AudioSource) -> PitchTrack:
        try:
            os.environ.setdefault(
                "NUMBA_CACHE_DIR", os.path.join(tempfile.gettempdir(), "klarivision-numba")
            )
            import librosa
        except ImportError as error:
            raise RuntimeError(
                "pYIN support is not installed. Install the pitch-pyin project extra."
            ) from error

        samples, sample_rate = sf.read(source.path, always_2d=False)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        if sample_rate != source.target_sample_rate:
            raise ValueError(
                f"Expected {source.target_sample_rate} Hz audio, received {sample_rate} Hz."
            )

        settings = self.settings
        samples = np.asarray(samples, dtype=np.float64)
        chunk_size = max(
            settings.frame_length * 2,
            int(settings.analysis_chunk_seconds * sample_rate),
        )
        overlap = settings.frame_length
        frequency_chunks: list[np.ndarray] = []
        voiced_chunks: list[np.ndarray] = []
        probability_chunks: list[np.ndarray] = []
        time_chunks: list[np.ndarray] = []

        for core_start in range(0, len(samples), chunk_size):
            analysis_start = max(0, core_start - overlap)
            analysis_end = min(len(samples), core_start + chunk_size)
            frequencies, voiced, probability = librosa.pyin(
                samples[analysis_start:analysis_end],
                fmin=settings.minimum_frequency_hz,
                fmax=settings.maximum_frequency_hz,
                sr=sample_rate,
                frame_length=settings.frame_length,
                hop_length=settings.hop_length,
                resolution=settings.resolution_cents / 100,
                center=False,
                fill_na=np.nan,
            )
            frame_numbers = np.arange(len(frequencies))
            times = (
                analysis_start + frame_numbers * settings.hop_length + settings.frame_length / 2
            ) / sample_rate
            keep = times >= core_start / sample_rate
            frequency_chunks.append(frequencies[keep])
            voiced_chunks.append(voiced[keep])
            probability_chunks.append(probability[keep])
            time_chunks.append(times[keep])

        frequencies = np.concatenate(frequency_chunks)
        voiced = np.concatenate(voiced_chunks)
        probability = np.concatenate(probability_chunks)
        times = np.concatenate(time_chunks)
        return PitchTrack(
            time_seconds=np.asarray(times, dtype=np.float64),
            frequency_hz=np.asarray(frequencies, dtype=np.float64),
            voiced=np.asarray(voiced, dtype=bool),
            confidence=np.asarray(probability, dtype=np.float64),
        )
