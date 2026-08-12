#!/usr/bin/env python3
"""Build the native 64x64 Attack Speed Tower visual assets.

The tower base is always read from the formal Life Tower ``lower_body.png``;
this builder never writes a second base layer.  The compact V2 ImageGen emblem
is partitioned directly into the requested 17x14 output lattice, sampled once
per logical cell, palette-reduced deterministically, and placed on a native
64x64 transparent canvas.  The combined master is only for registry thumbnails
and review; runtime scenes should reference the Life Tower base layer directly.
"""

from __future__ import annotations

import argparse
import hashlib
import math
from pathlib import Path

import numpy as np
from PIL import Image
from sklearn.cluster import KMeans

from build_life_tower_bob_preview import build_life_tower_bob_preview


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE_PATH = (
    PROJECT_ROOT
    / "dev_assets/source_images/plant_defense/attack_speed_tower"
    / "attack_speed_emblem_imagegen_v2_17x17_transparent.png"
)
DEFAULT_LOWER_PATH = (
    PROJECT_ROOT
    / "resources/texture/plant_defense/life_tower/layers/lower_body.png"
)
DEFAULT_OUTPUT_ROOT = (
    PROJECT_ROOT / "resources/texture/plant_defense/attack_speed_tower"
)
DEFAULT_PREVIEW_ROOT = (
    PROJECT_ROOT
    / "dev_assets/source_images/plant_defense/attack_speed_tower/final"
)

LOGICAL_SIZE = 64
PREVIEW_SCALE = 8
SOURCE_SIZE = (1254, 1254)
SOURCE_ALPHA_THRESHOLD = 128
SOURCE_BBOX = (423, 477, 826, 794)
SOURCE_LOGICAL_SIZE = (17, 14)
DESTINATION = (24, 20)
MAX_VISIBLE_EXTENT = 17
PALETTE_SIZE = 16
EXPECTED_SOURCE_SHA256 = (
    "62582fc5c5601f2a9b4f82b835eebb1f1db000a9834c13b130e83a803885a4c8"
)
EXPECTED_LOWER_SHA256 = (
    "2815c1ca6400bc4487021aa2be69704bde5ced69b90241a4210a79f89658e77d"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source_file:
        while chunk := source_file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _tight_bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        raise ValueError("source emblem contains no visible pixels")
    return int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)


def _rational_boundaries(start: int, end: int, cells: int) -> list[int]:
    extent = end - start
    return [
        start + math.floor(index * extent / cells + 0.5)
        for index in range(cells + 1)
    ]


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


def _dominant_cluster_medoid(samples: np.ndarray) -> np.ndarray:
    """Choose a real source RGB from the dominant perceptual color cluster."""
    unique_rgb, counts = np.unique(samples, axis=0, return_counts=True)
    if len(unique_rgb) == 1:
        return unique_rgb[0]
    unique_lab = _rgb_to_lab(unique_rgb)
    cluster_count = min(2, len(unique_rgb))
    model = KMeans(
        n_clusters=cluster_count,
        n_init=10,
        random_state=0,
    ).fit(unique_lab, sample_weight=counts)
    cluster_weights = np.bincount(
        model.labels_,
        weights=counts,
        minlength=cluster_count,
    )
    selected_cluster = int(np.flatnonzero(
        cluster_weights == cluster_weights.max()
    )[0])
    member_mask = model.labels_ == selected_cluster
    member_rgb = unique_rgb[member_mask]
    member_lab = unique_lab[member_mask]
    member_counts = counts[member_mask]
    weighted_lab = np.repeat(member_lab, member_counts, axis=0)
    cluster_median = np.median(weighted_lab, axis=0)
    distances = np.sum((member_lab - cluster_median) ** 2, axis=1)
    return member_rgb[int(np.argmin(distances))]


