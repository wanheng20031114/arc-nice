#!/usr/bin/env python3
"""Validate the Attack Speed Tower's native asset and lineage contract."""

from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
from PIL import Image

from build_attack_speed_tower_assets import (
    DEFAULT_LOWER_PATH,
    DEFAULT_OUTPUT_ROOT,
    DEFAULT_PREVIEW_ROOT,
    DEFAULT_SOURCE_PATH,
    DESTINATION,
    EXPECTED_LOWER_SHA256,
    MAX_VISIBLE_EXTENT,
    SOURCE_LOGICAL_SIZE,
    build_assets,
)


EXPECTED_SIZE = (64, 64)
EXPECTED_FOREGROUND_BBOX = (24, 20, 41, 34)
EXPECTED_FOREGROUND_PIXELS = 174
EXPECTED_FOREGROUND_COLORS = 16
EXPECTED_MASTER_PIXELS = 1052
EXPECTED_MASTER_COLORS = 53
EXPECTED_ROW_WIDTHS = [6, 9, 11, 13, 16, 15, 17, 17, 15, 16, 13, 11, 9, 6]
PREVIEW_SIZE = (512, 512)
GIF_FRAMES = 40
GIF_FRAME_DURATION_MS = 50


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_rgba(path: Path, expected_size: tuple[int, int]) -> np.ndarray:
    if not path.is_file():
        raise AssertionError(f"missing asset: {path}")
    with Image.open(path) as source:
        if source.size != expected_size:
            raise AssertionError(
                f"{path.name} must be {expected_size}, got {source.size}"
            )
        return np.asarray(source.convert("RGBA"), dtype=np.uint8)


def _assert_clean_binary_alpha(name: str, array: np.ndarray) -> None:
    alpha_values = set(int(value) for value in np.unique(array[:, :, 3]))
    if not alpha_values.issubset({0, 255}):
        raise AssertionError(f"{name} has non-binary alpha: {alpha_values}")
    transparent = array[:, :, 3] == 0
    if np.any(array[:, :, :3][transparent] != 0):
        raise AssertionError(f"{name} has RGB residue under transparent pixels")


