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
    .venv/bin/python scripts/run_external_pitch_benchmark.py --engine unified_v1
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

sys.path.insert(0, str(ROOT / "src"))

EXTERNAL = ROOT / "data/external"
CONTRACT_RATE = 48_000
# Bölme manifesti: scripts/split_external_pitch_datasets.py üretir. Hangi
# dosyaya bakmaya hakkımız olduğunu tanımlar; olmadan --split kullanılamaz.
SPLIT_MANIFEST = ROOT / "data/benchmarks/external-pitch-split-v1.json"


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

# pYIN, aday motorlardan biri değil: çevrimdışı, tüm parçayı görerek çalışan bir
# **referans tavanıdır**. Araştırma raporu onu "ulaşılabilir en iyi" olarak
# tanımlıyor ve donmuş dinleyici kararlarında 85 aralığın hiçbirinde oktav
# hatası yapmıyor. Tablodaki işlevi bir rakip değil, bir mesafe ölçüsüdür:
# nedensel bir motorun ne kadar yaklaşabildiğini gösterir.
#
# Aralık, `unified_v1`'in kestirici aralığıyla eşitlenir. pYIN'i kendisine
# verilmemiş bir aralıktan sorumlu tutmak karşılaştırmayı bozar.
PYIN_MINIMUM_HZ = 65.0
PYIN_MAXIMUM_HZ = 2_400.0


def librosa_pyin_frames(audio: np.ndarray) -> list[tuple[float, float | None]] | None:
    """librosa'nın pYIN'i. Kurulu değilse None döner."""
    try:
        import librosa
    except ImportError:
        return None
    hop = 512
    f0, voiced, _ = librosa.pyin(
        audio.astype(np.float32),
        fmin=PYIN_MINIMUM_HZ,
        fmax=PYIN_MAXIMUM_HZ,
        sr=CONTRACT_RATE,
        frame_length=2_048,
        hop_length=hop,
    )
    times = librosa.times_like(f0, sr=CONTRACT_RATE, hop_length=hop)
    return [
        (float(t), float(hz) if flag and np.isfinite(hz) else None)
        for t, hz, flag in zip(times, f0, voiced)
    ]


def vamp_pyin_frames(audio_path: Path) -> list[tuple[float, float | None]] | None:
    """Sonic Annotator üzerinden native Vamp pYIN. Kurulu değilse None döner."""
    try:
        from klarivision.pitch.models import AudioSource
        from klarivision.pitch.vamp_pyin import VampPyinPitchExtractor
    except ImportError:
        return None
    extractor = VampPyinPitchExtractor()
    if not extractor.available():
        return None
    try:
        track = extractor.extract(AudioSource(path=audio_path))
    except Exception:  # noqa: BLE001 - eksik eklenti tabloyu düşürmemeli
        return None
    return [
        (float(t), float(hz) if bool(v) else None)
        for t, hz, v in zip(track.time_seconds, track.frequency_hz, track.voiced)
    ]


