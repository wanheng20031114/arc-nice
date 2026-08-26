#!/usr/bin/env python3
"""Deterministically build and validate consumable icons and native repairs.

Each approved transparent ImageGen master is retained beside its processing
artifacts. Rejected rasters are removed after approval unless an accepted
precise edit uses them as an input. One pixel is sampled per *measured* logical source cell, and the result is
centered on a transparent 32x32 canvas.  The pipeline intentionally has no
unsafe resize or palette-reduction escape hatch: an unreliable or oversized
source must be regenerated instead of being hidden behind destructive
downscaling.  Human-authored native masters are validation-only inputs and are
never overwritten by the ImageGen rebuild path.

Examples:
  python dev_tools/process_consumable_assets.py --list-plan
  python dev_tools/process_consumable_assets.py --asset skill_charge_battery
  python dev_tools/process_consumable_assets.py
"""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    NormalizedSubject,
    TRANSPARENT,
    clean_transparency,
    load_transparent_source,
    normalize_imagegen_subject,
    portable_path,
    source_audit,
)
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "dev_assets/source_images/consumables"
OUTPUT_ROOT = ROOT / "resources/texture/consumables"
CANVAS_SIZE = (32, 32)
MIN_SUBJECT_SIZE = (8, 8)
TRANSPARENT_BORDER = 1
OUTER_BOUNDARY_COLOR = (5, 8, 12, 255)
OUTER_BOUNDARY_TOLERANCE = 8
MAX_SECOND_LAYER_DARK_RATIO = 0.20
MAX_ALIGNED_SAME_COLOR_2X2_COVERAGE = 0.25


@dataclass(frozen=True)
class AssetSpec:
    slug: str
    display_name: str
    tier: str
    shape: str
    max_subject_size: tuple[int, int]
    reviewed_logical_size: tuple[int, int] | None = None
    review_note: str = ""
    expected_normalized_size: tuple[int, int] | None = None
    logical_row_deletions: tuple[int, ...] = ()
    logical_row_duplications_after: tuple[int, ...] = ()
    expected_final_size: tuple[int, int] | None = None
    forbid_production_upscale: bool = False
    repair_asset: bool = False
    native_manual_master_filename: str | None = None
    manual_master_note: str = ""

    @property
    def source_directory(self) -> Path:
        return SOURCE_ROOT / self.slug

    @property
    def source_path(self) -> Path:
        if self.native_manual_master_filename is not None:
            return self.source_directory / self.native_manual_master_filename
        return self.alpha_path

    @property
    def alpha_path(self) -> Path:
        return self.source_directory / f"{self.slug}_alpha.png"

    @property
    def logical_preview_path(self) -> Path:
        return self.source_directory / f"{self.slug}_logical_preview.png"

    @property
    def output_path(self) -> Path:
        return OUTPUT_ROOT / f"{self.slug}.png"

    @property
    def atlas_path(self) -> Path:
        return ROOT / "resources/atlas" / f"{self.slug}.tres"

    @property
    def config_path(self) -> Path:
        return ROOT / "resources/config/consumables" / f"{self.slug}.tres"


