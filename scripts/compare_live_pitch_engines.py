#!/usr/bin/env python3
"""Produce a deterministic, side-by-side score for KlariVision's live engines.

The app's visual comparison is useful for exploration, but rendering two live
engines changes scheduling.  This script runs each algorithm separately over
the same clean reference recording and mirrors the 4096/512 live configuration.
It writes both a machine-readable JSON result and a compact Turkish HTML report.
"""

from __future__ import annotations

import html
import json
import math
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
WAV_PATH = ROOT / "data/benchmarks/canli_pitch_referans_v1.wav"
MANIFEST_PATH = ROOT / "data/benchmarks/canli_pitch_referans_v1.json"
JSON_OUTPUT = ROOT / "outputs/live-pitch-engine-karsilastirma-v1.json"
HTML_OUTPUT = ROOT / "outputs/live-pitch-engine-karsilastirma-v1.html"
WINDOW = 4096
HOP = 512

Estimate = tuple[float, float] | None


def cents(actual: float, expected: float) -> float:
    return 1200.0 * math.log2(actual / expected)


def expected_frequency(label: str, local_time: float) -> float:
    fixed = {
        "A3_sabit": 220.0,
        "C4_sabit": 261.625565,
        "E4_sabit": 329.627557,
        "A4_sabit": 440.0,
        "C3_sabit": 130.812783,
        "C4_ani_gecis": 261.625565,
        "A3_10cent_pes": 220.0 * 2 ** (-10 / 1200),
        "A3_tam": 220.0,
        "A3_10cent_tiz": 220.0 * 2 ** (10 / 1200),
    }
    if label in fixed:
        return fixed[label]
    if label == "A3_vibrato":
        return 220.0 * 2 ** (30 * math.sin(2 * math.pi * 5.5 * local_time) / 1200)
    if label == "E4_vibrato":
        return 329.627557 * 2 ** (22 * math.sin(2 * math.pi * 6.0 * local_time) / 1200)
    if label == "A3_C4_glissando":
        return 220.0 * 2 ** (math.log2(261.625565 / 220.0) * local_time / 1.5)
    if label == "G3_yukari_carpma":
        return 220.0 if local_time < 0.060 else 195.997718
    if label == "G3_asagi_carpma":
        return 174.614116 if local_time < 0.060 else 195.997718
    raise KeyError(label)


