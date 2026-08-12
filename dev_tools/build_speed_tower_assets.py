#!/usr/bin/env python3
"""Build native Speed Tower layers from the generated boot source.

The Life Tower lower body is reused byte-for-byte.  The generated boot is
sampled on its detected 14x13 logical grid, reduced to a small fixed palette,
and placed on the shared 64x64 runtime canvas without interpolation.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import GifImagePlugin, Image
from sklearn.cluster import KMeans

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = (
    PROJECT_ROOT
    / "dev_assets/source_images/plant_defense/speed_tower"
    / "generated_boot_alpha.png"
)
OUTPUT_ROOT = PROJECT_ROOT / "resources/texture/plant_defense/speed_tower"
LIFE_LOWER_PATH = (
    PROJECT_ROOT
    / "resources/texture/plant_defense/life_tower/layers/lower_body.png"
)
PREVIEW_ROOT = (
    PROJECT_ROOT
    / "dev_assets/source_images/plant_defense/speed_tower/final"
)

CANVAS_SIZE = 64
BOOT_WIDTH = 14
BOOT_HEIGHT = 13
BOOT_X = 25
BOOT_Y = 23
BOOT_PALETTE_SIZE = 8
PREVIEW_SCALE = 8
PREVIEW_FRAMES = 40
PREVIEW_DURATION_MS = 50
PREVIEW_AMPLITUDE_PIXELS = 2


def _rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    srgb = rgb.astype(np.float64) / 255.0
    linear = np.where(
        srgb <= 0.04045,
        srgb / 12.92,
        ((srgb + 0.055) / 1.055) ** 2.4,
    )
    matrix = np.array(
        [
            [0.4124564, 0.3575761, 0.1804375],
            [0.2126729, 0.7151522, 0.0721750],
            [0.0193339, 0.1191920, 0.9503041],
        ],
        dtype=np.float64,
    )
    xyz = linear @ matrix.T
    scaled = xyz / np.array([0.95047, 1.0, 1.08883])
    delta = 6.0 / 29.0
    transformed = np.where(
        scaled > delta**3,
        np.cbrt(scaled),
        scaled / (3.0 * delta**2) + 4.0 / 29.0,
    )
    lab = np.empty_like(transformed)
    lab[:, 0] = 116.0 * transformed[:, 1] - 16.0
    lab[:, 1] = 500.0 * (transformed[:, 0] - transformed[:, 1])
    lab[:, 2] = 200.0 * (transformed[:, 1] - transformed[:, 2])
    return lab


def _boundaries(start: int, end: int, count: int) -> list[int]:
    extent = end - start
    return [
        start + math.floor(index * extent / count + 0.5)
        for index in range(count + 1)
    ]


def _dominant_medoid(samples: np.ndarray) -> np.ndarray:
    unique_rgb, counts = np.unique(samples, axis=0, return_counts=True)
    if len(unique_rgb) == 1:
        return unique_rgb[0]
    lab = _rgb_to_lab(unique_rgb)
    model = KMeans(
        n_clusters=min(2, len(unique_rgb)),
        n_init=10,
        random_state=0,
    ).fit(lab, sample_weight=counts)
    weights = np.bincount(
        model.labels_,
        weights=counts,
        minlength=model.n_clusters,
    )
    selected = int(np.argmax(weights))
    member_indices = np.flatnonzero(model.labels_ == selected)
    member_lab = lab[member_indices]
    center = model.cluster_centers_[selected]
    distances = np.sum((member_lab - center) ** 2, axis=1)
    return unique_rgb[member_indices[int(np.argmin(distances))]]


def _quantize_medoid(colors: np.ndarray, palette_size: int) -> np.ndarray:
    lab = _rgb_to_lab(colors)
    model = KMeans(
        n_clusters=min(palette_size, len(colors)),
        n_init=20,
        random_state=0,
    ).fit(lab)
    palette = np.zeros((model.n_clusters, 3), dtype=np.uint8)
    for cluster in range(model.n_clusters):
        indices = np.flatnonzero(model.labels_ == cluster)
        distances = np.sum(
            (lab[indices] - model.cluster_centers_[cluster]) ** 2,
            axis=1,
        )
        palette[cluster] = colors[indices[int(np.argmin(distances))]]
    return palette[model.labels_]


def _build_bob_preview(
    lower: np.ndarray,
    boot: np.ndarray,
    output_path: Path,
) -> None:
    rgba_frames: list[Image.Image] = []
    lower_image = Image.fromarray(lower, mode="RGBA")
    boot_image = Image.fromarray(boot, mode="RGBA")
    for frame_index in range(PREVIEW_FRAMES):
        offset = -round(
            PREVIEW_AMPLITUDE_PIXELS
            * math.sin(math.tau * frame_index / PREVIEW_FRAMES)
        )
        frame = lower_image.copy()
        frame.alpha_composite(boot_image, dest=(0, offset))
        rgba_frames.append(
            frame.resize(
                (CANVAS_SIZE * PREVIEW_SCALE, CANVAS_SIZE * PREVIEW_SCALE),
                Image.Resampling.NEAREST,
            )
        )
    visible_colors = sorted(
        {
            tuple(int(channel) for channel in color)
            for layer in (lower, boot)
            for color in np.unique(
                layer[:, :, :3][layer[:, :, 3] == 255],
                axis=0,
            )
        }
    )
    if len(visible_colors) > 255:
        raise ValueError("preview exceeds the GIF palette budget")
    palette = [0, 0, 0]
    for color in visible_colors:
        palette.extend(color)
    palette.extend([0] * (768 - len(palette)))
    indexed_frames: list[Image.Image] = []
    for frame in rgba_frames:
        rgba = np.asarray(frame, dtype=np.uint8)
        visible = rgba[:, :, 3] == 255
        indices = np.zeros(rgba.shape[:2], dtype=np.uint8)
        assigned = np.zeros_like(visible)
        for palette_index, color in enumerate(visible_colors, start=1):
            color_mask = visible & np.all(
                rgba[:, :, :3] == np.asarray(color, dtype=np.uint8),
                axis=2,
            )
            indices[color_mask] = palette_index
            assigned |= color_mask
        if not np.array_equal(assigned, visible):
            raise AssertionError("preview contains an unassigned visible color")
        indexed = Image.fromarray(indices, mode="P")
        indexed.putpalette(palette)
        indexed.info["transparency"] = 0
        indexed_frames.append(indexed)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    header, _ = GifImagePlugin.getheader(
        indexed_frames[0],
        info={"background": 0, "loop": 0, "transparency": 0},
    )
    with output_path.open("wb") as output:
        for block in header:
            output.write(block)
        for frame in indexed_frames:
            for block in GifImagePlugin.getdata(
                frame,
                duration=PREVIEW_DURATION_MS,
                disposal=2,
                transparency=0,
            ):
                output.write(block)
        output.write(b";")

    durations: list[int] = []
    with Image.open(output_path) as animation:
        if animation.n_frames != PREVIEW_FRAMES:
            raise AssertionError("preview GIF lost sampled frames")
        for frame_index in range(animation.n_frames):
            animation.seek(frame_index)
            durations.append(int(animation.info.get("duration", 0)))
    if durations != [PREVIEW_DURATION_MS] * PREVIEW_FRAMES:
        raise AssertionError("preview GIF durations changed during encoding")


def build_assets(
    source_path: Path,
    output_root: Path,
    lower_path: Path,
    preview_root: Path,
) -> None:
    source = np.asarray(Image.open(source_path).convert("RGBA"), dtype=np.uint8)
    visible = source[:, :, 3] >= 128
    ys, xs = np.where(visible)
    if len(xs) == 0:
        raise ValueError("boot source has no visible pixels")
    left, top, right, bottom = (
        int(xs.min()),
        int(ys.min()),
        int(xs.max() + 1),
        int(ys.max() + 1),
    )
    x_bounds = _boundaries(left, right, BOOT_WIDTH)
    y_bounds = _boundaries(top, bottom, BOOT_HEIGHT)
    boot_mask = np.zeros((BOOT_HEIGHT, BOOT_WIDTH), dtype=bool)
    boot_colors = np.zeros((BOOT_HEIGHT, BOOT_WIDTH, 3), dtype=np.uint8)
    for logical_y in range(BOOT_HEIGHT):
        for logical_x in range(BOOT_WIDTH):
            cell_visible = visible[
                y_bounds[logical_y]:y_bounds[logical_y + 1],
                x_bounds[logical_x]:x_bounds[logical_x + 1],
            ]
            if int(cell_visible.sum()) * 2 < cell_visible.size:
                continue
            cell_rgb = source[
                y_bounds[logical_y]:y_bounds[logical_y + 1],
                x_bounds[logical_x]:x_bounds[logical_x + 1],
                :3,
            ][cell_visible]
            boot_mask[logical_y, logical_x] = True
            boot_colors[logical_y, logical_x] = _dominant_medoid(cell_rgb)

    reduced = _quantize_medoid(
        boot_colors[boot_mask],
        BOOT_PALETTE_SIZE,
    )
    boot = np.zeros((CANVAS_SIZE, CANVAS_SIZE, 4), dtype=np.uint8)
    local = np.zeros((BOOT_HEIGHT, BOOT_WIDTH, 4), dtype=np.uint8)
    local[boot_mask, :3] = reduced
    local[boot_mask, 3] = 255
    boot[BOOT_Y:BOOT_Y + BOOT_HEIGHT, BOOT_X:BOOT_X + BOOT_WIDTH] = local

    lower = np.asarray(Image.open(lower_path).convert("RGBA"), dtype=np.uint8)
    if lower.shape != (CANVAS_SIZE, CANVAS_SIZE, 4):
        raise ValueError("shared lower body must be 64x64 RGBA")
    if np.any((lower[:, :, 3] > 0) & (boot[:, :, 3] > 0)):
        raise ValueError("static boot overlaps the shared lower body")
    master = lower.copy()
    boot_visible = boot[:, :, 3] > 0
    master[boot_visible] = boot[boot_visible]

    layer_root = output_root / "layers"
    layer_root.mkdir(parents=True, exist_ok=True)
    preview_root.mkdir(parents=True, exist_ok=True)
    Image.fromarray(boot, mode="RGBA").save(
        layer_root / "boot_foreground.png",
        optimize=True,
    )
    Image.fromarray(master, mode="RGBA").save(
        output_root / "speed_tower.png",
        optimize=True,
    )
    Image.fromarray(master, mode="RGBA").resize(
        (512, 512),
        Image.Resampling.NEAREST,
    ).save(preview_root / "speed_tower_runtime_preview_8x.png", optimize=True)
    _build_bob_preview(
        lower,
        boot,
        preview_root / "speed_tower_bob_preview.gif",
    )
    print(f"source_bbox={(left, top, right, bottom)}")
    print(f"boot_bbox={(BOOT_X, BOOT_Y, BOOT_X + BOOT_WIDTH, BOOT_Y + BOOT_HEIGHT)}")
    print(f"boot_pixels={int(boot_mask.sum())}")
    print(f"boot_colors={len(np.unique(reduced, axis=0))}")
    print("SPEED_TOWER_ASSET_BUILD_OK")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=SOURCE_PATH)
    parser.add_argument("--output-root", type=Path, default=OUTPUT_ROOT)
    parser.add_argument("--lower", type=Path, default=LIFE_LOWER_PATH)
    parser.add_argument("--preview-root", type=Path, default=PREVIEW_ROOT)
    args = parser.parse_args()
    build_assets(
        args.source.resolve(),
        args.output_root.resolve(),
        args.lower.resolve(),
        args.preview_root.resolve(),
    )


if __name__ == "__main__":
    main()
