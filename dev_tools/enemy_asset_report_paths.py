#!/usr/bin/env python3
"""Shared paths for disposable enemy asset-pipeline JSON reports.

Enemy source rasters and review PNG/GIF files remain checked in, while machine-
generated manifests and audit reports are rebuilt under the ignored dev output
tree.  Keeping this path helper tiny lets each staged pipeline retain its
existing producer/consumer contract without recreating tracked JSON files.
"""

from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENEMY_ASSET_REPORT_DIRECTORY = (
    PROJECT_ROOT / "dev_tools" / "output" / "asset_reports"
)


def enemy_asset_report_path(filename: str) -> Path:
    """Return an ignored JSON report path and ensure its directory exists."""

    if Path(filename).name != filename or not filename.endswith(".json"):
        raise ValueError(f"invalid enemy asset report filename: {filename!r}")
    ENEMY_ASSET_REPORT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    return ENEMY_ASSET_REPORT_DIRECTORY / filename


def is_enemy_asset_report_path(path: Path) -> bool:
    """Return whether *path* is contained by the ignored report directory."""

    resolved = path.resolve()
    report_directory = ENEMY_ASSET_REPORT_DIRECTORY.resolve()
    return resolved == report_directory or report_directory in resolved.parents
