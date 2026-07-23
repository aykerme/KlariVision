"""JSON output for reviewable ornament candidates."""

from __future__ import annotations

import json
from pathlib import Path

from .models import OrnamentCandidate


def write_candidates(candidates: list[OrnamentCandidate], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            {
                "candidates": [
                    {
                        "kind": candidate.kind,
                        "start_seconds": candidate.start_seconds,
                        "end_seconds": candidate.end_seconds,
                        "confidence": candidate.confidence,
                        "rate_hz": candidate.rate_hz,
                        "amplitude_cents": candidate.amplitude_cents,
                    }
                    for candidate in candidates
                ]
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
