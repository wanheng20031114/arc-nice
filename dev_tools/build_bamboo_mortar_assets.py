#!/usr/bin/env python3
"""Build the Bamboo Mortar's strict native-64 pixel asset family.

The user-approved 64x64 transparent anchor is the sole production authority for
all stable body pixels.  The high-resolution imagegen images are retained only
as visual/provenance references; a normal build must never re-sample them or
overwrite the approved anchor.

Every animation frame copies that anchor byte-for-byte before changing only the
upper storage-tube contents and muzzle during charge/fire.  The shell and small
square HDR status lamp remain separate Godot nodes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from io import BytesIO
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "dev_assets/source_images/plant_defense/bamboo_mortar"
OUTPUT_ROOT = ROOT / "resources/texture/plant_defense/bamboo_mortar"

REFERENCE_PATH = SOURCE_ROOT / "bamboo_mortar_reference.png"
NATIVE_IMAGEGEN_PATH = (
    SOURCE_ROOT / "bamboo_mortar_native64_imagegen_magenta.png"
)
APPROVED_IMAGEGEN_PATH = (
    SOURCE_ROOT
    / "bamboo_mortar_approved_rope_tail_imagegen_magenta.png"
)
ANCHOR_PATH = SOURCE_ROOT / "bamboo_mortar_anchor_alpha.png"
CHARGE_REFERENCE_PATH = (
    SOURCE_ROOT / "bamboo_mortar_charge_imagegen_magenta.png"
)
FIRE_REFERENCE_PATH = (
    SOURCE_ROOT / "bamboo_mortar_fire_burst_imagegen_magenta.png"
)
AUDIT_PATH = SOURCE_ROOT / "bamboo_mortar_asset_audit.json"

CANVAS_SIZE = (64, 64)
NATIVE_LOGICAL_SIZE = (64, 64)
EXPECTED_NATIVE_SOURCE_SIZE = (1254, 1254)
EXPECTED_BODY_BBOX = (4, 4, 59, 62)
MAX_BODY_SIZE = (60, 60)
TRANSPARENT = (0, 0, 0, 0)
EXPECTED_APPROVED_REFERENCE_SHA256 = (
    "5ef40a0a56b8b76b3d466bf23226271234715573c13c832813e1d559019c3412"
)
EXPECTED_APPROVED_ANCHOR_RGBA_SHA256 = (
    "98b4dd99cedea45fa919268c992e59c80199542eb5b3edcc1db4df1f10fc5b24"
)

# Twelve base colors are enough to retain the reference's bamboo, leaf, rope,
# rim, bomb, and bore hierarchy without the source image's thousands of nearly
# identical greens.
OUTLINE = (7, 25, 9, 255)
DEEP_GREEN = (14, 52, 22, 255)
DARK_GREEN = (22, 83, 31, 255)
MID_GREEN = (43, 125, 39, 255)
GREEN = (91, 169, 45, 255)
LIGHT_GREEN = (151, 205, 52, 255)
LIME_HIGHLIGHT = (202, 227, 73, 255)
DARK_BROWN = (66, 48, 15, 255)
BROWN = (126, 92, 28, 255)
GOLD = (190, 151, 48, 255)
RIM = (241, 203, 99, 255)
RIM_HIGHLIGHT = (255, 226, 132, 255)

BASE_PALETTE = (
    OUTLINE,
    DEEP_GREEN,
    DARK_GREEN,
    MID_GREEN,
    GREEN,
    LIGHT_GREEN,
    LIME_HIGHLIGHT,
    DARK_BROWN,
    BROWN,
    GOLD,
    RIM,
    RIM_HIGHLIGHT,
)

EMBER = (174, 57, 16, 255)
ORANGE = (227, 86, 15, 255)
AMBER = (255, 146, 24, 255)
PALE_FLAME = (255, 217, 76, 255)
WHITE_HOT = (255, 244, 184, 255)
SMOKE_DARK = (70, 66, 57, 255)
SMOKE_LIGHT = (127, 119, 98, 255)
HEAT_PALETTE = (EMBER, ORANGE, AMBER, PALE_FLAME, WHITE_HOT)

UPPER_STORAGE_RECT = (15, 15, 26, 27)
MUZZLE_RECT = (31, 3, 54, 20)
FIRE_EFFECT_RECT = (31, 0, 64, 22)
STATUS_LIGHT_REGION = (28, 39, 36, 47)
APPROVED_ROPE_TAIL_PIXELS = {
    (41, 44): RIM,
    (42, 44): RIM,
    (41, 45): GOLD,
    (42, 45): GOLD,
    (43, 45): RIM,
    (44, 45): GOLD,
    (43, 46): DARK_BROWN,
    (44, 46): DARK_BROWN,
}


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
                (red, green, blue, 255)
                if alpha >= 128
                else TRANSPARENT
            )
    return cleaned


def _is_chroma(pixel: tuple[int, int, int, int]) -> bool:
    """Reject magenta key/outline remnants without eating warm brown pixels."""
    red, green, blue, alpha = pixel
    return (
        alpha >= 128
        and red >= 70
        and blue >= 60
        and red > green * 1.35
        and blue > green * 1.12
    )


def _nearest_palette_index(
    rgb: tuple[int, int, int],
    palette: tuple[tuple[int, int, int, int], ...],
) -> int:
    red, green, blue = rgb
    return min(
        range(len(palette)),
        key=lambda index: (
            (red - palette[index][0]) ** 2 * 2
            + (green - palette[index][1]) ** 2 * 3
            + (blue - palette[index][2]) ** 2
        ),
    )


def _decode_native64_anchor(source: Image.Image) -> Image.Image:
    """Fold the imagegen-authored 64-cell lattice without resizing geometry."""
    if source.size != EXPECTED_NATIVE_SOURCE_SIZE:
        raise RuntimeError(
            "Native imagegen source must remain "
            f"{EXPECTED_NATIVE_SOURCE_SIZE[0]}x"
            f"{EXPECTED_NATIVE_SOURCE_SIZE[1]}, got "
            f"{source.width}x{source.height}"
        )
    result = Image.new("RGBA", NATIVE_LOGICAL_SIZE, TRANSPARENT)
    pixels = result.load()
    for logical_y in range(NATIVE_LOGICAL_SIZE[1]):
        source_y = min(
            source.height - 1,
            int((logical_y + 0.5) * source.height / NATIVE_LOGICAL_SIZE[1]),
        )
        for logical_x in range(NATIVE_LOGICAL_SIZE[0]):
            source_x = min(
                source.width - 1,
                int(
                    (logical_x + 0.5)
                    * source.width
                    / NATIVE_LOGICAL_SIZE[0]
                ),
            )
            source_pixel = source.getpixel((source_x, source_y))
            if source_pixel[3] < 128 or _is_chroma(source_pixel):
                continue
            palette_index = _nearest_palette_index(
                source_pixel[:3],
                BASE_PALETTE,
            )
            pixels[logical_x, logical_y] = BASE_PALETTE[palette_index]
    return _clean(result)


def _empty_upper_storage_tube(image: Image.Image) -> None:
    pixels = image.load()
    # Remove only the raised bomb and rebuild a compact rim/cavity attached to
    # the existing tube body.  The lower decorative bomb is left untouched.
    for y in range(15, 25):
        for x in range(15, 26):
            pixels[x, y] = TRANSPARENT
    opening = {
        (19, 19): OUTLINE,
        (20, 19): OUTLINE,
        (21, 19): OUTLINE,
        (22, 19): OUTLINE,
        (17, 20): OUTLINE,
        (18, 20): RIM,
        (19, 20): BROWN,
        (20, 20): DARK_BROWN,
        (21, 20): DARK_BROWN,
        (22, 20): BROWN,
        (23, 20): RIM,
        (24, 20): OUTLINE,
        (16, 21): OUTLINE,
        (17, 21): RIM_HIGHLIGHT,
        (18, 21): BROWN,
        (19, 21): DARK_BROWN,
        (20, 21): DARK_BROWN,
        (21, 21): DARK_BROWN,
        (22, 21): BROWN,
        (23, 21): RIM,
        (24, 21): OUTLINE,
        (16, 22): OUTLINE,
        (17, 22): RIM,
        (18, 22): DARK_BROWN,
        (19, 22): DARK_BROWN,
        (20, 22): DARK_BROWN,
        (21, 22): DARK_BROWN,
        (22, 22): DARK_BROWN,
        (23, 22): RIM,
        (24, 22): OUTLINE,
        (17, 23): OUTLINE,
        (18, 23): RIM_HIGHLIGHT,
        (19, 23): RIM,
        (20, 23): RIM,
        (21, 23): RIM,
        (22, 23): RIM,
        (23, 23): OUTLINE,
        (17, 24): OUTLINE,
        (18, 24): GREEN,
        (19, 24): GREEN,
        (20, 24): MID_GREEN,
        (21, 24): MID_GREEN,
        (22, 24): DARK_GREEN,
        (23, 24): OUTLINE,
    }
    for point, color in opening.items():
        pixels[point] = color


def _muzzle_interior_points(anchor: Image.Image) -> list[tuple[int, int]]:
    points: list[tuple[int, int]] = []
    for y in range(MUZZLE_RECT[1], MUZZLE_RECT[3]):
        for x in range(MUZZLE_RECT[0], MUZZLE_RECT[2]):
            if anchor.getpixel((x, y)) not in (DARK_BROWN, BROWN):
                continue
            normalized = (
                ((x - 43.0) / 10.5) ** 2
                + ((y - 9.5) / 7.5) ** 2
            )
            if normalized <= 1.0:
                points.append((x, y))
    if len(points) < 40:
        raise RuntimeError(
            "Reconstructed muzzle interior is unexpectedly small: "
            f"{len(points)} texels"
        )
    return sorted(
        points,
        key=lambda point: (
            (point[0] - 47) ** 2 + (point[1] - 8) ** 2,
            point[1],
            point[0],
        ),
    )


def _heat_muzzle(
    image: Image.Image,
    anchor: Image.Image,
    stage: int,
) -> None:
    if not 0 <= stage <= 7:
        raise ValueError(f"Heat stage must be 0..7, got {stage}")
    points = _muzzle_interior_points(anchor)
    heated_count = max(
        1,
        math.ceil(len(points) * (stage + 1) / 8.0),
    )
    pixels = image.load()
    for order, point in enumerate(points):
        if order >= heated_count:
            continue
        relative = order / max(1, heated_count - 1)
        intensity = min(
            4,
            max(0, stage // 2 + (1 if relative < 0.28 else 0)),
        )
        pixels[point] = HEAT_PALETTE[intensity]
    if stage == 7:
        for point in ((46, 7), (47, 7), (46, 8), (47, 8), (48, 8)):
            if point in points:
                pixels[point] = WHITE_HOT


def _build_idle(anchor: Image.Image) -> Image.Image:
    return _clean(anchor.copy())


def _build_charge_frames(anchor: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []
    for stage in range(8):
        frame = anchor.copy()
        _empty_upper_storage_tube(frame)
        _heat_muzzle(frame, anchor, stage)
        frames.append(_clean(frame))
    return frames


def _paint_points(
    image: Image.Image,
    points: dict[tuple[int, int], tuple[int, int, int, int]],
) -> None:
    pixels = image.load()
    for (x, y), color in points.items():
        if 0 <= x < image.width and 0 <= y < image.height:
            pixels[x, y] = color


def _paint_logical_cells(
    image: Image.Image,
    cells: dict[tuple[int, int], tuple[int, int, int, int]],
) -> None:
    """Expand one 32x32 logical pixel into an aligned native 2x2 block."""
    points: dict[tuple[int, int], tuple[int, int, int, int]] = {}
    for (logical_x, logical_y), color in cells.items():
        native_x = logical_x * 2
        native_y = logical_y * 2
        for offset_y in range(2):
            for offset_x in range(2):
                points[(native_x + offset_x, native_y + offset_y)] = color
    _paint_points(image, points)


def _paint_ignition_star(image: Image.Image) -> None:
    """Paint a compact pressure-star that survives the in-game 0.5 scale."""
    _paint_logical_cells(
        image,
        {
            (25, 3): WHITE_HOT,
            (25, 4): WHITE_HOT,
            (24, 3): PALE_FLAME,
            (24, 4): PALE_FLAME,
            (26, 3): PALE_FLAME,
            (26, 4): PALE_FLAME,
            (25, 2): PALE_FLAME,
            (25, 5): PALE_FLAME,
            (27, 2): ORANGE,
            (27, 5): ORANGE,
            (28, 3): AMBER,
            (28, 4): AMBER,
            (29, 1): EMBER,
        },
    )


def _paint_main_blast(image: Image.Image) -> None:
    """Paint an inset, connected white-hot jet on the logical 32px grid."""
    rows = {
        1: (29, 30),
        2: (27, 30),
        3: (26, 30),
        4: (25, 29),
        5: (24, 28),
        6: (23, 27),
        7: (23, 26),
    }
    cells: dict[tuple[int, int], tuple[int, int, int, int]] = {}
    for y, (left, right) in rows.items():
        for x in range(left, right + 1):
            edge_distance = min(x - left, right - x)
            if edge_distance >= 2:
                color = WHITE_HOT
            elif edge_distance >= 1:
                color = PALE_FLAME
            elif x == right:
                color = EMBER
            else:
                color = ORANGE
            cells[(x, y)] = color
    cells.update(
        {
            (30, 6): PALE_FLAME,
            (28, 8): ORANGE,
            (26, 9): EMBER,
        }
    )
    _paint_logical_cells(image, cells)


def _paint_smoke_ring(image: Image.Image) -> None:
    """Paint a 2-native-pixel hollow ring that reads at 0.5 scale."""
    ring_rows = {
        1: (27, 29),
        2: (26, 26, 30, 30),
        3: (25, 25, 30, 30),
        4: (25, 25, 30, 30),
        5: (26, 26, 30, 30),
        6: (27, 29),
    }
    cells: dict[tuple[int, int], tuple[int, int, int, int]] = {}
    for y, spans in ring_rows.items():
        for span_index in range(0, len(spans), 2):
            left = spans[span_index]
            right = spans[span_index + 1]
            for x in range(left, right + 1):
                cells[(x, y)] = (
                    SMOKE_LIGHT
                    if (x + y) % 3 != 0
                    else SMOKE_DARK
                )
    cells.update(
        {
            (29, 7): ORANGE,
            (26, 8): EMBER,
        }
    )
    _paint_logical_cells(image, cells)


def _paint_fading_smoke(image: Image.Image) -> None:
    """Paint two aligned smoke clusters instead of subpixel-sized noise."""
    _paint_logical_cells(
        image,
        {
            (26, 3): SMOKE_DARK,
            (27, 2): SMOKE_LIGHT,
            (27, 3): SMOKE_LIGHT,
            (26, 4): SMOKE_DARK,
            (29, 1): SMOKE_DARK,
            (30, 1): SMOKE_LIGHT,
            (26, 6): EMBER,
        },
    )


def _build_fire_frames(anchor: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []

    ignition = anchor.copy()
    _empty_upper_storage_tube(ignition)
    _heat_muzzle(ignition, anchor, 7)
    _paint_ignition_star(ignition)
    frames.append(_clean(ignition))

    blast = anchor.copy()
    _empty_upper_storage_tube(blast)
    _heat_muzzle(blast, anchor, 7)
    _paint_main_blast(blast)
    frames.append(_clean(blast))

    pressure_ring = anchor.copy()
    _empty_upper_storage_tube(pressure_ring)
    _heat_muzzle(pressure_ring, anchor, 4)
    _paint_smoke_ring(pressure_ring)
    frames.append(_clean(pressure_ring))

    smoke = anchor.copy()
    _empty_upper_storage_tube(smoke)
    _heat_muzzle(smoke, anchor, 1)
    _paint_fading_smoke(smoke)
    frames.append(_clean(smoke))
    return frames


def _visible_colors(
    image: Image.Image,
) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for red, green, blue, alpha in image.getdata()
        if alpha == 255
    }


def _inside_rect(
    x: int,
    y: int,
    rect: tuple[int, int, int, int],
) -> bool:
    left, top, right, bottom = rect
    return left <= x < right and top <= y < bottom


def _assert_clean(label: str, image: Image.Image) -> None:
    alpha_values = {pixel[3] for pixel in image.getdata()}
    if not alpha_values.issubset({0, 255}):
        raise RuntimeError(f"{label} has non-binary alpha")
    if any(
        alpha == 0 and (red != 0 or green != 0 or blue != 0)
        for red, green, blue, alpha in image.getdata()
    ):
        raise RuntimeError(f"{label} has dirty transparent RGB")
    if any(
        _is_chroma((red, green, blue, alpha))
        for red, green, blue, alpha in image.getdata()
    ):
        raise RuntimeError(f"{label} retains magenta chroma pixels")


def _image_sha256(image: Image.Image) -> str:
    return hashlib.sha256(_encode_png(image)).hexdigest()


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _validate_approved_anchor(
    native_imagegen_source: Image.Image,
    anchor: Image.Image,
) -> None:
    """Lock the approved pixels and prove the rope-tail edit stayed local."""
    _assert_clean("approved_anchor", anchor)
    anchor_rgba_sha256 = _rgba_sha256(anchor)
    if anchor_rgba_sha256 != EXPECTED_APPROVED_ANCHOR_RGBA_SHA256:
        raise RuntimeError(
            "Approved Bamboo Mortar anchor pixels changed: "
            f"{anchor_rgba_sha256}"
        )

    unedited_baseline = _decode_native64_anchor(native_imagegen_source)
    changed_points = {
        (x, y)
        for y in range(CANVAS_SIZE[1])
        for x in range(CANVAS_SIZE[0])
        if anchor.getpixel((x, y)) != unedited_baseline.getpixel((x, y))
    }
    expected_points = set(APPROVED_ROPE_TAIL_PIXELS)
    if changed_points != expected_points:
        raise RuntimeError(
            "Approved anchor must differ from the clean baseline at exactly "
            f"the eight rope-tail pixels; got {sorted(changed_points)}"
        )
    for point, expected_color in APPROVED_ROPE_TAIL_PIXELS.items():
        if anchor.getpixel(point) != expected_color:
            raise RuntimeError(
                "Approved rope-tail pixel changed: "
                f"point={point} actual={anchor.getpixel(point)}"
            )


def _validate(
    reference: Image.Image,
    native_imagegen_source: Image.Image,
    approved_imagegen_source: Image.Image,
    anchor: Image.Image,
    idle: Image.Image,
    charge_frames: list[Image.Image],
    fire_frames: list[Image.Image],
) -> dict:
    if reference.size != (1254, 1254):
        raise RuntimeError(
            f"Design reference must be 1254x1254, got {reference.size}"
        )
    if native_imagegen_source.size != EXPECTED_NATIVE_SOURCE_SIZE:
        raise RuntimeError(
            "Native imagegen source dimensions changed: "
            f"{native_imagegen_source.size}"
        )
    if approved_imagegen_source.size != EXPECTED_NATIVE_SOURCE_SIZE:
        raise RuntimeError(
            "Approved rope-tail imagegen reference dimensions changed: "
            f"{approved_imagegen_source.size}"
        )
    approved_reference_sha256 = hashlib.sha256(
        APPROVED_IMAGEGEN_PATH.read_bytes()
    ).hexdigest()
    if approved_reference_sha256 != EXPECTED_APPROVED_REFERENCE_SHA256:
        raise RuntimeError(
            "Approved rope-tail imagegen reference changed: "
            f"{approved_reference_sha256}"
        )
    if anchor.size != CANVAS_SIZE:
        raise RuntimeError(f"Anchor must be 64x64, got {anchor.size}")
    _validate_approved_anchor(native_imagegen_source, anchor)
    if anchor.getchannel("A").getbbox() != EXPECTED_BODY_BBOX:
        raise RuntimeError(
            "Native-64 anchor bbox changed: "
            f"{anchor.getchannel('A').getbbox()}"
        )
    body_width = EXPECTED_BODY_BBOX[2] - EXPECTED_BODY_BBOX[0]
    body_height = EXPECTED_BODY_BBOX[3] - EXPECTED_BODY_BBOX[1]
    if body_width > MAX_BODY_SIZE[0] or body_height > MAX_BODY_SIZE[1]:
        raise RuntimeError(
            "Bamboo Mortar native composition exceeds the 60x60 body budget"
        )
    if len(charge_frames) != 8 or len(fire_frames) != 4:
        raise RuntimeError("Expected exactly 8 charge and 4 fire frames")

    body_frames = [idle, *charge_frames, *fire_frames]
    for index, frame in enumerate(body_frames):
        if frame.size != CANVAS_SIZE:
            raise RuntimeError(f"Body frame {index} is not 64x64")
        _assert_clean(f"body_{index}", frame)
        if len(_visible_colors(frame)) > 20:
            raise RuntimeError(
                f"Body frame {index} exceeds the 20-color limit"
            )

    anchor_pixels = anchor.load()
    for frame_index, frame in enumerate(charge_frames):
        frame_pixels = frame.load()
        for y in range(64):
            for x in range(64):
                if (
                    _inside_rect(x, y, UPPER_STORAGE_RECT)
                    or _inside_rect(x, y, MUZZLE_RECT)
                ):
                    continue
                if frame_pixels[x, y] != anchor_pixels[x, y]:
                    raise RuntimeError(
                        "Charge frame changed a stable body pixel: "
                        f"frame={frame_index} point=({x},{y})"
                    )

    for frame_index, frame in enumerate(fire_frames):
        frame_pixels = frame.load()
        for y in range(64):
            for x in range(64):
                if (
                    _inside_rect(x, y, UPPER_STORAGE_RECT)
                    or _inside_rect(x, y, FIRE_EFFECT_RECT)
                ):
                    continue
                if frame_pixels[x, y] != anchor_pixels[x, y]:
                    raise RuntimeError(
                        "Fire frame changed a stable body pixel: "
                        f"frame={frame_index} point=({x},{y})"
                    )

    if len({_image_sha256(frame) for frame in charge_frames}) != 8:
        raise RuntimeError("All eight charge frames must be visually unique")
    if len({_image_sha256(frame) for frame in fire_frames}) != 4:
        raise RuntimeError("All four fire frames must be visually unique")
    if not all(
        frame.getpixel((20, 17)) == TRANSPARENT
        and frame.getpixel((20, 21)) == DARK_BROWN
        for frame in (*charge_frames, *fire_frames)
    ):
        raise RuntimeError(
            "Upper storage tube must be empty throughout charge/fire"
        )
    if not all(
        frame.getpixel((14, 29)) == idle.getpixel((14, 29))
        for frame in (*charge_frames, *fire_frames)
    ):
        raise RuntimeError("Lower decorative bomb must remain loaded")

    fire_effect_changed_pixel_counts: list[int] = []
    fire_effect_new_pixel_counts: list[int] = []
    for frame in fire_frames:
        changed_count = 0
        new_pixel_count = 0
        for y in range(FIRE_EFFECT_RECT[1], FIRE_EFFECT_RECT[3]):
            for x in range(FIRE_EFFECT_RECT[0], FIRE_EFFECT_RECT[2]):
                frame_pixel = frame.getpixel((x, y))
                anchor_pixel = anchor.getpixel((x, y))
                if frame_pixel != anchor_pixel:
                    changed_count += 1
                if frame_pixel[3] > 0 and anchor_pixel[3] == 0:
                    new_pixel_count += 1
        fire_effect_changed_pixel_counts.append(changed_count)
        fire_effect_new_pixel_counts.append(new_pixel_count)
    if not (
        fire_effect_new_pixel_counts[0] >= 24
        and fire_effect_new_pixel_counts[1] >= 96
        and fire_effect_new_pixel_counts[1]
        > fire_effect_new_pixel_counts[0] * 2
        and 48 <= fire_effect_new_pixel_counts[2] <= 80
        and fire_effect_new_pixel_counts[3] >= 16
        and fire_effect_new_pixel_counts[3]
        < fire_effect_new_pixel_counts[2]
        and all(
            fire_frames[2].getpixel(point) == TRANSPARENT
            for point in ((56, 6), (57, 6), (56, 7), (57, 7))
        )
        and all(
            frame.getchannel("A").getbbox()[1] >= 2
            and frame.getchannel("A").getbbox()[2] <= 62
            for frame in fire_frames
        )
    ):
        raise RuntimeError(
            "Fire sequence must read as ignition, dominant blast, hollow "
            "pressure ring, then fading smoke without edge clipping; got "
            "new-pixel counts "
            f"{fire_effect_new_pixel_counts}"
        )

    # Nothing in the front-center status-light area may animate in the body
    # textures.  The square mask is composited by its own Godot node.
    for frame in (*charge_frames, *fire_frames):
        for y in range(STATUS_LIGHT_REGION[1], STATUS_LIGHT_REGION[3]):
            for x in range(STATUS_LIGHT_REGION[0], STATUS_LIGHT_REGION[2]):
                if frame.getpixel((x, y)) != idle.getpixel((x, y)):
                    raise RuntimeError(
                        "Status-light pixels were baked into a body frame"
                    )

    return {
        "schema_version": 6,
        "design_reference_sha256": hashlib.sha256(
            REFERENCE_PATH.read_bytes()
        ).hexdigest(),
        "approved_rope_tail_imagegen_reference_sha256": (
            approved_reference_sha256
        ),
        "native64_imagegen_source_sha256": hashlib.sha256(
            NATIVE_IMAGEGEN_PATH.read_bytes()
        ).hexdigest(),
        "approved_anchor_png_sha256": hashlib.sha256(
            ANCHOR_PATH.read_bytes()
        ).hexdigest(),
        "approved_anchor_rgba_sha256": _rgba_sha256(anchor),
        "imagegen_charge_reference_sha256": hashlib.sha256(
            CHARGE_REFERENCE_PATH.read_bytes()
        ).hexdigest(),
        "imagegen_fire_reference_sha256": hashlib.sha256(
            FIRE_REFERENCE_PATH.read_bytes()
        ).hexdigest(),
        "pixel_grid_analyzer": {
            "command": (
                "python dev_tools/pixel_grid_analyzer.py "
                "bamboo_mortar_native64_imagegen_magenta.png --json"
            ),
            "detection_mode": "approximate",
            "grid_cell_width": 19.55,
            "grid_cell_height": 19.5,
            "confidence": 0.959,
            "logical_canvas_size": list(NATIVE_LOGICAL_SIZE),
        },
        "native64_baseline_decode": {
            "method": (
                "One center sample from each imagegen-authored logical cell; "
                "used only to audit the eight-pixel rope-tail delta."
            ),
            "source_size": list(native_imagegen_source.size),
            "logical_source_size": list(NATIVE_LOGICAL_SIZE),
            "canvas_size": list(CANVAS_SIZE),
            "geometric_resize": False,
            "merged_source_cells": False,
            "base_palette_size": len(BASE_PALETTE),
        },
        "approved_rope_tail_delta": {
            "changed_pixel_count": len(APPROVED_ROPE_TAIL_PIXELS),
            "highlight_points": [[41, 44], [42, 44], [43, 45]],
            "gold_points": [[44, 45], [41, 45], [42, 45]],
            "shadow_points": [[43, 46], [44, 46]],
        },
        "building_frame_visible_colors": [
            len(_visible_colors(frame)) for frame in body_frames
        ],
        "building_subject_bboxes": [
            list(frame.getchannel("A").getbbox() or ())
            for frame in body_frames
        ],
        "charge_frame_hashes": [
            _image_sha256(frame) for frame in charge_frames
        ],
        "fire_frame_hashes": [
            _image_sha256(frame) for frame in fire_frames
        ],
        "fire_effect_changed_pixel_counts": (
            fire_effect_changed_pixel_counts
        ),
        "fire_effect_new_pixel_counts": fire_effect_new_pixel_counts,
        "fire_sequence": [
            "compact_ignition_star",
            "dominant_white_hot_blast",
            "hollow_pressure_smoke_ring",
            "fading_separated_smoke",
        ],
        "body_width": body_width,
        "body_height": body_height,
        "upper_storage_empty_during_charge_and_fire": True,
        "lower_decorative_bomb_preserved": True,
        "status_light_baked_into_body_frames": False,
        "status_light_rendering": (
            "Independent small square Godot node with HDR/shader emission; "
            "this builder emits no status-light bitmap."
        ),
        "shell_baked_into_fire_frames": False,
        "binary_alpha": True,
        "transparent_rgb_clean": True,
        "magenta_pixels_removed": True,
        "imagegen_role": (
            "The approved high-resolution image is retained as visual "
            "provenance. The approved transparent 64x64 anchor is the sole "
            "production authority. Charge/fire sheets supply motion language; "
            "the enhanced fire reference contributes only the four-stage "
            "eruption rhythm, and only storage/muzzle regions change."
        ),
        "production_anchor_read_only": True,
    }


def _encode_png(image: Image.Image) -> bytes:
    buffer = BytesIO()
    image.save(buffer, format="PNG", optimize=False)
    return buffer.getvalue()


def _managed_outputs(
    idle: Image.Image,
    charge_frames: list[Image.Image],
    fire_frames: list[Image.Image],
    audit: dict,
) -> dict[Path, bytes]:
    outputs: dict[Path, bytes] = {
        OUTPUT_ROOT / "idle.png": _encode_png(idle),
        AUDIT_PATH: (
            json.dumps(audit, ensure_ascii=False, indent=2) + "\n"
        ).encode("utf-8"),
    }
    for index, frame in enumerate(charge_frames):
        outputs[OUTPUT_ROOT / f"charge_{index}.png"] = _encode_png(frame)
    for index, frame in enumerate(fire_frames):
        outputs[OUTPUT_ROOT / f"fire_{index}.png"] = _encode_png(frame)
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Verify that every managed output matches a fresh rebuild.",
    )
    args = parser.parse_args()

    reference = _load_rgba(REFERENCE_PATH)
    native_imagegen_source = _load_rgba(NATIVE_IMAGEGEN_PATH)
    approved_imagegen_source = _load_rgba(APPROVED_IMAGEGEN_PATH)
    # Their hashes establish the exact imagegen animation references used to
    # author the local storage/muzzle changes without replacing stable pixels.
    _load_rgba(CHARGE_REFERENCE_PATH)
    _load_rgba(FIRE_REFERENCE_PATH)

    # This is an approved input, never a managed output.  Validate before any
    # cleanup so dirty transparency or softened alpha cannot be silently fixed.
    anchor = _load_rgba(ANCHOR_PATH)
    idle = _build_idle(anchor)
    charge_frames = _build_charge_frames(anchor)
    fire_frames = _build_fire_frames(anchor)
    audit = _validate(
        reference,
        native_imagegen_source,
        approved_imagegen_source,
        anchor,
        idle,
        charge_frames,
        fire_frames,
    )
    outputs = _managed_outputs(
        idle,
        charge_frames,
        fire_frames,
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