def estimate_yin(samples: np.ndarray, sample_rate: int) -> Estimate:
    rms = float(np.sqrt(np.mean(samples * samples)))
    if rms <= 0.008:
        return None
    min_lag = max(2, int(sample_rate / 1500))
    max_lag = min(len(samples) // 2, int(sample_rate / 80))
    if min_lag >= max_lag:
        return None
    energy = np.concatenate(([0.0], np.cumsum(samples * samples, dtype=np.float64)))
    difference = np.zeros(max_lag + 1)
    for lag in range(min_lag, max_lag + 1):
        count = len(samples) - lag
        difference[lag] = max(0.0, energy[count] + energy[len(samples)] - energy[lag] - 2.0 * np.dot(samples[:count], samples[lag:]))
    cumulative = 0.0
    normalized = np.ones(max_lag + 1)
    for lag in range(1, max_lag + 1):
        cumulative += difference[lag]
        if cumulative > 0:
            normalized[lag] = difference[lag] * lag / cumulative
    selected = None
    lag = min_lag
    while lag <= max_lag:
        if normalized[lag] < 0.14:
            while lag + 1 <= max_lag and normalized[lag + 1] < normalized[lag]:
                lag += 1
            selected = lag
            break
        lag += 1
    if selected is None:
        return None
    previous = normalized[selected - 1] if selected > min_lag else normalized[selected]
    current = normalized[selected]
    next_value = normalized[selected + 1] if selected < max_lag else normalized[selected]
    denominator = previous - 2 * current + next_value
    correction = 0.5 * (previous - next_value) / denominator if abs(denominator) > 1e-6 else 0.0
    frequency = sample_rate / (selected + max(-0.5, min(0.5, correction)))
    return (frequency, float(np.clip(1 - current, 0, 1))) if 80 <= frequency <= 1500 else None


def estimate_autocorrelation(samples: np.ndarray, sample_rate: int) -> Estimate:
    rms = float(np.sqrt(np.mean(samples * samples)))
    if rms <= 0.006:
        return None
    min_lag = max(2, int(sample_rate / 1500))
    max_lag = min(len(samples) // 2, int(sample_rate / 80))
    if min_lag + 2 >= max_lag:
        return None
    energy = np.concatenate(([0.0], np.cumsum(samples * samples, dtype=np.float64)))
    correlation = np.zeros(max_lag + 1)
    for lag in range(min_lag, max_lag + 1):
        count = len(samples) - lag
        e1, e2 = energy[count], energy[len(samples)] - energy[lag]
        correlation[lag] = np.dot(samples[:count], samples[lag:]) / max(1e-12, math.sqrt(e1 * e2))
    peaks = [lag for lag in range(min_lag + 1, max_lag) if correlation[lag] >= correlation[lag - 1] and correlation[lag] > correlation[lag + 1]]
    if not peaks:
        return None
    strongest = max(peaks, key=lambda item: correlation[item])
    if correlation[strongest] < 0.38:
        return None
    selected = next((lag for lag in peaks if correlation[lag] >= max(0.52, correlation[strongest] * 0.84)), strongest)
    previous, current, next_value = correlation[selected - 1], correlation[selected], correlation[selected + 1]
    denominator = previous - 2 * current + next_value
    correction = 0.5 * (previous - next_value) / denominator if abs(denominator) > 1e-6 else 0.0
    frequency = sample_rate / (selected + max(-0.5, min(0.5, correction)))
    return (frequency, float(np.clip(current, 0, 1))) if 80 <= frequency <= 1500 else None


@dataclass
class YinStabilizer:
    recent: list[float]
    last: float | None = None
    pending: Estimate = None

    def apply(self, result: Estimate) -> Estimate:
        if result is None:
            self.pending = None
            return None
        frequency, confidence = result
        if self.last is not None:
            distance = abs(cents(frequency, self.last))
            if distance > 850:
                if self.pending is not None and abs(cents(frequency, self.pending[0])) < 180:
                    self.pending = None
                    self.recent = [frequency]
                    self.last = frequency
                    return result
                self.pending = result
                return (self.last, min(confidence, 0.55))
        self.pending = None
        self.recent.append(frequency)
        if len(self.recent) > 3:
            self.recent.pop(0)
        stable = sorted(self.recent)[len(self.recent) // 2]
        self.last = stable
        return (stable, confidence)


def run_engine(audio: np.ndarray, sample_rate: int, estimator: Callable[[np.ndarray, int], Estimate], stabilize_yin: bool) -> list[dict[str, float]]:
    stabilizer = YinStabilizer([]) if stabilize_yin else None
    frames = []
    for end in range(WINDOW, len(audio) + 1, HOP):
        result = estimator(audio[end - WINDOW:end], sample_rate)
        if stabilizer is not None:
            result = stabilizer.apply(result)
        if result is not None:
            frames.append({
                "time_seconds": (end - WINDOW / 2) / sample_rate,
                "frequency": result[0],
                "confidence": result[1],
            })
    return frames


def median_or_none(values: list[float]) -> float | None:
    return round(float(np.median(values)), 2) if values else None


def section_score(frames: list[dict[str, float]], section: dict[str, object], frame_rate: float) -> dict[str, object]:
    start, end = float(section["start_seconds"]), float(section["end_seconds"])
    label = str(section["label"])
    margin = min(0.08, (end - start) * 0.12)
    matching = [frame for frame in frames if start + margin <= frame["time_seconds"] <= end - margin]
    errors = [abs(cents(frame["frequency"], expected_frequency(label, frame["time_seconds"] - start))) for frame in matching]
    settled = next((frame for frame in frames if start <= frame["time_seconds"] <= min(end, start + 0.5) and abs(cents(frame["frequency"], expected_frequency(label, frame["time_seconds"] - start))) <= 25), None)
    expected_frames = max(1, round((end - start - 2 * margin) * frame_rate))
    return {
        "label": label,
        "description": section["description"],
        "frames": len(matching),
        "coverage_percent": round(100 * len(matching) / expected_frames, 1),
        "median_absolute_cent_error": median_or_none(errors),
        "p95_absolute_cent_error": round(float(np.percentile(errors, 95)), 2) if errors else None,
        "settling_delay_ms": round(1000 * (settled["time_seconds"] - start), 1) if settled else None,
    }


def winner(yin: dict[str, object], autocorrelation: dict[str, object]) -> str:
    y, a = yin["median_absolute_cent_error"], autocorrelation["median_absolute_cent_error"]
    if y is None and a is None:
        return "—"
    if y is None:
        return "Öz-ilinti"
    if a is None:
        return "YIN"
    if abs(float(y) - float(a)) < 0.5:
        return "Yakın"
    return "YIN" if float(y) < float(a) else "Öz-ilinti"


def format_value(value: object, suffix: str = "") -> str:
    return "—" if value is None else f"{value}{suffix}"


def write_html(result: dict[str, object]) -> None:
    rows = []
    for yin, auto in zip(result["yin"]["sections"], result["autocorrelation"]["sections"]):
        rows.append(
            "<tr>"
            f"<td><strong>{html.escape(str(yin['label']))}</strong><br><small>{html.escape(str(yin['description']))}</small></td>"
            f"<td>{format_value(yin['median_absolute_cent_error'], ' cent')}</td>"
            f"<td>{format_value(auto['median_absolute_cent_error'], ' cent')}</td>"
            f"<td>{format_value(yin['settling_delay_ms'], ' ms')}</td>"
            f"<td>{format_value(auto['settling_delay_ms'], ' ms')}</td>"
            f"<td>{winner(yin, auto)}</td>"
            "</tr>"
        )
    summary = result["summary"]
    document = f"""<!doctype html>
<html lang=\"tr\"><meta charset=\"utf-8\"><title>KlariVision · Canlı pitch motor karşılaştırması</title>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:40px;color:#172033;background:#f6f8fb}}
main{{max-width:1150px;margin:auto;background:white;padding:32px;border-radius:18px;box-shadow:0 8px 24px #1d2d5014}}
h1{{margin:0 0 8px}}p{{color:#536176;line-height:1.5}}.cards{{display:flex;gap:14px;margin:24px 0}}.card{{flex:1;background:#f2f5fa;padding:18px;border-radius:12px}}.card b{{font-size:24px;display:block;margin-top:4px}}table{{width:100%;border-collapse:collapse;font-size:14px}}th,td{{padding:12px;border-bottom:1px solid #e6eaf0;text-align:left;vertical-align:top}}th{{color:#536176;font-weight:600}}small{{color:#68778b}}.note{{margin-top:20px;font-size:13px}}
</style><main>
<h1>Canlı pitch motor karşılaştırması</h1>
<p>Temiz referans kaydı, iki motoru <strong>ayrı ayrı</strong> çalıştırır. Bu nedenle canlı çift-grafik modundaki işlem yükü bu sonuca karışmaz.</p>
<div class=\"cards\"><div class=\"card\">YIN · toplam medyan hata<b>{summary['yin_median_error']} cent</b></div><div class=\"card\">Öz-ilinti · toplam medyan hata<b>{summary['autocorrelation_median_error']} cent</b></div><div class=\"card\">Örnekleme<b>{result['frame_rate_hz']} ölçüm/sn</b></div></div>
<table><thead><tr><th>Test bölümü</th><th>YIN hata</th><th>Öz-ilinti hata</th><th>YIN yaklaşma</th><th>Öz-ilinti yaklaşma</th><th>Yakınlık</th></tr></thead><tbody>{''.join(rows)}</tbody></table>
<p class=\"note\">Hata, hedef frekanstan mutlak cent farkıdır; daha küçük daha iyidir. Yaklaşma süresi, bölüm başlangıcından itibaren ±25 cent içine ilk giriş zamanıdır. Hızlı geçişlerde analiz penceresinin fiziksel süresi de sonuca dahildir.</p>
</main>"""
    HTML_OUTPUT.write_text(document, encoding="utf-8")


def main() -> None:
    with wave.open(str(WAV_PATH), "rb") as source:
        sample_rate = source.getframerate()
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    frame_rate = sample_rate / HOP
    yin_frames = run_engine(audio, sample_rate, estimate_yin, stabilize_yin=True)
    auto_frames = run_engine(audio, sample_rate, estimate_autocorrelation, stabilize_yin=False)
    yin_sections = [section_score(yin_frames, section, frame_rate) for section in manifest["sections"]]
    auto_sections = [section_score(auto_frames, section, frame_rate) for section in manifest["sections"]]
    all_yin = [item["median_absolute_cent_error"] for item in yin_sections if item["median_absolute_cent_error"] is not None]
    all_auto = [item["median_absolute_cent_error"] for item in auto_sections if item["median_absolute_cent_error"] is not None]
    result = {
        "reference": str(WAV_PATH.relative_to(ROOT)),
        "configuration": {"window_samples": WINDOW, "hop_samples": HOP, "window_ms": round(1000 * WINDOW / sample_rate, 2)},
        "frame_rate_hz": round(frame_rate, 2),
        "yin": {"detected_frames": len(yin_frames), "sections": yin_sections},
        "autocorrelation": {"detected_frames": len(auto_frames), "sections": auto_sections},
        "summary": {
            "yin_median_error": median_or_none(all_yin),
            "autocorrelation_median_error": median_or_none(all_auto),
            "scope": "Her motor ayrı çalıştırıldı; çift motorlu canlı çizim kullanılmadı.",
        },
    }
    JSON_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    JSON_OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_html(result)
    print(JSON_OUTPUT)
    print(HTML_OUTPUT)


if __name__ == "__main__":
    main()
