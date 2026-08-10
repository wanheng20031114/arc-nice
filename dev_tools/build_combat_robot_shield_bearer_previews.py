#!/usr/bin/env python3
"""Build deterministic, review-only previews for the shield bearer robot.

The approved 32x32 C anchor is the only identity and pixel source.  ImageGen
boards are audited and recorded as motion/shape-language references only;
their pixels are never resized or copied into a candidate frame.

This script intentionally has no runtime-writing mode.  It only writes under
``dev_assets/generated_previews`` and therefore cannot cross the second human
review gate by accident.
"""

from __future__ import annotations

import hashlib
import json
import math
from collections import deque
from pathlib import Path
from typing import Iterable, Sequence

from enemy_asset_report_paths import enemy_asset_report_path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets/source_images/combat_robot_shield_bearer"
PREVIEW_DIR = PROJECT_ROOT / "dev_assets/generated_previews"
ANCHOR_PATH = SOURCE_DIR / "combat_robot_shield_bearer_anchor_c_approved_native32.png"

OUTPUT_PREFIX = "combat_robot_shield_bearer"
REPORT_PATH = enemy_asset_report_path(f"{OUTPUT_PREFIX}_preview_audit.json")
COMPARISON_PATH = PREVIEW_DIR / f"{OUTPUT_PREFIX}_comparison.png"

FRAME_SIZE = 32
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

# The approved visual contract reserves these logical regions.  The shield
# itself is a six-by-eighteen-pixel tower silhouette; the slightly wider arm
# ROI also contains its hand and one-pixel elbow linkage.
SHIELD_BBOX = (24, 8, 30, 26)
SHIELD_ARM_ROI = (20, 7, 30, 26)
LEG_ROI = (7, 22, 24, 28)
LEG_TOP_Y = LEG_ROI[1]
LEG_BOTTOM_Y = LEG_ROI[3]
HIP_LEFT_X = 13
HIP_RIGHT_X = 18

FX_CENTER = (15.5, 15.5)

SOURCE_SPECS: dict[str, tuple[Path, tuple[int, int]]] = {
    "move_m1": (
        SOURCE_DIR / "combat_robot_shield_bearer_move_m1_imagegen.png",
        (4, 2),
    ),
    "move_m2": (
        SOURCE_DIR / "combat_robot_shield_bearer_move_m2_imagegen.png",
        (4, 2),
    ),
    "shield_states_s1": (
        SOURCE_DIR / "combat_robot_shield_bearer_shield_states_s1_imagegen.png",
        (3, 1),
    ),
    "shield_states_s2": (
        SOURCE_DIR / "combat_robot_shield_bearer_shield_states_s2_imagegen.png",
        (3, 1),
    ),
    "death_d1": (
        SOURCE_DIR / "combat_robot_shield_bearer_death_d1_imagegen.png",
        (4, 2),
    ),
    "death_d2": (
        SOURCE_DIR / "combat_robot_shield_bearer_death_d2_imagegen.png",
        (4, 2),
    ),
    "block_b1": (
        SOURCE_DIR / "combat_robot_shield_bearer_block_fx_b1_imagegen.png",
        (3, 1),
    ),
    "block_b2": (
        SOURCE_DIR / "combat_robot_shield_bearer_block_fx_b2_imagegen.png",
        (3, 1),
    ),
    "break_x1": (
        SOURCE_DIR / "combat_robot_shield_bearer_break_fx_x1_imagegen.png",
        (5, 1),
    ),
    "break_x2": (
        SOURCE_DIR / "combat_robot_shield_bearer_break_fx_x2_imagegen.png",
        (5, 1),
    ),
}

ANIMATION_SPECS = {
    "move_m1": (8, 14),
    "move_m2": (8, 14),
    "death_d1": (8, 12),
    "death_d2": (8, 12),
    "block_b1": (3, 24),
    "block_b2": (3, 24),
    "break_x1": (5, 18),
    "break_x2": (5, 18),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _empty(size: tuple[int, int] = (FRAME_SIZE, FRAME_SIZE)) -> Image.Image:
    return Image.new("RGBA", size, TRANSPARENT)


def _normalize_rgba(image: Image.Image) -> Image.Image:
    """Snap to the robot palette and make transparency byte-deterministic."""
    snapped = snap_palette(image.convert("RGBA"))
    pixels = np.asarray(snapped, dtype=np.uint8).copy()
    visible = pixels[:, :, 3] >= 128
    pixels[:, :, 3] = np.where(visible, 255, 0).astype(np.uint8)
    pixels[~visible, :3] = 0
    return Image.fromarray(pixels, mode="RGBA")


def _bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Unexpected empty frame")
    return bbox


def _load_anchor() -> Image.Image:
    if not ANCHOR_PATH.is_file():
        raise FileNotFoundError(
            f"Approved C anchor is not ready: {ANCHOR_PATH.relative_to(PROJECT_ROOT)}"
        )
    anchor = _normalize_rgba(Image.open(ANCHOR_PATH))
    if anchor.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"Approved anchor must be 32x32, got {anchor.size}")
    bbox = _bbox(anchor)
    if bbox[2] - bbox[0] > MAX_VISIBLE_SIZE or bbox[3] - bbox[1] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"Approved anchor bbox {bbox} exceeds 28x28")
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"Approved anchor bbox {bbox} misses baseline y=28")
    shield_alpha = anchor.getchannel("A").crop(SHIELD_BBOX)
    if shield_alpha.getbbox() is None:
        raise AssertionError(f"Approved anchor has no shield pixels in {SHIELD_BBOX}")
    return anchor


def _clear_rect(image: Image.Image, rect: tuple[int, int, int, int]) -> Image.Image:
    result = image.copy()
    result.paste(TRANSPARENT, rect)
    return result


def _fixed_upper(anchor: Image.Image) -> Image.Image:
    """Remove only the authored leg ROI; the low shield remains untouched."""
    return _clear_rect(anchor, LEG_ROI)


def _draw_leg(
    layer: Image.Image,
    points: Sequence[tuple[int, int]],
    foot: tuple[int, int, int],
    front: bool,
) -> None:
    outline = PALETTE[0] if front else PALETTE[1]
    joint = PALETTE[4] if front else PALETTE[2]
    fill = PALETTE[5] if front else PALETTE[3]
    draw = ImageDraw.Draw(layer)
    draw.line(tuple(points), fill=outline, width=1)
    for point in points[1:-1]:
        draw.point(point, fill=joint)
    left, right, bottom_y = foot
    draw.rectangle((left, bottom_y - 1, right, bottom_y), fill=outline)
    if right - left >= 2:
        draw.line((left + 1, bottom_y - 1, right - 1, bottom_y - 1), fill=fill)


