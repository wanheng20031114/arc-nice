#!/usr/bin/env python3
"""Build Tiyi's High Noon casting loop from its approved imagegen source."""

from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = (
    ROOT / "dev_assets" / "source_images" / "player_tiyi" / "high_noon_cast_source.png"
)
OUTPUT_PATH = (
    ROOT / "resources" / "texture" / "player" / "tiyi" / "high_noon_cast.png"
)

SOURCE_SIZE = (2172, 724)
FRAME_COUNT = 7
UNITS_PER_FRAME = 5
SOURCE_CROP_SIZE = 272
LOGICAL_EFFECT_SIZE = 32
FRAME_SIZE = (64, 48)
ORBIT_OUTWARD_SHIFT = 8.0
MIN_UNIT_AREA = 1000
PURPLE_PALETTE = np.array(
    (
        (0x3B, 0x1C, 0x4E),
        (0x75, 0x40, 0x9A),
        (0xB0, 0x5A, 0xDD),
        (0xE7, 0xB6, 0xFF),
    ),
    dtype=np.uint8,
)


def _foreground_mask(source: np.ndarray) -> np.ndarray:
    red = source[:, :, 0].astype(np.float32)
    green = source[:, :, 1].astype(np.float32)
    blue = source[:, :, 2].astype(np.float32)
    chroma_green = (
        (green > 120.0)
        & (green > red * 1.35)
        & (green > blue * 1.20)
    )
    return ~chroma_green


def _collect_unit_components(
    mask: np.ndarray,
) -> tuple[np.ndarray, list[tuple[int, tuple[slice, slice]]]]:
    labels, _label_count = ndimage.label(
        mask,
        structure=np.ones((3, 3), dtype=np.uint8),
    )
    components: list[tuple[int, tuple[slice, slice]]] = []
    for label_index, bounds in enumerate(ndimage.find_objects(labels), start=1):
        if bounds is None:
            continue
        area = int((labels[bounds] == label_index).sum())
        if area >= MIN_UNIT_AREA:
            components.append((label_index, bounds))
    expected_count = FRAME_COUNT * UNITS_PER_FRAME
    if len(components) != expected_count:
        raise AssertionError(
            f"expected {expected_count} casting units, found {len(components)}"
        )
    components.sort(
        key=lambda component: (
            component[1][1].start + component[1][1].stop,
            component[1][0].start + component[1][0].stop,
        )
    )
    return labels, components


def _clean_source(
    source: np.ndarray,
    labels: np.ndarray,
    components: list[tuple[int, tuple[slice, slice]]],
) -> Image.Image:
    keep = np.zeros(labels.shape, dtype=bool)
    for label_index, _bounds in components:
        keep |= labels == label_index
    rgba = np.zeros((*labels.shape, 4), dtype=np.uint8)
    rgba[:, :, :3][keep] = source[:, :, :3][keep]
    rgba[:, :, 3][keep] = 255
    return Image.fromarray(rgba)


def _component_center(bounds: tuple[slice, slice]) -> tuple[float, float]:
    vertical, horizontal = bounds
    return (
        (horizontal.start + horizontal.stop) * 0.5,
        (vertical.start + vertical.stop) * 0.5,
    )


