#!/usr/bin/env python3
"""Audit the 64px visual contract shared by plant-defense buildings.

The raw PNGs are inspected directly instead of through Godot's imported
textures.  This keeps transparent-RGB and palette checks meaningful: Godot's
alpha-border import processing is allowed to populate transparent texels in
the generated texture cache even when the source PNG is clean.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_ROOT = ROOT / "resources/texture/plant_defense"
SOURCE_SIDE = 64
WORLD_SCALE = 0.5
WORLD_FOOTPRINT_SIDE = 32.0
MAX_VISIBLE_COLORS = 64
WAREHOUSE_MAX_SUBJECT_SIZE = (60, 62)
VEGETATION_STAKE_MAX_SUBJECT_SIZE = (22, 23)
VEGETATION_STAKE_MAX_VISIBLE_COLORS = 32
CANVAS_CENTER = (SOURCE_SIDE // 2, SOURCE_SIDE // 2)
AGAVE_HEAD_OFFSET = (0, -6)
AGAVE_HEAD_PIVOT_IN_TEXTURE = (36, 38)
AGAVE_HEAD_MAX_PIVOT_RADIUS = 19.0
CORN_MAX_SUBJECT_SIZE = (58, 60)
CORN_MAX_VISIBLE_COLORS = 48
CORN_BODY_FOOT = (32.0, 62.0)
CORN_HEAD_OFFSET = (-2, -1)
CORN_HEAD_PIVOT_IN_TEXTURE = (32, 32)
CORN_MUZZLE_IN_HEAD_TEXTURE = (57, 33)
CORN_FLASH_ANCHOR = (32, 32)
CORN_SPIN_MUTABLE_BBOX = (33, 24, 55, 41)
PREVIEW_ALIGNMENT_TOLERANCE_WORLD = 0.5

WAREHOUSE_ASSET = TEXTURE_ROOT / "oak_warehouse/oak_warehouse.png"
AGAVE_ICON = TEXTURE_ROOT / "agave_cannon/icon.png"
AGAVE_BODY_FRAMES = tuple(
    TEXTURE_ROOT / f"agave_cannon/agave_body_idle_{index}.png"
    for index in range(4)
)
AGAVE_HEAD_FRAMES = (
    TEXTURE_ROOT / "agave_cannon/agave_cannon_idle_0.png",
    *(
        TEXTURE_ROOT / f"agave_cannon/agave_cannon_fire_{index}.png"
        for index in range(5)
    ),
)
CORN_ICON = TEXTURE_ROOT / "corn_machine_gun/icon.png"
CORN_BODY_FRAMES = tuple(
    TEXTURE_ROOT / f"corn_machine_gun/corn_body_idle_{index}.png"
    for index in range(4)
)
CORN_HEAD_FRAMES = (
    TEXTURE_ROOT / "corn_machine_gun/corn_turret_idle_0.png",
    *(
        TEXTURE_ROOT / f"corn_machine_gun/corn_turret_spin_{index}.png"
        for index in range(4)
    ),
)
CORN_FLASH_FRAMES = tuple(
    TEXTURE_ROOT / f"corn_machine_gun/corn_muzzle_flash_{index}.png"
    for index in range(2)
)
VEGETATION_STAKE_ASSET = TEXTURE_ROOT / "vegetation_stake/vegetation_stake.png"
VEGETATION_STAKE_GLOW = TEXTURE_ROOT / "vegetation_stake/vegetation_stake_glow.png"
BUILDING_ASSETS = (
    WAREHOUSE_ASSET,
    AGAVE_ICON,
    *AGAVE_BODY_FRAMES,
    *AGAVE_HEAD_FRAMES,
    CORN_ICON,
    *CORN_BODY_FRAMES,
    *CORN_HEAD_FRAMES,
    *CORN_FLASH_FRAMES,
    VEGETATION_STAKE_ASSET,
    VEGETATION_STAKE_GLOW,
)


def _relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def _load_rgba(path: Path) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    with Image.open(path) as source:
        return source.convert("RGBA")


def _bbox_size(bbox: tuple[int, int, int, int] | None) -> tuple[int, int]:
    if bbox is None:
        return (0, 0)
    left, top, right, bottom = bbox
    return (right - left, bottom - top)


def _audit_png(path: Path) -> dict[str, Any]:
    image = _load_rgba(path)
    pixels = tuple(image.getdata())
    visible_colors = {pixel[:3] for pixel in pixels if pixel[3] == 255}
    alpha_values = {pixel[3] for pixel in pixels}
    bbox = image.getchannel("A").getbbox()
    world_bounds = None
    if bbox is not None:
        world_bounds = [
            round((bbox[0] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
            round((bbox[1] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
            round((bbox[2] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
            round((bbox[3] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
        ]
    if path in AGAVE_HEAD_FRAMES:
        audit_pivot = AGAVE_HEAD_PIVOT_IN_TEXTURE
    elif path in CORN_HEAD_FRAMES:
        audit_pivot = CORN_HEAD_PIVOT_IN_TEXTURE
    elif path in CORN_FLASH_FRAMES:
        audit_pivot = CORN_FLASH_ANCHOR
    else:
        audit_pivot = CANVAS_CENTER
    maximum_radius_from_audit_pivot = max(
        (
            math.hypot((x + 0.5) - audit_pivot[0], (y + 0.5) - audit_pivot[1])
            for y in range(image.height)
            for x in range(image.width)
            if image.getpixel((x, y))[3] == 255
        ),
        default=0.0,
    )
    import_text = path.with_suffix(path.suffix + ".import").read_text(encoding="utf-8")
    import_contract = {
        "lossless_compression": "compress/mode=0" in import_text,
        "mipmaps_disabled": "mipmaps/generate=false" in import_text,
        "premultiply_disabled": "process/premult_alpha=false" in import_text,
        "unlimited_source_size": "process/size_limit=0" in import_text,
    }
    return {
        "path": _relative(path),
        "size": list(image.size),
        "subject_bbox": list(bbox) if bbox is not None else None,
        "subject_size": list(_bbox_size(bbox)),
        "world_bounds_at_scale_0_5": world_bounds,
        "visible_color_count": len(visible_colors),
        "audit_pivot": list(audit_pivot),
        "maximum_radius_from_audit_pivot": round(maximum_radius_from_audit_pivot, 3),
        "binary_alpha": alpha_values.issubset({0, 255}),
        "transparent_rgb_clean": all(
            alpha != 0 or (red == 0 and green == 0 and blue == 0)
            for red, green, blue, alpha in pixels
        ),
        "non_empty": bbox is not None,
        "import_contract": import_contract,
    }


def _footpoint(audit: dict[str, Any]) -> tuple[float, float]:
    bbox = audit["subject_bbox"]
    if bbox is None:
        return (0.0, 0.0)
    left, _top, right, bottom = bbox
    return ((left + right - 1) * 0.5, float(bottom - 1))


def _agave_default_recomposition_metrics() -> dict[str, Any]:
    body = _load_rgba(AGAVE_BODY_FRAMES[0])
    head = _load_rgba(AGAVE_HEAD_FRAMES[0])
    recomposed = body.copy()
    recomposed.alpha_composite(head, AGAVE_HEAD_OFFSET)
    icon = _load_rgba(AGAVE_ICON)
    runtime_bbox = recomposed.getchannel("A").getbbox()
    icon_bbox = icon.getchannel("A").getbbox()
    edge_error_world = math.inf
    footpoint_error_world = math.inf
    if runtime_bbox is not None and icon_bbox is not None:
        edge_error_world = max(
            abs(runtime_edge - icon_edge)
            for runtime_edge, icon_edge in zip(runtime_bbox, icon_bbox)
        ) * WORLD_SCALE
        runtime_footpoint = (
            (runtime_bbox[0] + runtime_bbox[2] - 1) * 0.5,
            float(runtime_bbox[3] - 1),
        )
        icon_footpoint = (
            (icon_bbox[0] + icon_bbox[2] - 1) * 0.5,
            float(icon_bbox[3] - 1),
        )
        footpoint_error_world = math.dist(runtime_footpoint, icon_footpoint) * WORLD_SCALE
    return {
        "pixel_diff_count": sum(
        recomposed_pixel != icon_pixel
        for recomposed_pixel, icon_pixel in zip(recomposed.getdata(), icon.getdata())
        ),
        "runtime_subject_bbox": list(runtime_bbox) if runtime_bbox is not None else None,
        "icon_subject_bbox": list(icon_bbox) if icon_bbox is not None else None,
        "maximum_edge_error_world": round(edge_error_world, 3),
        "footpoint_error_world": round(footpoint_error_world, 3),
    }


def _pixel_difference_positions(
    first: Image.Image,
    second: Image.Image,
) -> set[tuple[int, int]]:
    if first.size != second.size:
        raise RuntimeError("Cannot compare plant assets with different sizes")
    first_pixels = first.convert("RGBA").load()
    second_pixels = second.convert("RGBA").load()
    return {
        (x, y)
        for y in range(first.height)
        for x in range(first.width)
        if first_pixels[x, y] != second_pixels[x, y]
    }


def _alpha_points(image: Image.Image) -> set[tuple[int, int]]:
    pixels = image.convert("RGBA").load()
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if pixels[x, y][3] > 0
    }


def _corn_family_metrics() -> dict[str, Any]:
    body_frames = [_load_rgba(path) for path in CORN_BODY_FRAMES]
    head_frames = [_load_rgba(path) for path in CORN_HEAD_FRAMES]
    flash_frames = [_load_rgba(path) for path in CORN_FLASH_FRAMES]
    icon = _load_rgba(CORN_ICON)

    body_reference = body_frames[0]
    head_reference = head_frames[0]
    body_reference_alpha = _alpha_points(body_reference)
    head_reference_alpha = _alpha_points(head_reference)
    body_differences = [
        len(_pixel_difference_positions(body_reference, frame))
        for frame in body_frames
    ]
    head_differences = [
        len(_pixel_difference_positions(head_reference, frame))
        for frame in head_frames
    ]
    mutable_left, mutable_top, mutable_right, mutable_bottom = CORN_SPIN_MUTABLE_BBOX
    changed_outside_mutable = [
        len(
            {
                point
                for point in _pixel_difference_positions(head_reference, frame)
                if not (
                    mutable_left <= point[0] < mutable_right
                    and mutable_top <= point[1] < mutable_bottom
                )
            }
        )
        for frame in head_frames
    ]

    recomposed = body_reference.copy()
    recomposed.alpha_composite(head_reference, CORN_HEAD_OFFSET)
    icon_recomposition_diff = len(_pixel_difference_positions(recomposed, icon))
    family_colors = {
        (red, green, blue)
        for image in (*body_frames, *head_frames, *flash_frames, icon)
        for red, green, blue, alpha in image.getdata()
        if alpha > 0
    }
    return {
        "body_alpha_silhouette_drift_pixels": [
            len(_alpha_points(frame) ^ body_reference_alpha)
            for frame in body_frames
        ],
        "body_pixel_differences_from_idle_0": body_differences,
        "head_alpha_silhouette_drift_pixels": [
            len(_alpha_points(frame) ^ head_reference_alpha)
            for frame in head_frames
        ],
        "head_pixel_differences_from_idle_0": head_differences,
        "head_changed_pixels_outside_mutable_bbox": changed_outside_mutable,
        "family_visible_color_count": len(family_colors),
        "muzzle_visible_in_all_head_frames": all(
            frame.getpixel(CORN_MUZZLE_IN_HEAD_TEXTURE)[3] == 255
            for frame in head_frames
        ),
        "flash_anchor_visible_in_all_frames": all(
            frame.getpixel(CORN_FLASH_ANCHOR)[3] == 255
            for frame in flash_frames
        ),
        "icon_recomposition_diff_pixels": icon_recomposition_diff,
    }


def _collect_failures(report: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    audits = {entry["path"]: entry for entry in report["assets"]}
    for path in BUILDING_ASSETS:
        audit = audits[_relative(path)]
        if audit["size"] != [SOURCE_SIDE, SOURCE_SIDE]:
            failures.append(f"{audit['path']} must be exactly 64x64")
        if not audit["non_empty"]:
            failures.append(f"{audit['path']} must contain visible pixels")
        world_bounds = audit["world_bounds_at_scale_0_5"]
        if world_bounds is not None and not (
            world_bounds[0] >= -WORLD_FOOTPRINT_SIDE * 0.5
            and world_bounds[1] >= -WORLD_FOOTPRINT_SIDE * 0.5
            and world_bounds[2] <= WORLD_FOOTPRINT_SIDE * 0.5
            and world_bounds[3] <= WORLD_FOOTPRINT_SIDE * 0.5
        ):
            failures.append(
                f"{audit['path']} escapes the centered 32x32 world footprint"
            )
        if not audit["binary_alpha"]:
            failures.append(f"{audit['path']} contains non-binary alpha")
        if not audit["transparent_rgb_clean"]:
            failures.append(f"{audit['path']} contains RGB data in transparent texels")
        if audit["visible_color_count"] > MAX_VISIBLE_COLORS:
            failures.append(
                f"{audit['path']} uses {audit['visible_color_count']} visible colors; "
                f"maximum is {MAX_VISIBLE_COLORS}"
            )
        failed_import_keys = [
            key for key, passed in audit["import_contract"].items() if not passed
        ]
        if failed_import_keys:
            failures.append(
                f"{audit['path']} violates import contract: {', '.join(failed_import_keys)}"
            )

    warehouse = audits[_relative(WAREHOUSE_ASSET)]
    warehouse_width, warehouse_height = warehouse["subject_size"]
    if (
        warehouse_width > WAREHOUSE_MAX_SUBJECT_SIZE[0]
        or warehouse_height > WAREHOUSE_MAX_SUBJECT_SIZE[1]
    ):
        failures.append(
            "oak warehouse subject must fit within 60x62 source pixels; "
            f"got {warehouse_width}x{warehouse_height}"
        )

    for path in (VEGETATION_STAKE_ASSET, VEGETATION_STAKE_GLOW):
        stake_audit = audits[_relative(path)]
        stake_width, stake_height = stake_audit["subject_size"]
        if (
            stake_width > VEGETATION_STAKE_MAX_SUBJECT_SIZE[0]
            or stake_height > VEGETATION_STAKE_MAX_SUBJECT_SIZE[1]
        ):
            failures.append(
                f"{stake_audit['path']} must fit within 22x23 source pixels; "
                f"got {stake_width}x{stake_height}"
            )
        if stake_audit["visible_color_count"] > VEGETATION_STAKE_MAX_VISIBLE_COLORS:
            failures.append(
                f"{stake_audit['path']} exceeds the Vegetation Stake 32-color limit"
            )

    stake_audit = audits[_relative(VEGETATION_STAKE_ASSET)]
    if tuple(stake_audit["subject_size"]) != VEGETATION_STAKE_MAX_SUBJECT_SIZE:
        failures.append(
            "Vegetation Stake body must remain exactly 22x23 source pixels; "
            f"got {stake_audit['subject_size'][0]}x{stake_audit['subject_size'][1]}"
        )

    stake = _load_rgba(VEGETATION_STAKE_ASSET)
    glow = _load_rgba(VEGETATION_STAKE_GLOW)
    if any(
        glow_pixel[3] > 0 and stake_pixel[3] == 0
        for stake_pixel, glow_pixel in zip(stake.getdata(), glow.getdata())
    ):
        failures.append("Vegetation Stake glow mask must be a strict subset of its sprite")

    body_audits = [audits[_relative(path)] for path in AGAVE_BODY_FRAMES]
    body_footpoints = [_footpoint(audit) for audit in body_audits]
    if body_footpoints:
        reference_x, reference_y = body_footpoints[0]
        for audit, (foot_x, foot_y) in zip(body_audits[1:], body_footpoints[1:]):
            if abs(foot_x - reference_x) > 1.0 or abs(foot_y - reference_y) > 1.0:
                failures.append(
                    f"{audit['path']} footpoint drifts more than one source pixel "
                    f"from ({reference_x}, {reference_y}) to ({foot_x}, {foot_y})"
                )

    for path in AGAVE_HEAD_FRAMES:
        audit = audits[_relative(path)]
        if (
            audit["maximum_radius_from_audit_pivot"]
            > AGAVE_HEAD_MAX_PIVOT_RADIUS
        ):
            failures.append(
                f"{_relative(path)} exceeds the "
                f"{AGAVE_HEAD_MAX_PIVOT_RADIUS}px pixel-center radius "
                "around the shared rear-barrel 36,38 pivot"
            )

    alignment = report["agave_default_preview_alignment"]
    if (
        alignment["maximum_edge_error_world"] > PREVIEW_ALIGNMENT_TOLERANCE_WORLD
        or alignment["footpoint_error_world"] > PREVIEW_ALIGNMENT_TOLERANCE_WORLD
    ):
        failures.append(
            "Agave runtime body/head composition and placement icon must keep "
            f"their world bounds and footpoint within {PREVIEW_ALIGNMENT_TOLERANCE_WORLD}px"
        )

    corn_paths = (
        CORN_ICON,
        *CORN_BODY_FRAMES,
        *CORN_HEAD_FRAMES,
        *CORN_FLASH_FRAMES,
    )
    for path in corn_paths:
        audit = audits[_relative(path)]
        width, height = audit["subject_size"]
        if width > CORN_MAX_SUBJECT_SIZE[0] or height > CORN_MAX_SUBJECT_SIZE[1]:
            failures.append(
                f"{audit['path']} must fit within {CORN_MAX_SUBJECT_SIZE[0]}x"
                f"{CORN_MAX_SUBJECT_SIZE[1]} source pixels; got {width}x{height}"
            )
        if audit["visible_color_count"] > CORN_MAX_VISIBLE_COLORS:
            failures.append(
                f"{audit['path']} exceeds the Corn Machine Gun "
                f"{CORN_MAX_VISIBLE_COLORS}-color limit"
            )

    corn_body_audits = [audits[_relative(path)] for path in CORN_BODY_FRAMES]
    corn_body_footpoints = [_footpoint(audit) for audit in corn_body_audits]
    if any(point != CORN_BODY_FOOT for point in corn_body_footpoints):
        failures.append(
            "Every Corn Machine Gun body frame must retain exact foot (32,62); "
            f"got {corn_body_footpoints}"
        )

    corn_metrics = report["corn_family_metrics"]
    if corn_metrics["family_visible_color_count"] > CORN_MAX_VISIBLE_COLORS:
        failures.append(
            "The Corn Machine Gun family must share no more than 48 visible colors; "
            f"got {corn_metrics['family_visible_color_count']}"
        )
    if corn_metrics["body_alpha_silhouette_drift_pixels"] != [0, 0, 0, 0]:
        failures.append("Corn body idle frames must have byte-identical alpha masks")
    if corn_metrics["body_pixel_differences_from_idle_0"] != [0, 1, 1, 1]:
        failures.append(
            "Corn body idle frames 1-3 must each change exactly one internal pixel"
        )
    if corn_metrics["head_alpha_silhouette_drift_pixels"] != [0, 0, 0, 0, 0]:
        failures.append("Corn turret idle/spin frames must have identical alpha masks")
    head_differences = corn_metrics["head_pixel_differences_from_idle_0"]
    if head_differences[0] != 0 or head_differences[1] != 0 or any(
        difference <= 0 for difference in head_differences[2:]
    ):
        failures.append(
            "Corn turret spin 0 must equal idle while spin phases 1-3 must be distinct"
        )
    if any(corn_metrics["head_changed_pixels_outside_mutable_bbox"]):
        failures.append(
            "Corn turret spin phases may not change the outer shell or installation point"
        )
    if not corn_metrics["muzzle_visible_in_all_head_frames"]:
        failures.append(
            f"Corn gameplay muzzle {CORN_MUZZLE_IN_HEAD_TEXTURE} must remain on every head frame"
        )
    if not corn_metrics["flash_anchor_visible_in_all_frames"]:
        failures.append(
            f"Corn flash frames must share visible anchor {CORN_FLASH_ANCHOR}"
        )
    if corn_metrics["icon_recomposition_diff_pixels"] != 0:
        failures.append(
            "Corn body/head pivot recomposition must match its placement icon exactly"
        )

    return failures


def build_report() -> dict[str, Any]:
    asset_audits = [_audit_png(path) for path in BUILDING_ASSETS]
    audits = {entry["path"]: entry for entry in asset_audits}
    body_footpoints = {
        _relative(path): list(_footpoint(audits[_relative(path)]))
        for path in AGAVE_BODY_FRAMES
    }
    return {
        "contract": {
            "source_canvas": [SOURCE_SIDE, SOURCE_SIDE],
            "static_world_scale": WORLD_SCALE,
            "world_footprint": [WORLD_FOOTPRINT_SIDE, WORLD_FOOTPRINT_SIDE],
            "max_visible_colors": MAX_VISIBLE_COLORS,
            "warehouse_max_subject": list(WAREHOUSE_MAX_SUBJECT_SIZE),
            "vegetation_stake_max_subject": list(VEGETATION_STAKE_MAX_SUBJECT_SIZE),
            "vegetation_stake_max_visible_colors": VEGETATION_STAKE_MAX_VISIBLE_COLORS,
            "agave_shared_head_pivot": list(AGAVE_HEAD_PIVOT_IN_TEXTURE),
            "agave_head_max_pivot_radius": AGAVE_HEAD_MAX_PIVOT_RADIUS,
            "agave_max_body_footpoint_drift": 1.0,
            "corn_max_subject": list(CORN_MAX_SUBJECT_SIZE),
            "corn_max_visible_colors": CORN_MAX_VISIBLE_COLORS,
            "corn_body_foot": list(CORN_BODY_FOOT),
            "corn_head_offset": list(CORN_HEAD_OFFSET),
            "corn_head_pivot": list(CORN_HEAD_PIVOT_IN_TEXTURE),
            "corn_muzzle": list(CORN_MUZZLE_IN_HEAD_TEXTURE),
            "corn_flash_anchor": list(CORN_FLASH_ANCHOR),
            "corn_spin_mutable_bbox_exclusive": list(CORN_SPIN_MUTABLE_BBOX),
            "preview_alignment_tolerance_world": PREVIEW_ALIGNMENT_TOLERANCE_WORLD,
        },
        "assets": asset_audits,
        "agave_body_footpoints": body_footpoints,
        "agave_default_preview_alignment": _agave_default_recomposition_metrics(),
        "corn_body_footpoints": {
            _relative(path): list(_footpoint(audits[_relative(path)]))
            for path in CORN_BODY_FRAMES
        },
        "corn_family_metrics": _corn_family_metrics(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        type=Path,
        help="Optionally write the full JSON audit report to this path.",
    )
    args = parser.parse_args()

    report = build_report()
    failures = _collect_failures(report)
    report["passed"] = not failures
    report["failures"] = failures
    if args.report is not None:
        report_path = args.report
        if not report_path.is_absolute():
            report_path = ROOT / report_path
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}")
        raise SystemExit(1)
    print("PLANT_DEFENSE_VISUAL_ASSET_AUDIT_OK")


if __name__ == "__main__":
    main()
