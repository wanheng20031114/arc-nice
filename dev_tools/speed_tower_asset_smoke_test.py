#!/usr/bin/env python3
"""Validate Speed Tower native sprite layers."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image


SIZE = (64, 64)
BOOT_BBOX = (25, 23, 39, 36)
BOOT_PIXELS = 132
MAX_BOOT_COLORS = 8
LOWER_PATH = Path("resources/texture/plant_defense/life_tower/layers/lower_body.png")
IMPORT_CONTRACT = (
    'compress/mode=0',
    'mipmaps/generate=false',
    'process/size_limit=0',
)


def _load(path: Path) -> np.ndarray:
    image = Image.open(path).convert("RGBA")
    if image.size != SIZE:
        raise AssertionError(f"{path} must be 64x64")
    array = np.asarray(image, dtype=np.uint8)
    if not set(np.unique(array[:, :, 3]).tolist()).issubset({0, 255}):
        raise AssertionError(f"{path} must use binary alpha")
    if np.any(array[:, :, :3][array[:, :, 3] == 0] != 0):
        raise AssertionError(f"{path} has RGB under transparent pixels")
    return array


def _assert_import_contract(path: Path) -> None:
    import_path = Path(f"{path}.import")
    if not import_path.is_file():
        raise AssertionError(f"{path} is missing its committed Godot import metadata")
    metadata = import_path.read_text(encoding="utf-8")
    for authored_setting in IMPORT_CONTRACT:
        if authored_setting not in metadata:
            raise AssertionError(
                f"{import_path} is missing {authored_setting}"
            )


def main() -> None:
    root = Path(
        sys.argv[1]
        if len(sys.argv) > 1
        else "resources/texture/plant_defense/speed_tower"
    )
    master = _load(root / "speed_tower.png")
    boot = _load(root / "layers/boot_foreground.png")
    lower = _load(LOWER_PATH)
    _assert_import_contract(root / "speed_tower.png")
    _assert_import_contract(root / "layers/boot_foreground.png")
    boot_visible = boot[:, :, 3] > 0
    lower_visible = lower[:, :, 3] > 0
    if np.any(boot_visible & lower_visible):
        raise AssertionError("boot and lower body overlap in static layers")
    rebuilt = lower.copy()
    rebuilt[boot_visible] = boot[boot_visible]
    if not np.array_equal(rebuilt, master):
        raise AssertionError("shared lower body + boot does not reconstruct master")
    if not np.array_equal(
        master[~boot_visible],
        lower[~boot_visible],
    ):
        raise AssertionError("master modified the shared lower body")
    bbox = Image.fromarray(boot[:, :, 3], mode="L").getbbox()
    if bbox != BOOT_BBOX:
        raise AssertionError(f"boot bbox {bbox} != {BOOT_BBOX}")
    pixels = int(boot_visible.sum())
    if pixels != BOOT_PIXELS:
        raise AssertionError(f"boot pixels {pixels} != {BOOT_PIXELS}")
    colors = np.unique(boot[:, :, :3][boot_visible], axis=0)
    if len(colors) > MAX_BOOT_COLORS:
        raise AssertionError(f"boot has {len(colors)} colors")
    if not np.any((colors[:, 0] > 220) & (colors[:, 1] > 150) & (colors[:, 2] < 80)):
        raise AssertionError("boot is missing a clear golden-yellow main color")
    if np.any((colors[:, 0] > 180) & (colors[:, 2] > 140) & (colors[:, 1] < 100)):
        raise AssertionError("boot retains magenta chroma-key residue")
    print("SPEED_TOWER_ASSET_SMOKE_OK")
    print(f"boot_bbox={bbox}")
    print(f"boot_pixels={pixels}")
    print(f"boot_colors={len(colors)}")

    preview_path = Path(
        "dev_assets/source_images/plant_defense/speed_tower/final/"
        "speed_tower_bob_preview.gif"
    )
    with Image.open(preview_path) as preview:
        durations = []
        if preview.size != (512, 512) or preview.n_frames != 40:
            raise AssertionError("bob preview must be 512x512 with 40 frames")
        if int(preview.info.get("loop", -1)) != 0:
            raise AssertionError("bob preview must loop forever")
        for frame_index in range(preview.n_frames):
            preview.seek(frame_index)
            durations.append(int(preview.info.get("duration", 0)))
        if durations != [50] * 40:
            raise AssertionError("bob preview must keep 40 exact 50ms frames")
        if sum(durations) != 2000:
            raise AssertionError("bob preview must last exactly two seconds")


if __name__ == "__main__":
    main()
