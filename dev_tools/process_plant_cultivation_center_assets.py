#!/usr/bin/env python3
"""Build and audit the Plant Cultivation Center and building-item icons."""

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
    clean_transparency,
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
AGAVE_ICON_SOURCE = (
    ROOT / "resources/texture/plant_defense/agave_cannon/icon.png"
)
CORN_ICON_SOURCE = (
    ROOT / "resources/texture/plant_defense/corn_machine_gun/icon.png"
)
BAMBOO_MORTAR_ICON_SOURCE = (
    ROOT / "resources/texture/plant_defense/bamboo_mortar/idle.png"
)
AGAVE_ITEM_ICON_OUTPUT = (
    ROOT / "resources/texture/building_items/agave_cannon.png"
)
CORN_ITEM_ICON_OUTPUT = (
    ROOT / "resources/texture/building_items/corn_machine_gun.png"
)
BAMBOO_MORTAR_ITEM_ICON_OUTPUT = (
    ROOT / "resources/texture/building_items/bamboo_mortar.png"
)
PANEL_SOURCE = (
    SOURCE_DIR / "plant_cultivation_center_panel_background_imagegen.png"
)
PANEL_OUTPUT = (
    ROOT
    / "resources/texture/production"
    / "plant_cultivation_center_panel_background.png"
)
AUDIT_OUTPUT = SOURCE_DIR / "plant_cultivation_center_asset_audit.json"

BUILDING_MAX_SIZE = (60, 60)
BUILDING_FOOT_TARGET = (32, 62)
BUILDING_COLOR_LIMIT = 64
ITEM_ICON_SIZE = (32, 32)
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


def _build_half_scale_icon(source_path: Path) -> Image.Image:
    with Image.open(source_path) as source_image:
        source = clean_transparency(source_image.convert("RGBA"))
    if source.size != (CANVAS_SIDE, CANVAS_SIDE):
        raise RuntimeError(
            f"Building item source must be 64x64: {source_path} is {source.size}"
        )
    return clean_transparency(
        source.resize(ITEM_ICON_SIZE, Image.Resampling.NEAREST)
    )


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


def _audit_item_icon(
    image: Image.Image,
    *,
    label: str,
    source_path: Path,
    output_path: Path,
) -> dict:
    rgba = clean_transparency(image)
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError(f"{label} item icon is empty")
    visible_colors = {
        pixel[:3]
        for pixel in rgba.getdata()
        if pixel[3] > 0
    }
    alpha_values = sorted(set(rgba.getchannel("A").getdata()))
    transparent_rgb_clean = all(
        alpha > 0 or (red, green, blue) == (0, 0, 0)
        for red, green, blue, alpha in rgba.getdata()
    )
    checks = {
        "canvas_32x32": rgba.size == ITEM_ICON_SIZE,
        "binary_alpha": set(alpha_values).issubset({0, 255}),
        "transparent_rgb_clean": transparent_rgb_clean,
        "subject_within_32x32": (
            bbox[2] - bbox[0] <= ITEM_ICON_SIZE[0]
            and bbox[3] - bbox[1] <= ITEM_ICON_SIZE[1]
        ),
    }
    return {
        "label": label,
        "source_path": portable_path(source_path),
        "output_path": portable_path(output_path),
        "conversion": "exact integer 1/2 nearest-neighbour sampling",
        "canvas_size": list(rgba.size),
        "subject_bbox_exclusive": list(bbox),
        "subject_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        "visible_color_count": len(visible_colors),
        "alpha_values": alpha_values,
        "checks": checks,
        "passed": all(checks.values()),
    }


def build_assets() -> tuple[dict[str, Image.Image], dict]:
    building, building_context = _build_building()
    agave_icon = _build_half_scale_icon(AGAVE_ICON_SOURCE)
    corn_icon = _build_half_scale_icon(CORN_ICON_SOURCE)
    bamboo_mortar_icon = _build_half_scale_icon(
        BAMBOO_MORTAR_ICON_SOURCE
    )
    panel = _build_panel()

    building_audit = audit_image(
        building,
        label="plant_cultivation_center",
        path=portable_path(BUILDING_OUTPUT),
        max_subject_size=BUILDING_MAX_SIZE,
    )
    agave_audit = _audit_item_icon(
        agave_icon,
        label="agave_cannon_building_item",
        source_path=AGAVE_ICON_SOURCE,
        output_path=AGAVE_ITEM_ICON_OUTPUT,
    )
    corn_audit = _audit_item_icon(
        corn_icon,
        label="corn_machine_gun_building_item",
        source_path=CORN_ICON_SOURCE,
        output_path=CORN_ITEM_ICON_OUTPUT,
    )
    bamboo_mortar_audit = _audit_item_icon(
        bamboo_mortar_icon,
        label="bamboo_mortar_building_item",
        source_path=BAMBOO_MORTAR_ICON_SOURCE,
        output_path=BAMBOO_MORTAR_ITEM_ICON_OUTPUT,
    )

    failures = validation_failures([building_audit])
    for item_audit in (
        agave_audit,
        corn_audit,
        bamboo_mortar_audit,
    ):
        for check_name, passed in item_audit["checks"].items():
            if not passed:
                failures.append(f"{item_audit['label']}: {check_name}")
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
            "building item icons reduced by exact integer 1/2 sampling",
        ],
        "visual_contract": {
            "building_source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "building_subject_limit_px": list(BUILDING_MAX_SIZE),
            "building_footprint_cells": [2, 2],
            "building_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "building_world_size_px": [32, 32],
            "building_item_icon_canvas_px": list(ITEM_ICON_SIZE),
            "panel_size_px": list(PANEL_SIZE),
        },
        "building": {**building_context, "audit": building_audit},
        "building_items": {
            "agave_cannon": agave_audit,
            "corn_machine_gun": corn_audit,
            "bamboo_mortar": bamboo_mortar_audit,
        },
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
        "agave_icon": agave_icon,
        "corn_icon": corn_icon,
        "bamboo_mortar_icon": bamboo_mortar_icon,
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
    AGAVE_ITEM_ICON_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    PANEL_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    _save_image_if_changed(assets["building"], BUILDING_OUTPUT)
    _save_image_if_changed(assets["agave_icon"], AGAVE_ITEM_ICON_OUTPUT)
    _save_image_if_changed(
        assets["corn_icon"],
        CORN_ITEM_ICON_OUTPUT,
    )
    _save_image_if_changed(
        assets["bamboo_mortar_icon"],
        BAMBOO_MORTAR_ITEM_ICON_OUTPUT,
    )
    _save_image_if_changed(assets["panel"], PANEL_OUTPUT)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Plant Cultivation Center: {BUILDING_OUTPUT}")
    print(f"Built Agave Cannon item icon: {AGAVE_ITEM_ICON_OUTPUT}")
    print(f"Built Corn Machine Gun item icon: {CORN_ITEM_ICON_OUTPUT}")
    print(
        "Built Bamboo Mortar item icon: "
        f"{BAMBOO_MORTAR_ITEM_ICON_OUTPUT}"
    )
    print(f"Built Plant Cultivation Center panel: {PANEL_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
