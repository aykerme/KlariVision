#!/usr/bin/env python3
"""Fetch standard f0-evaluation datasets into data/external/<dataset>/.

This is a *download helper*, not part of the tuning loop. Everything it
fetches feeds `scripts/run_external_pitch_benchmark.py`, an assertion gate
that is independent of the clarinet-only judges the engines are tuned
against (see that script's module docstring).

Each dataset is independent: a failure or manual-only dataset never blocks
the others. Re-running is safe and cheap — an archive already present with a
matching SHA-256 is skipped without re-downloading.

Availability as investigated 2026-09-05 (see docs/ExternalPitchBenchmark.md
for the full write-up):
  - MDB-stem-synth   : automatic, Zenodo (record 1481172), CC BY-NC 4.0.
  - PTDB-TUG         : automatic, plain HTTP directory at TU Graz (SPSC lab,
                        no login), ODbL 1.0 / DbCL 1.0. ~4.2 GB.
  - vocadito         : automatic, Zenodo (record 5578807), CC BY 4.0.
  - MIR-1K           : the canonical host (mirlab.org) now 404s and the
                        Zenodo record (3532216) is access-restricted with no
                        files attached. A figshare mirror (article 5802891)
                        still serves the original archive and is used here
                        instead — flagged in the manifest as a mirror, not
                        the canonical source.
  - Bach10           : the original Duan/Pardo Bach10 site
                        (music.cs.northwestern.edu) no longer resolves and
                        has no scriptable download; it is marked `manual`.
                        Bach10-mf0-synth (Zenodo record 1481156, CC BY-NC
                        4.0) is fetched instead — the same ten Bach10
                        chorales, resynthesised for perfect f0 ground truth,
                        published by the MDB-stem-synth authors. It ships
                        both the polyphonic mixes (audio_mix/) with
                        per-instrument multi-f0 reference (annotation_mf0/,
                        columns: bassoon, clarinet, saxophone, violin) and
                        monophonic solo stems (audio_stems/ +
                        annotation_stems/), so the polyphonic "bleed" case
                        this project cares about is still exercised.

Usage:
    .venv/bin/python scripts/fetch_external_pitch_datasets.py --list
    .venv/bin/python scripts/fetch_external_pitch_datasets.py
    .venv/bin/python scripts/fetch_external_pitch_datasets.py --dataset vocadito
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import shutil
import tarfile
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTERNAL_ROOT = ROOT / "data/external"
MANIFEST_PATH = EXTERNAL_ROOT / "manifest.json"
CHUNK = 1 << 20  # 1 MiB
USER_AGENT = "klarivision-external-pitch-benchmark/1 (+research use)"


@dataclasses.dataclass(frozen=True)
class DatasetSpec:
    key: str
    display_name: str
    what_it_tests: str
    automatic: bool
    source_url: str
    license_name: str
    license_url: str
    version_or_doi: str
    archive_name: str = ""
    download_url: str = ""
    manual_instructions: str = ""
    note: str = ""


DATASETS: tuple[DatasetSpec, ...] = (
    DatasetSpec(
        key="mdb_stem_synth",
        display_name="MDB-stem-synth",
        what_it_tests="Multi-instrument, perfect synthetic-resynthesis f0 reference.",
        automatic=True,
        source_url="https://zenodo.org/records/1481172",
        license_name="CC BY-NC 4.0",
        license_url="https://creativecommons.org/licenses/by-nc/4.0/",
        version_or_doi="10.5281/zenodo.1481172",
        archive_name="MDB-stem-synth.tar.gz",
        download_url="https://zenodo.org/records/1481172/files/MDB-stem-synth.tar.gz?download=1",
        note="230 mono stems + perfect f0 CSVs (analysis/synthesis method).",
    ),
    DatasetSpec(
        key="ptdb_tug",
        display_name="PTDB-TUG",
        what_it_tests="Speech, EGG-aligned. Non-clarinet timbre, different odd/even partial distribution.",
        automatic=True,
        source_url=(
            "https://www.spsc.tugraz.at/databases-and-tools/"
            "ptdb-tug-pitch-tracking-database-from-graz-university-of-technology.html"
        ),
        license_name="Open Database License 1.0 / Database Contents License 1.0",
        license_url="https://opendatacommons.org/licenses/odbl/1.0/",
        version_or_doi="SPSC TU Graz, published 2011-09",
        archive_name="SPEECH_DATA_ZIPPED.zip",
        download_url="https://www2.spsc.tugraz.at/databases/PTDB-TUG/SPEECH_DATA_ZIPPED.zip",
        note="~4.2 GB. Laryngograph-referenced pitch for 20 speakers reading TIMIT sentences.",
    ),
    DatasetSpec(
        key="vocadito",
        display_name="vocadito",
        what_it_tests="Vocal, small, permissively licensed.",
        automatic=True,
        source_url="https://zenodo.org/records/5578807",
        license_name="CC BY 4.0",
        license_url="https://creativecommons.org/licenses/by/4.0/",
        version_or_doi="10.5281/zenodo.5578807",
        archive_name="vocadito.zip",
        download_url="https://zenodo.org/records/5578807/files/vocadito.zip?download=1",
        note="40 short solo-vocal excerpts, 7 languages, frame-level f0.",
    ),
    DatasetSpec(
        key="mir_1k",
        display_name="MIR-1K",
        what_it_tests="Vocal.",
        automatic=True,
        source_url="https://figshare.com/articles/dataset/MIR-1K_rar/5802891",
        license_name="CC BY 4.0 (per figshare mirror; verify against original MIRLab terms before redistribution)",
        license_url="https://creativecommons.org/licenses/by/4.0/",
        version_or_doi="figshare article 5802891 (mirror of MIRLab MIR-1K)",
        archive_name="MIR-1K.rar",
        download_url="https://ndownloader.figshare.com/files/10256751",
        note=(
            "Canonical host mirlab.org/dataset/public/MIR-1K.rar now 404s and the Zenodo "
            "record (3532216) is access-restricted with no files. This figshare article is "
            "the only automatically fetchable copy found; it is a third-party mirror, not the "
            "canonical release."
        ),
    ),
    DatasetSpec(
        key="bach10",
        display_name="Bach10",
        what_it_tests="Polyphonic mixture — stresses the parity estimate under bleed.",
        automatic=False,
        source_url="http://music.cs.northwestern.edu/data/Bach10.html",
        license_name="Research use per Duan & Pardo (no public redistribution license posted)",
        license_url="",
        version_or_doi="Duan & Pardo, Bach10 (IEEE TASLP 2010)",
        manual_instructions=(
            "The canonical Bach10 site (music.cs.northwestern.edu/data/Bach10.html) no longer "
            "resolves over HTTPS (certificate mismatch) and has no scriptable download; it has "
            "historically been distributed on request to Zhiyao Duan / Bryan Pardo. Email the "
            "authors or search for a current mirror, place the archive under "
            "data/external/bach10/, and re-run this script to record its checksum. "
            "Meanwhile 'bach10_mf0_synth' below fetches the same ten chorales with perfect "
            "f0 ground truth and is used as the automatic stand-in for the benchmark."
        ),
    ),
    DatasetSpec(
        key="bach10_mf0_synth",
        display_name="Bach10-mf0-synth",
        what_it_tests=(
            "Polyphonic mixture (bassoon/clarinet/saxophone/violin, incl. a clarinet part) "
            "with perfect multi-f0 ground truth — stand-in for Bach10 (see bach10 entry)."
        ),
        automatic=True,
        source_url="https://zenodo.org/records/1481156",
        license_name="CC BY-NC 4.0",
        license_url="https://creativecommons.org/licenses/by-nc/4.0/",
        version_or_doi="10.5281/zenodo.1481156",
        archive_name="Bach10-mf0-syth.tar.gz",
        download_url="https://zenodo.org/records/1481156/files/Bach10-mf0-syth.tar.gz?download=1",
        note="10 Bach chorales, resynthesised mixes + solo stems, perfect f0.",
    ),
)

DATASET_BY_KEY = {spec.key: spec for spec in DATASETS}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest() -> dict[str, object]:
    if MANIFEST_PATH.exists():
        return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    return {"datasets": {}}


def save_manifest(manifest: dict[str, object]) -> None:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _count_members(archive: Path) -> int:
    try:
        if archive.suffix == ".zip":
            with zipfile.ZipFile(archive) as zf:
                return sum(1 for info in zf.infolist() if not info.is_dir())
        if archive.name.endswith((".tar.gz", ".tgz", ".tar")):
            with tarfile.open(archive) as tf:
                return sum(1 for member in tf.getmembers() if member.isfile())
    except (zipfile.BadZipFile, tarfile.TarError):
        return -1
    return -1  # unknown archive type (e.g. .rar — no stdlib reader)


def _download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as out:
        shutil.copyfileobj(response, out, length=CHUNK)
    partial.replace(destination)


def fetch_one(spec: DatasetSpec, manifest: dict[str, object], *, force: bool) -> dict[str, object]:
    entry: dict[str, object] = {
        "display_name": spec.display_name,
        "what_it_tests": spec.what_it_tests,
        "source_url": spec.source_url,
        "license": spec.license_name,
        "license_url": spec.license_url,
        "version_or_doi": spec.version_or_doi,
        "note": spec.note,
    }
    if not spec.automatic:
        entry["status"] = "manual"
        entry["manual_instructions"] = spec.manual_instructions
        print(f"[{spec.key}] manual — {spec.source_url}")
        print(f"    {spec.manual_instructions}")
        return entry

    dataset_dir = EXTERNAL_ROOT / spec.key
    archive_path = dataset_dir / spec.archive_name

    if archive_path.exists() and not force:
        # Already on disk: re-verify its checksum every run (cheap, local) rather
        # than trusting a possibly-stale manifest, but never re-download for it.
        digest = sha256_of(archive_path)
        file_count = _count_members(archive_path)
        entry.update(
            {
                "status": "already_present",
                "archive_name": spec.archive_name,
                "archive_path": str(archive_path.relative_to(ROOT)),
                "archive_sha256": digest,
                "file_count": file_count,
            }
        )
        print(f"[{spec.key}] already present, checksum verified ({digest[:12]}…) — skipping download")
        return entry

    try:
        print(f"[{spec.key}] downloading {spec.download_url}")
        _download(spec.download_url, archive_path)
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        entry["status"] = "error"
        entry["error"] = str(error)
        print(f"[{spec.key}] FAILED: {error}")
        return entry

    digest = sha256_of(archive_path)
    file_count = _count_members(archive_path)
    entry.update(
        {
            "status": "downloaded",
            "archive_name": spec.archive_name,
            "archive_path": str(archive_path.relative_to(ROOT)),
            "archive_sha256": digest,
            "file_count": file_count,
            "downloaded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
    print(f"[{spec.key}] downloaded, sha256={digest[:12]}…, files={file_count}")
    return entry


def list_status(manifest: dict[str, object]) -> None:
    recorded = manifest.get("datasets", {})
    for spec in DATASETS:
        dataset_dir = EXTERNAL_ROOT / spec.key
        archive_path = dataset_dir / spec.archive_name if spec.archive_name else None
        if not spec.automatic:
            state = "manual"
        elif archive_path and archive_path.exists():
            state = "present" if recorded.get(spec.key, {}).get("archive_sha256") else "present (unverified)"
        else:
            state = "not fetched"
        print(f"{spec.key:20s} {state:20s} {spec.display_name} — {spec.license_name}")
        print(f"{'':20s} {'':20s} {spec.source_url}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", action="append", choices=sorted(DATASET_BY_KEY), default=None)
    parser.add_argument("--list", action="store_true", help="Show status without downloading anything.")
    parser.add_argument("--force", action="store_true", help="Re-download even if a verified archive exists.")
    arguments = parser.parse_args()

    manifest = load_manifest()

    if arguments.list:
        list_status(manifest)
        return

    keys = arguments.dataset or [spec.key for spec in DATASETS]
    manifest.setdefault("datasets", {})
    for key in keys:
        spec = DATASET_BY_KEY[key]
        manifest["datasets"][key] = fetch_one(spec, manifest, force=arguments.force)
        save_manifest(manifest)  # persist incrementally: one dataset's failure must not lose others' results

    print(f"manifest: {MANIFEST_PATH}")


if __name__ == "__main__":
    main()
