#!/usr/bin/env python3
"""Build the strict native-pixel Bamboo Mortar asset family.

The approved 64x64 anchor remains immutable outside a few declared gameplay
regions.  Imagegen supplies the animation language for muzzle heat and the
eight-stage explosion; this processor converts that direction into a shared,
auditable logical grid with binary alpha and fixed palettes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = (
    ROOT / "dev_assets/source_images/plant_defense/bamboo_mortar"
)
OUTPUT_ROOT = ROOT / "resources/texture/plant_defense/bamboo_mortar"
ANCHOR_PATH = SOURCE_ROOT / "bamboo_mortar_anchor_alpha.png"
CHARGE_SOURCE_PATH = (
    SOURCE_ROOT / "bamboo_mortar_charge_imagegen_magenta.png"
)
EXPLOSION_SOURCE_PATH = (
    SOURCE_ROOT / "bamboo_mortar_explosion_imagegen_magenta.png"
)
AUDIT_PATH = SOURCE_ROOT / "bamboo_mortar_asset_audit.json"

TRANSPARENT = (0, 0, 0, 0)
OUTLINE = (7, 25, 9, 255)
DEEP_GREEN = (15, 60, 28, 255)
MID_GREEN = (26, 96, 37, 255)
GREEN = (52, 134, 42, 255)
LIGHT_GREEN = (112, 183, 45, 255)
HIGHLIGHT_GREEN = (184, 219, 56, 255)
DARK_BROWN = (75, 58, 18, 255)
BROWN = (154, 114, 36, 255)
RIM = (241, 203, 99, 255)
GOLD = (212, 162, 60, 255)

WARM_COLORS = (
    (176, 70, 18, 255),
    (222, 94, 18, 255),
    (246, 145, 28, 255),
    (255, 215, 82, 255),
)
EXPLOSION_PALETTE = (
    (53, 31, 19),
    (93, 53, 28),
    (139, 86, 43),
    (189, 130, 71),
    (205, 70, 18),
    (241, 103, 17),
    (255, 153, 24),
    (255, 204, 38),
    (255, 240, 135),
    (113, 174, 48),
    (179, 218, 74),
)

CHARGE_MUTABLE_RECTS = (
    (16, 16, 27, 25),  # upper storage tube / loaded bomb
    (10, 24, 22, 35),  # lower storage tube / decorative bomb
    (32, 1, 54, 18),  # real muzzle interior
    (28, 37, 37, 46),  # front-center indicator
)


def _inside_mutable_region(x: int, y: int) -> bool:
    return any(
        left <= x < right and top <= y < bottom
        for left, top, right, bottom in CHARGE_MUTABLE_RECTS
    )


def _load_rgba(path: Path) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    with Image.open(path) as source:
        return source.convert("RGBA")


def _clean(image: Image.Image) -> Image.Image:
    cleaned = image.convert("RGBA")
    pixels = cleaned.load()
    for y in range(cleaned.height):
        for x in range(cleaned.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (
                (red, green, blue, 255) if alpha >= 128 else TRANSPARENT
            )
    return cleaned


def _paint_bomb(
    image: Image.Image,
    center: tuple[int, int],
) -> None:
    """Paint one compact bomb inside an existing bamboo storage rim."""
    cx, cy = center
    pixels = image.load()
    shape = {
        (-2, -1): OUTLINE,
        (-1, -2): OUTLINE,
        (0, -2): OUTLINE,
        (1, -2): OUTLINE,
        (2, -1): OUTLINE,
        (-3, 0): OUTLINE,
        (3, 0): OUTLINE,
        (-2, 1): OUTLINE,
        (2, 1): OUTLINE,
        (-1, 2): OUTLINE,
        (0, 2): OUTLINE,
        (1, 2): OUTLINE,
        (-2, 0): MID_GREEN,
        (-1, -1): LIGHT_GREEN,
        (0, -1): GREEN,
        (1, -1): GREEN,
        (2, 0): DEEP_GREEN,
        (-1, 0): GREEN,
        (0, 0): GREEN,
        (1, 0): MID_GREEN,
        (-1, 1): MID_GREEN,
        (0, 1): MID_GREEN,
        (1, 1): DEEP_GREEN,
    }
    for (dx, dy), color in shape.items():
        x = cx + dx
        y = cy + dy
        if 0 <= x < image.width and 0 <= y < image.height:
            pixels[x, y] = color


def _empty_upper_storage_tube(image: Image.Image) -> None:
    """Restore a clearly hollow opening where the loaded bomb was stored."""
    pixels = image.load()
    for y, x_min, x_max in (
        (18, 19, 23),
        (19, 18, 24),
        (20, 18, 24),
        (21, 19, 23),
        (22, 20, 22),
    ):
        for x in range(x_min, x_max + 1):
            pixels[x, y] = DARK_BROWN
    pixels[19, 19] = BROWN
    pixels[20, 18] = BROWN


def _paint_indicator(
    image: Image.Image,
    color: tuple[int, int, int, int],
) -> None:
    pixels = image.load()
    for x, y in (
        (31, 40),
        (32, 40),
        (30, 41),
        (31, 41),
        (32, 41),
        (33, 41),
        (31, 42),
        (32, 42),
    ):
        pixels[x, y] = color
    pixels[30, 40] = OUTLINE
    pixels[33, 40] = OUTLINE
    pixels[30, 42] = OUTLINE
    pixels[33, 42] = OUTLINE


def _build_idle(anchor: Image.Image) -> Image.Image:
    idle = anchor.copy()
    _paint_bomb(idle, (21, 20))
    _paint_bomb(idle, (15, 29))
    _paint_indicator(idle, HIGHLIGHT_GREEN)
    return _clean(idle)


def _build_charge_frames(anchor: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []
    interior_colors = {DARK_BROWN, BROWN, GOLD}
    for frame_index in range(8):
        frame = anchor.copy()
        _empty_upper_storage_tube(frame)
        _paint_bomb(frame, (15, 29))

        pixels = frame.load()
        heat_level = min(3, frame_index // 2)
        for y in range(2, 17):
            for x in range(33, 53):
                current = pixels[x, y]
                if current not in interior_colors:
                    continue
                # Preserve a dark inner rim while the central bore becomes
                # brighter, matching the imagegen eight-stage heat direction.
                distance = abs(x - 43) + abs(y - 9)
                local_level = max(0, heat_level - (1 if distance > 9 else 0))
                if current == DARK_BROWN and frame_index < 4:
                    pixels[x, y] = WARM_COLORS[0]
                else:
                    pixels[x, y] = WARM_COLORS[local_level]
        if frame_index >= 6:
            for point in ((43, 8), (44, 8), (42, 9), (43, 9), (44, 9)):
                x, y = point
                if pixels[x, y][3] > 0:
                    pixels[x, y] = WARM_COLORS[3]

        indicator_level = min(3, 1 + frame_index // 3)
        _paint_indicator(frame, WARM_COLORS[indicator_level])
        frames.append(_clean(frame))
    return frames


def _build_glow_mask() -> Image.Image:
    mask = Image.new("RGBA", (64, 64), TRANSPARENT)
    pixels = mask.load()
    for x, y in (
        (31, 40),
        (32, 40),
        (30, 41),
        (31, 41),
        (32, 41),
        (33, 41),
        (31, 42),
        (32, 42),
    ):
        pixels[x, y] = (255, 255, 255, 255)
    return mask


def _is_chroma(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, _alpha = pixel
    return red >= 205 and green <= 105 and blue >= 180


def _nearest_palette_color(
    rgb: tuple[int, int, int],
    palette: tuple[tuple[int, int, int], ...],
) -> tuple[int, int, int]:
    red, green, blue = rgb
    return min(
        palette,
        key=lambda color: (
            (red - color[0]) ** 2
            + (green - color[1]) ** 2
            + (blue - color[2]) ** 2
        ),
    )


def _build_explosion_frames() -> list[Image.Image]:
    sheet = _load_rgba(EXPLOSION_SOURCE_PATH)
    frames: list[Image.Image] = []
    for frame_index in range(8):
        column = frame_index % 4
        row = frame_index // 4
        left = round(column * sheet.width / 4.0)
        right = round((column + 1) * sheet.width / 4.0)
        top = round(row * sheet.height / 2.0)
        bottom = round((row + 1) * sheet.height / 2.0)
        cell = sheet.crop((left, top, right, bottom))
        logical = cell.resize((64, 64), Image.Resampling.NEAREST)
        source_pixels = logical.load()
        result = Image.new("RGBA", (64, 64), TRANSPARENT)
        target_pixels = result.load()
        for y in range(64):
            for x in range(64):
                pixel = source_pixels[x, y]
                if _is_chroma(pixel):
                    continue
                chosen = _nearest_palette_color(
                    pixel[:3],
                    EXPLOSION_PALETTE,
                )
                target_pixels[x, y] = (*chosen, 255)
        frames.append(_clean(result))
    return frames


def _build_shell() -> Image.Image:
    shell = Image.new("RGBA", (12, 12), TRANSPARENT)
    _paint_bomb(shell, (6, 6))
    pixels = shell.load()
    pixels[5, 3] = RIM
    pixels[6, 3] = GOLD
    return _clean(shell)


def _visible_colors(image: Image.Image) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for red, green, blue, alpha in image.getdata()
        if alpha == 255
    }


def _validate(
    anchor: Image.Image,
    idle: Image.Image,
    charge_frames: list[Image.Image],
    explosion_frames: list[Image.Image],
    glow_mask: Image.Image,
    shell: Image.Image,
) -> dict:
    if anchor.size != (64, 64):
        raise RuntimeError(f"Anchor must be 64x64, got {anchor.size}")
    building_frames = [idle, *charge_frames]
    for index, frame in enumerate(building_frames):
        if frame.size != (64, 64):
            raise RuntimeError(f"Building frame {index} is not 64x64")
        alpha_values = {pixel[3] for pixel in frame.getdata()}
        if not alpha_values.issubset({0, 255}):
            raise RuntimeError(f"Building frame {index} has non-binary alpha")
        if len(_visible_colors(frame)) > 14:
            raise RuntimeError(
                f"Building frame {index} exceeds the 14-color limit"
            )
    anchor_pixels = anchor.load()
    for frame_index, frame in enumerate(charge_frames):
        frame_pixels = frame.load()
        for y in range(64):
            for x in range(64):
                if _inside_mutable_region(x, y):
                    continue
                if frame_pixels[x, y] != anchor_pixels[x, y]:
                    raise RuntimeError(
                        "Charge frame changed an immutable anchor pixel: "
                        f"frame={frame_index} point=({x},{y})"
                    )
    for index, frame in enumerate(explosion_frames):
        if frame.size != (64, 64):
            raise RuntimeError(f"Explosion frame {index} is not 64x64")
        if len(_visible_colors(frame)) > 12:
            raise RuntimeError(
                f"Explosion frame {index} exceeds the 12-color limit"
            )
    for label, image in (
        ("glow_mask", glow_mask),
        ("shell", shell),
        *(
            (f"building_{index}", image)
            for index, image in enumerate(building_frames)
        ),
        *(
            (f"explosion_{index}", image)
            for index, image in enumerate(explosion_frames)
        ),
    ):
        if not {pixel[3] for pixel in image.getdata()}.issubset({0, 255}):
            raise RuntimeError(f"{label} has non-binary alpha")
        if any(
            alpha == 0 and (red != 0 or green != 0 or blue != 0)
            for red, green, blue, alpha in image.getdata()
        ):
            raise RuntimeError(f"{label} has dirty transparent RGB")
    return {
        "schema_version": 1,
        "anchor_sha256": hashlib.sha256(ANCHOR_PATH.read_bytes()).hexdigest(),
        "imagegen_charge_sha256": hashlib.sha256(
            CHARGE_SOURCE_PATH.read_bytes()
        ).hexdigest(),
        "imagegen_explosion_sha256": hashlib.sha256(
            EXPLOSION_SOURCE_PATH.read_bytes()
        ).hexdigest(),
        "building_frame_visible_colors": [
            len(_visible_colors(frame)) for frame in building_frames
        ],
        "explosion_frame_visible_colors": [
            len(_visible_colors(frame)) for frame in explosion_frames
        ],
        "building_subject_bboxes": [
            list(frame.getchannel("A").getbbox() or ())
            for frame in building_frames
        ],
        "explosion_subject_bboxes": [
            list(frame.getchannel("A").getbbox() or ())
            for frame in explosion_frames
        ],
        "charge_immutable_pixels_preserved": True,
        "binary_alpha": True,
        "transparent_rgb_clean": True,
        "imagegen_role": (
            "Eight-stage muzzle/indicator heat direction and eight-stage "
            "bamboo-fire-dust explosion source."
        ),
    }


def _encode_png(image: Image.Image, destination: Path) -> bytes:
    from io import BytesIO

    buffer = BytesIO()
    image.save(buffer, format="PNG", optimize=False)
    return buffer.getvalue()


def _managed_outputs(
    idle: Image.Image,
    charge_frames: list[Image.Image],
    explosion_frames: list[Image.Image],
    glow_mask: Image.Image,
    shell: Image.Image,
    audit: dict,
) -> dict[Path, bytes]:
    outputs: dict[Path, bytes] = {
        OUTPUT_ROOT / "idle.png": _encode_png(idle, OUTPUT_ROOT / "idle.png"),
        OUTPUT_ROOT / "glow_mask.png": _encode_png(
            glow_mask,
            OUTPUT_ROOT / "glow_mask.png",
        ),
        OUTPUT_ROOT / "shell.png": _encode_png(
            shell,
            OUTPUT_ROOT / "shell.png",
        ),
        AUDIT_PATH: (
            json.dumps(audit, ensure_ascii=False, indent=2) + "\n"
        ).encode("utf-8"),
    }
    for index, frame in enumerate(charge_frames):
        outputs[OUTPUT_ROOT / f"charge_{index}.png"] = _encode_png(
            frame,
            OUTPUT_ROOT / f"charge_{index}.png",
        )
    for index, frame in enumerate(explosion_frames):
        outputs[OUTPUT_ROOT / f"explosion_{index}.png"] = _encode_png(
            frame,
            OUTPUT_ROOT / f"explosion_{index}.png",
        )
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Verify that every managed output matches a fresh rebuild.",
    )
    args = parser.parse_args()

    anchor = _clean(_load_rgba(ANCHOR_PATH))
    idle = _build_idle(anchor)
    charge_frames = _build_charge_frames(anchor)
    explosion_frames = _build_explosion_frames()
    glow_mask = _build_glow_mask()
    shell = _build_shell()
    audit = _validate(
        anchor,
        idle,
        charge_frames,
        explosion_frames,
        glow_mask,
        shell,
    )
    outputs = _managed_outputs(
        idle,
        charge_frames,
        explosion_frames,
        glow_mask,
        shell,
        audit,
    )

    if args.check_only:
        mismatches = [
            path
            for path, expected in outputs.items()
            if not path.is_file() or path.read_bytes() != expected
        ]
        if mismatches:
            for path in mismatches:
                print(f"OUT_OF_DATE {path.relative_to(ROOT).as_posix()}")
            return 1
        print("BAMBOO_MORTAR_ASSET_BUILD_OK")
        return 0

    for path, payload in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
    print(
        "BAMBOO_MORTAR_ASSET_BUILD_OK "
        f"managed_outputs={len(outputs)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
