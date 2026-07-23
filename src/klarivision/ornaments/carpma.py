"""Rule-based çarpma candidate detector for a monophonic pitch track."""

from __future__ import annotations

import numpy as np
from scipy import signal

from klarivision.pitch.models import PitchTrack

from .models import OrnamentCandidate


def detect_carpma(track: PitchTrack) -> list[OrnamentCandidate]:
    """Return short return-to-pitch excursions that deserve human review.

    The result is an aid for annotation, not an automatic musical verdict.
    """
    valid = track.voiced & np.isfinite(track.frequency_hz)
    times, frequencies = track.time_seconds[valid], track.frequency_hz[valid]
    if len(times) < 9:
        return []
    candidates: list[OrnamentCandidate] = []
    for segment_times, segment_frequencies in _continuous_segments(times, frequencies):
        candidates.extend(_detect_in_segment(segment_times, segment_frequencies))
    return _merge_overlaps(candidates)


def _continuous_segments(times: np.ndarray, frequencies: np.ndarray) -> list[tuple[np.ndarray, np.ndarray]]:
    frame_step = float(np.median(np.diff(times)))
    boundaries = np.flatnonzero(np.diff(times) > frame_step * 1.8) + 1
    indices = np.split(np.arange(len(times)), boundaries)
    return [(times[index], frequencies[index]) for index in indices if len(index) >= 9]


def _detect_in_segment(times: np.ndarray, frequencies: np.ndarray) -> list[OrnamentCandidate]:
    dt = float(np.median(np.diff(times)))
    smooth = signal.medfilt(1200 * np.log2(frequencies / 440.0), kernel_size=5)
    distance = max(2, int(round(0.045 / dt)))
    extrema = np.concatenate((
        signal.find_peaks(smooth, prominence=24.0, distance=distance)[0],
        signal.find_peaks(-smooth, prominence=24.0, distance=distance)[0],
    ))
    look = max(2, int(round(0.14 / dt)))
    candidates: list[OrnamentCandidate] = []
    for center in sorted(set(int(index) for index in extrema)):
        left, right = max(0, center - look), min(len(times) - 1, center + look)
        if center - left < 2 or right - center < 2:
            continue
        before = float(np.median(smooth[left:center]))
        after = float(np.median(smooth[center + 1 : right + 1]))
        amplitude, return_error = abs(float(smooth[center]) - (before + after) / 2), abs(before - after)
        duration = float(times[right] - times[left])
        if not 24.0 <= amplitude <= 240.0 or duration > 0.34 or return_error > min(34.0, amplitude * 0.75):
            continue
        confidence = 0.25 + 0.35 * min(1.0, (amplitude - 24.0) / 80.0) + 0.25 * max(0.0, 1.0 - return_error / 34.0) + 0.15 * max(0.0, 1.0 - abs(duration - 0.18) / 0.18)
        candidates.append(OrnamentCandidate(
            kind="carpma", start_seconds=float(times[left]), end_seconds=float(times[right]),
            confidence=round(min(0.92, confidence), 3), amplitude_cents=round(amplitude, 1),
        ))
    return candidates


def _merge_overlaps(candidates: list[OrnamentCandidate]) -> list[OrnamentCandidate]:
    if not candidates:
        return []
    candidates.sort(key=lambda candidate: candidate.start_seconds)
    merged = [candidates[0]]
    for candidate in candidates[1:]:
        previous = merged[-1]
        if candidate.start_seconds <= previous.end_seconds:
            if candidate.confidence > previous.confidence:
                merged[-1] = candidate
        else:
            merged.append(candidate)
    return merged
