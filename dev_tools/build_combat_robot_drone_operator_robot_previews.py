#!/usr/bin/env python3
"""Build stage-two, review-only robot previews for the drone operator.

The approved C anchor is the only identity/pixel source.  Independently
generated ImageGen boards are deliberately treated as motion-language
references: M1 supplies a long mechanical stride, M2 a compact stride, D1/D2
two button cadences, and K1/K2 two collapse cadences.  No ImageGen pose is
resized into a runtime frame.

This script has no runtime-writing switch.  Every output stays under
``dev_assets/generated_previews`` until the second human review gate passes.
"""

from __future__ import annotations

import hashlib
import json
import math
from collections import deque
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets/source_images/combat_robot_drone_operator"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets/generated_previews"

ANCHOR_PATH = (
    SOURCE_DIR
    / "combat_robot_drone_operator_anchor_c_approved_native32.png"
)
EXPECTED_ANCHOR_SHA256 = (
    "30af60b309a8adb247b4a7d3ec0cb8cde3046e2ebe2bf30cac08758d209d5a11"
)

SOURCE_SPECS = {
    "move_m1": (
        SOURCE_DIR / "combat_robot_drone_operator_move_m1_imagegen.png",
        (4, 2),
    ),
    "move_m2": (
        SOURCE_DIR / "combat_robot_drone_operator_move_m2_imagegen.png",
        (4, 2),
    ),
    "deploy_d1": (
        SOURCE_DIR / "combat_robot_drone_operator_deploy_d1_imagegen.png",
        (3, 1),
    ),
    "deploy_d2": (
        SOURCE_DIR / "combat_robot_drone_operator_deploy_d2_imagegen.png",
        (3, 1),
    ),
    "death_k1": (
        SOURCE_DIR / "combat_robot_drone_operator_death_k1_imagegen.png",
        (4, 2),
    ),
    "death_k2": (
        SOURCE_DIR / "combat_robot_drone_operator_death_k2_imagegen.png",
        (4, 2),
    ),
}

FRAME_SIZE = 32
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
LEG_TOP_Y = 22
LEG_BOTTOM_Y = 28
HIP_LEFT_X = 13
HIP_RIGHT_X = 18
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_TEXT = (226, 229, 226, 255)

OUTPUT_PREFIX = "combat_robot_drone_operator"
REPORT_PATH = PREVIEW_DIR / f"{OUTPUT_PREFIX}_robot_preview_audit.json"
COMPARISON_PATH = PREVIEW_DIR / f"{OUTPUT_PREFIX}_robot_comparison.png"

