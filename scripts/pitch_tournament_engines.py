#!/usr/bin/env python3
"""Canonical benchmark adapters for KlariVision's three live pitch engines.

All traces use the centre of the source analysis window as their timestamp.
Decision latency is metadata: it is never removed by shifting a trace.
"""

from __future__ import annotations

import csv
import math
import os
import resource
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numba import njit

from benchmark_live_pyin_alignment import DEFAULT_MINIMUM_RMS, centered_rms, yin_candidates
from run_pitch_regression_suite import LIVE_WINDOW, HOP, causal_yin_frames


ROOT = Path(__file__).resolve().parents[1]
MIN_FREQUENCY = 80.0
MAX_FREQUENCY = 1_500.0
V2_ANALYSIS_MAX_FREQUENCY = 1_650.0
V2_LAG_FRAMES = int(os.environ.get("KLARIVISION_V2_LAG_FRAMES", "5"))
if V2_LAG_FRAMES not in {2, 3, 4, 5}:
    raise ValueError("KLARIVISION_V2_LAG_FRAMES must be one of 2, 3, 4 or 5")


@dataclass(frozen=True)
class EngineTrace:
    engine: str
    implementation: str
    frames: list[tuple[float, float, float]]
    runtime_seconds: float
    audio_seconds: float
    analysis_half_window_ms: float
    fixed_lag_ms: float

    @property
    def decision_latency_ms(self) -> float:
        return self.analysis_half_window_ms + self.fixed_lag_ms

    @property
    def realtime_factor(self) -> float:
        return self.runtime_seconds / max(self.audio_seconds, 1e-12)


def _swift_centered_float32(samples: np.ndarray) -> np.ndarray:
    """Match Swift's Double mean followed by Float32 centred samples."""
    mean = float(np.asarray(samples, dtype=np.float64).sum(dtype=np.float64) / len(samples))
    return np.asarray(np.asarray(samples, dtype=np.float64) - mean, dtype=np.float32)


