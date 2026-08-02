#!/usr/bin/env python3
"""Build review-only drone, marker, and mechanical-explosion candidates.

The ImageGen boards establish silhouette and timing language, but they are not
ordinary-resized into runtime cells.  The drone boards are much denser than the
12x9 contract, and several late explosion cells do not expose a trustworthy
logical grid.  This script therefore constructs every candidate directly on
the final native pixel grid with the approved robot palette.

Outputs are written only to ``dev_assets/generated_previews``.  There is no
runtime-writing option: promotion into ``resources`` remains behind the second
human review gate.
"""

from __future__ import annotations

from collections.abc import Iterable
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_drone_operator"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"

ANCHOR_PATH = (
    SOURCE_DIR / "combat_robot_drone_operator_anchor_c_approved_native32.png"
)
SWORD_ROBOT_REFERENCE_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot.png"
)
GUNNER_ROBOT_REFERENCE_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_gunner.png"
)
TANGO_CAST_REFERENCE_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "player"
    / "tango"
    / "tango_cast_unit.png"
)
DRONE_V1_SOURCE_PATH = (
    SOURCE_DIR / "combat_robot_suicide_drone_fly_v1_imagegen.png"
)
DRONE_V2_SOURCE_PATH = (
    SOURCE_DIR / "combat_robot_suicide_drone_fly_v2_imagegen.png"
)
EXPLOSION_X1_SOURCE_PATH = (
    SOURCE_DIR / "combat_robot_mechanical_explosion_x1_imagegen.png"
)
EXPLOSION_X2_SOURCE_PATH = (
    SOURCE_DIR / "combat_robot_mechanical_explosion_x2_imagegen.png"
)

DRONE_V1_STRIP_PATH = (
    PREVIEW_DIR / "combat_robot_suicide_drone_v1_strip_candidate.png"
)
DRONE_V2_STRIP_PATH = (
    PREVIEW_DIR / "combat_robot_suicide_drone_v2_strip_candidate.png"
)
DRONE_V1_UPSCALED_PATH = (
    PREVIEW_DIR / "combat_robot_suicide_drone_v1_strip_16x.png"
)
DRONE_V2_UPSCALED_PATH = (
    PREVIEW_DIR / "combat_robot_suicide_drone_v2_strip_16x.png"
)
DRONE_V1_GIF_PATH = (
    PREVIEW_DIR / "combat_robot_suicide_drone_v1.gif"
)
DRONE_V2_GIF_PATH = (
    PREVIEW_DIR / "combat_robot_suicide_drone_v2.gif"
)

TARGET_MARKER_PATH = (
    PREVIEW_DIR / "combat_robot_drone_target_marker_candidate.png"
)
TARGET_MARKER_UPSCALED_PATH = (
    PREVIEW_DIR / "combat_robot_drone_target_marker_16x.png"
)

EXPLOSION_X1_STRIP_PATH = (
    PREVIEW_DIR / "combat_robot_mechanical_explosion_x1_strip_candidate.png"
)
EXPLOSION_X2_STRIP_PATH = (
    PREVIEW_DIR / "combat_robot_mechanical_explosion_x2_strip_candidate.png"
)
EXPLOSION_X1_UPSCALED_PATH = (
    PREVIEW_DIR / "combat_robot_mechanical_explosion_x1_strip_4x.png"
)
EXPLOSION_X2_UPSCALED_PATH = (
    PREVIEW_DIR / "combat_robot_mechanical_explosion_x2_strip_4x.png"
)
EXPLOSION_X1_GIF_PATH = (
    PREVIEW_DIR / "combat_robot_mechanical_explosion_x1.gif"
)
EXPLOSION_X2_GIF_PATH = (
    PREVIEW_DIR / "combat_robot_mechanical_explosion_x2.gif"
)

COMPARISON_PATH = (
    PREVIEW_DIR / "combat_robot_drone_operator_drone_fx_comparison.png"
)
REPORT_PATH = (
    PREVIEW_DIR / "combat_robot_drone_operator_drone_fx_preview_report.json"
)

DRONE_CELL_SIZE = 16
DRONE_FRAME_COUNT = 4
DRONE_FPS = 12
DRONE_EXPECTED_BBOX = (2, 3, 14, 12)
DRONE_EXPECTED_VISIBLE_SIZE = (12, 9)

EXPLOSION_CELL_SIZE = 64
EXPLOSION_FRAME_COUNT = 8
EXPLOSION_FPS = 14
EXPLOSION_CENTER = 31.5
EXPLOSION_MAX_DIAMETER = 56

TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
OUTLINE = PALETTE[0]
DEEP_SHADOW = PALETTE[1]
JOINT_SHADOW = PALETTE[2]
DARK_STEEL = PALETTE[3]
MID_STEEL = PALETTE[4]
PLATE_GRAY = PALETTE[5]
PLATE_HIGHLIGHT = PALETTE[6]
ENERGY_WHITE = PALETTE[7]
DEEP_RED = PALETTE[8]
ACTIVE_RED = PALETTE[9]
HOT_ORANGE = PALETTE[10]
HOT_HIGHLIGHT = PALETTE[11]

