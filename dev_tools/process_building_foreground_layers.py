#!/usr/bin/env python3
"""Build complementary foreground layers for reviewed 64x64 buildings.

The source sprites are already native-resolution pixel art.  This tool never
resizes, filters, quantizes, or otherwise rewrites their visible pixels.  It
only routes each opaque source pixel to either the lower body or the reviewed
upper foreground mask.  The two outputs therefore reconstruct the master
sprite byte-for-byte at the RGBA pixel level.

Use ``--check-only`` in validation/CI to regenerate both layers in memory and
compare them with the PNGs currently stored on disk.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import numpy as np
from PIL import Image, ImageDraw

from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
CANVAS_SIZE = (64, 64)
OUTPUT_PREVIEW = ROOT / "dev_tools/output/building_foreground_layers_montage.png"


@dataclass(frozen=True)
class LayerSpec:
    name: str
    source: Path
    lower_output: Path
    upper_output: Path
    upper_rectangles: tuple[tuple[int, int, int, int], ...]
    expected_upper_visible: int
    expected_total_visible: int


# Rectangles are (y_begin, y_end, x_begin, x_end), with exclusive ends.  They
# are the native 64x64 coordinates recovered from the user's red-line review.
RESEARCH_UPPER_RECTANGLES = (
    (5, 6, 27, 41),
    (6, 8, 26, 41),
    (8, 10, 25, 42),
    (10, 11, 25, 43),
    (11, 12, 25, 44),
    (12, 17, 24, 44),
    (17, 20, 24, 43),
    (20, 26, 24, 42),
    (26, 33, 23, 42),
    (33, 34, 25, 38),
)

PLANT_CULTIVATION_UPPER_RECTANGLES = (
    (4, 5, 22, 38),
    (5, 6, 21, 41),
    (6, 7, 20, 42),
    (7, 8, 20, 43),
    (8, 9, 19, 44),
    (9, 10, 18, 45),
    (10, 11, 18, 46),
    (11, 13, 18, 47),
    (13, 14, 53, 57),
    (13, 20, 17, 47),
    (14, 15, 7, 11),
    (14, 15, 52, 60),
    (15, 16, 5, 13),
    (15, 16, 51, 60),
    (16, 17, 4, 14),
    (16, 17, 51, 61),
    (17, 18, 3, 14),
    (17, 18, 50, 61),
    (18, 19, 50, 62),
    (18, 24, 3, 15),
    (19, 21, 49, 62),
    (20, 21, 17, 30),
    (20, 21, 36, 48),
    (21, 22, 17, 26),
    (21, 22, 45, 48),
    (21, 22, 49, 63),
    (22, 23, 17, 24),
    (22, 24, 46, 48),
    (22, 25, 50, 63),
    (23, 24, 17, 23),
    (24, 28, 45, 48),
    (24, 29, 2, 15),
    (24, 31, 17, 22),
    (25, 26, 51, 63),
    (26, 28, 52, 63),
    (28, 30, 44, 48),
    (28, 32, 53, 63),
    (29, 32, 3, 14),
    (30, 31, 45, 48),
    (31, 32, 17, 21),
    (31, 32, 46, 47),
    (32, 34, 53, 62),
    (32, 35, 3, 13),
    (34, 36, 52, 62),
    (35, 36, 3, 12),
    (36, 37, 4, 12),
    (36, 37, 52, 61),
    (37, 38, 54, 60),
    (38, 39, 56, 59),
)


SPECS = (
    LayerSpec(
        name="research_center",
        source=ROOT
        / "resources/texture/plant_defense/research_center/research_center.png",
        lower_output=ROOT
        / "resources/texture/plant_defense/research_center/layers/lower_body.png",
        upper_output=ROOT
        / "resources/texture/plant_defense/research_center/layers/upper_foreground.png",
        upper_rectangles=RESEARCH_UPPER_RECTANGLES,
        expected_upper_visible=371,
        expected_total_visible=1816,
    ),
    LayerSpec(
        name="plant_cultivation_center",
        source=ROOT
        / "resources/texture/plant_defense/plant_cultivation_center/plant_cultivation_center.png",
        lower_output=ROOT
        / "resources/texture/plant_defense/plant_cultivation_center/layers/lower_body.png",
        upper_output=ROOT
        / "resources/texture/plant_defense/plant_cultivation_center/layers/upper_foreground.png",
        upper_rectangles=PLANT_CULTIVATION_UPPER_RECTANGLES,
        expected_upper_visible=880,
        expected_total_visible=2529,
    ),
)


def _sha256_pixels(pixels: np.ndarray) -> str:
    return hashlib.sha256(pixels.tobytes()).hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def _load_native_source(spec: LayerSpec) -> tuple[Image.Image, np.ndarray, dict]:
    _require(spec.source.is_file(), f"Missing source sprite: {spec.source}")
    with Image.open(spec.source) as source_file:
        image = source_file.convert("RGBA")
    pixels = np.array(image, dtype=np.uint8)
    analysis = analyze_image(image)

    _require(image.size == CANVAS_SIZE, f"{spec.name}: source must be 64x64")
    _require(
        analysis["grid_cell_width"] == 1.0
        and analysis["grid_cell_height"] == 1.0
        and analysis["recommended_canvas_grid_width"] == 64
        and analysis["recommended_canvas_grid_height"] == 64,
        f"{spec.name}: pixel_grid_analyzer did not verify a native 1px grid: {analysis}",
    )

    alpha_values = set(np.unique(pixels[:, :, 3]).tolist())
    _require(
        alpha_values.issubset({0, 255}),
        f"{spec.name}: source alpha is not binary: {sorted(alpha_values)}",
    )
    transparent = pixels[:, :, 3] == 0
    _require(
        bool(np.all(pixels[transparent, :3] == 0)),
        f"{spec.name}: source has non-zero RGB in transparent pixels",
    )
    visible_count = int(np.count_nonzero(~transparent))
    _require(
        visible_count == spec.expected_total_visible,
        f"{spec.name}: visible pixel count changed: "
        f"{visible_count} != {spec.expected_total_visible}",
    )
    return image, pixels, analysis


def _reviewed_mask(spec: LayerSpec) -> np.ndarray:
    height, width = CANVAS_SIZE[1], CANVAS_SIZE[0]
    mask = np.zeros((height, width), dtype=bool)
    for y_begin, y_end, x_begin, x_end in spec.upper_rectangles:
        _require(
            0 <= y_begin < y_end <= height and 0 <= x_begin < x_end <= width,
            f"{spec.name}: reviewed rectangle is outside 64x64: "
            f"{(y_begin, y_end, x_begin, x_end)}",
        )
        mask[y_begin:y_end, x_begin:x_end] = True
    return mask


def _validate_layer_image(name: str, pixels: np.ndarray) -> None:
    _require(
        pixels.shape == (64, 64, 4),
        f"{name}: layer array must be 64x64 RGBA, got {pixels.shape}",
    )
    alpha_values = set(np.unique(pixels[:, :, 3]).tolist())
    _require(
        alpha_values.issubset({0, 255}),
        f"{name}: layer alpha is not binary: {sorted(alpha_values)}",
    )
    transparent = pixels[:, :, 3] == 0
    _require(
        bool(np.all(pixels[transparent, :3] == 0)),
        f"{name}: transparent RGB must be zero",
    )


def _build_layers(spec: LayerSpec) -> dict:
    source_image, source, analysis = _load_native_source(spec)
    reviewed_mask = _reviewed_mask(spec)
    source_visible = source[:, :, 3] == 255
    upper_visible = reviewed_mask & source_visible
    lower_visible = (~reviewed_mask) & source_visible

    lower = np.zeros_like(source)
    upper = np.zeros_like(source)
    lower[lower_visible] = source[lower_visible]
    upper[upper_visible] = source[upper_visible]
    _validate_layer_image(f"{spec.name}/lower_body", lower)
    _validate_layer_image(f"{spec.name}/upper_foreground", upper)

    _require(
        not bool(np.any(lower_visible & upper_visible)),
        f"{spec.name}: lower and upper layers overlap",
    )
    recomposed = lower.copy()
    recomposed[upper_visible] = upper[upper_visible]
    _require(
        bool(np.array_equal(recomposed, source)),
        f"{spec.name}: layers do not reconstruct every source RGBA pixel",
    )

    upper_count = int(np.count_nonzero(upper_visible))
    lower_count = int(np.count_nonzero(lower_visible))
    _require(
        upper_count == spec.expected_upper_visible,
        f"{spec.name}: reviewed upper visible count changed: "
        f"{upper_count} != {spec.expected_upper_visible}",
    )
    _require(
        lower_count + upper_count == spec.expected_total_visible,
        f"{spec.name}: layer visible counts do not preserve source total",
    )

    return {
        "spec": spec,
        "source_image": source_image,
        "source": source,
        "lower": lower,
        "upper": upper,
        "recomposed": recomposed,
        "analysis": analysis,
        "source_pixel_sha256": _sha256_pixels(source),
        "lower_pixel_sha256": _sha256_pixels(lower),
        "upper_pixel_sha256": _sha256_pixels(upper),
        "upper_visible_pixels": upper_count,
        "lower_visible_pixels": lower_count,
    }


def _save_png(pixels: np.ndarray, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(pixels).save(
        path,
        format="PNG",
        optimize=True,
        compress_level=9,
    )


def _compare_disk_artifact(path: Path, expected: np.ndarray, label: str) -> None:
    _require(path.is_file(), f"{label}: generated artifact is missing: {path}")
    with Image.open(path) as disk_file:
        _require(
            disk_file.size == CANVAS_SIZE,
            f"{label}: disk artifact must be 64x64, got {disk_file.size}",
        )
        disk = np.array(disk_file.convert("RGBA"), dtype=np.uint8)
    _validate_layer_image(label, disk)
    _require(
        bool(np.array_equal(disk, expected)),
        f"{label}: disk PNG differs from the reproducibly generated RGBA pixels",
    )


def _checkerboard() -> Image.Image:
    canvas = Image.new("RGBA", CANVAS_SIZE, (174, 180, 180, 255))
    draw = ImageDraw.Draw(canvas)
    for y in range(0, 64, 4):
        for x in range(0, 64, 4):
            if (x // 4 + y // 4) % 2 == 0:
                draw.rectangle((x, y, x + 3, y + 3), fill=(198, 203, 203, 255))
    return canvas


def _preview_cell(pixels: np.ndarray, scale: int = 6) -> Image.Image:
    background = _checkerboard()
    background.alpha_composite(Image.fromarray(pixels))
    return background.resize((64 * scale, 64 * scale), Image.Resampling.NEAREST)


def _write_montage(results: Iterable[dict]) -> None:
    results = list(results)
    scale = 6
    gap = 8
    cell_size = 64 * scale
    montage = Image.new(
        "RGBA",
        (cell_size * 4 + gap * 3, cell_size * len(results) + gap * (len(results) - 1)),
        (112, 118, 118, 255),
    )
    for row, result in enumerate(results):
        for column, key in enumerate(("source", "lower", "upper", "recomposed")):
            montage.alpha_composite(
                _preview_cell(result[key], scale),
                (column * (cell_size + gap), row * (cell_size + gap)),
            )
    OUTPUT_PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    montage.convert("RGB").save(OUTPUT_PREVIEW, format="PNG", optimize=True)


def _report(results: Iterable[dict], check_only: bool) -> dict:
    buildings = []
    for result in results:
        spec: LayerSpec = result["spec"]
        analysis = dict(result["analysis"])
        buildings.append(
            {
                "name": spec.name,
                "source": str(spec.source.relative_to(ROOT)).replace("\\", "/"),
                "pixel_grid_analyzer": analysis,
                "source_pixel_sha256": result["source_pixel_sha256"],
                "lower_pixel_sha256": result["lower_pixel_sha256"],
                "upper_pixel_sha256": result["upper_pixel_sha256"],
                "visible_pixels": {
                    "total": spec.expected_total_visible,
                    "lower": result["lower_visible_pixels"],
                    "upper": result["upper_visible_pixels"],
                },
                "checks": {
                    "native_64x64_one_pixel_grid": True,
                    "binary_alpha": True,
                    "transparent_rgb_zero": True,
                    "lower_upper_non_overlapping": True,
                    "lossless_rgba_recomposition": True,
                    "disk_artifacts_match": True,
                },
            }
        )
    return {
        "status": "passed",
        "mode": "check_only" if check_only else "build",
        "resampling": "none",
        "buildings": buildings,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Do not write; compare regenerated layers with the PNGs on disk.",
    )
    args = parser.parse_args()

    results = [_build_layers(spec) for spec in SPECS]
    if not args.check_only:
        for result in results:
            spec: LayerSpec = result["spec"]
            _save_png(result["lower"], spec.lower_output)
            _save_png(result["upper"], spec.upper_output)
        _write_montage(results)

    # Both modes certify the actual files on disk.  In build mode this also
    # catches encoder/write mistakes immediately after generation.
    for result in results:
        spec: LayerSpec = result["spec"]
        _compare_disk_artifact(
            spec.lower_output,
            result["lower"],
            f"{spec.name}/lower_body",
        )
        _compare_disk_artifact(
            spec.upper_output,
            result["upper"],
            f"{spec.name}/upper_foreground",
        )

    print(json.dumps(_report(results, args.check_only), ensure_ascii=False, indent=2))
    if not args.check_only:
        print(f"Visual montage: {OUTPUT_PREVIEW}")


if __name__ == "__main__":
    main()