def _palette_medoid_quantize(
    representative_colors: np.ndarray,
    palette_size: int,
) -> np.ndarray:
    """Reduce colors while keeping every palette entry source-authored."""
    lab = _rgb_to_lab(representative_colors)
    cluster_count = min(palette_size, len(representative_colors))
    model = KMeans(
        n_clusters=cluster_count,
        n_init=20,
        random_state=0,
    ).fit(lab)
    palette = np.zeros((cluster_count, 3), dtype=np.uint8)
    for cluster in range(cluster_count):
        member_indices = np.flatnonzero(model.labels_ == cluster)
        member_lab = lab[member_indices]
        distances = np.sum(
            (member_lab - model.cluster_centers_[cluster]) ** 2,
            axis=1,
        )
        palette[cluster] = representative_colors[
            member_indices[int(np.argmin(distances))]
        ]
    return palette[model.labels_]


def rebuild_speed_foreground(
    source: Image.Image,
) -> tuple[np.ndarray, dict[str, object]]:
    rgba = np.asarray(source.convert("RGBA"), dtype=np.uint8)
    if source.size != SOURCE_SIZE:
        raise ValueError(
            f"ImageGen source must be {SOURCE_SIZE}, got {source.size}"
        )
    source_mask = rgba[:, :, 3] >= SOURCE_ALPHA_THRESHOLD
    bbox = _tight_bbox(source_mask)
    if bbox != SOURCE_BBOX:
        raise ValueError(f"source bbox changed: {bbox} != {SOURCE_BBOX}")

    logical_width, logical_height = SOURCE_LOGICAL_SIZE
    left, top, right, bottom = bbox
    x_boundaries = _rational_boundaries(left, right, logical_width)
    y_boundaries = _rational_boundaries(top, bottom, logical_height)
    local_mask = np.zeros((logical_height, logical_width), dtype=bool)
    local_colors = np.zeros(
        (logical_height, logical_width, 3),
        dtype=np.uint8,
    )

    for logical_y in range(logical_height):
        cell_top = y_boundaries[logical_y]
        cell_bottom = y_boundaries[logical_y + 1]
        for logical_x in range(logical_width):
            cell_left = x_boundaries[logical_x]
            cell_right = x_boundaries[logical_x + 1]
            cell_mask = source_mask[
                cell_top:cell_bottom,
                cell_left:cell_right,
            ]
            if int(cell_mask.sum()) * 2 < cell_mask.size:
                continue
            samples = rgba[
                cell_top:cell_bottom,
                cell_left:cell_right,
                :3,
            ][cell_mask]
            local_mask[logical_y, logical_x] = True
            local_colors[logical_y, logical_x] = _dominant_cluster_medoid(
                samples
            )

    representative_colors = local_colors[local_mask]
    reduced_colors = _palette_medoid_quantize(
        representative_colors,
        PALETTE_SIZE,
    )
    local_rgba = np.zeros(
        (logical_height, logical_width, 4),
        dtype=np.uint8,
    )
    local_rgba[local_mask, :3] = reduced_colors
    local_rgba[local_mask, 3] = 255

    local_bbox = _tight_bbox(local_mask)
    visible_width = local_bbox[2] - local_bbox[0]
    visible_height = local_bbox[3] - local_bbox[1]
    if visible_width > MAX_VISIBLE_EXTENT or visible_height > MAX_VISIBLE_EXTENT:
        raise ValueError(
            "formal speed emblem exceeds the 17x17 visible-footprint gate: "
            f"{visible_width}x{visible_height}"
        )

    foreground = np.zeros(
        (LOGICAL_SIZE, LOGICAL_SIZE, 4),
        dtype=np.uint8,
    )
    destination_x, destination_y = DESTINATION
    foreground[
        destination_y:destination_y + logical_height,
        destination_x:destination_x + logical_width,
    ] = local_rgba
    metadata: dict[str, object] = {
        "source_bbox": bbox,
        "source_logical_size": SOURCE_LOGICAL_SIZE,
        "destination": DESTINATION,
        "local_visible_bbox": local_bbox,
        "visible_size": (visible_width, visible_height),
        "visible_pixels": int(local_mask.sum()),
        "row_widths": local_mask.sum(axis=1).tolist(),
        "palette_size": len(np.unique(reduced_colors, axis=0)),
    }
    return foreground, metadata


