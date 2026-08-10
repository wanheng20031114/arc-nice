#!/usr/bin/env python3
"""Build review/runtime sprites for the combat-robot gunner.

The approved native anchor is the immutable identity source.  Independently
generated ImageGen boards contribute animation language only:

* M2 contributes the first four authored gait silhouettes; the opposite half
  cycle is mirrored around the two hip mounts.
* F2 contributes the recoil cadence, while the approved anchor supplies every
  rigid upper-body pixel.
* D1 contributes the progressive forward-collapse silhouettes.
* B2 contributes the compact dark-red / hot-core projectile language.

No high-resolution ImageGen board is ordinarily downscaled.  Each cell is
green-keyed, inspected with ``pixel_grid_analyzer``, and sampled once at its
detected shared logical grid.  The approved 32px anchor is never rescaled.

By default this script writes only review artifacts under
``dev_assets/generated_previews``.  ``--write-runtime`` additionally writes the
two production textures after the review gate has been approved.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from statistics import median
from typing import Iterable

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_gunner"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"

ANCHOR_PATH = SOURCE_DIR / "combat_robot_gunner_anchor_b_native32.png"
MOVE_SOURCE_PATH = SOURCE_DIR / "combat_robot_gunner_move_m2_imagegen.png"
FIRE_SOURCE_PATH = SOURCE_DIR / "combat_robot_gunner_fire_f2_imagegen.png"
DEATH_SOURCE_PATH = SOURCE_DIR / "combat_robot_gunner_death_d1_imagegen.png"
BULLET_SOURCE_PATH = SOURCE_DIR / "combat_robot_gunner_bullet_b2_imagegen.png"

RUNTIME_TEXTURE_DIR = (
    PROJECT_ROOT / "resources/texture/enemy/mechanical_life"
)
RUNTIME_SHEET_PATH = RUNTIME_TEXTURE_DIR / "combat_robot_gunner.png"
RUNTIME_BULLET_PATH = (
    RUNTIME_TEXTURE_DIR / "combat_robot_gunner_bullet.png"
)

FRAME_SIZE = 32
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
ANCHOR_SHIFT_X = 4
ANCHOR_ANTENNA_CENTER_X = 13
HIP_LEFT_X = 13
HIP_RIGHT_X = 18
LEG_TOP_Y = 22
LEG_BOTTOM_Y = 28
MUZZLE_X = 30
MUZZLE_Y = 17

MOVE_SOURCE_GRID = (4, 2)
FIRE_SOURCE_GRID = (4, 1)
DEATH_SOURCE_GRID = (4, 2)
BULLET_SOURCE_GRID = (3, 1)

SHEET_PATH = PREVIEW_DIR / "combat_robot_gunner_sheet_candidate.png"
BULLET_PATH = PREVIEW_DIR / "combat_robot_gunner_bullet_candidate.png"
UPSCALED_SHEET_PATH = PREVIEW_DIR / "combat_robot_gunner_sheet_candidate_4x.png"
COMPARISON_PATH = PREVIEW_DIR / "combat_robot_gunner_comparison.png"
MOVE_GIF_PATH = PREVIEW_DIR / "combat_robot_gunner_move.gif"
FIRE_GIF_PATH = PREVIEW_DIR / "combat_robot_gunner_fire.gif"
DEATH_GIF_PATH = PREVIEW_DIR / "combat_robot_gunner_death.gif"
BULLET_GIF_PATH = PREVIEW_DIR / "combat_robot_gunner_bullet.gif"
REPORT_PATH = enemy_asset_report_path("combat_robot_gunner_asset_build_report.json")

TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
ATTACK_ALERT_RED = (255, 0, 0, 255)
ATTACK_ALERT_POINTS = (
    (13, 5),
    (15, 11),
    (16, 11),
    (17, 11),
    (15, 12),
    (16, 12),
    (17, 12),
)


def _green_key(image: Image.Image) -> Image.Image:
    """Remove the requested green screen and normalize binary transparency."""
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


def _split_keyed_board(
    source_path: Path,
    columns: int,
    rows: int,
) -> list[Image.Image]:
    keyed = _green_key(Image.open(source_path))
    cells: list[Image.Image] = []
    for row in range(rows):
        top, bottom = _cell_bounds(keyed.height, rows, row)
        for column in range(columns):
            left, right = _cell_bounds(keyed.width, columns, column)
            cell = keyed.crop((left, top, right, bottom))
            bbox = cell.getchannel("A").getbbox()
            if bbox is None:
                raise ValueError(
                    f"{source_path.name} cell ({column},{row}) is empty after keying"
                )
            cells.append(cell.crop(bbox))
    return cells


def _extract_logical_frames(
    source_path: Path,
    grid: tuple[int, int],
    shared_grid_override: tuple[float, float] | None = None,
) -> tuple[list[Image.Image], list[dict]]:
    """Sample every cell at one shared, analyzer-detected logical grid."""
    cells = _split_keyed_board(source_path, grid[0], grid[1])
    analyses = [analyze_image(cell) for cell in cells]
    unsafe = [
        index
        for index, analysis in enumerate(analyses)
        if analysis["detection_mode"] == "native_or_unknown"
        or float(analysis["confidence"]) < 0.65
    ]
    if unsafe and shared_grid_override is None:
        raise ValueError(
            f"{source_path.name} has unsafe logical-grid cells {unsafe}; "
            "regenerate instead of forcing a resize"
        )

    if shared_grid_override is None:
        shared_grid_width = median(
            float(analysis["grid_cell_width"]) for analysis in analyses
        )
        shared_grid_height = median(
            float(analysis["grid_cell_height"]) for analysis in analyses
        )
    else:
        shared_grid_width, shared_grid_height = shared_grid_override
    frames: list[Image.Image] = []
    report: list[dict] = []
    for index, (cell, analysis) in enumerate(zip(cells, analyses)):
        logical_width = max(1, round(cell.width / shared_grid_width))
        logical_height = max(1, round(cell.height / shared_grid_height))
        logical = cell.resize(
            (logical_width, logical_height),
            Image.Resampling.NEAREST,
        )
        logical = snap_palette(logical)
        frames.append(logical)
        report.append(
            {
                "frame": index,
                "source_crop": [cell.width, cell.height],
                "logical_size": [logical.width, logical.height],
                "grid_width": float(analysis["grid_cell_width"]),
                "grid_height": float(analysis["grid_cell_height"]),
                "confidence": float(analysis["confidence"]),
                "detection_mode": analysis["detection_mode"],
            }
        )
    for item in report:
        item["shared_grid_width"] = shared_grid_width
        item["shared_grid_height"] = shared_grid_height
    return frames, report


def _paste_alpha(destination: Image.Image, source: Image.Image, xy: tuple[int, int]) -> None:
    destination.alpha_composite(source, xy)


def _translate(image: Image.Image, offset_x: int, offset_y: int = 0) -> Image.Image:
    result = Image.new("RGBA", image.size, TRANSPARENT)
    _paste_alpha(result, image, (offset_x, offset_y))
    return result


def _build_aligned_anchor() -> Image.Image:
    anchor = snap_palette(Image.open(ANCHOR_PATH).convert("RGBA"))
    if anchor.size != (FRAME_SIZE, FRAME_SIZE):
        raise ValueError(f"Approved anchor must be 32x32, got {anchor.size}")
    aligned = _translate(anchor, ANCHOR_SHIFT_X)
    if aligned.getchannel("A").getbbox() != (10, 4, 30, 28):
        raise AssertionError(
            f"Unexpected aligned B bbox: {aligned.getchannel('A').getbbox()}"
        )
    return aligned


def _build_fixed_upper(anchor: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Remove only the two standing legs, retaining the gun magazine."""
    result = anchor.copy()
    magazine = anchor.crop((20, 20, 22, 23))
    result.paste(TRANSPARENT, (10, LEG_TOP_Y, 21, LEG_BOTTOM_Y))
    _paste_alpha(result, magazine, (20, 20))
    return result, magazine


