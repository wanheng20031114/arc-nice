#!/usr/bin/env python3
"""Build the layered 128 px Orange Charging Tower runtime textures.

The image generator supplies one approved, composited 128x128 source. Runtime
animation reuses transparent responsibility layers instead of swapping complete
tower frames: a dormant body, the three orange slices, and the two glass panes.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from statistics import median

from PIL import Image, ImageDraw


CANVAS_SIZE = (128, 128)
TRANSPARENT = (0, 0, 0, 0)
SLICE_RECTS = (
    (45, 37, 83, 49),
    (44, 49, 84, 60),
    (31, 59, 97, 69),
)
GLASS_POLYGONS = (
    ((34, 34), (59, 35), (59, 69), (34, 67)),
    ((69, 35), (94, 34), (94, 67), (69, 69)),
)
BOTTOM_BAKED_HIGHLIGHT_RECT = (48, 64, 80, 69)
EXPECTED_BOTTOM_BAKED_HIGHLIGHT_COUNT = 29


def _is_orange(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return (
        alpha > 0
        and red >= 82
        and red >= green * 1.18
        and green >= blue * 0.95
        and red - blue >= 34
    )


def _is_glass_colored(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return (
        alpha > 0
        and green >= red * 0.72
        and blue >= red * 0.62
        and max(red, green, blue) >= 54
    )


def _darken_orange(pixel: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    red, green, blue, alpha = pixel
    return (
        max(62, round(red * 0.58)),
        max(30, round(green * 0.48)),
        max(13, round(blue * 0.62)),
        alpha,
    )


def _is_baked_bottom_highlight(
    x: int,
    y: int,
    pixel: tuple[int, int, int, int],
) -> bool:
    left, top, right, bottom = BOTTOM_BAKED_HIGHLIGHT_RECT
    if not (left <= x < right and top <= y < bottom):
        return False
    red, green, blue, alpha = pixel
    return (
        not _is_orange(pixel)
        and alpha > 0
        and red >= 240
        and green >= 210
        and blue <= 135
    )


def _bottom_dormant_row_color(
    source_pixels,
    y: int,
) -> tuple[int, int, int]:
    left, _, right, _ = BOTTOM_BAKED_HIGHLIGHT_RECT
    darkened_neighbors = [
        _darken_orange(source_pixels[x, y])
        for x in range(left, right)
        if _is_orange(source_pixels[x, y])
    ]
    if not darkened_neighbors:
        raise ValueError(f"Bottom orange slice row {y} has no dormant colors.")
    return tuple(
        int(median(pixel[channel] for pixel in darkened_neighbors))
        for channel in range(3)
    )


def _make_polygon_mask(size: tuple[int, int]) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    for polygon in GLASS_POLYGONS:
        draw.polygon(polygon, fill=112)
        draw.line(
            list(polygon) + [polygon[0]],
            fill=196,
            width=2,
            joint="curve",
        )
    return mask


def _clean_transparency(image: Image.Image) -> Image.Image:
    result = image.convert("RGBA")
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (red, green, blue, alpha) if alpha > 0 else TRANSPARENT
    return result


def build_layers(
    source_path: Path,
    output_dir: Path,
    preview_output: Path | None = None,
) -> None:
    source = _clean_transparency(Image.open(source_path))
    if source.size != CANVAS_SIZE:
        raise ValueError(
            f"Orange Charging Tower source must be 128x128, got {source.size}."
        )

    body = source.copy()
    orange_layers = Image.new("RGBA", CANVAS_SIZE, TRANSPARENT)
    source_pixels = source.load()
    body_pixels = body.load()
    orange_pixels = orange_layers.load()
    _, highlight_top, _, highlight_bottom = BOTTOM_BAKED_HIGHLIGHT_RECT
    bottom_dormant_row_colors = {
        y: _bottom_dormant_row_color(source_pixels, y)
        for y in range(highlight_top, highlight_bottom)
    }
    migrated_baked_highlights = 0

    for left, top, right, bottom in SLICE_RECTS:
        for y in range(top, bottom):
            for x in range(left, right):
                pixel = source_pixels[x, y]
                is_orange = _is_orange(pixel)
                is_baked_highlight = _is_baked_bottom_highlight(
                    x,
                    y,
                    pixel,
                )
                if not is_orange and not is_baked_highlight:
                    continue
                orange_pixels[x, y] = pixel
                # Every dormant layer must share one dark baseline. The runtime
                # shader restores exactly one authored slice at a time instead
                # of inheriting the generator's single baked highlight.
                if is_baked_highlight:
                    dormant_red, dormant_green, dormant_blue = (
                        bottom_dormant_row_colors[y]
                    )
                    body_pixels[x, y] = (
                        dormant_red,
                        dormant_green,
                        dormant_blue,
                        pixel[3],
                    )
                    migrated_baked_highlights += 1
                else:
                    body_pixels[x, y] = _darken_orange(pixel)

    if migrated_baked_highlights != EXPECTED_BOTTOM_BAKED_HIGHLIGHT_COUNT:
        raise ValueError(
            "Expected to migrate "
            f"{EXPECTED_BOTTOM_BAKED_HIGHLIGHT_COUNT} baked bottom highlights, "
            f"got {migrated_baked_highlights}."
        )

    glass_mask = _make_polygon_mask(CANVAS_SIZE)
    glass_mask_pixels = glass_mask.load()
    glass_glow = Image.new("RGBA", CANVAS_SIZE, TRANSPARENT)
    glass_glow_pixels = glass_glow.load()
    for y in range(CANVAS_SIZE[1]):
        for x in range(CANVAS_SIZE[0]):
            mask_alpha = glass_mask_pixels[x, y]
            if mask_alpha <= 0:
                continue
            pixel = source_pixels[x, y]
            if pixel[3] <= 0:
                continue

            # Keep the generated glass facets genuinely translucent while the
            # opaque orange pixels behind them remain legible.
            if _is_glass_colored(pixel):
                body_pixels[x, y] = (
                    pixel[0],
                    pixel[1],
                    pixel[2],
                    max(78, min(188, round(pixel[3] * 0.58))),
                )
            glass_glow_pixels[x, y] = (255, 170, 72, mask_alpha)

    output_dir.mkdir(parents=True, exist_ok=True)
    _clean_transparency(body).save(output_dir / "body.png", optimize=True)
    _clean_transparency(orange_layers).save(
        output_dir / "orange_layers_glow.png", optimize=True
    )
    _clean_transparency(glass_glow).save(
        output_dir / "glass_cycle_glow.png", optimize=True
    )
    source.save(output_dir / "icon.png", optimize=True)

    if preview_output is not None:
        preview_output.parent.mkdir(parents=True, exist_ok=True)
        preview = source.resize((32, 32), Image.Resampling.NEAREST)
        preview.save(preview_output, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Split an approved 128 px Orange Charging Tower source."
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument(
        "--preview-output",
        type=Path,
        help="Optional exact 32x32 nearest-neighbour review preview.",
    )
    args = parser.parse_args()
    build_layers(args.source, args.output_dir, args.preview_output)


if __name__ == "__main__":
    main()