def _make_leg_layer(
    left: tuple[Sequence[tuple[int, int]], tuple[int, int, int]],
    right: tuple[Sequence[tuple[int, int]], tuple[int, int, int]],
) -> Image.Image:
    layer = _empty()
    _draw_leg(layer, left[0], left[1], front=False)
    _draw_leg(layer, right[0], right[1], front=True)
    return _normalize_rgba(layer)


def _mirror_leg_layer(layer: Image.Image) -> Image.Image:
    """Mirror around x=15.5 while retaining the fixed robot upper."""
    result = _empty()
    source = layer.load()
    destination = result.load()
    for y in range(LEG_TOP_Y, LEG_BOTTOM_Y):
        for x in range(FRAME_SIZE):
            pixel = source[x, y]
            if pixel[3] > 0:
                destination[31 - x, y] = pixel
    return _normalize_rgba(result)


def _long_stride_layers() -> list[Image.Image]:
    """M1: the existing robots' long contact/down/pass/up gait."""
    half_cycle = (
        (
            (((13, 22), (12, 24), (10, 26)), (8, 12, 27)),
            (((18, 22), (19, 24), (21, 26)), (20, 23, 27)),
        ),
        (
            (((13, 22), (11, 24), (10, 26)), (8, 11, 27)),
            (((18, 22), (19, 24), (20, 26)), (19, 22, 27)),
        ),
        (
            (((13, 22), (14, 24), (15, 25)), (14, 17, 26)),
            (((18, 22), (17, 24), (16, 26)), (14, 18, 27)),
        ),
        (
            (((13, 22), (15, 24), (18, 25)), (17, 20, 26)),
            (((18, 22), (17, 24), (15, 26)), (13, 17, 27)),
        ),
    )
    authored = [_make_leg_layer(left, right) for left, right in half_cycle]
    return authored + [_mirror_leg_layer(layer) for layer in authored]


def _compact_stride_layers() -> list[Image.Image]:
    """M2: a compact planted gait with a sharper single-leg passing pose."""
    half_cycle = (
        (
            (((13, 22), (12, 24), (12, 26)), (10, 14, 27)),
            (((18, 22), (19, 24), (20, 26)), (18, 22, 27)),
        ),
        (
            (((13, 22), (12, 24), (13, 26)), (11, 14, 27)),
            (((18, 22), (18, 24), (19, 26)), (17, 21, 27)),
        ),
        (
            (((13, 22), (14, 24), (15, 25)), (14, 16, 26)),
            (((18, 22), (17, 24), (17, 26)), (15, 19, 27)),
        ),
        (
            (((13, 22), (14, 24), (16, 25)), (15, 18, 26)),
            (((18, 22), (17, 24), (16, 26)), (14, 18, 27)),
        ),
    )
    authored = [_make_leg_layer(left, right) for left, right in half_cycle]
    return authored + [_mirror_leg_layer(layer) for layer in authored]


def _compose_move(
    upper: Image.Image,
    leg_layers: Sequence[Image.Image],
) -> list[Image.Image]:
    frames: list[Image.Image] = []
    for legs in leg_layers:
        frame = upper.copy()
        frame.alpha_composite(legs)
        frames.append(_normalize_rgba(frame))
    return frames


def _paint_opaque(
    image: Image.Image,
    points: Iterable[tuple[int, int]],
    color: tuple[int, int, int, int],
) -> None:
    """Recolor only existing alpha, preserving the physical shield outline."""
    for point in points:
        if image.getpixel(point)[3] == 255:
            image.putpixel(point, color)


def _damage_shield(intact_upper: Image.Image, style: str, stage: str) -> Image.Image:
    if style not in {"s1", "s2"} or stage not in {"cracked", "critical"}:
        raise ValueError((style, stage))
    result = intact_upper.copy()
    if style == "s1":
        cracked_dark = ((25, 14), (26, 15), (27, 16), (26, 17))
        cracked_hot = ((27, 17), (27, 18))
        critical_dark = (
            (25, 11), (26, 12), (27, 13),
            (25, 19), (26, 18), (28, 18),
            (26, 22), (27, 21), (28, 20),
        )
        critical_hot = ((27, 14), (26, 18), (28, 19), (27, 22))
    else:
        cracked_dark = ((25, 13), (26, 13), (27, 14), (28, 14))
        cracked_hot = ((26, 18), (27, 18))
        critical_dark = (
            (25, 10), (26, 11), (28, 12),
            (25, 17), (26, 17), (28, 18),
            (25, 22), (26, 21), (27, 20), (28, 20),
        )
        critical_hot = ((27, 15), (28, 16), (26, 19), (27, 23))
    _paint_opaque(result, cracked_dark, PALETTE[1])
    _paint_opaque(result, cracked_hot, PALETTE[8])
    if stage == "critical":
        _paint_opaque(result, critical_dark, PALETTE[0])
        _paint_opaque(result, critical_hot, PALETTE[10])
    return _normalize_rgba(result)


def _broken_upper(intact_upper: Image.Image, style: str) -> Image.Image:
    """Remove shield/front arm and author a connected, empty downward hand."""
    result = intact_upper.copy()
    result.paste(TRANSPARENT, SHIELD_ARM_ROI)
    draw = ImageDraw.Draw(result)
    # One-pixel linear arm stays attached to the right shoulder but no longer
    # reaches the former shield collider.
    arm = ((20, 15), (21, 16), (21, 18), (20, 20))
    draw.line(arm, fill=PALETTE[0], width=1)
    draw.point((21, 17), fill=PALETTE[4])
    draw.point((20, 20), fill=PALETTE[5] if style == "s1" else PALETTE[4])
    return _normalize_rgba(result)


def _build_state_uppers(anchor: Image.Image, style: str) -> dict[str, Image.Image]:
    intact = _fixed_upper(anchor)
    states = {
        "intact": intact,
        "cracked": _damage_shield(intact, style, "cracked"),
        "critical": _damage_shield(intact, style, "critical"),
        "broken": _broken_upper(intact, style),
    }
    return states


def _translate(image: Image.Image, dx: int, dy: int) -> Image.Image:
    result = _empty()
    result.alpha_composite(image, (dx, dy))
    return result


def _crop_visible(image: Image.Image) -> Image.Image:
    return image.crop(_bbox(image))


