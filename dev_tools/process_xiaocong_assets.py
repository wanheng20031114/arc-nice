#!/usr/bin/env python3
"""Build Xiaocong's native pixel assets from reviewed ImageGen source art.

The Xiaocong source already carries native transparency. Its generated pixel grid is
measured before any reduction; this stage then samples each detected logical
cell once, applies a small non-dithered palette, and performs only integer-pixel
animation edits.  Runtime frames are kept at their native size in Godot.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

from pixel_crop_tool import (
    compress_to_logical_grid,
    crop_to_square,
    normalize_transparency,
)
from pixel_grid_analyzer import analyze_image, find_subject_bbox


SOURCE_SUBJECT_GRID_SIZE = (23, 37)
RUNTIME_FRAME_SIZE = (27, 41)
RUNTIME_SUBJECT_OFFSET = (2, 2)
SOURCE_MIN_GRID_CONFIDENCE = 0.9
RUNTIME_PALETTE_COLORS = 28
FRAME_COUNT = 12


def _hard_palette(image: Image.Image, colors: int) -> Image.Image:
    return image.convert("RGBA").quantize(
        colors=colors,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.NONE,
    ).convert("RGBA")


def build_xiaocong_base(source: Path) -> Image.Image:
    transparent = normalize_transparency(Image.open(source), alpha_threshold=127)
    analysis = analyze_image(transparent)
    detected_size = (
        int(analysis["subject_grid_width"]),
        int(analysis["subject_grid_height"]),
    )
    if float(analysis["confidence"]) < SOURCE_MIN_GRID_CONFIDENCE:
        raise ValueError(
            "Xiaocong source grid confidence is too low: "
            f"{analysis['confidence']:.3f}"
        )
    if detected_size != SOURCE_SUBJECT_GRID_SIZE:
        raise ValueError(
            "Xiaocong source logical subject changed: "
            f"expected {SOURCE_SUBJECT_GRID_SIZE}, detected {detected_size}"
        )

    # The measured subject bounds are exactly 23x37 generated logical cells.
    # Nearest-neighbour center sampling maps one detected cell to one runtime
    # pixel; it is not an arbitrary visual resize.
    subject = transparent.crop(find_subject_bbox(transparent)).resize(
        SOURCE_SUBJECT_GRID_SIZE,
        Image.Resampling.NEAREST,
    )
    subject = _hard_palette(subject, RUNTIME_PALETTE_COLORS)
    base = Image.new("RGBA", RUNTIME_FRAME_SIZE, (0, 0, 0, 0))
    base.alpha_composite(subject, RUNTIME_SUBJECT_OFFSET)
    return base


def _shift_opaque_pixels(image: Image.Image, y_offset: int) -> Image.Image:
    shifted = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shifted.alpha_composite(image, (0, y_offset))
    return shifted


def _replace_eye_row(frame: Image.Image, mode: str) -> None:
    """Animate the reviewed native eye clusters without resampling the frame."""
    pixels = frame.load()
    eye_clusters = ((9, 11), (16, 18))
    skin_color = (233, 229, 207, 255)
    lid_color = (35, 30, 25, 255)
    if mode == "half":
        for x0, x1 in eye_clusters:
            for x in range(x0, x1 + 1):
                pixels[x, 21] = lid_color
                pixels[x, 22] = skin_color
    elif mode == "closed":
        for x0, x1 in eye_clusters:
            for x in range(x0, x1 + 1):
                for y in range(19, 23):
                    pixels[x, y] = skin_color
                pixels[x, 21] = lid_color


def build_xiaocong_sheet(base: Image.Image) -> Image.Image:
    # One calm three-second loop at 4 FPS: a two-frame rise and one natural
    # four-phase blink.  There is no rotation or directional pose change.
    y_offsets = (0, 0, 0, -1, -1, -1, -1, 0, 0, 0, 0, 0)
    eye_modes = ("open", "open", "open", "open", "open", "open",
                 "open", "open", "half", "closed", "half", "open")
    logical_sheet = Image.new(
        "RGBA",
        (
            RUNTIME_FRAME_SIZE[0] * FRAME_COUNT,
            RUNTIME_FRAME_SIZE[1],
        ),
        (0, 0, 0, 0),
    )
    for index, (y_offset, eye_mode) in enumerate(zip(y_offsets, eye_modes)):
        frame = base.copy()
        _replace_eye_row(frame, eye_mode)
        frame = _shift_opaque_pixels(frame, y_offset)
        logical_sheet.alpha_composite(
            frame,
            (index * RUNTIME_FRAME_SIZE[0], 0),
        )

    # Runtime frames remain native 27x41 pixels and are displayed at scale 1.
    # All animation changes are whole-pixel edits, so camera movement cannot
    # introduce fractional sprite sampling.
    return logical_sheet


def build_fate_stone(source: Path) -> Image.Image:
    transparent = normalize_transparency(Image.open(source))
    square = crop_to_square(transparent, padding=36, align_to_grid=True)
    logical, _analysis = compress_to_logical_grid(
        square,
        logical_size=48,
        allow_unsafe_grid_compression=True,
    )
    return _hard_palette(logical, 24)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xiaocong-source", type=Path, required=True)
    parser.add_argument("--stone-source", type=Path, required=True)
    parser.add_argument("--base-out", type=Path, required=True)
    parser.add_argument("--sheet-out", type=Path, required=True)
    parser.add_argument("--stone-out", type=Path, required=True)
    args = parser.parse_args()

    base = build_xiaocong_base(args.xiaocong_source)
    sheet = build_xiaocong_sheet(base)
    stone = build_fate_stone(args.stone_source)
    for output in (args.base_out, args.sheet_out, args.stone_out):
        output.parent.mkdir(parents=True, exist_ok=True)
    base.save(args.base_out, optimize=True)
    sheet.save(args.sheet_out, optimize=True)
    stone.save(args.stone_out, optimize=True)
    print(f"Xiaocong base: {base.size[0]}x{base.size[1]}")
    print(f"Xiaocong sheet: {sheet.size[0]}x{sheet.size[1]} ({FRAME_COUNT} frames)")
    print(f"Fate stone: {stone.size[0]}x{stone.size[1]}")


if __name__ == "__main__":
    main()
