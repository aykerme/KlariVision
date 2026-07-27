"""Paths for bundled resources and writable local KlariVision data."""

from __future__ import annotations

import sys
from pathlib import Path


def resource_root() -> Path:
    """Return the read-only project or bundled application resources."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS)  # type: ignore[attr-defined]
    return Path(__file__).resolve().parents[2]


def user_data_root() -> Path:
    """Return a writable data directory without polluting an app bundle."""
    if getattr(sys, "frozen", False):
        return Path.home() / "Library" / "Application Support" / "KlariVision"
    return resource_root()
