#!/usr/bin/env python3
"""Deterministically build Tiyi runtime pixel assets from imagegen sources.

The five authored boards are retained under ``dev_assets/source_images/player_tiyi``.
This script consumes their chroma-key Alpha derivatives, registers every frame
to the game's logical pixel grid, applies fixed palettes, and writes the runtime
atlases plus a reproducibility manifest.
"""

from __future__ import annotations

from collections.abc import Iterable
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "player_tiyi"
OUTPUT_DIR = ROOT / "resources" / "texture" / "player" / "tiyi"
ANIMATION_PATH = ROOT / "resources" / "animation" / "player_tiyi.tres"
APPROVED_MOVEMENT_PATH = SOURCE_DIR / "movement_scale1_20px_candidate.png"
APPROVED_MOVEMENT_REPORT_PATH = APPROVED_MOVEMENT_PATH.with_suffix(".json")
WEISH_ARMED_EFFECT = (
    ROOT / "resources" / "texture" / "player" / "weishidaier" / "armed_effect.png"
)

SOURCE_NAMES = ("anchor", "movement", "bullet", "hit", "icon")
FRAME_SIZE = 32
ALPHA_THRESHOLD = 127

DEATH_PURPLE_PALETTE = (
    (0x3B, 0x1C, 0x4E),
    (0x75, 0x40, 0x9A),
    (0xB0, 0x5A, 0xDD),
    (0xE7, 0xB6, 0xFF),
)
CHARACTER_PALETTE = (
    (15, 14, 18),
    (29, 27, 33),
    (48, 44, 52),
    (72, 68, 78),
    (105, 99, 112),
    (59, 41, 71),
    (84, 61, 101),
    (112, 87, 133),
    (140, 113, 163),
    (166, 140, 190),
    (194, 170, 214),
    (220, 205, 235),
    (92, 23, 63),
    (139, 37, 91),
    (184, 62, 118),
    (205, 100, 151),
    (203, 140, 118),
    (232, 184, 160),
    (247, 215, 197),
    (112, 84, 75),
    (157, 118, 101),
    (184, 180, 191),
    (218, 216, 223),
    (246, 245, 247),
)
PURPLE_WHITE_PALETTE = (*DEATH_PURPLE_PALETTE, (255, 255, 255))
UI_PALETTE = (*CHARACTER_PALETTE, *PURPLE_WHITE_PALETTE)

# Per-frame lattice measurements from movement_alpha.png. Values are:
# (logical_width, logical_height, target_x, target_y,
#  physical_period_x, physical_period_y, boundary_delta_x, boundary_delta_y)
# Boundary deltas are relative to the full-image connected-component bbox.
MOVEMENT_FRAME_SPECS = (
    (
        (25, 24, 5, 3, 8.680, 8.705, 0.07, -0.80),
        (25, 24, 5, 3, 8.640, 8.705, -0.12, -0.82),
        (23, 24, 5, 3, 8.575, 8.705, -0.11, -0.81),
        (25, 24, 5, 3, 8.530, 8.705, -0.04, -0.82),
    ),
    (
        (25, 24, 2, 3, 8.690, 8.695, -0.09, -0.67),
        (25, 24, 2, 3, 8.645, 8.695, -0.13, -0.67),
        (24, 24, 3, 3, 8.585, 8.695, -0.43, -0.67),
        (23, 24, 4, 3, 8.535, 8.695, 0.33, -0.66),
    ),
    (
        (27, 23, 5, 3, 8.655, 8.680, -1.51, 0.86),
        (24, 23, 5, 3, 8.610, 8.685, -0.89, 0.76),
        (22, 23, 5, 3, 8.650, 8.675, -0.85, 0.90),
        (26, 23, 5, 3, 8.605, 8.680, -1.83, 0.83),
    ),
    (
        (27, 23, 0, 3, 8.770, 8.760, -1.02, 0.07),
        (26, 23, 1, 3, 8.770, 8.760, -0.99, 0.06),
        (22, 23, 5, 3, 8.755, 8.760, -0.05, 0.06),
        (22, 23, 5, 3, 8.775, 8.760, 0.70, -0.95),
    ),
)
MOVEMENT_DIRECTION_NAMES = ("down", "up", "right", "left")