def _shear_x_native(image: Image.Image, factor: float) -> Image.Image:
    image = _crop_visible(image)
    shifts = [round(factor * y) for y in range(image.height)]
    minimum = min(shifts)
    maximum = max(shifts)
    result = _empty((image.width + maximum - minimum, image.height))
    for y, shift in enumerate(shifts):
        result.alpha_composite(image.crop((0, y, image.width, y + 1)), (shift - minimum, y))
    return _crop_visible(_normalize_rgba(result))


def _shear_y_native(image: Image.Image, factor: float) -> Image.Image:
    image = _crop_visible(image)
    shifts = [round(factor * x) for x in range(image.width)]
    minimum = min(shifts)
    maximum = max(shifts)
    result = _empty((image.width, image.height + maximum - minimum))
    for x, shift in enumerate(shifts):
        result.alpha_composite(image.crop((x, 0, x + 1, image.height)), (x, shift - minimum))
    return _crop_visible(_normalize_rgba(result))


def _rotate_native(image: Image.Image, angle_degrees: float) -> Image.Image:
    """Rotate logical pixels with integer shears, never interpolation."""
    if math.isclose(angle_degrees, 90.0):
        return _crop_visible(image.transpose(Image.Transpose.ROTATE_90))
    if math.isclose(angle_degrees, -90.0):
        return _crop_visible(image.transpose(Image.Transpose.ROTATE_270))
    radians = math.radians(angle_degrees)
    first = _shear_x_native(image, -math.tan(radians * 0.5))
    second = _shear_y_native(first, math.sin(radians))
    return _shear_x_native(second, -math.tan(radians * 0.5))


