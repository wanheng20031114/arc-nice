#!/usr/bin/env python3
"""Build a grid-normalized 32x32 collectible icon from an alpha PNG.

The generated source is expected to already have a transparent background. The
script estimates the source's visual pixel grid, reduces every detected grid
cell to one representative logical pixel, and only then crops and centers the
logical subject. Oversized logical subjects are rejected instead of silently
losing detail through another downscale.
"""

from __future__ import annotations

import argparse
from collections import deque
import json
import sys
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image


CANVAS_SIZE = 32
DEFAULT_CELL_ALPHA_COVERAGE = 0.25


def _alpha_normalized(image: Image.Image, alpha_threshold: int) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= alpha_threshold:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return rgba


def _axis_boundaries(start: int, end: int, cell_count: int) -> list[int]:
    """Split an analyzer bbox into deterministic, non-overlapping grid cells."""
    span = end - start
    if cell_count <= 0 or span < cell_count:
        raise ValueError(
            f"Invalid grid geometry: {cell_count} cells cannot cover {span} pixels"
        )

    return [start + (span * index) // cell_count for index in range(cell_count + 1)]


def _representative_cell_pixel(
    source: Image.Image,
    bbox: tuple[int, int, int, int],
    alpha_threshold: int,
    coverage_threshold: float,
) -> tuple[int, int, int, int]:
    """Return one opaque source-representative color for a physical grid cell."""
    left, top, right, bottom = bbox
    area = (right - left) * (bottom - top)
    if area <= 0:
        return (0, 0, 0, 0)

    pixels = source.load()
    samples: list[tuple[int, int, int, int, int, int]] = []
    total_alpha = 0
    weighted_red = 0
    weighted_green = 0
    weighted_blue = 0

    for y in range(top, bottom):
        for x in range(left, right):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= alpha_threshold:
                continue
            samples.append((red, green, blue, alpha, x, y))
            total_alpha += alpha
            weighted_red += red * alpha
            weighted_green += green * alpha
            weighted_blue += blue * alpha

    coverage = total_alpha / float(area * 255)
    if not samples or coverage < coverage_threshold:
        return (0, 0, 0, 0)

    def representative_key(sample: tuple[int, int, int, int, int, int]) -> tuple[int, int, int, int]:
        red, green, blue, alpha, x, y = sample
        distance = (
            (red * total_alpha - weighted_red) ** 2
            + (green * total_alpha - weighted_green) ** 2
            + (blue * total_alpha - weighted_blue) ** 2
        )
        return (distance, -alpha, y, x)

    red, green, blue, _alpha, _x, _y = min(samples, key=representative_key)
    return (red, green, blue, 255)


def _normalize_to_logical_grid(
    source: Image.Image,
    bbox: tuple[int, int, int, int],
    logical_width: int,
    logical_height: int,
    alpha_threshold: int,
    coverage_threshold: float,
) -> Image.Image:
    """Collapse each analyzer-provided physical grid cell to one logical pixel."""
    x_boundaries = _axis_boundaries(bbox[0], bbox[2], logical_width)
    y_boundaries = _axis_boundaries(bbox[1], bbox[3], logical_height)
    logical = Image.new("RGBA", (logical_width, logical_height), (0, 0, 0, 0))
    logical_pixels = logical.load()

    for logical_y in range(logical_height):
        for logical_x in range(logical_width):
            cell_bbox = (
                x_boundaries[logical_x],
                y_boundaries[logical_y],
                x_boundaries[logical_x + 1],
                y_boundaries[logical_y + 1],
            )
            logical_pixels[logical_x, logical_y] = _representative_cell_pixel(
                source,
                cell_bbox,
                alpha_threshold,
                coverage_threshold,
            )

    return logical


def _force_black_exterior_boundary(image: Image.Image) -> Image.Image:
    """Make every visible pixel touching exterior transparency pure black."""
    result = image.convert("RGBA")
    pixels = result.load()
    width, height = result.size
    exterior = [[False] * width for _ in range(height)]
    queue: deque[tuple[int, int]] = deque()

    def enqueue_if_transparent(x: int, y: int) -> None:
        if not exterior[y][x] and pixels[x, y][3] == 0:
            exterior[y][x] = True
            queue.append((x, y))

    for x in range(width):
        enqueue_if_transparent(x, 0)
        enqueue_if_transparent(x, height - 1)
    for y in range(height):
        enqueue_if_transparent(0, y)
        enqueue_if_transparent(width - 1, y)

    neighbors = [
        (offset_x, offset_y)
        for offset_y in (-1, 0, 1)
        for offset_x in (-1, 0, 1)
        if offset_x != 0 or offset_y != 0
    ]
    while queue:
        x, y = queue.popleft()
        for offset_x, offset_y in neighbors:
            neighbor_x = x + offset_x
            neighbor_y = y + offset_y
            if 0 <= neighbor_x < width and 0 <= neighbor_y < height:
                enqueue_if_transparent(neighbor_x, neighbor_y)

    boundary_pixels: list[tuple[int, int]] = []
    for y in range(height):
        for x in range(width):
            if pixels[x, y][3] == 0:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            if any(
                not (
                    0 <= x + offset_x < width
                    and 0 <= y + offset_y < height
                )
                or exterior[y + offset_y][x + offset_x]
                for offset_x, offset_y in neighbors
            ):
                boundary_pixels.append((x, y))

    for x, y in boundary_pixels:
        pixels[x, y] = (0, 0, 0, 255)

    return result


def build_icon(
    input_path: Path,
    output_path: Path,
    alpha_threshold: int,
    min_subject_size: int,
    max_subject_size: int,
    cell_alpha_coverage: float = DEFAULT_CELL_ALPHA_COVERAGE,
) -> dict:
    if min_subject_size > max_subject_size:
        raise ValueError("--min-subject-size cannot exceed --max-subject-size")
    if max_subject_size > CANVAS_SIZE:
        raise ValueError(f"--max-subject-size cannot exceed the {CANVAS_SIZE}px canvas")
    if not 0.0 < cell_alpha_coverage <= 1.0:
        raise ValueError("--cell-alpha-coverage must be greater than 0 and at most 1")

    with Image.open(input_path) as opened_source:
        source = opened_source.convert("RGBA")
    analysis_source = _alpha_normalized(source, alpha_threshold)
    if analysis_source.getchannel("A").getbbox() is None:
        raise ValueError(f"No visible subject found in {input_path}")

    analysis = analyze_image(analysis_source)
    bbox_data = analysis["subject_bbox"]
    bbox = (
        int(bbox_data["left"]),
        int(bbox_data["top"]),
        int(bbox_data["right"]),
        int(bbox_data["bottom"]),
    )
    if bbox[2] <= bbox[0] or bbox[3] <= bbox[1]:
        raise ValueError(f"No visible subject found in {input_path}")

    detected_logical_width = max(1, int(analysis["subject_grid_width"]))
    detected_logical_height = max(1, int(analysis["subject_grid_height"]))
    logical_grid = _normalize_to_logical_grid(
        source,
        bbox,
        detected_logical_width,
        detected_logical_height,
        alpha_threshold,
        cell_alpha_coverage,
    )
    logical_bbox = logical_grid.getchannel("A").getbbox()
    if logical_bbox is None:
        raise ValueError(
            f"No logical pixels survived the {cell_alpha_coverage:.3f} cell alpha coverage threshold"
        )

    subject = logical_grid.crop(logical_bbox)
    logical_width, logical_height = subject.size
    largest_dimension = max(logical_width, logical_height)
    if largest_dimension > max_subject_size:
        raise ValueError(
            "Normalized logical subject "
            f"{logical_width}x{logical_height} exceeds --max-subject-size "
            f"{max_subject_size}; provide a target-resolution source instead of "
            "silently downscaling it"
        )

    if largest_dimension < min_subject_size:
        scale = float(min_subject_size) / float(largest_dimension)
        logical_width = max(1, round(logical_width * scale))
        logical_height = max(1, round(logical_height * scale))
        subject = subject.resize(
            (logical_width, logical_height),
            Image.Resampling.NEAREST,
        )

    if max(logical_width, logical_height) > max_subject_size:
        raise ValueError(
            f"Minimum-size expansion produced {logical_width}x{logical_height}, "
            f"exceeding --max-subject-size {max_subject_size}"
        )

    output = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    paste_x = (CANVAS_SIZE - logical_width) // 2
    paste_y = (CANVAS_SIZE - logical_height) // 2
    output.alpha_composite(subject, (paste_x, paste_y))
    output = _force_black_exterior_boundary(output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output.save(output_path)

    output_bbox = output.getchannel("A").getbbox()
    return {
        "input": str(input_path),
        "output": str(output_path),
        "source_size": [source.width, source.height],
        "source_bbox": bbox,
        "grid_cell_width": analysis["grid_cell_width"],
        "grid_cell_height": analysis["grid_cell_height"],
        "confidence": analysis["confidence"],
        "subject_grid_size": [analysis["subject_grid_width"], analysis["subject_grid_height"]],
        "logical_grid_size": [detected_logical_width, detected_logical_height],
        "logical_subject_bbox": logical_bbox,
        "cell_alpha_coverage": cell_alpha_coverage,
        "final_subject_size": [logical_width, logical_height],
        "final_bbox": output_bbox,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize a generated pixel grid cell-by-cell, crop it in logical "
            "space, enforce a pure-black exterior boundary, and center it on a "
            "32x32 transparent canvas. Logical subjects over the maximum size "
            "fail instead of being downscaled."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("input_path", type=Path, help="transparent source PNG")
    parser.add_argument("output_path", type=Path, help="destination 32x32 PNG")
    parser.add_argument(
        "--alpha-threshold",
        type=int,
        default=24,
        help="source alpha values at or below this value are treated as transparent",
    )
    parser.add_argument(
        "--min-subject-size",
        type=int,
        default=12,
        help="upscale a smaller normalized subject so its longest side reaches this size",
    )
    parser.add_argument(
        "--max-subject-size",
        type=int,
        default=26,
        help="reject normalized subjects whose longest side exceeds this size",
    )
    parser.add_argument(
        "--cell-alpha-coverage",
        type=float,
        default=DEFAULT_CELL_ALPHA_COVERAGE,
        help="minimum alpha-weighted coverage required to keep a logical grid cell",
    )
    args = parser.parse_args()

    try:
        result = build_icon(
            args.input_path,
            args.output_path,
            max(0, min(args.alpha_threshold, 255)),
            max(1, args.min_subject_size),
            max(1, args.max_subject_size),
            args.cell_alpha_coverage,
        )
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
