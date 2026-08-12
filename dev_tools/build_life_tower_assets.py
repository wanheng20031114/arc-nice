#!/usr/bin/env python3
"""Reconstruct clean native Life Tower layers from an enlarged AI source.

The source contains two independently scaled sprites.  Each subject is first
aligned to its own detected logical grid (heart 16x14, plant base 45x29), then
placed in a shared 64x64 runtime canvas.  A logical cell gets a real source
color chosen from its dominant Lab-color cluster.  Logical colors are finally
reduced with equal-weight Lab palette clustering, so neither subject nor large
source areas can dominate the palette.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from sklearn.cluster import KMeans

from build_life_tower_bob_preview import build_life_tower_bob_preview


LOGICAL_SIZE = 64
PREVIEW_SCALE = 8
DEFAULT_PALETTE_SIZE = 56
DEFAULT_HEART_Y = 23
DEFAULT_BASE_Y = 28
HEART_PALETTE_SIZE = 16
BASE_PALETTE_SIZE = 40


@dataclass(frozen=True)
class SubjectSpec:
    name: str
    logical_width: int
    logical_height: int
    destination_x: int
    destination_y: int


HEART_SPEC = SubjectSpec("heart", 16, 14, 24, DEFAULT_HEART_Y)
BASE_SPEC = SubjectSpec("base", 45, 29, 9, DEFAULT_BASE_Y)

SIDE_FLOWER_ORIGINS = ((14, 36), (44, 36))
SIDE_FLOWER_CLEANUP_Y = 35
SIDE_FLOWER_TEMPLATE = (
    "..W..",
    "WWWWW",
    "WWYWW",
    ".WWW.",
    ".W.W.",
)
SIDE_FLOWER_WHITE = np.array([253, 253, 253, 255], dtype=np.uint8)
SIDE_FLOWER_CENTER = np.array([251, 200, 2, 255], dtype=np.uint8)
SIDE_FLOWER_OUTLINE = np.array([8, 20, 1, 255], dtype=np.uint8)


def _active_row_runs(mask: np.ndarray) -> list[tuple[int, int]]:
    active_rows = np.any(mask, axis=1)
    runs: list[tuple[int, int]] = []
    start: int | None = None
    for row, active in enumerate(active_rows):
        if active and start is None:
            start = row
        elif not active and start is not None:
            runs.append((start, row))
            start = None
    if start is not None:
        runs.append((start, len(active_rows)))
    return runs


def _tight_bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        raise ValueError("subject contains no visible pixels")
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
    """Choose a real RGB from the largest of two perceptual color clusters."""
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
    candidates = np.flatnonzero(cluster_weights == cluster_weights.max())
    if len(candidates) > 1:
        global_median = np.median(_rgb_to_lab(samples), axis=0)
        center_distances = np.sum(
            (model.cluster_centers_[candidates] - global_median) ** 2,
            axis=1,
        )
        selected_cluster = int(candidates[int(np.argmin(center_distances))])
    else:
        selected_cluster = int(candidates[0])

    member_mask = model.labels_ == selected_cluster
    member_rgb = unique_rgb[member_mask]
    member_lab = unique_lab[member_mask]
    member_counts = counts[member_mask]
    # Repeat only this small set so the median respects physical pixel counts.
    weighted_lab = np.repeat(member_lab, member_counts, axis=0)
    cluster_median = np.median(weighted_lab, axis=0)
    distances = np.sum((member_lab - cluster_median) ** 2, axis=1)
    return member_rgb[int(np.argmin(distances))]


def _extract_subject(
    rgba: np.ndarray,
    subject_mask: np.ndarray,
    spec: SubjectSpec,
) -> tuple[np.ndarray, np.ndarray]:
    left, top, right, bottom = _tight_bbox(subject_mask)
    x_boundaries = _rational_boundaries(left, right, spec.logical_width)
    y_boundaries = _rational_boundaries(top, bottom, spec.logical_height)
    local_mask = np.zeros(
        (spec.logical_height, spec.logical_width),
        dtype=bool,
    )
    local_colors = np.zeros(
        (spec.logical_height, spec.logical_width, 3),
        dtype=np.uint8,
    )

    for logical_y in range(spec.logical_height):
        cell_top = y_boundaries[logical_y]
        cell_bottom = y_boundaries[logical_y + 1]
        for logical_x in range(spec.logical_width):
            cell_left = x_boundaries[logical_x]
            cell_right = x_boundaries[logical_x + 1]
            cell_mask = subject_mask[
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
            local_colors[logical_y, logical_x] = _dominant_cluster_medoid(samples)

    if not np.array_equal(local_mask, np.fliplr(local_mask)):
        raise ValueError(f"{spec.name} logical silhouette is not symmetric")
    return local_mask, local_colors


def _palette_medoid_quantize(
    representative_colors: np.ndarray,
    palette_size: int,
) -> np.ndarray:
    """Equal-weight logical palette whose entries are all observed RGB colors."""
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


def _repair_side_flowers(lower: np.ndarray) -> None:
    """Replace the two phase-damaged 5x6 flowers with one canonical 5x5 form.

    The side flowers use the same physical pixel size as the base but start on
    a half-cell phase.  Reconstructing the entire base grid therefore split
    each flower over six rows.  Only old white/yellow flower pixels inside the
    two tiny cleanup regions are cleared; surrounding leaves remain byte-for-
    byte unchanged.
    """
    for origin_x, origin_y in SIDE_FLOWER_ORIGINS:
        cleanup = lower[
            SIDE_FLOWER_CLEANUP_Y:origin_y + len(SIDE_FLOWER_TEMPLATE),
            origin_x:origin_x + len(SIDE_FLOWER_TEMPLATE[0]),
        ]
        rgb = cleanup[:, :, :3]
        old_white = np.all(rgb >= np.array([220, 220, 180]), axis=2)
        old_center = (
            (rgb[:, :, 0] >= 200)
            & (rgb[:, :, 1] >= 80)
            & (rgb[:, :, 2] <= 32)
        )
        cleanup[old_white | old_center] = SIDE_FLOWER_OUTLINE

        for offset_y, row in enumerate(SIDE_FLOWER_TEMPLATE):
            for offset_x, marker in enumerate(row):
                if marker == "W":
                    lower[origin_y + offset_y, origin_x + offset_x] = (
                        SIDE_FLOWER_WHITE
                    )
                elif marker == "Y":
                    lower[origin_y + offset_y, origin_x + offset_x] = (
                        SIDE_FLOWER_CENTER
                    )


def rebuild_layers(
    source: Image.Image,
    palette_size: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, dict[str, object]]:
    rgba = np.asarray(source.convert("RGBA"), dtype=np.uint8)
    visible = rgba[:, :, 3] > 0
    if visible.all():
        raise ValueError("source background is opaque; remove chroma key first")
    runs = _active_row_runs(visible)
    if len(runs) != 2:
        raise ValueError(f"expected two separated subjects, found rows: {runs}")
    split_row = (runs[0][1] + runs[1][0]) // 2
    heart_source = visible.copy()
    heart_source[split_row:] = False
    base_source = visible.copy()
    base_source[:split_row] = False

    heart_mask, heart_colors = _extract_subject(rgba, heart_source, HEART_SPEC)
    base_mask, base_colors = _extract_subject(rgba, base_source, BASE_SPEC)
    masks_and_colors = (
        (HEART_SPEC, heart_mask, heart_colors),
        (BASE_SPEC, base_mask, base_colors),
    )

    heart_budget = min(HEART_PALETTE_SIZE, palette_size - 2)
    base_budget = min(BASE_PALETTE_SIZE, palette_size - heart_budget)
    if base_budget < 2:
        base_budget = 2
        heart_budget = palette_size - base_budget
    reduced_by_subject = {
        "heart": _palette_medoid_quantize(
            heart_colors[heart_mask],
            heart_budget,
        ),
        "base": _palette_medoid_quantize(
            base_colors[base_mask],
            base_budget,
        ),
    }

    heart = np.zeros((LOGICAL_SIZE, LOGICAL_SIZE, 4), dtype=np.uint8)
    lower = np.zeros_like(heart)
    for spec, local_mask, _ in masks_and_colors:
        count = int(local_mask.sum())
        target = heart if spec.name == "heart" else lower
        local_rgba = np.zeros(
            (spec.logical_height, spec.logical_width, 4),
            dtype=np.uint8,
        )
        local_rgba[local_mask, :3] = reduced_by_subject[spec.name]
        local_rgba[local_mask, 3] = 255
        y0 = spec.destination_y
        x0 = spec.destination_x
        target[
            y0:y0 + spec.logical_height,
            x0:x0 + spec.logical_width,
        ] = local_rgba

    _repair_side_flowers(lower)

    overlap = (heart[:, :, 3] > 0) & (lower[:, :, 3] > 0)
    if overlap.any():
        raise ValueError(f"static layers overlap at {int(overlap.sum())} pixels")
    master = lower.copy()
    heart_visible = heart[:, :, 3] > 0
    master[heart_visible] = heart[heart_visible]
    metadata: dict[str, object] = {
        "source_split": split_row,
        "heart_source_bbox": _tight_bbox(heart_source),
        "base_source_bbox": _tight_bbox(base_source),
        "heart_pixels": int(heart_mask.sum()),
        "base_pixels": int(base_mask.sum()),
        "heart_row_widths": heart_mask.sum(axis=1).tolist(),
        "heart_palette_budget": heart_budget,
        "base_palette_budget": base_budget,
    }
    return lower, heart, master, metadata


def _save_rgba(array: np.ndarray, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(array, mode="RGBA").save(path, optimize=True)


def save_previews(
    lower: np.ndarray,
    heart: np.ndarray,
    master: np.ndarray,
    preview_path: Path,
) -> None:
    preview_path.parent.mkdir(parents=True, exist_ok=True)
    preview = Image.fromarray(master, mode="RGBA").resize(
        (LOGICAL_SIZE * PREVIEW_SCALE, LOGICAL_SIZE * PREVIEW_SCALE),
        Image.Resampling.NEAREST,
    )
    preview.save(preview_path, optimize=True)


def _bbox_text(array: np.ndarray) -> str:
    return str(Image.fromarray(array[:, :, 3], mode="L").getbbox())


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reconstruct native 64x64 Life Tower sprite layers",
    )
    parser.add_argument("source_path", help="Transparent RGBA source image")
    parser.add_argument("output_root", help="Final life_tower texture directory")
    parser.add_argument("--preview-root", default=None)
    parser.add_argument(
        "--palette-size",
        type=int,
        default=DEFAULT_PALETTE_SIZE,
    )
    args = parser.parse_args()

    output_root = Path(args.output_root)
    preview_root = Path(args.preview_root) if args.preview_root else output_root
    palette_size = max(2, min(args.palette_size, 256))
    with Image.open(args.source_path) as source:
        lower, heart, master, metadata = rebuild_layers(source, palette_size)

    lower_path = output_root / "layers" / "lower_body.png"
    heart_path = output_root / "layers" / "heart_foreground.png"
    _save_rgba(master, output_root / "life_tower.png")
    _save_rgba(lower, lower_path)
    _save_rgba(heart, heart_path)
    save_previews(
        lower,
        heart,
        master,
        preview_root / "life_tower_runtime_preview_8x.png",
    )
    build_life_tower_bob_preview(
        lower_path,
        heart_path,
        preview_root / "life_tower_bob_preview.gif",
    )

    visible_colors = np.unique(master[:, :, :3][master[:, :, 3] > 0], axis=0)
    print(f"source:              {args.source_path}")
    print(f"palette size:        {len(visible_colors)} / {palette_size}")
    print(
        "palette budgets:     "
        f"heart {metadata['heart_palette_budget']}, "
        f"base {metadata['base_palette_budget']}"
    )
    print(f"source split row:    {metadata['source_split']}")
    print(f"heart source bbox:   {metadata['heart_source_bbox']}")
    print(f"base source bbox:    {metadata['base_source_bbox']}")
    print(f"heart pixels:        {metadata['heart_pixels']}")
    print(f"heart row widths:    {metadata['heart_row_widths']}")
    print(f"base pixels:         {metadata['base_pixels']}")
    print(f"base bbox:           {_bbox_text(lower)}")
    print(f"heart bbox:          {_bbox_text(heart)}")
    print(f"master bbox:         {_bbox_text(master)}")
    print(f"output root:         {output_root}")


if __name__ == "__main__":
    main()
