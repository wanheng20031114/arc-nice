"""Build Tango's Electric Surge skill icon from its ImageGen chroma source."""

from __future__ import annotations

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "tango"
    / "tango_electric_surge_skill1_icon_imagegen_magenta.png"
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


def _is_magenta(red: int, green: int, blue: int) -> bool:
    """Remove the key and its antialiased spill without eating navy/cyan art."""
    return red >= 72 and blue >= 72 and min(red, blue) - green >= 18


def _remove_chroma(source: Image.Image) -> Image.Image:
    keyed = source.convert("RGBA")
    pixels = keyed.load()
    for y in range(keyed.height):
        for x in range(keyed.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0 or _is_magenta(red, green, blue):
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return keyed


def build_icon() -> None:
    keyed = _remove_chroma(Image.open(SOURCE))
    bounds = keyed.getchannel("A").getbbox()
    if bounds is None:
        raise RuntimeError("Tango skill icon source became empty after chroma removal")

    subject = keyed.crop(bounds)
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

    icon_pixels = icon.load()
    for y in range(icon.height):
        for x in range(icon.width):
            red, green, blue, alpha = icon_pixels[x, y]
            if alpha > 0 and _is_magenta(red, green, blue):
                icon_pixels[x, y] = (0, 0, 0, 0)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT, optimize=True)
    print(f"Built {OUTPUT.relative_to(ROOT)} ({ICON_SIZE}x{ICON_SIZE})")


if __name__ == "__main__":
    build_icon()
