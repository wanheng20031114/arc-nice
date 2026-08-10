#!/usr/bin/env python3
"""Build and audit the Plant Cultivation Center visual assets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
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
SOURCE_DIR = (
    ROOT
    / "dev_assets/source_images/plant_defense/plant_cultivation_center"
)
BUILDING_SOURCE = (
    SOURCE_DIR
    / "plant_cultivation_center_compact_imagegen_magenta.png"
)
BUILDING_OUTPUT = (
    ROOT
    / "resources/texture/plant_defense/plant_cultivation_center"
    / "plant_cultivation_center.png"
)
PANEL_SOURCE = (
    SOURCE_DIR / "plant_cultivation_center_panel_background_imagegen.png"
)
PANEL_OUTPUT = (
    ROOT
    / "resources/texture/production"
    / "plant_cultivation_center_panel_background.png"
)
AUDIT_OUTPUT = (
    ROOT
    / "dev_tools/output/plant_defense/plant_cultivation_center_asset_audit.json"
)

BUILDING_MAX_SIZE = (60, 60)
BUILDING_FOOT_TARGET = (32, 62)
BUILDING_COLOR_LIMIT = 64
PANEL_SIZE = (728, 544)
PANEL_COLOR_LIMIT = 128


def _build_building() -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        BUILDING_SOURCE,
        max_subject_size=BUILDING_MAX_SIZE,
        fit_oversized=False,
    )
    registered, paste_origin = place_bottom_center(
        subject.image,
        target=BUILDING_FOOT_TARGET,
    )
    palette = build_shared_palette(
        [registered],
        max_colors=BUILDING_COLOR_LIMIT,
    )
    output = apply_palette(registered, palette)
    return output, {
        "source": source_audit(subject),
        "registration": {
            "mode": "bottom_center",
            "paste_origin": list(paste_origin),
            "foot_target": list(BUILDING_FOOT_TARGET),
            "measured_foot_anchor": list(foot_anchor(output)),
        },
        "visible_palette_size": len(palette),
    }


def _build_panel() -> Image.Image:
    with Image.open(PANEL_SOURCE) as source_image:
        panel = source_image.convert("RGB")
    source_ratio = panel.width / panel.height
    target_ratio = PANEL_SIZE[0] / PANEL_SIZE[1]
    if abs(source_ratio - target_ratio) > 0.02:
        raise RuntimeError(
            "Plant Cultivation Center panel must remain approximately "
            f"728:544, got {panel.size}"
        )
    panel = panel.resize(PANEL_SIZE, Image.Resampling.NEAREST)
    return panel.quantize(
        colors=PANEL_COLOR_LIMIT,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")


def _save_image_if_changed(image: Image.Image, output_path: Path) -> bool:
    if output_path.is_file():
        with Image.open(output_path) as existing_image:
            existing = existing_image.convert("RGBA")
            generated = image.convert("RGBA")
            if (
                existing.size == generated.size
                and existing.tobytes() == generated.tobytes()
            ):
                return False
    image.save(output_path)
    return True


def build_assets() -> tuple[dict[str, Image.Image], dict]:
    building, building_context = _build_building()
    panel = _build_panel()

    building_audit = audit_image(
        building,
        label="plant_cultivation_center",
        path=portable_path(BUILDING_OUTPUT),
        max_subject_size=BUILDING_MAX_SIZE,
    )
    failures = validation_failures([building_audit])
    if panel.size != PANEL_SIZE:
        failures.append("plant cultivation center panel must be 728x544")

    report = {
        "schema_version": 1,
        "asset_family": "plant_cultivation_center",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen selected concept",
            "built-in imagegen logical-grid compactness correction",
            "flat #FF00FF chroma key",
            "pixel_grid_analyzer measured logical grid",
            "nearest logical-cell selection without smoothing",
            "palette reduction without dithering",
            "binary-alpha and footprint audit",
        ],
        "visual_contract": {
            "building_source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "building_subject_limit_px": list(BUILDING_MAX_SIZE),
            "building_footprint_cells": [2, 2],
            "building_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "building_world_size_px": [32, 32],
            "panel_size_px": list(PANEL_SIZE),
        },
        "building": {**building_context, "audit": building_audit},
        "panel": {
            "source_path": portable_path(PANEL_SOURCE),
            "output_path": portable_path(PANEL_OUTPUT),
            "output_size": list(panel.size),
            "visible_color_limit": PANEL_COLOR_LIMIT,
            "contains_baked_item_slots": False,
        },
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    return {
        "building": building,
        "panel": panel,
    }, report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    assets, report = build_assets()
    if args.check_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    BUILDING_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    PANEL_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    _save_image_if_changed(assets["building"], BUILDING_OUTPUT)
    _save_image_if_changed(assets["panel"], PANEL_OUTPUT)
    AUDIT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Plant Cultivation Center: {BUILDING_OUTPUT}")
    print(f"Built Plant Cultivation Center panel: {PANEL_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