# Small/large pairs intentionally use the same 20-ish/25-ish width language as
# the existing healing and rock bottles.  A redraw source may temporarily be
# taller than 30 logical rows only when a reviewed, explicit row-removal recipe
# brings the native result back under the 30x30 production contract.
ASSETS = (
    AssetSpec(
        "skill_charge_battery",
        "蓝晶技力电池",
        "low",
        "small_battery",
        (22, 30),
    ),
    AssetSpec(
        "large_skill_charge_battery",
        "大型蓝晶技力电池",
        "medium",
        "large_battery",
        (27, 30),
    ),
    AssetSpec(
        "magic_resistance_potion",
        "紫晶法抗药水",
        "low",
        "small_bottle",
        (22, 30),
        native_manual_master_filename="magic_resistance_potion_native_manual_master.png",
        manual_master_note=(
            "Native 32x32 manual correction committed by the user in 609532c5. "
            "The production texture is authoritative; full ImageGen rebuilds "
            "audit it but never overwrite it."
        ),
    ),
    AssetSpec(
        "large_magic_resistance_potion",
        "大型紫晶法抗药水",
        "medium",
        "large_bottle",
        (27, 30),
    ),
    AssetSpec(
        "regeneration_potion",
        "凝胶再生剂",
        "low",
        "small_bottle",
        (22, 30),
        native_manual_master_filename="regeneration_potion_native_manual_master.png",
        manual_master_note=(
            "Native 32x32 manual correction committed by the user in 609532c5. "
            "The production texture is authoritative; full ImageGen rebuilds "
            "audit it but never overwrite it."
        ),
    ),
    AssetSpec(
        "large_regeneration_potion",
        "大型凝胶再生剂",
        "medium",
        "large_bottle",
        (27, 30),
    ),
    AssetSpec("guardian_mixture", "守护合剂", "medium", "single_bottle", (24, 30)),
    AssetSpec(
        "battle_spirit_potion",
        "战意药水",
        "medium",
        "single_bottle",
        (20, 31),
        reviewed_logical_size=(20, 31),
        review_note=(
            "PerfectPixel and gradient reviews both locked 20x31; the "
            "262x419 source bbox yields near-square 13.10x13.52 cells."
        ),
        expected_normalized_size=(20, 31),
        logical_row_deletions=(2,),
        expected_final_size=(20, 30),
        forbid_production_upscale=True,
    ),
    AssetSpec("focus_potion", "专注药水", "medium", "single_bottle", (24, 30)),
    AssetSpec(
        "windwalk_potion",
        "风行药水",
        "medium",
        "single_bottle",
        (24, 32),
        reviewed_logical_size=(24, 32),
        review_note=(
            "PerfectPixel independent review locked 24x32. The automatic "
            "analyzer proposed 26x32 with a less plausible X/Y cell ratio."
        ),
        expected_normalized_size=(24, 32),
        logical_row_deletions=(2, 10),
        expected_final_size=(24, 30),
        forbid_production_upscale=True,
    ),
    AssetSpec(
        "phantom_potion",
        "幻影药剂",
        "medium",
        "single_bottle",
        (24, 30),
        native_manual_master_filename="phantom_potion_native_manual_master.png",
        manual_master_note=(
            "Native 32x32 manual correction committed by the user in 609532c5. "
            "The production texture is authoritative; full ImageGen rebuilds "
            "audit it but never overwrite it."
        ),
    ),
    AssetSpec(
        "void_battery",
        "虚空电池",
        "high",
        "battery",
        (28, 30),
        reviewed_logical_size=(18, 26),
        review_note=(
            "Manual per-source review accepted the 18x26 grid. The automatic "
            "analyzer reported confidence 0.574 with near-square periods "
            "30.7x30.2 physical pixels; the low score is caused by a local "
            "14px Y-axis harmonic, not a continuous or ungridded illustration."
        ),
    ),
)


REPAIR_ASSETS = (
    AssetSpec(
        "healing_potion",
        "治疗血瓶",
        "low",
        "small_bottle",
        (22, 30),
        reviewed_logical_size=(22, 28),
        review_note=(
            "Manual review locked 22x28: the 568x710 source bbox yields "
            "near-square 25.82x25.36 cells. Two reviewed belly rows are "
            "authored by duplicating existing native rows without scaling."
        ),
        expected_normalized_size=(22, 28),
        logical_row_duplications_after=(18, 20),
        expected_final_size=(22, 30),
        forbid_production_upscale=True,
        repair_asset=True,
    ),
)


ALL_ASSETS = ASSETS + REPAIR_ASSETS


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _visible_colors(image: Image.Image) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for red, green, blue, alpha in image.convert("RGBA").getdata()
        if alpha > 0
    }