DRONE_V1_MASK = (
    ".###........",
    "#####.......",
    ".#######....",
    "..#########.",
    "..##########",
    "..#########.",
    ".#######....",
    "#####.......",
    ".###........",
)
DRONE_V2_MASK = (
    "#######.....",
    "#######.....",
    "..########..",
    "...#########",
    "...#########",
    "...#########",
    "..########..",
    "#######.....",
    "#######.....",
)


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _empty(size: tuple[int, int]) -> Image.Image:
    return Image.new("RGBA", size, TRANSPARENT)


def _on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    result.alpha_composite(image)
    return result


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    try:
        return ImageFont.truetype("arial.ttf", size)
    except OSError:
        return ImageFont.load_default()


def _is_green_key(red: np.ndarray, green: np.ndarray, blue: np.ndarray) -> np.ndarray:
    return (
        (green >= 96)
        & (green - red >= 38)
        & (green - blue >= 38)
        & (green >= np.maximum(red, blue) * 1.35)
    )


def _green_key(image: Image.Image) -> Image.Image:
    """Normalize an ImageGen green board for source-grid analysis only."""
    rgb = np.asarray(image.convert("RGB"), dtype=np.int16)
    red = rgb[:, :, 0]
    green = rgb[:, :, 1]
    blue = rgb[:, :, 2]
    keyed = _is_green_key(red, green, blue)
    rgba = np.empty((image.height, image.width, 4), dtype=np.uint8)
    rgba[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    rgba[:, :, 3] = np.where(keyed, 0, 255).astype(np.uint8)
    rgba[keyed, :3] = 0
    return Image.fromarray(rgba, mode="RGBA")


def _cell_bounds(size: int, count: int, index: int) -> tuple[int, int]:
    return round(index * size / count), round((index + 1) * size / count)


def _source_grid_report(
    source_path: Path,
    columns: int,
    rows: int,
    expected_subject_grid: tuple[int, int] | None = None,
) -> dict[str, Any]:
    """Audit the raw board without consuming its pixels in native art."""
    source = Image.open(source_path)
    keyed = _green_key(source)
    cells: list[dict[str, Any]] = []
    for row in range(rows):
        top, bottom = _cell_bounds(keyed.height, rows, row)
        for column in range(columns):
            left, right = _cell_bounds(keyed.width, columns, column)
            cell = keyed.crop((left, top, right, bottom))
            bbox = cell.getchannel("A").getbbox()
            if bbox is None:
                raise AssertionError(
                    f"{source_path.name} cell ({column},{row}) is empty"
                )
            subject = cell.crop(bbox)
            analysis = analyze_image(subject)
            unsafe = (
                analysis["detection_mode"] == "native_or_unknown"
                or float(analysis["confidence"]) < 0.65
            )
            detected_subject_grid = (
                int(analysis["subject_grid_width"]),
                int(analysis["subject_grid_height"]),
            )
            target_contract_mismatch = (
                expected_subject_grid is not None
                and detected_subject_grid != expected_subject_grid
            )
            cells.append(
                {
                    "frame": row * columns + column,
                    "source_cell": [left, top, right, bottom],
                    "subject_bbox_in_cell": list(bbox),
                    "subject_size": list(subject.size),
                    "grid_analysis": analysis,
                    "unsafe_for_automatic_grid_compression": unsafe,
                    "target_contract_mismatch": target_contract_mismatch,
                    "unsafe_for_target_contract": (
                        unsafe or target_contract_mismatch
                    ),
                }
            )
    return {
        "path": _relative(source_path),
        "source_size": list(source.size),
        "source_mode": source.mode,
        "board_grid": [columns, rows],
        "usage": "design_and_timing_language_only",
        "ordinary_resize_into_native_cells": False,
        "expected_subject_grid": (
            list(expected_subject_grid)
            if expected_subject_grid is not None
            else None
        ),
        "cells": cells,
        "unsafe_grid_cells": [
            cell["frame"]
            for cell in cells
            if cell["unsafe_for_automatic_grid_compression"]
        ],
        "target_contract_mismatch_cells": [
            cell["frame"]
            for cell in cells
            if cell["target_contract_mismatch"]
        ],
        "unsafe_for_target_contract_cells": [
            cell["frame"]
            for cell in cells
            if cell["unsafe_for_target_contract"]
        ],
    }


def _mask_points(mask: tuple[str, ...]) -> set[tuple[int, int]]:
    if len(mask) != DRONE_EXPECTED_VISIBLE_SIZE[1]:
        raise AssertionError("Drone mask height must be exactly nine pixels")
    if {len(row) for row in mask} != {DRONE_EXPECTED_VISIBLE_SIZE[0]}:
        raise AssertionError("Drone mask width must be exactly twelve pixels")
    return {
        (x + DRONE_EXPECTED_BBOX[0], y + DRONE_EXPECTED_BBOX[1])
        for y, row in enumerate(mask)
        for x, value in enumerate(row)
        if value == "#"
    }


def _paint_drone_base(mask: tuple[str, ...]) -> Image.Image:
    frame = _empty((DRONE_CELL_SIZE, DRONE_CELL_SIZE))
    points = _mask_points(mask)
    pixels = frame.load()
    for x, y in points:
        pixels[x, y] = OUTLINE

    # Fill only fully enclosed pixels.  This leaves a crisp one-pixel outline
    # independent of which of the two silhouettes is selected.
    for x, y in points:
        if all(
            neighbor in points
            for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1))
        ):
            pixels[x, y] = MID_STEEL

    # Deterministic cold-steel lighting: upper surfaces are lighter, lower
    # surfaces and the rear fuselage are darker.  Accent pixels are applied
    # later and are the only pixels allowed to change between fly frames.
    for x, y in points:
        if pixels[x, y] == OUTLINE:
            continue
        if y <= 6:
            pixels[x, y] = PLATE_GRAY
        elif y >= 9:
            pixels[x, y] = DARK_STEEL
        elif x <= 5:
            pixels[x, y] = JOINT_SHADOW
        else:
            pixels[x, y] = MID_STEEL
    return frame


