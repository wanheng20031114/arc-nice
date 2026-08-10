#!/usr/bin/env python3
"""Build and audit the selected Planting Base building sprite.

The selected source contains enclosed background openings, so this processor
uses the sampled magenta candidate mask globally instead of a border-only flood
fill.  The generated source is already within the logical-size contract, so it
is reduced exactly once by selecting one center pixel per measured logical cell.
No fitting resize, interpolation, color averaging, antialiasing, or smoothing
is allowed.  The audited 64x64 result is also split into complementary lower
and upper draw layers from the user's reviewed blue-outline mask.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from connected_background_remover import (
    ConnectedBackgroundOptions,
    build_sample_background_mask,
)
from pixel_grid_analyzer import analyze_image
from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    WORLD_SCALE,
    _measure_periodic_pixel_grid,
    apply_palette,
    audit_image,
    build_shared_palette,
    clean_transparency,
    foot_anchor,
    place_bottom_center,
    portable_path,
    validation_failures,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/planting_base"
SOURCE = (
    SOURCE_DIR
    / "planting_base_selected_native_coarse_imagegen_magenta.png"
)
OUTPUT_DIR = (
    ROOT
    / "resources/texture/plant_defense/planting_base"
)
OUTPUT = OUTPUT_DIR / "planting_base.png"
LOWER_LAYER_OUTPUT = OUTPUT_DIR / "layers/lower_body.png"
UPPER_LAYER_OUTPUT = OUTPUT_DIR / "layers/upper_canopy.png"
AUDIT_OUTPUT = ROOT / "dev_tools/output/plant_defense/planting_base_asset_audit.json"

SUBJECT_LIMIT = (60, 60)
# An even-width 56px subject is geometrically centered on the 64px canvas at
# x=31.5 (the midpoint between the two central pixel columns).
FOOT_TARGET = (31.5, 62)
COLOR_LIMIT = 64

# Source-specific safety gate established from the selected image's visible
# square-pixel cadence.  A changed or non-pixel source must fail instead of
# silently receiving an arbitrary high-resolution resize.
MIN_REVIEWED_PERIOD = 15.5
MAX_REVIEWED_PERIOD = 18.5
MIN_AXIS_PHASE_SCORE = 0.65
MAX_PERIOD_RATIO = 1.05

# Center-sampled interior of the user's blue outline, mapped from the annotated
# 8x preview back onto the 64x64 logical canvas.  The lower rows deliberately
# fork around the central nursery basin; the isolated hand-drawn y=26 tail is
# excluded so the semantic upper layer ends cleanly on both arch legs.  Values
# are (y_begin, y_end, x_begin, x_end), with exclusive end coordinates.
UPPER_CANOPY_LAYER_SPANS = (
    (0, 1, 23, 34),
    (1, 2, 20, 39),
    (2, 3, 18, 42),
    (3, 4, 16, 43),
    (4, 5, 15, 44),
    (5, 7, 14, 45),
    (7, 9, 14, 46),
    (9, 15, 13, 47),
    (15, 16, 14, 47),
    (16, 17, 15, 47),
    (17, 18, 16, 47),
    (18, 19, 17, 46),
    (19, 20, 19, 46),
    (20, 21, 20, 45),
    (21, 22, 21, 43),
    (22, 23, 22, 41),
    (23, 24, 23, 40),
    (24, 25, 23, 27),
    (24, 25, 36, 40),
    (25, 26, 23, 26),
    (25, 26, 37, 40),
)
EXPECTED_UPPER_VISIBLE_PIXELS = 383


def _global_magenta_key(source_path: Path) -> tuple[Image.Image, dict]:
    """Remove all sampled magenta cells, including enclosed architectural holes."""
    if not source_path.is_file():
        raise FileNotFoundError(source_path)

    with Image.open(source_path) as source_image:
        source = source_image.convert("RGBA")
    array = np.array(source, dtype=np.uint8)
    options = ConnectedBackgroundOptions(
        sample=(0, 0),
        rgb_tolerance=72,
        hue_tolerance=0.035,
        expansion_radius=12,
        harden_alpha=True,
    )
    background_mask = build_sample_background_mask(array, options)
    original_alpha = array[:, :, 3] > 0
    visible_mask = (~background_mask) & original_alpha
    array[background_mask] = (0, 0, 0, 0)
    array[visible_mask, 3] = 255
    keyed = clean_transparency(Image.fromarray(array))
    bbox = keyed.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Planting Base chroma key produced an empty subject")

    return keyed, {
        "mode": "global_sampled_magenta_candidate_mask",
        "sample_rgb": list(source.getpixel(options.sample)[:3]),
        "rgb_tolerance": options.rgb_tolerance,
        "hue_tolerance": options.hue_tolerance,
        "removed_pixel_count": int(np.count_nonzero(background_mask)),
        "visible_pixel_count": int(np.count_nonzero(visible_mask)),
        "reason": "selected arch and channels contain enclosed background holes",
    }


def _center_sample(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Select exactly one source-pixel center for each destination pixel."""
    target_width, target_height = size
    if target_width <= 0 or target_height <= 0:
        raise ValueError(f"Invalid center-sample target: {size}")

    source = np.array(image.convert("RGBA"), dtype=np.uint8)
    source_height, source_width = source.shape[:2]
    x_indices = np.minimum(
        ((np.arange(target_width) + 0.5) * source_width / target_width).astype(int),
        source_width - 1,
    )
    y_indices = np.minimum(
        ((np.arange(target_height) + 0.5) * source_height / target_height).astype(int),
        source_height - 1,
    )
    sampled = source[y_indices[:, None], x_indices[None, :]]
    return clean_transparency(Image.fromarray(sampled))


