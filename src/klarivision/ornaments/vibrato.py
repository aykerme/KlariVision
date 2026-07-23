"""Rule-based vibrato candidate detector for a monophonic pitch track."""

from __future__ import annotations

import numpy as np
from scipy import signal

from klarivision.pitch.models import PitchTrack

from .models import OrnamentCandidate


def detect_vibrato(
    track: PitchTrack,
    *,
    window_seconds: float = 0.55,
    step_seconds: float = 0.18,
) -> list[OrnamentCandidate]:
    """Find sustained, regular pitch oscillations that may be vibrato.

    This deliberately returns candidates rather than asserting musical truth.
    The detector removes a linear melodic trend, then looks for at least two
    similarly spaced oscillation peaks between 3.5 and 9 Hz.
    """
    valid = track.voiced & np.isfinite(track.frequency_hz)
    times = track.time_seconds[valid]
    frequencies = track.frequency_hz[valid]
    if len(times) < 8:
        return []

    candidates: list[OrnamentCandidate] = []
    for segment_times, segment_frequencies in _continuous_segments(times, frequencies):
        candidates.extend(
            _detect_in_segment(segment_times, segment_frequencies, window_seconds, step_seconds)
        )
    return _merge_candidates(candidates)


def _continuous_segments(
    times: np.ndarray, frequencies: np.ndarray
) -> list[tuple[np.ndarray, np.ndarray]]:
    frame_step = np.median(np.diff(times))
    boundaries = np.flatnonzero(np.diff(times) > frame_step * 1.8) + 1
    indices = np.split(np.arange(len(times)), boundaries)
    return [(times[index], frequencies[index]) for index in indices if len(index) >= 8]


def _detect_in_segment(
    times: np.ndarray,
    frequencies: np.ndarray,
    window_seconds: float,
    step_seconds: float,
) -> list[OrnamentCandidate]:
    dt = float(np.median(np.diff(times)))
    window = max(12, int(round(window_seconds / dt)))
    step = max(1, int(round(step_seconds / dt)))
    if len(times) < window:
        return []

    result: list[OrnamentCandidate] = []
    cents = 1200 * np.log2(frequencies / np.median(frequencies))
    for start in range(0, len(times) - window + 1, step):
        end = start + window
        residual = signal.detrend(cents[start:end], type="linear")
        peaks, properties = signal.find_peaks(
            residual,
            prominence=5.0,
            distance=max(1, int(round(0.07 / dt))),
        )
        if len(peaks) < 3:
            continue
        periods = np.diff(peaks) * dt
        rate = 1 / float(np.median(periods))
        variation = float(np.std(periods) / np.mean(periods))
        amplitude = float(np.median(properties["prominences"]) / 2)
        if not 3.5 <= rate <= 9.0 or variation > 0.35 or not 4 <= amplitude <= 70:
            continue
        cycle_score = min(1.0, (len(peaks) - 2) / 4)
        regularity_score = max(0.0, 1 - variation / 0.35)
        amplitude_score = min(1.0, max(0.0, (amplitude - 4) / 36))
        confidence = 0.30 + 0.28 * cycle_score + 0.27 * regularity_score + 0.15 * amplitude_score
        result.append(
            OrnamentCandidate(
                kind="vibrato",
                start_seconds=float(times[start]),
                end_seconds=float(times[end - 1]),
                confidence=round(min(0.96, confidence), 3),
                rate_hz=round(rate, 2),
                amplitude_cents=round(amplitude, 1),
            )
        )
    return result


def _merge_candidates(candidates: list[OrnamentCandidate]) -> list[OrnamentCandidate]:
    if not candidates:
        return []
    merged: list[OrnamentCandidate] = [candidates[0]]
    for candidate in candidates[1:]:
        previous = merged[-1]
        if candidate.start_seconds <= previous.end_seconds + 0.12:
            merged[-1] = OrnamentCandidate(
                kind="vibrato",
                start_seconds=previous.start_seconds,
                end_seconds=max(previous.end_seconds, candidate.end_seconds),
                confidence=max(previous.confidence, candidate.confidence),
                rate_hz=candidate.rate_hz,
                amplitude_cents=candidate.amplitude_cents,
            )
        else:
            merged.append(candidate)
    return merged
