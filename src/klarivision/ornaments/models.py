"""Shared ornament-candidate model."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class OrnamentCandidate:
    """A short region that merits a musician's review, not a final classification."""

    kind: str
    start_seconds: float
    end_seconds: float
    confidence: float
    rate_hz: float | None = None
    amplitude_cents: float | None = None
