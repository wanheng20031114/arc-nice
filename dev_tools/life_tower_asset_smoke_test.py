#!/usr/bin/env python3
"""Validate the native Life Tower sprite-layer contract."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image


EXPECTED_SIZE = (64, 64)
EXPECTED_VISIBLE_COLORS = 53
EXPECTED_HEART_BBOX = (24, 23, 40, 37)
EXPECTED_BASE_BBOX = (9, 28, 54, 57)
EXPECTED_HEART_PIXELS = 166
EXPECTED_BASE_PIXELS = 878
EXPECTED_HEART_ROW_WIDTHS = [8, 12, 16, 16, 16, 16, 16, 14, 14, 12, 10, 8, 6, 2]
SIDE_FLOWER_ORIGINS = ((14, 36), (44, 36))
SIDE_FLOWER_TEMPLATE = np.array(
    [
        [0, 0, 1, 0, 0],
        [1, 1, 1, 1, 1],
        [1, 1, 2, 1, 1],
        [0, 1, 1, 1, 0],
        [0, 1, 0, 1, 0],
    ],
    dtype=np.uint8,
)
SIDE_FLOWER_WHITE = np.array([253, 253, 253], dtype=np.uint8)
SIDE_FLOWER_CENTER = np.array([251, 200, 2], dtype=np.uint8)


def _load_rgba(path: Path) -> np.ndarray:
    if not path.is_file():
        raise AssertionError(f"missing asset: {path}")
    image = Image.open(path)
    if image.size != EXPECTED_SIZE:
        raise AssertionError(
            f"{path.name} must be 64x64, got {image.width}x{image.height}"
        )
    return np.asarray(image.convert("RGBA"), dtype=np.uint8)


def _assert_clean_alpha(name: str, array: np.ndarray) -> None:
    alpha_values = set(int(value) for value in np.unique(array[:, :, 3]))
    if not alpha_values.issubset({0, 255}):
        raise AssertionError(f"{name} has non-binary alpha: {alpha_values}")
    transparent = array[:, :, 3] == 0
    if np.any(array[:, :, :3][transparent] != 0):
        raise AssertionError(f"{name} has RGB residue under transparent pixels")


def main() -> None:
    texture_root = Path(
        sys.argv[1]
        if len(sys.argv) > 1
        else "resources/texture/plant_defense/life_tower"
    )
    master = _load_rgba(texture_root / "life_tower.png")
    lower = _load_rgba(texture_root / "layers" / "lower_body.png")
    heart = _load_rgba(texture_root / "layers" / "heart_foreground.png")

    _assert_clean_alpha("master", master)
    _assert_clean_alpha("lower_body", lower)
    _assert_clean_alpha("heart_foreground", heart)

    lower_visible = lower[:, :, 3] > 0
    heart_visible = heart[:, :, 3] > 0
    overlap_count = int(np.count_nonzero(lower_visible & heart_visible))
    if overlap_count != 0:
        raise AssertionError(f"static layers overlap at {overlap_count} pixels")

    reconstructed = lower.copy()
    reconstructed[heart_visible] = heart[heart_visible]
    if not np.array_equal(reconstructed, master):
        raise AssertionError("lower + heart does not reconstruct life_tower.png")

    visible_colors = np.unique(master[:, :, :3][master[:, :, 3] > 0], axis=0)
    if len(visible_colors) != EXPECTED_VISIBLE_COLORS:
        raise AssertionError(
            f"visible palette has {len(visible_colors)} colors; "
            f"expected {EXPECTED_VISIBLE_COLORS}"
        )

    heart_bbox = Image.fromarray(heart[:, :, 3], mode="L").getbbox()
    if heart_bbox != EXPECTED_HEART_BBOX:
        raise AssertionError(
            f"heart bbox is {heart_bbox}; expected {EXPECTED_HEART_BBOX}"
        )
    heart_pixels = int(heart_visible.sum())
    if heart_pixels != EXPECTED_HEART_PIXELS:
        raise AssertionError(
            f"heart has {heart_pixels} pixels; expected {EXPECTED_HEART_PIXELS}"
        )
    if not np.array_equal(heart_visible, np.fliplr(heart_visible)):
        raise AssertionError("heart silhouette is not horizontally symmetric")
    heart_rows = heart_visible[
        EXPECTED_HEART_BBOX[1]:EXPECTED_HEART_BBOX[3],
        EXPECTED_HEART_BBOX[0]:EXPECTED_HEART_BBOX[2],
    ].sum(axis=1).tolist()
    if heart_rows != EXPECTED_HEART_ROW_WIDTHS:
        raise AssertionError(
            f"heart row widths are {heart_rows}; "
            f"expected {EXPECTED_HEART_ROW_WIDTHS}"
        )

    base_bbox = Image.fromarray(lower[:, :, 3], mode="L").getbbox()
    if base_bbox != EXPECTED_BASE_BBOX:
        raise AssertionError(
            f"base bbox is {base_bbox}; expected {EXPECTED_BASE_BBOX}"
        )
    base_pixels = int(lower_visible.sum())
    if base_pixels != EXPECTED_BASE_PIXELS:
        raise AssertionError(
            f"base has {base_pixels} pixels; expected {EXPECTED_BASE_PIXELS}"
        )
    base_region = lower_visible[
        EXPECTED_BASE_BBOX[1]:EXPECTED_BASE_BBOX[3],
        EXPECTED_BASE_BBOX[0]:EXPECTED_BASE_BBOX[2],
    ]
    if not np.array_equal(base_region, np.fliplr(base_region)):
        raise AssertionError("base silhouette is not horizontally symmetric")

    side_flower_masks = []
    for origin_x, origin_y in SIDE_FLOWER_ORIGINS:
        flower_rgb = lower[
            origin_y:origin_y + 5,
            origin_x:origin_x + 5,
            :3,
        ]
        flower_mask = np.zeros((5, 5), dtype=np.uint8)
        flower_mask[np.all(flower_rgb == SIDE_FLOWER_WHITE, axis=2)] = 1
        flower_mask[np.all(flower_rgb == SIDE_FLOWER_CENTER, axis=2)] = 2
        if not np.array_equal(flower_mask, SIDE_FLOWER_TEMPLATE):
            raise AssertionError(
                f"side flower at {(origin_x, origin_y)} is malformed: "
                f"{flower_mask.tolist()}"
            )
        side_flower_masks.append(flower_mask)
        stale_top = lower[origin_y - 1, origin_x:origin_x + 5, :3]
        if np.any(np.all(stale_top == SIDE_FLOWER_WHITE, axis=1)):
            raise AssertionError(
                f"side flower at {(origin_x, origin_y)} retains a sixth row"
            )
    if not np.array_equal(side_flower_masks[0], side_flower_masks[1]):
        raise AssertionError("left and right side flowers do not match")

    heart_colors = heart[:, :, :3][heart_visible]
    if not np.any(np.all(heart_colors >= np.array([245, 245, 245]), axis=1)):
        raise AssertionError("heart white highlight was lost during color reduction")

    magenta_like = (
        (master[:, :, 3] > 0)
        & (master[:, :, 0] > 200)
        & (master[:, :, 2] > 180)
        & (master[:, :, 1] < 80)
    )
    if np.any(magenta_like):
        raise AssertionError("visible chroma-key residue remains in the sprite")

    print("LIFE_TOWER_ASSET_SMOKE_OK")
    print(f"visible_colors={len(visible_colors)}")
    print(f"lower_pixels={base_pixels}")
    print(f"heart_pixels={heart_pixels}")
    print(f"static_overlap={overlap_count}")


if __name__ == "__main__":
    main()