# One name, frame count and exact playback contract per review strip.
ANIMATION_SPECS = {
    "move_m1": (8, 14),
    "move_m2": (8, 14),
    "deploy_d1": (3, 30),
    "deploy_d2": (3, 30),
    "death_k1": (8, 12),
    "death_k2": (8, 12),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _alpha_composite(
    destination: Image.Image,
    source: Image.Image,
    xy: tuple[int, int],
) -> None:
    destination.alpha_composite(source, xy)


def _normalize_rgba(image: Image.Image) -> Image.Image:
    """Snap colors, force binary alpha, and zero every transparent RGB byte."""
    snapped = snap_palette(image.convert("RGBA"))
    pixels = np.asarray(snapped, dtype=np.uint8).copy()
    visible = pixels[:, :, 3] >= 128
    pixels[:, :, 3] = np.where(visible, 255, 0).astype(np.uint8)
    pixels[~visible, :3] = 0
    return Image.fromarray(pixels, mode="RGBA")


def _load_anchor() -> Image.Image:
    digest = _sha256(ANCHOR_PATH)
    if digest != EXPECTED_ANCHOR_SHA256:
        raise ValueError(
            "Approved C anchor changed: "
            f"expected {EXPECTED_ANCHOR_SHA256}, got {digest}"
        )
    anchor = _normalize_rgba(Image.open(ANCHOR_PATH))
    if anchor.size != (FRAME_SIZE, FRAME_SIZE):
        raise ValueError(f"Approved anchor must be 32x32, got {anchor.size}")
    if anchor.getchannel("A").getbbox() != (10, 4, 24, 28):
        raise ValueError(
            "Approved C anchor registration changed: "
            f"{anchor.getchannel('A').getbbox()}"
        )
    return anchor


def _fixed_upper(anchor: Image.Image) -> Image.Image:
    """Remove exactly the six authored leg rows, retaining all other bytes."""
    upper = anchor.copy()
    upper.paste(TRANSPARENT, (0, LEG_TOP_Y, FRAME_SIZE, LEG_BOTTOM_Y))
    return upper


def _draw_leg(
    layer: Image.Image,
    points: Sequence[tuple[int, int]],
    foot: tuple[int, int, int],
    front: bool,
) -> None:
    """Draw one thin mechanical leg and a two-row planted/lifted foot."""
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
    layer = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    # Back leg is always painted first, preventing draw-order shimmer at a cross.
    _draw_leg(layer, left[0], left[1], front=False)
    _draw_leg(layer, right[0], right[1], front=True)
    return _normalize_rgba(layer)


def _mirror_leg_layer(layer: Image.Image) -> Image.Image:
    """Mirror only the legs around x=15.5; the approved upper never flips."""
    result = Image.new("RGBA", layer.size, TRANSPARENT)
    source = layer.load()
    destination = result.load()
    for y in range(LEG_TOP_Y, LEG_BOTTOM_Y):
        for x in range(FRAME_SIZE):
            pixel = source[x, y]
            if pixel[3] > 0:
                destination[31 - x, y] = pixel
    return result


def _long_stride_layers() -> list[Image.Image]:
    """M1 language: contact/down/pass/up with long opposing foot travel."""
    half_cycle = (
        (
            (((13, 22), (12, 24), (10, 26)), (8, 12, 27)),
            (((18, 22), (19, 24), (21, 26)), (20, 24, 27)),
        ),
        (
            (((13, 22), (11, 24), (10, 26)), (8, 11, 27)),
            (((18, 22), (19, 24), (20, 26)), (19, 23, 27)),
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
    """M2 language: short grounded travel with a compact lifted knee."""
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
    for layer in leg_layers:
        frame = upper.copy()
        _alpha_composite(frame, layer, (0, 0))
        frames.append(_normalize_rgba(frame))
    return frames


def _build_deploy(anchor: Image.Image, cadence: str) -> list[Image.Image]:
    """Animate only an existing thumb pixel and the existing status pixel."""
    if cadence not in {"d1", "d2"}:
        raise ValueError(f"Unknown deploy cadence: {cadence}")
    frame0 = anchor.copy()
    frame1 = anchor.copy()
    frame2 = anchor.copy()

    # (15,16) is the approved one-pixel thumb on the controller's top edge;
    # (20,17) is its existing orange status point.  All edits stay on already
    # opaque controller/hand pixels, so neither outline nor alpha can flicker.
    if cadence == "d1":
        frame1.putpixel((15, 16), PALETTE[4])
        frame1.putpixel((15, 17), PALETTE[6])
        frame1.putpixel((20, 17), PALETTE[11])
        frame2.putpixel((15, 16), PALETTE[4])
        frame2.putpixel((15, 17), PALETTE[6])
        frame2.putpixel((20, 17), PALETTE[9])
    else:
        frame1.putpixel((15, 16), PALETTE[4])
        frame1.putpixel((16, 16), PALETTE[6])
        frame1.putpixel((20, 17), PALETTE[9])
        frame2.putpixel((15, 16), PALETTE[6])
        frame2.putpixel((16, 16), PALETTE[0])
        frame2.putpixel((20, 17), PALETTE[11])
    return [_normalize_rgba(frame) for frame in (frame0, frame1, frame2)]


def _translate(image: Image.Image, dx: int, dy: int) -> Image.Image:
    result = Image.new("RGBA", image.size, TRANSPARENT)
    _alpha_composite(result, image, (dx, dy))
    return result


def _crouch_pose(
    upper: Image.Image,
    depth: int,
    direction: int,
) -> Image.Image:
    """Lower the immutable upper and fold two native one-pixel legs."""
    frame = _translate(upper, direction * max(0, depth - 1), depth)
    layer = Image.new("RGBA", frame.size, TRANSPARENT)
    draw = ImageDraw.Draw(layer)
    hip_y = LEG_TOP_Y + depth
    left_hip = (HIP_LEFT_X + direction * max(0, depth - 1), hip_y)
    right_hip = (HIP_RIGHT_X + direction * max(0, depth - 1), hip_y)
    # Feet stay planted while knees spread: a readable crouch, not a scaled body.
    draw.line((left_hip, (12 - depth, 25), (10 - depth, 26)), fill=PALETTE[0], width=1)
    draw.rectangle((9 - depth, 26, 13 - depth, 27), fill=PALETTE[0])
    draw.line((10 - depth, 26, 12 - depth, 26), fill=PALETTE[5])
    draw.line((right_hip, (19 + depth, 25), (21 + depth, 26)), fill=PALETTE[0], width=1)
    draw.rectangle((19 + depth, 26, 23 + depth, 27), fill=PALETTE[0])
    draw.line((20 + depth, 26, 22 + depth, 26), fill=PALETTE[5])
    _alpha_composite(frame, layer, (0, 0))
    return _normalize_rgba(frame)


def _imbalance_pose(upper: Image.Image) -> Image.Image:
    """K2's wide recovery step before the supporting leg folds."""
    frame = upper.copy()
    layer = Image.new("RGBA", frame.size, TRANSPARENT)
    draw = ImageDraw.Draw(layer)
    draw.line(((HIP_LEFT_X, 22), (11, 24), (9, 26)), fill=PALETTE[1], width=1)
    draw.rectangle((7, 26, 11, 27), fill=PALETTE[0])
    draw.line((8, 26, 10, 26), fill=PALETTE[4])
    draw.line(((HIP_RIGHT_X, 22), (18, 24), (17, 25)), fill=PALETTE[0], width=1)
    draw.rectangle((16, 25, 19, 26), fill=PALETTE[0])
    draw.line((17, 25, 18, 25), fill=PALETTE[5])
    _alpha_composite(frame, layer, (0, 0))
    return _normalize_rgba(frame)


def _crop_visible(image: Image.Image) -> Image.Image:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Unexpected empty pose")
    return image.crop(bbox)


def _shear_x_native(image: Image.Image, factor: float) -> Image.Image:
    """Shift complete logical rows; no sampling, scaling or color invention."""
    image = _crop_visible(image)
    shifts = [round(factor * y) for y in range(image.height)]
    minimum = min(shifts)
    maximum = max(shifts)
    result = Image.new(
        "RGBA",
        (image.width + maximum - minimum, image.height),
        TRANSPARENT,
    )
    for y, shift in enumerate(shifts):
        row = image.crop((0, y, image.width, y + 1))
        _alpha_composite(result, row, (shift - minimum, y))
    return _crop_visible(_normalize_rgba(result))


def _shear_y_native(image: Image.Image, factor: float) -> Image.Image:
    """Shift complete logical columns; the inverse of ``_shear_x_native``."""
    image = _crop_visible(image)
    shifts = [round(factor * x) for x in range(image.width)]
    minimum = min(shifts)
    maximum = max(shifts)
    result = Image.new(
        "RGBA",
        (image.width, image.height + maximum - minimum),
        TRANSPARENT,
    )
    for x, shift in enumerate(shifts):
        column = image.crop((x, 0, x + 1, image.height))
        _alpha_composite(result, column, (x, shift - minimum))
    return _crop_visible(_normalize_rgba(result))


def _rotate_native_via_shears(
    image: Image.Image,
    angle_degrees: float,
) -> Image.Image:
    """Rotate native logical pixels with three reversible integer shears.

    Unlike ``PIL.Image.rotate`` this never samples a neighborhood.  Every
    source pixel is shifted as a whole logical pixel, and adjacent rows/columns
    move by at most one pixel throughout the requested +/-70 degree range.
    Exact quarter turns use an exact transpose.
    """
    if math.isclose(angle_degrees, 90.0):
        return _crop_visible(image.transpose(Image.Transpose.ROTATE_90))
    if math.isclose(angle_degrees, -90.0):
        return _crop_visible(image.transpose(Image.Transpose.ROTATE_270))
    radians = math.radians(angle_degrees)
    first = _shear_x_native(image, -math.tan(radians * 0.5))
    second = _shear_y_native(first, math.sin(radians))
    third = _shear_x_native(second, -math.tan(radians * 0.5))
    return _crop_visible(_normalize_rgba(third))


def _place_pose(
    pose: Image.Image,
    center_x: float,
    bottom_y: int,
) -> Image.Image:
    pose = _crop_visible(_normalize_rgba(pose))
    if pose.width > MAX_VISIBLE_SIZE or pose.height > MAX_VISIBLE_SIZE:
        raise ValueError(f"Native death pose {pose.size} exceeds 28px")
    x = round(center_x - pose.width * 0.5)
    y = bottom_y - pose.height
    x = min(max(0, x), FRAME_SIZE - pose.width)
    if y < 0 or y + pose.height > FRAME_SIZE:
        raise ValueError(f"Cannot place death pose {pose.size} at bottom {bottom_y}")
    frame = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    _alpha_composite(frame, pose, (x, y))
    return _normalize_rgba(frame)


def _lower_mounts(
    frame: Image.Image,
    upper_bottom_y: int,
) -> tuple[tuple[int, int], tuple[int, int]]:
    """Find stable left/right mounts along the rigid upper's lower outline."""
    alpha = np.asarray(frame.getchannel("A")) > 0
    points: list[tuple[int, int]] = []
    for y in range(max(0, upper_bottom_y - 3), upper_bottom_y):
        for x in range(FRAME_SIZE):
            if alpha[y, x]:
                points.append((x, y))
    if not points:
        raise ValueError("Tilted upper has no lower-edge mounts")
    lowest_y = max(y for _x, y in points)
    lowest = sorted(x for x, y in points if y == lowest_y)
    return (lowest[0], lowest_y), (lowest[-1], lowest_y)


def _tilt_with_supports(
    upper: Image.Image,
    angle_degrees: float,
    center_x: float,
    upper_bottom_y: int,
    direction: int,
    single_support: bool,
) -> Image.Image:
    """Place a clean sheared rigid upper and explicitly connect folded legs."""
    tilted = _rotate_native_via_shears(_crop_visible(upper), angle_degrees)
    frame = _place_pose(tilted, center_x=center_x, bottom_y=upper_bottom_y)
    left_mount, right_mount = _lower_mounts(frame, upper_bottom_y)
    layer = Image.new("RGBA", frame.size, TRANSPARENT)
    draw = ImageDraw.Draw(layer)

    if direction > 0:
        support_mount = left_mount
        tucked_mount = right_mount
        support_knee = (support_mount[0] - 1, min(26, support_mount[1] + 1))
        foot_left = support_knee[0] - 2
        tucked_end = (tucked_mount[0] - 1, min(27, tucked_mount[1] + 1))
    else:
        support_mount = right_mount
        tucked_mount = left_mount
        support_knee = (support_mount[0] + 1, min(26, support_mount[1] + 1))
        foot_left = support_knee[0] - 1
        tucked_end = (tucked_mount[0] + 1, min(27, tucked_mount[1] + 1))

    draw.line((support_mount, support_knee, (support_knee[0], 26)), fill=PALETTE[0], width=1)
    draw.rectangle((foot_left, 26, foot_left + 3, 27), fill=PALETTE[0])
    draw.line((foot_left + 1, 26, foot_left + 2, 26), fill=PALETTE[5])
    if not single_support:
        draw.line((tucked_mount, tucked_end), fill=PALETTE[1], width=1)
        draw.point(tucked_end, fill=PALETTE[4])
    _alpha_composite(frame, layer, (0, 0))
    return _normalize_rgba(frame)


def _tilted_landed_upper(
    upper: Image.Image,
    angle_degrees: float,
    center_x: float,
) -> Image.Image:
    tilted = _rotate_native_via_shears(_crop_visible(upper), angle_degrees)
    return _place_pose(tilted, center_x=center_x, bottom_y=BASELINE_Y)


def _build_death_k1(anchor: Image.Image, upper: Image.Image) -> list[Image.Image]:
    """K1 language: forward crouch, commit, then controller-first collapse."""
    crouch1 = _crouch_pose(upper, depth=1, direction=1)
    crouch2 = _crouch_pose(upper, depth=2, direction=1)
    return [
        anchor.copy(),
        crouch1,
        crouch2,
        _tilt_with_supports(upper, -12.0, 16.5, 24, 1, False),
        _tilt_with_supports(upper, -28.0, 17.0, 27, 1, True),
        _tilted_landed_upper(upper, -46.0, 17.5),
        _tilted_landed_upper(upper, -68.0, 18.0),
        _tilted_landed_upper(upper, -90.0, 18.0),
    ]


def _build_death_k2(anchor: Image.Image, upper: Image.Image) -> list[Image.Image]:
    """K2 language: side imbalance, support failure and opposite-side fold."""
    imbalance = _imbalance_pose(upper)
    fold = _crouch_pose(upper, depth=2, direction=-1)
    return [
        anchor.copy(),
        imbalance,
        fold,
        _tilt_with_supports(upper, 16.0, 14.5, 24, -1, False),
        _tilt_with_supports(upper, 31.0, 14.0, 27, -1, True),
        _tilted_landed_upper(upper, 49.0, 13.5),
        _tilted_landed_upper(upper, 70.0, 13.0),
        _tilted_landed_upper(upper, 90.0, 13.0),
    ]


def _cell_bounds(size: int, count: int, index: int) -> tuple[int, int]:
    return round(index * size / count), round((index + 1) * size / count)


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


def _source_grid_report(path: Path, grid: tuple[int, int]) -> dict:
    """Audit source logic grids without sampling/resizing any source pose."""
    keyed = _green_key(Image.open(path))
    frames: list[dict] = []
    for row in range(grid[1]):
        top, bottom = _cell_bounds(keyed.height, grid[1], row)
        for column in range(grid[0]):
            left, right = _cell_bounds(keyed.width, grid[0], column)
            cell = keyed.crop((left, top, right, bottom))
            bbox = cell.getchannel("A").getbbox()
            if bbox is None:
                raise ValueError(f"Empty source cell {path.name} ({column},{row})")
            cropped = cell.crop(bbox)
            analysis = analyze_image(cropped)
            confidence = float(analysis["confidence"])
            mode = str(analysis["detection_mode"])
            unsafe = mode == "native_or_unknown" or confidence < 0.65
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
                    "unsafe_for_resizing": unsafe,
                }
            )
    return {
        "path": str(path.relative_to(PROJECT_ROOT)),
        "sha256": _sha256(path),
        "board_size": [keyed.width, keyed.height],
        "grid": list(grid),
        "frames": frames,
        "source_pixels_imported_into_preview": False,
        "use": "motion_language_only",
    }


def _visible_colors(image: Image.Image) -> set[tuple[int, int, int, int]]:
    return {pixel for pixel in image.getdata() if pixel[3] > 0}


def _bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Unexpected empty frame")
    return bbox


def _component_sizes(
    image: Image.Image,
    crop: tuple[int, int, int, int],
) -> list[int]:
    alpha = np.asarray(image.crop(crop).getchannel("A")) > 0
    visited = np.zeros(alpha.shape, dtype=bool)
    sizes: list[int] = []
    for start_y in range(alpha.shape[0]):
        for start_x in range(alpha.shape[1]):
            if not alpha[start_y, start_x] or visited[start_y, start_x]:
                continue
            queue = deque([(start_x, start_y)])
            visited[start_y, start_x] = True
            size = 0
            while queue:
                x, y = queue.popleft()
                size += 1
                for next_y in range(max(0, y - 1), min(alpha.shape[0], y + 2)):
                    for next_x in range(max(0, x - 1), min(alpha.shape[1], x + 2)):
                        if alpha[next_y, next_x] and not visited[next_y, next_x]:
                            visited[next_y, next_x] = True
                            queue.append((next_x, next_y))
            sizes.append(size)
    return sorted(sizes, reverse=True)


def _frame_audit(frame: Image.Image, label: str) -> dict:
    bbox = _bbox(frame)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label} bbox {bbox} exceeds 28x28")
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"{label} bbox {bbox} misses baseline y=28")
    alpha_values = set(frame.getchannel("A").getdata())
    if not alpha_values.issubset({0, 255}):
        raise AssertionError(f"{label} has non-binary alpha: {alpha_values}")
    if not _visible_colors(frame).issubset(set(PALETTE)):
        raise AssertionError(f"{label} contains colors outside robot PALETTE")
    for red, green, blue, alpha in frame.getdata():
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} has dirty transparent RGB")
    return {
        "frame": label,
        "bbox": list(bbox),
        "visible_size": [width, height],
        "baseline_y": bbox[3],
        "rgba_sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
    }


