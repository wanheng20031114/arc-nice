#!/usr/bin/env python3
"""Build a clean grass-green Slime sheet from an ImageGen palette board.

ImageGen is the color authority.  The authored ordinary Slime sheet remains
the geometry authority: alpha, frame bounds, eyes, and every visual-pixel
coordinate stay unchanged.  Only eight median swatch colors are admitted to
the runtime texture, so generated gradients and compression noise cannot leak
into the pixel art.
"""

from __future__ import annotations

import argparse
from bisect import bisect_left, bisect_right
from pathlib import Path
from statistics import median

from PIL import Image


COLUMNS = 3
ROWS = 2
FRAME_SIZE = 32
GRID_SCALE = 16
PALETTE_COLUMNS = 4
PALETTE_ROWS = 2
PALETTE_COLOR_COUNT = PALETTE_COLUMNS * PALETTE_ROWS
PALETTE_INNER_START = 0.25
PALETTE_INNER_END = 0.75
SOURCE_SAMPLE_STRIDE = 4
FOREGROUND_DOMINANCE = 8
MINIMUM_LUMINANCE_CORRELATION = 0.90
LOGICAL_SHEET_SIZE = (FRAME_SIZE * COLUMNS, FRAME_SIZE * ROWS)
ALIGNED_SOURCE_SIZE = (
    LOGICAL_SHEET_SIZE[0] * GRID_SCALE,
    LOGICAL_SHEET_SIZE[1] * GRID_SCALE,
)
MOVE_EYE_PIXELS = (
    (14, 15),
    (14, 16),
    (18, 15),
    (18, 16),
)
MOVE_EYE_COORDINATES = frozenset(
    (frame_index * FRAME_SIZE + x, y)
    for frame_index in range(COLUMNS)
    for x, y in MOVE_EYE_PIXELS
)


