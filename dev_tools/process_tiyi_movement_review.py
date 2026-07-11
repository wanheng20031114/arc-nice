#!/usr/bin/env python3
"""Decode only Tiyi's 16 authored movement frames for visual review.

This deliberately does not write runtime assets.  It measures every frame with
the project's pixel-grid analyzer, resolves the calibrated 8/9px integer
lattice, and emits exactly one output pixel for every visual logical-pixel
cell.  No resize and no palette quantization are used.  Generated candidates
use a separate filename so this tool can never overwrite the approved source.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from pixel_grid_analyzer import analyze_image
from process_tiyi_assets import (
    ALPHA_THRESHOLD,
    FRAME_SIZE,
    MOVEMENT_DIRECTION_NAMES,
    MOVEMENT_FRAME_SPECS,
    _central_cell_bounds,
    _movement_components,
    _rounded_lattice_boundaries,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "dev_assets" / "source_images" / "player_tiyi" / "movement_alpha.png"
OUTPUT_PATH = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "player_tiyi"
    / "movement_logical_candidate.png"
)
REPORT_PATH = OUTPUT_PATH.with_suffix(".json")
FRAME_COLUMNS = 4
FRAME_ROWS = 4
ANALYZER_PADDING = 18
EXPECTED_VISIBLE_LOGICAL_PIXELS = (
    (317, 316, 311, 315),
    (319, 320, 314, 316),
    (288, 284, 276, 286),
    (288, 287, 276, 279),
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _normalize_detected_period(period: float) -> float:
    """Promote an occasional half-period harmonic back to the visual grid."""
    while 1.0 < period < 7.0:
        period *= 2.0
    return period


def _source_rgb_medoid(colors: np.ndarray) -> np.ndarray:
    """Choose the actual source RGB minimizing total L1 error in the cell."""
    unique, counts = np.unique(colors.astype(np.int32), axis=0, return_counts=True)
    pairwise_l1 = np.abs(unique[:, None, :] - unique[None, :, :]).sum(axis=2)
    total_error = pairwise_l1 @ counts
    minimum_error = int(total_error.min())
    candidates = np.flatnonzero(total_error == minimum_error)
    if len(candidates) > 1:
        candidate_counts = counts[candidates]
        candidates = candidates[candidate_counts == candidate_counts.max()]
    # np.unique is lexicographically sorted, so the final tie-break is stable.
    return unique[int(candidates[0])].astype(np.uint8)


def _frame_analyzer_measurement(
    source: Image.Image,
    bbox: tuple[int, int, int, int],
) -> dict[str, object]:
    left, top, right, bottom = bbox
    crop_box = (
        max(0, left - ANALYZER_PADDING),
        max(0, top - ANALYZER_PADDING),
        min(source.width, right + ANALYZER_PADDING),
        min(source.height, bottom + ANALYZER_PADDING),
    )
    result = analyze_image(source.crop(crop_box))
    result["grid_cell_width"] = round(
        _normalize_detected_period(float(result["grid_cell_width"])), 3
    )
    result["grid_cell_height"] = round(
        _normalize_detected_period(float(result["grid_cell_height"])), 3
    )
    return result


def _decode_frame(
    source_rgba: np.ndarray,
    component_area: int,
    bbox: tuple[int, int, int, int],
    spec: tuple[int, int, int, int, float, float, float, float],
) -> tuple[Image.Image, dict[str, object]]:
    logical_width, logical_height, target_x, target_y, period_x, period_y, delta_x, delta_y = spec
    left, top, right, bottom = bbox
    x_boundaries = _rounded_lattice_boundaries(left + delta_x, period_x, logical_width)
    y_boundaries = _rounded_lattice_boundaries(top + delta_y, period_y, logical_height)
    logical = np.zeros((logical_height, logical_width, 4), dtype=np.uint8)

    ambiguous_alpha_cells = 0
    visible_logical_pixels = 0
    representative_from_source = 0
    central_color_absolute_error = 0
    central_color_sample_count = 0
    for logical_y in range(logical_height):
        cell_top, cell_bottom = _central_cell_bounds(
            y_boundaries[logical_y], y_boundaries[logical_y + 1]
        )
        for logical_x in range(logical_width):
            cell_left, cell_right = _central_cell_bounds(
                x_boundaries[logical_x], x_boundaries[logical_x + 1]
            )
            sample = source_rgba[cell_top:cell_bottom, cell_left:cell_right]
            visible = sample[:, :, 3] >= ALPHA_THRESHOLD
            coverage = float(visible.mean())
            if coverage not in (0.0, 1.0):
                ambiguous_alpha_cells += 1
            if coverage < 0.5:
                continue

            source_colors = sample[:, :, :3][visible]
            representative = _source_rgb_medoid(source_colors)
            logical[logical_y, logical_x, :3] = representative
            logical[logical_y, logical_x, 3] = 255
            visible_logical_pixels += 1
            if np.any(np.all(source_colors == representative, axis=1)):
                representative_from_source += 1
            central_color_absolute_error += int(
                np.abs(source_colors.astype(np.int32) - representative.astype(np.int32)).sum()
            )
            central_color_sample_count += int(source_colors.size)

    if ambiguous_alpha_cells != 0:
        raise AssertionError(
            f"Frame {bbox} has {ambiguous_alpha_cells} ambiguous logical Alpha cells"
        )
    if representative_from_source != visible_logical_pixels:
        raise AssertionError("A representative RGB was synthesized instead of copied from its source cell")

    native = Image.fromarray(logical)
    expected_native_bbox = (0, 0, logical_width, logical_height)
    if native.getchannel("A").getbbox() != expected_native_bbox:
        raise AssertionError(
            f"Decoded frame bbox {native.getchannel('A').getbbox()} != {expected_native_bbox}"
        )
    canvas = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(native, (target_x, target_y))

    source_lattice_alpha = (
        source_rgba[
            y_boundaries[0] : y_boundaries[-1],
            x_boundaries[0] : x_boundaries[-1],
            3,
        ]
        >= ALPHA_THRESHOLD
    )
    reconstructed_alpha = np.zeros_like(source_lattice_alpha)
    for logical_y in range(logical_height):
        for logical_x in range(logical_width):
            if logical[logical_y, logical_x, 3] != 255:
                continue
            reconstructed_alpha[
                y_boundaries[logical_y] - y_boundaries[0] : y_boundaries[logical_y + 1]
                - y_boundaries[0],
                x_boundaries[logical_x] - x_boundaries[0] : x_boundaries[logical_x + 1]
                - x_boundaries[0],
            ] = True
    intersection = int(np.logical_and(source_lattice_alpha, reconstructed_alpha).sum())
    union = int(np.logical_or(source_lattice_alpha, reconstructed_alpha).sum())
    alpha_iou = intersection / union

    alpha = logical[:, :, 3] == 255
    visible_y, visible_x = np.where(alpha)
    expected_logical_area = component_area / (period_x * period_y)
    area_error = abs(visible_logical_pixels - expected_logical_area) / expected_logical_area
    return canvas, {
        "source_bbox": [left, top, right, bottom],
        "source_component_area": component_area,
        "registered_grid_period": [period_x, period_y],
        "registered_boundary_delta": [delta_x, delta_y],
        "physical_cell_widths": sorted({int(value) for value in np.diff(x_boundaries)}),
        "physical_cell_heights": sorted({int(value) for value in np.diff(y_boundaries)}),
        "logical_size": [logical_width, logical_height],
        "target_bbox": [target_x, target_y, target_x + logical_width, target_y + logical_height],
        "total_logical_cells": logical_width * logical_height,
        "visible_logical_pixels": visible_logical_pixels,
        "ambiguous_alpha_cells": ambiguous_alpha_cells,
        "representative_rgb_copied_from_source_percent": round(
            representative_from_source / max(visible_logical_pixels, 1) * 100.0, 3
        ),
        "central_rgb_mean_absolute_error": round(
            central_color_absolute_error / max(central_color_sample_count, 1), 4
        ),
        "source_reprojection_alpha_iou": round(alpha_iou, 5),
        "logical_area_error_percent": round(area_error * 100.0, 3),
        "alpha_centroid": [
            round(float(visible_x.mean() + target_x), 3),
            round(float(visible_y.mean() + target_y), 3),
        ],
        "foot_baseline": int(visible_y.max() + target_y),
    }


def main() -> None:
    if not SOURCE_PATH.is_file():
        raise FileNotFoundError(SOURCE_PATH)
    source = Image.open(SOURCE_PATH).convert("RGBA")
    source_rgba = np.array(source, dtype=np.uint8)
    components = _movement_components(source)
    sheet = Image.new(
        "RGBA",
        (FRAME_COLUMNS * FRAME_SIZE, FRAME_ROWS * FRAME_SIZE),
        (0, 0, 0, 0),
    )
    frame_reports: list[dict[str, object]] = []

    for row, row_components in enumerate(components):
        for column, (component_area, bbox) in enumerate(row_components):
            spec = MOVEMENT_FRAME_SPECS[row][column]
            analyzer = _frame_analyzer_measurement(source, bbox)
            detected_x = float(analyzer["grid_cell_width"])
            detected_y = float(analyzer["grid_cell_height"])
            if abs(detected_x - spec[4]) > 0.12 or abs(detected_y - spec[5]) > 0.12:
                raise AssertionError(
                    f"Analyzer period {(detected_x, detected_y)} disagrees with registered "
                    f"period {(spec[4], spec[5])} for frame {(row, column)}"
                )
            frame, report = _decode_frame(source_rgba, component_area, bbox, spec)
            expected_visible_pixels = EXPECTED_VISIBLE_LOGICAL_PIXELS[row][column]
            if int(report["visible_logical_pixels"]) != expected_visible_pixels:
                raise AssertionError(
                    f"Frame {(row, column)} retained {report['visible_logical_pixels']} logical "
                    f"pixels instead of calibrated {expected_visible_pixels}"
                )
            report["direction"] = MOVEMENT_DIRECTION_NAMES[row]
            report["frame"] = column
            report["logical_pixel_presence_matches_calibration"] = True
            report["pipeline_analyzer"] = {
                "detection_mode": analyzer["detection_mode"],
                "detected_grid_period": [detected_x, detected_y],
                "confidence": analyzer["confidence"],
            }
            frame_reports.append(report)
            sheet.alpha_composite(frame, (column * FRAME_SIZE, row * FRAME_SIZE))

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUTPUT_PATH, optimize=True)
    rgba = np.array(sheet, dtype=np.uint8)
    visible = rgba[:, :, 3] == 255
    transparent = ~visible
    if np.any(rgba[:, :, 3][visible] != 255) or np.any(rgba[transparent] != 0):
        raise AssertionError("Review image must use hard Alpha and zero transparent RGB")

    report = {
        "scope": "movement_alpha rows 0-3 only; no death frames and no runtime integration",
        "source": SOURCE_PATH.relative_to(ROOT).as_posix(),
        "output": OUTPUT_PATH.relative_to(ROOT).as_posix(),
        "source_sha256": _sha256(SOURCE_PATH),
        "output_sha256": _sha256(OUTPUT_PATH),
        "output_size": list(sheet.size),
        "frame_grid": "4 columns x 4 rows of 32x32 review cells",
        "resize_used": False,
        "palette_quantization_used": False,
        "color_rule": "actual source RGB medoid from each logical cell's central 60%",
        "alpha_rule": "central 60% must be entirely visible or entirely transparent",
        "total_logical_cells": sum(int(frame["total_logical_cells"]) for frame in frame_reports),
        "visible_logical_pixels": sum(
            int(frame["visible_logical_pixels"]) for frame in frame_reports
        ),
        "ambiguous_alpha_cells": sum(
            int(frame["ambiguous_alpha_cells"]) for frame in frame_reports
        ),
        "logical_pixel_presence_match_percent": 100.0,
        "minimum_source_reprojection_alpha_iou": min(
            float(frame["source_reprojection_alpha_iou"]) for frame in frame_reports
        ),
        "maximum_logical_area_error_percent": max(
            float(frame["logical_area_error_percent"]) for frame in frame_reports
        ),
        "unique_visible_rgb_count": int(
            len(np.unique(rgba[:, :, :3][visible], axis=0))
        ),
        "frames": frame_reports,
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"Tiyi movement review written to {OUTPUT_PATH}")
    print(f"Measurement report written to {REPORT_PATH}")


if __name__ == "__main__":
    main()
