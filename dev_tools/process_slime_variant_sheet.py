#!/usr/bin/env python3
"""Decode a strict 16x ImageGen Slime sheet without geometrical rescaling.

The 1536x1024 mother image is a nearest-neighbour preview of a 96x64 logical
sprite sheet.  One 16x16 source block therefore becomes exactly one output
pixel.  The base Slime is used only as a geometry validation oracle; none of
its pixels or alpha values are copied into the generated variant.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from statistics import median

from PIL import Image


COLUMNS = 3
ROWS = 2
FRAME_SIZE = 32
GRID_SCALE = 16
SHEET_SIZE = (FRAME_SIZE * COLUMNS, FRAME_SIZE * ROWS)
SOURCE_SIZE = (SHEET_SIZE[0] * GRID_SCALE, SHEET_SIZE[1] * GRID_SCALE)
SAMPLE_INSET = 4
VISIBLE_ALPHA_THRESHOLD = 128
EYE_LUMINANCE_THRESHOLD = 0.32
MOVE_EYE_PIXELS = {
    (14, 15),
    (14, 16),
    (18, 15),
    (18, 16),
}
MOVE_FACE_ROI = (13, 14, 20, 17)
EXPECTED_FRAME_BOUNDS = (
    (7, 8, 25, 22),
    (6, 9, 26, 22),
    (7, 9, 25, 22),
    (4, 11, 28, 22),
    (1, 15, 30, 22),
    (4, 18, 27, 22),
)


def _luminance(color: tuple[int, int, int, int]) -> float:
    red, green, blue, _alpha = color
    return (
        red * 0.2126
        + green * 0.7152
        + blue * 0.0722
    ) / 255.0


def _median_color(
    colors: list[tuple[int, int, int, int]],
) -> tuple[int, int, int, int]:
    return (
        round(median(color[0] for color in colors)),
        round(median(color[1] for color in colors)),
        round(median(color[2] for color in colors)),
        255,
    )


def _decode_logical_cell(
    source: Image.Image,
    logical_x: int,
    logical_y: int,
) -> tuple[tuple[int, int, int, int], float]:
    source_x = logical_x * GRID_SCALE
    source_y = logical_y * GRID_SCALE
    samples = [
        source.getpixel((x, y))
        for y in range(
            source_y + SAMPLE_INSET,
            source_y + GRID_SCALE - SAMPLE_INSET,
        )
        for x in range(
            source_x + SAMPLE_INSET,
            source_x + GRID_SCALE - SAMPLE_INSET,
        )
    ]
    visible = [
        color
        for color in samples
        if color[3] >= VISIBLE_ALPHA_THRESHOLD
    ]
    coverage = len(visible) / len(samples)
    if coverage < 0.5:
        return ((0, 0, 0, 0), coverage)
    return (_median_color(visible), coverage)


def _decode_fixed_grid(source: Image.Image) -> Image.Image:
    if source.size != SOURCE_SIZE:
        raise ValueError(
            "Generated Slime source must be exactly "
            f"{SOURCE_SIZE[0]}x{SOURCE_SIZE[1]}."
        )
    result = Image.new("RGBA", SHEET_SIZE, (0, 0, 0, 0))
    ambiguous_cells: list[tuple[int, int, float]] = []
    for logical_y in range(SHEET_SIZE[1]):
        for logical_x in range(SHEET_SIZE[0]):
            color, coverage = _decode_logical_cell(
                source,
                logical_x,
                logical_y,
            )
            if 0.10 < coverage < 0.90:
                ambiguous_cells.append((logical_x, logical_y, coverage))
            result.putpixel((logical_x, logical_y), color)
    if ambiguous_cells:
        preview = ", ".join(
            f"({x},{y})={coverage:.2f}"
            for x, y, coverage in ambiguous_cells[:8]
        )
        raise ValueError(
            "Generated Slime pixels are not aligned to the global 16x16 "
            f"visual grid: {preview}."
        )
    return result


def _binary_alpha_mask(image: Image.Image) -> tuple[bool, ...]:
    return tuple(alpha >= VISIBLE_ALPHA_THRESHOLD for alpha in image.getchannel("A").getdata())


def _validate_generated_geometry(base: Image.Image, generated: Image.Image) -> None:
    if base.size != SHEET_SIZE:
        raise ValueError("Base Slime sheet must be exactly 96x64.")
    base_mask = _binary_alpha_mask(base)
    generated_mask = _binary_alpha_mask(generated)
    if base_mask != generated_mask:
        differences = [
            (index % SHEET_SIZE[0], index // SHEET_SIZE[0])
            for index, (base_visible, generated_visible) in enumerate(
                zip(base_mask, generated_mask)
            )
            if base_visible != generated_visible
        ]
        raise ValueError(
            "Generated Slime changed the authored visual-pixel geometry; "
            "regenerate it instead of scaling or replacing its alpha mask. "
            f"First mismatches: {differences[:12]}."
        )
    for frame_index, expected_bounds in enumerate(EXPECTED_FRAME_BOUNDS):
        frame_x = frame_index % COLUMNS * FRAME_SIZE
        frame_y = frame_index // COLUMNS * FRAME_SIZE
        frame = generated.crop(
            (frame_x, frame_y, frame_x + FRAME_SIZE, frame_y + FRAME_SIZE)
        )
        bounds = frame.getchannel("A").getbbox()
        if bounds != expected_bounds:
            raise ValueError(
                f"Frame {frame_index} bounds {bounds} do not match "
                f"the authored bounds {expected_bounds}."
            )


def _normalize_move_eyes(sheet: Image.Image) -> tuple[int, int, int, int]:
    eye_samples = [
        sheet.getpixel((frame_index * FRAME_SIZE + x, y))
        for frame_index in range(3)
        for x, y in MOVE_EYE_PIXELS
    ]
    visible_eye_samples = [color for color in eye_samples if color[3] >= 128]
    if len(visible_eye_samples) != len(eye_samples):
        raise ValueError("A generated move-frame eye left the Slime silhouette.")
    eye_color = _median_color(visible_eye_samples)
    left, top, right, bottom = MOVE_FACE_ROI
    for frame_index in range(3):
        frame_offset_x = frame_index * FRAME_SIZE
        row_fill_colors: dict[int, tuple[int, int, int, int]] = {}
        for y in range(top, bottom):
            candidates = [
                sheet.getpixel((frame_offset_x + x, y))
                for x in range(left, right)
                if (x, y) not in MOVE_EYE_PIXELS
                and sheet.getpixel((frame_offset_x + x, y))[3] >= 128
                and _luminance(sheet.getpixel((frame_offset_x + x, y)))
                >= EYE_LUMINANCE_THRESHOLD
            ]
            if not candidates:
                raise ValueError(
                    f"Frame {frame_index} has no usable face color on row {y}."
                )
            row_fill_colors[y] = _median_color(candidates)
        for y in range(top, bottom):
            for x in range(left, right):
                coordinate = (x, y)
                sheet_coordinate = (frame_offset_x + x, y)
                color = sheet.getpixel(sheet_coordinate)
                if (
                    coordinate not in MOVE_EYE_PIXELS
                    and color[3] >= 128
                    and _luminance(color) < EYE_LUMINANCE_THRESHOLD
                ):
                    sheet.putpixel(sheet_coordinate, row_fill_colors[y])
        for x, y in MOVE_EYE_PIXELS:
            sheet.putpixel((frame_offset_x + x, y), eye_color)
    return eye_color


def _validate_move_eyes(
    sheet: Image.Image,
    eye_color: tuple[int, int, int, int],
) -> None:
    left, top, right, bottom = MOVE_FACE_ROI
    for frame_index in range(3):
        frame_offset_x = frame_index * FRAME_SIZE
        exact_eye_pixels = {
            (x, y)
            for y in range(top, bottom)
            for x in range(left, right)
            if sheet.getpixel((frame_offset_x + x, y)) == eye_color
        }
        if exact_eye_pixels != MOVE_EYE_PIXELS:
            raise ValueError(
                f"Frame {frame_index} eye pixels moved or changed thickness: "
                f"{sorted(exact_eye_pixels)}."
            )
        dark_pixels = {
            (x, y)
            for y in range(top, bottom)
            for x in range(left, right)
            if sheet.getpixel((frame_offset_x + x, y))[3] >= 128
            and _luminance(sheet.getpixel((frame_offset_x + x, y)))
            < EYE_LUMINANCE_THRESHOLD
        }
        if dark_pixels != MOVE_EYE_PIXELS:
            raise ValueError(
                f"Frame {frame_index} contains extra dark eye-width pixels: "
                f"{sorted(dark_pixels)}."
            )


def process_variant_sheet(
    base_path: Path,
    source_path: Path,
    output_path: Path,
) -> None:
    with Image.open(base_path) as base_image:
        base = base_image.convert("RGBA")
    with Image.open(source_path) as source_image:
        source = source_image.convert("RGBA")
    result = _decode_fixed_grid(source)
    _validate_generated_geometry(base, result)
    eye_color = _normalize_move_eyes(result)
    _validate_generated_geometry(base, result)
    _validate_move_eyes(result, eye_color)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(output_path, format="PNG", optimize=True)
    print(
        f"Wrote {output_path} from the authored 16x16 visual grid; "
        f"move eyes normalized to #{eye_color[0]:02x}{eye_color[1]:02x}"
        f"{eye_color[2]:02x}."
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Decode a 1536x1024 ImageGen Slime sheet on its fixed 16x16 "
            "visual grid without resizing any frame geometry."
        )
    )
    parser.add_argument(
        "base_path",
        type=Path,
        help="96x64 base Slime sheet used only to reject geometry drift",
    )
    parser.add_argument("source_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()
    process_variant_sheet(args.base_path, args.source_path, args.output_path)


if __name__ == "__main__":
    main()
