#!/usr/bin/env python3
"""Compare causal live YIN variants against KlariVision's offline pYIN tracks.

The script deliberately uses only a current analysis window plus the prior
accepted pitch.  That is the latency budget a microphone monitor can afford;
offline pYIN is allowed to inspect future frames through Viterbi decoding.
"""

from __future__ import annotations

import json
import math
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numba import njit


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MINIMUM_RMS = 0.015


def centered_rms(samples: np.ndarray) -> float:
    """Shared signal gate: RMS after removing the frame's DC component."""
    if len(samples) == 0:
        return 0.0
    centered = samples - float(np.mean(samples))
    return math.sqrt(float(np.mean(centered * centered)))


def signal_is_eligible(samples: np.ndarray, minimum_rms: float = DEFAULT_MINIMUM_RMS) -> bool:
    return centered_rms(samples) >= minimum_rms


@dataclass(frozen=True)
class Case:
    name: str
    wav: Path
    reference: Path


CASES = [
    Case("gercek-klarnet", Path("/private/tmp/gercek-klarnet-calimi.wav"), ROOT / "outputs/gercek-klarnet-calimi.vamp-pyin.json"),
    Case("calim2", Path("/private/tmp/calim2.wav"), ROOT / "outputs/calim2.vamp-pyin.json"),
]


def cents(a: float, b: float) -> float:
    return 1200 * math.log2(a / b)


def load_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as file:
        sample_rate = file.getframerate()
        raw = np.frombuffer(file.readframes(file.getnframes()), dtype="<i2")
    return raw.astype(np.float64) / 32768.0, sample_rate


def prepare_reference(frames: list[dict[str, object]]) -> tuple[np.ndarray, np.ndarray]:
    voiced = [(float(frame["time_seconds"]), float(frame["frequency_hz"])) for frame in frames if frame.get("voiced") and frame.get("frequency_hz")]
    return np.array([entry[0] for entry in voiced]), np.array([entry[1] for entry in voiced])


def reference_at(times: np.ndarray, values: np.ndarray, time: float) -> float | None:
    index = np.searchsorted(times, time)
    if index == 0 or index >= len(times):
        return None
    if times[index] - times[index - 1] > 0.08:
        return None
    return float(2 ** np.interp(time, times[index - 1:index + 1], np.log2(values[index - 1:index + 1])))