def _build_drone_frames(
    mask: tuple[str, ...],
    candidate: str,
) -> tuple[list[Image.Image], set[tuple[int, int]]]:
    base = _paint_drone_base(mask)
    if candidate == "v1":
        core = {(7, 7), (8, 7), (7, 8), (8, 8)}
        wing_lights = {(2, 4), (2, 10)}
        fixed_edits = {
            (6, 6): PLATE_HIGHLIGHT,
            (7, 6): PLATE_HIGHLIGHT,
            (9, 6): PLATE_GRAY,
            (10, 7): PLATE_GRAY,
            (11, 7): PLATE_HIGHLIGHT,
            (12, 7): MID_STEEL,
            (9, 8): DARK_STEEL,
            (10, 8): DARK_STEEL,
        }
    elif candidate == "v2":
        core = {(8, 7), (9, 7), (8, 8), (9, 8)}
        wing_lights = {(2, 4), (2, 10)}
        fixed_edits = {
            (4, 4): PLATE_GRAY,
            (5, 4): PLATE_HIGHLIGHT,
            (4, 10): DARK_STEEL,
            (5, 10): JOINT_SHADOW,
            (7, 6): PLATE_HIGHLIGHT,
            (8, 6): PLATE_HIGHLIGHT,
            (10, 7): MID_STEEL,
            (11, 7): PLATE_GRAY,
            (12, 7): PLATE_HIGHLIGHT,
        }
    else:
        raise ValueError(f"Unknown drone candidate {candidate}")

    mask_points = _mask_points(mask)
    if (core | wing_lights | set(fixed_edits)) - mask_points:
        raise AssertionError(f"{candidate} edits escaped its alpha mask")
    for point, color in fixed_edits.items():
        base.putpixel(point, color)

    phase_colors = (
        (DEEP_RED, ACTIVE_RED),
        (ACTIVE_RED, HOT_ORANGE),
        (HOT_ORANGE, HOT_HIGHLIGHT),
        (HOT_HIGHLIGHT, ACTIVE_RED),
    )
    frames: list[Image.Image] = []
    for core_color, wing_color in phase_colors:
        frame = base.copy()
        for point in core:
            frame.putpixel(point, core_color)
        for point in wing_lights:
            frame.putpixel(point, wing_color)
        frames.append(frame)
    return frames, core | wing_lights


def _build_target_marker() -> Image.Image:
    frame = _empty((16, 16))
    pixels = frame.load()
    bracket_points: set[tuple[int, int]] = set()
    for x in range(2, 6):
        bracket_points.add((x, 2))
        bracket_points.add((x, 13))
        bracket_points.add((15 - x, 2))
        bracket_points.add((15 - x, 13))
    for y in range(3, 6):
        bracket_points.add((2, y))
        bracket_points.add((13, y))
        bracket_points.add((2, 15 - y))
        bracket_points.add((13, 15 - y))
    for point in bracket_points:
        pixels[point] = ACTIVE_RED
    # Inner end caps make the four brackets read as a targeting reticle, while
    # the empty gaps ensure this is not mistaken for an explosion-radius ring.
    for point in ((5, 2), (10, 2), (5, 13), (10, 13)):
        pixels[point] = HOT_ORANGE
    for point in ((7, 7), (8, 7), (7, 8), (8, 8)):
        pixels[point] = HOT_ORANGE
    return frame


def _octagonal_distance(x: int, y: int) -> float:
    dx = abs(x - EXPLOSION_CENTER)
    dy = abs(y - EXPLOSION_CENTER)
    return max(dx, dy) + (math.sqrt(2.0) - 1.0) * min(dx, dy)


def _set_explosion_pixel(
    frame: Image.Image,
    x: int,
    y: int,
    color: tuple[int, int, int, int],
) -> None:
    if 0 <= x < EXPLOSION_CELL_SIZE and 0 <= y < EXPLOSION_CELL_SIZE:
        frame.putpixel((x, y), color)