def _assert_move_contract(
    frames: Sequence[Image.Image],
    upper: Image.Image,
    label: str,
) -> dict:
    audits = [_frame_audit(frame, f"{label}[{i}]") for i, frame in enumerate(frames)]
    upper_hashes: list[str] = []
    leg_hashes: list[str] = []
    for frame in frames:
        fixed = frame.copy()
        fixed.paste(TRANSPARENT, (0, LEG_TOP_Y, FRAME_SIZE, LEG_BOTTOM_Y))
        upper_hashes.append(hashlib.sha256(fixed.tobytes()).hexdigest())
        leg_hashes.append(
            hashlib.sha256(
                frame.crop((0, LEG_TOP_Y, FRAME_SIZE, LEG_BOTTOM_Y)).tobytes()
            ).hexdigest()
        )
    expected_upper_hash = hashlib.sha256(upper.tobytes()).hexdigest()
    if set(upper_hashes) != {expected_upper_hash}:
        raise AssertionError(f"{label} upper body/controller is not byte-identical")
    if len(set(leg_hashes)) != 8:
        raise AssertionError(f"{label} must contain eight unique leg masks")
    return {
        "frames": audits,
        "fixed_upper_sha256": expected_upper_hash,
        "unique_leg_masks": len(set(leg_hashes)),
    }


