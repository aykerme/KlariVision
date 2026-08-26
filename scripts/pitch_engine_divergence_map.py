#!/usr/bin/env python3
"""Motorlar arası perde uyuşmazlığını epizotlara indirgeyen tanı aracı.

Gerçek kayıtlarda gerçek-değer yoktur; pYIN kararlı bir referanstır ama kesin
doğru değildir (`docs/TEST_BASELINE.md`).  Bu araç bu yüzden "hangi motor
yanlış" demez.  Dört motoru aynı kaynakta koşar, her karede motorlar-arası
medyandan belirgin biçimde ayrışan motoru işaretler ve ayrışmaları epizotlara
toplar.  Elde kalan liste, kullanıcının dinleyerek karara bağlaması gereken
kısa parçalardır — 191 saniyelik bir kayıt yerine birkaç dakikalık iş.

Ayrışmanın sınıfı da hesaplanır, çünkü hepsi aynı ağırlıkta değildir:
32 ms'lik analiz penceresi hızlı bir perde geçişinde zaten onlarca sentlik
bulanıklık üretir, dolayısıyla geçiş anındaki küçük ayrışmalar motor hatası
sayılmamalı ve eşik ayarına gerekçe yapılmamalıdır.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import statistics
import sys
import wave
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))

from klarivision.pitch.cpp_engine import ENGINES, OFFLINE_TRACK_REVISION, executable, extract
from pitch_error_metrics import harmonic_relationship

SCHEMA = "klarivision-pitch-divergence-map-v1"
ENGINE_ORDER = ("yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1")
OUTPUTS = ROOT / "outputs"

# Bir karenin "aynı kare" sayılması için gereken zaman yakınlığı.  Motorlar aynı
# 512 örnek hop'unu kullandığı için damgalar birebir çakışır; yuvarlama yalnız
# kayan nokta gürültüsünü siler.
TIME_DECIMALS = 4
# pYIN farklı bir hop ile üretildiği için en yakın referans karesi aranır.
REFERENCE_TOLERANCE_SECONDS = 0.012
# Ayrışmanın "hızlı geçişte" sayılması için gereken yerel perde eğimi.  950
# sent/sn ölçülen tipik değer; 300 eşiği vibrato ve süslemeyi de kapsar.
TRANSITION_SLOPE_CENTS_PER_SECOND = 300.0
# Yerel eğim bu kadar kare ileri/geri bakarak ölçülür (±6 kare ≈ ±64 ms).
SLOPE_HALF_WINDOW_FRAMES = 6
# Bu sınırın üstündeki sapma tek bir pencerenin bulanmasıyla açıklanamaz.
LARGE_ERROR_CENTS = 100.0


def _cents(frequency_hz: float, reference_hz: float) -> float:
    return 1200.0 * math.log2(frequency_hz / reference_hz)


def load_track(path: Path) -> dict[float, float]:
    """offline_track_v1 JSON'undan yalnız sesli kareleri oku.

    Sessiz kareler dosyada hiç yer almaz; seslilik uyuşmazlığı bu yüzden zaman
    ızgarasındaki eksiklik olarak görünür.
    """
    payload = json.loads(path.read_text(encoding="utf-8"))
    track: dict[float, float] = {}
    for frame in payload.get("frames", []):
        if not frame.get("voiced"):
            continue
        frequency = float(frame.get("frequency_hz") or 0.0)
        if frequency > 0.0:
            track[round(float(frame["time_seconds"]), TIME_DECIMALS)] = frequency
    return track


def load_reference(path: Path) -> list[tuple[float, float]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return [
        (float(frame["time_seconds"]), float(frame["frequency_hz"]))
        for frame in payload.get("frames", [])
        if frame.get("voiced") and float(frame.get("frequency_hz") or 0.0) > 0.0
    ]


def reference_at(reference: list[tuple[float, float]], times: list[float], time: float) -> float | None:
    """En yakın referans karesini döndür; tolerans dışındaysa None."""
    if not times:
        return None
    index = bisect.bisect_left(times, time)
    best: tuple[float, float] | None = None
    for candidate in (index - 1, index, index + 1):
        if 0 <= candidate < len(times):
            distance = abs(times[candidate] - time)
            if best is None or distance < best[0]:
                best = (distance, reference[candidate][1])
    return best[1] if best and best[0] <= REFERENCE_TOLERANCE_SECONDS else None


def classify(cents: float, slope_cents_per_second: float, *, lone: bool) -> tuple[str, str]:
    """Ayrışmayı sınıfına ve (varsa) harmonik oran etiketine ayır."""
    if not lone:
        # Birden çok motor aynı anda ayrışıyorsa medyan o karede güvenilir
        # değildir ve hata tek bir motora atfedilemez.
        return "ortak", ""
    label = harmonic_relationship(cents) or ""
    if abs(cents) > LARGE_ERROR_CENTS:
        return ("harmonik" if label else "buyuk"), label
    if abs(slope_cents_per_second) > TRANSITION_SLOPE_CENTS_PER_SECOND:
        # Perde hızla hareket ederken pencere bulanması bu büyüklükte bir farkı
        # tek başına açıklar; motor hatası olduğu varsayılmaz.
        return "gecis", label
    return "sapma", label


def build_events(
    tracks: dict[str, dict[float, float]],
    reference: list[tuple[float, float]],
    *,
    cents_threshold: float,
) -> dict[str, list[dict[str, object]]]:
    engines = list(tracks)
    every_time = sorted(set().union(*(set(track) for track in tracks.values())))
    common = [time for time in every_time if all(time in tracks[name] for name in engines)]
    consensus = [statistics.median(tracks[name][time] for name in engines) for time in common]
    reference_times = [item[0] for item in reference]

    def slope(index: int) -> float:
        low = max(0, index - SLOPE_HALF_WINDOW_FRAMES)
        high = min(len(common) - 1, index + SLOPE_HALF_WINDOW_FRAMES)
        if high <= low:
            return 0.0
        return _cents(consensus[high], consensus[low]) / (common[high] - common[low])

    events: dict[str, list[dict[str, object]]] = {name: [] for name in engines}
    for index, time in enumerate(common):
        offsets = {name: _cents(tracks[name][time], consensus[index]) for name in engines}
        outliers = [name for name, value in offsets.items() if abs(value) > cents_threshold]
        if not outliers:
            continue
        local_slope = slope(index)
        for name in outliers:
            kind, label = classify(offsets[name], local_slope, lone=len(outliers) == 1)
            events[name].append(
                {
                    "time_seconds": round(time, 3),
                    "cents_from_consensus": round(offsets[name], 1),
                    "kind": kind,
                    "harmonic_label": label,
                    "frequency_hz": round(tracks[name][time], 1),
                    "consensus_hz": round(consensus[index], 1),
                    "reference_hz": (
                        round(value, 1)
                        if (value := reference_at(reference, reference_times, time)) is not None
                        else None
                    ),
                    "slope_cents_per_second": round(local_slope),
                }
            )

    # Seslilik uyuşmazlığı: bir motor tek başına sesli ("kaçak nokta") ya da tek
    # başına sessiz ("boşluk").  İkisi de perde hatası değildir ama kullanıcının
    # gördüğü eğriyi doğrudan bozar.
    for time in every_time:
        voiced = [name for name in engines if time in tracks[name]]
        silent = [name for name in engines if time not in tracks[name]]
        if len(voiced) == 1:
            name = voiced[0]
            kind, others = "kacak", silent
        elif len(silent) == 1:
            name = silent[0]
            kind, others = "bosluk", voiced
        else:
            continue
        events[name].append(
            {
                "time_seconds": round(time, 3),
                "cents_from_consensus": 0.0,
                "kind": kind,
                "harmonic_label": "",
                "frequency_hz": round(tracks[name].get(time, 0.0), 1),
                "consensus_hz": round(statistics.median(tracks[other][time] for other in others), 1)
                if kind == "bosluk"
                else 0.0,
                "reference_hz": (
                    round(value, 1)
                    if (value := reference_at(reference, reference_times, time)) is not None
                    else None
                ),
                "slope_cents_per_second": 0,
            }
        )

    for name in engines:
        events[name].sort(key=lambda item: item["time_seconds"])
    return events


def group_episodes(events: list[dict[str, object]], *, gap_seconds: float) -> list[dict[str, object]]:
    """Ardışık ayrışma karelerini tek bir dinlenebilir parçaya topla."""
    episodes: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    for event in events:
        time = float(event["time_seconds"])
        if current is not None and time - float(current["end_seconds"]) <= gap_seconds:
            current["end_seconds"] = time
            current["frame_count"] += 1
            current["_kinds"][event["kind"]] += 1
            if abs(float(event["cents_from_consensus"])) > abs(float(current["peak_cents"])):
                current["peak_cents"] = event["cents_from_consensus"]
                current["peak_time_seconds"] = time
                current["harmonic_label"] = event["harmonic_label"]
        else:
            if current is not None:
                episodes.append(current)
            current = {
                "start_seconds": time,
                "end_seconds": time,
                "frame_count": 1,
                "peak_cents": event["cents_from_consensus"],
                # Kare okuması epizodun ortasından değil, sapmanın en büyük
                # olduğu kareden alınmalı; kısa epizotlarda orta nokta iki
                # aykırı karenin arasına düşüp hatayı görünmez yapıyordu.
                "peak_time_seconds": time,
                "harmonic_label": event["harmonic_label"],
                "_kinds": Counter([event["kind"]]),
            }
    if current is not None:
        episodes.append(current)
    for index, episode in enumerate(episodes):
        kinds = episode.pop("_kinds")
        episode["kind"] = kinds.most_common(1)[0][0]
        episode["kind_counts"] = dict(sorted(kinds.items()))
        episode["index"] = index
    return episodes


def curve(track: dict[float, float]) -> list[list[float]]:
    """Eğriyi sayfada çizmek için sent cinsinden kompakt diziye indir."""
    return [[round(time, 3), round(_cents(hz, 440.0), 1)] for time, hz in sorted(track.items())]


def fingerprint(payload: dict[str, object]) -> str:
    stable = json.loads(json.dumps(payload))
    stable.pop("fingerprint", None)
    stable.pop("generated_at", None)
    return hashlib.sha256(
        json.dumps(stable, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def wav_duration_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as handle:
        return handle.getnframes() / float(handle.getframerate())


def _extract_one(arguments: tuple[str, str, str]) -> str:
    source, engine, destination = arguments
    extract(Path(source), engine, Path(destination))
    return destination


def track_path(stem: str, engine: str) -> Path:
    return OUTPUTS / f"{stem}.{engine}.offline_track_v1.{OFFLINE_TRACK_REVISION}.json"


def ensure_tracks(source: Path, engines: list[str]) -> dict[str, Path]:
    """Eksik veya bayat motor izlerini paralel üret; güncel olanları yeniden kullan."""
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    binary = executable()
    freshness = max(source.stat().st_mtime, binary.stat().st_mtime)
    paths = {engine: track_path(source.stem, engine) for engine in engines}
    stale = [
        (str(source), engine, str(path))
        for engine, path in paths.items()
        if not path.is_file() or path.stat().st_mtime < freshness
    ]
    if stale:
        print(f"{len(stale)} motor izi yeniden üretiliyor: {', '.join(item[1] for item in stale)}")
        with ProcessPoolExecutor(max_workers=min(len(stale), 4)) as pool:
            list(pool.map(_extract_one, stale))
    else:
        print("Bütün motor izleri güncel; önbellekten kullanılıyor.")
    return paths


def build_payload(
    source: Path,
    engines: list[str],
    tracks: dict[str, dict[float, float]],
    reference: list[tuple[float, float]],
    reference_path: Path | None,
    *,
    cents_threshold: float,
    gap_seconds: float,
) -> dict[str, object]:
    events = build_events(tracks, reference, cents_threshold=cents_threshold)
    episodes = {name: group_episodes(events[name], gap_seconds=gap_seconds) for name in engines}
    summary = {}
    for name in engines:
        kinds = Counter(str(event["kind"]) for event in events[name])
        summary[name] = {
            "event_count": len(events[name]),
            "episode_count": len(episodes[name]),
            "kind_counts": dict(sorted(kinds.items())),
        }
    payload: dict[str, object] = {
        "schema": SCHEMA,
        "source": source.name,
        "source_sha256": file_sha256(source),
        "duration_seconds": round(wav_duration_seconds(source), 3),
        "engines": engines,
        "reference": reference_path.name if reference_path else None,
        "reference_frames": len(reference),
        "thresholds": {
            "divergence_cents": cents_threshold,
            "episode_gap_seconds": gap_seconds,
            "transition_slope_cents_per_second": TRANSITION_SLOPE_CENTS_PER_SECOND,
            "large_error_cents": LARGE_ERROR_CENTS,
        },
        "frames_per_engine": {name: len(tracks[name]) for name in engines},
        "summary": summary,
        "episodes": episodes,
        "events": events,
    }
    payload["fingerprint"] = fingerprint(payload)
    return payload


def render_review(payload: dict[str, object], tracks, reference, audio_relative: str | None) -> str:
    template = (ROOT / "scripts" / "pitch_divergence_review_template.html").read_text(encoding="utf-8")
    curves = {name: curve(tracks[name]) for name in payload["engines"]}
    curves["pyin"] = [[round(t, 3), round(_cents(hz, 440.0), 1)] for t, hz in reference]
    page = {
        "source": payload["source"],
        "duration": payload["duration_seconds"],
        "engines": payload["engines"],
        "events": payload["events"],
        "episodes": payload["episodes"],
        "curves": curves,
        "audio": audio_relative,
        "fingerprint": payload["fingerprint"],
    }
    blob = json.dumps(page, separators=(",", ":"), ensure_ascii=False)
    if "</script>" in blob:
        raise ValueError("Veri bloğu script etiketini kapatıyor.")
    return template.replace("__DATA__", blob)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="48 kHz mono WAV kaynağı")
    parser.add_argument("--engine", action="append", choices=sorted(ENGINES), default=None)
    parser.add_argument("--reference", type=Path, default=None, help="pYIN .vamp.json (varsayılan: yanındaki)")
    parser.add_argument("--cents", type=float, default=50.0, help="ayrışma eşiği (sent)")
    parser.add_argument("--gap", type=float, default=0.25, help="epizot birleştirme boşluğu (sn)")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--no-html", action="store_true")
    parser.add_argument(
        "--no-audio", action="store_true",
        help="sesi bağlamadan ikinci bir kopya yaz (paylaşım için)",
    )
    arguments = parser.parse_args()

    source = arguments.source.expanduser().resolve()
    if not source.is_file():
        parser.error(f"Kaynak bulunamadı: {source}")
    engines = arguments.engine or list(ENGINE_ORDER)

    paths = ensure_tracks(source, engines)
    tracks = {engine: load_track(path) for engine, path in paths.items()}

    reference_path = arguments.reference
    if reference_path is None:
        candidate = OUTPUTS / f"{source.stem}.vamp.json"
        reference_path = candidate if candidate.is_file() else None
    reference = load_reference(reference_path) if reference_path else []
    if not reference:
        print("Uyarı: pYIN referansı yok. Ayrışma haritası yine üretilir, referans sütunu boş kalır.")

    payload = build_payload(
        source, engines, tracks, reference, reference_path,
        cents_threshold=arguments.cents, gap_seconds=arguments.gap,
    )
    destination = arguments.output or OUTPUTS / f"{source.stem}.divergence-map.json"
    destination.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"\nKaynak      {payload['source']}  ({payload['duration_seconds']} sn)")
    print(f"Parmak izi  {payload['fingerprint'][:16]}…")
    print(f"Harita      {destination.relative_to(ROOT)}")
    print(f"\n{'motor':<20}{'olay':>6}{'epizot':>8}   sınıf dağılımı")
    for name in engines:
        row = payload["summary"][name]
        kinds = ", ".join(f"{key} {value}" for key, value in row["kind_counts"].items())
        print(f"{name:<20}{row['event_count']:>6}{row['episode_count']:>8}   {kinds}")

    if not arguments.no_html:
        try:
            audio_relative = str(Path(source).relative_to(ROOT))
            audio_relative = "../" + audio_relative
        except ValueError:
            audio_relative = None
        review = OUTPUTS / f"{source.stem}.divergence-review.html"
        review.write_text(render_review(payload, tracks, reference, audio_relative), encoding="utf-8")
        print(f"\nİnceleme sayfası  {review.relative_to(ROOT)}")
        print("Sesli dinleyip karara bağlamak için bu sayfayı yerel sunucudan aç.")
        if arguments.no_audio:
            shared = OUTPUTS / f"{source.stem}.divergence-review.shared.html"
            shared.write_text(render_review(payload, tracks, reference, None), encoding="utf-8")
            print(f"Sessiz paylaşım kopyası  {shared.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
