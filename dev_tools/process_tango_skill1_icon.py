"""Build Tango's Electric Surge skill icon from its transparent ImageGen source."""

from __future__ import annotations

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "tango"
    / "tango_electric_surge_skill1_icon_imagegen_transparent.png"
)
OUTPUT = (
    ROOT
    / "resources"
    / "texture"
    / "player"
    / "tango"
    / "skill1_icon.png"
)
ICON_SIZE = 128
SUBJECT_SIZE = 116


def _load_native_transparent_source() -> Image.Image:
    if not SOURCE.is_file():
        raise FileNotFoundError(
            f"{SOURCE} is missing. Provide the Electric Surge icon as an "
            "ImageGen PNG with a native transparent background."
        )
    with Image.open(SOURCE) as source:
        if "A" not in source.getbands():
            raise ValueError(
                f"{SOURCE} has no Alpha channel. Regenerate it with a native "
                "transparent background."
            )
        minimum_alpha, maximum_alpha = source.getchannel("A").getextrema()
        if minimum_alpha >= 255 or maximum_alpha == 0:
            raise ValueError(
                f"{SOURCE} must contain both transparent and visible pixels in "
                "its native Alpha channel."
            )
        rgba = source.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
    return rgba


def build_icon() -> None:
    source = _load_native_transparent_source()
    bounds = source.getchannel("A").getbbox()
    if bounds is None:
        raise RuntimeError("Tango skill icon source has no visible Alpha pixels")

    subject = source.crop(bounds)
    scale = min(SUBJECT_SIZE / subject.width, SUBJECT_SIZE / subject.height)
    target_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(target_size, Image.Resampling.BOX)

    icon = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (0, 0, 0, 0))
    offset = (
        (ICON_SIZE - subject.width) // 2,
        (ICON_SIZE - subject.height) // 2,
    )
    icon.alpha_composite(subject, offset)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT, optimize=True)
    print(f"Built {OUTPUT.relative_to(ROOT)} ({ICON_SIZE}x{ICON_SIZE})")


if __name__ == "__main__":
    build_icon()