def _map_to_purple_palette(frame: Image.Image) -> Image.Image:
    rgba = np.asarray(frame.convert("RGBA"), dtype=np.uint8).copy()
    visible = rgba[:, :, 3] >= 128
    rgba[:, :, 3] = np.where(visible, 255, 0).astype(np.uint8)
    if visible.any():
        luminance = (
            rgba[:, :, 0].astype(np.uint16) * 54
            + rgba[:, :, 1].astype(np.uint16) * 183
            + rgba[:, :, 2].astype(np.uint16) * 19
        ) // 256
        palette_indices = np.clip(luminance // 64, 0, 3)
        rgba[:, :, :3][visible] = PURPLE_PALETTE[palette_indices[visible]]
    rgba[~visible] = (0, 0, 0, 0)
    return Image.fromarray(rgba)


def _move_units_outward(logical: Image.Image) -> tuple[Image.Image, list[float]]:
    rgba = np.asarray(logical.convert("RGBA"), dtype=np.uint8)
    labels, unit_count = ndimage.label(
        rgba[:, :, 3] == 255,
        structure=np.ones((3, 3), dtype=np.uint8),
    )
    if unit_count != UNITS_PER_FRAME:
        raise AssertionError(
            f"logical frame has {unit_count} casting units, expected {UNITS_PER_FRAME}"
        )

    expanded = np.zeros((FRAME_SIZE[1], FRAME_SIZE[0], 4), dtype=np.uint8)
    logical_center = np.array(
        ((LOGICAL_EFFECT_SIZE - 1) * 0.5, (LOGICAL_EFFECT_SIZE - 1) * 0.5),
        dtype=np.float32,
    )
    expanded_center = np.array(
        ((FRAME_SIZE[0] - 1) * 0.5, (FRAME_SIZE[1] - 1) * 0.5),
        dtype=np.float32,
    )
    radial_shifts: list[float] = []
    for label_index in range(1, unit_count + 1):
        vertical, horizontal = np.where(labels == label_index)
        component_center = np.array(
            (float(horizontal.mean()), float(vertical.mean())),
            dtype=np.float32,
        )
        radial_vector = component_center - logical_center
        radius = float(np.linalg.norm(radial_vector))
        if radius <= 0.0:
            raise AssertionError("casting unit cannot overlap the animation center")
        radial_direction = radial_vector / radius
        desired_center = (
            expanded_center
            + radial_direction * (radius + ORBIT_OUTWARD_SHIFT)
        )
        translation = np.rint(desired_center - component_center).astype(np.int32)
        target_horizontal = horizontal + int(translation[0])
        target_vertical = vertical + int(translation[1])
        if (
            target_horizontal.min() < 0
            or target_horizontal.max() >= FRAME_SIZE[0]
            or target_vertical.min() < 0
            or target_vertical.max() >= FRAME_SIZE[1]
        ):
            raise AssertionError("outward casting-unit shift exceeds the frame canvas")
        expanded[target_vertical, target_horizontal] = rgba[vertical, horizontal]
        shifted_center = component_center + translation.astype(np.float32)
        shifted_radius = float(np.linalg.norm(shifted_center - expanded_center))
        radial_shifts.append(shifted_radius - radius)
    return Image.fromarray(expanded), radial_shifts


def _build_sheet(
    source: Image.Image,
) -> tuple[Image.Image, list[int], list[float]]:
    source_array = np.asarray(source.convert("RGB"), dtype=np.uint8)
    mask = _foreground_mask(source_array)
    labels, components = _collect_unit_components(mask)
    cleaned = _clean_source(source_array, labels, components)

    sheet = Image.new(
        "RGBA",
        (FRAME_SIZE[0] * FRAME_COUNT, FRAME_SIZE[1]),
        (0, 0, 0, 0),
    )
    visible_counts: list[int] = []
    radial_shifts: list[float] = []
    for frame_index in range(FRAME_COUNT):
        frame_components = components[
            frame_index * UNITS_PER_FRAME : (frame_index + 1) * UNITS_PER_FRAME
        ]
        centers = np.array(
            [_component_center(bounds) for _label_index, bounds in frame_components],
            dtype=np.float32,
        )
        center_x, center_y = centers.mean(axis=0)
        left = int(round(float(center_x) - SOURCE_CROP_SIZE * 0.5))
        top = int(round(float(center_y) - SOURCE_CROP_SIZE * 0.5))
        crop = cleaned.crop(
            (left, top, left + SOURCE_CROP_SIZE, top + SOURCE_CROP_SIZE)
        )
        logical = crop.resize(
            (LOGICAL_EFFECT_SIZE, LOGICAL_EFFECT_SIZE),
            Image.Resampling.NEAREST,
        )
        logical = _map_to_purple_palette(logical)
        expanded, frame_radial_shifts = _move_units_outward(logical)
        radial_shifts.extend(frame_radial_shifts)
        visible_counts.append(
            int(np.count_nonzero(np.asarray(expanded)[:, :, 3] == 255))
        )
        sheet.alpha_composite(
            expanded,
            (frame_index * FRAME_SIZE[0], 0),
        )
    return sheet, visible_counts, radial_shifts


def _validate(
    sheet: Image.Image,
    visible_counts: list[int],
    radial_shifts: list[float],
) -> None:
    expected_size = (FRAME_SIZE[0] * FRAME_COUNT, FRAME_SIZE[1])
    if sheet.size != expected_size:
        raise AssertionError(f"unexpected sheet size: {sheet.size}")
    rgba = np.asarray(sheet, dtype=np.uint8)
    alpha_values = set(np.unique(rgba[:, :, 3]).tolist())
    if not alpha_values.issubset({0, 255}):
        raise AssertionError(f"non-binary alpha values: {sorted(alpha_values)}")
    transparent = rgba[:, :, 3] == 0
    if np.any(rgba[:, :, :3][transparent] != 0):
        raise AssertionError("transparent pixels must have zero RGB")
    visible_colors = {
        tuple(color)
        for color in rgba[:, :, :3][~transparent].reshape(-1, 3).tolist()
    }
    allowed_colors = {tuple(color) for color in PURPLE_PALETTE.tolist()}
    if not visible_colors.issubset(allowed_colors):
        raise AssertionError("casting effect contains colors outside the purple palette")
    if min(visible_counts) < 100 or max(visible_counts) > 220:
        raise AssertionError(f"unexpected per-frame pixel density: {visible_counts}")
    if min(radial_shifts) < 7.0 or max(radial_shifts) > 9.0:
        raise AssertionError(f"unexpected radial shifts: {radial_shifts}")
    for frame_index in range(FRAME_COUNT):
        frame_alpha = rgba[
            :,
            frame_index * FRAME_SIZE[0] : (frame_index + 1) * FRAME_SIZE[0],
            3,
        ]
        _labels, unit_count = ndimage.label(
            frame_alpha == 255,
            structure=np.ones((3, 3), dtype=np.uint8),
        )
        if unit_count != UNITS_PER_FRAME:
            raise AssertionError(
                f"frame {frame_index} has {unit_count} casting units, "
                f"expected {UNITS_PER_FRAME}"
            )


def main() -> None:
    source = Image.open(SOURCE_PATH).convert("RGB")
    if source.size != SOURCE_SIZE:
        raise AssertionError(f"unexpected source size: {source.size}")
    sheet, visible_counts, radial_shifts = _build_sheet(source)
    _validate(sheet, visible_counts, radial_shifts)
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUTPUT_PATH, optimize=True)
    digest = hashlib.sha256(OUTPUT_PATH.read_bytes()).hexdigest()
    print(f"Wrote {OUTPUT_PATH.relative_to(ROOT).as_posix()}")
    print(f"Frame visible pixels: {visible_counts}")
    print(
        "Radial shifts: "
        f"min={min(radial_shifts):.3f}, max={max(radial_shifts):.3f}"
    )
    print(f"SHA256: {digest}")


if __name__ == "__main__":
    main()