def _paint_center(frame: Image.Image, color: tuple[int, int, int, int]) -> None:
    for point in ((31, 31), (32, 31), (31, 32), (32, 32)):
        frame.putpixel(point, color)


def _paint_octagonal_bands(
    frame: Image.Image,
    bands: tuple[tuple[float, float, tuple[int, int, int, int]], ...],
    *,
    segmented: bool = False,
) -> None:
    """Paint concentric faceted bands, optionally with rotational gaps."""
    pixels = frame.load()
    for y in range(EXPLOSION_CELL_SIZE):
        for x in range(EXPLOSION_CELL_SIZE):
            distance = _octagonal_distance(x, y)
            if segmented:
                dx = abs(x - EXPLOSION_CENTER)
                dy = abs(y - EXPLOSION_CENTER)
                # Four-fold symmetric mechanical gaps, never affecting center.
                gap = (
                    (int(dx + dy) % 9 in (0, 1))
                    and abs(dx - dy) > 3.0
                )
                if gap:
                    continue
            for inner, outer, color in bands:
                if inner < distance <= outer:
                    pixels[x, y] = color
                    break


def _paint_cardinal_embers(
    frame: Image.Image,
    distance: int,
    color: tuple[int, int, int, int],
    *,
    length: int = 2,
) -> None:
    """Place centered two-pixel-thick, four-fold symmetric fragments."""
    for step in range(length):
        offset = distance + step
        for x, y in (
            (31 - offset, 31),
            (31 - offset, 32),
            (32 + offset, 31),
            (32 + offset, 32),
            (31, 31 - offset),
            (32, 31 - offset),
            (31, 32 + offset),
            (32, 32 + offset),
        ):
            _set_explosion_pixel(frame, x, y, color)


def _paint_diagonal_embers(
    frame: Image.Image,
    distance: int,
    color: tuple[int, int, int, int],
    *,
    size: int = 1,
) -> None:
    for sx in (-1, 1):
        for sy in (-1, 1):
            anchor_x = 31 if sx < 0 else 32
            anchor_y = 31 if sy < 0 else 32
            for along in range(size):
                x = anchor_x + sx * (distance + along)
                y = anchor_y + sy * (distance + along)
                _set_explosion_pixel(frame, x, y, color)


def _build_explosion_x1_frames() -> list[Image.Image]:
    frames: list[Image.Image] = []

    specifications = (
        # ignition: compact, layered mechanical core
        (
            (
                (0.0, 1.0, ENERGY_WHITE),
                (1.0, 2.0, HOT_HIGHLIGHT),
                (2.0, 3.0, ACTIVE_RED),
            ),
            False,
        ),
        (
            (
                (0.0, 1.5, ENERGY_WHITE),
                (1.5, 3.5, HOT_HIGHLIGHT),
                (3.5, 5.5, HOT_ORANGE),
                (5.5, 7.0, DEEP_RED),
            ),
            False,
        ),
        (
            (
                (0.0, 2.0, ENERGY_WHITE),
                (2.0, 5.0, HOT_HIGHLIGHT),
                (5.0, 8.5, HOT_ORANGE),
                (8.5, 11.5, ACTIVE_RED),
                (11.5, 13.0, DEEP_RED),
            ),
            False,
        ),
        (
            (
                (0.0, 2.0, ENERGY_WHITE),
                (2.0, 6.0, HOT_HIGHLIGHT),
                (6.0, 11.0, HOT_ORANGE),
                (11.0, 16.0, ACTIVE_RED),
                (16.0, 20.0, DEEP_RED),
                (20.0, 21.0, OUTLINE),
            ),
            False,
        ),
        # peak: three separate shock bands reach the exact 56px diameter
        (
            (
                (0.0, 2.0, ENERGY_WHITE),
                (2.0, 5.0, HOT_HIGHLIGHT),
                (8.0, 11.0, HOT_ORANGE),
                (14.0, 18.0, ACTIVE_RED),
                (22.0, 26.5, DEEP_RED),
                (26.5, 28.0, OUTLINE),
            ),
            False,
        ),
        # release: the full disk becomes a broken ring and fragments
        (
            (
                (18.0, 20.0, HOT_ORANGE),
                (20.0, 23.0, ACTIVE_RED),
                (23.0, 24.5, DEEP_RED),
            ),
            True,
        ),
        (
            (
                (13.0, 15.0, HOT_ORANGE),
                (15.0, 18.5, ACTIVE_RED),
            ),
            True,
        ),
        (
            (
                (8.0, 9.5, ACTIVE_RED),
                (11.0, 12.5, DEEP_RED),
            ),
            True,
        ),
    )

    for index, (bands, segmented) in enumerate(specifications):
        frame = _empty((EXPLOSION_CELL_SIZE, EXPLOSION_CELL_SIZE))
        _paint_octagonal_bands(frame, bands, segmented=segmented)
        if index >= 5:
            _paint_center(frame, ACTIVE_RED if index < 7 else DEEP_RED)
        if index == 4:
            _paint_cardinal_embers(frame, 27, HOT_ORANGE, length=1)
        elif index == 5:
            _paint_cardinal_embers(frame, 26, ACTIVE_RED, length=1)
            _paint_diagonal_embers(frame, 20, HOT_ORANGE, size=2)
        elif index == 6:
            _paint_cardinal_embers(frame, 20, ACTIVE_RED, length=2)
            _paint_diagonal_embers(frame, 15, HOT_ORANGE)
        elif index == 7:
            _paint_cardinal_embers(frame, 13, DEEP_RED)
            _paint_diagonal_embers(frame, 9, ACTIVE_RED)
        frames.append(frame)
    return frames