def _antenna_center(frame: Image.Image) -> float:
    alpha = np.asarray(frame.getchannel("A"))
    ys, xs = np.nonzero(alpha[: min(5, frame.height), :] > 0)
    if xs.size == 0:
        raise ValueError("Move source lost its antenna registration mark")
    return float(np.median(xs))


def _extract_authored_leg_layer(source: Image.Image) -> Image.Image:
    """Retarget one M2 leg phase into B's six-row leg budget.

    M2's generated legs are eight logical rows tall while approved B uses six.
    We center-sample that limb-only band once, leaving the rigid upper untouched.
    """
    band_height = min(8, source.height)
    band = source.crop((0, source.height - band_height, source.width, source.height))
    band = band.resize((band.width, LEG_BOTTOM_Y - LEG_TOP_Y), Image.Resampling.NEAREST)

    # Remove the generated gun/magazine from the lower band.  The antenna gives
    # a stable chassis registration even when a foot extends the source bbox.
    antenna_center = _antenna_center(source)
    maximum_leg_x = math.floor(antenna_center + 8)
    band_pixels = band.load()
    for y in range(band.height):
        for x in range(band.width):
            if x > maximum_leg_x:
                band_pixels[x, y] = TRANSPARENT

    runtime = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    offset_x = round(ANCHOR_ANTENNA_CENTER_X - antenna_center)
    _paste_alpha(runtime, band, (offset_x, LEG_TOP_Y))

    # Keep limb pixels inside the body/foot corridor.  This trims only source
    # gutter drift, never the approved upper or an authored joint.
    pixels = runtime.load()
    for y in range(LEG_TOP_Y, LEG_BOTTOM_Y):
        for x in range(FRAME_SIZE):
            if x < 9 or x > 22:
                pixels[x, y] = TRANSPARENT
    return runtime


