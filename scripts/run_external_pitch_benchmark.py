#!/usr/bin/env python3
"""Bu takım bir *iddia kapısıdır, ayar hedefi değildir.*

Klarnet yargıçları (donmuş dinleyici kararları, oktav tuzağı paketi, sentetik
turnuva) neyi optimize ettiğimizi söyler. Bu küme neyi bozmadığımızı söyler --
ve motorun hiç görmediği veride. Buradaki sayılar kaydedilir ve gerilememesi
beklenir; **doğrudan onlara karşı ayar yapılmaz.** Bir eşiği bu tablonun
sayılarına bakarak seçmek, tablonun tek işlevini yok eder.

Bakılacak sayı **RPA - RCA** farkıdır. Raw pitch accuracy perdeyi tam olarak
ister; raw chroma accuracy oktavı bağışlar. Aradaki fark, tanımı gereği oktav
hata oranıdır -- yani bu projenin varlık sebebi olan büyüklüğün, ayarlanmamış
veride ölçülmüş hâli.

Kullanım:

    .venv/bin/python scripts/run_external_pitch_benchmark.py
    .venv/bin/python scripts/run_external_pitch_benchmark.py --dataset vocadito --limit 5
    .venv/bin/python scripts/run_external_pitch_benchmark.py --engine unified_v1 --engine yin_v1
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from pitch_tournament_engines import run_engines  # noqa: E402
from run_pitch_engine_tournament import read_wav  # noqa: E402

EXTERNAL = ROOT / "data/external"
CONTRACT_RATE = 48_000


@dataclass(frozen=True)
class Dataset:
    """Bir kümenin ses ve referans dosyalarının nasıl eşleştiğini tarif eder."""

    name: str
    audio_glob: str
    annotation_dir: str
    #: Ses dosyasının adından referans dosyasının adını üretir.
    annotation_suffix: str = ".csv"
    audio_suffix_strip: str = ".wav"
    annotation_prefix_strip: str = ""
    note: str = ""


DATASETS: tuple[Dataset, ...] = (
    Dataset(
        name="mdb_stem_synth",
        audio_glob="mdb_stem_synth/MDB-stem-synth/audio_stems/*.wav",
        annotation_dir="mdb_stem_synth/MDB-stem-synth/annotation_stems",
        note="Çok enstrümanlı, yeniden sentezlenmiş kusursuz f0 referansı. "
        "'Genel amaçlı' iddiasının asıl sınavı.",
    ),
    Dataset(
        name="bach10_mf0_synth",
        audio_glob="bach10_mf0_synth/Bach10-mf0-synth/audio_stems/*.wav",
        annotation_dir="bach10_mf0_synth/Bach10-mf0-synth/annotation_stems",
        note="Nefesli ve yaylı stem'ler; klarnet stem'leri de içerir.",
    ),
    Dataset(
        name="vocadito",
        audio_glob="vocadito/Audio/*.wav",
        annotation_dir="vocadito/Annotations/F0",
        annotation_suffix="_f0.csv",
        note="Vokal. Klarnetten tamamen farklı bir tını ve harmonik dağılım.",
    ),
)


@dataclass
class FileResult:
    dataset: str
    source: str
    engine: str
    metrics: dict[str, float] = field(default_factory=dict)


def resample_to_contract(audio: np.ndarray, rate: int) -> np.ndarray:
    """Doğrusal yeniden örnekleme.

    Motor sözleşmesi 48 kHz; bu kümeler 44,1 kHz. Perde tahmini için doğrusal
    ara değerleme yeterlidir: getirdiği hata bant genişliğinin en üstünde
    kalır, oysa ölçülen temeller 2 kHz'in altındadır.
    """
    if rate == CONTRACT_RATE:
        return audio
    duration = len(audio) / rate
    target_count = int(round(duration * CONTRACT_RATE))
    source_times = np.arange(len(audio)) / rate
    target_times = np.arange(target_count) / CONTRACT_RATE
    return np.interp(target_times, source_times, audio)


HOP_SECONDS = 512 / CONTRACT_RATE


def on_hop_grid(frames, duration: float) -> tuple[np.ndarray, np.ndarray]:
    """Motor izini düzenli bir hop ızgarasına oturtur, boşlukları 0 Hz yapar.

    Bu adım şart. Eski motorlar sessiz bir kareyi hiç yayımlamaz -- izlerinde o
    kare yoktur, sıfır olarak değil. `mir_eval` böyle bir izi ara değerlerken
    boşluğun iki ucunu birleştirir ve arada kalan her şeyi ötümlü sayar, ki bu
    da ötüm yanlış-alarmını neredeyse 1,0 gösterir ve karşılaştırmayı anlamsız
    kılar. Izgaraya oturtmak, "kare yok" ile "kare sessiz"i aynı şeye çevirir --
    ki iki motorun karşılaştırılabilmesi için olması gereken de budur.
    """
    count = max(1, int(np.floor(duration / HOP_SECONDS)) + 1)
    times = np.arange(count) * HOP_SECONDS
    hz = np.zeros(count)
    for frame in frames:
        if not frame[1]:
            continue
        index = int(round(frame[0] / HOP_SECONDS))
        if 0 <= index < count:
            hz[index] = frame[1]
    return times, hz


def read_reference(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """`time,frequency` CSV; 0 Hz ötümsüz demektir."""
    raw = np.loadtxt(path, delimiter=",", ndmin=2)
    return raw[:, 0], raw[:, 1]


def annotation_for(dataset: Dataset, audio_path: Path) -> Path:
    stem = audio_path.name
    if stem.endswith(dataset.audio_suffix_strip):
        stem = stem[: -len(dataset.audio_suffix_strip)]
    return EXTERNAL / dataset.annotation_dir / f"{stem}{dataset.annotation_suffix}"


def score(
    reference_times: np.ndarray,
    reference_hz: np.ndarray,
    estimate_times: np.ndarray,
    estimate_hz: np.ndarray,
) -> dict[str, float]:
    import mir_eval

    ref_voicing, ref_cent, est_voicing, est_cent = mir_eval.melody.to_cent_voicing(
        reference_times, reference_hz, estimate_times, estimate_hz
    )
    recall, false_alarm = mir_eval.melody.voicing_measures(ref_voicing, est_voicing)
    raw_pitch = mir_eval.melody.raw_pitch_accuracy(ref_voicing, ref_cent, est_voicing, est_cent)
    raw_chroma = mir_eval.melody.raw_chroma_accuracy(ref_voicing, ref_cent, est_voicing, est_cent)
    overall = mir_eval.melody.overall_accuracy(ref_voicing, ref_cent, est_voicing, est_cent)

    # Gross pitch error: ötümlü ve tespit edilmiş karelerde 50 sentten büyük
    # sapma oranı. mir_eval bunu ayrı bir ölçüt olarak vermiyor.
    both = (ref_voicing > 0) & (est_voicing > 0)
    gross = float(np.mean(np.abs(ref_cent[both] - est_cent[both]) > 50.0)) if both.any() else 0.0

    return {
        "raw_pitch_accuracy": float(raw_pitch),
        "raw_chroma_accuracy": float(raw_chroma),
        # Perdeyi tam isteyen ölçüt ile oktavı bağışlayan ölçüt arasındaki
        # fark: oktav hata oranı.
        "octave_error_rate": float(raw_chroma - raw_pitch),
        "gross_pitch_error": gross,
        "voicing_recall": float(recall),
        "voicing_false_alarm": float(false_alarm),
        "overall_accuracy": float(overall),
    }


def evaluate_dataset(
    dataset: Dataset, engines: list[str] | None, limit: int | None
) -> list[FileResult]:
    audio_files = sorted(EXTERNAL.glob(dataset.audio_glob))
    if not audio_files:
        print(f"ATLANDI {dataset.name}: ses bulunamadı ({dataset.audio_glob})")
        return []
    if limit:
        # Deterministik alt örnekleme: aynı çağrı hep aynı dosyaları seçer.
        step = max(1, len(audio_files) // limit)
        audio_files = audio_files[::step][:limit]

    results: list[FileResult] = []
    for index, audio_path in enumerate(audio_files, start=1):
        annotation_path = annotation_for(dataset, audio_path)
        if not annotation_path.is_file():
            print(f"  atlandı (referans yok): {audio_path.name}")
            continue
        try:
            audio, rate = read_wav(audio_path)
        except ValueError as error:
            print(f"  atlandı ({error}): {audio_path.name}")
            continue
        audio = resample_to_contract(audio, rate)
        reference_times, reference_hz = read_reference(annotation_path)
        if not np.any(reference_hz > 0):
            continue  # tamamen ötümsüz stem; ölçecek bir şey yok

        traces = run_engines(audio, CONTRACT_RATE)
        for name, trace in traces.items():
            if engines and name not in engines:
                continue
            times, hz = on_hop_grid(trace.frames, len(audio) / CONTRACT_RATE)
            results.append(
                FileResult(dataset.name, audio_path.name, name, score(reference_times, reference_hz, times, hz))
            )
        print(f"  [{index}/{len(audio_files)}] {audio_path.name}")
    return results


def aggregate(results: list[FileResult]) -> dict[tuple[str, str], dict[str, float]]:
    grouped: dict[tuple[str, str], list[dict[str, float]]] = {}
    for result in results:
        grouped.setdefault((result.dataset, result.engine), []).append(result.metrics)
    return {
        key: {metric: float(np.mean([m[metric] for m in rows])) for metric in rows[0]}
        for key, rows in grouped.items()
    }


def markdown_report(summary: dict[tuple[str, str], dict[str, float]]) -> str:
    lines = [
        "# Dış perde karşılaştırması",
        "",
        "Bu tablo bir **iddia kapısıdır, ayar hedefi değildir.** Sayılar kaydedilir",
        "ve gerilememesi beklenir; doğrudan onlara karşı ayar yapılmaz.",
        "",
        "**RPA − RCA** farkı, tanımı gereği oktav hata oranıdır: raw pitch accuracy",
        "perdeyi tam ister, raw chroma accuracy oktavı bağışlar.",
        "",
    ]
    for dataset in sorted({key[0] for key in summary}):
        note = next((d.note for d in DATASETS if d.name == dataset), "")
        lines += [f"## {dataset}", "", note, "",
                  "| Motor | RPA | RCA | **Oktav hatası** | GPE | Ötüm recall | Yanlış alarm | Genel |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|"]
        rows = [(engine, summary[(dataset, engine)]) for d, engine in summary if d == dataset]
        for engine, metrics in sorted(rows, key=lambda row: row[1]["octave_error_rate"]):
            lines.append(
                f"| {engine} | {metrics['raw_pitch_accuracy']:.4f} | {metrics['raw_chroma_accuracy']:.4f} "
                f"| **{metrics['octave_error_rate']:.4f}** | {metrics['gross_pitch_error']:.4f} "
                f"| {metrics['voicing_recall']:.4f} | {metrics['voicing_false_alarm']:.4f} "
                f"| {metrics['overall_accuracy']:.4f} |"
            )
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", action="append", help="yalnız bu kümeyi koş")
    parser.add_argument("--engine", action="append", help="yalnız bu motoru koş")
    parser.add_argument("--limit", type=int, help="küme başına dosya sayısını sınırla")
    parser.add_argument("--output", type=Path, default=ROOT / "outputs/external-pitch-benchmark.json")
    parser.add_argument("--markdown", type=Path, default=ROOT / "outputs/external-pitch-benchmark.md")
    args = parser.parse_args()

    selected = [d for d in DATASETS if not args.dataset or d.name in args.dataset]
    started = time.time()
    results: list[FileResult] = []
    for dataset in selected:
        print(f"{dataset.name}:")
        results.extend(evaluate_dataset(dataset, args.engine, args.limit))

    if not results:
        print("Hiçbir küme ölçülemedi. Önce indirin:")
        print("  .venv/bin/python scripts/fetch_external_pitch_datasets.py --list")
        return 0

    summary = aggregate(results)
    payload = {
        "schema": "klarivision-external-pitch-benchmark-v1",
        "policy": "assertion-gate-never-a-tuning-target",
        "datasets": [d.name for d in selected],
        "file_count": len({(r.dataset, r.source) for r in results}),
        "summary": {f"{key[0]}::{key[1]}": value for key, value in summary.items()},
        "files": [
            {"dataset": r.dataset, "source": r.source, "engine": r.engine, **r.metrics}
            for r in results
        ],
    }
    fingerprint = hashlib.sha256(
        json.dumps(payload, sort_keys=True).encode("utf-8")
    ).hexdigest()
    payload["fingerprint"] = fingerprint

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    args.markdown.write_text(markdown_report(summary))

    print()
    print(markdown_report(summary))
    print(f"dosya={payload['file_count']} süre={time.time() - started:.1f}s fingerprint={fingerprint}")
    print(args.output)
    print(args.markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
