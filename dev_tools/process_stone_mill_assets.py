#!/usr/bin/env python3
"""Build and audit the Stone Mill and its two powder material icons."""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    TRANSPARENT,
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
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/stone_mill"

BUILDING_SOURCE = SOURCE_DIR / "stone_mill_imagegen_magenta_v2.png"
BLUE_POWDER_SOURCE = (
    SOURCE_DIR / "capoo_blue_crystal_powder_imagegen_magenta_v2.png"
)
WHITE_POWDER_SOURCE = SOURCE_DIR / "white_crystal_powder_imagegen_magenta_v2.png"

BUILDING_OUTPUT = (
    ROOT / "resources/texture/plant_defense/stone_mill/stone_mill.png"
)
BLUE_POWDER_OUTPUT = (
    ROOT / "resources/texture/materials/capoo_blue_crystal_powder.png"
)
WHITE_POWDER_OUTPUT = ROOT / "resources/texture/materials/white_crystal_powder.png"
AUDIT_OUTPUT = SOURCE_DIR / "stone_mill_asset_audit.json"

BUILDING_MAX_SIZE = (32, 32)
BUILDING_EXPECTED_SIZE = (25, 27)
BUILDING_FOOT_TARGET = (32, 47)
MATERIAL_CANVAS_SIZE = (32, 32)
MATERIAL_EXPECTED_SIZES = {
    "capoo_blue_crystal_powder": (25, 16),
    "white_crystal_powder": (22, 15),
}
VISIBLE_COLOR_LIMIT = 32


def _visible_color_count(image: Image.Image) -> int:
    return len(
        {
            (red, green, blue)
            for red, green, blue, alpha in image.convert("RGBA").getdata()
            if alpha > 0
        }
    )


def _transparency_audit(image: Image.Image) -> dict:
    rgba = image.convert("RGBA")
    alpha_values = sorted(set(rgba.getchannel("A").getdata()))
    transparent_rgb_clean = all(
        alpha > 0 or (red, green, blue) == (0, 0, 0)
        for red, green, blue, alpha in rgba.getdata()
    )
    return {
        "alpha_values": alpha_values,
        "binary_alpha": all(value in (0, 255) for value in alpha_values),
        "transparent_rgb_clean": transparent_rgb_clean,
    }


def _build_building() -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        BUILDING_SOURCE,
        max_subject_size=BUILDING_MAX_SIZE,
        fit_oversized=False,
    )
    if subject.detected_logical_size != BUILDING_EXPECTED_SIZE:
        raise RuntimeError(
            "Stone Mill source logical size changed: expected "
            f"{BUILDING_EXPECTED_SIZE}, got {subject.detected_logical_size}"
        )
    if subject.logical_size != subject.detected_logical_size:
        raise RuntimeError("Stone Mill must retain its detected logical size")

    registered, paste_origin = place_bottom_center(
        subject.image,
        target=BUILDING_FOOT_TARGET,
    )
    palette = build_shared_palette([registered], max_colors=VISIBLE_COLOR_LIMIT)
    output = clean_transparency(apply_palette(registered, palette))
    return output, {
        "source": source_audit(subject),
        "paste_origin": list(paste_origin),
        "foot_target": list(BUILDING_FOOT_TARGET),
        "measured_foot_anchor": list(foot_anchor(output)),
        "oversized_source_policy": "reject_and_regenerate_without_logical_resize",
        "visible_palette_size": len(palette),
    }


