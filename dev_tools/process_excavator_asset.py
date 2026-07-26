#!/usr/bin/env python3
"""Build and strictly audit the Excavator and Dirt Block pixel assets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    TRANSPARENT,
    WORLD_FOOTPRINT_SIDE,
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
EXCAVATOR_SOURCE_DIR = (
    ROOT / "dev_assets/source_images/plant_defense/excavator"
)
EXCAVATOR_SOURCE = (
    EXCAVATOR_SOURCE_DIR / "excavator_imagegen_magenta_v2.png"
)
DIRT_BLOCK_SOURCE = (
    ROOT
    / "dev_assets/source_images/materials/dirt_block"
    / "dirt_block_imagegen_magenta_v1.png"
)
EXCAVATOR_OUTPUT = (
    ROOT / "resources/texture/plant_defense/excavator/excavator.png"
)
DIRT_BLOCK_OUTPUT = ROOT / "resources/texture/materials/dirt_block.png"
AUDIT_OUTPUT = EXCAVATOR_SOURCE_DIR / "excavator_asset_audit.json"

EXCAVATOR_EXPECTED_SIZE = (46, 50)
EXCAVATOR_MAX_SIZE = (64, 64)
EXCAVATOR_FOOT_TARGET = (32, 62)
EXCAVATOR_COLOR_LIMIT = 64
DIRT_BLOCK_EXPECTED_SIZE = (22, 22)
DIRT_BLOCK_CANVAS_SIZE = (32, 32)
DIRT_BLOCK_COLOR_LIMIT = 32

FINAL_IMAGEGEN_PROMPT_SUMMARIES = {
    "excavator": (
        "Use the v1 Excavator as the design target and the existing Wood "
        "Processing Station, Stone Mill, Oak Warehouse, and Water Collector "
        "as style references. Preserve the compact chassis, front-center "
        "drill, small right-side soil hopper, and copper-and-iron palette; "
        "strongly simplify pipes, bolts, and railings into uniform large "
        "square pixel blocks, keeping the subject within 54x58 logical "
        "pixels on a pure #FF00FF background. No shadow, ground, grass, "
        "water, scenery, or text."
    ),
    "dirt_block": (
        "One centered brown compacted-dirt block or soil clod, about 22 "
        "logical pixels across for a 32x32 inventory canvas, drawn with "
        "uniform coarse square pixels on a pure #FF00FF background. No "
        "grass, roots, loose pieces, container, ground, text, or UI."
    ),
}


def _visible_color_count(image: Image.Image) -> int:
    return len(
        {
            (red, green, blue)
            for red, green, blue, alpha in image.convert("RGBA").getdata()
            if alpha > 0
        }
    )


def _transparency_metrics(image: Image.Image) -> dict:
    rgba = image.convert("RGBA")
    alpha_values = sorted(set(rgba.getchannel("A").getdata()))
    transparent_rgb_clean = all(
        alpha > 0 or (red, green, blue) == (0, 0, 0)
        for red, green, blue, alpha in rgba.getdata()
    )
    return {
        "alpha_values": alpha_values,
        "binary_alpha": set(alpha_values).issubset({0, 255}),
        "transparent_rgb_clean": transparent_rgb_clean,
    }


def _build_excavator() -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        EXCAVATOR_SOURCE,
        max_subject_size=EXCAVATOR_MAX_SIZE,
        fit_oversized=False,
    )
    registered, paste_origin = place_bottom_center(
        subject.image,
        target=EXCAVATOR_FOOT_TARGET,
    )
    palette = build_shared_palette(
        [registered],
        max_colors=EXCAVATOR_COLOR_LIMIT,
    )
    output = clean_transparency(apply_palette(registered, palette))
    output_audit = audit_image(
        output,
        label="excavator",
        path=portable_path(EXCAVATOR_OUTPUT),
        max_subject_size=EXCAVATOR_MAX_SIZE,
    )
    measured_foot_anchor = foot_anchor(output)
    strict_checks = {
        "fit_oversized_is_disabled": True,
        "detected_logical_size_is_46x50": (
            subject.detected_logical_size == EXCAVATOR_EXPECTED_SIZE
        ),
        "detected_logical_size_retained": (
            subject.logical_size == subject.detected_logical_size
        ),
        "no_logical_fit": subject.logical_fit_scale == 1.0,
        "canvas_is_64x64": output.size == (CANVAS_SIDE, CANVAS_SIDE),
        "bottom_center_registered_at_32_62": (
            abs(measured_foot_anchor[0] - EXCAVATOR_FOOT_TARGET[0]) <= 0.5
            and measured_foot_anchor[1] == EXCAVATOR_FOOT_TARGET[1]
        ),
        "visible_colors_at_most_64": (
            _visible_color_count(output) <= EXCAVATOR_COLOR_LIMIT
        ),
        "binary_alpha": _transparency_metrics(output)["binary_alpha"],
        "transparent_rgb_clean": _transparency_metrics(output)[
            "transparent_rgb_clean"
        ],
    }
    return output, {
        "input_path": portable_path(EXCAVATOR_SOURCE),
        "output_path": portable_path(EXCAVATOR_OUTPUT),
        "final_imagegen_prompt_summary": FINAL_IMAGEGEN_PROMPT_SUMMARIES[
            "excavator"
        ],
        "source": source_audit(subject),
        "normalization_contract": {
            "fit_oversized": False,
            "expected_logical_subject_size": list(EXCAVATOR_EXPECTED_SIZE),
            "secondary_logical_scaling": False,
        },
        "registration": {
            "mode": "bottom_center",
            "paste_origin": list(paste_origin),
            "target": list(EXCAVATOR_FOOT_TARGET),
            "measured_foot_anchor": list(measured_foot_anchor),
        },
        "palette": {
            "limit": EXCAVATOR_COLOR_LIMIT,
            "actual_color_count": _visible_color_count(output),
            "rgb": [list(color) for color in palette],
        },
        "transparency": _transparency_metrics(output),
        "strict_checks": strict_checks,
        "audit": output_audit,
        "passed": output_audit["passed"] and all(strict_checks.values()),
    }


def _build_dirt_block() -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        DIRT_BLOCK_SOURCE,
        max_subject_size=DIRT_BLOCK_EXPECTED_SIZE,
        fit_oversized=False,
    )
    palette = build_shared_palette(
        [subject.image],
        max_colors=DIRT_BLOCK_COLOR_LIMIT,
    )
    logical = clean_transparency(apply_palette(subject.image, palette))
    paste_origin = (
        (DIRT_BLOCK_CANVAS_SIZE[0] - logical.width) // 2,
        (DIRT_BLOCK_CANVAS_SIZE[1] - logical.height) // 2,
    )
    output = Image.new("RGBA", DIRT_BLOCK_CANVAS_SIZE, TRANSPARENT)
    output.alpha_composite(logical, paste_origin)
    output = clean_transparency(output)

    bbox = output.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Dirt Block output is empty")
    subject_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])
    margins = (
        bbox[0],
        bbox[1],
        DIRT_BLOCK_CANVAS_SIZE[0] - bbox[2],
        DIRT_BLOCK_CANVAS_SIZE[1] - bbox[3],
    )
    transparency = _transparency_metrics(output)
    visible_colors = _visible_color_count(output)
    strict_checks = {
        "fit_oversized_is_disabled": True,
        "canvas_is_32x32": output.size == DIRT_BLOCK_CANVAS_SIZE,
        "detected_logical_size_is_22x22": (
            subject.detected_logical_size == DIRT_BLOCK_EXPECTED_SIZE
        ),
        "logical_22x22_subject_retained_without_secondary_scaling": (
            subject.logical_size == DIRT_BLOCK_EXPECTED_SIZE
            and logical.size == DIRT_BLOCK_EXPECTED_SIZE
            and subject_size == DIRT_BLOCK_EXPECTED_SIZE
        ),
        "no_logical_fit": subject.logical_fit_scale == 1.0,
        "centered_with_balanced_margins": (
            margins[0] == margins[2] and margins[1] == margins[3]
        ),
        "visible_colors_at_most_32": visible_colors <= DIRT_BLOCK_COLOR_LIMIT,
        "binary_alpha": transparency["binary_alpha"],
        "transparent_rgb_clean": transparency["transparent_rgb_clean"],
    }
    return output, {
        "input_path": portable_path(DIRT_BLOCK_SOURCE),
        "output_path": portable_path(DIRT_BLOCK_OUTPUT),
        "final_imagegen_prompt_summary": FINAL_IMAGEGEN_PROMPT_SUMMARIES[
            "dirt_block"
        ],
        "source": source_audit(subject),
        "normalization_contract": {
            "fit_oversized": False,
            "expected_logical_subject_size": list(DIRT_BLOCK_EXPECTED_SIZE),
            "secondary_logical_scaling": False,
        },
        "canvas_size": list(output.size),
        "subject_bbox_exclusive": list(bbox),
        "subject_size": list(subject_size),
        "paste_origin": list(paste_origin),
        "margins_left_top_right_bottom": list(margins),
        "palette": {
            "limit": DIRT_BLOCK_COLOR_LIMIT,
            "actual_color_count": visible_colors,
            "rgb": [list(color) for color in palette],
        },
        "transparency": transparency,
        "strict_checks": strict_checks,
        "passed": all(strict_checks.values()),
    }


def build_assets() -> tuple[dict[str, Image.Image], dict]:
    excavator, excavator_report = _build_excavator()
    dirt_block, dirt_block_report = _build_dirt_block()

    failures = validation_failures([excavator_report["audit"]])
    failures.extend(
        f"excavator: {name}"
        for name, passed in excavator_report["strict_checks"].items()
        if not passed
    )
    failures.extend(
        f"dirt_block: {name}"
        for name, passed in dirt_block_report["strict_checks"].items()
        if not passed
    )
    report = {
        "schema_version": 1,
        "asset_family": "excavator",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen final masters on flat #FF00FF",
            "plant_pixel_asset_pipeline connected chroma-key removal",
            "pixel_grid_analyzer measured logical-grid center sampling",
            "fit_oversized=False with exact detected-size retention",
            "palette reduction without dithering",
            "binary-alpha hardening and transparent-RGB clearing",
            "strict output-contract audit before file writes",
        ],
        "visual_contract": {
            "excavator_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "excavator_subject_limit_px": list(EXCAVATOR_MAX_SIZE),
            "excavator_foot_target_px": list(EXCAVATOR_FOOT_TARGET),
            "excavator_visible_color_limit": EXCAVATOR_COLOR_LIMIT,
            "world_scale": [WORLD_SCALE, WORLD_SCALE],
            "world_footprint_px": [
                WORLD_FOOTPRINT_SIDE,
                WORLD_FOOTPRINT_SIDE,
            ],
            "dirt_block_canvas_px": list(DIRT_BLOCK_CANVAS_SIZE),
            "dirt_block_subject_px": list(DIRT_BLOCK_EXPECTED_SIZE),
            "dirt_block_visible_color_limit": DIRT_BLOCK_COLOR_LIMIT,
            "alpha": "binary",
            "transparent_rgb": [0, 0, 0],
        },
        "imagegen_inputs": [
            {
                "asset": "excavator",
                "input_path": portable_path(EXCAVATOR_SOURCE),
                "final_prompt_summary": FINAL_IMAGEGEN_PROMPT_SUMMARIES[
                    "excavator"
                ],
            },
            {
                "asset": "dirt_block",
                "input_path": portable_path(DIRT_BLOCK_SOURCE),
                "final_prompt_summary": FINAL_IMAGEGEN_PROMPT_SUMMARIES[
                    "dirt_block"
                ],
            },
        ],
        "excavator": excavator_report,
        "dirt_block": dirt_block_report,
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    return {"excavator": excavator, "dirt_block": dirt_block}, report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate in memory without writing PNG or audit files.",
    )
    args = parser.parse_args()

    assets, report = build_assets()
    if args.check_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    EXCAVATOR_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    DIRT_BLOCK_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    assets["excavator"].save(
        EXCAVATOR_OUTPUT,
        optimize=True,
        compress_level=9,
    )
    assets["dirt_block"].save(
        DIRT_BLOCK_OUTPUT,
        optimize=True,
        compress_level=9,
    )
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Excavator: {EXCAVATOR_OUTPUT}")
    print(f"Built Dirt Block: {DIRT_BLOCK_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