def main() -> None:
    foreground_path = DEFAULT_OUTPUT_ROOT / "layers/speed_foreground.png"
    master_path = DEFAULT_OUTPUT_ROOT / "attack_speed_tower.png"
    preview_path = (
        DEFAULT_PREVIEW_ROOT / "attack_speed_tower_runtime_preview_8x.png"
    )
    gif_path = DEFAULT_PREVIEW_ROOT / "attack_speed_tower_bob_preview.gif"
    forbidden_base_copy = DEFAULT_OUTPUT_ROOT / "layers/lower_body.png"

    if forbidden_base_copy.exists():
        raise AssertionError(
            "Attack Speed Tower must reference the Life Tower base directly; "
            "a copied lower_body.png is forbidden"
        )
    if _sha256(DEFAULT_LOWER_PATH) != EXPECTED_LOWER_SHA256:
        raise AssertionError("formal Life Tower lower_body.png changed")

    foreground = _load_rgba(foreground_path, EXPECTED_SIZE)
    master = _load_rgba(master_path, EXPECTED_SIZE)
    lower = _load_rgba(DEFAULT_LOWER_PATH, EXPECTED_SIZE)
    preview = _load_rgba(preview_path, PREVIEW_SIZE)
    _assert_clean_binary_alpha("speed_foreground", foreground)
    _assert_clean_binary_alpha("attack_speed_tower", master)
    _assert_clean_binary_alpha("formal lower_body", lower)
    _assert_clean_binary_alpha("runtime preview", preview)

    foreground_visible = foreground[:, :, 3] > 0
    lower_visible = lower[:, :, 3] > 0
    foreground_bbox = Image.fromarray(
        foreground[:, :, 3],
        mode="L",
    ).getbbox()
    if foreground_bbox != EXPECTED_FOREGROUND_BBOX:
        raise AssertionError(
            f"foreground bbox is {foreground_bbox}; "
            f"expected {EXPECTED_FOREGROUND_BBOX}"
        )
    visible_width = foreground_bbox[2] - foreground_bbox[0]
    visible_height = foreground_bbox[3] - foreground_bbox[1]
    if visible_width > MAX_VISIBLE_EXTENT or visible_height > MAX_VISIBLE_EXTENT:
        raise AssertionError(
            f"foreground exceeds 17x17: {visible_width}x{visible_height}"
        )
    if (visible_width, visible_height) != SOURCE_LOGICAL_SIZE:
        raise AssertionError(
            f"foreground is {visible_width}x{visible_height}; "
            f"expected {SOURCE_LOGICAL_SIZE}"
        )
    if int(foreground_visible.sum()) != EXPECTED_FOREGROUND_PIXELS:
        raise AssertionError("foreground pixel count changed")
    destination_x, destination_y = DESTINATION
    row_widths = foreground_visible[
        destination_y:destination_y + visible_height,
        destination_x:destination_x + visible_width,
    ].sum(axis=1).tolist()
    if row_widths != EXPECTED_ROW_WIDTHS:
        raise AssertionError(
            f"foreground row widths changed: {row_widths}"
        )
    foreground_colors = np.unique(
        foreground[:, :, :3][foreground_visible],
        axis=0,
    )
    if len(foreground_colors) != EXPECTED_FOREGROUND_COLORS:
        raise AssertionError(
            f"foreground palette has {len(foreground_colors)} colors"
        )
    if not np.any(
        (foreground_colors[:, 2] >= 240)
        & (foreground_colors[:, 1] >= 200)
    ):
        raise AssertionError("electric-cyan/white speed highlight was lost")
    if not np.any(
        (foreground_colors[:, 2] >= 220)
        & (foreground_colors[:, 0] <= 4)
        & (foreground_colors[:, 1] <= 120)
    ):
        raise AssertionError("deep-blue speed shading was lost")
    if not np.any(np.all(foreground_colors <= np.array([12, 16, 16]), axis=1)):
        raise AssertionError("near-black pixel outline was lost")

    overlap = int(np.count_nonzero(foreground_visible & lower_visible))
    if overlap != 0:
        raise AssertionError(f"foreground overlaps base at {overlap} pixels")
    for bob_offset in (-2, -1, 0, 1, 2):
        shifted_visible = np.zeros_like(foreground_visible)
        if bob_offset < 0:
            shifted_visible[:bob_offset] = foreground_visible[-bob_offset:]
        elif bob_offset > 0:
            shifted_visible[bob_offset:] = foreground_visible[:-bob_offset]
        else:
            shifted_visible = foreground_visible
        animated_overlap = int(np.count_nonzero(shifted_visible & lower_visible))
        if animated_overlap != 0:
            raise AssertionError(
                "foreground overlaps base during bob at offset "
                f"{bob_offset}: {animated_overlap} pixels"
            )
    reconstructed = lower.copy()
    reconstructed[foreground_visible] = foreground[foreground_visible]
    if not np.array_equal(reconstructed, master):
        raise AssertionError(
            "formal Life Tower lower_body + speed_foreground does not "
            "reconstruct attack_speed_tower.png"
        )
    if int((master[:, :, 3] > 0).sum()) != EXPECTED_MASTER_PIXELS:
        raise AssertionError("master pixel count changed")
    master_colors = np.unique(
        master[:, :, :3][master[:, :, 3] > 0],
        axis=0,
    )
    if len(master_colors) != EXPECTED_MASTER_COLORS:
        raise AssertionError(
            f"master palette has {len(master_colors)} colors"
        )

    expected_preview = np.asarray(
        Image.fromarray(master, mode="RGBA").resize(
            PREVIEW_SIZE,
            Image.Resampling.NEAREST,
        ),
        dtype=np.uint8,
    )
    if not np.array_equal(preview, expected_preview):
        raise AssertionError("runtime preview is not an exact 8x nearest copy")

    durations: list[int] = []
    with Image.open(gif_path) as animation:
        if animation.size != PREVIEW_SIZE:
            raise AssertionError(f"preview GIF size is {animation.size}")
        if animation.n_frames != GIF_FRAMES:
            raise AssertionError(
                f"preview GIF has {animation.n_frames} frames"
            )
        if int(animation.info.get("loop", -1)) != 0:
            raise AssertionError("preview GIF must loop forever")
        for frame_index in range(animation.n_frames):
            animation.seek(frame_index)
            durations.append(int(animation.info.get("duration", 0)))
    if durations != [GIF_FRAME_DURATION_MS] * GIF_FRAMES:
        raise AssertionError(f"preview GIF durations changed: {durations}")

    built_foreground, built_master, metadata = build_assets(
        DEFAULT_SOURCE_PATH,
        DEFAULT_LOWER_PATH,
    )
    if not np.array_equal(built_foreground, foreground):
        raise AssertionError("formal foreground does not match deterministic build")
    if not np.array_equal(built_master, master):
        raise AssertionError("formal master does not match deterministic build")
    if tuple(metadata["visible_size"]) != SOURCE_LOGICAL_SIZE:
        raise AssertionError("builder did not enforce the 17x14 visible bbox")

    magenta_like = (
        (master[:, :, 3] > 0)
        & (master[:, :, 0] > 200)
        & (master[:, :, 2] > 180)
        & (master[:, :, 1] < 80)
    )
    if np.any(magenta_like):
        raise AssertionError("visible chroma-key residue remains in formal sprite")

    print("ATTACK_SPEED_TOWER_ASSET_SMOKE_OK")
    print(f"foreground_bbox={foreground_bbox}")
    print(f"foreground_size={visible_width}x{visible_height}")
    print(f"foreground_pixels={int(foreground_visible.sum())}")
    print(f"foreground_colors={len(foreground_colors)}")
    print(f"static_overlap={overlap}")
    print(f"lower_sha256={EXPECTED_LOWER_SHA256}")
    print(f"gif_frames={GIF_FRAMES}")
    print(f"gif_duration_ms={sum(durations)}")


if __name__ == "__main__":
    main()
