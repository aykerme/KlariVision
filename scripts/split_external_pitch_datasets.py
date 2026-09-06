#!/usr/bin/env python3
"""Dış perde kümelerini geliştirme / holdout / yedek olarak böler.

**Bu betik neden var.** `run_external_pitch_benchmark.py` bugüne kadar bir
*iddia kapısı* olarak kullanıldı: sayılara bakılır, gerilememesi beklenir, ama
onlara karşı ayar yapılmaz. Klarnet dışı ötüm kapsamasını iyileştirmek için
artık bu kümelere karşı **çalışmak** gerekiyor -- ve bir kümeye karşı çalışmak,
o kümeyi ölçüt olmaktan çıkarır. Tek çözüm, çalışılacak veriyi hüküm verilecek
veriden fiziksel olarak ayırmaktır.

Bölme kuralları:

1. **Deterministik.** Atama, dosya adının SHA-256'sından türetilir. Kimse
   hangi dosyanın nereye gideceğini seçmez; bir dosyayı "zor geldi" diye
   yeniden atamak mümkün değildir.
2. **Bulaşma kontrolü.** `outputs/external-pitch-benchmark.json` içinde daha
   önce ölçülmüş her dosya **geliştirmeye** gider. O dosyaların sonuçları
   görülmüştür; holdout'ta yerleri yoktur.
3. **Donmuş.** Manifest yazıldıktan sonra bu betik onu değiştirmez; farklı bir
   sonuç hesaplarsa hata verip durur. `--force` yalnız bilinçli bir yeniden
   bölme içindir (örneğin tükenmiş bir holdout'un yedekten tazelenmesi) ve
   kaydı `docs/TEST_BASELINE.md`'ye düşmelidir.
4. **Katmanlı.** Oranlar her küme içinde ayrı ayrı uygulanır, yoksa 230
   dosyalık `mdb_stem_synth` küçük kümeleri yutar.

Yedek bölüm bilerek en büyüğüdür: bir holdout ancak bir kez harcanabilir, ve
harcandığında yerine yenisinin **zaten ayrılmış** olması gerekir -- o an
yeniden bölmek, yeni holdout'u o günkü bilgiyle seçmek demektir.

Kullanım:

    .venv/bin/python scripts/split_external_pitch_datasets.py
    .venv/bin/python scripts/split_external_pitch_datasets.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from run_external_pitch_benchmark import DATASETS, EXTERNAL, annotation_for  # noqa: E402

# Sürüm kontrollü: `data/external/` tümüyle .gitignore'dadır (ses dosyaları
# depoya girmez), ama bölmenin kendisi girmek zorundadır. Manifest olmadan
# "holdout'a bakmadım" iddiası doğrulanamaz.
MANIFEST = ROOT / "data/benchmarks/external-pitch-split-v1.json"
MEASURED = ROOT / "outputs/external-pitch-benchmark.json"

SCHEMA = "klarivision-external-pitch-split-v1"

# Görülmemiş dosyaların bölüm payları. Holdout, oran ölçütlerinin (RPA, ötüm
# recall) dosya başına gürültüsünü bastıracak kadar büyük; yedek, holdout bir
# kez harcandıktan sonra yerine geçebilecek kadar.
DEVELOPMENT_SHARE = 0.25
HOLDOUT_SHARE = 0.25


def stable_rank(dataset_name: str, filename: str) -> str:
    """Dosyanın bölme içindeki yerini belirleyen değişmez anahtar."""
    return hashlib.sha256(f"{dataset_name}/{filename}".encode()).hexdigest()


def already_measured() -> dict[str, set[str]]:
    """Kayıtlı dış karşılaştırmada sonucu görülmüş dosyalar."""
    if not MEASURED.is_file():
        return {}
    payload = json.loads(MEASURED.read_text(encoding="utf-8"))
    seen: dict[str, set[str]] = {}
    for row in payload.get("files", []):
        seen.setdefault(row["dataset"], set()).add(row["source"])
    return seen


def build_split() -> dict[str, object]:
    seen = already_measured()
    datasets: dict[str, object] = {}
    for dataset in DATASETS:
        files = sorted(
            path.name
            for path in EXTERNAL.glob(dataset.audio_glob)
            if annotation_for(dataset, path).is_file()
        )
        if not files:
            raise SystemExit(
                f"{dataset.name}: referanslı ses bulunamadı. Önce "
                "scripts/fetch_external_pitch_datasets.py çalıştırılmalı."
            )
        contaminated = sorted(set(files) & seen.get(dataset.name, set()))
        unseen = [name for name in files if name not in set(contaminated)]
        # Hash sırası: rastgele ama tekrarlanabilir, ve dosya adının
        # alfabetik/enstrüman sırasıyla ilişkisiz.
        unseen.sort(key=lambda name: stable_rank(dataset.name, name))

        development_count = round(len(unseen) * DEVELOPMENT_SHARE)
        holdout_count = round(len(unseen) * HOLDOUT_SHARE)
        development = unseen[:development_count]
        holdout = unseen[development_count:development_count + holdout_count]
        reserve = unseen[development_count + holdout_count:]

        datasets[dataset.name] = {
            "total_annotated": len(files),
            # Görülmüş dosyalar geliştirmeye eklenir, payların üstüne: bulaşma
            # bir bütçe kalemi değil, bir kısıttır.
            "development": sorted(contaminated + development),
            "holdout": sorted(holdout),
            "reserve": sorted(reserve),
            "previously_measured": contaminated,
        }

    payload = {
        "schema": SCHEMA,
        "policy": {
            "development": "Ayar, teşhis ve deneme buraya bakabilir.",
            "holdout": (
                "Donmuş. Yalnız kayda geçecek bir iddia için, iddia "
                "hazırlandıktan SONRA bir kez koşulur. Bir eşiği bu bölümün "
                "sayılarına bakarak seçmek, bölümü yok eder."
            ),
            "reserve": (
                "Hiç dokunulmamış havuz. Holdout harcandığında yerine buradan "
                "yeni bir holdout ayrılır; o an yeniden bölmek, yeni holdout'u "
                "o günkü bilgiyle seçmek olurdu."
            ),
            "contamination": (
                "outputs/external-pitch-benchmark.json içinde sonucu görülmüş "
                "her dosya geliştirmededir."
            ),
        },
        "shares_of_unseen": {
            "development": DEVELOPMENT_SHARE,
            "holdout": HOLDOUT_SHARE,
            "reserve": round(1.0 - DEVELOPMENT_SHARE - HOLDOUT_SHARE, 6),
        },
        "datasets": datasets,
    }
    payload["fingerprint"] = fingerprint(payload)
    return payload


def fingerprint(payload: dict[str, object]) -> str:
    stable = {"schema": payload["schema"], "datasets": payload["datasets"]}
    encoded = json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode()).hexdigest()[:16]


def counts(payload: dict[str, object]) -> str:
    lines = []
    for name, entry in payload["datasets"].items():  # type: ignore[union-attr]
        lines.append(
            f"  {name:20s} geliştirme={len(entry['development']):3d} "
            f"(görülmüş {len(entry['previously_measured']):2d}) "
            f"holdout={len(entry['holdout']):3d} yedek={len(entry['reserve']):3d} "
            f"toplam={entry['total_annotated']:3d}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true",
        help="Manifesti yeniden hesapla ve diskteki ile karşılaştır; yazma."
    )
    parser.add_argument(
        "--force", action="store_true",
        help="Var olan manifesti bilinçli olarak yeniden yaz (holdout rotasyonu)."
    )
    arguments = parser.parse_args()

    payload = build_split()
    print(f"Bölme parmak izi: {payload['fingerprint']}")
    print(counts(payload))

    if MANIFEST.is_file():
        existing = json.loads(MANIFEST.read_text(encoding="utf-8"))
        if existing.get("fingerprint") == payload["fingerprint"]:
            print("Manifest güncel; değişiklik yok.")
            return 0
        if arguments.check:
            print(
                f"UYUŞMAZLIK: diskteki manifest {existing.get('fingerprint')}, "
                f"hesaplanan {payload['fingerprint']}.",
                file=sys.stderr,
            )
            return 1
        if not arguments.force:
            print(
                "Manifest var ve farklı bir bölme hesaplandı. Bu genelde yeni\n"
                "dosya eklenmesi demektir ve mevcut holdout'u kaydırır -- yani\n"
                "donmuş bölümü sessizce tazeler. Bilinçliyse --force ver ve\n"
                "gerekçeyi docs/TEST_BASELINE.md'ye yaz.",
                file=sys.stderr,
            )
            return 1

    if arguments.check:
        print("Manifest yok.", file=sys.stderr)
        return 1

    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Yazıldı: {MANIFEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