def _is_green_foreground(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return (
        alpha >= 128
        and green >= red + FOREGROUND_DOMINANCE
        and green >= blue + FOREGROUND_DOMINANCE
    )


def _luminance(color: tuple[int, int, int, int]) -> float:
    red, green, blue, _alpha = color
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0


def _median_color(
    colors: list[tuple[int, int, int, int]],
) -> tuple[int, int, int, int]:
    return (
        round(median(color[0] for color in colors)),
        round(median(color[1] for color in colors)),
        round(median(color[2] for color in colors)),
        255,
    )


def _extract_swatch_palette(
    source: Image.Image,
) -> list[tuple[int, int, int, int]]:
    """Collapse each generated swatch to one noise-free median RGBA color."""
    if source.width < PALETTE_COLUMNS * 32 or source.height < PALETTE_ROWS * 32:
        raise ValueError("ImageGen palette board is too small for reliable sampling.")
    palette: list[tuple[int, int, int, int]] = []
    cell_width = source.width / PALETTE_COLUMNS
    cell_height = source.height / PALETTE_ROWS
    for row in range(PALETTE_ROWS):
        for column in range(PALETTE_COLUMNS):
            start_x = round((column + PALETTE_INNER_START) * cell_width)
            end_x = round((column + PALETTE_INNER_END) * cell_width)
            start_y = round((row + PALETTE_INNER_START) * cell_height)
            end_y = round((row + PALETTE_INNER_END) * cell_height)
            samples = [
                source.getpixel((x, y))
                for y in range(start_y, end_y, SOURCE_SAMPLE_STRIDE)
                for x in range(start_x, end_x, SOURCE_SAMPLE_STRIDE)
                if _is_green_foreground(source.getpixel((x, y)))
            ]
            if len(samples) < 100:
                raise ValueError(
                    f"Palette cell ({column}, {row}) has too few grass-green samples."
                )
            palette.append(_median_color(samples))
    palette.sort(key=_luminance)
    if len(set(palette)) != PALETTE_COLOR_COUNT:
        raise ValueError("ImageGen palette must yield eight distinct solid colors.")
    for darker, lighter in zip(palette, palette[1:]):
        if _luminance(lighter) <= _luminance(darker):
            raise ValueError("ImageGen palette lightness must increase strictly.")
    return palette


def _build_luminance_rank_lookup(
    reference: Image.Image,
    palette: list[tuple[int, int, int, int]],
) -> dict[tuple[int, int, int, int], tuple[int, int, int, int]]:
    """Quantize authored shading monotonically onto the finite palette."""
    opaque_colors = [color for color in reference.getdata() if color[3] == 255]
    sorted_luminances = sorted(_luminance(color) for color in opaque_colors)
    lookup: dict[
        tuple[int, int, int, int],
        tuple[int, int, int, int],
    ] = {}
    for color in set(opaque_colors):
        luminance = _luminance(color)
        first = bisect_left(sorted_luminances, luminance)
        last = bisect_right(sorted_luminances, luminance)
        rank = ((first + last - 1) * 0.5) / max(len(sorted_luminances) - 1, 1)
        palette_index = min(round(rank * (len(palette) - 1)), len(palette) - 1)
        lookup[color] = palette[palette_index]
    return lookup


def _transfer_palette(
    reference: Image.Image,
    source: Image.Image,
) -> tuple[Image.Image, list[tuple[int, int, int, int]]]:
    palette = _extract_swatch_palette(source)
    lookup = _build_luminance_rank_lookup(reference, palette)
    result = Image.new("RGBA", LOGICAL_SHEET_SIZE, (0, 0, 0, 0))
    for y in range(reference.height):
        for x in range(reference.width):
            reference_color = reference.getpixel((x, y))
            if reference_color[3] != 0:
                result.putpixel((x, y), lookup[reference_color])
    return result, palette


def _normalize_move_eyes(
    result: Image.Image,
    eye_color: tuple[int, int, int, int],
) -> None:
    for coordinate in MOVE_EYE_COORDINATES:
        result.putpixel(coordinate, eye_color)


def _pearson_correlation(values_a: list[float], values_b: list[float]) -> float:
    mean_a = sum(values_a) / len(values_a)
    mean_b = sum(values_b) / len(values_b)
    centered_a = [value - mean_a for value in values_a]
    centered_b = [value - mean_b for value in values_b]
    numerator = sum(a * b for a, b in zip(centered_a, centered_b))
    denominator_a = sum(value * value for value in centered_a) ** 0.5
    denominator_b = sum(value * value for value in centered_b) ** 0.5
    if denominator_a == 0.0 or denominator_b == 0.0:
        raise ValueError("Cannot correlate a flat luminance sequence.")
    return numerator / (denominator_a * denominator_b)


def _validate_logical_sheet(
    reference: Image.Image,
    result: Image.Image,
    palette: list[tuple[int, int, int, int]],
) -> float:
    if reference.size != LOGICAL_SHEET_SIZE or result.size != LOGICAL_SHEET_SIZE:
        raise ValueError("Both logical sheets must be exactly 96x64.")
    reference_luminances: list[float] = []
    result_luminances: list[float] = []
    visible_colors: set[tuple[int, int, int, int]] = set()
    for y in range(LOGICAL_SHEET_SIZE[1]):
        for x in range(LOGICAL_SHEET_SIZE[0]):
            reference_color = reference.getpixel((x, y))
            result_color = result.getpixel((x, y))
            if reference_color[3] != result_color[3]:
                raise ValueError(f"Alpha topology changed at ({x}, {y}).")
            if result_color[3] == 0:
                if result_color != (0, 0, 0, 0):
                    raise ValueError("Transparent pixels retain hidden RGB fringe.")
                continue
            visible_colors.add(result_color)
            if result_color not in palette:
                raise ValueError("Runtime sheet contains a color outside the clean palette.")
            if not _is_green_foreground(result_color):
                raise ValueError(f"Visible pixel ({x}, {y}) is not grass green.")
            if (x, y) not in MOVE_EYE_COORDINATES:
                reference_luminances.append(_luminance(reference_color))
                result_luminances.append(_luminance(result_color))
    if len(visible_colors) != PALETTE_COLOR_COUNT:
        raise ValueError(
            f"Runtime sheet must use exactly {PALETTE_COLOR_COUNT} colors; "
            f"found {len(visible_colors)}."
        )
    correlation = _pearson_correlation(reference_luminances, result_luminances)
    if correlation < MINIMUM_LUMINANCE_CORRELATION:
        raise ValueError(
            f"Luminance topology correlation {correlation:.6f} is below "
            f"{MINIMUM_LUMINANCE_CORRELATION:.3f}."
        )
    return correlation


def _validate_aligned_source(logical: Image.Image, aligned: Image.Image) -> None:
    if aligned.size != ALIGNED_SOURCE_SIZE:
        raise ValueError("Aligned source must be exactly 1536x1024.")
    for logical_y in range(LOGICAL_SHEET_SIZE[1]):
        for logical_x in range(LOGICAL_SHEET_SIZE[0]):
            expected = logical.getpixel((logical_x, logical_y))
            block = aligned.crop(
                (
                    logical_x * GRID_SCALE,
                    logical_y * GRID_SCALE,
                    (logical_x + 1) * GRID_SCALE,
                    (logical_y + 1) * GRID_SCALE,
                )
            )
            if any(pixel != expected for pixel in block.getdata()):
                raise ValueError(
                    f"Mother block ({logical_x}, {logical_y}) is not one "
                    "uniform 16x16 RGBA pixel."
                )


def _save_lossless_png(image: Image.Image, output_path: Path) -> None:
    """Write a compact PNG and prove the decoded RGBA bytes are unchanged."""
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
        source = source_image.convert("RGBA")

    logical_result, palette = _transfer_palette(reference, source)
    _normalize_move_eyes(logical_result, palette[0])
    correlation = _validate_logical_sheet(reference, logical_result, palette)
    aligned_source = logical_result.resize(
        ALIGNED_SOURCE_SIZE,
        resample=Image.Resampling.NEAREST,
    )
    _validate_aligned_source(logical_result, aligned_source)

    aligned_output_path.parent.mkdir(parents=True, exist_ok=True)
    _save_lossless_png(aligned_source, aligned_output_path)
    if logical_output_path is not None:
        logical_output_path.parent.mkdir(parents=True, exist_ok=True)
        _save_lossless_png(logical_result, logical_output_path)
    print(
        f"Wrote {aligned_output_path} at "
        f"{ALIGNED_SOURCE_SIZE[0]}x{ALIGNED_SOURCE_SIZE[1]}."
    )
    if logical_output_path is not None:
        print(f"Wrote {logical_output_path} at 96x64.")
    print("Validated byte-identical alpha and visual-pixel coordinates.")
    print(f"Validated exactly {len(palette)} finite palette colors: {palette}")
    print(f"Validated luminance-topology correlation: {correlation:.6f}.")
    print("Validated exact RGBA-uniform 16x16 mother-image blocks.")
    print("Validated lossless PNG encode/decode with byte-identical RGBA data.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Transfer eight clean ImageGen grass-green swatches onto the exact "
            "authored Slime alpha and shading topology."
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