def _mirror_leg_layer(layer: Image.Image) -> Image.Image:
    """Mirror legs around x=15.5 without mirroring the gunner's upper body."""
    result = Image.new("RGBA", layer.size, TRANSPARENT)
    source = layer.load()
    destination = result.load()
    for y in range(LEG_TOP_Y, LEG_BOTTOM_Y):
        for x in range(FRAME_SIZE):
            mirrored_x = 31 - x
            if source[x, y][3] > 0:
                destination[mirrored_x, y] = source[x, y]
    return result


def _draw_bridge(
    image: Image.Image,
    start: tuple[int, int],
    end: tuple[int, int],
    color: tuple[int, int, int, int] = PALETTE[0],
) -> None:
    ImageDraw.Draw(image).line((start, end), fill=color, width=1)


def _connect_leg_mounts(layer: Image.Image) -> None:
    alpha = np.asarray(layer.getchannel("A"))
    for hip_x in (HIP_LEFT_X, HIP_RIGHT_X):
        candidates: list[tuple[int, int, int]] = []
        for y in range(LEG_TOP_Y, min(LEG_TOP_Y + 3, LEG_BOTTOM_Y)):
            for x in range(max(0, hip_x - 3), min(FRAME_SIZE, hip_x + 4)):
                if alpha[y, x] > 0:
                    candidates.append((abs(x - hip_x) + y - LEG_TOP_Y, x, y))
        if not candidates:
            continue
        _distance, target_x, target_y = min(candidates)
        _draw_bridge(layer, (hip_x, LEG_TOP_Y), (target_x, target_y))


def _draw_leg(
    layer: Image.Image,
    hip: tuple[int, int],
    knee: tuple[int, int],
    ankle: tuple[int, int],
    foot: tuple[int, int],
    foot_bottom_y: int,
    role: str,
    foot_shape: str = "ground",
) -> None:
    """Trace one M2-derived mechanical leg on B's native six-row lattice."""
    if role == "front":
        outline = PALETTE[0]
        joint = PALETTE[4]
        foot_fill = PALETTE[5]
    else:
        outline = PALETTE[1]
        joint = PALETTE[2]
        foot_fill = PALETTE[3]
    draw = ImageDraw.Draw(layer)
    draw.line((hip, knee, ankle), fill=outline, width=1)
    draw.point(knee, fill=joint)
    left, right = foot
    if foot_shape == "toe":
        draw.line((left, foot_bottom_y - 1, right, foot_bottom_y - 1), fill=outline)
        draw.line((right - 1, foot_bottom_y, right, foot_bottom_y), fill=outline)
        draw.point((right - 1, foot_bottom_y - 1), fill=foot_fill)
    else:
        draw.rectangle((left, foot_bottom_y - 1, right, foot_bottom_y), fill=outline)
        if right - left >= 2:
            draw.line(
                (left + 1, foot_bottom_y - 1, right - 1, foot_bottom_y - 1),
                fill=foot_fill,
            )


def _build_stable_leg_layers() -> list[Image.Image]:
    """Retarget M2's contact/down/pass/up cadence without its scale flicker."""
    # First half-cycle.  The second half is an exact lower-body mirror around
    # x=15.5, so the loop has mechanically balanced stride lengths.
    phases = (
        # contact A: both feet land at opposite stride extremes
        (
            ((13, 22), (13, 24), (12, 25), (10, 14), 27, "back", "ground"),
            ((18, 22), (18, 24), (19, 25), (18, 22), 27, "front", "ground"),
        ),
        # down A: the rear heel lifts while the forward leg carries weight
        (
            ((13, 22), (12, 24), (12, 25), (10, 13), 27, "back", "toe"),
            ((18, 22), (17, 24), (18, 25), (16, 20), 27, "front", "ground"),
        ),
        # passing A: the rear foot folds below the hips, one pixel off ground
        (
            ((13, 22), (14, 24), (15, 25), (14, 17), 26, "back", "ground"),
            ((18, 22), (17, 24), (17, 25), (15, 19), 27, "front", "ground"),
        ),
        # up A: the folded leg swings forward before the opposite contact
        (
            ((13, 22), (15, 24), (17, 25), (16, 20), 26, "back", "ground"),
            ((18, 22), (16, 24), (15, 25), (13, 17), 27, "front", "ground"),
        ),
    )
    authored: list[Image.Image] = []
    for phase in phases:
        layer = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
        # Back leg is intentionally painted first; crossing phases retain a
        # readable front shin instead of alternating draw order/flicker.
        for specification in phase:
            _draw_leg(layer, *specification)
        authored.append(layer)
    return authored + [_mirror_leg_layer(layer) for layer in authored]


