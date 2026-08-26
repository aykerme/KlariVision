#!/usr/bin/env python3
"""Kullanıcı hükümlerine karşı hızlı motor regresyon denetimi.

`data/annotations/*.verdicts.v1.json` içindeki hükümler bu kayıt için
gerçek-değer yerine geçer: her zaman aralığında her motor için "sorun yok" ya
da somut bir kusur yazılıdır.  Bu betik motorları yalnız o aralıkları kapsayan
kısa kliplerde koşar ve her hücrenin hâlâ kusurlu olup olmadığını söyler.

Neden klip: tam dosya dört motor için ~102 sn CPU ister.  Hükümlerin kapladığı
aralıklar 2 sn ön-yükleme ile birlikte ~100 sn eder, fakat klip × motor görevleri
bağımsız olduğu için hepsi paralel koşar ve duvar süresi tek haneli saniyeye iner.
Ön-yükleme şart: motorlar nedensel oturumdur, kontur sürekliliği ve release
mantığı geçmiş kare ister; klipleri birleştirmek yapay atak/sönüm üretir.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import wave
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from klarivision.pitch.cpp_engine import ENGINES, executable, extract

SCHEMA = "klarivision-quick-pitch-check-v1"
REFERENCE_SCHEMA = "klarivision-pitch-reference-v1"
ENGINE_ORDER = ("yin_v1", "pitch_engine_v2", "vpm_like", "hapt_v1")
HOP_SECONDS = 512 / 48_000

PREROLL_SECONDS = 2.0
TAIL_SECONDS = 0.5
SAMPLE_RATE_HZ = 48_000
HOP_SAMPLES = 512
# Aynı klibe girecek kadar yakın satırlar birleştirilir.
CLIP_MERGE_GAP_SECONDS = 0.0

# Bir kareyi "büyük" sapma saymak için gereken fark (oktav/on ikili bölgesi).
LARGE_DEVIATION_CENTS = 400.0
# Perde kaymasının başladığı fark.
PITCH_TOLERANCE_CENTS = 50.0
# Kayma sayılması için gereken ardışık kare (tek karelik gürültüyü eler).
KAYMA_MINIMUM_FRAMES = 2
# Bu motorun kapsaması, aynı pencerede en iyi motorun kapsamasının bu oranının
# altına düşerse boşluk sayılır.
RELATIVE_COVERAGE_RATIO = 0.75
# Bütün motorlar birlikte eksik yayın yapıyorsa mutlak kapı devreye girer.
ABSOLUTE_COVERAGE = 0.90
# "Sessiz olmalı" aralığında hoş görülen kare sayısı (kenar payı).
SILENT_TOLERANCE_FRAMES = 1
# Etiketli bir boşluğun onarılmış sayılması için gereken kapsama.
REPAIRED_COVERAGE = 0.90
# Koruma kapısında boşluk sayılması için gereken ardışık eksik kare.  Ölçümle
# seçildi: 1-2 karede kıyas gürültüsü sahte bulgu üretiyor, 3 karede (32 ms)
# gerçek delikler kalıyor.
GUARD_MISSING_RUN_FRAMES = 3


def cents(a: float, b: float) -> float:
    return 1200.0 * math.log2(a / b)


# ---------------------------------------------------------------- klip üretimi


def clip_blocks(rows: list[dict], duration: float) -> list[tuple[float, float]]:
    """Hükümleri kapsayan en kısa klip kümesi.

    Klip başlangıcı **hop sınırına yaslanır**.  Bu kozmetik değil: kare zamanları
    kaynağın sıfırıncı örneğinden itibaren hop adımıyla üretilir, bu yüzden
    rastgele bir ofsetten kesilen klip bütün analiz pencerelerini kaydırır ve
    motor tam dosyadakinden başka bir sonuç verir.  Hizalamasız ölçümde
    hücrelerin %44,4'ü tam dosyadan farklıydı; hizalamayla bu %1,2'ye indi.
    """
    blocks: list[list[float]] = []
    for row in sorted(rows, key=lambda item: item["start_seconds"]):
        start = max(0.0, float(row["start_seconds"]) - PREROLL_SECONDS)
        start = (int(start * SAMPLE_RATE_HZ) // HOP_SAMPLES) * HOP_SAMPLES / SAMPLE_RATE_HZ
        end = min(duration, float(row["end_seconds"]) + TAIL_SECONDS)
        if blocks and start - blocks[-1][1] <= CLIP_MERGE_GAP_SECONDS:
            blocks[-1][1] = max(blocks[-1][1], end)
        else:
            blocks.append([start, end])
    return [(a, b) for a, b in blocks]


def write_clip(source: Path, start: float, end: float, destination: Path) -> None:
    """Kaynaktan örnek-hassas bir parça kes.  Kaynak yalnız okunur."""
    with wave.open(str(source), "rb") as handle:
        rate = handle.getframerate()
        handle.setpos(int(round(start * rate)))
        frames = handle.readframes(int(round((end - start) * rate)))
        with wave.open(str(destination), "wb") as out:
            out.setnchannels(handle.getnchannels())
            out.setsampwidth(handle.getsampwidth())
            out.setframerate(rate)
            out.writeframes(frames)


def _run(job: tuple[str, str, str]) -> tuple[str, str]:
    clip, engine, destination = job
    extract(Path(clip), engine, Path(destination))
    return engine, destination


# --------------------------------------------------------------- değerlendirme


def frames_in(frames: list[dict], start: float, end: float) -> dict[float, float]:
    """Penceredeki sesli kareler: zaman → frekans."""
    return {
        round(f["time_seconds"], 4): f["frequency_hz"]
        for f in frames
        if start <= f["time_seconds"] <= end and f["voiced"] and f["frequency_hz"] > 0
    }


def slot_count(start: float, end: float) -> int:
    return max(1, int(round((end - start) / HOP_SECONDS)) + 1)


def row_expectation(verdicts: dict[str, str]) -> str:
    """Aralığın kendisi sesli mi sessiz mi olmalı — hükümlerden türetilir."""
    return "silent" if any(code == "kacak" for code in verdicts.values()) else "voiced"


def longest_missing_run(row: dict, voiced: dict[str, dict[float, float]],
                        name: str, engines: list[str]) -> int:
    """Bu motorun sessiz, en az iki başka motorun sesli olduğu en uzun dilim."""
    start, end = float(row["start_seconds"]), float(row["end_seconds"])
    others = [item for item in engines if item != name]
    best = run = 0
    for index in range(slot_count(start, end)):
        moment = start + index * HOP_SECONDS
        near = lambda table: any(abs(t - moment) <= HOP_SECONDS * 0.6 for t in table)
        if not near(voiced[name]) and sum(1 for o in others if near(voiced[o])) >= 2:
            run += 1
            best = max(best, run)
        else:
            run = 0
    return best


def build_reference(row: dict, voiced: dict[str, dict[float, float]],
                    engines: list[str]) -> dict[float, float]:
    """Bir aralığın perde referansı: o satırda "sorun yok" denen motorların medyanı.

    Bu referans **dondurulur** ve `data/annotations/*.reference.v1.json` içine
    yazılır.  Her koşuda yeniden hesaplanırsa bir motorun düzeltilmesi bütün
    diğer motorların puanını da oynatır (ölçümde VPM düzeltilince YIN'in skoru
    hiç dokunulmadığı hâlde 35'ten 36'ya çıktı) ve karşılaştırma anlamsızlaşır.
    """
    if row_expectation(row["verdicts"]) != "voiced":
        return {}
    clean = [name for name in engines if row["verdicts"].get(name) == "yok"]
    reference: dict[float, float] = {}
    for moment in sorted({t for name in clean for t in voiced[name]}):
        values = [voiced[name][moment] for name in clean if moment in voiced[name]]
        if values:
            reference[moment] = statistics.median(values)
    return reference


def evaluate_row(row: dict, voiced: dict[str, dict[float, float]], engines: list[str],
                 frozen_reference: dict[float, float] | None = None) -> dict[str, dict]:
    """Bir aralıkta her motorun durumunu, hükmün türüne göre ayrı ayrı sına.

    Değerlendirme bilerek **asimetriktir**:

    * Kullanıcının kusur işaretlediği hücrede soru "o kusur gitti mi" — ölçüt
      doğrudan işaretin kendisidir.  Bu şart, çünkü 14 satırda dört motor birden
      susuyor; orada motorlar arası kıyas hiçbir şey söyleyemez, sesin var
      olduğunu yalnız kullanıcı biliyor.
    * "Sorun yok" denen hücrede soru "yeni ve büyük bir kusur belirdi mi" —
      ölçüt motorlar arası kıyastır.  Bu hücreler kusursuzluk beyanı değildir;
      kullanıcı o satırda **başka** motoru işaretlerken bunlara dokunmamıştır.
      Bu yüzden burada dar bir eşik kullanmak sahte regresyon üretir.

    Perde karşılaştırması kare karedir.  Pencere medyanı yanlıştı: işaretlenen
    oktav sıçramaları çoğu 2-3 karelik ani tepelerdir ve medyanın içinde
    kayboluyordu (13 etiketli oktav hatası böyle gözden kaçmıştı).
    """
    verdicts = row["verdicts"]
    start, end = float(row["start_seconds"]), float(row["end_seconds"])
    expectation = row_expectation(verdicts)
    slots = slot_count(start, end)

    reference = frozen_reference if frozen_reference is not None else {}

    results: dict[str, dict] = {}
    for name in engines:
        expected = verdicts.get(name, "")
        coverage = len(voiced[name]) / slots
        deviations = [
            cents(frequency, reference[moment])
            for moment, frequency in sorted(voiced[name].items())
            if moment in reference
        ]
        worst = max((abs(d) for d in deviations), default=0.0)
        has_octave = any(abs(d) > LARGE_DEVIATION_CENTS for d in deviations)
        run = 0
        has_drift = False
        for d in deviations:
            run = run + 1 if abs(d) > PITCH_TOLERANCE_CENTS else 0
            if run >= KAYMA_MINIMUM_FRAMES:
                has_drift = True
                break

        if expected in ("", "yok"):
            # Koruma kapısı: yalnız büyük ve açık kusurlar sayılır.
            broken: list[str] = []
            if expectation == "silent" and len(voiced[name]) > SILENT_TOLERANCE_FRAMES:
                broken.append("kacak")
            if has_octave:
                broken.append("oktav")
            if longest_missing_run(row, voiced, name, engines) >= GUARD_MISSING_RUN_FRAMES:
                broken.append("bosluk")
            results[name] = {"expected": "yok", "role": "koruma",
                             "state": "bozuldu" if broken else "korundu",
                             "problems": broken, "coverage": round(coverage, 3),
                             "worst_cents": round(worst, 1)}
            continue

        # Etiketli kusur: tam olarak o kusur hâlâ duruyor mu?
        if expected == "bosluk":
            still = coverage < REPAIRED_COVERAGE
        elif expected == "kacak":
            still = len(voiced[name]) > SILENT_TOLERANCE_FRAMES
        elif expected in ("oktav", "kayma"):
            if not reference:
                # Referans olmadan perde kusuru ölçülemez.  Bunu "gitti"
                # saymak, aracın ölçemediği yerde başarı raporlaması demekti.
                results[name] = {"expected": expected, "role": "etiketli",
                                 "state": "ölçülemedi", "problems": [],
                                 "coverage": round(coverage, 3),
                                 "worst_cents": round(worst, 1)}
                continue
            still = has_octave if expected == "oktav" else (has_octave or has_drift)
        else:  # titrek — güvenilir otomatik ölçütü yok
            results[name] = {"expected": expected, "role": "etiketli", "state": "ölçülmedi",
                             "problems": [], "coverage": round(coverage, 3),
                             "worst_cents": round(worst, 1)}
            continue
        results[name] = {"expected": expected, "role": "etiketli",
                         "state": "duruyor" if still else "gitti",
                         "problems": [expected] if still else [],
                         "coverage": round(coverage, 3), "worst_cents": round(worst, 1)}
    return results


# ------------------------------------------------------------------------ akış


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verdicts", type=Path,
                        default=ROOT / "data/annotations/sukru-tunar-ussak-taksim.verdicts.v1.json")
    parser.add_argument("--source", type=Path, default=None, help="varsayılan: hüküm dosyasındaki kaynak")
    parser.add_argument("--engine", action="append", choices=sorted(ENGINES), default=None)
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=ROOT / "outputs/quick-pitch-check.json")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--refresh-reference", action="store_true",
                        help="perde referansını bu koşudan yeniden dondur (yalnız dört motor koşarken)")
    parser.add_argument("--reuse-tracks", action="store_true",
                        help="motorları yeniden koşma, son koşunun izlerini kullan (yalnız puanlama)")
    arguments = parser.parse_args()

    payload = json.loads(arguments.verdicts.read_text(encoding="utf-8"))
    rows = payload["rows"]
    engines = arguments.engine or list(ENGINE_ORDER)
    source = arguments.source or (ROOT / "data/audio" / payload["source"])
    if not source.is_file():
        parser.error(f"Kaynak bulunamadı: {source}")

    with wave.open(str(source), "rb") as handle:
        duration = handle.getnframes() / float(handle.getframerate())

    started = time.perf_counter()
    blocks = clip_blocks(rows, duration)
    audio_seconds = sum(b - a for a, b in blocks)

    cached = ROOT / "outputs" / f"{source.stem}.quick-tracks.json"
    if arguments.reuse_tracks and cached.is_file():
        stored = json.loads(cached.read_text(encoding="utf-8"))
        tracks = {engine: stored["tracks"][engine] for engine in engines}
        blocks = blocks  # yalnız raporlama için
        return finish(arguments, payload, rows, engines, source, tracks, blocks,
                      audio_seconds, started)

    work = Path(tempfile.mkdtemp(prefix="klarivision-quick-"))
    try:
        jobs = []
        clip_paths = []
        for index, (a, b) in enumerate(blocks):
            clip = work / f"clip{index:03d}.wav"
            write_clip(source, a, b, clip)
            clip_paths.append((a, b, clip))
            for engine in engines:
                jobs.append((str(clip), engine, str(work / f"clip{index:03d}.{engine}.json")))

        with ProcessPoolExecutor(max_workers=max(1, arguments.workers)) as pool:
            list(pool.map(_run, jobs))

        # Klip-yerel kare zamanlarını kaynak zamanına geri taşı.
        tracks: dict[str, list[dict]] = {engine: [] for engine in engines}
        for index, (a, _b, _clip) in enumerate(clip_paths):
            for engine in engines:
                data = json.loads((work / f"clip{index:03d}.{engine}.json").read_text(encoding="utf-8"))
                for frame in data.get("frames", []):
                    tracks[engine].append({
                        "time_seconds": frame["time_seconds"] + a,
                        "frequency_hz": float(frame.get("frequency_hz") or 0.0),
                        "voiced": bool(frame.get("voiced")),
                    })
        for engine in engines:
            tracks[engine].sort(key=lambda item: item["time_seconds"])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    cache = ROOT / "outputs" / f"{source.stem}.quick-tracks.json"
    cache.write_text(json.dumps({"engines": engines, "tracks": tracks}), encoding="utf-8")

    return finish(arguments, payload, rows, engines, source, tracks, blocks,
                  audio_seconds, started)


def finish(arguments, payload, rows, engines, source, tracks, blocks, audio_seconds, started):

    reference_path = (ROOT / "data/annotations" /
                      f"{Path(payload['source']).stem}.reference.v1.json")
    frozen: dict[str, dict[float, float]] = {}
    if reference_path.is_file() and not arguments.refresh_reference:
        stored = json.loads(reference_path.read_text(encoding="utf-8"))
        frozen = {key: {float(t): hz for t, hz in table.items()}
                  for key, table in stored["rows"].items()}
    else:
        if len(engines) < len(ENGINE_ORDER):
            raise SystemExit(
                "Referans dondurulmamış. Önce dört motorla koş:\n"
                "  scripts/quick_pitch_check.py --refresh-reference"
            )
        for row in rows:
            voiced = {engine: frames_in(tracks[engine], row["start_seconds"], row["end_seconds"])
                      for engine in engines}
            frozen[str(row["index"])] = build_reference(row, voiced, engines)
        reference_path.parent.mkdir(parents=True, exist_ok=True)
        reference_path.write_text(json.dumps({
            "schema": REFERENCE_SCHEMA,
            "source": payload["source"],
            "verdicts": arguments.verdicts.name,
            "note": ("Perde referansı: her satırda 'sorun yok' denen motorların kare kare "
                     "medyanı.  Bir kez dondurulur; aksi hâlde bir motoru düzeltmek bütün "
                     "diğer motorların puanını da oynatır."),
            "rows": {key: {str(t): hz for t, hz in table.items()} for key, table in frozen.items()},
        }, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Perde referansı donduruldu: {reference_path.relative_to(ROOT)}")

    evaluated = []
    totals = {engine: Counter() for engine in engines}
    recall = {engine: Counter() for engine in engines}
    guard = {engine: Counter() for engine in engines}
    for row in rows:
        voiced = {
            engine: frames_in(tracks[engine], row["start_seconds"], row["end_seconds"])
            for engine in engines
        }
        result = evaluate_row(row, voiced, engines, frozen.get(str(row["index"]), {}))
        evaluated.append({"index": row["index"], "start_seconds": row["start_seconds"],
                          "end_seconds": row["end_seconds"], "engines": result})
        for engine, cell in result.items():
            if cell["role"] == "etiketli":
                recall[engine][cell["state"]] += 1
                if cell["state"] == "duruyor":
                    totals[engine][cell["expected"]] += 1
            else:
                guard[engine][cell["state"]] += 1
                for problem in cell["problems"]:
                    guard[engine]["yeni:" + problem] += 1

    elapsed = time.perf_counter() - started
    report = {
        "schema": SCHEMA,
        "source": source.name,
        "verdicts": arguments.verdicts.name,
        "engines": engines,
        "row_count": len(rows),
        "clip_count": len(blocks),
        "audio_seconds": round(audio_seconds, 1),
        "wall_seconds": round(elapsed, 2),
        "remaining_defects": {engine: dict(sorted(totals[engine].items())) for engine in engines},
        "labelled": {engine: dict(recall[engine]) for engine in engines},
        "guard": {engine: dict(guard[engine]) for engine in engines},
        "rows": evaluated,
    }
    destination = arguments.output.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"{len(blocks)} klip · {audio_seconds:.0f} sn ses · {len(engines)} motor · "
          f"{elapsed:.1f} sn duvar süresi\n")
    print(f"{'motor':<20}{'etiketli':>9}{'duruyor':>9}{'gitti':>7}{'ölçülmedi':>11}   kalan kusurlar")
    for engine in engines:
        r = recall[engine]
        labelled = r["duruyor"] + r["gitti"] + r["ölçülmedi"]
        detail = ", ".join(f"{k} {v}" for k, v in sorted(totals[engine].items()))
        print(f"{engine:<20}{labelled:>9}{r['duruyor']:>9}{r['gitti']:>7}"
              f"{r['ölçülmedi']:>11}   {detail or '—'}")

    print(f"\n{'motor':<20}{'koruma hücresi':>15}{'bozuldu':>9}   yeni kusurlar")
    for engine in engines:
        g = guard[engine]
        total = g["korundu"] + g["bozuldu"]
        detail = ", ".join(f"{k[5:]} {v}" for k, v in sorted(g.items()) if k.startswith("yeni:"))
        print(f"{engine:<20}{total:>15}{g['bozuldu']:>9}   {detail or '—'}")

    if arguments.baseline and arguments.baseline.is_file():
        base = json.loads(arguments.baseline.read_text(encoding="utf-8"))
        print(f"\n{'motor':<20}{'taban':>7}{'şimdi':>7}{'fark':>7}")
        worse = False
        for engine in engines:
            before = base["labelled"].get(engine, {}).get("duruyor", 0)
            after = recall[engine]["duruyor"]
            mark = "" if after <= before else "  ← KÖTÜLEŞTİ"
            worse = worse or after > before
            print(f"{engine:<20}{before:>7}{after:>7}{after-before:>+7}{mark}")
        for engine in engines:
            before = base["guard"].get(engine, {}).get("bozuldu", 0)
            after = guard[engine]["bozuldu"]
            if after > before:
                worse = True
                print(f"  koruma kapısı {engine}: {before} → {after}  ← YENİ KUSUR")
        if worse:
            print("\nRegresyon var.")
            raise SystemExit(1)
        print("\nRegresyon yok.")

    try:
        shown = destination.relative_to(ROOT)
    except ValueError:
        shown = destination
    print(f"\nRapor  {shown}")


if __name__ == "__main__":
    main()