def _delete_logical_rows(
    image: Image.Image,
    row_indices: tuple[int, ...],
) -> Image.Image:
    """Remove reviewed logical rows without resampling any retained pixel."""
    if not row_indices:
        return clean_transparency(image)
    if len(set(row_indices)) != len(row_indices):
        raise RuntimeError(f"Logical row deletion contains duplicates: {row_indices}")
    invalid = [row for row in row_indices if row < 0 or row >= image.height]
    if invalid:
        raise RuntimeError(
            f"Logical row deletion is outside 0..{image.height - 1}: {invalid}"
        )
    deleted = set(row_indices)
    retained_rows = [row for row in range(image.height) if row not in deleted]
    result = Image.new("RGBA", (image.width, len(retained_rows)), TRANSPARENT)
    source = image.convert("RGBA")
    for target_row, source_row in enumerate(retained_rows):
        result.paste(
            source.crop((0, source_row, source.width, source_row + 1)),
            (0, target_row),
        )
    return clean_transparency(result)


def _duplicate_logical_rows_after(
    image: Image.Image,
    row_indices: tuple[int, ...],
) -> Image.Image:
    """Duplicate reviewed native rows without resizing any authored pixel."""
    if not row_indices:
        return clean_transparency(image)
    if len(set(row_indices)) != len(row_indices):
        raise RuntimeError(f"Logical row duplication contains duplicates: {row_indices}")
    invalid = [row for row in row_indices if row < 0 or row >= image.height]
    if invalid:
        raise RuntimeError(
            f"Logical row duplication is outside 0..{image.height - 1}: {invalid}"
        )
    duplicated = set(row_indices)
    source = image.convert("RGBA")
    result = Image.new(
        "RGBA",
        (image.width, image.height + len(row_indices)),
        TRANSPARENT,
    )
    target_row = 0
    for source_row in range(source.height):
        row = source.crop((0, source_row, source.width, source_row + 1))
        result.paste(row, (0, target_row))
        target_row += 1
        if source_row in duplicated:
            result.paste(row, (0, target_row))
            target_row += 1
    return clean_transparency(result)


def _outer_boundary_pixels(image: Image.Image) -> set[tuple[int, int]]:
    """Return opaque pixels touching 4-connected exterior transparency.

    A transparent one-pixel pad makes the outside explicit.  Flood filling it
    prevents transparent decorative holes inside an icon from being mistaken
    for the silhouette's outer edge.
    """
    rgba = clean_transparency(image)
    padded = Image.new(
        "RGBA",
        (rgba.width + 2, rgba.height + 2),
        TRANSPARENT,
    )
    padded.alpha_composite(rgba, (1, 1))
    pixels = padded.load()
    exterior: set[tuple[int, int]] = {(0, 0)}
    queue: deque[tuple[int, int]] = deque(((0, 0),))
    while queue:
        x, y = queue.popleft()
        for delta_x, delta_y in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            neighbour = (x + delta_x, y + delta_y)
            if not (
                0 <= neighbour[0] < padded.width
                and 0 <= neighbour[1] < padded.height
            ):
                continue
            if neighbour in exterior or pixels[neighbour][3] > 0:
                continue
            exterior.add(neighbour)
            queue.append(neighbour)

    boundary: set[tuple[int, int]] = set()
    for y in range(rgba.height):
        for x in range(rgba.width):
            if rgba.getpixel((x, y))[3] == 0:
                continue
            padded_point = (x + 1, y + 1)
            if any(
                (padded_point[0] + delta_x, padded_point[1] + delta_y)
                in exterior
                for delta_x, delta_y in ((1, 0), (-1, 0), (0, 1), (0, -1))
            ):
                boundary.add((x, y))
    return boundary


def _is_boundary_dark(pixel: tuple[int, int, int, int]) -> bool:
    return pixel[3] == 255 and all(
        abs(pixel[channel] - OUTER_BOUNDARY_COLOR[channel])
        <= OUTER_BOUNDARY_TOLERANCE
        for channel in range(3)
    )


def _enforce_uniform_outer_boundary(
    image: Image.Image,
) -> tuple[Image.Image, set[tuple[int, int]]]:
    """Recolour only the 4-neighbour outermost silhouette pixels."""
    result = clean_transparency(image)
    boundary = _outer_boundary_pixels(result)
    if not boundary:
        raise RuntimeError("Cannot enforce an outer boundary on an empty subject")
    pixels = result.load()
    for point in boundary:
        pixels[point] = OUTER_BOUNDARY_COLOR
    return result, boundary