def _build_move_frames(
    fixed_upper: Image.Image,
    magazine: Image.Image,
    move_sources: list[Image.Image],
) -> tuple[list[Image.Image], list[Image.Image]]:
    if len(move_sources) != 8:
        raise ValueError(f"M2 must supply eight move phases, got {len(move_sources)}")
    legs = _build_stable_leg_layers()
    frames: list[Image.Image] = []
    for layer in legs:
        _connect_leg_mounts(layer)
        frame = fixed_upper.copy()
        _paste_alpha(frame, layer, (0, 0))
        _paste_alpha(frame, magazine, (20, 20))
        frames.append(snap_palette(frame))
    return frames, legs


def _build_recoil_upper(fixed_upper: Image.Image) -> Image.Image:
    """Move only authored arms/gun one pixel backward; keep the box immutable."""
    recoil = fixed_upper.copy()
    moving = Image.new("RGBA", recoil.size, TRANSPARENT)
    source_pixels = recoil.load()
    moving_pixels = moving.load()
    for y in range(13, 23):
        for x in range(FRAME_SIZE):
            is_rear_arm = x == 10 and y <= 19
            # x=20 and the y=20..21 pelvis/magazine junction stay fixed.  That
            # one-pixel overlap hides the layer seam while every exposed gun
            # pixel still recoils exactly one pixel.
            is_forward_arm_or_gun = x >= 21 and y <= 19
            if (is_rear_arm or is_forward_arm_or_gun) and source_pixels[x, y][3] > 0:
                moving_pixels[x, y] = source_pixels[x, y]
                source_pixels[x, y] = TRANSPARENT
    _paste_alpha(recoil, moving, (-1, 0))
    return recoil


def _add_muzzle_flash(upper: Image.Image, alternate: bool) -> Image.Image:
    flashed = upper.copy()
    pixels = flashed.load()
    if alternate:
        colors = (PALETTE[10], PALETTE[11], PALETTE[9], PALETTE[10])
    else:
        colors = (PALETTE[11], PALETTE[10], PALETTE[10], PALETTE[9])
    pixels[30, 16], pixels[31, 16], pixels[30, 17], pixels[31, 17] = colors
    return flashed


def _build_fire_matrix(
    fixed_upper: Image.Image,
    magazine: Image.Image,
    leg_layers: list[Image.Image],
) -> tuple[list[list[Image.Image]], list[Image.Image]]:
    base_upper = fixed_upper.copy()
    _paste_alpha(base_upper, magazine, (20, 20))
    recoil_upper = _build_recoil_upper(base_upper)
    upper_phases = [
        _add_muzzle_flash(base_upper, alternate=False),
        recoil_upper,
        _add_muzzle_flash(base_upper, alternate=True),
        recoil_upper.copy(),
    ]
    matrix: list[list[Image.Image]] = []
    for upper in upper_phases:
        row: list[Image.Image] = []
        for legs in leg_layers:
            frame = upper.copy()
            _paste_alpha(frame, legs, (0, 0))
            row.append(snap_palette(frame))
        matrix.append(row)
    return matrix, upper_phases


def _apply_reviewed_fire_edits(fire_matrix: list[list[Image.Image]]) -> None:
    """Preserve the reviewed bright attack signal and three repaired edges."""
    for upper_index in (0, 2):
        for frame in fire_matrix[upper_index]:
            pixels = frame.load()
            for point in ATTACK_ALERT_POINTS:
                if pixels[point] != PALETTE[8]:
                    raise ValueError(f"Attack alert source pixel changed at {point}")
                pixels[point] = ATTACK_ALERT_RED

    for leg_index in range(3):
        pixels = fire_matrix[1][leg_index].load()
        for y in range(13, 19):
            if pixels[9, y] != PALETTE[0] or pixels[10, y] != TRANSPARENT:
                raise ValueError(
                    f"Reviewed fire edge source changed at leg={leg_index}, y={y}"
                )
            pixels[9, y] = TRANSPARENT
            pixels[10, y] = PALETTE[0]


