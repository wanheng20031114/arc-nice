#!/usr/bin/env python3
"""Convert the selected 3x2 Slime reference to its visual pixel grid."""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image


COLUMNS = 3
ROWS = 2
SOURCE_FRAME_SIZE = 512
SOURCE_SHEET_SIZE = (
    SOURCE_FRAME_SIZE * COLUMNS,
    SOURCE_FRAME_SIZE * ROWS,
)
FRAME_SIZE = 32
OUTPUT_SHEET_SIZE = (FRAME_SIZE * COLUMNS, FRAME_SIZE * ROWS)
TARGET_BASELINE_Y = 22
MIN_COMPONENT_PIXELS = 64
MIN_GRID_CONFIDENCE = 0.65
# Per-frame centers of the first detected visual pixel. These phases were
# measured from the selected source rather than inferred from the 512px cell
# edges, whose margins are intentionally uneven.
FRAME_FIRST_SAMPLE_CENTERS = (
    (209.788, 206.465),
    (130.414, 219.801),
    (78.033, 220.088),
    (169.834, 171.829),
    (81.755, 228.379),
    (49.142, 267.101),
)
EIGHT_NEIGHBORS = tuple(
    (offset_x, offset_y)
    for offset_y in (-1, 0, 1)
    for offset_x in (-1, 0, 1)
    if (offset_x, offset_y) != (0, 0)
)


def _require_native_transparency(image: Image.Image, source_path: Path) -> None:
    if "A" not in image.getbands():
        raise ValueError(
            f"{source_path} has no Alpha channel. Provide an ImageGen source "
            "exported with a native transparent background."
        )
    minimum_alpha, maximum_alpha = image.getchannel("A").getextrema()
    if minimum_alpha >= 255 or maximum_alpha == 0:
        raise ValueError(
            f"{source_path} does not contain both transparent and visible pixels. "
            "Provide an ImageGen source with native transparent Alpha."
        )


def _collect_components(
    visible_pixels: set[tuple[int, int]],
) -> list[set[tuple[int, int]]]:
    remaining = set(visible_pixels)
    components: list[set[tuple[int, int]]] = []
    while remaining:
        first = remaining.pop()
        component = {first}
        pending = deque([first])
        while pending:
            current_x, current_y = pending.popleft()
            for offset_x, offset_y in EIGHT_NEIGHBORS:
                neighbor = (current_x + offset_x, current_y + offset_y)
                if neighbor not in remaining:
                    continue
                remaining.remove(neighbor)
                component.add(neighbor)
                pending.append(neighbor)
        components.append(component)
    return components


def _extract_clean_foreground(cell: Image.Image) -> Image.Image:
    source = cell.convert("RGBA")
    source_pixels = source.load()
    visible_pixels = {
        (x, y)
        for y in range(SOURCE_FRAME_SIZE)
        for x in range(SOURCE_FRAME_SIZE)
        if source_pixels[x, y][3] > 0
    }
    components = _collect_components(visible_pixels)
    kept_pixels = set().union(
        *(
            component
            for component in components
            if len(component) >= MIN_COMPONENT_PIXELS
        )
    )
    if not kept_pixels:
        raise ValueError("Slime frame contains no foreground in its Alpha channel.")

    result = Image.new(
        "RGBA",
        (SOURCE_FRAME_SIZE, SOURCE_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    result_pixels = result.load()
    for x, y in kept_pixels:
        red, green, blue, _alpha = source_pixels[x, y]
        result_pixels[x, y] = (red, green, blue, 255)
    return result


def _compress_and_align_frame(
    cell: Image.Image,
    frame_index: int,
) -> Image.Image:
    foreground = _extract_clean_foreground(cell)
    bounds = foreground.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError("Slime frame contains no visible pixels.")

    grid_analysis = analyze_image(foreground)
    if (
        grid_analysis["detection_mode"] == "native_or_unknown"
        or float(grid_analysis["confidence"]) < MIN_GRID_CONFIDENCE
    ):
        raise ValueError(
            "Slime frame visual pixel grid could not be detected safely: "
            f"{grid_analysis['detection_mode']} "
            f"({grid_analysis['confidence']:.3f})."
        )
    logical_width = int(grid_analysis["subject_grid_width"])
    logical_height = int(grid_analysis["subject_grid_height"])
    if logical_width > FRAME_SIZE or logical_height > TARGET_BASELINE_Y:
        raise ValueError(
            "Compressed Slime subject does not fit the 32x32 frame: "
            f"{logical_width}x{logical_height}."
        )

    # The source is approximate pixel art: one authored visual pixel spans
    # roughly 13-14 physical pixels. Sample the detected logical cell centers
    # directly so no resizer can skip a thin outline or either eye.
    grid_width = float(grid_analysis["grid_cell_width"])
    grid_height = float(grid_analysis["grid_cell_height"])
    first_center_x, first_center_y = FRAME_FIRST_SAMPLE_CENTERS[frame_index]
    source_pixels = cell.convert("RGBA").load()
    clean_alpha = foreground.getchannel("A").load()
    subject = Image.new(
        "RGBA",
        (logical_width, logical_height),
        (0, 0, 0, 0),
    )
    subject_pixels = subject.load()
    for logical_y in range(logical_height):
        source_y = max(
            0,
            min(
                SOURCE_FRAME_SIZE - 1,
                round(first_center_y + logical_y * grid_height),
            ),
        )
        for logical_x in range(logical_width):
            source_x = max(
                0,
                min(
                    SOURCE_FRAME_SIZE - 1,
                    round(first_center_x + logical_x * grid_width),
                ),
            )
            source_pixel = source_pixels[source_x, source_y]
            if clean_alpha[source_x, source_y] == 0:
                continue
            red, green, blue, _alpha = source_pixel
            subject_pixels[logical_x, logical_y] = (
                red,
                green,
                blue,
                255,
            )
    aligned = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    aligned.alpha_composite(
        subject,
        (
            (FRAME_SIZE - logical_width) // 2,
            TARGET_BASELINE_Y - logical_height,
        ),
    )
    return aligned


def process_sprite_sheet(source_path: Path, output_path: Path) -> None:
    with Image.open(source_path) as source_image:
        _require_native_transparency(source_image, source_path)
        source = source_image.convert("RGBA")
    if source.size != SOURCE_SHEET_SIZE:
        raise ValueError(
            "Native Slime source must be exactly 1536x1024 (3x2 512px frames)."
        )

    sheet = Image.new("RGBA", OUTPUT_SHEET_SIZE, (0, 0, 0, 0))
    for row in range(ROWS):
        for column in range(COLUMNS):
            frame_index = row * COLUMNS + column
            frame = _compress_and_align_frame(
                source.crop(
                    (
                        column * SOURCE_FRAME_SIZE,
                        row * SOURCE_FRAME_SIZE,
                        (column + 1) * SOURCE_FRAME_SIZE,
                        (row + 1) * SOURCE_FRAME_SIZE,
                    )
                ),
                frame_index,
            )
            sheet.alpha_composite(
                frame,
                (column * FRAME_SIZE, row * FRAME_SIZE),
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path, format="PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the 96x64 Slime sheet on its visual pixel grid."
    )
    parser.add_argument("source_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()
    process_sprite_sheet(args.source_path, args.output_path)


if __name__ == "__main__":
    main()
