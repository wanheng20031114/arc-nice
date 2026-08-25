#!/usr/bin/env python3
"""Build the true-64px Oak Warehouse sprite selected from imagegen drafts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    MAX_VISIBLE_COLORS,
    WORLD_FOOTPRINT_SIDE,
    WORLD_SCALE,
    apply_palette,
    audit_image,
    build_shared_palette,
    foot_anchor,
    normalize_imagegen_subject,
    place_bottom_center,
    portable_path,
    source_audit,
    validation_failures,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/oak_warehouse"
DEFAULT_INPUT = SOURCE_DIR / "oak_warehouse_selected_imagegen_transparent.png"
OUTPUT_PATH = ROOT / "resources/texture/plant_defense/oak_warehouse/oak_warehouse.png"
AUDIT_PATH = ROOT / "dev_tools/output/plant_defense/oak_warehouse_asset_audit.json"
MAX_SUBJECT_SIZE = (60, 62)
FOOT_TARGET = (32, 62)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build an audited true-64px Oak Warehouse sprite",
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    parser.add_argument("--audit-path", type=Path, default=AUDIT_PATH)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate entirely in memory; do not write PNG or audit files",
    )
    args = parser.parse_args()

    subject = normalize_imagegen_subject(
        args.input,
        max_subject_size=MAX_SUBJECT_SIZE,
    )
    registered, paste_origin = place_bottom_center(
        subject.image,
        target=FOOT_TARGET,
    )
    palette = build_shared_palette([registered], max_colors=MAX_VISIBLE_COLORS)
    output = apply_palette(registered, palette)
    output_audit = audit_image(
        output,
        label="oak_warehouse",
        path=portable_path(args.output),
        max_subject_size=MAX_SUBJECT_SIZE,
    )
    failures = validation_failures([output_audit])
    report = {
        "schema_version": 2,
        "asset_family": "oak_warehouse",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen source with native transparent Alpha",
            "reliable logical-grid analysis",
            "nearest center sample to one pixel per logical cell",
            "<=64-color palette without dithering",
            "bottom-centre registration",
            "binary-alpha and footprint audit",
        ],
        "visual_contract": {
            "source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "maximum_subject_px": list(MAX_SUBJECT_SIZE),
            "static_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "world_footprint_px": [WORLD_FOOTPRINT_SIDE, WORLD_FOOTPRINT_SIDE],
            "camera_zoom": 2,
            "screen_px_per_source_px": 1,
            "alpha": "binary",
            "transparent_rgb": [0, 0, 0],
            "visible_color_limit": MAX_VISIBLE_COLORS,
        },
        "source": source_audit(subject),
        "registration": {
            "mode": "bottom_center",
            "paste_origin": list(paste_origin),
            "output_foot_target": list(FOOT_TARGET),
            "measured_output_foot_anchor": list(foot_anchor(output)),
        },
        "shared_palette": {
            "actual_color_count": len(palette),
            "rgb": [list(color) for color in palette],
        },
        "outputs": [output_audit],
        "unmanaged_asset_invariants": [
            "oak_warehouse_panel_background.png is intentionally unchanged",
        ],
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))

    if args.check_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.save(args.output)
    args.audit_path.parent.mkdir(parents=True, exist_ok=True)
    args.audit_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Oak Warehouse asset: {args.output}")
    print(f"Audit report: {args.audit_path}")


if __name__ == "__main__":
    main()