def _aligned_same_color_2x2_coverage(image: Image.Image) -> float:
    """Measure non-overlapping, origin-aligned 2x2 macroblock coverage.

    Four opaque pixels count as the same colour when every RGB channel spans at
    most eight values.  Coverage is the fraction of all opaque subject pixels
    contained in such a block; this catches the rejected 16x16-upscaled look.
    """
    rgba = image.convert("RGBA")
    opaque_count = sum(alpha > 0 for *_, alpha in rgba.getdata())
    if opaque_count == 0:
        return 0.0
    pixels = rgba.load()
    covered: set[tuple[int, int]] = set()
    for y in range(0, rgba.height - 1, 2):
        for x in range(0, rgba.width - 1, 2):
            points = ((x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1))
            colors = [pixels[point] for point in points]
            if not all(color[3] == 255 for color in colors):
                continue
            if all(
                max(color[channel] for color in colors)
                - min(color[channel] for color in colors)
                <= OUTER_BOUNDARY_TOLERANCE
                for channel in range(3)
            ):
                covered.update(points)
    return len(covered) / opaque_count


def _redraw_metrics(
    image: Image.Image,
    boundary: set[tuple[int, int]],
) -> dict:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    second_layer: set[tuple[int, int]] = set()
    for y in range(rgba.height):
        for x in range(rgba.width):
            point = (x, y)
            if pixels[point][3] == 0 or point in boundary:
                continue
            if any(
                (x + delta_x, y + delta_y) in boundary
                for delta_x, delta_y in ((1, 0), (-1, 0), (0, 1), (0, -1))
            ):
                second_layer.add(point)

    outer_ratio = sum(_is_boundary_dark(pixels[point]) for point in boundary) / len(
        boundary
    )
    second_ratio = (
        sum(_is_boundary_dark(pixels[point]) for point in second_layer)
        / len(second_layer)
        if second_layer
        else 0.0
    )
    aligned_coverage = _aligned_same_color_2x2_coverage(rgba)
    return {
        "boundary_connectivity": 4,
        "uniform_outer_boundary_rgba": list(OUTER_BOUNDARY_COLOR),
        "dark_rgb_tolerance": OUTER_BOUNDARY_TOLERANCE,
        "outer_boundary_pixel_count": len(boundary),
        "second_layer_pixel_count": len(second_layer),
        "outer_boundary_dark_ratio": round(outer_ratio, 6),
        "second_layer_dark_ratio": round(second_ratio, 6),
        "aligned_tolerance8_same_color_2x2_coverage": round(
            aligned_coverage,
            6,
        ),
    }


def _apply_reviewed_redraw(
    spec: AssetSpec,
    normalized: NormalizedSubject,
) -> tuple[Image.Image, dict]:
    logical = clean_transparency(normalized.image)
    if spec.expected_normalized_size is None or spec.expected_final_size is None:
        raise RuntimeError(f"Incomplete redraw contract for {spec.slug}")
    if logical.size != spec.expected_normalized_size:
        raise RuntimeError(
            f"Normalized source changed for {spec.slug}: expected "
            f"{spec.expected_normalized_size}, received {logical.size}"
        )
    edited = _delete_logical_rows(logical, spec.logical_row_deletions)
    edited = _duplicate_logical_rows_after(
        edited,
        spec.logical_row_duplications_after,
    )
    if edited.size != spec.expected_final_size:
        raise RuntimeError(
            f"Reviewed row edit changed for {spec.slug}: expected "
            f"{spec.expected_final_size}, received {edited.size}"
        )
    outlined, boundary = _enforce_uniform_outer_boundary(edited)
    metrics = _redraw_metrics(outlined, boundary)
    assertions = {
        "outer_boundary_dark_ratio_is_1_0": (
            metrics["outer_boundary_dark_ratio"] == 1.0
        ),
        "second_layer_dark_ratio_at_most_0_20": (
            metrics["second_layer_dark_ratio"] <= MAX_SECOND_LAYER_DARK_RATIO
        ),
        "aligned_tolerance8_same_color_2x2_coverage_at_most_0_25": (
            metrics["aligned_tolerance8_same_color_2x2_coverage"]
            <= MAX_ALIGNED_SAME_COLOR_2X2_COVERAGE
        ),
    }
    failures = [name for name, passed in assertions.items() if not passed]
    if failures:
        raise RuntimeError(f"{spec.slug} strict redraw audit failed: {failures}")
    return outlined, {
        "expected_normalized_size": list(spec.expected_normalized_size),
        "deleted_original_logical_rows": list(spec.logical_row_deletions),
        "duplicated_post_deletion_logical_rows_after": list(
            spec.logical_row_duplications_after
        ),
        "expected_final_size": list(spec.expected_final_size),
        "retained_pixel_resampling": "none",
        "internal_color_blocks_modified": False,
        "outer_boundary_recolour_only": True,
        "metrics": metrics,
        "assertions": assertions,
    }


