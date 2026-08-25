#!/usr/bin/env python3
"""Extract the ImageGen slime directly from its transparent 16x sprite sheet.

The source is a 1536x1024, 3x2 sheet whose six 512x512 frame slots correspond
to six 32x32 runtime frames.  Generated pseudo-pixel phase varies slightly, so
single-point nearest sampling is unsafe.  Each intended 16x16 source cell is
instead classified by all 256 pixels: at least 35% alpha coverage makes one
opaque logical pixel, whose color is the visible-pixel median mapped without
dithering to a clean eight-color runtime palette.  The seven grass-green body
colors remain source-derived; only the yellowest highlight is kept green-led.
No averaged resizing, soft alpha, outline substitution, or frame repositioning
is performed.
"""

from __future__ import annotations

import argparse
from math import ceil
from pathlib import Path
from statistics import median

from PIL import Image


COLUMNS = 3
ROWS = 2
FRAME_SIZE = 32
SOURCE_GRID_SCALE = 16
SOURCE_FRAME_SIZE = FRAME_SIZE * SOURCE_GRID_SCALE
LOGICAL_SHEET_SIZE = (FRAME_SIZE * COLUMNS, FRAME_SIZE * ROWS)
SOURCE_SHEET_SIZE = (
    SOURCE_FRAME_SIZE * COLUMNS,
    SOURCE_FRAME_SIZE * ROWS,
)
ALIGNED_SOURCE_SIZE = (
    LOGICAL_SHEET_SIZE[0] * SOURCE_GRID_SCALE,
    LOGICAL_SHEET_SIZE[1] * SOURCE_GRID_SCALE,
)
FOREGROUND_OCCUPANCY = 0.35
SOURCE_CELL_PIXELS = SOURCE_GRID_SCALE * SOURCE_GRID_SCALE
MINIMUM_FOREGROUND_PIXELS = ceil(SOURCE_CELL_PIXELS * FOREGROUND_OCCUPANCY)
SOURCE_DERIVED_PALETTE = (
    (10, 110, 1, 255),
    (35, 136, 1, 255),
    (75, 172, 1, 255),
    (103, 201, 1, 255),
    (130, 224, 1, 255),
    (170, 233, 27, 255),
    (224, 236, 53, 255),
    (251, 239, 79, 255),
)
RUNTIME_PALETTE = SOURCE_DERIVED_PALETTE[:-1] + ((239, 251, 79, 255),)
MOVE_EYE_PIXELS = frozenset(
    {
        (14, 15),
        (14, 16),
        (18, 15),
        (18, 16),
    }
)
MOVE_FACE_ROI = (13, 14, 20, 17)


def _is_source_foreground(color: tuple[int, int, int, int]) -> bool:
    return color[3] >= 128


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