def _swift_yin_candidates(
    samples: np.ndarray, sample_rate: float, maximum_frequency: float
) -> list[tuple[float, float]]:
    """Mirror ``LivePitchAnalyzer.yinCandidates``' Float/vDSP arithmetic."""
    swift_samples = np.ascontiguousarray(samples, dtype=np.float32)
    if len(swift_samples) < 1024:
        return []
    minimum_lag = max(2, int(sample_rate / maximum_frequency))
    maximum_lag = min(len(swift_samples) // 2, int(sample_rate / MIN_FREQUENCY))
    if minimum_lag + 2 >= maximum_lag:
        return []

    cumulative_energy = np.empty(len(swift_samples) + 1, dtype=np.float32)
    cumulative_energy[0] = 0
    np.cumsum(swift_samples * swift_samples, dtype=np.float32, out=cumulative_energy[1:])
    difference = np.zeros(maximum_lag + 1, dtype=np.float32)
    for lag in range(minimum_lag, maximum_lag + 1):
        count = len(swift_samples) - lag
        correlation = np.dot(swift_samples[:count], swift_samples[lag:])
        value = np.float32(
            cumulative_energy[count]
            + (cumulative_energy[-1] - cumulative_energy[lag])
            - np.float32(2) * correlation
        )
        difference[lag] = max(np.float32(0), value)

    normalized = np.ones(maximum_lag + 1, dtype=np.float32)
    cumulative = np.float32(0)
    for lag in range(1, maximum_lag + 1):
        cumulative = np.float32(cumulative + difference[lag])
        if cumulative > 0:
            normalized[lag] = np.float32(
                difference[lag] * np.float32(lag) / cumulative
            )

    candidates: list[tuple[float, float]] = []
    for lag in range(minimum_lag + 1, maximum_lag):
        previous, current, following = normalized[lag - 1:lag + 2]
        if not (current <= previous and current < following and current < np.float32(0.50)):
            continue
        denominator = np.float32(previous - np.float32(2) * current + following)
        correction = (
            np.float32(0.5) * np.float32(previous - following) / denominator
            if abs(denominator) > np.float32(0.000_001) else np.float32(0)
        )
        correction = min(np.float32(0.5), max(np.float32(-0.5), correction))
        frequency = sample_rate / (lag + float(correction))
        if math.isfinite(frequency) and MIN_FREQUENCY <= frequency <= maximum_frequency:
            confidence = float(max(np.float32(0), min(np.float32(1), np.float32(1) - current)))
            candidates.append((frequency, confidence))
    return candidates


def _mpm_candidate_arrays(samples: np.ndarray, sample_rate: float) -> tuple[np.ndarray, np.ndarray]:
    """Mirror Swift's Float32 MPM/NSDF candidate generator.

    Swift keeps the input and cumulative energy in Float32 and uses a Float32
    vDSP dot product. The previous Float64/Numba implementation changed peak
    ordering at high-register candidate boundaries.
    """
    centred = _swift_centered_float32(samples)
    minimum_lag = max(2, int(sample_rate / MAX_FREQUENCY))
    maximum_lag = min(len(samples) // 2, int(sample_rate / MIN_FREQUENCY))
    cumulative = np.empty(len(centred) + 1, dtype=np.float32)
    cumulative[0] = 0
    np.cumsum(centred * centred, dtype=np.float32, out=cumulative[1:])
    nsdf = np.zeros(maximum_lag + 1, dtype=np.float32)
    for lag in range(minimum_lag, maximum_lag + 1):
        count = len(centred) - lag
        normalisation = np.float32(cumulative[count] + cumulative[-1] - cumulative[lag])
        if normalisation > np.float32(1e-9):
            correlation = np.dot(centred[:count], centred[lag:])
            nsdf[lag] = np.float32(2) * correlation / normalisation
    candidates: list[tuple[float, float]] = []
    for lag in range(minimum_lag + 1, maximum_lag):
        previous, current, following = nsdf[lag - 1], nsdf[lag], nsdf[lag + 1]
        if current < 0.55 or current < previous or current <= following:
            continue
        denominator = previous - 2 * current + following
        correction = (
            np.float32(0.5) * (previous - following) / denominator
            if abs(denominator) > np.float32(1e-6) else np.float32(0)
        )
        correction = min(np.float32(0.5), max(np.float32(-0.5), correction))
        frequency = sample_rate / (lag + float(correction))
        if MIN_FREQUENCY <= frequency <= MAX_FREQUENCY:
            candidates.append((frequency, float(min(np.float32(1), max(np.float32(0), current)))))
    candidates.sort(key=lambda candidate: candidate[1], reverse=True)
    candidates = candidates[:12]
    return (
        np.asarray([candidate[0] for candidate in candidates], dtype=np.float64),
        np.asarray([candidate[1] for candidate in candidates], dtype=np.float64),
    )


def _autocorrelation_candidate(
    samples: np.ndarray,
    sample_rate: float,
    *,
    applies_high_register_gate: bool = True,
) -> tuple[float, float] | None:
    if len(samples) < 1024:
        return None
    centred = _swift_centered_float32(samples)
    minimum_lag = max(2, int(sample_rate / MAX_FREQUENCY))
    maximum_lag = min(len(samples) // 2, int(sample_rate / MIN_FREQUENCY))
    cumulative = np.empty(len(centred) + 1, dtype=np.float64)
    cumulative[0] = 0
    np.cumsum(np.asarray(centred, dtype=np.float64) ** 2, dtype=np.float64, out=cumulative[1:])
    correlation = np.zeros(maximum_lag + 1)
    for lag in range(minimum_lag, maximum_lag + 1):
        count = len(centred) - lag
        denominator = math.sqrt(max(1e-12, cumulative[count] * (cumulative[-1] - cumulative[lag])))
        correlation[lag] = float(np.dot(centred[:count], centred[lag:])) / denominator
    peaks = [
        lag for lag in range(minimum_lag + 1, maximum_lag)
        if correlation[lag] >= correlation[lag - 1] and correlation[lag] > correlation[lag + 1]
    ]
    if not peaks:
        return None
    strongest = max(peaks, key=correlation.__getitem__)
    if correlation[strongest] < 0.38:
        return None
    acceptance = max(0.52, correlation[strongest] * 0.84)
    selected = next((lag for lag in peaks if correlation[lag] >= acceptance), strongest)
    left, middle, right = correlation[selected - 1:selected + 2]
    denominator = left - 2 * middle + right
    correction = 0.5 * (left - right) / denominator if abs(denominator) > 1e-6 else 0.0
    frequency = sample_rate / (selected + min(0.5, max(-0.5, correction)))
    confidence = min(1.0, max(0.0, float(middle)))
    if (
        not MIN_FREQUENCY <= frequency <= MAX_FREQUENCY
        or applies_high_register_gate and frequency > 900 and confidence < 0.80
    ):
        return None
    return frequency, confidence


def _prime_supports(samples: np.ndarray, sample_rate: float, frequencies: list[float]) -> list[float]:
    if not frequencies:
        return []
    fft_size = 1 << (len(samples) - 1).bit_length()
    spectrum = np.sqrt(np.abs(np.fft.rfft(samples * np.hanning(len(samples)), n=fft_size)))

    def value(frequency: float) -> float:
        if frequency <= 0 or frequency >= sample_rate / 2:
            return 0.0
        position = frequency * fft_size / sample_rate
        lower = int(math.floor(position))
        if lower + 1 >= len(spectrum):
            return 0.0
        fraction = position - lower
        return float(spectrum[lower] * (1 - fraction) + spectrum[lower + 1] * fraction)

    def prime(number: int) -> bool:
        return number >= 2 and all(number % divisor for divisor in range(2, int(math.sqrt(number)) + 1))

    results = []
    limit = min(5_000.0, sample_rate / 2 * 0.98)
    for frequency in frequencies:
        maximum_harmonic = int(limit // frequency)
        inner = kernel = spectral = 0.0
        for harmonic in range(1, maximum_harmonic + 1):
            peak = value(frequency * harmonic)
            spectral += peak * peak
            if harmonic != 1 and not prime(harmonic):
                continue
            weight = 1 / math.sqrt(harmonic)
            left = value(frequency * (harmonic - 0.5))
            right = value(frequency * (harmonic + 0.5))
            inner += weight * (peak - 0.5 * (left + right))
            kernel += weight * weight
        denominator = math.sqrt(kernel * spectral)
        results.append(min(1.0, max(0.0, inner / denominator)) if denominator > 1e-12 else 0.0)
    return results


def _tone_energy(samples: np.ndarray, sample_rate: float, frequency: float) -> float:
    timeline = np.arange(len(samples), dtype=np.float64)
    kernel = np.exp(-2j * np.pi * frequency * timeline / sample_rate)
    projection = abs(np.vdot(samples * np.hanning(len(samples)), kernel))
    return float(projection * projection)


def _resolve_v2_path(frames: list[list[tuple[float, float, str, bool]]]) -> tuple[float, float, bool] | None:
    if not frames or not frames[0]:
        return None
    voiced_count = 0
    while voiced_count < len(frames) and frames[voiced_count]:
        voiced_count += 1
    previous = [candidate[1] for candidate in frames[0]]
    back_pointers: list[list[int]] = []
    for frame_index in range(1, voiced_count):
        prior, current = frames[frame_index - 1], frames[frame_index]
        scores = [-math.inf] * len(current)
        back = [0] * len(current)
        for current_index, candidate in enumerate(current):
            for prior_index, prior_candidate in enumerate(prior):
                distance = abs(1200 * math.log2(candidate[0] / prior_candidate[0]))
                penalty = 0.18 * min(distance / 700, 1) + (0.12 if distance >= 850 else 0.0)
                path_score = previous[prior_index] - penalty
                if path_score > scores[current_index]:
                    scores[current_index] = path_score
                    back[current_index] = prior_index
            scores[current_index] += candidate[1]
        previous = scores
        back_pointers.append(back)
    selected = max(range(len(previous)), key=previous.__getitem__)
    for back in reversed(back_pointers):
        selected = back[selected]
    frequency, score, _, has_agreement = frames[0][selected]
    return frequency, min(1.0, max(0.0, score)), has_agreement


def _v2_is_publishable(frequency: float, confidence: float, has_high_register_agreement: bool) -> bool:
    """Exact Swift V2 publication contract after fixed-lag resolution."""
    return confidence >= 0.70 and (frequency <= 900.0 or has_high_register_agreement)


class _ExperimentalHarmonicJumpGate:
    """Mirror Swift's V2 causal downward-harmonic publication guard."""

    def __init__(self, required_confirmations: int = 2) -> None:
        self.required_confirmations = max(1, required_confirmations)
        self.published_frequency: float | None = None
        self.pending: tuple[float, float, int] | None = None

    def filter(self, result: tuple[float, float] | None) -> tuple[float, float] | None:
        if result is None:
            self.published_frequency = None
            self.pending = None
            return None
        frequency, confidence = result
        if self.published_frequency is None:
            self.published_frequency = frequency
            return result
        previous = self.published_frequency
        jump_cents = abs(1_200 * math.log2(frequency / previous))
        ratio = frequency / previous
        is_harmonic_jump = (
            frequency < previous
            and jump_cents >= 650
            and any(abs(1_200 * math.log2(ratio / target)) <= 110 for target in (1 / 3, 0.5, 2 / 3))
        )
        if not is_harmonic_jump:
            self.pending = None
            self.published_frequency = frequency
            return result
        if self.pending and abs(1_200 * math.log2(frequency / self.pending[0])) <= 180:
            confirmations = self.pending[2] + 1
            if confirmations >= self.required_confirmations:
                self.pending = None
                self.published_frequency = frequency
                return result
            self.pending = (frequency, confidence, confirmations)
            return previous, min(confidence, 0.55)
        self.pending = (frequency, confidence, 1)
        return previous, min(confidence, 0.55)


class _ShortV2GapBridge:
    """Stateful mirror of Swift's ``resolveShortV2Gap`` publication layer."""

    def __init__(self) -> None:
        self.last_published: tuple[float, float] | None = None
        self.pending: list[tuple[float, float, float]] = []

    def resolve(
        self,
        result: tuple[float, float] | None,
        time_seconds: float,
        signal_eligible: bool,
    ) -> list[tuple[float, float, float]]:
        if result is None:
            if not signal_eligible:
                self.pending.clear()
                self.last_published = None
            elif self.last_published is not None and len(self.pending) < 7:
                self.pending.append((time_seconds, *self.last_published))
            else:
                self.pending.clear()
                self.last_published = None
            return []

        frequency, confidence = result
        current = (time_seconds, frequency, confidence)
        previous = self.last_published
        bridged: list[tuple[float, float, float]] = []
        if self.pending:
            if (
                previous is not None
                and min(previous[1], confidence) >= 0.70
                and abs(1_200 * math.log2(frequency / previous[0])) <= 90
            ):
                bridged = self.pending.copy()
            self.pending.clear()
        self.last_published = (frequency, confidence)
        return [*bridged, current]


def _bridge_short_v2_gaps(
    frames: list[tuple[float, float, float]],
    hop_seconds: float,
    blocked_times: set[float] | None = None,
) -> list[tuple[float, float, float]]:
    """Restore source timestamps only when a stable V2 contour returns."""
    if not frames:
        return []
    blocked_times = blocked_times or set()
    bridged: list[tuple[float, float, float]] = [frames[0]]
    for current in frames[1:]:
        previous = bridged[-1]
        missing = round((current[0] - previous[0]) / hop_seconds) - 1
        same_contour = abs(1200 * math.log2(current[1] / previous[1])) <= 90
        if 0 < missing <= 7 and same_contour and min(previous[2], current[2]) >= 0.70:
            for index in range(1, missing + 1):
                time_seconds = previous[0] + index * hop_seconds
                if not any(
                    abs(time_seconds - blocked) <= hop_seconds * 0.1
                    for blocked in blocked_times
                ):
                    bridged.append((time_seconds, previous[1], previous[2]))
        bridged.append(current)
    return bridged


def _bridge_short_vpm_gaps(
    frames: list[tuple[float, float, float]],
    hop_seconds: float,
    blocked_times: set[float] | None = None,
) -> list[tuple[float, float, float]]:
    """Mirror the shipped causal VPM bridge; a hard gate ends its contour."""
    if not frames:
        return []
    blocked_times = blocked_times or set()
    bridged: list[tuple[float, float, float]] = [frames[0]]
    for current in frames[1:]:
        previous = bridged[-1]
        missing = round((current[0] - previous[0]) / hop_seconds) - 1
        missing_times = [previous[0] + index * hop_seconds for index in range(1, missing + 1)]
        crosses_hard_gate = any(
            abs(time_seconds - blocked) <= hop_seconds * 0.1
            for time_seconds in missing_times
            for blocked in blocked_times
        )
        same_contour = abs(1200 * math.log2(current[1] / previous[1])) <= 90
        if (
            0 < missing <= 7
            and same_contour
            and min(previous[2], current[2]) >= 0.70
            and not crosses_hard_gate
        ):
            bridged.extend(
                (time_seconds, previous[1], previous[2]) for time_seconds in missing_times
            )
        bridged.append(current)
    return bridged


def _bridge_short_hapt_gaps(
    frames: list[tuple[float, float, float]],
    hop_seconds: float,
    blocked_times: set[float] | None = None,
) -> list[tuple[float, float, float]]:
    """Mirror ProductionPitchSession's shared append_bridged() for hapt_v1:
    the stronger endpoint must clear .60, the weaker one only .30. A
    dropout's trailing edge is exactly where a real engine's own confidence
    is most degraded by the interruption itself (measured as low as .376 on
    the v1 adverse holdout, .551 on v1 room), so requiring both endpoints to
    independently clear the same bar under-bridges genuine short gaps."""
    if not frames:
        return []
    blocked_times = blocked_times or set()
    bridged: list[tuple[float, float, float]] = [frames[0]]
    for current in frames[1:]:
        previous = bridged[-1]
        missing = round((current[0] - previous[0]) / hop_seconds) - 1
        missing_times = [previous[0] + index * hop_seconds for index in range(1, missing + 1)]
        crosses_hard_gate = any(
            abs(time_seconds - blocked) <= hop_seconds * 0.1
            for time_seconds in missing_times
            for blocked in blocked_times
        )
        same_contour = abs(1200 * math.log2(current[1] / previous[1])) <= 90
        if (
            0 < missing <= 7
            and same_contour
            and max(previous[2], current[2]) >= 0.60
            and min(previous[2], current[2]) >= 0.30
            and not crosses_hard_gate
        ):
            bridged.extend(
                (time_seconds, previous[1], previous[2]) for time_seconds in missing_times
            )
        bridged.append(current)
    return bridged


def v2_frames(
    audio: np.ndarray,
    rate: int,
    window: int = LIVE_WINDOW,
    hop: int = HOP,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
    diagnostics: list[dict[str, object]] | None = None,
) -> list[tuple[float, float, float]]:
    buffered: list[list[tuple[float, float, str, bool]]] = []
    buffered_eligible: list[bool] = []
    output: list[tuple[float, float, float]] = []
    recent_rms_peak = 0.0
    harmonic_jump_gate = _ExperimentalHarmonicJumpGate()
    gap_bridge = _ShortV2GapBridge()
    diagnostic_candidate_buffer: list[list[dict[str, object]]] = []
    for end in range(window, len(audio) + 1, hop):
        samples = np.ascontiguousarray(audio[end - window:end], dtype=np.float64)
        window_rms = centered_rms(samples)
        eligible = window_rms >= minimum_rms
        recent_rms_peak = max(window_rms, recent_rms_peak * 0.85)
        candidates: list[tuple[float, float, str]] = [] if not eligible else [
            (frequency, confidence, "yin")
            for frequency, confidence in _swift_yin_candidates(
                samples, rate, V2_ANALYSIS_MAX_FREQUENCY
            )
            if confidence >= 0.50
        ]
        autocorrelation = _autocorrelation_candidate(
            samples, rate, applies_high_register_gate=False
        ) if eligible else None
        if autocorrelation:
            candidates.append((*autocorrelation, "autocorrelation"))
        mpm_frequencies, mpm_clarities = (
            _mpm_candidate_arrays(samples, float(rate))
            if eligible else (np.empty(0), np.empty(0))
        )
        candidates.extend(
            (float(frequency), float(clarity), "mpm")
            for frequency, clarity in zip(mpm_frequencies, mpm_clarities)
        )
        # V2's fixed-lag path must not convert a decaying room tail into a
        # voiced source point. The joint low-energy/weak-periodicity gate is
        # deliberately the same causal release criterion used by YIN v1.
        strongest_periodicity = max((candidate[1] for candidate in candidates), default=0.0)
        if strongest_periodicity < 0.90 and window_rms < recent_rms_peak * 0.35:
            candidates = []
        # Near the top of the display range, a fundamental can fall just
        # outside a period detector's lag search while its f/2 sub-period is
        # exceptionally periodic. Promote the 2x partner only when the
        # measured narrow-band line is overwhelmingly stronger; normal notes
        # with a second harmonic do not meet this ratio.
        spectral_partners: list[tuple[float, float, str]] = []
        for frequency, periodicity, _ in candidates:
            upper = frequency * 2
            if not (900 < upper <= V2_ANALYSIS_MAX_FREQUENCY):
                continue
            lower_energy = _tone_energy(samples, rate, frequency)
            upper_energy = _tone_energy(samples, rate, upper)
            if upper_energy > lower_energy * 8:
                spectral_partners.append((upper, max(0.92, periodicity), "spectral"))
        candidates.extend(spectral_partners)
        supports = _prime_supports(samples, rate, [candidate[0] for candidate in candidates])
        scored: list[tuple[float, float, str, bool]] = []
        for index, (frequency, periodicity, source) in enumerate(candidates):
            agrees = any(
                other_source != source and abs(1200 * math.log2(other_frequency / frequency)) <= 55
                for other_frequency, _, other_source in candidates
            )
            agreement = 1.0 if agrees else 0.25
            # Periodicity alone often prefers a 1/2 sub-period near the top
            # of the range. Give the already-normalized prime-harmonic
            # evidence equal weight so the path can retain the measured
            # fundamental when both observations are otherwise plausible.
            score = 0.40 * periodicity + 0.20 * agreement + 0.40 * supports[index]
            # In the upper clarinet register an ACF/MPM pair can briefly
            # collapse to no candidate while the remaining estimator retains
            # an exceptionally periodic, spectrally supported fundamental.
            # Treat that as independent publication evidence, not as broad
            # permission for an arbitrary high-frequency YIN peak.
            high_register_evidence = agrees or (
                frequency > 900 and periodicity >= 0.80 and supports[index] >= 0.75
            )
            scored.append((frequency, score, source, high_register_evidence))
        diagnostic_row: dict[str, object] | None = None
        if diagnostics is not None:
            diagnostic_candidates = [
                {
                    "source": source,
                    "frequency": frequency,
                    "periodicity": candidates[index][1],
                    "agreementSupport": 1.0 if any(
                        other_source != source
                        and abs(1_200 * math.log2(other_frequency / frequency)) <= 55
                        for other_frequency, _, other_source in candidates
                    ) else 0.25,
                    "primeHarmonicSupport": supports[index],
                    "emissionScore": score,
                }
                for index, (frequency, score, source, _) in enumerate(scored)
            ]
            diagnostic_candidate_buffer.append(diagnostic_candidates)
            diagnostic_row = {
                "time": (end - window / 2) / rate,
                "signalEligible": eligible,
                "candidates": [],
            }
        buffered.append(scored)
        buffered_eligible.append(eligible)
        if len(buffered) <= V2_LAG_FRAMES:
            if diagnostic_row is not None:
                diagnostic_row.update({
                    "resolvedTime": None, "resolvedSignalEligible": True,
                    "resolvedHighRegisterAgreement": False,
                    "publishedFrequency": None, "publishedConfidence": None,
                })
                diagnostics.append(diagnostic_row)
            continue
        resolved = _resolve_v2_path(buffered)
        source_end = end - V2_LAG_FRAMES * hop
        source_time = (source_end - window / 2) / rate
        source_eligible = buffered_eligible.pop(0)
        publication: tuple[float, float] | None = None
        # Swift's below-RMS entry branch can still resolve the oldest queued
        # source decision. It returns that decision without running the normal
        # publication or harmonic-jump gate a second time.
        if not eligible and resolved:
            publication = resolved[0], resolved[1]
        elif not source_eligible:
            publication = None
        elif resolved:
            if _v2_is_publishable(resolved[0], resolved[1], resolved[2]):
                publication = harmonic_jump_gate.filter((resolved[0], resolved[1]))
        output.extend(gap_bridge.resolve(publication, source_time, source_eligible))
        if diagnostic_row is not None:
            diagnostic_row["candidates"] = diagnostic_candidate_buffer.pop(0)
            diagnostic_row.update({
                "resolvedTime": source_time,
                "resolvedSignalEligible": source_eligible,
                "resolvedHighRegisterAgreement": bool(resolved and resolved[2]),
                "publishedFrequency": publication[0] if publication else None,
                "publishedConfidence": publication[1] if publication else None,
            })
            diagnostics.append(diagnostic_row)
        buffered.pop(0)
    return output


def _compile_v2_runner(destination: Path) -> None:
    subprocess.run([
        "xcrun", "clang++", "-O3", "-std=c++20", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "core/include"),
        str(ROOT / "core/src/pitch_engine_v2.cpp"),
        str(ROOT / "core/src/fixed_lag_tracker.cpp"),
        str(ROOT / "core/src/swipe_prime.cpp"),
        str(ROOT / "core/src/pitch_engine_v2_session.cpp"),
        str(ROOT / "core/tools/pitch_engine_v2_trace.cpp"),
        "-framework", "Accelerate", "-o", str(destination),
    ], check=True)


def _v2_runner() -> Path:
    runner = Path(tempfile.gettempdir()) / "klarivision_pitch_engine_v2_trace"
    sources = [
        ROOT / "core/include/klarivision/core/pitch_engine_v2.hpp",
        ROOT / "core/include/klarivision/core/pitch_engine_v2_session.hpp",
        ROOT / "core/include/klarivision/core/fixed_lag_tracker.hpp",
        ROOT / "core/src/pitch_engine_v2.cpp",
        ROOT / "core/src/fixed_lag_tracker.cpp",
        ROOT / "core/src/swipe_prime.cpp",
        ROOT / "core/src/pitch_engine_v2_session.cpp",
        ROOT / "core/tools/pitch_engine_v2_trace.cpp",
    ]
    if not runner.exists() or runner.stat().st_mtime < max(source.stat().st_mtime for source in sources):
        _compile_v2_runner(runner)
    return runner


def v2_cpp_frames(
    audio: np.ndarray,
    rate: int,
    window: int = LIVE_WINDOW,
    hop: int = HOP,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
) -> list[tuple[float, float, float]]:
    """Production adapter: run the canonical shared C++ V2 session."""
    runner = _v2_runner()
    with tempfile.NamedTemporaryFile(suffix=".f32") as raw:
        np.asarray(audio, dtype=np.float32).tofile(raw.name)
        completed = subprocess.run([
            str(runner), raw.name, str(rate), str(window), str(hop),
            str(minimum_rms), "0",
        ], check=True, capture_output=True, text=True)
    rows = csv.DictReader(completed.stdout.splitlines())
    return [
        (float(row["time"]), float(row["frequency"]), float(row["confidence"]))
        for row in rows
    ]


def _compile_vpm_runner(destination: Path) -> None:
    subprocess.run([
        "xcrun", "clang++", "-O3", "-std=c++20", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "core/include"), str(ROOT / "core/src/vpm_like.cpp"),
        str(ROOT / "core/tools/vpm_like_trace.cpp"), "-o", str(destination),
    ], check=True)


def _vpm_runner() -> Path:
    runner = Path(tempfile.gettempdir()) / "klarivision_vpm_like_tournament_trace"
    sources = [
        ROOT / "core/include/klarivision/core/vpm_like.hpp",
        ROOT / "core/src/vpm_like.cpp",
        ROOT / "core/tools/vpm_like_trace.cpp",
    ]
    if not runner.exists() or runner.stat().st_mtime < max(source.stat().st_mtime for source in sources):
        _compile_vpm_runner(runner)
    return runner


def vpm_frames(
    audio: np.ndarray,
    rate: int,
    window: int = LIVE_WINDOW,
    hop: int = HOP,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
) -> list[tuple[float, float, float]]:
    runner = _vpm_runner()
    with tempfile.NamedTemporaryFile(suffix=".f64") as raw:
        np.asarray(audio, dtype=np.float64).tofile(raw.name)
        completed = subprocess.run([
            str(runner), raw.name, str(rate), str(window), str(hop),
            "0.38", "0.90", "0.080", "0.005", "6", "0", str(minimum_rms),
        ], check=True, capture_output=True, text=True)
    rows = csv.DictReader(completed.stdout.splitlines())
    half_window = window / (2 * rate)
    frames = [
        (float(row["time_seconds"]) - half_window, float(row["frequency_hz"]), float(row["confidence"]))
        for row in rows
    ]
    blocked_times = {
        round((end - window / 2) / rate, 9)
        for end in range(window, len(audio) + 1, hop)
        if centered_rms(audio[end - window:end]) < minimum_rms
    }
    return _bridge_short_vpm_gaps(frames, hop / rate, blocked_times)


def _compile_hapt_runner(destination: Path) -> None:
    subprocess.run([
        "xcrun", "clang++", "-O3", "-std=c++20", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "core/include"), str(ROOT / "core/src/hapt.cpp"),
        str(ROOT / "core/src/harmonic_probe.cpp"),
        str(ROOT / "core/tools/hapt_trace.cpp"), "-o", str(destination),
    ], check=True)


def _hapt_runner() -> Path:
    runner = Path(tempfile.gettempdir()) / "klarivision_hapt_tournament_trace"
    sources = [
        ROOT / "core/include/klarivision/core/hapt.hpp",
        ROOT / "core/include/klarivision/core/harmonic_probe.hpp",
        ROOT / "core/src/hapt.cpp",
        ROOT / "core/src/harmonic_probe.cpp",
        ROOT / "core/tools/hapt_trace.cpp",
    ]
    if not runner.exists() or runner.stat().st_mtime < max(source.stat().st_mtime for source in sources):
        _compile_hapt_runner(runner)
    return runner


def hapt_frames(
    audio: np.ndarray,
    rate: int,
    window: int = LIVE_WINDOW,
    hop: int = HOP,
    minimum_rms: float = DEFAULT_MINIMUM_RMS,
) -> list[tuple[float, float, float]]:
    runner = _hapt_runner()
    with tempfile.NamedTemporaryFile(suffix=".f32") as raw:
        np.asarray(audio, dtype=np.float32).tofile(raw.name)
        completed = subprocess.run([
            str(runner), raw.name, str(rate), str(window), str(hop), str(minimum_rms),
        ], check=True, capture_output=True, text=True)
    rows = csv.DictReader(completed.stdout.splitlines())
    half_window = window / (2 * rate)
    frames = [
        (float(row["time_seconds"]) - half_window, float(row["frequency_hz"]), float(row["confidence"]))
        for row in rows
    ]
    blocked_times = {
        round((end - window / 2) / rate, 9)
        for end in range(window, len(audio) + 1, hop)
        if centered_rms(audio[end - window:end]) < minimum_rms
    }
    return _bridge_short_hapt_gaps(frames, hop / rate, blocked_times)


def run_engines(
    audio: np.ndarray, rate: int, minimum_rms: float = DEFAULT_MINIMUM_RMS
) -> dict[str, EngineTrace]:
    # Compilation is setup, not pitch-analysis CPU time.
    _vpm_runner()
    _hapt_runner()
    # Numba compilation is setup as well. Use a deterministic audible warm-up
    # long enough to exercise both the YIN and MPM inner kernels.
    warm_count = LIVE_WINDOW + (V2_LAG_FRAMES + 1) * HOP
    warm_time = np.arange(warm_count) / rate
    warm_audio = 0.2 * np.sin(2 * np.pi * 220.0 * warm_time)
    causal_yin_frames(warm_audio, rate, minimum_rms)
    v2_frames(warm_audio, rate, minimum_rms=minimum_rms)
    audio_seconds = len(audio) / rate
    half_window_ms = LIVE_WINDOW / (2 * rate) * 1_000
    definitions = {
        "yin_v1": ("Python mirror of shipped Swift YIN v1", lambda: [(*frame, 1.0) for frame in causal_yin_frames(audio, rate, minimum_rms)], 0.0),
        "pitch_engine_v2": ("Canonical shared C++ V2 session", lambda: v2_cpp_frames(audio, rate, minimum_rms=minimum_rms), V2_LAG_FRAMES * HOP / rate * 1_000),
        "vpm_like": ("Production C++ core vpm_like.cpp", lambda: vpm_frames(audio, rate, minimum_rms=minimum_rms), 0.0),
        "hapt_v1": ("Production C++ core hapt.cpp", lambda: hapt_frames(audio, rate, minimum_rms=minimum_rms), 0.0),
    }
    traces: dict[str, EngineTrace] = {}
    for name, (implementation, operation, fixed_lag_ms) in definitions.items():
        started = time.process_time()
        children_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        frames = operation()
        children_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        runtime = (
            time.process_time() - started
            + children_after.ru_utime - children_before.ru_utime
            + children_after.ru_stime - children_before.ru_stime
        )
        traces[name] = EngineTrace(
            name, implementation, frames, runtime, audio_seconds, half_window_ms, fixed_lag_ms
        )
    return traces
