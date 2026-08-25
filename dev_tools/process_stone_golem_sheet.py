#!/usr/bin/env python3
"""Build the native 64 px stone-golem sprite sheet from the generated source.

The generated source is an approximate 4x4 grid whose visual rows are not
guaranteed to be exactly one quarter of the canvas height.  Transparent gutters
are detected before slicing so feet and slam effects cannot be cut by nominal
grid boundaries.  Each source cell is then scaled with nearest-neighbour
sampling by one shared factor and aligned from its main body plus its lowest
visible pixel.  This keeps the body centered while preserving complete legs,
ground effects, and rubble.
"""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

from PIL import Image


GRID_COLUMNS = 4
GRID_ROWS = 4
FRAME_SIZE = 64
SOURCE_TO_LOGICAL_SCALE = 0.16
TARGET_ANCHOR = (32, 57)
ALPHA_THRESHOLD = 24
PALETTE_COLOR_COUNT = 24
GUTTER_SEARCH_FRACTION = 0.30


def _normalize_source(image: Image.Image, source_path: Path) -> Image.Image:
    if "A" not in image.getbands():
        raise ValueError(
            f"{source_path} has no Alpha channel. Provide an ImageGen sheet "
            "exported with a native transparent background."
        )
    minimum_alpha, maximum_alpha = image.getchannel("A").getextrema()
    if minimum_alpha >= 255 or maximum_alpha == 0:
        raise ValueError(
            f"{source_path} does not contain both transparent and visible pixels. "
            "Provide an ImageGen sheet with native transparent Alpha."
        )
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= ALPHA_THRESHOLD:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return rgba


def _find_axis_bounds(
    alpha: Image.Image,
    division_count: int,
    horizontal: bool,
) -> list[int]:
    """Find cell boundaries in empty gutters nearest the nominal grid splits."""
    width, height = alpha.size
    pixels = alpha.load()
    length = height if horizontal else width
    cross_length = width if horizontal else height
    occupied = []
    for axis_position in range(length):
        occupied.append(
            any(
                (
                    pixels[cross_position, axis_position]
                    if horizontal
                    else pixels[axis_position, cross_position]
                )
                > 0
                for cross_position in range(cross_length)
            )
        )

    nominal_cell_size = float(length) / float(division_count)
    search_radius = max(2, round(nominal_cell_size * GUTTER_SEARCH_FRACTION))
    boundaries = [0]
    for division_index in range(1, division_count):
        nominal = round(nominal_cell_size * division_index)
        search_start = max(boundaries[-1] + 1, nominal - search_radius)
        search_end = min(length - 1, nominal + search_radius)
        empty_runs: list[tuple[int, int]] = []
        run_start: int | None = None
        for axis_position in range(search_start, search_end + 1):
            if not occupied[axis_position]:
                if run_start is None:
                    run_start = axis_position
            elif run_start is not None:
                empty_runs.append((run_start, axis_position))
                run_start = None
        if run_start is not None:
            empty_runs.append((run_start, search_end + 1))
        if not empty_runs:
            raise ValueError(
                f"Could not find an empty source gutter near grid split {division_index}"
            )
        best_start, best_end = max(
            empty_runs,
            key=lambda run: (
                run[1] - run[0],
                -abs(((run[0] + run[1]) * 0.5) - nominal),
            ),
        )
        boundaries.append(round((best_start + best_end) * 0.5))
    boundaries.append(length)
    return boundaries


