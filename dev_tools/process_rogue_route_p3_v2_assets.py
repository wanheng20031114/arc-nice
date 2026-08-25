"""Build the second-generation P3 route-map runtime textures.

The ImageGen icon sources use native transparent Alpha. This script performs
only deterministic project-side work:

* crops the already-transparent subjects by alpha coverage;
* rescales them into a deliberately roomy 128x128 canvas;
* snaps visible RGB values to a compact six-colour palette without dithering;
* preserves a soft alpha edge for the non-pixel-art route-map UI;
* crops the generated underground ruins to 16:9 before a high-quality resize; and
* authors the simple three-colour empty-node bead.

Run from any working directory with ``python dev_tools/process_rogue_route_p3_v2_assets.py``.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageOps


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = REPO_ROOT / "dev_tools/generated_sources/rogue_route_p3_v2"
ALPHA_ROOT = SOURCE_ROOT / "alpha"
OUTPUT_ROOT = REPO_ROOT / "resources/texture/rogue_route"

BACKGROUND_SOURCE = SOURCE_ROOT / "underground_ruins_background_source.png"
BACKGROUND_OUTPUT = OUTPUT_ROOT / "underground_ruins_background.png"
BACKGROUND_SIZE = (2304, 1296)
# ImageGen delivers useful stone detail at a display-oriented exposure.  The
# route board needs a quieter information backdrop, so bake the exposure down
# once instead of paying for or tuning a runtime shader.
BACKGROUND_BRIGHTNESS = 0.85

ICON_SIZE = 128
ICON_SUBJECT_MAX = 88
ICON_PALETTE_SIZE = 6
ICON_NAMES = (
    "magical_encounter",
    "emergency_combat",
    "normal_combat",
    "wilderness_resource",
    "underground_shop",
    "prepare_ahead",
)

HUD_ICON_SIZE = 48
HUD_ICON_SUBJECT_MAX = 32
HUD_ICON_PALETTE_SIZE = 6
HUD_ICON_NAMES = (
    "hud_ap_icon",
    "hud_seed_icon",
    "hud_location_icon",
)

# The purple hood occupies less area than its dark face and outline, so an
# unconstrained six-colour median-cut palette discards the type's identity.
ICON_PALETTE_OVERRIDES = {
    "underground_shop": (
        (24, 32, 31),
        (46, 48, 56),
        (70, 58, 100),
        (114, 86, 143),
        (183, 136, 40),
        (241, 212, 117),
    ),
    # The cyan relic and bronze clasp are both smaller than the stone shell;
    # lock the semantic accents so median-cut cannot discard them at 22px.
    "wilderness_resource": (
        (14, 24, 24),
        (48, 61, 64),
        (95, 103, 103),
        (177, 174, 168),
        (49, 199, 221),
        (175, 128, 56),
    ),
}

EMPTY_NODE_OUTPUT = OUTPUT_ROOT / "empty_node.png"
EMPTY_NODE_SIZE = 32
EMPTY_NODE_SCALE = 4
EMPTY_NODE_PALETTE = (
    (17, 25, 37),
    (83, 102, 118),
    (217, 236, 244),
)


def _alpha_bbox(image: Image.Image, threshold: int = 4) -> tuple[int, int, int, int]:
    alpha = image.getchannel("A")
    mask = alpha.point(lambda value: 255 if value >= threshold else 0)
    bbox = mask.getbbox()
    if bbox is None:
        raise RuntimeError("Transparent source contains no visible subject")
    return bbox


def _resize_rgba_premultiplied(
    image: Image.Image,
    size: tuple[int, int],
) -> Image.Image:
    """Resize RGBA while preventing hidden transparent RGB from bleeding into edges."""

    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    resized_alpha = alpha.resize(size, Image.Resampling.LANCZOS)

    resized_premultiplied: list[Image.Image] = []
    for channel in rgba.convert("RGB").split():
        premultiplied = ImageChops.multiply(channel, alpha)
        resized_premultiplied.append(
            premultiplied.resize(size, Image.Resampling.LANCZOS)
        )

    alpha_values = list(resized_alpha.getdata())
    premultiplied_values = [list(channel.getdata()) for channel in resized_premultiplied]
    pixels: list[tuple[int, int, int, int]] = []
    for index, alpha_value in enumerate(alpha_values):
        if alpha_value <= 1:
            pixels.append((0, 0, 0, 0))
            continue
        channels = tuple(
            min(255, round(values[index] * 255.0 / alpha_value))
            for values in premultiplied_values
        )
        pixels.append((*channels, alpha_value))

    resized = Image.new("RGBA", size, (0, 0, 0, 0))
    resized.putdata(pixels)
    return resized


def _derive_palette(image: Image.Image, color_count: int) -> tuple[tuple[int, int, int], ...]:
    samples = [
        (red, green, blue)
        for red, green, blue, alpha in image.getdata()
        if alpha >= 24
    ]
    if not samples:
        raise RuntimeError("Cannot derive a palette from an empty icon")

    strip = Image.new("RGB", (len(samples), 1))
    strip.putdata(samples)
    indexed = strip.quantize(
        colors=color_count,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    )
    raw_palette = indexed.getpalette()
    if raw_palette is None:
        raise RuntimeError("Pillow did not return a palette")
    used_indices = sorted(indexed.getcolors(maxcolors=color_count) or ())
    palette = tuple(
        tuple(raw_palette[index * 3 : index * 3 + 3])
        for _count, index in used_indices
    )
    if not palette:
        raise RuntimeError("Derived palette is empty")
    return palette


def _snap_rgb_to_palette(
    image: Image.Image,
    palette: Iterable[tuple[int, int, int]],
) -> Image.Image:
    colors = tuple(palette)
    if not colors:
        raise ValueError("Palette must not be empty")

    snapped: list[tuple[int, int, int, int]] = []
    for red, green, blue, alpha in image.convert("RGBA").getdata():
        if alpha <= 1:
            snapped.append((0, 0, 0, 0))
            continue
        nearest = min(
            colors,
            key=lambda color: (
                (red - color[0]) ** 2
                + (green - color[1]) ** 2
                + (blue - color[2]) ** 2
            ),
        )
        snapped.append((*nearest, alpha))

    output = Image.new("RGBA", image.size, (0, 0, 0, 0))
    output.putdata(snapped)
    return output


def _build_background() -> None:
    if not BACKGROUND_SOURCE.is_file():
        raise FileNotFoundError(BACKGROUND_SOURCE)
    source = Image.open(BACKGROUND_SOURCE).convert("RGB")
    background = ImageOps.fit(
        source,
        BACKGROUND_SIZE,
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    background = ImageEnhance.Brightness(background).enhance(
        BACKGROUND_BRIGHTNESS
    )
    background.save(BACKGROUND_OUTPUT, format="PNG", optimize=True)


def _build_icon(
    name: str,
    canvas_size: int,
    subject_max: int,
    palette_size: int,
) -> tuple[tuple[int, int, int], ...]:
    source_path = ALPHA_ROOT / f"{name}_alpha.png"
    if not source_path.is_file():
        raise FileNotFoundError(source_path)

    source = Image.open(source_path).convert("RGBA")
    if source.getchannel("A").getextrema()[0] == 255:
        raise RuntimeError(f"Icon source must have a native transparent background: {source_path}")
    subject = source.crop(_alpha_bbox(source))
    scale = min(
        subject_max / subject.width,
        subject_max / subject.height,
    )
    target_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = _resize_rgba_premultiplied(subject, target_size)

    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    position = (
        (canvas_size - subject.width) // 2,
        (canvas_size - subject.height) // 2,
    )
    canvas.alpha_composite(subject, position)

    palette = ICON_PALETTE_OVERRIDES.get(name)
    if palette is None:
        palette = _derive_palette(canvas, palette_size)
    canvas = _snap_rgb_to_palette(canvas, palette)
    canvas.save(OUTPUT_ROOT / f"{name}.png", format="PNG", optimize=True)
    return palette


def _build_empty_node() -> None:
    working_size = EMPTY_NODE_SIZE * EMPTY_NODE_SCALE
    image = Image.new("RGBA", (working_size, working_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    scale = EMPTY_NODE_SCALE

    draw.ellipse(
        (2 * scale, 2 * scale, 30 * scale - 1, 30 * scale - 1),
        fill=(*EMPTY_NODE_PALETTE[0], 255),
    )
    draw.ellipse(
        (6 * scale, 6 * scale, 26 * scale - 1, 26 * scale - 1),
        fill=(*EMPTY_NODE_PALETTE[1], 255),
    )
    draw.ellipse(
        (9 * scale, 8 * scale, 14 * scale - 1, 13 * scale - 1),
        fill=(*EMPTY_NODE_PALETTE[2], 255),
    )

    image = image.resize(
        (EMPTY_NODE_SIZE, EMPTY_NODE_SIZE),
        Image.Resampling.LANCZOS,
    )
    image = _snap_rgb_to_palette(image, EMPTY_NODE_PALETTE)
    image.save(EMPTY_NODE_OUTPUT, format="PNG", optimize=True)


def _visible_rgb_colors(image: Image.Image) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for red, green, blue, alpha in image.convert("RGBA").getdata()
        if alpha > 0
    }


def _asset_report() -> dict[str, object]:
    assets: dict[str, object] = {}
    for path in (BACKGROUND_OUTPUT, EMPTY_NODE_OUTPUT) + tuple(
        OUTPUT_ROOT / f"{name}.png" for name in ICON_NAMES
    ) + tuple(
        OUTPUT_ROOT / f"{name}.png" for name in HUD_ICON_NAMES
    ):
        image = Image.open(path).convert("RGBA")
        alpha = image.getchannel("A")
        assets[path.name] = {
            "size": list(image.size),
            "mode": image.mode,
            "alpha_extrema": list(alpha.getextrema()),
            "transparent_corners": [
                alpha.getpixel((0, 0)),
                alpha.getpixel((image.width - 1, 0)),
                alpha.getpixel((0, image.height - 1)),
                alpha.getpixel((image.width - 1, image.height - 1)),
            ],
            "visible_rgb_colors": len(_visible_rgb_colors(image)),
            "visible_bbox": alpha.getbbox(),
        }
    return assets


def main() -> None:
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    _build_background()
    palettes = {
        name: _build_icon(
            name,
            ICON_SIZE,
            ICON_SUBJECT_MAX,
            ICON_PALETTE_SIZE,
        )
        for name in ICON_NAMES
    }
    palettes.update(
        {
            name: _build_icon(
                name,
                HUD_ICON_SIZE,
                HUD_ICON_SUBJECT_MAX,
                HUD_ICON_PALETTE_SIZE,
            )
            for name in HUD_ICON_NAMES
        }
    )
    _build_empty_node()

    report = {
        "icon_palettes": {
            name: ["#%02X%02X%02X" % color for color in palette]
            for name, palette in palettes.items()
        },
        "assets": _asset_report(),
    }
    report_path = SOURCE_ROOT / "processing_report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
