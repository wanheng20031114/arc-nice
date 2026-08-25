#!/usr/bin/env python3
"""Normalize and center transparent 32x32 collectible icons.

The source alpha channel is authoritative. This script clears hidden RGB from
transparent pixels, then recenters the visible subject on a 32x32 transparent
canvas without rescaling.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ICON_DIR = PROJECT_ROOT / "resources" / "texture" / "collectibles"


def clean_and_center_icon(
    image: Image.Image,
) -> tuple[Image.Image, tuple[int, int, int, int] | None]:
    rgba = image.convert("RGBA")
    if rgba.getchannel("A").getextrema()[0] == 255:
        raise ValueError(
            "collectible source must include ImageGen native transparent Alpha; "
            "regenerate it with a transparent background"
        )
    pixels = rgba.load()

    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)

    bbox = rgba.getchannel("A").getbbox()
    output = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    if bbox is None:
        return output, None

    subject = rgba.crop(bbox)
    paste_x = round((32 - subject.width) / 2.0)
    paste_y = round((32 - subject.height) / 2.0)
    output.alpha_composite(subject, (paste_x, paste_y))
    return output, bbox


def process_icon(path: Path, write: bool) -> str:
    image = Image.open(path)
    output, bbox = clean_and_center_icon(image)
    output_bbox = output.getchannel("A").getbbox()
    if write:
        output.save(path)
    return f"{path.name}: input_bbox={bbox}, output_bbox={output_bbox}"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Normalize transparent pixels and center collectible icons."
    )
    parser.add_argument("--icon-dir", type=Path, default=DEFAULT_ICON_DIR)
    parser.add_argument("--write", action="store_true", help="Overwrite source PNG files.")
    args = parser.parse_args()

    icon_dir = args.icon_dir.resolve()
    if not icon_dir.is_dir():
        raise SystemExit(f"Icon directory does not exist: {icon_dir}")

    for path in sorted(icon_dir.glob("*.png")):
        print(process_icon(path, args.write))


if __name__ == "__main__":
    main()