def _paint_cross(
    frame: Image.Image,
    radius: int,
) -> None:
    """Paint a centered two-pixel mechanical cross with a hot energy ramp."""
    pixels = frame.load()
    for y in range(EXPLOSION_CELL_SIZE):
        for x in range(EXPLOSION_CELL_SIZE):
            dx = abs(x - EXPLOSION_CENTER)
            dy = abs(y - EXPLOSION_CENTER)
            along = max(dx, dy)
            across = min(dx, dy)
            if along > radius - 0.5 or across > 1.5:
                continue
            if across > 0.5 or along > radius - 1.5:
                pixels[x, y] = DEEP_RED
            elif along <= 2.5:
                pixels[x, y] = ENERGY_WHITE
            elif along <= radius * 0.45:
                pixels[x, y] = HOT_HIGHLIGHT
            else:
                pixels[x, y] = HOT_ORANGE


def _build_explosion_x2_frames() -> list[Image.Image]:
    frames: list[Image.Image] = []
    radii = (3, 7, 13, 21, 28)
    for index, radius in enumerate(radii):
        frame = _empty((EXPLOSION_CELL_SIZE, EXPLOSION_CELL_SIZE))
        _paint_cross(frame, radius)
        if index >= 2:
            _paint_diagonal_embers(
                frame,
                distance=(7, 12, 18)[index - 2],
                color=HOT_ORANGE,
                size=2 if index == 4 else 1,
            )
        frames.append(frame)

    # The final three frames are event-driven debris only.  Their symmetric
    # embers converge toward the locked center while fading through the ramp.
    release_specs = (
        (22, 16, HOT_ORANGE, ACTIVE_RED),
        (15, 10, ACTIVE_RED, DEEP_RED),
        (8, 5, DEEP_RED, DEEP_RED),
    )
    for cardinal_distance, diagonal_distance, cardinal_color, diagonal_color in release_specs:
        frame = _empty((EXPLOSION_CELL_SIZE, EXPLOSION_CELL_SIZE))
        _paint_center(frame, ACTIVE_RED if cardinal_distance > 8 else DEEP_RED)
        _paint_cardinal_embers(
            frame,
            cardinal_distance,
            cardinal_color,
            length=2,
        )
        _paint_diagonal_embers(
            frame,
            diagonal_distance,
            diagonal_color,
            size=2,
        )
        frames.append(frame)
    return frames


def _build_strip(frames: list[Image.Image], cell_size: int) -> Image.Image:
    strip = _empty((len(frames) * cell_size, cell_size))
    for index, frame in enumerate(frames):
        if frame.size != (cell_size, cell_size):
            raise AssertionError(
                f"Frame {index} is {frame.size}, expected {cell_size}x{cell_size}"
            )
        strip.alpha_composite(frame, (index * cell_size, 0))
    return strip


def _save_upscaled(
    image: Image.Image,
    path: Path,
    scale: int,
) -> None:
    _on_background(image).resize(
        (image.width * scale, image.height * scale),
        Image.Resampling.NEAREST,
    ).save(path, optimize=True)


def _save_gif(
    frames: Iterable[Image.Image],
    path: Path,
    fps: int,
    scale: int,
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
        duration=round(1000 / fps),
        loop=0,
        disposal=2,
        optimize=False,
    )


def _assert_pixel_contract(image: Image.Image, label: str) -> None:
    allowed = set(PALETTE) | {TRANSPARENT}
    colors = set(image.getdata())
    unexpected = colors - allowed
    if unexpected:
        raise AssertionError(f"{label} contains colors outside palette: {unexpected}")
    for red, green, blue, alpha in image.getdata():
        if alpha not in (0, 255):
            raise AssertionError(f"{label} contains non-binary alpha")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} contains dirty transparent RGB")