def _largest_eroded_center(image: Image.Image) -> tuple[float, float]:
    """Locate the generated death frame's thick rotated box."""
    eroded = image.getchannel("A").filter(ImageFilter.MinFilter(5))
    mask = np.asarray(eroded) > 0
    height, width = mask.shape
    seen = np.zeros(mask.shape, dtype=bool)
    components: list[list[tuple[int, int]]] = []
    for start_y in range(height):
        for start_x in range(width):
            if not mask[start_y, start_x] or seen[start_y, start_x]:
                continue
            pending = [(start_x, start_y)]
            seen[start_y, start_x] = True
            points: list[tuple[int, int]] = []
            while pending:
                x, y = pending.pop()
                points.append((x, y))
                for next_y in range(max(0, y - 1), min(height, y + 2)):
                    for next_x in range(max(0, x - 1), min(width, x + 2)):
                        if mask[next_y, next_x] and not seen[next_y, next_x]:
                            seen[next_y, next_x] = True
                            pending.append((next_x, next_y))
            components.append(points)
    if not components:
        bbox = image.getchannel("A").getbbox()
        if bbox is None:
            raise ValueError("Empty death frame")
        return ((bbox[0] + bbox[2] - 1) * 0.5, (bbox[1] + bbox[3] - 1) * 0.5)
    core = max(components, key=len)
    return (
        (min(x for x, _y in core) + max(x for x, _y in core)) * 0.5,
        (min(y for _x, y in core) + max(y for _x, y in core)) * 0.5,
    )


def _build_crouch_frame(fixed_upper: Image.Image, magazine: Image.Image) -> Image.Image:
    frame = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    _paste_alpha(frame, fixed_upper, (0, 1))
    # Compact knees: feet remain planted while the rigid upper settles by 1px.
    draw = ImageDraw.Draw(frame)
    draw.line(((HIP_LEFT_X, 23), (12, 25)), fill=PALETTE[0], width=1)
    draw.line(((12, 25), (11, 26)), fill=PALETTE[2], width=1)
    draw.rectangle((10, 26, 14, 27), fill=PALETTE[0])
    draw.rectangle((11, 26, 13, 26), fill=PALETTE[5])
    draw.line(((HIP_RIGHT_X, 23), (19, 25)), fill=PALETTE[0], width=1)
    draw.rectangle((17, 26, 21, 27), fill=PALETTE[0])
    draw.rectangle((18, 26, 20, 26), fill=PALETTE[5])
    _paste_alpha(frame, magazine, (20, 21))
    return snap_palette(frame)


def _place_death_source(source: Image.Image, target_core_x: float) -> Image.Image:
    # D1's settled frame has one redundant rear-most column (two outline
    # pixels) while the forward gun edge carries three connected pixels.  Trim
    # that rear column rather than fitting/scaling the entire pose.
    if source.width == MAX_VISIBLE_SIZE + 1:
        source = source.crop((1, 0, source.width, source.height))
    if source.width > MAX_VISIBLE_SIZE or source.height > MAX_VISIBLE_SIZE:
        raise ValueError(
            f"Authored death pose {source.size} exceeds {MAX_VISIBLE_SIZE}px; "
            "regenerate or tighten the pose instead of shrinking it"
        )
    source_core_x, _source_core_y = _largest_eroded_center(source)
    paste_x = round(target_core_x - source_core_x)
    paste_y = BASELINE_Y - source.height
    paste_x = max(0, min(FRAME_SIZE - source.width, paste_x))
    frame = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    _paste_alpha(frame, source, (paste_x, paste_y))
    return snap_palette(frame)


def _build_death_frames(
    aligned_anchor: Image.Image,
    fixed_upper: Image.Image,
    magazine: Image.Image,
    death_sources: list[Image.Image],
) -> list[Image.Image]:
    if len(death_sources) != 8:
        raise ValueError(f"D1 must supply eight death phases, got {len(death_sources)}")
    frames = [aligned_anchor.copy(), _build_crouch_frame(fixed_upper, magazine)]
    target_core_x = (16.0, 16.5, 17.0, 17.5, 18.0, 18.5)
    for source, target_x in zip(death_sources[2:], target_core_x):
        frames.append(_place_death_source(source, target_x))
    return frames


def _build_bullet_sheet() -> tuple[Image.Image, list[Image.Image]]:
    """Enforce the approved 9x3 identical silhouette from B2's color language."""
    sheet = Image.new("RGBA", (36, 8), TRANSPARENT)
    frames: list[Image.Image] = []
    core_positions = (5, 7, 9)
    for index, core_x in enumerate(core_positions):
        frame = Image.new("RGBA", (12, 8), TRANSPARENT)
        pixels = frame.load()
        for x in range(2, 11):
            pixels[x, 3] = PALETTE[8]
            pixels[x, 4] = PALETTE[9]
            pixels[x, 5] = PALETTE[8]
        pixels[core_x, 4] = PALETTE[11]
        if core_x - 1 >= 2:
            pixels[core_x - 1, 4] = PALETTE[10]
        frames.append(frame)
        _paste_alpha(sheet, frame, (index * 12, 0))
    return sheet, frames


