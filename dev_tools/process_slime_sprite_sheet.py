#!/usr/bin/env python3
"""Convert an alpha-matted 3x2 slime reference into a 32px Godot sprite sheet."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


COLUMNS = 3
ROWS = 2
FRAME_SIZE = 32
SUBJECT_BASELINE = 22
ALPHA_THRESHOLD = 24
PALETTE_COLOR_COUNT = 16
MOVE_FRAME_BOUNDS = (
    (7, 9, 24, 22),
    (6, 9, 24, 22),
    (7, 9, 24, 22),
)
EYE_COLOR = (4, 59, 149, 255)
MOVE_EYE_POSITIONS = (
    ((13, 16), (17, 16)),
    ((12, 15), (17, 15)),
    ((13, 16), (17, 16)),
)
COLLAPSE_EYE_POSITIONS = ((13, 17), (17, 17))
OUTLINE_COLOR = EYE_COLOR
CLEAN_MOVE_ROW_SPANS = (
    (
        (9, 13, 16),
        (10, 11, 19),
        (11, 10, 20),
        (12, 9, 21),
        (13, 8, 22),
        (14, 8, 22),
        (15, 8, 22),
        (16, 7, 23),
        (17, 7, 23),
        (18, 7, 23),
        (19, 8, 22),
        (20, 8, 22),
        (21, 9, 21),
    ),
    (
        (9, 13, 17),
        (10, 10, 19),
        (11, 9, 20),
        (12, 8, 21),
        (13, 7, 22),
        (14, 7, 23),
        (15, 7, 23),
        (16, 6, 23),
        (17, 6, 23),
        (18, 6, 23),
        (19, 7, 23),
        (20, 7, 22),
        (21, 9, 20),
    ),
    (
        (9, 14, 16),
        (10, 12, 18),
        (11, 11, 19),
        (12, 10, 20),
        (13, 9, 21),
        (14, 8, 22),
        (15, 8, 23),
        (16, 7, 23),
        (17, 7, 23),
        (18, 7, 23),
        (19, 7, 23),
        (20, 8, 22),
        (21, 9, 21),
    ),
)


def _make_alpha_binary(image: Image.Image) -> Image.Image:
    result = image.convert("RGBA")
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= ALPHA_THRESHOLD:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return result


def _center_on_authored_baseline(frame: Image.Image) -> Image.Image:
    subject_bounds = frame.getchannel("A").getbbox()
    if subject_bounds is None:
        raise ValueError("Generated slime frame contains no visible pixels.")
    subject_width = subject_bounds[2] - subject_bounds[0]
    target_left = (FRAME_SIZE - subject_width) // 2
    offset = (
        target_left - subject_bounds[0],
        SUBJECT_BASELINE - subject_bounds[3],
    )
    result = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    result.alpha_composite(frame, offset)
    return result


def _fit_move_frame_to_insect_rhythm(
    cell: Image.Image,
    frame_index: int,
) -> Image.Image:
    source = _make_alpha_binary(cell)
    source_bounds = source.getchannel("A").getbbox()
    if source_bounds is None:
        raise ValueError("Generated slime move frame contains no visible pixels.")
    target_bounds = MOVE_FRAME_BOUNDS[frame_index]
    target_size = (
        target_bounds[2] - target_bounds[0],
        target_bounds[3] - target_bounds[1],
    )
    subject = source.crop(source_bounds).resize(
        target_size,
        Image.Resampling.NEAREST,
    )
    subject = _make_alpha_binary(subject)
    result = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    result.alpha_composite(subject, target_bounds[:2])
    return result


def _stamp_simple_eyes(sheet: Image.Image) -> None:
    """Keep the tiny eye marks readable after nearest-neighbor downscaling."""
    for frame_index, positions in enumerate(MOVE_EYE_POSITIONS):
        frame_offset_x = frame_index * FRAME_SIZE
        for local_x, local_y in positions:
            sheet.putpixel(
                (frame_offset_x + local_x, local_y),
                EYE_COLOR,
            )
    for local_x, local_y in COLLAPSE_EYE_POSITIONS:
        sheet.putpixel(
            (local_x, FRAME_SIZE + local_y),
            EYE_COLOR,
        )


def _repair_move_outlines(sheet: Image.Image) -> None:
    """Apply clean masks and a continuous one-pixel outline to live frames."""
    cardinal_neighbors = ((-1, 0), (1, 0), (0, -1), (0, 1))
    for frame_index, row_spans in enumerate(CLEAN_MOVE_ROW_SPANS):
        frame_offset_x = frame_index * FRAME_SIZE
        clean_mask = {
            (local_x, local_y)
            for local_y, left_x, right_x in row_spans
            for local_x in range(left_x, right_x + 1)
        }
        boundary = {
            (local_x, local_y)
            for local_x, local_y in clean_mask
            if any(
                (local_x + offset_x, local_y + offset_y)
                not in clean_mask
                for offset_x, offset_y in cardinal_neighbors
            )
        }
        for local_y in range(FRAME_SIZE):
            for local_x in range(FRAME_SIZE):
                sheet_position = (frame_offset_x + local_x, local_y)
                if (local_x, local_y) not in clean_mask:
                    sheet.putpixel(sheet_position, (0, 0, 0, 0))
                elif (local_x, local_y) in boundary:
                    sheet.putpixel(sheet_position, OUTLINE_COLOR)
        visible_mask = {
            (local_x, local_y)
            for local_x, local_y in clean_mask
            if sheet.getpixel(
                (frame_offset_x + local_x, local_y)
            )[3]
            > 0
        }
        if visible_mask != clean_mask:
            raise ValueError(
                "Generated slime does not cover the clean movement mask."
            )


def process_sprite_sheet(source_path: Path, output_path: Path) -> None:
    with Image.open(source_path) as source_image:
        source = source_image.convert("RGBA")
    if source.width % COLUMNS != 0 or source.height % ROWS != 0:
        raise ValueError(
            "Source dimensions must divide evenly into a 3x2 sprite sheet."
        )

    source_cell_width = source.width // COLUMNS
    source_cell_height = source.height // ROWS
    sheet = Image.new(
        "RGBA",
        (FRAME_SIZE * COLUMNS, FRAME_SIZE * ROWS),
        (0, 0, 0, 0),
    )
    for row in range(ROWS):
        for column in range(COLUMNS):
            cell = source.crop(
                (
                    column * source_cell_width,
                    row * source_cell_height,
                    (column + 1) * source_cell_width,
                    (row + 1) * source_cell_height,
                )
            )
            if row == 0:
                frame = _fit_move_frame_to_insect_rhythm(cell, column)
            else:
                frame = cell.resize(
                    (FRAME_SIZE, FRAME_SIZE),
                    Image.Resampling.NEAREST,
                )
                frame = _center_on_authored_baseline(
                    _make_alpha_binary(frame)
                )
            sheet.alpha_composite(
                frame,
                (column * FRAME_SIZE, row * FRAME_SIZE),
            )

    quantized = sheet.quantize(
        colors=PALETTE_COLOR_COUNT,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.NONE,
    ).convert("RGBA")
    quantized.putalpha(sheet.getchannel("A"))
    quantized = _make_alpha_binary(quantized)
    _repair_move_outlines(quantized)
    _stamp_simple_eyes(quantized)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    quantized.save(output_path, format="PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the 96x64 basic slime sprite sheet."
    )
    parser.add_argument("source_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()
    process_sprite_sheet(args.source_path, args.output_path)


if __name__ == "__main__":
    main()
