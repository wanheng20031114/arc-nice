#!/usr/bin/env python3
"""Build Xiaocong's native pixel assets from reviewed ImageGen source art.

The source files are chroma-keyed before this script is run.  This stage only
performs hard-alpha normalization, nearest-neighbour logical-grid reduction,
palette reduction without dithering, and exact integer-pixel animation edits.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from statistics import median

from PIL import Image

from pixel_crop_tool import (
    compress_to_logical_grid,
    crop_to_square,
    normalize_transparency,
)


LOGICAL_FRAME_SIZE = (52, 68)
ASSET_SCALE = 2
ASSET_FRAME_SIZE = tuple(dimension * ASSET_SCALE for dimension in LOGICAL_FRAME_SIZE)
FRAME_COUNT = 12
SOURCE_PADDING = 32


def _is_magenta_spill(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return (
        alpha > 0
        and red >= 80
        and blue >= 70
        and green <= 80
        and red - green >= 55
        and blue - green >= 45
    )


def _despill_magenta_edges(image: Image.Image) -> Image.Image:
    """Replace keyed magenta fringe with neighbouring opaque foreground color."""
    cleaned = image.copy().convert("RGBA")
    pixels = cleaned.load()
    remaining = {
        (x, y)
        for y in range(cleaned.height)
        for x in range(cleaned.width)
        if _is_magenta_spill(pixels[x, y])
    }
    neighbour_offsets = (
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),           (1, 0),
        (-1, 1),  (0, 1),  (1, 1),
    )

    # Work from clean foreground into each fringe component.  Updating one
    # frontier per pass preserves the existing opaque silhouette while avoiding
    # a transparent notch at the chroma boundary.
    while remaining:
        replacements: dict[tuple[int, int], tuple[int, int, int, int]] = {}
        for x, y in remaining:
            neighbours: list[tuple[int, int, int, int]] = []
            for offset_x, offset_y in neighbour_offsets:
                sample_x = x + offset_x
                sample_y = y + offset_y
                if not (0 <= sample_x < cleaned.width and 0 <= sample_y < cleaned.height):
                    continue
                if (sample_x, sample_y) in remaining:
                    continue
                sample = pixels[sample_x, sample_y]
                if sample[3] > 0:
                    neighbours.append(sample)
            if neighbours:
                replacements[(x, y)] = (
                    round(median(sample[0] for sample in neighbours)),
                    round(median(sample[1] for sample in neighbours)),
                    round(median(sample[2] for sample in neighbours)),
                    255,
                )

        if not replacements:
            # This should not occur for a chroma fringe attached to the subject.
            # Keep any isolated authored color instead of erasing opaque pixels.
            break
        for (x, y), replacement in replacements.items():
            pixels[x, y] = replacement
        remaining.difference_update(replacements)

    return cleaned


def _hard_palette(image: Image.Image, colors: int) -> Image.Image:
    alpha = image.getchannel("A")
    rgb = image.convert("RGB").quantize(
        colors=colors,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")
    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha.point(lambda value: 255 if value > 0 else 0))
    return rgba


def _center_crop(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    width, height = size
    left = (image.width - width) // 2
    top = (image.height - height) // 2
    return image.crop((left, top, left + width, top + height))


def build_xiaocong_base(source: Path) -> Image.Image:
    keyed = _despill_magenta_edges(normalize_transparency(Image.open(source)))
    square = crop_to_square(keyed, padding=SOURCE_PADDING, align_to_grid=True)
    # The v2 ImageGen source was manually reviewed at 1:1 and enlarged views:
    # its silhouette is clean and deliberately pixel-styled, but the generated
    # cell widths vary enough that automatic grid confidence is low.  The
    # explicit unsafe flag is therefore intentional.  Reduction happens once,
    # directly to the 68-pixel logical canvas with nearest-neighbour sampling.
    logical, _analysis = compress_to_logical_grid(
        square,
        logical_size=68,
        allow_unsafe_grid_compression=True,
    )
    base = _center_crop(logical, LOGICAL_FRAME_SIZE)
    return _hard_palette(base, 64)


def _shift_opaque_pixels(image: Image.Image, y_offset: int) -> Image.Image:
    shifted = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shifted.alpha_composite(image, (0, y_offset))
    return shifted


def _replace_eye_row(frame: Image.Image, mode: str) -> None:
    """Apply the reviewed 52x68 eye edit; coordinates are logical pixels."""
    pixels = frame.load()
    # Measured from the v2 logical frame: the visible two-pixel irises occupy
    # x=22..23 / x=28..29 and y=19..20.  The four-pixel edit boxes below include
    # the lashes but do not touch the fringe or the cheek highlights.
    eye_clusters = ((20, 23), (28, 31))
    skin_color = (253, 236, 211, 255)
    lid_color = (61, 42, 38, 255)
    if mode == "half":
        for x0, x1 in eye_clusters:
            for x in range(x0, x1 + 1):
                pixels[x, 19] = lid_color
    elif mode == "closed":
        for x0, x1 in eye_clusters:
            for x in range(x0, x1 + 1):
                pixels[x, 19] = skin_color
                pixels[x, 20] = lid_color


def build_xiaocong_sheet(base: Image.Image) -> Image.Image:
    # One calm three-second loop at 4 FPS: a two-frame rise and one natural
    # four-phase blink.  There is no rotation or directional pose change.
    y_offsets = (0, 0, 0, -1, -1, -1, -1, 0, 0, 0, 0, 0)
    eye_modes = ("open", "open", "open", "open", "open", "open",
                 "open", "open", "half", "closed", "half", "open")
    logical_sheet = Image.new(
        "RGBA",
        (LOGICAL_FRAME_SIZE[0] * FRAME_COUNT, LOGICAL_FRAME_SIZE[1]),
        (0, 0, 0, 0),
    )
    for index, (y_offset, eye_mode) in enumerate(zip(y_offsets, eye_modes)):
        frame = _shift_opaque_pixels(base, y_offset)
        _replace_eye_row(frame, eye_mode)
        logical_sheet.alpha_composite(
            frame,
            (index * LOGICAL_FRAME_SIZE[0], 0),
        )

    # Keep the animation authored on the 52x68 logical grid, then duplicate
    # every logical pixel into an exact 2x2 block.  Godot displays the resulting
    # 104x136 frames at scale 0.5, recovering the logical frame exactly without
    # sampling away independently generated high-resolution detail.
    return logical_sheet.resize(
        (ASSET_FRAME_SIZE[0] * FRAME_COUNT, ASSET_FRAME_SIZE[1]),
        Image.Resampling.NEAREST,
    )


def build_fate_stone(source: Path) -> Image.Image:
    keyed = normalize_transparency(Image.open(source))
    square = crop_to_square(keyed, padding=36, align_to_grid=True)
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
