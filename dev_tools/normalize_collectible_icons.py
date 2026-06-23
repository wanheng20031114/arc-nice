#!/usr/bin/env python3
"""
Clean and center 32x32 collectible icons.

This is intentionally not a flood-fill background remover: several icons have
holes, so disconnected key-color residue can remain inside the subject. The
script removes only magenta key-color artifacts, then recenters the visible
subject on a 32x32 transparent canvas without rescaling.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ICON_DIR = PROJECT_ROOT / "resources" / "texture" / "collectibles"
PURPLE_SUBJECTS = {"amethyst.png", "magic_ring.png"}


def is_strict_magenta(red: int, green: int, blue: int) -> bool:
    """Near-pure chroma-key magenta; safe even on purple-themed icons."""
    return (
        (red >= 180 and blue >= 180 and green <= 45 and abs(red - blue) <= 70)
        or (max(red, blue) >= 220 and min(red, blue) >= 150 and green <= 55 and abs(red - blue) <= 95)
        or (red >= 110 and blue >= 110 and green <= 16 and abs(red - blue) <= 55)
    )


def is_wide_magenta(red: int, green: int, blue: int) -> bool:
    """Broader magenta cleanup for icons that should not contain purple material."""
    maximum = max(red, green, blue)
    minimum = min(red, green, blue)
    if maximum < 56:
        return False
    saturation = float(maximum - minimum) / float(maximum)
    if saturation < 0.46:
        return False
    return (
        red >= 60
        and blue >= 60
        and green <= red * 0.42
        and green <= blue * 0.42
        and abs(red - blue) <= 95
    )


def should_remove_pixel(pixel: tuple[int, int, int, int], file_name: str) -> bool:
    red, green, blue, alpha = pixel
    if alpha == 0:
        return False
    if file_name in PURPLE_SUBJECTS:
        return is_strict_magenta(red, green, blue)
    return is_strict_magenta(red, green, blue) or is_wide_magenta(red, green, blue)


def clean_and_center_icon(image: Image.Image, file_name: str) -> tuple[Image.Image, int, tuple[int, int, int, int] | None]:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    removed_count = 0

    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            if should_remove_pixel((red, green, blue, alpha), file_name):
                pixels[x, y] = (0, 0, 0, 0)
                removed_count += 1

    bbox = rgba.getchannel("A").getbbox()
    output = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    if bbox is None:
        return output, removed_count, None

    subject = rgba.crop(bbox)
    paste_x = round((32 - subject.width) / 2.0)
    paste_y = round((32 - subject.height) / 2.0)
    output.alpha_composite(subject, (paste_x, paste_y))
    return output, removed_count, bbox


def process_icon(path: Path, write: bool) -> str:
    image = Image.open(path)
    output, removed_count, bbox = clean_and_center_icon(image, path.name)
    output_bbox = output.getchannel("A").getbbox()
    if write:
        output.save(path)
    return (
        f"{path.name}: removed={removed_count}, "
        f"input_bbox={bbox}, output_bbox={output_bbox}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Clean magenta residue and center collectible icons.")
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