def _alpha_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Unexpected empty frame")
    return bbox


def _visible_colors(image: Image.Image) -> set[tuple[int, int, int, int]]:
    return {pixel for pixel in image.getdata() if pixel[3] > 0}


def _assert_frame_contract(frame: Image.Image, label: str) -> None:
    bbox = _alpha_bbox(frame)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label} bbox {bbox} exceeds 28x28")
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"{label} bbox {bbox} misses baseline y=28")
    alphas = set(frame.getchannel("A").getdata())
    if not alphas.issubset({0, 255}):
        raise AssertionError(f"{label} contains non-binary alpha: {sorted(alphas)}")
    if not _visible_colors(frame).issubset(set(PALETTE) | {ATTACK_ALERT_RED}):
        raise AssertionError(f"{label} contains colors outside the fixed palette")
    for red, green, blue, alpha in frame.getdata():
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} has dirty transparent RGB")


def _assert_contracts(
    aligned_anchor: Image.Image,
    move_frames: list[Image.Image],
    fire_matrix: list[list[Image.Image]],
    death_frames: list[Image.Image],
    bullet_frames: list[Image.Image],
) -> None:
    for index, frame in enumerate(move_frames):
        _assert_frame_contract(frame, f"move[{index}]")
    for upper_index, row in enumerate(fire_matrix):
        for leg_index, frame in enumerate(row):
            _assert_frame_contract(frame, f"fire[{upper_index}][{leg_index}]")
    for index, frame in enumerate(death_frames):
        _assert_frame_contract(frame, f"death[{index}]")

    fixed_regions = []
    for frame in move_frames:
        fixed = frame.copy()
        fixed.paste(TRANSPARENT, (9, LEG_TOP_Y, 23, LEG_BOTTOM_Y))
        fixed_regions.append(fixed.tobytes())
    if len(set(fixed_regions)) != 1:
        raise AssertionError("Move upper body is not byte-identical across frames")

    leg_masks = []
    for frame in move_frames:
        leg_masks.append(frame.crop((9, LEG_TOP_Y, 23, LEG_BOTTOM_Y)).getchannel("A").tobytes())
    if len(set(leg_masks)) != 8:
        raise AssertionError("Move must contain eight unique leg silhouettes")

    if death_frames[0].tobytes() != aligned_anchor.tobytes():
        raise AssertionError("death[0] must exactly equal approved aligned anchor B")

    expected_flash = {(30, 16), (31, 16), (30, 17), (31, 17)}
    for upper_index, row in enumerate(fire_matrix):
        for frame in row:
            alert_points = {
                (x, y)
                for y in range(frame.height)
                for x in range(frame.width)
                if frame.getpixel((x, y)) == ATTACK_ALERT_RED
            }
            expected_alert = (
                set(ATTACK_ALERT_POINTS) if upper_index in (0, 2) else set()
            )
            if alert_points != expected_alert:
                raise AssertionError(
                    f"Fire F{upper_index} attack alert pixels differ: "
                    f"{sorted(alert_points)}"
                )
            visible_flash = {
                (x, y)
                for y in range(16, 18)
                for x in range(30, 32)
                if frame.getpixel((x, y))[3] > 0
            }
            if upper_index in (0, 2) and visible_flash != expected_flash:
                raise AssertionError(f"Fire F{upper_index} lost its exact 2x2 flash")
            if upper_index in (1, 3) and visible_flash:
                raise AssertionError(f"Fire F{upper_index} unexpectedly contains flash")

    alpha_masks = []
    core_centers = []
    for index, frame in enumerate(bullet_frames):
        bbox = _alpha_bbox(frame)
        if bbox != (2, 3, 11, 6):
            raise AssertionError(f"bullet[{index}] bbox {bbox} is not strict 9x3")
        alpha_masks.append(frame.getchannel("A").tobytes())
        hot_x = [
            x
            for y in range(frame.height)
            for x in range(frame.width)
            if frame.getpixel((x, y)) == PALETTE[11]
        ]
        core_centers.append(sum(hot_x) / len(hot_x))
    if len(set(alpha_masks)) != 1:
        raise AssertionError("Bullet alpha silhouette changes between frames")
    if not core_centers[0] < core_centers[1] < core_centers[2]:
        raise AssertionError("Bullet hot core does not move monotonically forward")