def _audit_drone(
    label: str,
    frames: list[Image.Image],
    variable_points: set[tuple[int, int]],
) -> dict[str, Any]:
    if len(frames) != DRONE_FRAME_COUNT:
        raise AssertionError(f"{label} must contain four frames")
    alpha_masks = []
    bboxes = []
    for index, frame in enumerate(frames):
        _assert_pixel_contract(frame, f"{label} frame {index}")
        bbox = frame.getchannel("A").getbbox()
        if bbox != DRONE_EXPECTED_BBOX:
            raise AssertionError(
                f"{label} frame {index} bbox {bbox}, expected {DRONE_EXPECTED_BBOX}"
            )
        bboxes.append(list(bbox))
        alpha_masks.append(frame.getchannel("A").tobytes())
    if len(set(alpha_masks)) != 1:
        raise AssertionError(f"{label} alpha mask changes between frames")

    first = frames[0]
    changed_points: set[tuple[int, int]] = set()
    for frame in frames[1:]:
        for y in range(DRONE_CELL_SIZE):
            for x in range(DRONE_CELL_SIZE):
                if frame.getpixel((x, y)) != first.getpixel((x, y)):
                    changed_points.add((x, y))
    if changed_points - variable_points:
        raise AssertionError(
            f"{label} changed non-light pixels: {sorted(changed_points - variable_points)}"
        )
    if len({frame.tobytes() for frame in frames}) != DRONE_FRAME_COUNT:
        raise AssertionError(f"{label} must contain four unique light phases")
    return {
        "frame_count": len(frames),
        "fps": DRONE_FPS,
        "cell_size": [DRONE_CELL_SIZE, DRONE_CELL_SIZE],
        "visible_bboxes": bboxes,
        "visible_size": list(DRONE_EXPECTED_VISIBLE_SIZE),
        "alpha_mask_identical": True,
        "non_light_pixels_identical": True,
        "changing_light_pixels": [list(point) for point in sorted(changed_points)],
        "unique_frames": len({frame.tobytes() for frame in frames}),
        "native_facing": "right",
        "runtime_rotation_expected": True,
    }


def _audit_marker(marker: Image.Image) -> dict[str, Any]:
    _assert_pixel_contract(marker, "target marker")
    bbox = marker.getchannel("A").getbbox()
    if bbox != (2, 2, 14, 14):
        raise AssertionError(f"Unexpected marker bbox {bbox}")
    # The annulus between the brackets and center must remain empty: no radius
    # circle is encoded into this static target indicator.
    forbidden_ring_pixels = []
    for y in range(4, 12):
        for x in range(4, 12):
            if (x, y) in {(7, 7), (8, 7), (7, 8), (8, 8)}:
                continue
            if marker.getpixel((x, y))[3]:
                forbidden_ring_pixels.append((x, y))
    if forbidden_ring_pixels:
        raise AssertionError(
            f"Marker contains radius-ring pixels {forbidden_ring_pixels}"
        )
    return {
        "size": list(marker.size),
        "visible_bbox": list(bbox),
        "four_broken_corner_brackets": True,
        "center_dot_bbox": [7, 7, 9, 9],
        "radius_ring": False,
        "animated": False,
    }


def _audit_explosion(label: str, frames: list[Image.Image]) -> dict[str, Any]:
    if len(frames) != EXPLOSION_FRAME_COUNT:
        raise AssertionError(f"{label} must contain eight frames")
    bboxes: list[list[int]] = []
    sizes: list[list[int]] = []
    centers: list[list[float]] = []
    for index, frame in enumerate(frames):
        _assert_pixel_contract(frame, f"{label} frame {index}")
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError(f"{label} frame {index} is empty")
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        if width > EXPLOSION_MAX_DIAMETER or height > EXPLOSION_MAX_DIAMETER:
            raise AssertionError(
                f"{label} frame {index} bbox {width}x{height} exceeds 56"
            )
        center_x = (bbox[0] + bbox[2] - 1) / 2.0
        center_y = (bbox[1] + bbox[3] - 1) / 2.0
        if (center_x, center_y) != (EXPLOSION_CENTER, EXPLOSION_CENTER):
            raise AssertionError(
                f"{label} frame {index} center {(center_x, center_y)} drifted"
            )
        bboxes.append(list(bbox))
        sizes.append([width, height])
        centers.append([center_x, center_y])
    if max(max(size) for size in sizes) != EXPLOSION_MAX_DIAMETER:
        raise AssertionError(f"{label} never reaches the exact 56px peak")
    if len({frame.tobytes() for frame in frames}) != EXPLOSION_FRAME_COUNT:
        raise AssertionError(f"{label} must contain eight unique frames")
    return {
        "frame_count": len(frames),
        "fps": EXPLOSION_FPS,
        "cell_size": [EXPLOSION_CELL_SIZE, EXPLOSION_CELL_SIZE],
        "visible_bboxes": bboxes,
        "visible_sizes": sizes,
        "centers": centers,
        "center_stable": True,
        "maximum_visible_diameter": max(max(size) for size in sizes),
        "unique_frames": len({frame.tobytes() for frame in frames}),
    }


def _draw_scaled_frame(
    canvas: Image.Image,
    frame: Image.Image,
    x: int,
    y: int,
    scale: int,
) -> None:
    canvas.alpha_composite(
        _on_background(frame).resize(
            (frame.width * scale, frame.height * scale),
            Image.Resampling.NEAREST,
        ),
        (x, y),
    )