def _center_on_canvas(subject: Image.Image) -> tuple[Image.Image, tuple[int, int]]:
    if subject.width > 30 or subject.height > 30:
        raise RuntimeError(
            f"Logical subject {subject.size} cannot retain a one-pixel border on {CANVAS_SIZE}"
        )
    origin = (
        (CANVAS_SIZE[0] - subject.width) // 2,
        (CANVAS_SIZE[1] - subject.height) // 2,
    )
    canvas = Image.new("RGBA", CANVAS_SIZE, TRANSPARENT)
    canvas.alpha_composite(subject, origin)
    return clean_transparency(canvas), origin


def _nearest_upscale_to_contract(
    logical: Image.Image,
    max_subject_size: tuple[int, int],
) -> tuple[Image.Image, float]:
    """Enlarge a sparse logical sprite for a readable 32px inventory bbox.

    This operation never shrinks, smooths, quantizes, or invents colors.  The
    untouched measured-grid result remains saved as ``logical_preview``; the
    production texture only repeats those exact cells with nearest sampling.
    """
    max_width, max_height = max_subject_size
    scale = min(max_width / logical.width, max_height / logical.height)
    if scale < 1.0:
        raise RuntimeError(
            f"Logical subject {logical.size} exceeds production cap {max_subject_size}"
        )
    target_size = (
        max(logical.width, min(max_width, round(logical.width * scale))),
        max(logical.height, min(max_height, round(logical.height * scale))),
    )
    if target_size == logical.size:
        return logical.copy(), 1.0
    return (
        clean_transparency(
            logical.resize(target_size, Image.Resampling.NEAREST)
        ),
        scale,
    )