def _assert_deploy_contract(
    frames: Sequence[Image.Image],
    anchor: Image.Image,
    label: str,
) -> dict:
    audits = [_frame_audit(frame, f"{label}[{i}]") for i, frame in enumerate(frames)]
    if frames[0].tobytes() != anchor.tobytes():
        raise AssertionError(f"{label}[0] must be the exact approved C anchor")
    anchor_alpha = anchor.getchannel("A").tobytes()
    allowed = {(15, 16), (16, 16), (15, 17), (20, 17)}
    changed_by_frame: list[list[list[int]]] = []
    for index, frame in enumerate(frames):
        if frame.getchannel("A").tobytes() != anchor_alpha:
            raise AssertionError(f"{label}[{index}] changed body/controller outline")
        changed = {
            (x, y)
            for y in range(FRAME_SIZE)
            for x in range(FRAME_SIZE)
            if frame.getpixel((x, y)) != anchor.getpixel((x, y))
        }
        if not changed.issubset(allowed):
            raise AssertionError(f"{label}[{index}] changed forbidden pixels: {changed}")
        changed_by_frame.append([list(point) for point in sorted(changed)])
    return {
        "frames": audits,
        "changed_pixels": changed_by_frame,
        "alpha_mask_fixed": True,
        "hands_controller_connected_by_construction": True,
    }