def _build_comparison(
    drone_v1: list[Image.Image],
    drone_v2: list[Image.Image],
    marker: Image.Image,
    explosion_x1: list[Image.Image],
    explosion_x2: list[Image.Image],
) -> Image.Image:
    canvas = Image.new("RGBA", (1400, 900), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title_font = _font(24)
    label_font = _font(18)
    small_font = _font(14)
    draw.text(
        (20, 14),
        "Drone operator FX candidates - deterministic native pixels",
        fill=PLATE_HIGHLIGHT,
        font=title_font,
    )

    drone_scale = 12
    drone_step = DRONE_CELL_SIZE * drone_scale + 12
    for row_index, (label, frames) in enumerate(
        (("V1 swept / diamond", drone_v1), ("V2 straight clipped wings", drone_v2))
    ):
        y = 66 + row_index * 220
        draw.text((20, y + 82), label, fill=PLATE_GRAY, font=label_font)
        for index, frame in enumerate(frames):
            x = 230 + index * drone_step
            _draw_scaled_frame(canvas, frame, x, y, drone_scale)
            draw.text((x + 84, y + 194), f"F{index}", fill=PLATE_GRAY, font=small_font)

    sword_reference = Image.open(SWORD_ROBOT_REFERENCE_PATH).convert("RGBA").crop(
        (0, 0, 32, 32)
    )
    gunner_reference = Image.open(GUNNER_ROBOT_REFERENCE_PATH).convert("RGBA").crop(
        (0, 0, 32, 32)
    )
    tango_reference = Image.open(TANGO_CAST_REFERENCE_PATH).convert("RGBA").crop(
        (0, 0, 8, 8)
    )
    anchor = Image.open(ANCHOR_PATH).convert("RGBA")

    draw.text((1060, 64), "Sword robot F0", fill=PLATE_GRAY, font=small_font)
    draw.text((1210, 64), "Gunner robot F0", fill=PLATE_GRAY, font=small_font)
    _draw_scaled_frame(canvas, sword_reference, 1050, 88, 4)
    _draw_scaled_frame(canvas, gunner_reference, 1200, 88, 4)

    draw.text(
        (1042, 238),
        "Tango 8x8 density only",
        fill=PLATE_GRAY,
        font=small_font,
    )
    draw.text((1220, 238), "Static lock marker", fill=PLATE_GRAY, font=small_font)
    _draw_scaled_frame(canvas, tango_reference, 1050, 264, 16)
    _draw_scaled_frame(canvas, marker, 1200, 264, 8)

    draw.text((1060, 414), "Approved C anchor", fill=PLATE_GRAY, font=small_font)
    _draw_scaled_frame(canvas, anchor, 1180, 392, 3)

    explosion_scale = 2
    explosion_step = EXPLOSION_CELL_SIZE * explosion_scale + 12
    for row_index, (label, frames) in enumerate(
        (
            ("X1 concentric mechanical rings / fragments", explosion_x1),
            ("X2 orthogonal cross sparks / converging embers", explosion_x2),
        )
    ):
        y = 510 + row_index * 180
        draw.text((20, y), label, fill=PLATE_GRAY, font=label_font)
        for index, frame in enumerate(frames):
            x = 20 + index * explosion_step
            _draw_scaled_frame(canvas, frame, x, y + 26, explosion_scale)
            draw.text((x + 54, y + 158), f"F{index}", fill=PLATE_GRAY, font=small_font)
    return canvas


def build() -> dict[str, Any]:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for path in (
        ANCHOR_PATH,
        SWORD_ROBOT_REFERENCE_PATH,
        GUNNER_ROBOT_REFERENCE_PATH,
        TANGO_CAST_REFERENCE_PATH,
        DRONE_V1_SOURCE_PATH,
        DRONE_V2_SOURCE_PATH,
        EXPLOSION_X1_SOURCE_PATH,
        EXPLOSION_X2_SOURCE_PATH,
    ):
        if not path.is_file():
            raise FileNotFoundError(path)

    anchor = Image.open(ANCHOR_PATH).convert("RGBA")
    if anchor.size != (32, 32):
        raise AssertionError(f"Approved C anchor is {anchor.size}, expected 32x32")
    _assert_pixel_contract(anchor, "approved C anchor")

    drone_v1, drone_v1_variable = _build_drone_frames(DRONE_V1_MASK, "v1")
    drone_v2, drone_v2_variable = _build_drone_frames(DRONE_V2_MASK, "v2")
    marker = _build_target_marker()
    explosion_x1 = _build_explosion_x1_frames()
    explosion_x2 = _build_explosion_x2_frames()

    audits = {
        "drone_v1": _audit_drone("drone V1", drone_v1, drone_v1_variable),
        "drone_v2": _audit_drone("drone V2", drone_v2, drone_v2_variable),
        "target_marker": _audit_marker(marker),
        "explosion_x1": _audit_explosion("explosion X1", explosion_x1),
        "explosion_x2": _audit_explosion("explosion X2", explosion_x2),
    }

    drone_v1_strip = _build_strip(drone_v1, DRONE_CELL_SIZE)
    drone_v2_strip = _build_strip(drone_v2, DRONE_CELL_SIZE)
    explosion_x1_strip = _build_strip(explosion_x1, EXPLOSION_CELL_SIZE)
    explosion_x2_strip = _build_strip(explosion_x2, EXPLOSION_CELL_SIZE)

    drone_v1_strip.save(DRONE_V1_STRIP_PATH, optimize=True)
    drone_v2_strip.save(DRONE_V2_STRIP_PATH, optimize=True)
    marker.save(TARGET_MARKER_PATH, optimize=True)
    explosion_x1_strip.save(EXPLOSION_X1_STRIP_PATH, optimize=True)
    explosion_x2_strip.save(EXPLOSION_X2_STRIP_PATH, optimize=True)

    _save_upscaled(drone_v1_strip, DRONE_V1_UPSCALED_PATH, 16)
    _save_upscaled(drone_v2_strip, DRONE_V2_UPSCALED_PATH, 16)
    _save_upscaled(marker, TARGET_MARKER_UPSCALED_PATH, 16)
    _save_upscaled(explosion_x1_strip, EXPLOSION_X1_UPSCALED_PATH, 4)
    _save_upscaled(explosion_x2_strip, EXPLOSION_X2_UPSCALED_PATH, 4)

    _save_gif(drone_v1, DRONE_V1_GIF_PATH, DRONE_FPS, 16)
    _save_gif(drone_v2, DRONE_V2_GIF_PATH, DRONE_FPS, 16)
    _save_gif(explosion_x1, EXPLOSION_X1_GIF_PATH, EXPLOSION_FPS, 4)
    _save_gif(explosion_x2, EXPLOSION_X2_GIF_PATH, EXPLOSION_FPS, 4)

    comparison = _build_comparison(
        drone_v1,
        drone_v2,
        marker,
        explosion_x1,
        explosion_x2,
    )
    comparison.save(COMPARISON_PATH, optimize=True)

    source_reports = {
        "drone_v1": _source_grid_report(
            DRONE_V1_SOURCE_PATH,
            4,
            1,
            expected_subject_grid=DRONE_EXPECTED_VISIBLE_SIZE,
        ),
        "drone_v2": _source_grid_report(
            DRONE_V2_SOURCE_PATH,
            4,
            1,
            expected_subject_grid=DRONE_EXPECTED_VISIBLE_SIZE,
        ),
        "explosion_x1": _source_grid_report(EXPLOSION_X1_SOURCE_PATH, 4, 2),
        "explosion_x2": _source_grid_report(EXPLOSION_X2_SOURCE_PATH, 4, 2),
    }
    outputs = [
        DRONE_V1_STRIP_PATH,
        DRONE_V2_STRIP_PATH,
        DRONE_V1_UPSCALED_PATH,
        DRONE_V2_UPSCALED_PATH,
        DRONE_V1_GIF_PATH,
        DRONE_V2_GIF_PATH,
        TARGET_MARKER_PATH,
        TARGET_MARKER_UPSCALED_PATH,
        EXPLOSION_X1_STRIP_PATH,
        EXPLOSION_X2_STRIP_PATH,
        EXPLOSION_X1_UPSCALED_PATH,
        EXPLOSION_X2_UPSCALED_PATH,
        EXPLOSION_X1_GIF_PATH,
        EXPLOSION_X2_GIF_PATH,
        COMPARISON_PATH,
    ]
    report: dict[str, Any] = {
        "stage": "second_human_review_gate",
        "preview_only": True,
        "runtime_written": False,
        "approved_identity_anchor": _relative(ANCHOR_PATH),
        "comparison_references": {
            "sword_robot_first_frame": {
                "path": _relative(SWORD_ROBOT_REFERENCE_PATH),
                "source_cell": [0, 0, 32, 32],
                "preview_scale": 4,
                "resampling": "nearest_integer",
            },
            "gunner_robot_first_frame": {
                "path": _relative(GUNNER_ROBOT_REFERENCE_PATH),
                "source_cell": [0, 0, 32, 32],
                "preview_scale": 4,
                "resampling": "nearest_integer",
            },
            "tango_density_only": {
                "path": _relative(TANGO_CAST_REFERENCE_PATH),
                "source_cell": [0, 0, 8, 8],
                "preview_scale": 16,
                "resampling": "nearest_integer",
                "label": "Tango 8x8 density only",
            },
        },
        "palette": [list(color) for color in PALETTE],
        "construction": {
            "native_pixel_authored": True,
            "source_pixels_resized_into_candidates": False,
            "pixel_grid_analyzer_used_for_source_audit": True,
            "pixel_crop_tool_used": False,
            "pixel_crop_tool_reason": (
                "No source compression is performed; exact native geometry is "
                "constructed directly after unsafe source-grid cells are reported."
            ),
        },
        "audits": audits,
        "source_grid_reports": source_reports,
        "outputs": [_relative(path) for path in outputs],
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "preview_only": True,
                "report": _relative(REPORT_PATH),
                "comparison": _relative(COMPARISON_PATH),
                "drone_contract": "4x 16x16; exact 12x9; shared alpha mask",
                "explosion_contract": "8x 64x64; 14 FPS; stable center; max 56px",
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return report


if __name__ == "__main__":
    build()
