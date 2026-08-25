#!/usr/bin/env python3
"""Build audited Water Collector, water-bottle, and panel assets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    TRANSPARENT,
    WORLD_SCALE,
    apply_palette,
    audit_image,
    build_shared_palette,
    clean_transparency,
    foot_anchor,
    normalize_imagegen_subject,
    place_bottom_center,
    portable_path,
    source_audit,
    validation_failures,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/water_collector"
ITEM_SOURCE_DIR = ROOT / "dev_assets/source_images/items/water_bottle"

BUILDING_SOURCE = SOURCE_DIR / "water_collector_selected_imagegen_transparent.png"
BOTTLE_SOURCE = ITEM_SOURCE_DIR / "water_bottle_imagegen_transparent.png"
PANEL_SOURCE = SOURCE_DIR / "water_collector_panel_background_imagegen.png"

BUILDING_OUTPUT = (
    ROOT
    / "resources/texture/plant_defense/water_collector/water_collector.png"
)
BOTTLE_OUTPUT = ROOT / "resources/texture/materials/water_bottle.png"
PANEL_OUTPUT = (
    ROOT / "resources/texture/production/water_collector_panel_background.png"
)
AUDIT_OUTPUT = ROOT / "dev_tools/output/plant_defense/water_collector_asset_audit.json"

BUILDING_MAX_SIZE = (58, 62)
BUILDING_FOOT_TARGET = (32, 62)
BUILDING_COLOR_LIMIT = 48
BOTTLE_MAX_SIZE = (22, 30)
BOTTLE_CANVAS_SIZE = (32, 32)
BOTTLE_BOTTOM_Y = 30
BOTTLE_COLOR_LIMIT = 16
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


def _build_bottle() -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        BOTTLE_SOURCE,
        max_subject_size=BOTTLE_MAX_SIZE,
        fit_oversized=False,
    )
    paste_origin = (
        (BOTTLE_CANVAS_SIZE[0] - subject.image.width) // 2,
        BOTTLE_BOTTOM_Y - subject.image.height + 1,
    )
    if (
        paste_origin[0] < 0
        or paste_origin[1] < 0
        or paste_origin[0] + subject.image.width > BOTTLE_CANVAS_SIZE[0]
        or paste_origin[1] + subject.image.height > BOTTLE_CANVAS_SIZE[1]
    ):
        raise RuntimeError(
            f"Water bottle {subject.image.size} does not fit 32x32 at {paste_origin}"
        )
    canvas = Image.new("RGBA", BOTTLE_CANVAS_SIZE, TRANSPARENT)
    canvas.alpha_composite(subject.image, paste_origin)
    canvas = clean_transparency(canvas)
    palette = build_shared_palette([canvas], max_colors=BOTTLE_COLOR_LIMIT)
    output = apply_palette(canvas, palette)
    bbox = output.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Water bottle output is empty")
    visible_colors = {
        pixel[:3]
        for pixel in output.getdata()
        if pixel[3] > 0
    }
    alpha_values = sorted(set(output.getchannel("A").getdata()))
    transparent_rgb_clean = all(
        alpha > 0 or (red, green, blue) == (0, 0, 0)
        for red, green, blue, alpha in output.getdata()
    )
    audit = {
        "path": portable_path(BOTTLE_OUTPUT),
        "canvas_size": list(output.size),
        "subject_bbox_exclusive": list(bbox),
        "subject_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        "visible_color_count": len(visible_colors),
        "alpha_values": alpha_values,
        "checks": {
            "canvas_32x32": output.size == BOTTLE_CANVAS_SIZE,
            "binary_alpha": set(alpha_values).issubset({0, 255}),
            "transparent_rgb_clean": transparent_rgb_clean,
            "visible_colors_within_limit": (
                len(visible_colors) <= BOTTLE_COLOR_LIMIT
            ),
            "subject_within_declared_limit": (
                bbox[2] - bbox[0] <= BOTTLE_MAX_SIZE[0]
                and bbox[3] - bbox[1] <= BOTTLE_MAX_SIZE[1]
            ),
        },
    }
    audit["passed"] = all(audit["checks"].values())
    return output, {
        "source": source_audit(subject),
        "registration": {
            "mode": "bottom_center_32px_canvas",
            "paste_origin": list(paste_origin),
            "bottom_y": BOTTLE_BOTTOM_Y,
        },
        "visible_palette_size": len(palette),
        "audit": audit,
    }


def _build_panel() -> Image.Image:
    with Image.open(PANEL_SOURCE) as source:
        panel = source.convert("RGB")
    aspect_ratio = panel.width / panel.height
    target_ratio = PANEL_SIZE[0] / PANEL_SIZE[1]
    if abs(aspect_ratio - target_ratio) > 0.02:
        raise RuntimeError(
            f"Water Collector panel must remain approximately 4:3, got {panel.size}"
        )
    panel = panel.resize(PANEL_SIZE, Image.Resampling.NEAREST)
    return panel.quantize(
        colors=PANEL_COLOR_LIMIT,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")


def build_assets() -> tuple[dict[str, Image.Image], dict]:
    building, building_context = _build_building()
    bottle, bottle_context = _build_bottle()
    panel = _build_panel()

    building_audit = audit_image(
        building,
        label="water_collector",
        path=portable_path(BUILDING_OUTPUT),
        max_subject_size=BUILDING_MAX_SIZE,
    )
    failures = validation_failures([building_audit])
    bottle_audit = bottle_context["audit"]
    for check_name, passed in bottle_audit["checks"].items():
        if not passed:
            failures.append(f"water_bottle: {check_name}")
    if panel.size != PANEL_SIZE:
        failures.append("water collector panel must be 728x544")

    report = {
        "schema_version": 1,
        "asset_family": "water_collector",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen reference-guided sprite masters with native transparent Alpha",
            "pixel_grid_analyzer measured logical grid",
            "nearest logical-cell selection without smoothing",
            "palette reduction without dithering",
            "binary-alpha and footprint audit",
        ],
        "visual_contract": {
            "building_source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "building_footprint_cells": [2, 2],
            "building_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "building_world_size_px": [32, 32],
            "bottle_canvas_px": list(BOTTLE_CANVAS_SIZE),
            "panel_size_px": list(PANEL_SIZE),
        },
        "building": {**building_context, "audit": building_audit},
        "water_bottle": bottle_context,
        "panel": {
            "source_path": portable_path(PANEL_SOURCE),
            "output_path": portable_path(PANEL_OUTPUT),
            "output_size": list(panel.size),
            "visible_color_limit": PANEL_COLOR_LIMIT,
        },
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    return {
        "building": building,
        "bottle": bottle,
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
    BOTTLE_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    PANEL_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    assets["building"].save(BUILDING_OUTPUT)
    assets["bottle"].save(BOTTLE_OUTPUT)
    assets["panel"].save(PANEL_OUTPUT)
    AUDIT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Water Collector sprite: {BUILDING_OUTPUT}")
    print(f"Built water-bottle icon: {BOTTLE_OUTPUT}")
    print(f"Built Water Collector panel: {PANEL_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