def _build_sheet(
    move_frames: list[Image.Image],
    fire_matrix: list[list[Image.Image]],
    death_frames: list[Image.Image],
) -> Image.Image:
    sheet = Image.new("RGBA", (256, 192), TRANSPARENT)
    for column, frame in enumerate(move_frames):
        _paste_alpha(sheet, frame, (column * FRAME_SIZE, 0))
    for upper_index, row in enumerate(fire_matrix):
        for column, frame in enumerate(row):
            _paste_alpha(sheet, frame, (column * FRAME_SIZE, (upper_index + 1) * FRAME_SIZE))
    for column, frame in enumerate(death_frames):
        _paste_alpha(sheet, frame, (column * FRAME_SIZE, 5 * FRAME_SIZE))
    return sheet


def _on_background(image: Image.Image, color: tuple[int, int, int, int] = REVIEW_BACKGROUND) -> Image.Image:
    result = Image.new("RGBA", image.size, color)
    result.alpha_composite(image)
    return result


def _save_gif(
    frames: Iterable[Image.Image],
    path: Path,
    duration_ms: int,
    scale: int = 8,
) -> None:
    prepared = [
        _on_background(frame).convert("RGB").resize(
            (frame.width * scale, frame.height * scale),
            Image.Resampling.NEAREST,
        )
        for frame in frames
    ]
    prepared[0].save(
        path,
        save_all=True,
        append_images=prepared[1:],
        duration=duration_ms,
        loop=0,
        disposal=2,
        optimize=False,
    )


def _build_comparison(
    aligned_anchor: Image.Image,
    move_frames: list[Image.Image],
    fire_matrix: list[list[Image.Image]],
    death_frames: list[Image.Image],
    bullet_frames: list[Image.Image],
) -> Image.Image:
    combat_robot_sheet = Image.open(
        RUNTIME_TEXTURE_DIR / "combat_robot.png"
    ).convert("RGBA")
    tango_sheet = Image.open(
        PROJECT_ROOT / "resources" / "texture" / "player" / "tango" / "tango_move.png"
    ).convert("RGBA")
    references = [
        ("Robot", combat_robot_sheet.crop((0, 0, 32, 32))),
        ("Tango", tango_sheet.crop((0, 0, 32, 32))),
        ("B anchor", aligned_anchor),
        ("Move", move_frames[0]),
        ("Flash", fire_matrix[0][0]),
        ("Recoil", fire_matrix[1][0]),
        ("Death", death_frames[-1]),
    ]
    scale = 6
    tile_width = 32 * scale + 16
    tile_height = 32 * scale + 36
    canvas = Image.new(
        "RGBA",
        (tile_width * len(references), tile_height + 64),
        REVIEW_BACKGROUND,
    )
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    for index, (label, frame) in enumerate(references):
        x = index * tile_width + 8
        draw.text((x, 8), label, fill=(226, 229, 226, 255), font=font)
        sprite = frame.resize((32 * scale, 32 * scale), Image.Resampling.NEAREST)
        canvas.alpha_composite(sprite, (x, 28))

    bullet_x = 8
    bullet_y = tile_height + 14
    draw.text((bullet_x, bullet_y), "Bullet B2 -> strict 9x3", fill=(226, 229, 226, 255), font=font)
    for index, frame in enumerate(bullet_frames):
        sprite = frame.resize((12 * 8, 8 * 8), Image.Resampling.NEAREST)
        canvas.alpha_composite(sprite, (160 + index * 112, tile_height))
    return canvas