def _largest_component_bbox(cell: Image.Image) -> tuple[int, int, int, int]:
    alpha = cell.getchannel("A")
    width, height = cell.size
    visible = alpha.load()
    visited = bytearray(width * height)
    best_pixels: list[tuple[int, int]] = []

    for start_y in range(height):
        for start_x in range(width):
            start_index = start_y * width + start_x
            if visited[start_index] or visible[start_x, start_y] == 0:
                continue
            visited[start_index] = 1
            queue: deque[tuple[int, int]] = deque([(start_x, start_y)])
            component: list[tuple[int, int]] = []
            while queue:
                x, y = queue.popleft()
                component.append((x, y))
                for next_x, next_y in (
                    (x - 1, y),
                    (x + 1, y),
                    (x, y - 1),
                    (x, y + 1),
                ):
                    if (
                        next_x < 0
                        or next_y < 0
                        or next_x >= width
                        or next_y >= height
                    ):
                        continue
                    next_index = next_y * width + next_x
                    if visited[next_index] or visible[next_x, next_y] == 0:
                        continue
                    visited[next_index] = 1
                    queue.append((next_x, next_y))
            if len(component) > len(best_pixels):
                best_pixels = component

    if not best_pixels:
        raise ValueError("Sprite cell has no visible foreground component")
    left = min(point[0] for point in best_pixels)
    top = min(point[1] for point in best_pixels)
    right = max(point[0] for point in best_pixels) + 1
    bottom = max(point[1] for point in best_pixels) + 1
    return left, top, right, bottom


def _place_frame(cell: Image.Image) -> Image.Image:
    body_bbox = _largest_component_bbox(cell)
    visible_bbox = cell.getchannel("A").getbbox()
    if visible_bbox is None:
        raise ValueError("Sprite cell has no visible foreground")
    anchor_x = (body_bbox[0] + body_bbox[2]) * 0.5
    anchor_y = float(visible_bbox[3])
    resized_size = (
        max(1, round(cell.width * SOURCE_TO_LOGICAL_SCALE)),
        max(1, round(cell.height * SOURCE_TO_LOGICAL_SCALE)),
    )
    resized = cell.resize(resized_size, Image.Resampling.NEAREST)
    paste_position = (
        round(TARGET_ANCHOR[0] - anchor_x * SOURCE_TO_LOGICAL_SCALE),
        round(TARGET_ANCHOR[1] - anchor_y * SOURCE_TO_LOGICAL_SCALE),
    )
    frame = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    frame.alpha_composite(resized, paste_position)
    return frame


def _quantize_sheet(image: Image.Image) -> Image.Image:
    alpha = image.getchannel("A")
    quantized = image.quantize(
        colors=PALETTE_COLOR_COUNT,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.NONE,
    ).convert("RGBA")
    quantized.putalpha(alpha)
    pixels = quantized.load()
    for y in range(quantized.height):
        for x in range(quantized.width):
            if pixels[x, y][3] == 0:
                pixels[x, y] = (0, 0, 0, 0)
    return quantized


def build_sheet(source_path: Path, output_path: Path) -> Image.Image:
    source = _normalize_source(Image.open(source_path), source_path)
    source_alpha = source.getchannel("A")
    column_bounds = _find_axis_bounds(
        source_alpha,
        GRID_COLUMNS,
        horizontal=False,
    )
    row_bounds = _find_axis_bounds(
        source_alpha,
        GRID_ROWS,
        horizontal=True,
    )
    sheet = Image.new(
        "RGBA",
        (FRAME_SIZE * GRID_COLUMNS, FRAME_SIZE * GRID_ROWS),
        (0, 0, 0, 0),
    )
    for row in range(GRID_ROWS):
        top, bottom = row_bounds[row], row_bounds[row + 1]
        for column in range(GRID_COLUMNS):
            left, right = column_bounds[column], column_bounds[column + 1]
            cell = source.crop((left, top, right, bottom))
            frame = _place_frame(cell)
            sheet.alpha_composite(
                frame,
                (column * FRAME_SIZE, row * FRAME_SIZE),
            )

    result = _quantize_sheet(sheet)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(output_path, optimize=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Process a native-transparent generated 4x4 stone-golem sheet "
            "into 64 px frames"
        )
    )
    parser.add_argument("source_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()
    result = build_sheet(args.source_path, args.output_path)
    print(
        "STONE_GOLEM_SHEET_OK "
        f"size={result.width}x{result.height} "
        f"frame={FRAME_SIZE}x{FRAME_SIZE} "
        f"scale={SOURCE_TO_LOGICAL_SCALE:.2f} "
        f"anchor={TARGET_ANCHOR[0]},{TARGET_ANCHOR[1]} "
        "grid=gutter-detected"
    )


if __name__ == "__main__":
    main()