def _is_grass_green(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return alpha == 255 and green >= 45 and green >= red - 16 and green >= blue + 20


def _median_color(
    colors: list[tuple[int, int, int, int]],
) -> tuple[int, int, int, int]:
    return (
        round(median(color[0] for color in colors)),
        round(median(color[1] for color in colors)),
        round(median(color[2] for color in colors)),
        255,
    )


def _quantize_to_source_palette(
    color: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    palette_index = min(
        range(len(SOURCE_DERIVED_PALETTE)),
        key=lambda index: sum(
            (color[channel] - SOURCE_DERIVED_PALETTE[index][channel]) ** 2
            for channel in range(3)
        ),
    )
    return RUNTIME_PALETTE[palette_index]


def _extract_native_grid(source: Image.Image) -> Image.Image:
    if source.size != SOURCE_SHEET_SIZE:
        raise ValueError(
            f"ImageGen source must be exactly {SOURCE_SHEET_SIZE[0]}x"
            f"{SOURCE_SHEET_SIZE[1]}; got {source.width}x{source.height}."
        )
    logical = Image.new("RGBA", LOGICAL_SHEET_SIZE, (0, 0, 0, 0))
    for logical_y in range(LOGICAL_SHEET_SIZE[1]):
        source_y = logical_y * SOURCE_GRID_SCALE
        for logical_x in range(LOGICAL_SHEET_SIZE[0]):
            source_x = logical_x * SOURCE_GRID_SCALE
            foreground = [
                source.getpixel((source_x + x, source_y + y))
                for y in range(SOURCE_GRID_SCALE)
                for x in range(SOURCE_GRID_SCALE)
                if _is_source_foreground(source.getpixel((source_x + x, source_y + y)))
            ]
            if len(foreground) < MINIMUM_FOREGROUND_PIXELS:
                continue
            logical.putpixel(
                (logical_x, logical_y),
                _quantize_to_source_palette(_median_color(foreground)),
            )
    return logical


def _measure_frame(
    image: Image.Image,
    frame_index: int,
) -> tuple[int, tuple[int, int, int, int]]:
    frame_x = frame_index % COLUMNS * FRAME_SIZE
    frame_y = frame_index // COLUMNS * FRAME_SIZE
    coordinates = [
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if image.getpixel((frame_x + x, frame_y + y))[3] == 255
    ]
    if not coordinates:
        raise ValueError(f"Frame {frame_index} contains no extracted slime pixels.")
    xs = [coordinate[0] for coordinate in coordinates]
    ys = [coordinate[1] for coordinate in coordinates]
    return len(coordinates), (min(xs), min(ys), max(xs) + 1, max(ys) + 1)


def _validate_move_eyes(result: Image.Image) -> None:
    darkest_green = RUNTIME_PALETTE[0]
    left, top, right, bottom = MOVE_FACE_ROI
    for frame_index in range(COLUMNS):
        frame_offset_x = frame_index * FRAME_SIZE
        darkest_face_pixels = {
            (x, y)
            for y in range(top, bottom)
            for x in range(left, right)
            if result.getpixel((frame_offset_x + x, y)) == darkest_green
        }
        if darkest_face_pixels != MOVE_EYE_PIXELS:
            raise ValueError(
                f"Frame {frame_index} eye geometry changed: "
                f"{sorted(darkest_face_pixels)}."
            )


def _validate_logical_sheet(reference: Image.Image, result: Image.Image) -> None:
    if reference.size != LOGICAL_SHEET_SIZE or result.size != LOGICAL_SHEET_SIZE:
        raise ValueError("Reference and result must both be exactly 96x64.")
    visible_colors: set[tuple[int, int, int, int]] = set()
    for y in range(result.height):
        for x in range(result.width):
            color = result.getpixel((x, y))
            if color[3] not in (0, 255):
                raise ValueError(f"Partial alpha at logical pixel ({x}, {y}).")
            if color[3] == 0:
                if color != (0, 0, 0, 0):
                    raise ValueError("Transparent pixels retain hidden RGB fringe.")
                continue
            if not _is_grass_green(color):
                raise ValueError(f"Visible logical pixel ({x}, {y}) is not grass green.")
            visible_colors.add(color)
    reference_frame_summaries = [
        _measure_frame(reference, frame_index)
        for frame_index in range(COLUMNS * ROWS)
    ]
    result_frame_summaries = [
        _measure_frame(result, frame_index)
        for frame_index in range(COLUMNS * ROWS)
    ]
    for frame_index, (reference_summary, result_summary) in enumerate(
        zip(reference_frame_summaries, result_frame_summaries)
    ):
        if result_summary != reference_summary:
            raise ValueError(
                f"Frame {frame_index} generated count/bounds {result_summary} "
                f"do not match the base Slime {reference_summary}."
            )
    if visible_colors != set(RUNTIME_PALETTE):
        raise ValueError("Runtime sheet must use all eight clean palette colors only.")
    _validate_move_eyes(result)
    print(
        "Frame visible pixels and exclusive bounds: "
        f"{result_frame_summaries}"
    )
    print(f"Visible runtime logical colors: {sorted(visible_colors)}")


def _validate_aligned_source(logical: Image.Image, aligned: Image.Image) -> None:
    if aligned.size != ALIGNED_SOURCE_SIZE:
        raise ValueError("Aligned source must be exactly 1536x1024.")
    for logical_y in range(LOGICAL_SHEET_SIZE[1]):
        for logical_x in range(LOGICAL_SHEET_SIZE[0]):
            expected = logical.getpixel((logical_x, logical_y))
            block = aligned.crop(
                (
                    logical_x * SOURCE_GRID_SCALE,
                    logical_y * SOURCE_GRID_SCALE,
                    (logical_x + 1) * SOURCE_GRID_SCALE,
                    (logical_y + 1) * SOURCE_GRID_SCALE,
                )
            )
            if any(pixel != expected for pixel in block.getdata()):
                raise ValueError(
                    f"Mother block ({logical_x}, {logical_y}) is not one "
                    "uniform 16x16 RGBA pixel."
                )


def _save_lossless_png(image: Image.Image, output_path: Path) -> None:
    """Write a compact PNG and prove decoded RGBA bytes are unchanged."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(output_path, format="PNG", compress_level=9)
    with Image.open(output_path) as saved_image:
        decoded = saved_image.convert("RGBA")
    if decoded.size != image.size or decoded.tobytes() != image.tobytes():
        raise ValueError(f"PNG round-trip changed RGBA pixels: {output_path}")


def align_imagegen_source(
    reference_path: Path,
    source_path: Path,
    aligned_output_path: Path,
    logical_output_path: Path | None,
) -> None:
    with Image.open(reference_path) as reference_image:
        reference = reference_image.convert("RGBA")
    with Image.open(source_path) as source_image:
        _require_native_transparency(source_image, source_path)
        source = source_image.convert("RGBA")

    logical_result = _extract_native_grid(source)
    _validate_logical_sheet(reference, logical_result)
    aligned_source = logical_result.resize(
        ALIGNED_SOURCE_SIZE,
        resample=Image.Resampling.NEAREST,
    )
    _validate_aligned_source(logical_result, aligned_source)

    _save_lossless_png(aligned_source, aligned_output_path)
    if logical_output_path is not None:
        _save_lossless_png(logical_result, logical_output_path)
    print(
        f"Wrote {aligned_output_path} at "
        f"{ALIGNED_SOURCE_SIZE[0]}x{ALIGNED_SOURCE_SIZE[1]}."
    )
    if logical_output_path is not None:
        print(f"Wrote {logical_output_path} at 96x64.")
    print("Validated full-cell foreground voting with binary alpha.")
    print("Validated generated silhouettes, highlights, eyes, and death fragments.")
    print("Validated exact RGBA-uniform 16x16 mother-image blocks.")
    print("Validated lossless PNG encode/decode with byte-identical RGBA data.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Extract a native-transparent ImageGen Slime sheet through "
            "full-cell foreground voting without averaged resizing."
        )
    )
    parser.add_argument("reference_path", type=Path)
    parser.add_argument("source_path", type=Path)
    parser.add_argument("aligned_output_path", type=Path)
    parser.add_argument("--logical-output", type=Path)
    args = parser.parse_args()
    align_imagegen_source(
        args.reference_path,
        args.source_path,
        args.aligned_output_path,
        args.logical_output,
    )


if __name__ == "__main__":
    main()
