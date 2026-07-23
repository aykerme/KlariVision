"""A small, inspectable YIN pitch extractor for monophonic recordings."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import soundfile as sf

from .models import AudioSource, PitchTrack


@dataclass(frozen=True)
class YinSettings:
    """Analysis settings tuned for the practical clarinet range."""

    frame_length: int = 2_048
    hop_length: int = 220
    minimum_frequency_hz: float = 110.0
    maximum_frequency_hz: float = 2_000.0
    threshold: float = 0.15
    minimum_rms: float = 0.004


class YinPitchExtractor:
    """Extract a dominant monophonic contour using the YIN difference function."""

    def __init__(self, settings: YinSettings | None = None) -> None:
        self.settings = settings or YinSettings()

    def extract(self, source: AudioSource) -> PitchTrack:
        samples, sample_rate = sf.read(source.path, always_2d=False)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        samples = np.asarray(samples, dtype=np.float64)
        if sample_rate != source.target_sample_rate:
            raise ValueError(
                f"Expected {source.target_sample_rate} Hz audio, received {sample_rate} Hz. "
                "Normalize audio before pitch extraction."
            )

        settings = self.settings
        if len(samples) < settings.frame_length:
            raise ValueError("Audio is shorter than one analysis frame.")

        starts = np.arange(0, len(samples) - settings.frame_length + 1, settings.hop_length)
        frequencies = np.full(len(starts), np.nan, dtype=np.float64)
        voiced = np.zeros(len(starts), dtype=bool)
        confidence = np.zeros(len(starts), dtype=np.float64)

        for index, start in enumerate(starts):
            frame = samples[start : start + settings.frame_length]
            frequency, certainty = self._estimate_frame(frame, sample_rate)
            confidence[index] = certainty
            if frequency is not None:
                frequencies[index] = frequency
                voiced[index] = True

        time_seconds = (starts + settings.frame_length / 2) / sample_rate
        return PitchTrack(time_seconds, frequencies, voiced, confidence)

    def _estimate_frame(
        self, frame: np.ndarray, sample_rate: int
    ) -> tuple[float | None, float]:
        settings = self.settings
        rms = float(np.sqrt(np.mean(np.square(frame))))
        if rms < settings.minimum_rms:
            return None, 0.0

        frame = frame - np.mean(frame)
        minimum_lag = max(2, int(sample_rate / settings.maximum_frequency_hz))
        maximum_lag = min(
            int(sample_rate / settings.minimum_frequency_hz), len(frame) // 2
        )
        lags = np.arange(1, maximum_lag + 1)
        difference = np.array(
            [np.sum((frame[:-lag] - frame[lag:]) ** 2) for lag in lags],
            dtype=np.float64,
        )
        cumulative_mean = difference * lags / np.maximum(np.cumsum(difference), 1e-12)
        candidate_values = cumulative_mean[minimum_lag - 1 :]
        below_threshold = np.flatnonzero(candidate_values < settings.threshold)

        if len(below_threshold):
            candidate_index = int(below_threshold[0] + minimum_lag - 1)
            while (
                candidate_index < len(cumulative_mean) - 1
                and cumulative_mean[candidate_index + 1]
                <= cumulative_mean[candidate_index]
            ):
                candidate_index += 1
        else:
            candidate_index = int(np.argmin(candidate_values) + minimum_lag - 1)

        if candidate_index > 0 and candidate_index < len(cumulative_mean) - 1:
            left = cumulative_mean[candidate_index - 1]
            middle = cumulative_mean[candidate_index]
            right = cumulative_mean[candidate_index + 1]
            denominator = left - 2 * middle + right
            adjustment = 0.0 if abs(denominator) < 1e-12 else 0.5 * (left - right) / denominator
        else:
            adjustment = 0.0

        lag = candidate_index + 1 + adjustment
        certainty = float(np.clip(1 - cumulative_mean[candidate_index], 0, 1))
        if certainty < 1 - settings.threshold:
            return None, certainty
        return sample_rate / lag, certainty