def build(write_runtime: bool = False) -> dict:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)

    move_sources, move_report = _extract_logical_frames(
        MOVE_SOURCE_PATH, MOVE_SOURCE_GRID
    )
    # F2 and B2 are analyzed even though their rigid contracts are rebuilt from
    # B.  This keeps the review traceable to independently generated sources.
    _fire_sources, fire_report = _extract_logical_frames(
        FIRE_SOURCE_PATH, FIRE_SOURCE_GRID
    )
    death_sources, death_report = _extract_logical_frames(
        DEATH_SOURCE_PATH,
        DEATH_SOURCE_GRID,
        # Rotation makes the analyzer mistake the later diagonal outlines for
        # native detail.  D1 frame 1 remains a high-confidence upright sample
        # (10.65x11.25); the reviewed strip-wide lattice is 11.25px square.
        # Applying it to every death cell avoids per-frame fit/compression.
        shared_grid_override=(11.25, 11.25),
    )
    _bullet_sources, bullet_report = _extract_logical_frames(
        BULLET_SOURCE_PATH, BULLET_SOURCE_GRID
    )

    aligned_anchor = _build_aligned_anchor()
    fixed_upper, magazine = _build_fixed_upper(aligned_anchor)
    move_frames, leg_layers = _build_move_frames(
        fixed_upper, magazine, move_sources
    )
    fire_matrix, _upper_phases = _build_fire_matrix(
        fixed_upper, magazine, leg_layers
    )
    _apply_reviewed_fire_edits(fire_matrix)
    death_frames = _build_death_frames(
        aligned_anchor,
        fixed_upper,
        magazine,
        death_sources,
    )
    bullet_sheet, bullet_frames = _build_bullet_sheet()
    _assert_contracts(
        aligned_anchor,
        move_frames,
        fire_matrix,
        death_frames,
        bullet_frames,
    )

    sheet = _build_sheet(move_frames, fire_matrix, death_frames)
    sheet.save(SHEET_PATH, optimize=True)
    bullet_sheet.save(BULLET_PATH, optimize=True)
    _on_background(sheet).resize(
        (sheet.width * 4, sheet.height * 4),
        Image.Resampling.NEAREST,
    ).save(UPSCALED_SHEET_PATH, optimize=True)

    comparison = _build_comparison(
        aligned_anchor,
        move_frames,
        fire_matrix,
        death_frames,
        bullet_frames,
    )
    comparison.save(COMPARISON_PATH, optimize=True)

    _save_gif(move_frames, MOVE_GIF_PATH, duration_ms=71)
    fire_preview_frames: list[Image.Image] = []
    for tick in range(24):
        upper_phase = tick % 4
        leg_phase = math.floor((tick / 25.0) * 7.0) % 8
        fire_preview_frames.append(fire_matrix[upper_phase][leg_phase])
    _save_gif(fire_preview_frames, FIRE_GIF_PATH, duration_ms=40)
    _save_gif(death_frames, DEATH_GIF_PATH, duration_ms=83)
    _save_gif(bullet_frames, BULLET_GIF_PATH, duration_ms=40, scale=16)

    if write_runtime:
        RUNTIME_SHEET_PATH.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(RUNTIME_SHEET_PATH, optimize=True)
        bullet_sheet.save(RUNTIME_BULLET_PATH, optimize=True)

    report = {
        "anchor": str(ANCHOR_PATH.relative_to(PROJECT_ROOT)),
        "anchor_integer_shift": [ANCHOR_SHIFT_X, 0],
        "selected_sources": {
            "move": str(MOVE_SOURCE_PATH.relative_to(PROJECT_ROOT)),
            "fire": str(FIRE_SOURCE_PATH.relative_to(PROJECT_ROOT)),
            "death": str(DEATH_SOURCE_PATH.relative_to(PROJECT_ROOT)),
            "bullet": str(BULLET_SOURCE_PATH.relative_to(PROJECT_ROOT)),
        },
        "source_grid_analysis": {
            "move": move_report,
            "fire": fire_report,
            "death": death_report,
            "bullet": bullet_report,
        },
        "runtime_contract": {
            "sheet_size": list(sheet.size),
            "frame_size": [FRAME_SIZE, FRAME_SIZE],
            "move_frames": 8,
            "fire_matrix_frames": 32,
            "death_frames": 8,
            "baseline_y": BASELINE_Y,
            "max_visible_bbox": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "muzzle_grid": [MUZZLE_X, MUZZLE_Y],
            "bullet_sheet_size": list(bullet_sheet.size),
            "bullet_visible_bbox": [9, 3],
        },
        "outputs": {
            "sheet": str(SHEET_PATH.relative_to(PROJECT_ROOT)),
            "bullet": str(BULLET_PATH.relative_to(PROJECT_ROOT)),
            "sheet_4x": str(UPSCALED_SHEET_PATH.relative_to(PROJECT_ROOT)),
            "comparison": str(COMPARISON_PATH.relative_to(PROJECT_ROOT)),
            "move_gif": str(MOVE_GIF_PATH.relative_to(PROJECT_ROOT)),
            "fire_gif": str(FIRE_GIF_PATH.relative_to(PROJECT_ROOT)),
            "death_gif": str(DEATH_GIF_PATH.relative_to(PROJECT_ROOT)),
            "bullet_gif": str(BULLET_GIF_PATH.relative_to(PROJECT_ROOT)),
        },
        "write_runtime": write_runtime,
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build approved combat-robot-gunner pixel assets"
    )
    parser.add_argument(
        "--write-runtime",
        action="store_true",
        help="also write production textures after the material review gate",
    )
    args = parser.parse_args()
    report = build(write_runtime=args.write_runtime)
    print(
        "COMBAT_ROBOT_GUNNER_ASSET_BUILD_OK "
        f"sheet={report['runtime_contract']['sheet_size']} "
        f"bullet={report['runtime_contract']['bullet_sheet_size']} "
        f"runtime={args.write_runtime}"
    )
    for output in report["outputs"].values():
        print(f"  {output}")


if __name__ == "__main__":
    main()