def on_hop_grid(frames, duration: float) -> tuple[np.ndarray, np.ndarray]:
    """Motor izini düzenli bir hop ızgarasına oturtur, boşlukları 0 Hz yapar.

    Bu adım şart. Motor sessiz bir kareyi hiç yayımlamaz -- izinde o kare
    yoktur, sıfır olarak değil. `mir_eval` böyle bir izi ara değerlerken
    boşluğun iki ucunu birleştirir ve arada kalan her şeyi ötümlü sayar, ki bu
    da ötüm yanlış-alarmını neredeyse 1,0 gösterir ve karşılaştırmayı anlamsız
    kılar. Izgaraya oturtmak, "kare yok" ile "kare sessiz"i aynı şeye çevirir.

    **Izgara motorun ilk karesine demirlenir, sıfıra değil.** Bu bir üslup
    tercihi değil: motorun zaman damgası analiz penceresinin *merkezi*, yani
    sıfır tabanlı hop ızgarasının tam yarısıdır. `round(t / hop)` böyle bir
    değeri yuvarlarken karar, izin metinde 8 ondalığa yuvarlanmasının hangi
    tarafa düştüğüne kalır; ardışık iki kare aynı yuvaya düşer ve aralarındaki
    yuva 0 Hz (= ötümsüz) kalır. Ölçüldü: 1994 yayımlanmış kare 1336 yuvaya
    iniyordu, yani her üç kareden biri **puanlanmadan önce** siliniyordu ve
    tabloya motorun kusuru gibi yansıyordu (bkz. docs/TEST_BASELINE.md).
    Kareler tam bir hop aralıklı olduğu için `(t - t0) / hop` tam sayıdır ve
    demirlenmiş ızgarada belirsizlik kalmaz.
    """
    # Motor izleri (zaman, hz, güven), pYIN izleri (zaman, hz) verir; ikisi de
    # buradan geçtiği için indeksle okunur, açarak değil.
    voiced = [(float(frame[0]), float(frame[1])) for frame in frames if frame[1]]
    if not voiced:
        count = max(1, int(np.floor(duration / HOP_SECONDS)) + 1)
        return np.arange(count) * HOP_SECONDS, np.zeros(count)

    # Izgara izin FAZINA kilitlenir, ilk karesine değil. Faza kilitlemek
    # indeksi tam sayı yapar; ızgarayı yine de sıfırdan başlatmak, dosyanın
    # başındaki sessizliğin kapsam içinde kalmasını sağlar. İlk *ötümlü*
    # kareden başlatmak ikisini karıştırır: ölçüldü, baştaki sessizlik
    # ızgaradan düşünce mir_eval o bölgeyi ötümlü sayıyor ve yanlış alarm
    # pYIN referansında bile 0,025'ten 0,124'e çıkıyordu.
    phase = voiced[0][0] % HOP_SECONDS
    # Zaten ızgarada olan bir iz (pYIN referansları böyle) faz olarak
    # 3e-18 gibi bir kayan nokta artığı verir. Sıfır saymazsak mir_eval
    # başa bir t=0 örneği ekler, sonra zamanları 10 ondalığa yuvarlar ve
    # iki sıfır yan yana gelir: "Expect x to not have duplicates". Bir
    # nanosaniye, gerçek hiçbir damga farkının altında, her artığın üstünde.
    if phase < 1e-9 or HOP_SECONDS - phase < 1e-9:
        phase = 0.0
    span = max(duration, voiced[-1][0]) - phase
    count = max(1, int(np.floor(span / HOP_SECONDS)) + 1)
    times = phase + np.arange(count) * HOP_SECONDS
    hz = np.zeros(count)
    for time, frequency in voiced:
        index = int(round((time - phase) / HOP_SECONDS))
        if 0 <= index < count:
            hz[index] = frequency
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


def load_split(section: str) -> dict[str, set[str]]:
    """Manifestten bir bölümün dosya adlarını küme başına okur."""
    if not SPLIT_MANIFEST.is_file():
        raise SystemExit(
            "Bölme manifesti yok. Önce:\n"
            "  .venv/bin/python scripts/split_external_pitch_datasets.py"
        )
    payload = json.loads(SPLIT_MANIFEST.read_text(encoding="utf-8"))
    return {
        name: set(entry[section]) for name, entry in payload["datasets"].items()
    }


def evaluate_dataset(
    dataset: Dataset,
    engines: list[str] | None,
    limit: int | None,
    skip_reference: bool = False,
    allowed: set[str] | None = None,
) -> list[FileResult]:
    audio_files = sorted(EXTERNAL.glob(dataset.audio_glob))
    if not audio_files:
        print(f"ATLANDI {dataset.name}: ses bulunamadı ({dataset.audio_glob})")
        return []
    if allowed is not None:
        audio_files = [path for path in audio_files if path.name in allowed]
        if not audio_files:
            print(f"  bu bölümde {dataset.name} dosyası yok")
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

        duration = len(audio) / CONTRACT_RATE
        candidates: dict[str, list] = {
            name: trace.frames for name, trace in run_engines(audio, CONTRACT_RATE).items()
        }
        if not skip_reference:
            vamp = vamp_pyin_frames(audio_path)
            if vamp is not None:
                candidates["pyin_vamp (referans)"] = vamp
            librosa_frames = librosa_pyin_frames(audio)
            if librosa_frames is not None:
                candidates["pyin_librosa (referans)"] = librosa_frames

        for name, frames in candidates.items():
            if engines and name not in engines:
                continue
            times, hz = on_hop_grid(frames, duration)
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


