#!/usr/bin/env python3
"""Run a reproducible live-YIN ↔ pYIN regression suite on local media.

This is a developer-only quality gate.  It never touches user studies or
stores raw audio in reports.  For every input it derives both pitch traces,
finds their best temporal alignment automatically, and records persistent
large disagreements for investigation.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import math
import subprocess
import tempfile
import wave
from pathlib import Path

import librosa
import numpy as np

from benchmark_live_pyin_alignment import DEFAULT_MINIMUM_RMS, centered_rms, cents, choose, yin_candidates


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "data/benchmarks"
IMPORTS = ROOT / "data/imports"
REPORT = ROOT / "outputs/pitch-regression-suite.json"
HTML_REPORT = ROOT / "outputs/pitch-regression-suite.html"
PYIN_WINDOW = 4096
# Keep the causal regression path identical to the app's fixed
# "Hızlı vibrato" mode.  A stale 4096-sample test window used to hide the
# short harmonic mistakes that were plainly visible in the 1536-sample live
# graph.
LIVE_WINDOW = 1536
HOP = 512
MIN_FREQUENCY = 80.0
MAX_FREQUENCY = 1_500.0
# A note attack, tonguing transient or a short muted gap can produce a few
# octave-scale frames in either real-time or offline analysis. It is not a
# user-visible harmonic lock. Only sustained disagreement is a regression.
# Offline pYIN can label an attack one or two frames before the causal live
# engine has an observable fundamental.  A sub-0.6 second disagreement is a
# response-time difference, not a sustained wrong harmonic lock.
PERSISTENT_DIVERGENCE_SECONDS = 0.60
# The graph publishes about 86 points/s at 44.1 kHz. An octave error lasting
# only a tenth of a second is already plainly visible even though it is too
# short to be a sustained harmonic lock. Track these separately so a clean
# aggregate p95 can no longer hide the defects reported by the user.
VISIBLE_DIVERGENCE_SECONDS = 0.08


def input_files(include_imports: bool) -> list[Path]:
    extensions = {".wav", ".m4a", ".mp3", ".mp4", ".mov"}
    folders = [BENCHMARKS] + ([IMPORTS] if include_imports else [])
    candidates = sorted(path for folder in folders if folder.exists() for path in folder.iterdir()
                        if path.is_file() and path.suffix.lower() in extensions)
    # Cached studies may contain many filenames for the exact same recording.
    # One analysis per content hash is enough: it keeps the quality gate fast
    # without hiding any genuinely different source.
    unique: list[Path] = []
    seen: set[str] = set()
    for path in candidates:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest not in seen:
            seen.add(digest)
            unique.append(path)
    return unique


def read_pcm(path: Path) -> tuple[np.ndarray, int]:
    """Read media through Apple conversion so video and M4A work too."""
    with tempfile.TemporaryDirectory(prefix="klarivision-regression-") as temporary:
        wav = Path(temporary) / "source.wav"
        source = path
        if path.suffix.lower() != ".wav":
            subprocess.run(
                ["afconvert", str(path), "-o", str(wav), "-d", "LEI16@44100", "-f", "WAVE"],
                check=True,
                capture_output=True,
            )
            source = wav
        with wave.open(str(source), "rb") as file:
            rate = file.getframerate()
            channels = file.getnchannels()
            raw = np.frombuffer(file.readframes(file.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
        if channels > 1:
            raw = raw.reshape(-1, channels).mean(axis=1)
        return raw, rate


def pyin_frames(audio: np.ndarray, rate: int) -> list[tuple[float, float]]:
    f0, voiced, _ = librosa.pyin(
        audio.astype(np.float32), fmin=MIN_FREQUENCY, fmax=MAX_FREQUENCY,
        sr=rate, frame_length=PYIN_WINDOW, hop_length=HOP,
    )
    return [
        (index * HOP / rate, float(frequency))
        for index, (frequency, is_voiced) in enumerate(zip(f0, voiced))
        if is_voiced and frequency is not None and np.isfinite(frequency)
    ]


def spectral_tone_energy(samples: np.ndarray, rate: int, frequency: float) -> float:
    """Same narrow-band harmonic check used by the Swift live engine."""
    if frequency <= 0 or len(samples) < 8:
        return 0.0
    time = np.arange(len(samples), dtype=np.float64)
    window = np.hanning(len(samples))
    phase = 2 * np.pi * frequency * time / rate
    value = samples * window
    return float(np.dot(value, np.cos(phase)) ** 2 + np.dot(value, np.sin(phase)) ** 2)


def autocorrelation_pitch(samples: np.ndarray, rate: int) -> tuple[float, float] | None:
    """Mirror the Swift engine's narrow ambiguity fallback."""
    if len(samples) < 1024:
        return None
    centered = samples - float(np.mean(samples))
    rms = math.sqrt(float(np.mean(centered * centered)))
    if rms <= 0.006:
        return None
    min_lag = max(2, int(rate / MAX_FREQUENCY))
    max_lag = min(len(samples) // 2, int(rate / MIN_FREQUENCY))
    correlation = np.zeros(max_lag + 1, dtype=np.float64)
    for lag in range(min_lag, max_lag + 1):
        leading = centered[:-lag]
        delayed = centered[lag:]
        denominator = math.sqrt(max(1e-12, float(np.dot(leading, leading) * np.dot(delayed, delayed))))
        correlation[lag] = float(np.dot(leading, delayed)) / denominator
    peaks = [
        lag for lag in range(min_lag + 1, max_lag)
        if correlation[lag] >= correlation[lag - 1] and correlation[lag] > correlation[lag + 1]
    ]
    if not peaks:
        return None
    strongest = max(peaks, key=lambda lag: correlation[lag])
    if correlation[strongest] < 0.38:
        return None
    acceptance = max(0.52, correlation[strongest] * 0.84)
    selected = next((lag for lag in peaks if correlation[lag] >= acceptance), strongest)
    previous, current, following = correlation[selected - 1:selected + 2]
    denominator = previous - 2 * current + following
    correction = 0.5 * (previous - following) / denominator if abs(denominator) > 1e-9 else 0.0
    refined_lag = selected + min(0.5, max(-0.5, correction))
    frequency = rate / refined_lag
    confidence = float(max(0, min(1, current)))
    if not MIN_FREQUENCY <= frequency <= MAX_FREQUENCY:
        return None
    if frequency > 900 and confidence < 0.80:
        return None
    return frequency, confidence


def causal_yin_frames(
    audio: np.ndarray, rate: int, minimum_rms: float = DEFAULT_MINIMUM_RMS
) -> list[tuple[float, float]]:
    previous: float | None = None
    pending_jump: tuple[float, float, int] | None = None
    pending_gap: list[tuple[float, float]] = []
    silent_estimates = 0
    recent_rms_peak = 0.0
    result: list[tuple[float, float]] = []
    for end in range(LIVE_WINDOW, len(audio) + 1, HOP):
        frame_time = (end - LIVE_WINDOW / 2) / rate
        window = audio[end - LIVE_WINDOW:end]
        window_rms = centered_rms(window)
        hard_gated = window_rms < minimum_rms
        candidates = [] if hard_gated else yin_candidates(window, rate, minimum_rms=minimum_rms)
        confident = [(frequency, confidence) for frequency, confidence in candidates if confidence >= 0.76]
        # Keep the regression model aligned with the Swift live monitor: a
        # running musical contour may use a weaker, still plausible YIN
        # candidate rather than dropping a breathy or reflected clarinet tone.
        usable = [(frequency, confidence) for frequency, confidence in candidates if confidence >= 0.55]
        recent_rms_peak = max(window_rms, recent_rms_peak * 0.85)
        # A room tail can remain weakly periodic for two or three hops after a
        # release.  It is not a new note: confidence has dropped below the
        # normal publication gate while energy has collapsed relative to the
        # immediately preceding contour.  Suppress only that joint condition;
        # a quiet but steady note ages the peak out and remains publishable.
        strongest_confidence = max((confidence for _, confidence in candidates), default=0.0)
        if usable and strongest_confidence < 0.90 and window_rms < recent_rms_peak * 0.35:
            usable = []
        if not usable:
            silent_estimates += 1
            # A short zeroed input can be a transport/dropout artifact rather
            # than a phrase release. Do not publish a held pitch yet: retain
            # at most seven source timestamps and fill them only if the same
            # contour returns before that limit. A real silence never gains
            # false-voiced frames because its pending points are discarded.
            if hard_gated:
                pending_gap.clear()
            elif previous is not None and len(pending_gap) < 7:
                pending_gap.append((frame_time, previous))
            else:
                pending_gap.clear()
            if silent_estimates >= 30:
                previous = None
                pending_jump = None
                pending_gap.clear()
            continue
        silent_estimates = 0
        window_energy_scale = float(np.dot(window, window)) * len(window)

        def supported_upper_register_mate(base_frequency: float) -> float | None:
            """Return a strongly measured 2x/3x mate from any usable YIN peak."""
            upper_candidates: list[tuple[float, float]] = []
            for candidate_frequency, _ in usable:
                candidate_energy = spectral_tone_energy(window, rate, candidate_frequency)
                for factor in (3.0, 2.0):
                    upper = candidate_frequency * factor
                    if upper <= max(900.0, base_frequency) or upper > MAX_FREQUENCY:
                        continue
                    upper_energy = spectral_tone_energy(window, rate, upper)
                    if upper_energy > max(candidate_energy * 80, window_energy_scale * 0.008):
                        upper_candidates.append((upper_energy, upper))
            if not upper_candidates:
                return None
            return max(upper_candidates)[1]

        spectrally_confirmed_jump = False
        if previous is None:
            frequency, confidence = max(confident or usable, key=lambda item: item[1])
        else:
            # Causal continuity, harmonic mate and nearby-note guards. The
            # suite deliberately does not apply the UI's output holdback for
            # a large transition: it compares pitch decisions, rather than
            # the short presentation gap that holdback creates.
            continuity = usable
            def distance(value: float) -> float:
                return abs(cents(value, previous))
            def score(item: tuple[float, float]) -> float:
                return item[1] - 0.30 * min(distance(item[0]) / 700.0, 1.0)
            frequency, confidence = max(continuity, key=score)
            def long_window_supports_upper(lower: float, upper: float) -> bool:
                """Resolve a short-window octave ambiguity without pYIN lookahead.

                The 1536-sample path supplies the visible low latency.  Only
                when it proposes an octave-scale register change do we inspect
                the already-captured 4096-sample history.  A real high note is
                also competitive in that longer context; a strong clarinet
                overtone (as at 111–113 s) is not.
                """
                if end < PYIN_WINDOW:
                    return False
                history = audio[end - PYIN_WINDOW:end]
                longer = [
                    item for item in yin_candidates(history, rate, minimum_rms=minimum_rms)
                    if item[1] >= 0.55
                ]
                lower_matches = [item for item in longer if abs(cents(item[0], lower)) < 90]
                upper_matches = [item for item in longer if abs(cents(item[0], upper)) < 90]
                if not upper_matches:
                    return False
                upper_confidence = max(item[1] for item in upper_matches)
                lower_confidence = max((item[1] for item in lower_matches), default=0.0)
                return upper_confidence >= lower_confidence - 0.06

            def overwhelming_spectral_upper(lower: float, upper: float) -> bool:
                """Accept a weak-YIN high fundamental only with extreme evidence.

                The adverse fixture can leave the real 880–1319 Hz line
                thousands of times stronger than a very periodic 1/3–1/5
                sub-period. A normal clarinet overtone in the Şükrü Tunar
                ambiguity is only tens of times stronger, so it deliberately
                does not enter this escape hatch.
                """
                if end < PYIN_WINDOW:
                    return False
                history = audio[end - PYIN_WINDOW:end]
                short_ratio = spectral_tone_energy(window, rate, upper) / max(
                    spectral_tone_energy(window, rate, lower), 1e-9
                )
                long_ratio = spectral_tone_energy(history, rate, upper) / max(
                    spectral_tone_energy(history, rate, lower), 1e-9
                )
                return short_ratio >= 500 and long_ratio >= 500
            # Clarinet's odd harmonics can make a 1/2, 2/3, 3/2 or 2× mate
            # more periodic than the fundamental. Only recover a mate when it
            # continues the immediately preceding musical contour, exactly as
            # the live Swift implementation does.
            base_energy = spectral_tone_energy(window, rate, frequency)
            for factor in (2.0, 3.0, 1.5, 2.0 / 3.0, 0.5, 1.0 / 3.0):
                mate = frequency * factor
                if not (MIN_FREQUENCY <= mate <= MAX_FREQUENCY):
                    continue
                if abs(cents(mate, previous)) >= 300:
                    continue
                if spectral_tone_energy(window, rate, mate) > base_energy * 0.55:
                    frequency = mate
                    break
            # Mirror the live engine's upper-register rescue. A strong,
            # persistent high fundamental must not be hidden by a low
            # sub-period merely because that low candidate is nearer to the
            # preceding note. The report still requires sustained agreement,
            # so an isolated high harmonic cannot pass as a note change.
            base_energy = spectral_tone_energy(window, rate, frequency)
            upper = [
                item for item in usable
                if item[0] > frequency
                and distance(item[0]) > 900
            ]
            if upper:
                window_energy_scale = float(np.dot(window, window)) * len(window)
                supported_upper = [
                    item for item in upper
                    if spectral_tone_energy(window, rate, item[0]) > max(base_energy * 12, window_energy_scale * 0.005)
                    and (
                        long_window_supports_upper(frequency, item[0])
                        or overwhelming_spectral_upper(frequency, item[0])
                    )
                ]
                if supported_upper:
                    upper_choice = max(
                        supported_upper,
                        key=lambda item: spectral_tone_energy(window, rate, item[0]),
                    )
                    spectrally_confirmed_jump = True
                    frequency, confidence = upper_choice
            # A real upward octave entry can arrive with a temporarily weaker
            # YIN confidence than its 1/2-period candidate. Clarinet has weak
            # even harmonics, so a strong *spectral* line at the 2× candidate
            # is useful independent evidence that it is the new fundamental,
            # not merely the second harmonic of the previous low note.
            base_energy = spectral_tone_energy(window, rate, frequency)
            window_energy_scale = float(np.dot(window, window)) * len(window)
            octave_candidates = [
                item for item in usable
                if 1.85 <= item[0] / frequency <= 2.15
                and item[1] >= confidence - 0.25
                and spectral_tone_energy(window, rate, item[0]) > max(base_energy * 12, window_energy_scale * 0.005)
                and long_window_supports_upper(frequency, item[0])
            ]
            if octave_candidates:
                frequency, confidence = max(
                    octave_candidates,
                    key=lambda item: spectral_tone_energy(window, rate, item[0]),
                )
                spectrally_confirmed_jump = True
            # A nearby low-period candidate must not undo an upward choice
            # that the spectrum has independently confirmed. This was the
            # cause of the 1/2-frequency locks around 79–83 s and 130–133 s.
            if distance(frequency) > 650 and not spectrally_confirmed_jump:
                nearby = [item for item in continuity if distance(item[0]) < 350]
                if nearby:
                    stable = max(nearby, key=lambda item: item[1])
                    if stable[1] >= confidence - 0.12:
                        frequency, confidence = stable
            if frequency < 220 and distance(frequency) > 650:
                autocorrelation = autocorrelation_pitch(window, rate)
                if autocorrelation is not None and autocorrelation[0] > frequency * 1.75 and autocorrelation[1] >= 0.52:
                    frequency, confidence = autocorrelation
            # Even independently supported changes receive the short
            # three-hop confirmation. This costs only a few tens of
            # milliseconds and prevents an isolated upper harmonic from being
            # drawn as a real note.
            if rescued_upper := supported_upper_register_mate(frequency):
                frequency = rescued_upper
                spectrally_confirmed_jump = True
            if distance(frequency) > 900:
                # Ornamented clarinet attacks can move by more than 180 cents
                # between two 11.6 ms hops. Keep confirming the same directed
                # leap while it remains inside a musically plausible fast
                # transition instead of resetting the gate on every hop.
                if pending_jump is not None and abs(cents(frequency, pending_jump[0])) < 360:
                    confirmations = pending_jump[2] + 1
                    if confirmations < 3:
                        pending_jump = (frequency, confidence, confirmations)
                        continue
                    pending_jump = None
                else:
                    pending_jump = (frequency, confidence, 1)
                    continue
            else:
                pending_jump = None
        # Explicit 3rd-harmonic guard. A clarinet's strong odd spectrum can
        # make YIN choose 3f while the real fundamental f is still the
        # strongest spectral line (for example 110 -> 330 Hz). Conversely, a
        # true high fundamental can be reported as f/3 even when the measured
        # spectrum contains virtually no energy at that subharmonic. These
        # checks use the measured signal itself, not the expected test pitch.
        selected_energy = spectral_tone_energy(window, rate, frequency)
        lower_fundamentals = [
            item for item in usable
            if (1.85 <= frequency / item[0] <= 2.15 or 2.85 <= frequency / item[0] <= 3.15)
            and spectral_tone_energy(window, rate, item[0]) > selected_energy * 1.8
        ]
        # Do not replace an already continuous upper contour with a fleeting
        # subharmonic solely because its instantaneous spectral bin wins. A
        # true downward change is still eligible: it is far from `previous`.
        if lower_fundamentals and (previous is None or abs(cents(frequency, previous)) > 300):
            frequency, confidence = max(
                lower_fundamentals,
                key=lambda item: spectral_tone_energy(window, rate, item[0]),
            )
            selected_energy = spectral_tone_energy(window, rate, frequency)

        # A hidden fundamental can leave two nearly equal YIN periodicities at
        # f and 2f.  If the active contour has fallen to f, recover 2f only
        # when it is independently present in the candidate list with similar
        # periodicity and its measured line is decisively stronger.  This is a
        # local ambiguity repair, not a general spectral promotion rule.
        octave_recoveries: list[tuple[float, float, float]] = []
        for lower_frequency, lower_confidence in usable:
            upper_frequency = lower_frequency * 2.0
            if not (upper_frequency > frequency * 1.5 and upper_frequency <= 900.0):
                continue
            upper_confidence = max((candidate_confidence for candidate_frequency, candidate_confidence in usable
                                    if abs(cents(candidate_frequency, upper_frequency)) <= 55), default=None)
            if upper_confidence is None or upper_confidence < lower_confidence - 0.05:
                continue
            lower_energy = spectral_tone_energy(window, rate, lower_frequency)
            upper_energy = spectral_tone_energy(window, rate, upper_frequency)
            if upper_energy > lower_energy * 3.0:
                octave_recoveries.append((upper_energy, upper_frequency, upper_confidence))
        if octave_recoveries:
            _, frequency, confidence = max(octave_recoveries)
            selected_energy = spectral_tone_energy(window, rate, frequency)

        # The selected YIN period can be a deep sub-period (for example f/10)
        # even though another usable YIN peak sits at f/2 or f/3.  Searching
        # harmonic mates of only the selected peak therefore cannot recover
        # the real upper-register line.  Keep YIN as the period estimator, but
        # let every usable peak propose a strictly gated spectral mate.
        if rescued_upper := supported_upper_register_mate(frequency):
            frequency = rescued_upper

        if pending_gap:
            # Do not let continuity correction disguise a new onset as a
            # return of the prior contour.  The raw YIN candidates must also
            # contain a mate near the held pitch; otherwise a phrase release
            # followed by another note would paint the intervening silence.
            raw_contour_returned = previous is not None and any(
                confidence >= 0.55 and abs(cents(candidate, previous)) <= 90
                for candidate, confidence in candidates
            )
            if raw_contour_returned and previous is not None and abs(cents(frequency, previous)) <= 90:
                result.extend(pending_gap)
            pending_gap.clear()
        previous = frequency
        result.append((frame_time, frequency))
    return result


def matched_errors(live: list[tuple[float, float]], reference: list[tuple[float, float]], offset: float) -> list[tuple[float, float]]:
    errors: list[tuple[float, float]] = []
    index = 0
    for live_time, frequency in live:
        target = live_time - offset
        while index + 1 < len(reference) and reference[index + 1][0] <= target:
            index += 1
        if index + 1 >= len(reference):
            break
        lower, upper = reference[index], reference[index + 1]
        gap = upper[0] - lower[0]
        if gap <= 0 or gap > 0.09 or not lower[0] <= target <= upper[0]:
            continue
        amount = (target - lower[0]) / gap
        expected = 2 ** (math.log2(lower[1]) + amount * (math.log2(upper[1]) - math.log2(lower[1])))
        errors.append((live_time, abs(cents(frequency, expected))))
    return errors


def calibrate(live: list[tuple[float, float]], reference: list[tuple[float, float]]) -> tuple[float, list[tuple[float, float]]]:
    best: tuple[float, float, list[tuple[float, float]]] | None = None
    for milliseconds in range(-120, 121):
        offset = milliseconds / 1000
        errors = matched_errors(live, reference, offset)
        if len(errors) < 80:
            continue
        values = sorted(value for _, value in errors)
        score = values[len(values) // 2] + 0.35 * values[int((len(values) - 1) * 0.90)]
        if best is None or score < best[1]:
            best = (offset, score, errors)
    if best is None:
        return 0.0, []
    return best[0], best[2]


def divergence_ranges(
    errors: list[tuple[float, float]],
    minimum_duration: float,
) -> list[dict[str, float | int]]:
    found: list[dict[str, float | int]] = []
    active: dict[str, float | int] | None = None
    for time, value in errors:
        if value < 100:
            continue
        if active is not None and time - float(active["end_seconds"]) <= 0.08:
            active["end_seconds"] = time
            active["peak_cents"] = max(float(active["peak_cents"]), value)
            active["points"] = int(active["points"]) + 1
        else:
            if active is not None and float(active["end_seconds"]) - float(active["start_seconds"]) >= minimum_duration:
                found.append(active)
            active = {"start_seconds": time, "end_seconds": time, "peak_cents": value, "points": 1}
    if active is not None and float(active["end_seconds"]) - float(active["start_seconds"]) >= minimum_duration:
        found.append(active)
    return found


def sample_windows(audio: np.ndarray, rate: int, seconds: float | None, complete: bool = False) -> list[tuple[float, np.ndarray]]:
    """Return full audio, samples, or contiguous blocks that cover all audio."""
    if seconds is None or len(audio) / rate <= seconds * 3.2:
        return [(0.0, audio)]
    length = int(seconds * rate)
    if complete:
        return [
            (start / rate, audio[start:min(start + length, len(audio))])
            for start in range(0, len(audio), length)
        ]
    max_start = len(audio) - length
    starts = sorted({0, max_start // 2, max_start})
    return [(start / rate, audio[start:start + length]) for start in starts]


def evaluate(path: Path, window_seconds: float | None = None, complete: bool = False) -> dict[str, object]:
    audio, rate = read_pcm(path)
    segment_results: list[dict[str, object]] = []
    errors: list[tuple[float, float]] = []
    reference_count = 0
    live_count = 0
    offsets: list[float] = []
    for start, segment in sample_windows(audio, rate, window_seconds, complete):
        reference = pyin_frames(segment, rate)
        live = causal_yin_frames(segment, rate)
        offset, segment_errors = calibrate(live, reference)
        offsets.append(offset)
        reference_count += len(reference)
        live_count += len(live)
        errors.extend((start + time, value) for time, value in segment_errors)
        segment_values = sorted(value for _, value in segment_errors)
        segment_results.append({
            "start_seconds": round(start, 3),
            "duration_seconds": round(len(segment) / rate, 3),
            "matched_points": len(segment_errors),
            "p95_absolute_cent_error": round(float(np.percentile(segment_values, 95)), 2) if segment_values else None,
            "automatic_offset_seconds": round(offset, 3),
        })
    values = sorted(value for _, value in errors)
    ranges = divergence_ranges(errors, PERSISTENT_DIVERGENCE_SECONDS)
    visible_ranges = divergence_ranges(errors, VISIBLE_DIVERGENCE_SECONDS)
    p95 = round(float(np.percentile(values, 95)), 2) if values else None
    # Spoken introductions or intentionally silent windows are not pitch
    # failures. A source is testable if it has at least one voiced window;
    # every voiced window must then meet the quality gate.
    voiced_segments = [item for item in segment_results if int(item["matched_points"]) >= 80]
    segments_pass = all(
        item["p95_absolute_cent_error"] is None or float(item["p95_absolute_cent_error"]) <= 20
        for item in voiced_segments
    )
    status = "geçti" if values and voiced_segments and p95 is not None and p95 <= 20 and segments_pass and not visible_ranges else "incelenecek"
    return {
        "source": str(path.relative_to(ROOT)),
        "duration_seconds": round(len(audio) / rate, 3),
        "sampled_windows": segment_results,
        "sample_rate": rate,
        "reference_frames": reference_count,
        "live_frames": live_count,
        "matched_points": len(errors),
        "automatic_offset_seconds": round(float(np.median(offsets)), 3) if offsets else None,
        "median_absolute_cent_error": round(float(np.median(values)), 2) if values else None,
        "p95_absolute_cent_error": p95,
        "persistent_divergences": ranges,
        "visible_divergences": visible_ranges,
        "status": status,
    }


def write_html(results: list[dict[str, object]]) -> None:
    rows = []
    for item in results:
        ranges = item.get("persistent_divergences", [])
        notes = " · ".join(
            f"{entry['start_seconds']:.2f}–{entry['end_seconds']:.2f} sn / {entry['peak_cents']:.0f} cent"
            for entry in ranges
        ) or "—"
        status = str(item.get("status", "hata"))
        color = "#147a3d" if status == "geçti" else "#b42318"
        rows.append(
            "<tr>"
            f"<td>{html.escape(str(item.get('source', '—')))}</td>"
            f"<td><b style='color:{color}'>{html.escape(status)}</b></td>"
            f"<td>{item.get('automatic_offset_seconds', '—')}</td>"
            f"<td>{item.get('median_absolute_cent_error', '—')}</td>"
            f"<td>{item.get('p95_absolute_cent_error', '—')}</td>"
            f"<td>{html.escape(notes)}</td></tr>"
        )
    passed = sum(item.get("status") == "geçti" for item in results)
    HTML_REPORT.write_text(
        "<!doctype html><meta charset='utf-8'><title>KlariVision · Pitch regresyonu</title>"
        "<style>body{font:14px -apple-system;padding:30px;color:#182230}table{border-collapse:collapse;width:100%}th,td{padding:10px;border-bottom:1px solid #dde3ea;text-align:left}th{background:#f4f7fa}</style>"
        f"<h1>Pitch regresyon raporu</h1><p>{passed}/{len(results)} kayıt geçti. Eşik: p95 ≤ 20 cent ve kalıcı büyük sapma yok.</p>"
        "<table><thead><tr><th>Kaynak</th><th>Durum</th><th>Otomatik ofset (sn)</th><th>Ortanca cent</th><th>p95 cent</th><th>İncelenecek aralık</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--imports", action="store_true", help="Include cached user video/audio imports too.")
    parser.add_argument("--resume", action="store_true", help="Keep completed cases and continue with the next source.")
    parser.add_argument("--fresh", action="store_true", help="Discard the previous report and rerun every selected source.")
    parser.add_argument("--full", action="store_true", help="Analyse every second of every selected recording in contiguous blocks.")
    parser.add_argument("--only", help="Analyse one source whose filename contains this text.")
    args = parser.parse_args()
    existing: dict[str, dict[str, object]] = {}
    if args.resume and not args.fresh and REPORT.exists():
        try:
            existing = {str(item["source"]): item for item in json.loads(REPORT.read_text(encoding="utf-8")).get("cases", [])}
        except (OSError, ValueError, KeyError):
            existing = {}
    results = list(existing.values())
    completed = set(existing)
    def save() -> None:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps({"schema": "klarivision-pitch-regression-v1", "cases": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        write_html(results)
    paths = input_files(args.imports)
    if args.only:
        needle = args.only.casefold()
        paths = [path for path in paths if needle in path.name.casefold()]
        if not paths:
            raise SystemExit(f"No source matches: {args.only}")
    for path in paths:
        relative = str(path.relative_to(ROOT))
        if relative in completed:
            continue
        try:
            # Full mode covers every second in bounded blocks: this avoids a
            # huge pYIN allocation while retaining the complete recording.
            # Controlled benchmarks remain single full-length tests.
            # A targeted full-recording diagnosis must preserve the causal
            # engine's history from the first sample to the last. Splitting it
            # into 18-second blocks resets that history and can make a replayed
            # excerpt look correct while the uninterrupted performance fails.
            window_seconds = None if args.full and args.only else (18.0 if path.parent == IMPORTS else None)
            result = evaluate(path, window_seconds=window_seconds, complete=args.full)
            print(f"OK   {result['source']}  offset={result['automatic_offset_seconds']:+.3f}s  p95={result['p95_absolute_cent_error']}")
            results.append(result)
        except Exception as error:  # Keep the suite running to show every failure.
            print(f"FAIL {path}: {error}")
            results.append({"source": relative, "error": str(error)})
        save()
    save()
    print(REPORT)


if __name__ == "__main__":
    main()