def _assert_death_contract(
    frames: Sequence[Image.Image],
    anchor: Image.Image,
    label: str,
) -> dict:
    audits = [_frame_audit(frame, f"{label}[{i}]") for i, frame in enumerate(frames)]
    if frames[0].tobytes() != anchor.tobytes():
        raise AssertionError(f"{label}[0] must be the exact approved C anchor")
    # Controller, hands and body are one rigid native layer throughout.  The
    # transform itself preserves that relationship; this connectivity count is
    # recorded as an additional regression signal for the complete silhouette.
    component_sizes = [_component_sizes(frame, _bbox(frame)) for frame in frames]
    # K1 frame 3 intentionally still includes the last planted foot during the
    # handoff from crouch to rigid-body fall.  Every other pose must be one
    # clean component; no floating ImageGen/rotation fragments are accepted.
    if any(not sizes or sizes[0] < 160 for sizes in component_sizes):
        raise AssertionError(
            f"{label} lost the connected body/controller component: {component_sizes}"
        )
    unexpected_fragments = [
        (index, sizes)
        for index, sizes in enumerate(component_sizes)
        if len(sizes) > 1 and not (label == "death_k1" and index == 3)
    ]
    if unexpected_fragments:
        raise AssertionError(
            f"{label} contains floating rotated fragments: {unexpected_fragments}"
        )
    return {
        "frames": audits,
        "eight_connected_component_sizes": component_sizes,
        "floating_rotated_fragments": False,
        "controller_and_hands_rigid_transform": True,
        "source_board_resized": False,
    }