def _measure_reviewed_grid(keyed: Image.Image) -> tuple[dict, tuple[int, int, int, int]]:
    general_analysis = analyze_image(keyed)
    bbox_data = general_analysis["subject_bbox"]
    bbox = (
        int(bbox_data["left"]),
        int(bbox_data["top"]),
        int(bbox_data["right"]),
        int(bbox_data["bottom"]),
    )
    periodic = _measure_periodic_pixel_grid(keyed.crop(bbox))
    if periodic is None:
        raise RuntimeError("Planting Base periodic logical grid was not measurable")

    periods = (
        float(periodic["grid_cell_width"]),
        float(periodic["grid_cell_height"]),
    )
    axis_scores = [float(value) for value in periodic["fallback_axis_scores"]]
    period_ratio = float(periodic["fallback_period_ratio"])
    if not all(MIN_REVIEWED_PERIOD <= value <= MAX_REVIEWED_PERIOD for value in periods):
        raise RuntimeError(f"Planting Base grid period escaped reviewed range: {periods}")
    if min(axis_scores) < MIN_AXIS_PHASE_SCORE:
        raise RuntimeError(f"Planting Base grid phase evidence is too weak: {axis_scores}")
    if period_ratio > MAX_PERIOD_RATIO:
        raise RuntimeError(f"Planting Base X/Y grid periods disagree: {period_ratio}")

    measured = {
        **periodic,
        "general_analyzer_result": general_analysis,
        "safety_gate": {
            "period_range_px": [MIN_REVIEWED_PERIOD, MAX_REVIEWED_PERIOD],
            "minimum_axis_phase_score": MIN_AXIS_PHASE_SCORE,
            "maximum_xy_period_ratio": MAX_PERIOD_RATIO,
            "passed": True,
        },
    }
    return measured, bbox


def _split_semantic_layers(
    image: Image.Image,
) -> tuple[Image.Image, Image.Image]:
    """Split the static sprite into complementary lower and upper draw layers."""
    source = np.array(image.convert("RGBA"), dtype=np.uint8)
    upper_mask = np.zeros((CANVAS_SIDE, CANVAS_SIDE), dtype=bool)
    for y_begin, y_end, x_begin, x_end in UPPER_CANOPY_LAYER_SPANS:
        upper_mask[y_begin:y_end, x_begin:x_end] = True

    upper = np.zeros_like(source)
    lower = np.zeros_like(source)
    upper[upper_mask] = source[upper_mask]
    lower[~upper_mask] = source[~upper_mask]
    return (
        clean_transparency(Image.fromarray(lower)),
        clean_transparency(Image.fromarray(upper)),
    )