def _place_crop(
    image: Image.Image,
    center: tuple[float, float],
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    image = _crop_visible(_normalize_rgba(image))
    x = round(center[0] - image.width * 0.5)
    y = round(center[1] - image.height * 0.5)
    x = min(max(0, x), FRAME_SIZE - image.width)
    y = min(max(0, y), FRAME_SIZE - image.height)
    result = _empty()
    result.alpha_composite(image, (x, y))
    return result, (x, y, x + image.width, y + image.height)


def _extract_death_layers(anchor: Image.Image) -> tuple[Image.Image, Image.Image]:
    body = anchor.copy()
    body.paste(TRANSPARENT, SHIELD_ARM_ROI)
    shield = _empty()
    shield.alpha_composite(anchor.crop(SHIELD_BBOX), (0, 0))
    return _crop_visible(body), _crop_visible(shield)


def _draw_connected_arm(
    frame: Image.Image,
    body_frame: Image.Image,
    shield_frame: Image.Image,
) -> tuple[tuple[int, int], tuple[int, int]]:
    """Bridge actual opaque body/shield pixels with an 8-connected arm.

    Picking endpoints from the transformed alpha masks is more robust than
    relying on a rotated bounding-box corner: integer shears can make that
    corner transparent.  A middle-height penalty keeps the bridge at the hand
    rather than choosing a geometrically closer helmet/shield-top pair.
    """
    body_alpha = np.asarray(body_frame.getchannel("A")) > 0
    shield_alpha = np.asarray(shield_frame.getchannel("A")) > 0
    body_points = [
        (x, y)
        for y in range(7, 27)
        for x in range(8, 27)
        if body_alpha[y, x]
    ]
    shield_points = [
        (x, y)
        for y in range(7, 27)
        for x in range(5, 31)
        if shield_alpha[y, x]
    ]
    if not body_points or not shield_points:
        raise AssertionError("Death rig lost body or shield pixels")
    target_y = sum(y for _x, y in shield_points) / len(shield_points)
    shoulder, grip = min(
        ((body, shield) for body in body_points for shield in shield_points),
        key=lambda pair: (
            (pair[0][0] - pair[1][0]) ** 2
            + (pair[0][1] - pair[1][1]) ** 2
            + abs(pair[0][1] - target_y) * 2,
            -pair[0][0],
            pair[1][0],
        ),
    )
    draw = ImageDraw.Draw(frame)
    draw.line((shoulder, grip), fill=PALETTE[0], width=1)
    mid = ((shoulder[0] + grip[0]) // 2, (shoulder[1] + grip[1]) // 2)
    draw.point(mid, fill=PALETTE[4])
    return shoulder, grip


def _build_death(
    anchor: Image.Image,
    cadence: str,
) -> tuple[list[Image.Image], list[tuple[tuple[int, int], tuple[int, int]]]]:
    """Build a shield-connected fall without resizing any source pixels."""
    if cadence not in {"d1", "d2"}:
        raise ValueError(cadence)
    body_source, shield_source = _extract_death_layers(anchor)
    if cadence == "d1":
        body_angles = (0, 0, -8, -16, -28, -43, -63, -90)
        shield_angles = (0, 0, -4, -10, -23, -38, -55, -65)
        body_centers = (
            (14, 16), (14, 17), (14.5, 18), (15, 19),
            (15.5, 20), (16, 21), (16.5, 22), (16, 23),
        )
        shield_centers = (
            (27, 17), (27, 18), (26.5, 18), (26, 19),
            (25, 20), (23, 21), (21, 22), (19, 24),
        )
    else:
        body_angles = (0, 0, 7, 15, 27, 42, 62, 90)
        shield_angles = (0, 0, 3, 9, 21, 36, 53, 64)
        body_centers = (
            (14, 16), (14, 17), (13.5, 18), (13, 19),
            (13, 20), (13.5, 21), (14, 22), (16, 23),
        )
        shield_centers = (
            (27, 17), (27, 18), (26.5, 18), (25.5, 19),
            (24.5, 20), (23, 21), (21, 22), (19, 24),
        )

    frames: list[Image.Image] = [anchor.copy()]
    # Both points are opaque and on opposite sides of the approved grip.
    semantic_pairs = [((19, 17), (25, 17))]
    for index in range(1, 8):
        body_rotated = _rotate_native(body_source, body_angles[index])
        shield_rotated = _rotate_native(shield_source, shield_angles[index])
        body_frame, body_rect = _place_crop(body_rotated, body_centers[index])
        shield_frame, shield_rect = _place_crop(shield_rotated, shield_centers[index])
        frame = _empty()
        frame.alpha_composite(body_frame)
        frame.alpha_composite(shield_frame)

        # Endpoints are selected from actual transformed opaque pixels, so the
        # hand remains connected even where an integer shear empties a bbox
        # corner.
        shoulder, grip = _draw_connected_arm(frame, body_frame, shield_frame)

        # Final contact is always placed on the y=28 baseline.  Translation is
        # integer-only and applies to the fully connected composite.
        bbox = _bbox(frame)
        dy = BASELINE_Y - bbox[3]
        frame = _translate(frame, 0, dy)
        frames.append(_normalize_rgba(frame))
        semantic_pairs.append(
            ((shoulder[0], shoulder[1] + dy), (grip[0], grip[1] + dy))
        )
    return frames, semantic_pairs


def _build_block_b1() -> list[Image.Image]:
    frames: list[Image.Image] = []
    specs = (
        ((15, 15, 17, 17), ((13, 15), (18, 16), (16, 13), (16, 18))),
        ((14, 14, 18, 18), ((11, 15), (20, 16), (16, 11), (16, 20))),
        ((15, 15, 17, 17), ((12, 13), (20, 14), (13, 20), (19, 19))),
    )
    for index, (core, sparks) in enumerate(specs):
        frame = _empty()
        draw = ImageDraw.Draw(frame)
        core_color = PALETTE[7] if index < 2 else PALETTE[10]
        draw.rectangle(core, fill=core_color)
        for spark_index, point in enumerate(sparks):
            draw.point(point, fill=PALETTE[11] if spark_index % 2 == 0 else PALETTE[9])
            # Symmetric mate fixes the FX center while retaining directional
            # visual weight inside each pair.
            draw.point((31 - point[0], 31 - point[1]), fill=PALETTE[9])
        frames.append(_normalize_rgba(frame))
    return frames


def _build_block_b2() -> list[Image.Image]:
    frames: list[Image.Image] = []
    specs = (
        (2, ((13, 14), (18, 17))),
        (5, ((11, 12), (20, 19), (12, 20), (19, 11))),
        (3, ((10, 15), (21, 16), (14, 10), (17, 21))),
    )
    for index, (radius, sparks) in enumerate(specs):
        frame = _empty()
        draw = ImageDraw.Draw(frame)
        color = (PALETTE[7], PALETTE[11], PALETTE[10])[index]
        draw.line((16 - radius, 16, 16, 16 - radius, 15 + radius, 15), fill=color, width=1)
        draw.line((15 + radius, 15, 15, 15 + radius, 16 - radius, 16), fill=PALETTE[9], width=1)
        for point in sparks:
            draw.point(point, fill=PALETTE[10])
            draw.point((31 - point[0], 31 - point[1]), fill=PALETTE[8])
        frames.append(_normalize_rgba(frame))
    return frames


def _rect_pair(
    draw: ImageDraw.ImageDraw,
    rect: tuple[int, int, int, int],
    color: tuple[int, int, int, int],
) -> None:
    draw.rectangle(rect, fill=color)
    mirror = (31 - rect[2], 31 - rect[3], 31 - rect[0], 31 - rect[1])
    draw.rectangle(mirror, fill=color)


def _critical_shield_fx_frame(critical_upper: Image.Image, angular: bool) -> Image.Image:
    """Register the exact critical shield pixels around the fixed FX center."""
    shield = critical_upper.crop(SHIELD_BBOX)
    frame = _empty()
    # A 6x18 source placed at (13,7) has center (15.5,15.5).
    frame.alpha_composite(shield, (13, 7))
    draw = ImageDraw.Draw(frame)
    if angular:
        sparks = ((12, 14), (12, 15), (19, 16), (19, 17), (15, 6), (16, 25))
    else:
        sparks = ((12, 15), (12, 16), (19, 15), (19, 16), (15, 6), (16, 25))
    for index, point in enumerate(sparks):
        draw.point(point, fill=PALETTE[11] if index < 2 else PALETTE[10])
    return _normalize_rgba(frame)


def _build_break_x1(critical_upper: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []
    # X1: rigid plate chunks peel along the vertical energy spine.
    chunk_specs = (
        (((14, 8, 17, 23), PALETTE[3]),),
        (((12, 7, 15, 14), PALETTE[4]), ((16, 16, 19, 24), PALETTE[3])),
        (((9, 7, 12, 11), PALETTE[4]), ((18, 10, 21, 15), PALETTE[3]), ((11, 20, 14, 24), PALETTE[2])),
        (((7, 9, 9, 12), PALETTE[3]), ((22, 17, 24, 20), PALETTE[2]), ((10, 24, 12, 26), PALETTE[3])),
        (((11, 14, 12, 15), PALETTE[2]), ((14, 20, 15, 21), PALETTE[8])),
    )
    for index, chunks in enumerate(chunk_specs):
        if index == 0:
            frames.append(_critical_shield_fx_frame(critical_upper, angular=False))
            continue
        frame = _empty()
        draw = ImageDraw.Draw(frame)
        for rect, color in chunks:
            _rect_pair(draw, rect, color)
        if index < 3:
            draw.line((15, 10 + index * 2, 15, 21 - index), fill=PALETTE[10], width=1)
            draw.line((16, 10 + index * 2, 16, 21 - index), fill=PALETTE[9], width=1)
        draw.point((15, 15), fill=PALETTE[11] if index < 2 else PALETTE[10])
        draw.point((16, 16), fill=PALETTE[11] if index < 2 else PALETTE[10])
        frames.append(_normalize_rgba(frame))
    return frames


def _build_break_x2(critical_upper: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []
    # X2: an angular mechanical burst, then paired falling fragments.
    radii = (3, 6, 9, 11, 8)
    for index, radius in enumerate(radii):
        if index == 0:
            frames.append(_critical_shield_fx_frame(critical_upper, angular=True))
            continue
        frame = _empty()
        draw = ImageDraw.Draw(frame)
        if index == 4:
            _rect_pair(draw, (11, 15, 12, 16), PALETTE[3])
            _rect_pair(draw, (14, 20, 15, 21), PALETTE[8])
            draw.point((15, 15), fill=PALETTE[10])
            draw.point((16, 16), fill=PALETTE[10])
            frames.append(_normalize_rgba(frame))
            continue
        if index < 3:
            color = (PALETTE[7], PALETTE[11], PALETTE[10])[index]
            draw.line((16 - radius, 16, 16, 16 - radius, 15 + radius, 15), fill=color, width=2)
            draw.line((15 + radius, 15, 15, 15 + radius, 16 - radius, 16), fill=PALETTE[9], width=1)
        fragment_y = min(25, 12 + index * 3)
        _rect_pair(draw, (9 - index, fragment_y, 11 - index, fragment_y + 2), PALETTE[3])
        _rect_pair(draw, (12, min(26, fragment_y + 3), 13, min(27, fragment_y + 4)), PALETTE[8])
        draw.point((15, 15), fill=PALETTE[10])
        draw.point((16, 16), fill=PALETTE[10])
        frames.append(_normalize_rgba(frame))
    return frames


def _frame_audit(frame: Image.Image, label: str, require_baseline: bool) -> dict:
    if frame.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"{label} is {frame.size}, expected 32x32")
    bbox = _bbox(frame)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label} bbox {bbox} exceeds 28x28")
    if require_baseline and bbox[3] != BASELINE_Y:
        raise AssertionError(f"{label} bbox {bbox} misses baseline y=28")
    colors = set(frame.getdata())
    if not colors.issubset(set(PALETTE) | {TRANSPARENT}):
        raise AssertionError(f"{label} contains colors outside fixed palette")
    for red, green, blue, alpha in colors:
        if alpha not in (0, 255):
            raise AssertionError(f"{label} contains non-binary alpha")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} contains dirty transparent RGB")
    return {
        "label": label,
        "bbox": list(bbox),
        "visible_size": [width, height],
        "baseline_y": bbox[3] if require_baseline else None,
        "rgba_sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
    }


def _masked_hash(image: Image.Image, clear_rect: tuple[int, int, int, int]) -> str:
    return hashlib.sha256(_clear_rect(image, clear_rect).tobytes()).hexdigest()


def _alpha_roi_bytes(
    image: Image.Image,
    rect: tuple[int, int, int, int],
) -> bytes:
    return image.getchannel("A").crop(rect).tobytes()


def _audit_move(
    frames: Sequence[Image.Image],
    expected_upper: Image.Image,
    label: str,
) -> dict:
    audits = [_frame_audit(frame, f"{label}[{i}]", True) for i, frame in enumerate(frames)]
    upper_hash = hashlib.sha256(expected_upper.tobytes()).hexdigest()
    upper_hashes = [_masked_hash(frame, LEG_ROI) for frame in frames]
    if set(upper_hashes) != {upper_hash}:
        raise AssertionError(f"{label} upper/shield is not byte-identical")
    leg_hashes = [hashlib.sha256(frame.crop(LEG_ROI).tobytes()).hexdigest() for frame in frames]
    if len(set(leg_hashes)) != 8:
        raise AssertionError(f"{label} does not have eight unique leg phases")
    return {
        "frames": audits,
        "fixed_upper_sha256": upper_hash,
        "unique_leg_phases": 8,
    }


def _audit_state_moves(
    state_moves: dict[str, list[Image.Image]],
    style: str,
) -> dict:
    names = ("intact", "cracked", "critical", "broken")
    if tuple(state_moves) != names:
        raise AssertionError(f"Unexpected {style} state order: {tuple(state_moves)}")
    phase_core_hashes: list[str] = []
    for phase in range(8):
        hashes = [_masked_hash(state_moves[name][phase], SHIELD_ARM_ROI) for name in names]
        if len(set(hashes)) != 1:
            raise AssertionError(f"{style} phase {phase} differs outside shield/arm ROI")
        phase_core_hashes.append(hashes[0])
    alpha_masks = [
        _alpha_roi_bytes(state_moves[name][0], SHIELD_BBOX)
        for name in ("intact", "cracked", "critical")
    ]
    if len(set(alpha_masks)) != 1:
        raise AssertionError(f"{style} unbroken shield alpha masks differ")
    leg_phase_hashes: dict[int, set[str]] = {}
    for phase in range(8):
        hashes = {
            hashlib.sha256(state_moves[name][phase].crop(LEG_ROI).tobytes()).hexdigest()
            for name in names
        }
        if len(hashes) != 1:
            raise AssertionError(f"{style} phase {phase} does not share one leg phase")
        leg_phase_hashes[phase] = hashes
    return {
        "phase_core_hashes": phase_core_hashes,
        "outside_shield_arm_roi_byte_identical": True,
        "unbroken_shield_alpha_identical": True,
        "four_states_share_each_leg_phase": True,
    }


def _component_labels(image: Image.Image) -> tuple[np.ndarray, list[int]]:
    alpha = np.asarray(image.getchannel("A")) > 0
    visited = np.zeros(alpha.shape, dtype=bool)
    labels = np.zeros(alpha.shape, dtype=np.int32)
    sizes: list[int] = []
    component_id = 0
    for start_y in range(FRAME_SIZE):
        for start_x in range(FRAME_SIZE):
            if not alpha[start_y, start_x] or visited[start_y, start_x]:
                continue
            queue = deque([(start_x, start_y)])
            visited[start_y, start_x] = True
            component_id += 1
            labels[start_y, start_x] = component_id
            size = 0
            while queue:
                x, y = queue.popleft()
                size += 1
                for next_y in range(max(0, y - 1), min(FRAME_SIZE, y + 2)):
                    for next_x in range(max(0, x - 1), min(FRAME_SIZE, x + 2)):
                        if alpha[next_y, next_x] and not visited[next_y, next_x]:
                            visited[next_y, next_x] = True
                            labels[next_y, next_x] = component_id
                            queue.append((next_x, next_y))
            sizes.append(size)
    return labels, sizes


def _component_sizes(image: Image.Image) -> list[int]:
    _labels, sizes = _component_labels(image)
    return sorted(sizes, reverse=True)


def _audit_death(
    frames: Sequence[Image.Image],
    anchor: Image.Image,
    label: str,
    semantic_pairs: Sequence[tuple[tuple[int, int], tuple[int, int]]],
) -> dict:
    if frames[0].tobytes() != anchor.tobytes():
        raise AssertionError(f"{label}[0] must equal the approved anchor")
    audits = [_frame_audit(frame, f"{label}[{i}]", True) for i, frame in enumerate(frames)]
    if len(semantic_pairs) != len(frames):
        raise AssertionError(f"{label} semantic pair count mismatch")
    component_sizes = []
    semantic_component_ids = []
    for index, (frame, (body_point, shield_point)) in enumerate(zip(frames, semantic_pairs)):
        labels, unsorted_sizes = _component_labels(frame)
        component_sizes.append(sorted(unsorted_sizes, reverse=True))
        body_id = int(labels[body_point[1], body_point[0]])
        shield_id = int(labels[shield_point[1], shield_point[0]])
        if body_id <= 0 or shield_id <= 0 or body_id != shield_id:
            raise AssertionError(
                f"{label}[{index}] body {body_point} and shield {shield_point} "
                f"are not in one 8-connected component ({body_id}, {shield_id})"
            )
        semantic_component_ids.append(body_id)
    # A free rear hand or separated foot may form a tiny component in the C
    # silhouette; the main body-hand-shield component must remain dominant.
    if any(not sizes or sizes[0] < sum(sizes) - 16 for sizes in component_sizes):
        raise AssertionError(f"{label} lost body-to-shield continuity: {component_sizes}")
    return {
        "frames": audits,
        "component_sizes": component_sizes,
        "shield_hand_connected_by_construction": True,
        "body_and_shield_same_8_connected_component": True,
        "semantic_component_ids": semantic_component_ids,
        "source_board_resized": False,
    }


def _audit_fx(
    frames: Sequence[Image.Image],
    label: str,
    require_terminal_contraction: bool = False,
) -> dict:
    audits = [_frame_audit(frame, f"{label}[{i}]", False) for i, frame in enumerate(frames)]
    centers = []
    for frame in frames:
        bbox = _bbox(frame)
        center = ((bbox[0] + bbox[2] - 1) / 2.0, (bbox[1] + bbox[3] - 1) / 2.0)
        if center != FX_CENTER:
            raise AssertionError(f"{label} bbox center drifted: {bbox} -> {center}")
        centers.append(list(center))
    if len({frame.tobytes() for frame in frames}) != len(frames):
        raise AssertionError(f"{label} contains duplicate FX frames")
    if require_terminal_contraction:
        previous_bbox = _bbox(frames[-2])
        final_bbox = _bbox(frames[-1])
        previous_area = (previous_bbox[2] - previous_bbox[0]) * (previous_bbox[3] - previous_bbox[1])
        final_area = (final_bbox[2] - final_bbox[0]) * (final_bbox[3] - final_bbox[1])
        if final_area >= previous_area:
            raise AssertionError(
                f"{label} terminal frame must contract: {previous_bbox} -> {final_bbox}"
            )
    return {
        "frames": audits,
        "centers": centers,
        "center_stable": True,
        "unique_frames": len(frames),
        "terminal_frame_contracts": require_terminal_contraction,
    }


def _assert_break_origin(
    frame: Image.Image,
    critical_upper: Image.Image,
    label: str,
) -> dict:
    expected = critical_upper.crop(SHIELD_BBOX)
    actual = frame.crop((13, 7, 19, 25))
    if actual.getchannel("A").tobytes() != expected.getchannel("A").tobytes():
        raise AssertionError(f"{label} X0 critical shield alpha is not pixel-aligned")
    if actual.tobytes() != expected.tobytes():
        raise AssertionError(f"{label} X0 critical shield RGBA is not an exact copy")
    return {
        "source_shield_bbox": list(SHIELD_BBOX),
        "fx_registered_bbox": [13, 7, 19, 25],
        "critical_alpha_exact": True,
        "critical_rgba_exact": True,
    }


def _build_strip(frames: Sequence[Image.Image]) -> Image.Image:
    strip = _empty((FRAME_SIZE * len(frames), FRAME_SIZE))
    for index, frame in enumerate(frames):
        strip.alpha_composite(frame, (index * FRAME_SIZE, 0))
    return strip


def _build_state_atlas(state_moves: dict[str, list[Image.Image]]) -> Image.Image:
    atlas = _empty((FRAME_SIZE * 8, FRAME_SIZE * 4))
    for row, frames in enumerate(state_moves.values()):
        for column, frame in enumerate(frames):
            atlas.alpha_composite(frame, (column * FRAME_SIZE, row * FRAME_SIZE))
    return atlas


def _on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    result.alpha_composite(image)
    return result


def _save_gif(
    frames: Iterable[Image.Image],
    path: Path,
    fps: int,
    scale: int = 12,
) -> None:
    prepared = [
        _on_background(frame)
        .resize((frame.width * scale, frame.height * scale), Image.Resampling.NEAREST)
        .convert("RGB")
        for frame in frames
    ]
    prepared[0].save(
        path,
        save_all=True,
        append_images=prepared[1:],
        duration=round(1000 / fps),
        loop=0,
        disposal=2,
        optimize=False,
    )


def _save_animation_outputs(
    name: str,
    frames: Sequence[Image.Image],
    fps: int,
) -> dict:
    strip = _build_strip(frames)
    strip_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_{name}_candidate.png"
    upscale_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_{name}_candidate_16x.png"
    gif_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_{name}_candidate.gif"
    strip.save(strip_path, optimize=True)
    _on_background(strip).resize(
        (strip.width * 16, strip.height * 16),
        Image.Resampling.NEAREST,
    ).save(upscale_path, optimize=True)
    _save_gif(frames, gif_path, fps=fps)
    return {
        "native_strip": _relative(strip_path),
        "integer_16x_strip": _relative(upscale_path),
        "gif": _relative(gif_path),
        "native_strip_size": list(strip.size),
        "fps": fps,
    }


def _save_state_outputs(
    style: str,
    move_name: str,
    state_moves: dict[str, list[Image.Image]],
    fps: int,
) -> dict:
    atlas = _build_state_atlas(state_moves)
    atlas_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_{move_name}_{style}_states_candidate.png"
    upscale_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_{move_name}_{style}_states_candidate_8x.png"
    gif_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_{move_name}_{style}_states_candidate.gif"
    atlas.save(atlas_path, optimize=True)
    _on_background(atlas).resize(
        (atlas.width * 8, atlas.height * 8),
        Image.Resampling.NEAREST,
    ).save(upscale_path, optimize=True)

    gif_frames: list[Image.Image] = []
    for phase in range(8):
        stacked = _empty((FRAME_SIZE, FRAME_SIZE * 4))
        for row, frames in enumerate(state_moves.values()):
            stacked.alpha_composite(frames[phase], (0, row * FRAME_SIZE))
        gif_frames.append(stacked)
    _save_gif(gif_frames, gif_path, fps=fps, scale=6)
    return {
        "native_4x8_atlas": _relative(atlas_path),
        "integer_8x_atlas": _relative(upscale_path),
        "four_state_gif": _relative(gif_path),
        "state_order": ["intact", "cracked", "critical", "broken"],
        "native_size": list(atlas.size),
        "fps": fps,
    }


def _save_state_summary(
    style: str,
    state_moves: dict[str, list[Image.Image]],
) -> dict:
    """Save one registered pose per durability state for direct comparison."""
    frames = [poses[0] for poses in state_moves.values()]
    strip = _build_strip(frames)
    strip_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_shield_states_{style}_candidate.png"
    upscale_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_shield_states_{style}_candidate_16x.png"
    cycle_path = PREVIEW_DIR / f"{OUTPUT_PREFIX}_shield_states_{style}_review_cycle.gif"
    strip.save(strip_path, optimize=True)
    _on_background(strip).resize(
        (strip.width * 16, strip.height * 16),
        Image.Resampling.NEAREST,
    ).save(upscale_path, optimize=True)
    _save_gif(frames, cycle_path, fps=2)
    return {
        "native_strip": _relative(strip_path),
        "integer_16x_strip": _relative(upscale_path),
        "review_cycle_gif": _relative(cycle_path),
        "state_order": ["intact", "cracked", "critical", "broken"],
        "review_cycle_only_not_runtime_animation": True,
    }


def _green_key(image: Image.Image) -> Image.Image:
    rgb = np.asarray(image.convert("RGB"), dtype=np.int16)
    red = rgb[:, :, 0]
    green = rgb[:, :, 1]
    blue = rgb[:, :, 2]
    key = (
        (green >= 96)
        & (green - red >= 38)
        & (green - blue >= 38)
        & (green >= np.maximum(red, blue) * 1.35)
    )
    rgba = np.empty((image.height, image.width, 4), dtype=np.uint8)
    rgba[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    rgba[:, :, 3] = np.where(key, 0, 255).astype(np.uint8)
    rgba[key, :3] = 0
    return Image.fromarray(rgba, mode="RGBA")


def _cell_bounds(size: int, count: int, index: int) -> tuple[int, int]:
    return round(index * size / count), round((index + 1) * size / count)


def _source_grid_report(path: Path, grid: tuple[int, int]) -> dict:
    keyed = _green_key(Image.open(path))
    frames: list[dict] = []
    for row in range(grid[1]):
        top, bottom = _cell_bounds(keyed.height, grid[1], row)
        for column in range(grid[0]):
            left, right = _cell_bounds(keyed.width, grid[0], column)
            cell = keyed.crop((left, top, right, bottom))
            bbox = cell.getchannel("A").getbbox()
            if bbox is None:
                frames.append({"frame": row * grid[0] + column, "empty": True})
                continue
            cropped = cell.crop(bbox)
            analysis = analyze_image(cropped)
            confidence = float(analysis["confidence"])
            mode = str(analysis["detection_mode"])
            frames.append(
                {
                    "frame": row * grid[0] + column,
                    "source_crop": [cropped.width, cropped.height],
                    "detected_grid_cell": [
                        float(analysis["grid_cell_width"]),
                        float(analysis["grid_cell_height"]),
                    ],
                    "confidence": confidence,
                    "detection_mode": mode,
                    "unsafe_for_direct_resize": mode == "native_or_unknown" or confidence < 0.65,
                }
            )
    return {
        "path": _relative(path),
        "sha256": _sha256(path),
        "board_size": list(keyed.size),
        "declared_reference_grid": list(grid),
        "frames": frames,
        "source_pixels_imported_into_preview": False,
        "use": "motion_or_shape_language_only",
    }


def _reference_frame(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    return image.crop((0, 0, 32, 32))


def _font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    for path in (
        Path("C:/Windows/Fonts/consola.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _draw_preview_frame(
    canvas: Image.Image,
    frame: Image.Image,
    position: tuple[int, int],
    scale: int,
) -> None:
    canvas.alpha_composite(
        _on_background(frame).resize(
            (frame.width * scale, frame.height * scale),
            Image.Resampling.NEAREST,
        ),
        position,
    )


def _build_comparison(
    anchor: Image.Image,
    animations: dict[str, list[Image.Image]],
    state_sets: dict[str, dict[str, dict[str, list[Image.Image]]]],
) -> Image.Image:
    canvas = Image.new("RGBA", (2300, 2700), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title_font = _font(25)
    label_font = _font(18)
    small_font = _font(14)
    draw.text((20, 14), "Shield bearer - deterministic second-gate candidates", fill=REVIEW_TEXT, font=title_font)
    draw.text((20, 48), "All candidates: native 32px cells / fixed palette / ImageGen pixels not imported", fill=REVIEW_MUTED, font=small_font)

    references = (
        ("Sword F0", PROJECT_ROOT / "resources/texture/enemy/mechanical_life/combat_robot.png", 32),
        ("Gunner F0", PROJECT_ROOT / "resources/texture/enemy/mechanical_life/combat_robot_gunner.png", 32),
        ("Operator F0", PROJECT_ROOT / "resources/texture/enemy/mechanical_life/combat_robot_drone_operator.png", 32),
    )
    x = 20
    for label, path, _size in references:
        draw.text((x, 84), label, fill=REVIEW_TEXT, font=small_font)
        _draw_preview_frame(canvas, _reference_frame(path), (x, 106), 5)
        x += 190
    draw.text((x, 84), "Approved C", fill=REVIEW_TEXT, font=small_font)
    _draw_preview_frame(canvas, anchor, (x, 106), 5)
    x += 190
    tango = Image.open(PROJECT_ROOT / "resources/texture/player/tango/tango_cast_unit.png").convert("RGBA").crop((0, 0, 8, 8))
    draw.text((x, 84), "Tango 8x8 density only", fill=REVIEW_TEXT, font=small_font)
    _draw_preview_frame(canvas, tango, (x, 106), 20)

    row_y = 300
    animation_labels = (
        ("move_m1", "M1 long mechanical stride - 8f @14fps"),
        ("move_m2", "M2 compact planted stride - 8f @14fps"),
        ("death_d1", "D1 forward shield-led collapse - 8f @12fps"),
        ("death_d2", "D2 counterbalance fold - 8f @12fps"),
        ("block_b1", "B1 hot cross shield impact - 3f @24fps"),
        ("block_b2", "B2 angular shield impact - 3f @24fps"),
        ("break_x1", "X1 rigid plate split - 5f @18fps"),
        ("break_x2", "X2 angular mechanical burst - 5f @18fps"),
    )
    for name, label in animation_labels:
        draw.text((20, row_y), label, fill=REVIEW_TEXT, font=label_font)
        strip = _on_background(_build_strip(animations[name])).resize(
            (len(animations[name]) * FRAME_SIZE * 8, FRAME_SIZE * 8),
            Image.Resampling.NEAREST,
        )
        canvas.alpha_composite(strip, (20, row_y + 26))
        row_y += 294

    # State comparison sits to the right of the first four animation rows.
    state_x = 1020
    state_y = 300
    for style in ("s1", "s2"):
        draw.text((state_x, state_y), f"{style.upper()} shield states: intact / cracked / critical / broken", fill=REVIEW_TEXT, font=label_font)
        state_moves = state_sets["move_m1"][style]
        for index, (state, frames) in enumerate(state_moves.items()):
            draw.text((state_x + index * 210, state_y + 28), state, fill=REVIEW_MUTED, font=small_font)
            _draw_preview_frame(canvas, frames[0], (state_x + index * 210, state_y + 50), 6)
        state_y += 290
    return canvas


def _ensure_preview_only() -> None:
    resolved_preview = PREVIEW_DIR.resolve()
    resolved_runtime = (PROJECT_ROOT / "resources").resolve()
    if resolved_preview == resolved_runtime or resolved_runtime in resolved_preview.parents:
        raise AssertionError("Preview output directory overlaps runtime resources")


def build() -> dict:
    _ensure_preview_only()
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for source_path, _grid in SOURCE_SPECS.values():
        if not source_path.is_file():
            raise FileNotFoundError(source_path)

    anchor = _load_anchor()
    leg_variants = {
        "move_m1": _long_stride_layers(),
        "move_m2": _compact_stride_layers(),
    }
    state_uppers = {
        style: _build_state_uppers(anchor, style)
        for style in ("s1", "s2")
    }
    state_sets: dict[str, dict[str, dict[str, list[Image.Image]]]] = {}
    for move_name, legs in leg_variants.items():
        state_sets[move_name] = {}
        for style, uppers in state_uppers.items():
            state_sets[move_name][style] = {
                state: _compose_move(upper, legs)
                for state, upper in uppers.items()
            }

    death_d1, death_d1_pairs = _build_death(anchor, "d1")
    death_d2, death_d2_pairs = _build_death(anchor, "d2")
    animations = {
        "move_m1": state_sets["move_m1"]["s1"]["intact"],
        "move_m2": state_sets["move_m2"]["s1"]["intact"],
        "death_d1": death_d1,
        "death_d2": death_d2,
        "block_b1": _build_block_b1(),
        "block_b2": _build_block_b2(),
        "break_x1": _build_break_x1(state_uppers["s1"]["critical"]),
        "break_x2": _build_break_x2(state_uppers["s2"]["critical"]),
    }

    animation_audit = {
        "move_m1": _audit_move(animations["move_m1"], state_uppers["s1"]["intact"], "move_m1"),
        "move_m2": _audit_move(animations["move_m2"], state_uppers["s1"]["intact"], "move_m2"),
        "death_d1": _audit_death(
            animations["death_d1"], anchor, "death_d1", death_d1_pairs
        ),
        "death_d2": _audit_death(
            animations["death_d2"], anchor, "death_d2", death_d2_pairs
        ),
        "block_b1": _audit_fx(animations["block_b1"], "block_b1"),
        "block_b2": _audit_fx(animations["block_b2"], "block_b2"),
        "break_x1": _audit_fx(
            animations["break_x1"], "break_x1", require_terminal_contraction=True
        ),
        "break_x2": _audit_fx(
            animations["break_x2"], "break_x2", require_terminal_contraction=True
        ),
    }
    animation_audit["break_x1"]["critical_origin"] = _assert_break_origin(
        animations["break_x1"][0], state_uppers["s1"]["critical"], "break_x1"
    )
    animation_audit["break_x2"]["critical_origin"] = _assert_break_origin(
        animations["break_x2"][0], state_uppers["s2"]["critical"], "break_x2"
    )
    state_audit: dict[str, dict[str, dict]] = {}
    for move_name, styles in state_sets.items():
        state_audit[move_name] = {}
        for style, state_moves in styles.items():
            for state, frames in state_moves.items():
                for index, frame in enumerate(frames):
                    _frame_audit(frame, f"{move_name}/{style}/{state}[{index}]", True)
            state_audit[move_name][style] = _audit_state_moves(state_moves, style)

    outputs: dict[str, dict] = {}
    for name, frames in animations.items():
        expected_count, fps = ANIMATION_SPECS[name]
        if len(frames) != expected_count:
            raise AssertionError(f"{name} has {len(frames)} frames, expected {expected_count}")
        outputs[name] = _save_animation_outputs(name, frames, fps)

    state_outputs: dict[str, dict[str, dict]] = {}
    for move_name, styles in state_sets.items():
        state_outputs[move_name] = {}
        for style, state_moves in styles.items():
            state_outputs[move_name][style] = _save_state_outputs(
                style,
                move_name,
                state_moves,
                ANIMATION_SPECS[move_name][1],
            )
    shield_state_outputs = {
        style: _save_state_summary(
            style,
            state_sets["move_m1"][style],
        )
        for style in ("s1", "s2")
    }

    comparison = _build_comparison(anchor, animations, state_sets)
    comparison.save(COMPARISON_PATH, optimize=True)
    source_reports = {
        name: _source_grid_report(path, grid)
        for name, (path, grid) in SOURCE_SPECS.items()
    }

    report = {
        "stage": "second_human_review_gate",
        "preview_only": True,
        "runtime_written": False,
        "approved_anchor": {
            "path": _relative(ANCHOR_PATH),
            "sha256": _sha256(ANCHOR_PATH),
            "identity_and_pixel_source": True,
        },
        "construction": {
            "imagegen_source_pixels_imported": False,
            "imagegen_boards_used_as_motion_language_only": True,
            "native_anchor_resized": False,
            "palette": [list(color) for color in PALETTE],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "cell_size": [FRAME_SIZE, FRAME_SIZE],
            "maximum_visible_bbox": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "baseline_y": BASELINE_Y,
            "shield_bbox": list(SHIELD_BBOX),
            "shield_arm_roi": list(SHIELD_ARM_ROI),
            "leg_roi": list(LEG_ROI),
            "death_transform": "native integer shears and exact quarter-turns",
        },
        "animation_audit": animation_audit,
        "shield_state_audit": state_audit,
        "source_grid_analysis": source_reports,
        "outputs": outputs,
        "state_outputs": state_outputs,
        "shield_state_outputs": shield_state_outputs,
        "comparison": _relative(COMPARISON_PATH),
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def main() -> None:
    report = build()
    print("COMBAT_ROBOT_SHIELD_BEARER_PREVIEWS_OK")
    print(f"  preview_only={report['preview_only']}")
    print(f"  comparison={report['comparison']}")
    print(f"  audit={_relative(REPORT_PATH)}")
    for name, outputs in report["outputs"].items():
        print(f"  {name}: {outputs['native_strip']} {outputs['integer_16x_strip']} {outputs['gif']}")


if __name__ == "__main__":
    main()