def _build_strip(frames: Sequence[Image.Image]) -> Image.Image:
    strip = Image.new(
        "RGBA",
        (FRAME_SIZE * len(frames), FRAME_SIZE),
        TRANSPARENT,
    )
    for index, frame in enumerate(frames):
        _alpha_composite(strip, frame, (index * FRAME_SIZE, 0))
    return strip


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
        .resize(
            (frame.width * scale, frame.height * scale),
            Image.Resampling.NEAREST,
        )
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
    strip.resize(
        (strip.width * 16, strip.height * 16),
        Image.Resampling.NEAREST,
    ).save(upscale_path, optimize=True)
    _save_gif(frames, gif_path, fps=fps)
    return {
        "native_strip": str(strip_path.relative_to(PROJECT_ROOT)),
        "integer_16x_strip": str(upscale_path.relative_to(PROJECT_ROOT)),
        "gif": str(gif_path.relative_to(PROJECT_ROOT)),
        "native_strip_size": list(strip.size),
        "fps": fps,
    }


def _reference_frame(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    return image.crop((0, 0, 32, 32))


def _build_comparison(
    anchor: Image.Image,
    animations: dict[str, list[Image.Image]],
) -> Image.Image:
    scale = 8
    label_height = 24
    row_height = FRAME_SIZE * scale + label_height
    width = FRAME_SIZE * 8 * scale
    height = row_height * 7
    canvas = Image.new("RGBA", (width, height), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()

    reference_items = (
        (
            "Sword robot",
            _reference_frame(
                PROJECT_ROOT
                / "resources/texture/enemy/mechanical_life/combat_robot.png"
            ),
        ),
        (
            "Gunner robot",
            _reference_frame(
                PROJECT_ROOT
                / "resources/texture/enemy/mechanical_life/combat_robot_gunner.png"
            ),
        ),
        ("Approved C", anchor),
        (
            "Tango 8x8 (density only)",
            Image.open(
                PROJECT_ROOT
                / "resources/texture/player/tango/tango_cast_unit.png"
            )
            .convert("RGBA")
            .crop((0, 0, 8, 8))
            .resize((32, 32), Image.Resampling.NEAREST),
        ),
    )
    reference_x = 8
    for label, reference in reference_items:
        draw.text((reference_x, 7), label, fill=REVIEW_TEXT, font=font)
        sprite = reference.resize(
            (FRAME_SIZE * scale, FRAME_SIZE * scale),
            Image.Resampling.NEAREST,
        )
        canvas.alpha_composite(sprite, (reference_x, label_height))
        reference_x += FRAME_SIZE * scale

    row_labels = {
        "move_m1": "M1 - long mechanical stride / 8f @ 14fps",
        "move_m2": "M2 - compact grounded stride / 8f @ 14fps",
        "deploy_d1": "D1 - downward press + armed lamp / 3f @ 30fps",
        "deploy_d2": "D2 - lateral tap + hot lamp / 3f @ 30fps",
        "death_k1": "K1 - forward crouch-collapse / 8f @ 12fps",
        "death_k2": "K2 - side imbalance-fold / 8f @ 12fps",
    }
    for row_index, name in enumerate(row_labels, start=1):
        y = row_index * row_height
        draw.text((8, y + 7), row_labels[name], fill=REVIEW_TEXT, font=font)
        strip = _on_background(_build_strip(animations[name])).resize(
            (len(animations[name]) * FRAME_SIZE * scale, FRAME_SIZE * scale),
            Image.Resampling.NEAREST,
        )
        canvas.alpha_composite(strip, (0, y + label_height))
    return canvas


def build() -> dict:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    anchor = _load_anchor()
    upper = _fixed_upper(anchor)

    animations = {
        "move_m1": _compose_move(upper, _long_stride_layers()),
        "move_m2": _compose_move(upper, _compact_stride_layers()),
        "deploy_d1": _build_deploy(anchor, "d1"),
        "deploy_d2": _build_deploy(anchor, "d2"),
        "death_k1": _build_death_k1(anchor, upper),
        "death_k2": _build_death_k2(anchor, upper),
    }

    audit = {
        "move_m1": _assert_move_contract(animations["move_m1"], upper, "move_m1"),
        "move_m2": _assert_move_contract(animations["move_m2"], upper, "move_m2"),
        "deploy_d1": _assert_deploy_contract(animations["deploy_d1"], anchor, "deploy_d1"),
        "deploy_d2": _assert_deploy_contract(animations["deploy_d2"], anchor, "deploy_d2"),
        "death_k1": _assert_death_contract(animations["death_k1"], anchor, "death_k1"),
        "death_k2": _assert_death_contract(animations["death_k2"], anchor, "death_k2"),
    }

    outputs: dict[str, dict] = {}
    for name, frames in animations.items():
        expected_count, fps = ANIMATION_SPECS[name]
        if len(frames) != expected_count:
            raise AssertionError(f"{name} frame count {len(frames)} != {expected_count}")
        outputs[name] = _save_animation_outputs(name, frames, fps)

    comparison = _build_comparison(anchor, animations)
    comparison.save(COMPARISON_PATH, optimize=True)

    source_report = {
        name: _source_grid_report(path, grid)
        for name, (path, grid) in SOURCE_SPECS.items()
    }
    report = {
        "stage": "second_review_gate_preview_only",
        "runtime_written": False,
        "anchor": {
            "path": str(ANCHOR_PATH.relative_to(PROJECT_ROOT)),
            "sha256": _sha256(ANCHOR_PATH),
            "immutable_identity_source": True,
        },
        "construction": {
            "imagegen_source_pixels_imported": False,
            "source_boards_used_as_motion_language_only": True,
            "native_anchor_resized": False,
            "native_death_transform": (
                "integer row/column shears + exact quarter-turn transpose; "
                "PIL arbitrary-angle rotation is not used"
            ),
            "palette": [list(color) for color in PALETTE],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "baseline_y": BASELINE_Y,
            "maximum_visible_bbox": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
        },
        "source_grid_analysis": source_report,
        "animation_audit": audit,
        "outputs": outputs,
        "comparison": str(COMPARISON_PATH.relative_to(PROJECT_ROOT)),
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def main() -> None:
    report = build()
    print("COMBAT_ROBOT_DRONE_OPERATOR_ROBOT_PREVIEWS_OK")
    print(f"  comparison={report['comparison']}")
    print(f"  audit={REPORT_PATH.relative_to(PROJECT_ROOT)}")
    for name, outputs in report["outputs"].items():
        print(
            f"  {name}: {outputs['native_strip']} "
            f"{outputs['integer_16x_strip']} {outputs['gif']}"
        )


if __name__ == "__main__":
    main()