def _audit_output(
    output: Image.Image,
    subject: Image.Image,
    paste_origin: tuple[int, int],
) -> tuple[dict, tuple[int, int, int, int]]:
    rgba = output.convert("RGBA")
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Output contains no visible subject")
    alpha_values = sorted(set(rgba.getchannel("A").getdata()))
    placed = rgba.crop(
        (
            paste_origin[0],
            paste_origin[1],
            paste_origin[0] + subject.width,
            paste_origin[1] + subject.height,
        )
    )
    checks = {
        "canvas_32x32": rgba.size == CANVAS_SIZE,
        "one_pixel_transparent_border": (
            bbox[0] >= TRANSPARENT_BORDER
            and bbox[1] >= TRANSPARENT_BORDER
            and bbox[2] <= CANVAS_SIZE[0] - TRANSPARENT_BORDER
            and bbox[3] <= CANVAS_SIZE[1] - TRANSPARENT_BORDER
        ),
        "binary_alpha": set(alpha_values).issubset({0, 255}),
        "transparent_rgb_clean": all(
            alpha > 0 or (red, green, blue) == (0, 0, 0)
            for red, green, blue, alpha in rgba.getdata()
        ),
        "logical_pixels_preserved": placed.tobytes() == subject.tobytes(),
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise RuntimeError("; ".join(failures))
    return checks, bbox


def _save_lossless(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True, compress_level=9)


def _normalize_source(spec: AssetSpec, source: Image.Image) -> NormalizedSubject:
    if spec.reviewed_logical_size is None:
        return normalize_imagegen_subject(
            spec.source_path,
            max_subject_size=spec.max_subject_size,
            fit_oversized=False,
        )

    analysis = analyze_image(source)
    bbox_dict = analysis["subject_bbox"]
    bbox = (
        int(bbox_dict["left"]),
        int(bbox_dict["top"]),
        int(bbox_dict["right"]),
        int(bbox_dict["bottom"]),
    )
    logical_width, logical_height = spec.reviewed_logical_size
    if (
        logical_width > spec.max_subject_size[0]
        or logical_height > spec.max_subject_size[1]
    ):
        raise RuntimeError(
            f"Reviewed grid {spec.reviewed_logical_size} exceeds {spec.max_subject_size}"
        )
    cell_width = (bbox[2] - bbox[0]) / logical_width
    cell_height = (bbox[3] - bbox[1]) / logical_height
    cell_ratio = max(cell_width, cell_height) / min(cell_width, cell_height)
    if cell_ratio > 1.10:
        raise RuntimeError(
            f"Reviewed grid cells are not near-square for {spec.slug}: "
            f"{cell_width:.3f}x{cell_height:.3f}"
        )
    subject = clean_transparency(
        source.crop(bbox).resize(
            spec.reviewed_logical_size,
            Image.Resampling.NEAREST,
        )
    )
    reviewed_analysis = {
        **analysis,
        "manual_review": {
            "approved_logical_size": list(spec.reviewed_logical_size),
            "cell_width": round(cell_width, 3),
            "cell_height": round(cell_height, 3),
            "cell_aspect_ratio": round(cell_ratio, 3),
            "note": spec.review_note,
            "global_unsafe_override_enabled": False,
        },
    }
    return NormalizedSubject(
        image=subject,
        source_path=spec.source_path,
        source_analysis=reviewed_analysis,
        logical_size=subject.size,
        detected_logical_size=spec.reviewed_logical_size,
        logical_fit_scale=1.0,
        normalization_mode="manual_reviewed_grid_center_sample",
    )


def _build_native_manual_asset(spec: AssetSpec) -> dict:
    """Validate a user-authored native master without writing production pixels."""
    if spec.native_manual_master_filename is None:
        raise RuntimeError(f"{spec.slug} is not a native manual-master asset")
    if not spec.source_path.is_file():
        raise FileNotFoundError(spec.source_path)
    if not spec.output_path.is_file():
        raise FileNotFoundError(spec.output_path)

    with Image.open(spec.source_path) as opened:
        master = opened.convert("RGBA")
    with Image.open(spec.output_path) as opened:
        production = opened.convert("RGBA")
    if master.size != CANVAS_SIZE or production.size != CANVAS_SIZE:
        raise RuntimeError(
            f"Native manual master must remain 32x32 for {spec.slug}: "
            f"master={master.size}, production={production.size}"
        )
    master_matches_production = master.tobytes() == production.tobytes()
    if not master_matches_production:
        raise RuntimeError(
            f"Native manual master drifted from production for {spec.slug}; "
            "refresh the reviewed master explicitly instead of rebuilding it"
        )
    bbox = production.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError(f"Native manual master is empty: {spec.slug}")
    subject = production.crop(bbox)
    checks, output_bbox = _audit_output(
        production,
        subject,
        (bbox[0], bbox[1]),
    )
    checks.update(
        {
            "native_manual_master_matches_production_pixels": (
                master_matches_production
            ),
            "production_write_skipped": True,
        }
    )
    report = {
        "schema_version": 2,
        "asset": spec.slug,
        "display_name": spec.display_name,
        "status": "passed_native_manual_master",
        "tier": spec.tier,
        "shape": spec.shape,
        "repair_asset": spec.repair_asset,
        "pipeline_mode": "native_manual_master_validation_only",
        "production_overwrite_policy": "never",
        "manual_master_note": spec.manual_master_note,
        "paths": {
            "native_manual_master": portable_path(spec.source_path),
            "production_texture": portable_path(spec.output_path),
            "atlas": portable_path(spec.atlas_path),
            "config": portable_path(spec.config_path),
        },
        "source_selection": {
            "approved": {
                "path": portable_path(spec.source_path),
                "sha256": _sha256(spec.source_path),
                "kind": "user_authored_native_manual_master",
            },
        },
        "hashes": {
            "native_manual_master_sha256": _sha256(spec.source_path),
            "production_texture_sha256": _sha256(spec.output_path),
            "processing_script_sha256": _sha256(Path(__file__)),
        },
        "logical_subject_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        "production_subject_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        "production_upscale": 1.0,
        "paste_origin": [bbox[0], bbox[1]],
        "output_bbox_exclusive": list(output_bbox),
        "visible_color_count": len(_visible_colors(production)),
        "alpha_values": sorted(set(production.getchannel("A").getdata())),
        "checks": checks,
    }
    return report


def _assert_existing_png_matches(
    expected: Image.Image,
    path: Path,
    *,
    label: str,
) -> None:
    if not path.is_file():
        raise FileNotFoundError(path)
    with Image.open(path) as opened:
        actual = opened.convert("RGBA")
    expected_rgba = expected.convert("RGBA")
    if (
        actual.size != expected_rgba.size
        or actual.tobytes() != expected_rgba.tobytes()
    ):
        raise RuntimeError(
            f"Configured {label} no longer matches its deterministic build: {path}"
        )


def _build_asset(spec: AssetSpec, *, write_outputs: bool = True) -> dict:
    if spec.native_manual_master_filename is not None:
        return _build_native_manual_asset(spec)
    if not spec.source_path.is_file():
        raise FileNotFoundError(spec.source_path)

    source = load_transparent_source(spec.source_path)
    normalized = _normalize_source(spec, source)
    logical = clean_transparency(normalized.image)
    redraw_record: dict | None = None
    if spec.logical_row_deletions or spec.logical_row_duplications_after:
        logical, redraw_record = _apply_reviewed_redraw(spec, normalized)
    if logical.width < MIN_SUBJECT_SIZE[0] or logical.height < MIN_SUBJECT_SIZE[1]:
        raise RuntimeError(
            f"Logical subject {logical.size} is too small to remain legible: {spec.slug}"
        )
    if normalized.logical_fit_scale != 1.0:
        raise RuntimeError(
            f"Logical fit would be destructive for {spec.slug}: "
            f"scale={normalized.logical_fit_scale}"
        )

    if spec.forbid_production_upscale:
        production_subject = logical.copy()
        production_upscale = 1.0
    else:
        production_subject, production_upscale = _nearest_upscale_to_contract(
            logical,
            spec.max_subject_size,
        )
    if _visible_colors(production_subject) != _visible_colors(logical):
        raise RuntimeError(
            f"Nearest production upscale changed the authored palette: {spec.slug}"
        )
    output, paste_origin = _center_on_canvas(production_subject)
    checks, output_bbox = _audit_output(
        output,
        production_subject,
        paste_origin,
    )
    if redraw_record is not None:
        checks.update(redraw_record["assertions"])

    if write_outputs:
        _save_lossless(logical, spec.logical_preview_path)
        _save_lossless(output, spec.output_path)
    else:
        _assert_existing_png_matches(
            logical,
            spec.logical_preview_path,
            label=f"{spec.slug} logical preview",
        )
        _assert_existing_png_matches(
            output,
            spec.output_path,
            label=f"{spec.slug} production texture",
        )

    report = {
        "schema_version": 2,
        "asset": spec.slug,
        "display_name": spec.display_name,
        "status": "passed",
        "tier": spec.tier,
        "shape": spec.shape,
        "repair_asset": spec.repair_asset,
        "pipeline": [
            "built-in ImageGen native transparent source, one distinct source per item",
            "visible RGBA preserved without palette quantization",
            "strict pixel-grid analysis with no unsafe compression override",
            "one final pixel center-sampled per measured logical cell",
            (
                "no production upscale or shrink for reviewed redraw"
                if spec.forbid_production_upscale
                else "nearest-neighbour upscale only when needed for a readable inventory bbox"
            ),
            "centered placement on a transparent 32x32 RGBA canvas",
            "binary alpha, clean transparent RGB, and one-pixel border audit",
            "lossless PNG encoding",
        ],
        "commands": {
            "build": f"python dev_tools/process_consumable_assets.py --asset {spec.slug}",
        },
        "processing_parameters": {
            "hard_alpha": True,
            "transparent_rgb": [0, 0, 0],
            "logical_sampler": "Pillow nearest center sample",
            "production_upscale": (
                "forbidden; native logical pixels are placed 1:1"
                if spec.forbid_production_upscale
                else "nearest only; shrinking forbidden"
            ),
            "palette_quantization": "none",
            "png": "optimize=true, compress_level=9 (lossless)",
        },
        "paths": {
            "source_master": portable_path(spec.source_path),
            "logical_preview": portable_path(spec.logical_preview_path),
            "production_texture": portable_path(spec.output_path),
            "atlas": portable_path(spec.atlas_path),
            "config": portable_path(spec.config_path),
        },
        "source_selection": {
            "approved": {
                "path": portable_path(spec.source_path),
                "sha256": _sha256(spec.source_path),
            },
            "manual_review_note": spec.review_note,
            "global_unsafe_override_enabled": False,
        },
        "hashes": {
            "source_master_sha256": _sha256(spec.source_path),
            "logical_preview_sha256": _sha256(spec.logical_preview_path),
            "production_texture_sha256": _sha256(spec.output_path),
            "processing_script_sha256": _sha256(Path(__file__)),
        },
        "source": source_audit(normalized),
        "reviewed_redraw": redraw_record,
        "max_subject_size": list(spec.max_subject_size),
        "logical_subject_size": list(logical.size),
        "production_subject_size": list(production_subject.size),
        "production_upscale": round(production_upscale, 6),
        "paste_origin": list(paste_origin),
        "output_bbox_exclusive": list(output_bbox),
        "visible_color_count": len(_visible_colors(output)),
        "alpha_values": sorted(set(output.getchannel("A").getdata())),
        "checks": checks,
    }
    return report


def validate_asset_outputs(spec: AssetSpec) -> dict:
    """Rebuild in memory and compare every configured PNG without writing files."""
    return _build_asset(spec, write_outputs=False)


def plan_payload() -> dict:
    return {
        "schema_version": 2,
        "asset_count": len(ASSETS),
        "new_expansion_asset_count": len(ASSETS),
        "repair_asset_count": len(REPAIR_ASSETS),
        "contract": {
            "source_background": "native_transparent_alpha",
            "production_canvas": [32, 32],
            "production_mode": "RGBA",
            "alpha_values": [0, 255],
            "minimum_transparent_border": TRANSPARENT_BORDER,
            "palette_quantization": "none",
            "unsafe_grid_compression": False,
        },
        "assets": [
            {
                **asdict(spec),
                "source": portable_path(spec.source_path),
                "alpha": portable_path(spec.alpha_path),
                "logical_preview": portable_path(spec.logical_preview_path),
                "production_texture": portable_path(spec.output_path),
                "atlas": portable_path(spec.atlas_path),
                "config": portable_path(spec.config_path),
            }
            for spec in ALL_ASSETS
        ],
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build strict 32x32 consumable icons from approved ImageGen masters"
    )
    parser.add_argument(
        "--asset",
        action="append",
        choices=[spec.slug for spec in ALL_ASSETS],
        help="Build only one named asset; repeat to build several",
    )
    parser.add_argument(
        "--list-plan",
        action="store_true",
        help="Print the exact file/size contract without requiring generated sources",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Rebuild in memory and validate configured PNGs without writing files",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    if args.list_plan:
        print(json.dumps(plan_payload(), ensure_ascii=False, indent=2))
        return

    requested = set(args.asset or [])
    specs = [
        spec for spec in ALL_ASSETS if not requested or spec.slug in requested
    ]
    reports = [
        validate_asset_outputs(spec) if args.check_only else _build_asset(spec)
        for spec in specs
    ]
    action = "Checked" if args.check_only else "Built"
    for report in reports:
        print(
            f"{action} {report['asset']}: "
            f"{report['logical_subject_size']} -> 32x32, "
            f"{report['hashes']['production_texture_sha256']}"
        )


if __name__ == "__main__":
    main()