IMAGEGEN_FILES = {
    "anchor": "exec-8fd3bd1f-0a11-47bc-9995-39092d169e44.png",
    "movement": "exec-4e568288-905d-4da4-b373-15c71a2129c9.png",
    "bullet": "exec-0e28cb80-1256-4bb9-bf8e-63b0e4a3bb38.png",
    "hit": "exec-bb02a38b-a8dc-4eba-959e-f36bd2427754.png",
    "icon": "exec-0f1f7921-a444-49f7-9859-d4c41d69c77c.png",
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _load_alpha(name: str) -> Image.Image:
    path = SOURCE_DIR / f"{name}_alpha.png"
    if not path.is_file():
        raise FileNotFoundError(path)
    return Image.open(path).convert("RGBA")


def _binary_alpha(image: Image.Image, threshold: int = ALPHA_THRESHOLD) -> Image.Image:
    array = np.array(image.convert("RGBA"), dtype=np.uint8)
    visible = array[:, :, 3] >= threshold
    array[~visible] = (0, 0, 0, 0)
    array[visible, 3] = 255
    return Image.fromarray(array)


def _map_to_palette(image: Image.Image, palette: Iterable[tuple[int, int, int]]) -> Image.Image:
    rgba = np.array(_binary_alpha(image), dtype=np.uint8)
    visible = rgba[:, :, 3] == 255
    palette_array = np.array(tuple(palette), dtype=np.int32)
    if visible.any():
        colors = rgba[:, :, :3][visible].astype(np.int32)
        distance = ((colors[:, None, :] - palette_array[None, :, :]) ** 2).sum(axis=2)
        rgba[:, :, :3][visible] = palette_array[distance.argmin(axis=1)].astype(np.uint8)
    rgba[~visible] = (0, 0, 0, 0)
    return Image.fromarray(rgba)


def _split_uniform_grid(image: Image.Image, columns: int, rows: int) -> list[Image.Image]:
    frames: list[Image.Image] = []
    for row in range(rows):
        top = round(row * image.height / rows)
        bottom = round((row + 1) * image.height / rows)
        for column in range(columns):
            left = round(column * image.width / columns)
            right = round((column + 1) * image.width / columns)
            frames.append(image.crop((left, top, right, bottom)))
    return frames


def _fit_foreground(
    image: Image.Image,
    canvas_size: tuple[int, int],
    maximum_size: tuple[int, int],
) -> Image.Image:
    hardened = _binary_alpha(image)
    bbox = hardened.getchannel("A").getbbox()
    if bbox is None:
        return Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    crop = hardened.crop(bbox)
    scale = min(
        maximum_size[0] / max(crop.width, 1),
        maximum_size[1] / max(crop.height, 1),
    )
    resized = crop.resize(
        (
            max(1, round(crop.width * scale)),
            max(1, round(crop.height * scale)),
        ),
        Image.Resampling.NEAREST,
    )
    canvas = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    canvas.alpha_composite(
        resized,
        (
            (canvas_size[0] - resized.width) // 2,
            (canvas_size[1] - resized.height) // 2,
        ),
    )
    return _binary_alpha(canvas)


def _movement_components(
    source: Image.Image,
) -> list[list[tuple[int, tuple[int, int, int, int]]]]:
    """Locate all 16 authored movement sprites without cutting through a frame.

    The first source row reaches one pixel beyond a naïve fifth-height slice, so
    connected components must be labelled on the complete source image first.
    """
    alpha = np.array(source.getchannel("A"), dtype=np.uint8) >= ALPHA_THRESHOLD
    labels, _count = ndimage.label(alpha)
    components: list[tuple[int, tuple[int, int, int, int]]] = []
    for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
        if slices is None:
            continue
        area = int((labels[slices] == label_index).sum())
        top = int(slices[0].start)
        if area < 1000 or top >= 1000:
            continue
        bbox = (
            int(slices[1].start),
            top,
            int(slices[1].stop),
            int(slices[0].stop),
        )
        components.append((area, bbox))
    if len(components) != 16:
        raise ValueError(f"Movement board must contain 16 connected sprites, got {len(components)}")

    components.sort(key=lambda item: (item[1][1], item[1][0]))
    rows: list[list[tuple[int, tuple[int, int, int, int]]]] = []
    for row in range(4):
        row_components = components[row * 4 : (row + 1) * 4]
        row_components.sort(key=lambda item: item[1][0])
        rows.append(row_components)
    return rows


def _rounded_lattice_boundaries(start: float, period: float, count: int) -> list[int]:
    boundaries = [int(np.floor(start + index * period + 0.5)) for index in range(count + 1)]
    widths = np.diff(boundaries)
    if not np.all(np.isin(widths, (8, 9))):
        raise AssertionError(f"Logical lattice must resolve to 8/9px cells, got {widths.tolist()}")
    return boundaries


def _central_cell_bounds(start: int, end: int) -> tuple[int, int]:
    """Return the central 60% of one physical logical-pixel block."""
    width = end - start
    inner_start = int(np.floor(start + width * 0.2 + 0.5))
    inner_end = int(np.floor(start + width * 0.8 + 0.5))
    return inner_start, max(inner_start + 1, inner_end)


def _sample_logical_frame(
    source_rgba: np.ndarray,
    component_area: int,
    bbox: tuple[int, int, int, int],
    spec: tuple[int, int, int, int, float, float, float, float],
) -> tuple[Image.Image, dict[str, object]]:
    """Decode one enlarged sprite cell-by-cell; no image resize is performed."""
    logical_width, logical_height, target_x, target_y, period_x, period_y, delta_x, delta_y = spec
    left, top, right, bottom = bbox
    x_boundaries = _rounded_lattice_boundaries(left + delta_x, period_x, logical_width)
    y_boundaries = _rounded_lattice_boundaries(top + delta_y, period_y, logical_height)
    palette = np.array(CHARACTER_PALETTE, dtype=np.int32)
    decoded = np.zeros((logical_height, logical_width, 4), dtype=np.uint8)

    for logical_y in range(logical_height):
        cell_top, cell_bottom = _central_cell_bounds(
            y_boundaries[logical_y], y_boundaries[logical_y + 1]
        )
        for logical_x in range(logical_width):
            cell_left, cell_right = _central_cell_bounds(
                x_boundaries[logical_x], x_boundaries[logical_x + 1]
            )
            sample = source_rgba[cell_top:cell_bottom, cell_left:cell_right]
            if sample.size == 0:
                continue
            visible = sample[:, :, 3] >= ALPHA_THRESHOLD
            # Alpha coverage, rather than one arbitrarily chosen source pixel,
            # makes edge cells stable in the presence of chroma-key antialiasing.
            if float(visible.mean()) < 0.5:
                continue
            colors = sample[:, :, :3][visible].astype(np.int32)
            distances = ((colors[:, None, :] - palette[None, :, :]) ** 2).sum(axis=2)
            palette_indices = distances.argmin(axis=1)
            palette_index = int(np.bincount(palette_indices, minlength=len(palette)).argmax())
            decoded[logical_y, logical_x, :3] = palette[palette_index].astype(np.uint8)
            decoded[logical_y, logical_x, 3] = 255

    native = Image.fromarray(decoded)
    native_bbox = native.getchannel("A").getbbox()
    expected_native_bbox = (0, 0, logical_width, logical_height)
    if native_bbox != expected_native_bbox:
        raise AssertionError(
            f"Decoded movement frame bbox {native_bbox} != expected {expected_native_bbox}"
        )

    canvas = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(native, (target_x, target_y))
    visible_y, visible_x = np.where(decoded[:, :, 3] == 255)
    physical_area = component_area
    expected_logical_area = physical_area / (period_x * period_y)
    logical_area = int(len(visible_x))
    area_error = abs(logical_area - expected_logical_area) / expected_logical_area
    source_lattice_alpha = (
        source_rgba[
            y_boundaries[0] : y_boundaries[-1],
            x_boundaries[0] : x_boundaries[-1],
            3,
        ]
        >= ALPHA_THRESHOLD
    )
    reconstructed_alpha = np.zeros_like(source_lattice_alpha)
    for logical_y in range(logical_height):
        for logical_x in range(logical_width):
            if decoded[logical_y, logical_x, 3] != 255:
                continue
            reconstructed_alpha[
                y_boundaries[logical_y] - y_boundaries[0] : y_boundaries[logical_y + 1]
                - y_boundaries[0],
                x_boundaries[logical_x] - x_boundaries[0] : x_boundaries[logical_x + 1]
                - x_boundaries[0],
            ] = True
    alpha_union = int(np.logical_or(source_lattice_alpha, reconstructed_alpha).sum())
    alpha_intersection = int(np.logical_and(source_lattice_alpha, reconstructed_alpha).sum())
    alpha_iou = alpha_intersection / alpha_union
    diagnostics: dict[str, object] = {
        "source_bbox": [left, top, right, bottom],
        "source_visible_area": physical_area,
        "measured_period": [period_x, period_y],
        "boundary_delta": [delta_x, delta_y],
        "physical_cell_widths": sorted({int(width) for width in np.diff(x_boundaries)}),
        "physical_cell_heights": sorted({int(height) for height in np.diff(y_boundaries)}),
        "logical_size": [logical_width, logical_height],
        "target_bbox": [target_x, target_y, target_x + logical_width, target_y + logical_height],
        "logical_visible_area": logical_area,
        "expected_logical_area": round(expected_logical_area, 3),
        "area_error_percent": round(area_error * 100.0, 3),
        "source_reprojection_alpha_iou": round(alpha_iou, 5),
        "alpha_centroid": [
            round(float(visible_x.mean() + target_x), 3),
            round(float(visible_y.mean() + target_y), 3),
        ],
    }
    return _binary_alpha(canvas), diagnostics


def _build_body() -> tuple[Image.Image, list[dict[str, object]]]:
    source = _load_alpha("movement")
    source_rgba = np.array(source, dtype=np.uint8)
    rows = _movement_components(source)
    sheet = Image.new("RGBA", (160, 160), (0, 0, 0, 0))
    movement_diagnostics: list[dict[str, object]] = []
    for row, frames in enumerate(rows):
        for column, (component_area, bbox) in enumerate(frames):
            frame, diagnostics = _sample_logical_frame(
                source_rgba,
                component_area,
                bbox,
                MOVEMENT_FRAME_SPECS[row][column],
            )
            diagnostics["direction"] = MOVEMENT_DIRECTION_NAMES[row]
            diagnostics["frame"] = column
            movement_diagnostics.append(diagnostics)
            sheet.alpha_composite(frame, (column * FRAME_SIZE, row * FRAME_SIZE))

    death_cells = _split_uniform_grid(source, 5, 5)[20:24]
    for column, panel in enumerate(death_cells):
        frame = panel.resize((FRAME_SIZE, FRAME_SIZE), Image.Resampling.NEAREST)
        frame = _map_to_palette(frame, DEATH_PURPLE_PALETTE)
        sheet.alpha_composite(frame, (column * FRAME_SIZE, 4 * FRAME_SIZE))
    # The fifth death frame is deliberately fully transparent.
    return _binary_alpha(sheet), movement_diagnostics


def _build_bullet() -> Image.Image:
    panels = _split_uniform_grid(_load_alpha("bullet"), 2, 1)
    sheet = Image.new("RGBA", (64, 8), (0, 0, 0, 0))
    for index, panel in enumerate(panels):
        frame = _fit_foreground(panel, (32, 8), (32, 6))
        sheet.alpha_composite(_map_to_palette(frame, PURPLE_WHITE_PALETTE), (index * 32, 0))
    return _binary_alpha(sheet)


def _build_hit() -> Image.Image:
    panels = _split_uniform_grid(_load_alpha("hit"), 3, 2)
    sheet = Image.new("RGBA", (288, 48), (0, 0, 0, 0))
    for index, panel in enumerate(panels):
        frame = panel.resize((48, 48), Image.Resampling.NEAREST)
        sheet.alpha_composite(_map_to_palette(frame, PURPLE_WHITE_PALETTE), (index * 48, 0))
    return _binary_alpha(sheet)


def _build_portrait_and_icon() -> tuple[Image.Image, Image.Image]:
    panels = _split_uniform_grid(_load_alpha("icon"), 2, 1)
    movement = Image.open(APPROVED_MOVEMENT_PATH).convert("RGBA")
    portrait = movement.crop((0, 0, FRAME_SIZE, FRAME_SIZE)).resize(
        (128, 128),
        Image.Resampling.NEAREST,
    )
    skill_icon = panels[1].resize((128, 128), Image.Resampling.NEAREST)
    return (
        _binary_alpha(portrait, threshold=1),
        _map_to_palette(skill_icon, UI_PALETTE),
    )


def _build_armed_effect() -> Image.Image:
    if not WEISH_ARMED_EFFECT.is_file():
        raise FileNotFoundError(WEISH_ARMED_EFFECT)
    source = _binary_alpha(Image.open(WEISH_ARMED_EFFECT).convert("RGBA"), threshold=1)
    rgba = np.array(source, dtype=np.uint8)
    visible = rgba[:, :, 3] == 255
    if visible.any():
        luminance = (
            rgba[:, :, 0].astype(np.uint16) * 54
            + rgba[:, :, 1].astype(np.uint16) * 183
            + rgba[:, :, 2].astype(np.uint16) * 19
        ) // 256
        indices = np.clip(luminance // 64, 0, 3)
        palette = np.array(DEATH_PURPLE_PALETTE, dtype=np.uint8)
        rgba[:, :, :3][visible] = palette[indices[visible]]
    rgba[~visible] = (0, 0, 0, 0)
    return Image.fromarray(rgba)


def _animation_resource() -> str:
    rows = {"down": 0, "up": 1, "right": 2, "left": 3}
    lines = [
        '[gd_resource type="SpriteFrames" format=3 uid="uid://dxmeyfyr1jyoj"]',
        "",
        '[ext_resource type="Texture2D" path="res://resources/texture/player/tiyi/body.png" id="1_body"]',
        '[ext_resource type="Texture2D" path="res://resources/texture/player/tiyi/movement.png" id="2_movement"]',
        "",
    ]
    for row in range(5):
        column_count = 4 if row < 4 else 5
        for column in range(column_count):
            lines.extend(
                [
                    f'[sub_resource type="AtlasTexture" id="AtlasTexture_r{row}c{column}"]',
                    (
                        'atlas = ExtResource("2_movement")'
                        if row < 4
                        else 'atlas = ExtResource("1_body")'
                    ),
                    f"region = Rect2({column * 32}, {row * 32}, 32, 32)",
                    "",
                ]
            )

    animations: list[tuple[str, float, bool, list[tuple[int, int]]]] = []
    for prefix in ("armed",):
        for direction in ("down", "left", "right", "up"):
            animations.append(
                (prefix + "_" + direction, 8.0, True, [(rows[direction], column) for column in range(4)])
            )
    animations.append(("death", 10.0, False, [(4, column) for column in range(5)]))
    for direction in ("down", "left", "right", "up"):
        animations.append(
            ("normal_" + direction, 8.0, True, [(rows[direction], column) for column in range(4)])
        )

    lines.append("[resource]")
    lines.append("animations = [")
    for animation_index, (name, speed, loop, frames) in enumerate(animations):
        lines.append("{")
        lines.append('"frames": [')
        for frame_index, (row, column) in enumerate(frames):
            suffix = "," if frame_index + 1 < len(frames) else ""
            lines.extend(
                [
                    "{",
                    '"duration": 1.0,',
                    f'"texture": SubResource("AtlasTexture_r{row}c{column}")',
                    "}" + suffix,
                ]
            )
        lines.extend(
            [
                "],",
                f'"loop": {str(loop).lower()},',
                f'"name": &"{name}",',
                f'"speed": {speed:.1f}',
                "}" + ("," if animation_index + 1 < len(animations) else ""),
            ]
        )
    lines.append("]")
    lines.append("")
    return "\n".join(lines)


def _run_pixel_tools() -> tuple[dict[str, object], dict[str, str]]:
    analyses: dict[str, object] = {}
    crop_logs: dict[str, str] = {}
    for name in SOURCE_NAMES:
        alpha_path = SOURCE_DIR / f"{name}_alpha.png"
        analyze_command = [
            sys.executable,
            str(ROOT / "dev_tools" / "pixel_grid_analyzer.py"),
            str(alpha_path),
            "--json",
        ]
        analyze = subprocess.run(
            analyze_command,
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        analyses[name] = json.loads(analyze.stdout)

        crop_path = SOURCE_DIR / f"{name}_crop_tool.png"
        crop_command = [
            sys.executable,
            str(ROOT / "dev_tools" / "pixel_crop_tool.py"),
            str(alpha_path),
            str(crop_path),
            "--padding",
            "0",
            "--alpha-threshold",
            str(ALPHA_THRESHOLD),
        ]
        crop = subprocess.run(
            crop_command,
            cwd=ROOT,
            check=True,
            capture_output=True,
        )
        try:
            crop_stdout = crop.stdout.decode("utf-8")
        except UnicodeDecodeError:
            crop_stdout = crop.stdout.decode("gb18030")
        crop_logs[name] = crop_stdout.strip()
    return analyses, crop_logs


def _validate_runtime(
    outputs: dict[str, Path],
    movement_diagnostics: list[dict[str, object]],
) -> dict[str, object]:
    expected_sizes = {
        "body": (160, 160),
        "movement": (128, 128),
        "portrait": (128, 128),
        "skill1_icon": (128, 128),
        "sniper_bullet": (64, 8),
        "sniper_hit": (288, 48),
        "armed_effect": (384, 32),
    }
    validation: dict[str, object] = {}
    for name, path in outputs.items():
        image = Image.open(path).convert("RGBA")
        if image.size != expected_sizes[name]:
            raise AssertionError(f"{name}: expected {expected_sizes[name]}, got {image.size}")
        rgba = np.array(image, dtype=np.uint8)
        alphas = sorted(int(value) for value in np.unique(rgba[:, :, 3]))
        if any(value not in (0, 255) for value in alphas):
            raise AssertionError(f"{name}: runtime alpha is not binary: {alphas}")
        transparent = rgba[:, :, 3] == 0
        if transparent.any() and np.any(rgba[:, :, :3][transparent] != 0):
            raise AssertionError(f"{name}: transparent RGB is not zeroed")
        visible_colors = {
            tuple(int(channel) for channel in pixel[:3])
            for pixel in rgba.reshape(-1, 4)
            if pixel[3] == 255
        }
        validation[name] = {
            "size": list(image.size),
            "alpha_values": alphas,
            "visible_palette_size": len(visible_colors),
            "sha256": _sha256(path),
        }
    validation["body_animation"] = _validate_body_animation(
        outputs["body"], movement_diagnostics
    )
    validation["approved_movement_animation"] = _validate_approved_movement_animation(
        outputs["movement"]
    )
    validation["ui_portrait_source"] = _validate_ui_portrait(
        outputs["portrait"], outputs["movement"]
    )
    return validation


def _validate_ui_portrait(portrait_path: Path, movement_path: Path) -> dict[str, object]:
    movement = Image.open(movement_path).convert("RGBA")
    expected = movement.crop((0, 0, FRAME_SIZE, FRAME_SIZE)).resize(
        (128, 128),
        Image.Resampling.NEAREST,
    )
    expected = _binary_alpha(expected, threshold=1)
    portrait = Image.open(portrait_path).convert("RGBA")
    if not np.array_equal(
        np.array(portrait, dtype=np.uint8),
        np.array(expected, dtype=np.uint8),
    ):
        raise AssertionError(
            "portrait must be normal_down frame 0 enlarged exactly 4x with nearest-neighbor"
        )
    return {
        "source_animation": "normal_down",
        "source_frame": 0,
        "source_region": [0, 0, FRAME_SIZE, FRAME_SIZE],
        "integer_scale": 4,
        "rgba_byte_identical_to_scaled_source": True,
    }


def _validate_approved_movement_animation(movement_path: Path) -> dict[str, object]:
    movement = Image.open(movement_path).convert("RGBA")
    if movement.size != (128, 128):
        raise AssertionError(f"approved movement must be 128x128, got {movement.size}")
    foot_baselines: list[list[int]] = []
    alpha_centroids: list[list[list[float]]] = []
    visible_pixels: list[list[int]] = []
    body_sizes: list[list[list[int]]] = []
    body_x_ranges = ((5, 25), (7, 27), (5, 25), (7, 27))
    expected_baselines = (
        (24, 23, 24, 23),
        (24, 23, 24, 23),
        (23, 23, 23, 23),
        (23, 23, 23, 23),
    )
    bob_rhythms = (
        (0, -1, 0, -1),
        (0, -1, 0, -1),
        (0, 0, 1, -1),
        (0, 0, 1, -1),
    )
    for row in range(4):
        row_baselines: list[int] = []
        row_centroids: list[list[float]] = []
        row_visible_pixels: list[int] = []
        row_body_sizes: list[list[int]] = []
        for column in range(4):
            frame = movement.crop(
                (
                    column * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (column + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            alpha = np.array(frame.getchannel("A"), dtype=np.uint8) == 255
            visible_y, visible_x = np.where(alpha)
            if len(visible_x) == 0:
                raise AssertionError(f"approved movement row {row} frame {column} is empty")
            baseline = int(visible_y.max())
            expected_baseline = expected_baselines[row][column]
            if baseline != expected_baseline:
                raise AssertionError(
                    f"approved movement row {row} frame {column} baseline "
                    f"{baseline} != {expected_baseline}"
                )
            centroid = [float(visible_x.mean()), float(visible_y.mean())]
            if not 15.0 <= centroid[0] <= 16.0 or not 14.3 <= centroid[1] <= 16.3:
                raise AssertionError(
                    f"approved movement row {row} frame {column} centroid {centroid} is unstable"
                )
            body_left, body_right = body_x_ranges[row]
            body_y, body_x = np.where(alpha[:, body_left:body_right])
            if len(body_x) == 0:
                raise AssertionError(
                    f"approved movement row {row} frame {column} body is empty"
                )
            body_size = [
                int(body_x.max() - body_x.min() + 1),
                int(body_y.max() - body_y.min() + 1),
            ]
            if body_size[0] > 20 or body_size[1] > 20:
                raise AssertionError(
                    f"approved movement row {row} frame {column} body "
                    f"{body_size} exceeds 20x20"
                )
            row_baselines.append(baseline)
            row_centroids.append([round(value, 3) for value in centroid])
            row_visible_pixels.append(int(len(visible_x)))
            row_body_sizes.append(body_size)
        if max(value[0] for value in row_centroids) - min(
            value[0] for value in row_centroids
        ) > 0.9:
            raise AssertionError(f"approved movement row {row} horizontal center drift exceeds 0.9px")
        if max(value[1] for value in row_centroids) - min(
            value[1] for value in row_centroids
        ) > 1.25:
            raise AssertionError(f"approved movement row {row} vertical center drift exceeds 1.25px")
        foot_baselines.append(row_baselines)
        alpha_centroids.append(row_centroids)
        visible_pixels.append(row_visible_pixels)
        body_sizes.append(row_body_sizes)
    return {
        "canonical_source": APPROVED_MOVEMENT_PATH.relative_to(ROOT).as_posix(),
        "canonical_source_sha256": _sha256(APPROVED_MOVEMENT_PATH),
        "runtime_copy_sha256": _sha256(movement_path),
        "byte_identical_to_canonical": (
            APPROVED_MOVEMENT_PATH.read_bytes() == movement_path.read_bytes()
        ),
        "foot_baselines": foot_baselines,
        "bob_rhythms": [list(rhythm) for rhythm in bob_rhythms],
        "body_sizes_excluding_rifle_extension": body_sizes,
        "alpha_centroids": alpha_centroids,
        "visible_pixels": visible_pixels,
    }


def _validate_body_animation(
    body_path: Path,
    movement_diagnostics: list[dict[str, object]],
) -> dict[str, object]:
    body = Image.open(body_path).convert("RGBA")
    if len(movement_diagnostics) != 16:
        raise AssertionError(
            f"movement diagnostics must contain 16 frames, got {len(movement_diagnostics)}"
        )
    foot_baselines: list[list[int]] = []
    alpha_centroids: list[list[list[float]]] = []
    area_errors: list[list[float]] = []
    eye_centroids: dict[str, list[list[float]]] = {}
    eye_colors = np.array(
        ((92, 23, 63), (139, 37, 91), (184, 62, 118), (205, 100, 151)),
        dtype=np.uint8,
    )
    for row in range(4):
        row_baselines: list[int] = []
        row_centroids: list[list[float]] = []
        row_area_errors: list[float] = []
        for column in range(4):
            frame = body.crop(
                (
                    column * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (column + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                raise AssertionError(f"body row {row} frame {column} is empty")
            logical_width, logical_height, target_x, target_y, *_rest = MOVEMENT_FRAME_SPECS[row][column]
            expected_bbox = (
                target_x,
                target_y,
                target_x + logical_width,
                target_y + logical_height,
            )
            if bbox != expected_bbox:
                raise AssertionError(
                    f"body row {row} frame {column} bbox {bbox} != {expected_bbox}"
                )
            row_baselines.append(bbox[3] - 1)
            expected_baseline = 26 if row < 2 else 25
            if row_baselines[-1] != expected_baseline:
                raise AssertionError(
                    f"body row {row} frame {column} baseline "
                    f"{row_baselines[-1]} != {expected_baseline}"
                )

            alpha = np.array(frame.getchannel("A"), dtype=np.uint8) == 255
            visible_y, visible_x = np.where(alpha)
            centroid = [float(visible_x.mean()), float(visible_y.mean())]
            if not 15.05 <= centroid[0] <= 15.95 or not 15.35 <= centroid[1] <= 15.75:
                raise AssertionError(
                    f"body row {row} frame {column} centroid {centroid} lost the authored axis"
                )
            row_centroids.append([round(value, 3) for value in centroid])

            diagnostics = movement_diagnostics[row * 4 + column]
            area_error = float(diagnostics["area_error_percent"])
            if area_error > 8.0:
                raise AssertionError(
                    f"body row {row} frame {column} logical area error {area_error}% > 8%"
                )
            row_area_errors.append(area_error)
            alpha_iou = float(diagnostics["source_reprojection_alpha_iou"])
            if alpha_iou < 0.92:
                raise AssertionError(
                    f"body row {row} frame {column} source reprojection IoU {alpha_iou} < 0.92"
                )

            if row in (0, 2, 3):
                rgba = np.array(frame, dtype=np.uint8)
                eye_mask = np.any(
                    np.all(rgba[:, :, None, :3] == eye_colors[None, None, :, :], axis=3),
                    axis=2,
                )
                eye_mask[18:] = False
                eye_y, eye_x = np.where(eye_mask)
                if len(eye_x) == 0:
                    raise AssertionError(f"body row {row} frame {column} lost eye pixels")
                eye_centroid = [round(float(eye_x.mean()), 3), round(float(eye_y.mean()), 3)]
                expected_eye = {0: (16.0, 12.5), 2: (19.0, 12.5), 3: (12.0, 12.5)}[row]
                if any(abs(eye_centroid[index] - expected_eye[index]) > 0.01 for index in range(2)):
                    raise AssertionError(
                        f"body row {row} frame {column} eye {eye_centroid} != {expected_eye}"
                    )
                eye_centroids.setdefault(MOVEMENT_DIRECTION_NAMES[row], []).append(eye_centroid)
        foot_baselines.append(row_baselines)
        alpha_centroids.append(row_centroids)
        area_errors.append(row_area_errors)
        x_span = max(centroid[0] for centroid in row_centroids) - min(
            centroid[0] for centroid in row_centroids
        )
        y_span = max(centroid[1] for centroid in row_centroids) - min(
            centroid[1] for centroid in row_centroids
        )
        if x_span > 0.9 or y_span > 0.35:
            raise AssertionError(
                f"body row {row} axis drift too large: x={x_span:.3f}, y={y_span:.3f}"
            )

    death_strip = body.crop((0, 4 * FRAME_SIZE, 5 * FRAME_SIZE, 5 * FRAME_SIZE))
    death_colors = {
        tuple(pixel[:3])
        for pixel in death_strip.getdata()
        if pixel[3] == 255
    }
    if not death_colors.issubset(set(DEATH_PURPLE_PALETTE)):
        raise AssertionError("death frames contain colors outside the fixed purple scale")
    return {
        "decode_method": "per-frame 8/9px integer lattice, central 60% palette mode",
        "authored_frames_preserved": True,
        "runtime_resize_applied": False,
        "foot_baselines": foot_baselines,
        "alpha_centroids": alpha_centroids,
        "logical_area_error_percent": area_errors,
        "eye_centroids": eye_centroids,
        "minimum_source_reprojection_alpha_iou": min(
            float(frame["source_reprojection_alpha_iou"]) for frame in movement_diagnostics
        ),
        "death_palette": ["#%02X%02X%02X" % color for color in sorted(death_colors)],
    }


def _write_readme() -> None:
    readme = """# 提伊像素素材源与处理说明

本目录保留五张内置 imagegen 生成的 `*_source.png` 原图、官方色键脚本生成的
`*_alpha.png`，以及项目 `pixel_crop_tool.py` 的可复核裁切结果。运行
`python dev_tools/process_tiyi_assets.py` 可确定性重建全部运行时图集、动画资源与
`manifest.json`。

## 动画设计依据

维什戴尔图集看起来在移动，关键并不是频繁改脸，而是稳定的视觉轴、交替的腿脚
接触点，以及很克制的身体起伏。`movement_alpha.png` 已经正确作者化了提伊的四拍
动作。人工监修母版 `movement_logical_lossless.png` 再经过结构化逐行收拢，得到已批准的
`movement_scale1_20px_candidate.png`：主体排除枪支延伸后不超过 20×20，完整面部块
逐 RGBA 保留，且没有插值或新增颜色。最终四拍按维什戴尔的节奏加入整数像素起伏；
正背面为 `0,-1,0,-1px`，侧面上半身为 `0,0,+1,-1px`，腿脚接地点保持稳定。

## 精确逻辑像素解码

移动源图不是普通连续色插画，而是把一个逻辑像素放大成约 8.5–8.8 个物理像素的
作者化像素板。处理器按以下固定步骤解码，完全不对人物外包框执行 resize：

1. 在完整源图上一次性标记连通域，取得 16 个完整人物，避免分行裁切漏掉脚底像素。
2. 每帧独立使用测得的横纵周期与相位，把格界量化为连续的 8/9px 整数单元。
3. 每个单元只统计中央 60%：Alpha 覆盖达到 50% 才视为可见，再对有限角色调色板
   的索引取众数，从而排除色键边缘和任意单点采样造成的抖动。
4. 保留得到的 22–27×23–24 逻辑轮廓，以作者化人物轴直接放入 32×32 单元。
   down/up 脚底固定在 y=26，right/left 固定在 y=25。
5. 自动验证每帧包围盒、Alpha 质心、同方向轴漂移和“源可见面积÷格面积”的误差；
   面积误差上限为 8%，当前清单记录每一帧的实际结果。

## 运行时布局

- `movement.png`: 128×128，逐字节复制已经批准的
  `movement_scale1_20px_candidate.png`；运行时四方向动画以此文件为唯一权威素材，
  不重新压缩、不调色，场景使用整数 `scale=1`。
- `body.png`: 160×160，保留生成管线与最后一行五帧紫色死亡特效；运行时死亡
  动画只读取其第五行。
- `sniper_bullet.png`: 64×8，两帧 32×8。
- `sniper_hit.png`: 288×48，六帧 48×48。
- `armed_effect.png`: 384×32，八帧 48×32，复用维什戴尔几何并确定性改为紫色阶。
- `portrait.png`: 取 `normal_down` 第 0 帧的完整 32×32 单元，以最近邻严格放大
  4 倍至 128×128，供角色选择卡牌与背包左侧个人数据共同使用。
- `skill1_icon.png`: 128×128，继续使用独立技能图标源。

运行时 PNG 只含 0/255 Alpha，透明像素 RGB 清零；移动人物不经过缩放，其他需要
适配固定画布的图集才使用最近邻。死亡和武装特效固定使用
`#3B1C4E / #75409A / #B05ADD / #E7B6FF`。
"""
    (SOURCE_DIR / "README.md").write_text(readme, encoding="utf-8", newline="\n")


def main() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    ANIMATION_PATH.parent.mkdir(parents=True, exist_ok=True)
    for name in SOURCE_NAMES:
        for suffix in ("source", "alpha"):
            path = SOURCE_DIR / f"{name}_{suffix}.png"
            if not path.is_file():
                raise FileNotFoundError(path)
    for approved_path in (APPROVED_MOVEMENT_PATH, APPROVED_MOVEMENT_REPORT_PATH):
        if not approved_path.is_file():
            raise FileNotFoundError(approved_path)

    analyses, crop_logs = _run_pixel_tools()
    body, movement_diagnostics = _build_body()
    bullet = _build_bullet()
    hit = _build_hit()
    portrait, skill_icon = _build_portrait_and_icon()
    armed_effect = _build_armed_effect()

    images = {
        "body": body,
        "portrait": portrait,
        "skill1_icon": skill_icon,
        "sniper_bullet": bullet,
        "sniper_hit": hit,
        "armed_effect": armed_effect,
    }
    output_paths: dict[str, Path] = {}
    for name, image in images.items():
        path = OUTPUT_DIR / f"{name}.png"
        _binary_alpha(image).save(path, optimize=True)
        output_paths[name] = path
    approved_movement_output = OUTPUT_DIR / "movement.png"
    shutil.copyfile(APPROVED_MOVEMENT_PATH, approved_movement_output)
    output_paths["movement"] = approved_movement_output

    ANIMATION_PATH.write_text(_animation_resource(), encoding="utf-8", newline="\n")
    validation = _validate_runtime(output_paths, movement_diagnostics)
    _write_readme()

    source_records: dict[str, object] = {}
    for name in SOURCE_NAMES:
        source_path = SOURCE_DIR / f"{name}_source.png"
        alpha_path = SOURCE_DIR / f"{name}_alpha.png"
        crop_path = SOURCE_DIR / f"{name}_crop_tool.png"
        source_records[name] = {
            "imagegen_file": IMAGEGEN_FILES[name],
            "source": {
                "path": source_path.relative_to(ROOT).as_posix(),
                "sha256": _sha256(source_path),
            },
            "alpha": {
                "path": alpha_path.relative_to(ROOT).as_posix(),
                "sha256": _sha256(alpha_path),
            },
            "pixel_grid_analysis": analyses[name],
            "pixel_crop": {
                "path": crop_path.relative_to(ROOT).as_posix(),
                "sha256": _sha256(crop_path),
                "stdout": crop_logs[name],
            },
        }

    manifest = {
        "schema_version": 2,
        "generator": "built-in imagegen",
        "processor": "dev_tools/process_tiyi_assets.py",
        "source_records": source_records,
        "tool_commands": {
            "remove_chroma_key": (
                "python C:/Users/wh/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py "
                "--input <name>_source.png --out <name>_alpha.png --auto-key border "
                "--soft-matte --transparent-threshold 12 --opaque-threshold 220 --despill --force"
            ),
            "pixel_grid_analyzer": "python dev_tools/pixel_grid_analyzer.py <name>_alpha.png --json",
            "pixel_crop_tool": (
                "python dev_tools/pixel_crop_tool.py <name>_alpha.png <name>_crop_tool.png "
                "--padding 0 --alpha-threshold 127"
            ),
            "processor": "python dev_tools/process_tiyi_assets.py",
            "movement_20px_builder": "python dev_tools/process_tiyi_20px_candidate.py",
        },
        "runtime": validation,
        "movement_logical_decode": {
            "source": "dev_assets/source_images/player_tiyi/movement_alpha.png",
            "component_detection": "whole-image connected components",
            "cell_boundaries": "per-frame measured lattice rounded to contiguous 8/9px cells",
            "cell_sample": "central 60%, alpha coverage >= 50%, nearest-palette index mode",
            "runtime_resize": False,
            "frames": movement_diagnostics,
        },
        "animation": {
            "path": ANIMATION_PATH.relative_to(ROOT).as_posix(),
            "movement_grid": "approved movement.png: 4 columns x 4 rows, 32x32 cells",
            "death_grid": "body.png row 4: 5 columns, 32x32 cells",
            "runtime_uses_approved_movement": True,
            "normal": {"directions": ["down", "up", "right", "left"], "frames": 4, "fps": 8, "loop": True},
            "standing_animation": "reuses the active 8 FPS normal/armed directional loop",
            "ui_portrait": {
                "animation": "normal_down",
                "frame": 0,
                "region": [0, 0, 32, 32],
                "integer_scale": 4,
                "consumers": ["character selection card", "player profile inventory panel"],
            },
            "armed": {"directions": ["down", "up", "right", "left"], "frames": 4, "fps": 8, "loop": True},
            "death": {"frames": 5, "fps": 10, "loop": False, "last_frame_fully_transparent": True},
            "authored_movement_frames_preserved": True,
        },
        "fixed_palettes": {
            "death_and_armed": ["#%02X%02X%02X" % color for color in DEATH_PURPLE_PALETTE],
            "runtime_alpha": [0, 255],
        },
        "provenance": {
            "approved_movement_source": APPROVED_MOVEMENT_PATH.relative_to(ROOT).as_posix(),
            "approved_movement_source_sha256": _sha256(APPROVED_MOVEMENT_PATH),
            "approved_movement_report": APPROVED_MOVEMENT_REPORT_PATH.relative_to(ROOT).as_posix(),
            "approved_movement_report_sha256": _sha256(APPROVED_MOVEMENT_REPORT_PATH),
            "portrait_source": APPROVED_MOVEMENT_PATH.relative_to(ROOT).as_posix(),
            "portrait_source_region": [0, 0, 32, 32],
            "portrait_integer_scale": 4,
            "approved_movement_runtime_path": approved_movement_output.relative_to(ROOT).as_posix(),
            "approved_movement_runtime_byte_identical": (
                APPROVED_MOVEMENT_PATH.read_bytes() == approved_movement_output.read_bytes()
            ),
            "armed_effect_geometry": WEISH_ARMED_EFFECT.relative_to(ROOT).as_posix(),
            "armed_effect_geometry_sha256": _sha256(WEISH_ARMED_EFFECT),
        },
    }
    manifest_path = SOURCE_DIR / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"Tiyi runtime assets written to {OUTPUT_DIR}")
    print(f"SpriteFrames written to {ANIMATION_PATH}")
    print(f"Manifest written to {manifest_path}")


if __name__ == "__main__":
    main()
