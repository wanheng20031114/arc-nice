from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import Image


HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parents[4]
SOURCE_PATH = HERE / "cropped_10_unquantized.png"
OUTPUT_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "ui"
    / "inventory"
    / "quick_use_badge.png"
)

# Two authored sky-blue tones plus transparent pixels.  The pale upper shape is
# the press actuator; the saturated lower bar is the button being activated.
PALETTE = (
    (169, 232, 255, 255),
    (22, 143, 209, 255),
)
TRANSPARENT = (0, 0, 0, 0)


def _distance(source: tuple[int, int, int, int], target: tuple[int, int, int, int]) -> int:
    red = source[0] - target[0]
    green = source[1] - target[1]
    blue = source[2] - target[2]
    return red * red * 2 + green * green * 3 + blue * blue


def main() -> None:
    source = Image.open(SOURCE_PATH).convert("RGBA")
    if source.size != (10, 10):
        raise ValueError(f"Expected a 10x10 reviewed logical source, got {source.size}")

    output = Image.new("RGBA", source.size, TRANSPARENT)
    for y in range(source.height):
        for x in range(source.width):
            pixel = source.getpixel((x, y))
            if pixel[3] <= 127:
                continue
            output.putpixel((x, y), min(PALETTE, key=lambda color: _distance(pixel, color)))

    visible = {pixel for pixel in output.getdata() if pixel[3] > 0}
    alpha_values = {pixel[3] for pixel in output.getdata()}
    bbox = output.getbbox()
    if not visible or len(visible) > len(PALETTE):
        raise ValueError(f"Unexpected visible palette size: {len(visible)}")
    if not alpha_values.issubset({0, 255}):
        raise ValueError(f"Alpha must be binary, got {sorted(alpha_values)}")
    if bbox is None or bbox[0] < 1 or bbox[1] < 1 or bbox[2] > 9 or bbox[3] > 9:
        raise ValueError(f"Badge must retain a one-pixel transparent safety edge, got {bbox}")

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    output.save(OUTPUT_PATH, format="PNG", optimize=False, compress_level=9)
    digest = hashlib.sha256(OUTPUT_PATH.read_bytes()).hexdigest()
    print(f"Wrote {OUTPUT_PATH}")
    print(f"Visible colors: {len(visible)}")
    print(f"Subject bbox: {bbox}")
    print(f"SHA-256: {digest}")


if __name__ == "__main__":
    main()