def _build_material(
    *,
    label: str,
    source_path: Path,
    output_path: Path,
) -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        source_path,
        max_subject_size=MATERIAL_CANVAS_SIZE,
        fit_oversized=False,
    )
    expected_size = MATERIAL_EXPECTED_SIZES[label]
    if subject.detected_logical_size != expected_size:
        raise RuntimeError(
            f"{label} source logical size changed: expected {expected_size}, "
            f"got {subject.detected_logical_size}"
        )
    if subject.logical_size != subject.detected_logical_size:
        raise RuntimeError(f"{label} must retain its detected logical size")

    palette = build_shared_palette([subject.image], max_colors=VISIBLE_COLOR_LIMIT)
    logical = clean_transparency(apply_palette(subject.image, palette))
    paste_origin = (
        (MATERIAL_CANVAS_SIZE[0] - logical.width) // 2,
        (MATERIAL_CANVAS_SIZE[1] - logical.height) // 2,
    )
    output = Image.new("RGBA", MATERIAL_CANVAS_SIZE, TRANSPARENT)
    output.alpha_composite(logical, paste_origin)
    output = clean_transparency(output)

    bbox = output.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError(f"{label} output is empty")
    subject_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])
    margins = (
        bbox[0],
        bbox[1],
        MATERIAL_CANVAS_SIZE[0] - bbox[2],
        MATERIAL_CANVAS_SIZE[1] - bbox[3],
    )
    centered = abs(margins[0] - margins[2]) <= 1 and abs(
        margins[1] - margins[3]
    ) <= 1
    transparency = _transparency_audit(output)
    visible_colors = _visible_color_count(output)
    checks = {
        "canvas_32x32": output.size == MATERIAL_CANVAS_SIZE,
        "detected_logical_size_retained": subject_size
        == subject.detected_logical_size,
        "centered_with_balanced_margins": centered,
        "binary_alpha": transparency["binary_alpha"],
        "transparent_rgb_clean": transparency["transparent_rgb_clean"],
        "visible_colors_at_most_32": visible_colors <= VISIBLE_COLOR_LIMIT,
        "no_logical_fit": subject.logical_fit_scale == 1.0,
    }
    return output, {
        "source": source_audit(subject),
        "output_path": portable_path(output_path),
        "canvas_size": list(output.size),
        "subject_bbox_exclusive": list(bbox),
        "subject_size": list(subject_size),
        "paste_origin": list(paste_origin),
        "margins_left_top_right_bottom": list(margins),
        "visible_palette_size": len(palette),
        "visible_color_count": visible_colors,
        "alpha_values": transparency["alpha_values"],
        "checks": checks,
        "passed": all(checks.values()),
    }


def main() -> None:
    building, building_context = _build_building()
    blue_powder, blue_context = _build_material(
        label="capoo_blue_crystal_powder",
        source_path=BLUE_POWDER_SOURCE,
        output_path=BLUE_POWDER_OUTPUT,
    )
    white_powder, white_context = _build_material(
        label="white_crystal_powder",
        source_path=WHITE_POWDER_SOURCE,
        output_path=WHITE_POWDER_OUTPUT,
    )

    building_audit = audit_image(
        building,
        label="stone_mill",
        path=portable_path(BUILDING_OUTPUT),
        max_subject_size=BUILDING_MAX_SIZE,
    )
    building_transparency = _transparency_audit(building)
    building_colors = _visible_color_count(building)
    building_checks = {
        "visible_colors_at_most_32": building_colors <= VISIBLE_COLOR_LIMIT,
        "binary_alpha": building_transparency["binary_alpha"],
        "transparent_rgb_clean": building_transparency[
            "transparent_rgb_clean"
        ],
        "foot_anchor_matches_target": tuple(foot_anchor(building))
        == tuple(float(value) for value in BUILDING_FOOT_TARGET),
    }

    failures = validation_failures([building_audit])
    failures.extend(
        f"stone_mill: {name}"
        for name, passed in building_checks.items()
        if not passed
    )
    for label, context in (
        ("capoo_blue_crystal_powder", blue_context),
        ("white_crystal_powder", white_context),
    ):
        failures.extend(
            f"{label}: {name}"
            for name, passed in context["checks"].items()
            if not passed
        )

    report = {
        "schema_version": 1,
        "asset_family": "stone_mill",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen precise-object-edit masters",
            "flat #FF00FF chroma key",
            "plant_pixel_asset_pipeline measured logical-grid center sampling",
            "fit_oversized=False for every source",
            "detected powder logical sizes retained and centered on 32x32 canvases",
            "palette reduction to at most 32 colors without dithering",
            "binary-alpha and transparent-RGB audit",
        ],
        "building": {
            **building_context,
            "visible_color_count": building_colors,
            "alpha_values": building_transparency["alpha_values"],
            "strict_checks": building_checks,
            "audit": building_audit,
        },
        "materials": {
            "capoo_blue_crystal_powder": blue_context,
            "white_crystal_powder": white_context,
        },
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))

    BUILDING_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    BLUE_POWDER_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    WHITE_POWDER_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    building.save(BUILDING_OUTPUT, optimize=True, compress_level=9)
    blue_powder.save(BLUE_POWDER_OUTPUT, optimize=True, compress_level=9)
    white_powder.save(WHITE_POWDER_OUTPUT, optimize=True, compress_level=9)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Built Stone Mill: {BUILDING_OUTPUT}")
    print(f"Built blue crystal powder: {BLUE_POWDER_OUTPUT}")
    print(f"Built white crystal powder: {WHITE_POWDER_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
