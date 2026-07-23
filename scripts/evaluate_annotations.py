"""Write a reproducible comparison of manual labels and automatic candidates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from klarivision.ornaments.evaluate import evaluate_candidates


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("annotations", type=Path)
    parser.add_argument("candidates", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--kind", default="vibrato")
    arguments = parser.parse_args()

    annotations = json.loads(arguments.annotations.read_text(encoding="utf-8"))["annotations"]
    candidates = json.loads(arguments.candidates.read_text(encoding="utf-8"))["candidates"]
    report = evaluate_candidates(annotations, candidates, kind=arguments.kind)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key not in {"matches", "missed_annotations", "unmatched_candidates"}}, ensure_ascii=False))


if __name__ == "__main__":
    main()
