#!/usr/bin/env python3
"""Build the native 64 px stone-golem sprite sheet from the generated source.

The generated source is an approximate 4x4 grid.  Each source cell is scaled
with nearest-neighbour sampling by one shared factor, then aligned from its
largest connected foreground component.  This keeps the golem's body size and
feet anchor stable without letting the slam ring or loose death rubble pull the
character off-center.
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
ALPHA_THRESHOLD = 96
PALETTE_COLOR_COUNT = 24


def _is_chroma_spill(red: int, green: int, blue: int) -> bool:
    return red >= 150 and blue >= 150 and green * 2 < red + blue


def _normalize_source(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= ALPHA_THRESHOLD or _is_chroma_spill(red, green, blue):
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return rgba


def _cell_bounds(length: int, index: int, count: int) -> tuple[int, int]:
    start = round(length * index / count)
    end = round(length * (index + 1) / count)
    return start, end


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
    anchor_x = (body_bbox[0] + body_bbox[2]) * 0.5
    anchor_y = float(body_bbox[3])
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
    source = _normalize_source(Image.open(source_path))
    sheet = Image.new(
        "RGBA",
        (FRAME_SIZE * GRID_COLUMNS, FRAME_SIZE * GRID_ROWS),
        (0, 0, 0, 0),
    )
    for row in range(GRID_ROWS):
        top, bottom = _cell_bounds(source.height, row, GRID_ROWS)
        for column in range(GRID_COLUMNS):
            left, right = _cell_bounds(source.width, column, GRID_COLUMNS)
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
        description="Process the generated 4x4 stone-golem sheet into 64 px frames"
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
        f"anchor={TARGET_ANCHOR[0]},{TARGET_ANCHOR[1]}"
    )


if __name__ == "__main__":
    main()