def build_asset() -> tuple[Image.Image, Image.Image, Image.Image, dict]:
    keyed, chroma_key_audit = _global_magenta_key(SOURCE)
    grid_analysis, source_bbox = _measure_reviewed_grid(keyed)
    source_subject = keyed.crop(source_bbox)
    detected_size = (
        int(grid_analysis["subject_grid_width"]),
        int(grid_analysis["subject_grid_height"]),
    )
    if any(
        measured > limit
        for measured, limit in zip(detected_size, SUBJECT_LIMIT, strict=True)
    ):
        raise RuntimeError(
            "Planting Base source exceeds the logical subject contract: "
            f"detected {detected_size}, limit {SUBJECT_LIMIT}. Regenerate a "
            "natively coarser source instead of resampling it to fit."
        )

    # Select one representative source center for every measured logical cell.
    # The detected logical size must already fit: a second fitting pass would
    # skip uneven rows/columns and visibly fracture continuous pixel-art forms.
    logical_subject = _center_sample(source_subject, detected_size)
    registered, paste_origin = place_bottom_center(
        logical_subject,
        target=FOOT_TARGET,
    )
    palette = build_shared_palette([registered], max_colors=COLOR_LIMIT)
    output = apply_palette(registered, palette)
    lower_layer, upper_layer = _split_semantic_layers(output)

    output_audit = audit_image(
        output,
        label="planting_base",
        path=portable_path(OUTPUT),
        max_subject_size=SUBJECT_LIMIT,
    )
    measured_foot = foot_anchor(output)
    exact_foot_target = measured_foot == (
        float(FOOT_TARGET[0]),
        float(FOOT_TARGET[1]),
    )
    output_audit["checks"]["exact_bottom_center_foot_target"] = exact_foot_target
    output_audit["passed"] = all(output_audit["checks"].values())
    lower_audit = audit_image(
        lower_layer,
        label="planting_base_lower_body",
        path=portable_path(LOWER_LAYER_OUTPUT),
        max_subject_size=SUBJECT_LIMIT,
    )
    upper_audit = audit_image(
        upper_layer,
        label="planting_base_upper_canopy",
        path=portable_path(UPPER_LAYER_OUTPUT),
        max_subject_size=SUBJECT_LIMIT,
    )
    output_pixels = np.array(output.convert("RGBA"), dtype=np.uint8)
    lower_pixels = np.array(lower_layer.convert("RGBA"), dtype=np.uint8)
    upper_pixels = np.array(upper_layer.convert("RGBA"), dtype=np.uint8)
    upper_visible = upper_pixels[:, :, 3] > 0
    lower_visible = lower_pixels[:, :, 3] > 0
    recomposed_pixels = np.where(
        upper_visible[:, :, None],
        upper_pixels,
        lower_pixels,
    )
    semantic_checks = {
        "binary_non_overlapping": not bool(
            np.any(upper_visible & lower_visible)
        ),
        "lossless_rgba_recomposition": bool(
            np.array_equal(recomposed_pixels, output_pixels)
        ),
        "reviewed_upper_visible_pixel_count": int(
            np.count_nonzero(upper_visible)
        )
        == EXPECTED_UPPER_VISIBLE_PIXELS,
    }
    failures = validation_failures(
        [output_audit, lower_audit, upper_audit]
    )
    failures.extend(
        f"planting_base_semantic_layers: {check_name}"
        for check_name, passed in semantic_checks.items()
        if not passed
    )

    report = {
        "schema_version": 1,
        "asset_family": "planting_base",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "sampled magenta global chroma key including enclosed holes",
            "pixel_grid_analyzer baseline measurement",
            "independent periodic-phase grid measurement with strict source-specific gate",
            "single measured-cell center sample with one source logical cell per output pixel",
            "hard failure when the detected logical subject exceeds 60x60",
            "palette reduction to at most 64 colors without dithering",
            "reviewed blue-outline semantic split into complementary lower and upper draw layers",
            "binary-alpha, transparent-RGB, footprint, and foot-anchor audit",
        ],
        "visual_contract": {
            "building_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "building_subject_limit_px": list(SUBJECT_LIMIT),
            "building_footprint_cells": [2, 2],
            "building_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "building_world_size_px": [32, 32],
            "foot_target_px": list(FOOT_TARGET),
            "visible_color_limit": COLOR_LIMIT,
        },
        "source": {
            "path": portable_path(SOURCE),
            "sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "source_canvas_px": list(keyed.size),
            "subject_bbox_exclusive": list(source_bbox),
            "subject_physical_size_px": list(source_subject.size),
            "chroma_key": chroma_key_audit,
            "grid_analysis": grid_analysis,
        },
        "normalization": {
            "mode": "single_stage_measured_cell_center_sample",
            "detected_logical_subject_size": list(detected_size),
            "output_logical_subject_size": list(detected_size),
            "interpolation": "none",
            "secondary_resampling": False,
            "one_source_logical_cell_per_output_pixel": True,
            "logical_fit_reason": (
                "the imagegen repair is natively within the <=60x60 subject "
                "contract, so no fitting resample is permitted"
            ),
        },
        "registration": {
            "mode": "bottom_center",
            "paste_origin": list(paste_origin),
            "foot_target": list(FOOT_TARGET),
            "measured_foot_anchor": list(measured_foot),
        },
        "palette": {
            "mode": "median_cut_no_dither_then_nearest_palette_assignment",
            "visible_palette_size": len(palette),
        },
        "semantic_draw_layers": {
            "mode": "reviewed_blue_outline_logical_row_spans",
            "upper_canopy_row_spans": [
                list(span) for span in UPPER_CANOPY_LAYER_SPANS
            ],
            "upper_z_index": 4,
            "lower_z_index": 0,
            "upper_visible_pixel_count": int(
                np.count_nonzero(upper_visible)
            ),
            "lower_visible_pixel_count": int(
                np.count_nonzero(lower_visible)
            ),
            "checks": semantic_checks,
            "lower_output": lower_audit,
            "upper_output": upper_audit,
        },
        "output": output_audit,
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    return output, lower_layer, upper_layer, report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    output, lower_layer, upper_layer, report = build_asset()
    if args.check_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    output.save(OUTPUT, format="PNG", optimize=True, compress_level=9)
    LOWER_LAYER_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    lower_layer.save(
        LOWER_LAYER_OUTPUT,
        format="PNG",
        optimize=True,
        compress_level=9,
    )
    upper_layer.save(
        UPPER_LAYER_OUTPUT,
        format="PNG",
        optimize=True,
        compress_level=9,
    )
    AUDIT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Planting Base sprite: {OUTPUT}")
    print(f"Built Planting Base lower layer: {LOWER_LAYER_OUTPUT}")
    print(f"Built Planting Base upper layer: {UPPER_LAYER_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