def _load_formal_lower(path: Path) -> np.ndarray:
    if _sha256(path) != EXPECTED_LOWER_SHA256:
        raise ValueError(
            "formal Life Tower lower_body.png changed; review base lineage "
            "before rebuilding the Attack Speed Tower"
        )
    with Image.open(path) as source:
        lower = np.asarray(source.convert("RGBA"), dtype=np.uint8)
    if lower.shape != (LOGICAL_SIZE, LOGICAL_SIZE, 4):
        raise ValueError(f"formal lower body must be 64x64, got {lower.shape}")
    return lower


def build_assets(
    source_path: Path,
    lower_path: Path,
) -> tuple[np.ndarray, np.ndarray, dict[str, object]]:
    if _sha256(source_path) != EXPECTED_SOURCE_SHA256:
        raise ValueError(
            "transparent V2 ImageGen source changed; update its lineage and "
            "review the logical sampling contract before rebuilding"
        )
    with Image.open(source_path) as source:
        foreground, metadata = rebuild_speed_foreground(source)
    lower = _load_formal_lower(lower_path)
    lower_visible = lower[:, :, 3] > 0
    foreground_visible = foreground[:, :, 3] > 0
    overlap = lower_visible & foreground_visible
    if overlap.any():
        raise ValueError(
            f"speed emblem overlaps the formal base at {int(overlap.sum())} pixels"
        )
    master = lower.copy()
    master[foreground_visible] = foreground[foreground_visible]
    metadata["static_overlap"] = 0
    metadata["lower_sha256"] = EXPECTED_LOWER_SHA256
    return foreground, master, metadata


def _save_rgba(array: np.ndarray, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(array, mode="RGBA").save(path, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build native Attack Speed Tower sprite assets",
    )
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE_PATH)
    parser.add_argument("--lower", type=Path, default=DEFAULT_LOWER_PATH)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument(
        "--preview-root",
        type=Path,
        default=DEFAULT_PREVIEW_ROOT,
    )
    args = parser.parse_args()

    source_path = args.source.resolve()
    lower_path = args.lower.resolve()
    output_root = args.output_root.resolve()
    preview_root = args.preview_root.resolve()
    foreground, master, metadata = build_assets(source_path, lower_path)

    foreground_path = output_root / "layers/speed_foreground.png"
    master_path = output_root / "attack_speed_tower.png"
    _save_rgba(foreground, foreground_path)
    _save_rgba(master, master_path)
    preview_root.mkdir(parents=True, exist_ok=True)
    Image.fromarray(master, mode="RGBA").resize(
        (
            LOGICAL_SIZE * PREVIEW_SCALE,
            LOGICAL_SIZE * PREVIEW_SCALE,
        ),
        Image.Resampling.NEAREST,
    ).save(
        preview_root / "attack_speed_tower_runtime_preview_8x.png",
        optimize=True,
    )
    gif_result = build_life_tower_bob_preview(
        lower_path,
        foreground_path,
        preview_root / "attack_speed_tower_bob_preview.gif",
    )

    print(f"source:                 {source_path}")
    print(f"formal lower:           {lower_path}")
    print(f"lower SHA-256:          {metadata['lower_sha256']}")
    print(f"source bbox:            {metadata['source_bbox']}")
    print(f"source logical size:    {metadata['source_logical_size']}")
    print(f"destination:            {metadata['destination']}")
    print(f"visible bbox:           {metadata['local_visible_bbox']}")
    print(f"visible size:           {metadata['visible_size']}")
    print(f"foreground pixels:      {metadata['visible_pixels']}")
    print(f"foreground row widths:  {metadata['row_widths']}")
    print(f"foreground colors:      {metadata['palette_size']}")
    print(f"static overlap:         {metadata['static_overlap']}")
    print(f"preview frames:         {gif_result['frames']}")
    print(f"output root:            {output_root}")
    print("ATTACK_SPEED_TOWER_ASSET_BUILD_OK")


if __name__ == "__main__":
    main()