@njit(cache=True)
def _yin_candidate_arrays(
    samples: np.ndarray, sample_rate: float, maximum_frequency: float
) -> tuple[np.ndarray, np.ndarray]:
    """Numerical inner loop, compiled once for rapid experiment iteration."""
    min_lag = max(2, int(sample_rate / maximum_frequency))
    max_lag = min(len(samples) // 2, int(sample_rate / 80))
    cumulative_energy = np.zeros(len(samples) + 1)
    for index in range(len(samples)):
        cumulative_energy[index + 1] = cumulative_energy[index] + samples[index] * samples[index]
    difference = np.ones(max_lag + 1)
    for lag in range(min_lag, max_lag + 1):
        count = len(samples) - lag
        correlation = 0.0
        for index in range(count):
            correlation += samples[index] * samples[index + lag]
        value = cumulative_energy[count] + (cumulative_energy[len(samples)] - cumulative_energy[lag]) - 2 * correlation
        difference[lag] = max(0.0, value)
    normalized = np.ones(max_lag + 1)
    cumulative = 0.0
    for lag in range(1, max_lag + 1):
        cumulative += difference[lag]
        if cumulative > 0:
            normalized[lag] = difference[lag] * lag / cumulative
    frequencies = np.empty(max_lag)
    confidences = np.empty(max_lag)
    count = 0
    for lag in range(min_lag + 1, max_lag):
        if normalized[lag] <= normalized[lag - 1] and normalized[lag] < normalized[lag + 1] and normalized[lag] < 0.50:
            denominator = normalized[lag - 1] - 2 * normalized[lag] + normalized[lag + 1]
            correction = 0.5 * (normalized[lag - 1] - normalized[lag + 1]) / denominator if abs(denominator) > 1e-9 else 0.0
            correction = min(0.5, max(-0.5, correction))
            frequencies[count] = sample_rate / (lag + correction)
            confidences[count] = 1 - normalized[lag]
            count += 1
    return frequencies[:count], confidences[:count]


def yin_candidates(
    samples: np.ndarray,
    sample_rate: float,
    maximum_frequency: float = 1500.0,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
) -> list[tuple[float, float]]:
    # Mirror LivePitchAnalyzer.yinCandidates exactly. The app deliberately
    # ignores residual room/hum energy below this level.
    if not signal_is_eligible(samples, minimum_rms):
        return []
    frequencies, confidences = _yin_candidate_arrays(
        np.ascontiguousarray(samples), sample_rate, maximum_frequency
    )
    return list(zip(frequencies.tolist(), confidences.tolist()))


def choose(candidates: list[tuple[float, float]], previous: float | None, mode: str) -> tuple[float, float] | None:
    confident = [(frequency, confidence) for frequency, confidence in candidates if confidence >= 0.76]
    if not confident:
        return None
    if mode == "raw":
        return max(confident, key=lambda item: item[1])
    if previous is None:
        return max(confident, key=lambda item: item[1])
    if mode == "swift-like":
        # Mirrors the live Swift engine's causal continuity decision.  It
        # keeps candidates down to 0.55 confidence for a smooth contour but
        # still requires 0.76 confidence for a new independent onset.
        continuity = [(frequency, confidence) for frequency, confidence in candidates if confidence >= 0.55]
        if not continuity:
            continuity = confident
        def swift_score(item: tuple[float, float]) -> float:
            distance = abs(cents(item[0], previous))
            return item[1] - 0.30 * min(distance / 700.0, 1.0)
        selected = max(continuity, key=swift_score)
        distance = abs(cents(selected[0], previous))
        if distance > 650:
            nearby = [item for item in continuity if abs(cents(item[0], previous)) < 350]
            if nearby:
                stable = max(nearby, key=lambda item: item[1])
                if stable[1] >= selected[1] - 0.12:
                    selected = stable
        return selected
    # pYIN-inspired causal selection: periodicity is the main score, but a
    # sudden octave/harmonic jump must be materially more convincing.
    def score(item: tuple[float, float]) -> float:
        frequency, confidence = item
        distance = abs(cents(frequency, previous))
        continuity = min(distance / 700.0, 1.0)
        return confidence - (0.10 if mode == "causal-light" else 0.18) * continuity
    candidate = max(confident, key=score)
    if abs(cents(candidate[0], previous)) > 650 and candidate[1] < 0.90:
        nearby = [item for item in confident if abs(cents(item[0], previous)) < 350]
        if nearby:
            return max(nearby, key=lambda item: item[1])
    return candidate


def evaluate(case: Case, mode: str, block: int, hop: int) -> tuple[float, float, int]:
    samples, sample_rate = load_wav(case.wav)
    reference_times, reference_values = prepare_reference(json.loads(case.reference.read_text())["frames"])
    previous: float | None = None
    errors: list[float] = []
    for end in range(block, len(samples), hop):
        result = choose(yin_candidates(samples[end - block:end], sample_rate), previous, mode)
        if result is None:
            continue
        frequency, _ = result
        expected = reference_at(reference_times, reference_values, (end - block / 2) / sample_rate)
        if expected is None:
            continue
        error = abs(cents(frequency, expected))
        if error < 1_000:
            errors.append(error)
            previous = frequency
    if not errors:
        return math.inf, math.inf, 0
    return float(np.median(errors)), float(np.percentile(errors, 95)), len(errors)


def main() -> None:
    # Benchmark every 46 ms. The app can still publish every 11.6 ms; this
    # keeps the evaluation fast enough for repeated algorithm experiments.
    variants = [("raw", 2048, 1024), ("causal-light", 2048, 1024), ("causal", 2048, 1024), ("swift-like", 2048, 1024), ("causal", 3072, 1024)]
    totals: list[tuple[float, str, int, int, list[tuple[str, float, float, int]]]] = []
    for mode, block, hop in variants:
        results = [(case.name, *evaluate(case, mode, block, hop)) for case in CASES if case.wav.exists() and case.reference.exists()]
        score = float(np.mean([result[1] for result in results]))
        totals.append((score, mode, block, hop, results))
    for _, mode, block, hop, results in sorted(totals):
        print(f"{mode:13s} block={block} hop={hop}")
        for name, median, p95, count in results:
            print(f"  {name:15s} median={median:6.1f} cents  p95={p95:6.1f}  n={count}")


if __name__ == "__main__":
    main()