def markdown_report(summary: dict[tuple[str, str], dict[str, float]], split: str | None = None) -> str:
    lines = [
        "# Dış perde karşılaştırması",
        "",
        "Bu tablo bir **iddia kapısıdır, ayar hedefi değildir.** Sayılar kaydedilir",
        "ve gerilememesi beklenir; doğrudan onlara karşı ayar yapılmaz.",
        "",
        "**RPA − RCA** farkı, tanımı gereği oktav hata oranıdır: raw pitch accuracy",
        "perdeyi tam ister, raw chroma accuracy oktavı bağışlar.",
        "",
        # Bölüm adı tablonun parçasıdır: hangi veriye bakıldığı yazmıyorsa,
        # tablo bir iddiayı destekliyor mu yoksa ona göre mi ayarlandı,
        # ayırt edilemez.
        f"Bölüm: **{split or 'bölme yok — bütün dosyalar'}**"
        + ("  (donmuş; ayar hedefi değildir)" if split == "holdout" else ""),
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
    parser.add_argument(
        "--split",
        choices=("development", "holdout", "reserve"),
        help=(
            "Bölme manifestindeki bölümlerden birini koş. Ayar ve teşhis "
            "yalnız 'development' ile yapılır; 'holdout' hazırlanmış bir "
            "iddiayı kaydetmek için bir kez koşulur."
        ),
    )
    parser.add_argument(
        "--no-reference", action="store_true",
        help="çevrimdışı pYIN referanslarını atla (hızlı koşu)",
    )
    parser.add_argument("--output", type=Path, default=ROOT / "outputs/external-pitch-benchmark.json")
    parser.add_argument("--markdown", type=Path, default=ROOT / "outputs/external-pitch-benchmark.md")
    args = parser.parse_args()

    selected = [d for d in DATASETS if not args.dataset or d.name in args.dataset]
    split = load_split(args.split) if args.split else None
    if args.split == "holdout":
        # Holdout bir kez harcanır. Kazara koşulmasın diye görünür olsun.
        print(
            "DİKKAT: donmuş holdout koşuluyor. Bu bölüm yalnız hazırlanmış bir\n"
            "iddiayı kaydetmek için koşulur; sonucuna bakıp eşik ayarlamak\n"
            "bölümü harcar. Ayar için --split development kullanın.\n"
        )
    started = time.time()
    results: list[FileResult] = []
    for dataset in selected:
        print(f"{dataset.name}:")
        results.extend(evaluate_dataset(
            dataset, args.engine, args.limit, args.no_reference,
            allowed=split.get(dataset.name) if split else None,
        ))

    if not results:
        print("Hiçbir küme ölçülemedi. Önce indirin:")
        print("  .venv/bin/python scripts/fetch_external_pitch_datasets.py --list")
        return 0

    summary = aggregate(results)
    payload = {
        "schema": "klarivision-external-pitch-benchmark-v1",
        "policy": "assertion-gate-never-a-tuning-target",
        # Hangi bölümün koşulduğu sonucun parçasıdır: bölüm adı olmayan bir
        # tablo, hangi veriye bakılarak üretildiğini söylemez.
        "split": args.split or "all-files-no-split",
        "split_fingerprint": (
            json.loads(SPLIT_MANIFEST.read_text(encoding="utf-8"))["fingerprint"]
            if args.split else None
        ),
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
    args.markdown.write_text(markdown_report(summary, args.split))

    print()
    print(markdown_report(summary, args.split))
    print(f"dosya={payload['file_count']} süre={time.time() - started:.1f}s fingerprint={fingerprint}")
    print(args.output)
    print(args.markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
