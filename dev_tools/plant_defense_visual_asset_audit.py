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
BAMBOO_BUILDING_MAX_VISIBLE_COLORS = 20
BAMBOO_BUILDING_UNION_MAX_VISIBLE_COLORS = 20
BAMBOO_EXPLOSION_MAX_VISIBLE_COLORS = 12
BAMBOO_IDLE_CHARGE_SUBJECT_BBOX = (4, 4, 59, 62)
BAMBOO_FIRE_SUBJECT_BBOXES = (
    (4, 2, 60, 62),
    (4, 2, 62, 62),
    (4, 2, 62, 62),
    (4, 2, 62, 62),
)
BAMBOO_UPPER_STORAGE_MUTABLE_RECT = (15, 15, 26, 27)
BAMBOO_MUZZLE_MUTABLE_RECT = (31, 3, 54, 20)
BAMBOO_FIRE_EFFECT_MUTABLE_RECT = (31, 0, 64, 22)
BAMBOO_CHARGE_MUTABLE_RECTS = (
    BAMBOO_UPPER_STORAGE_MUTABLE_RECT,
    BAMBOO_MUZZLE_MUTABLE_RECT,
)
BAMBOO_FIRE_MUTABLE_RECTS = (
    BAMBOO_UPPER_STORAGE_MUTABLE_RECT,
    BAMBOO_FIRE_EFFECT_MUTABLE_RECT,
)
BAMBOO_UPPER_STORAGE_LOADED_MARKERS = (
    ((20, 17), (7, 25, 9, 255)),
    ((18, 20), (91, 169, 45, 255)),
    ((20, 21), (126, 92, 28, 255)),
)
BAMBOO_UPPER_STORAGE_EMPTY_MARKERS = (
    ((20, 17), (0, 0, 0, 0)),
    ((18, 20), (241, 203, 99, 255)),
    ((20, 21), (66, 48, 15, 255)),
)
BAMBOO_LOWER_DECORATIVE_BOMB_RECT = (11, 26, 18, 32)
BAMBOO_APPROVED_ROPE_TAIL_PIXELS = (
    ((41, 44), (241, 203, 99, 255)),
    ((42, 44), (241, 203, 99, 255)),
    ((41, 45), (190, 151, 48, 255)),
    ((42, 45), (190, 151, 48, 255)),
    ((43, 45), (241, 203, 99, 255)),
    ((44, 45), (190, 151, 48, 255)),
    ((43, 46), (66, 48, 15, 255)),
    ((44, 46), (66, 48, 15, 255)),
)
BAMBOO_STATUS_LIGHT_REGION = (28, 39, 36, 47)
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
WATER_COLLECTOR_ASSET = TEXTURE_ROOT / "water_collector/water_collector.png"
RESEARCH_CENTER_ASSET = TEXTURE_ROOT / "research_center/research_center.png"
BAMBOO_SOURCE_ANCHOR = (
    ROOT
    / "dev_assets/source_images/plant_defense/bamboo_mortar"
    / "bamboo_mortar_anchor_alpha.png"
)
BAMBOO_IDLE = TEXTURE_ROOT / "bamboo_mortar/idle.png"
BAMBOO_CHARGE_FRAMES = tuple(
    TEXTURE_ROOT / f"bamboo_mortar/charge_{index}.png"
    for index in range(8)
)
BAMBOO_FIRE_FRAMES = tuple(
    TEXTURE_ROOT / f"bamboo_mortar/fire_{index}.png"
    for index in range(4)
)
BAMBOO_EXPLOSION_FRAMES = tuple(
    TEXTURE_ROOT / f"bamboo_mortar/explosion_{index}.png"
    for index in range(8)
)
BAMBOO_OBSOLETE_GLOW_MASK = TEXTURE_ROOT / "bamboo_mortar/glow_mask.png"
BAMBOO_SHELL = TEXTURE_ROOT / "bamboo_mortar/shell.png"
BAMBOO_BUILDING_FRAMES = (
    BAMBOO_IDLE,
    *BAMBOO_CHARGE_FRAMES,
    *BAMBOO_FIRE_FRAMES,
)
BAMBOO_FRAME_ASSETS = (
    *BAMBOO_BUILDING_FRAMES,
    *BAMBOO_EXPLOSION_FRAMES,
)
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
    WATER_COLLECTOR_ASSET,
    RESEARCH_CENTER_ASSET,
    *BAMBOO_FRAME_ASSETS,
)
AUDITED_ASSETS = (*BUILDING_ASSETS, BAMBOO_SHELL)


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


def _inside_any_rect(
    point: tuple[int, int],
    rects: tuple[tuple[int, int, int, int], ...],
) -> bool:
    x, y = point
    return any(
        left <= x < right and top <= y < bottom
        for left, top, right, bottom in rects
    )


def _visible_color_set(image: Image.Image) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for red, green, blue, alpha in image.convert("RGBA").getdata()
        if alpha == 255
    }


def _bamboo_mortar_metrics() -> dict[str, Any]:
    anchor = _load_rgba(BAMBOO_SOURCE_ANCHOR)
    idle = _load_rgba(BAMBOO_IDLE)
    charge_frames = [_load_rgba(path) for path in BAMBOO_CHARGE_FRAMES]
    fire_frames = [_load_rgba(path) for path in BAMBOO_FIRE_FRAMES]
    building_frames = [idle, *charge_frames, *fire_frames]
    explosion_frames = [_load_rgba(path) for path in BAMBOO_EXPLOSION_FRAMES]
    shell = _load_rgba(BAMBOO_SHELL)
    charge_differences = [
        _pixel_difference_positions(anchor, frame)
        for frame in charge_frames
    ]
    fire_differences = [
        _pixel_difference_positions(anchor, frame)
        for frame in fire_frames
    ]
    charge_immutable_change_counts = [
        sum(
            not _inside_any_rect(point, BAMBOO_CHARGE_MUTABLE_RECTS)
            for point in differences
        )
        for differences in charge_differences
    ]
    fire_immutable_change_counts = [
        sum(
            not _inside_any_rect(point, BAMBOO_FIRE_MUTABLE_RECTS)
            for point in differences
        )
        for differences in fire_differences
    ]
    charge_storage_change_counts = [
        sum(
            _inside_any_rect(
                point,
                (BAMBOO_UPPER_STORAGE_MUTABLE_RECT,),
            )
            for point in differences
        )
        for differences in charge_differences
    ]
    charge_muzzle_change_counts = [
        sum(
            _inside_any_rect(point, (BAMBOO_MUZZLE_MUTABLE_RECT,))
            for point in differences
        )
        for differences in charge_differences
    ]
    fire_storage_change_counts = [
        sum(
            _inside_any_rect(
                point,
                (BAMBOO_UPPER_STORAGE_MUTABLE_RECT,),
            )
            for point in differences
        )
        for differences in fire_differences
    ]
    fire_effect_change_counts = [
        sum(
            _inside_any_rect(
                point,
                (BAMBOO_FIRE_EFFECT_MUTABLE_RECT,),
            )
            for point in differences
        )
        for differences in fire_differences
    ]
    status_region_static = all(
        all(
            frame.getpixel((x, y)) == idle.getpixel((x, y))
            for y in range(
                BAMBOO_STATUS_LIGHT_REGION[1],
                BAMBOO_STATUS_LIGHT_REGION[3],
            )
            for x in range(
                BAMBOO_STATUS_LIGHT_REGION[0],
                BAMBOO_STATUS_LIGHT_REGION[2],
            )
        )
        for frame in (*charge_frames, *fire_frames)
    )
    lower_bomb_preserved = all(
        all(
            frame.getpixel(point) == idle.getpixel(point)
            for point in (
                (x, y)
                for y in range(
                    BAMBOO_LOWER_DECORATIVE_BOMB_RECT[1],
                    BAMBOO_LOWER_DECORATIVE_BOMB_RECT[3],
                )
                for x in range(
                    BAMBOO_LOWER_DECORATIVE_BOMB_RECT[0],
                    BAMBOO_LOWER_DECORATIVE_BOMB_RECT[2],
                )
            )
        )
        for frame in (*charge_frames, *fire_frames)
    )
    rope_tail_preserved = all(
        all(
            frame.getpixel(point) == color
            for point, color in BAMBOO_APPROVED_ROPE_TAIL_PIXELS
        )
        for frame in building_frames
    )
    return {
        "anchor_size": list(anchor.size),
        "anchor_subject_bbox": list(
            anchor.getchannel("A").getbbox() or ()
        ),
        "building_subject_bboxes": [
            list(frame.getchannel("A").getbbox() or ())
            for frame in building_frames
        ],
        "idle_matches_approved_anchor": (
            len(_pixel_difference_positions(anchor, idle)) == 0
        ),
        "building_union_visible_color_count": len(
            set().union(
                *(_visible_color_set(frame) for frame in building_frames)
            )
        ),
        "explosion_union_visible_color_count": len(
            set().union(
                *(_visible_color_set(frame) for frame in explosion_frames)
            )
        ),
        "charge_immutable_change_counts": charge_immutable_change_counts,
        "fire_immutable_change_counts": fire_immutable_change_counts,
        "charge_storage_change_counts": charge_storage_change_counts,
        "charge_muzzle_change_counts": charge_muzzle_change_counts,
        "fire_storage_change_counts": fire_storage_change_counts,
        "fire_effect_change_counts": fire_effect_change_counts,
        "charge_unique_frame_count": len(
            {frame.tobytes() for frame in charge_frames}
        ),
        "fire_unique_frame_count": len(
            {frame.tobytes() for frame in fire_frames}
        ),
        "upper_storage_loaded_marker_matches": sum(
            idle.getpixel(point) == color
            for point, color in BAMBOO_UPPER_STORAGE_LOADED_MARKERS
        ),
        "upper_storage_empty_marker_matches": [
            sum(
                frame.getpixel(point) == color
                for point, color in BAMBOO_UPPER_STORAGE_EMPTY_MARKERS
            )
            for frame in (*charge_frames, *fire_frames)
        ],
        "lower_decorative_bomb_preserved": lower_bomb_preserved,
        "approved_short_rope_tail_pixel_count": len(
            BAMBOO_APPROVED_ROPE_TAIL_PIXELS
        ),
        "approved_short_rope_tail_preserved": rope_tail_preserved,
        "status_light_region_static": status_region_static,
        "status_light_bitmap_absent_from_contract": (
            not BAMBOO_OBSOLETE_GLOW_MASK.exists()
        ),
        "shell_size": list(shell.size),
        "shell_visible_color_count": len(_visible_color_set(shell)),
        "shell_binary_alpha": {
            pixel[3] for pixel in shell.getdata()
        }.issubset({0, 255}),
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

    failures.extend(_collect_bamboo_failures(report))
    return failures


def _collect_bamboo_failures(report: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    audits = {entry["path"]: entry for entry in report["assets"]}
    for path in BAMBOO_FRAME_ASSETS:
        audit = audits[_relative(path)]
        if audit["size"] != [SOURCE_SIDE, SOURCE_SIDE]:
            failures.append(f"{audit['path']} must be exactly 64x64")
        if not audit["non_empty"]:
            failures.append(f"{audit['path']} must contain visible pixels")
        if not audit["binary_alpha"]:
            failures.append(f"{audit['path']} must use strict binary alpha")
        if not audit["transparent_rgb_clean"]:
            failures.append(
                f"{audit['path']} contains RGB data in transparent texels"
            )
        failed_import_keys = [
            key for key, passed in audit["import_contract"].items() if not passed
        ]
        if failed_import_keys:
            failures.append(
                f"{audit['path']} violates import contract: "
                f"{', '.join(failed_import_keys)}"
            )
    for path in (BAMBOO_IDLE, *BAMBOO_CHARGE_FRAMES):
        audit = audits[_relative(path)]
        if (
            tuple(audit["subject_bbox"] or ())
            != BAMBOO_IDLE_CHARGE_SUBJECT_BBOX
        ):
            failures.append(
                f"{audit['path']} must retain Bamboo Mortar body bbox "
                f"{BAMBOO_IDLE_CHARGE_SUBJECT_BBOX}; "
                f"got {audit['subject_bbox']}"
            )
    for path, expected_bbox in zip(
        BAMBOO_FIRE_FRAMES,
        BAMBOO_FIRE_SUBJECT_BBOXES,
    ):
        audit = audits[_relative(path)]
        if tuple(audit["subject_bbox"] or ()) != expected_bbox:
            failures.append(
                f"{audit['path']} must retain Bamboo Mortar fire bbox "
                f"{expected_bbox}; got {audit['subject_bbox']}"
            )
    for path in BAMBOO_BUILDING_FRAMES:
        audit = audits[_relative(path)]
        if audit["visible_color_count"] > BAMBOO_BUILDING_MAX_VISIBLE_COLORS:
            failures.append(
                f"{audit['path']} exceeds the Bamboo Mortar "
                f"{BAMBOO_BUILDING_MAX_VISIBLE_COLORS}-color limit"
            )
    for path in BAMBOO_EXPLOSION_FRAMES:
        audit = audits[_relative(path)]
        if audit["visible_color_count"] > BAMBOO_EXPLOSION_MAX_VISIBLE_COLORS:
            failures.append(
                f"{audit['path']} exceeds the Bamboo Mortar explosion "
                f"{BAMBOO_EXPLOSION_MAX_VISIBLE_COLORS}-color limit"
            )

    bamboo_metrics = report["bamboo_mortar_metrics"]
    if bamboo_metrics["anchor_size"] != [SOURCE_SIDE, SOURCE_SIDE]:
        failures.append("Bamboo Mortar approved anchor must remain exactly 64x64")
    if (
        tuple(bamboo_metrics["anchor_subject_bbox"])
        != BAMBOO_IDLE_CHARGE_SUBJECT_BBOX
    ):
        failures.append(
            "Bamboo Mortar approved anchor, idle frame and charge frames "
            "must share the same stable subject bbox"
        )
    if (
        bamboo_metrics["building_union_visible_color_count"]
        > BAMBOO_BUILDING_UNION_MAX_VISIBLE_COLORS
    ):
        failures.append(
            "The complete Bamboo Mortar building family must share no more "
            f"than {BAMBOO_BUILDING_UNION_MAX_VISIBLE_COLORS} visible colors"
        )
    if bamboo_metrics["explosion_union_visible_color_count"] > 12:
        failures.append(
            "The complete Bamboo Mortar explosion family must share no more "
            "than 12 visible colors"
        )
    if not bamboo_metrics["idle_matches_approved_anchor"]:
        failures.append(
            "Bamboo Mortar idle frame must exactly match its approved anchor"
        )
    if any(bamboo_metrics["charge_immutable_change_counts"]):
        failures.append(
            "Bamboo Mortar charge frames changed approved-anchor pixels "
            "outside upper storage and muzzle regions"
        )
    if any(bamboo_metrics["fire_immutable_change_counts"]):
        failures.append(
            "Bamboo Mortar fire frames changed approved-anchor pixels "
            "outside upper storage and muzzle-effect regions"
        )
    if bamboo_metrics["charge_storage_change_counts"] != [62] * 8:
        failures.append(
            "Every Bamboo Mortar charge frame must replace exactly the same "
            "62 upper-storage pixels"
        )
    if bamboo_metrics["fire_storage_change_counts"] != [62] * 4:
        failures.append(
            "Every Bamboo Mortar fire frame must replace exactly the same "
            "62 upper-storage pixels"
        )
    if not all(
        later > earlier
        for earlier, later in zip(
            bamboo_metrics["charge_muzzle_change_counts"],
            bamboo_metrics["charge_muzzle_change_counts"][1:],
        )
    ):
        failures.append(
            "Bamboo Mortar charge frames must progressively heat more "
            "pixels inside the native-64 muzzle region"
        )
    if any(
        change_count <= 0
        for change_count in bamboo_metrics["fire_effect_change_counts"]
    ):
        failures.append(
            "Every Bamboo Mortar fire frame must visibly change the "
            "native-64 muzzle-effect region"
        )
    if bamboo_metrics["charge_unique_frame_count"] != 8:
        failures.append("All eight Bamboo Mortar charge frames must be unique")
    if bamboo_metrics["fire_unique_frame_count"] != 4:
        failures.append("All four Bamboo Mortar fire frames must be unique")
    if (
        bamboo_metrics["upper_storage_loaded_marker_matches"]
        != len(BAMBOO_UPPER_STORAGE_LOADED_MARKERS)
    ):
        failures.append(
            "Bamboo Mortar idle frame must visibly retain the upper decorative bomb"
        )
    if any(
        marker_matches != len(BAMBOO_UPPER_STORAGE_EMPTY_MARKERS)
        for marker_matches in bamboo_metrics[
            "upper_storage_empty_marker_matches"
        ]
    ):
        failures.append(
            "Every Bamboo Mortar charge/fire frame must show the upper storage "
            "tube empty"
        )
    if not bamboo_metrics["lower_decorative_bomb_preserved"]:
        failures.append(
            "Every Bamboo Mortar charge/fire frame must preserve the lower "
            "decorative bomb"
        )
    if (
        bamboo_metrics["approved_short_rope_tail_pixel_count"] != 8
        or not bamboo_metrics["approved_short_rope_tail_preserved"]
    ):
        failures.append(
            "Every Bamboo Mortar body frame must retain the approved "
            "eight-pixel short rope tail"
        )
    if not bamboo_metrics["status_light_region_static"]:
        failures.append(
            "Bamboo Mortar body frames must not bake animation into the "
            "Godot-rendered status-light region"
        )
    if not bamboo_metrics["status_light_bitmap_absent_from_contract"]:
        failures.append(
            "Bamboo Mortar status light must not retain a bitmap mask; "
            "the authored square Godot node owns this visual"
        )
    if bamboo_metrics["shell_size"][0] > 12 or bamboo_metrics["shell_size"][1] > 12:
        failures.append("Bamboo Mortar shell must fit within a native 12x12 canvas")
    if (
        not bamboo_metrics["shell_binary_alpha"]
        or bamboo_metrics["shell_visible_color_count"] > 10
    ):
        failures.append(
            "Bamboo Mortar shell must use binary alpha and no more than 10 colors"
        )
    for path, expected_size in ((BAMBOO_SHELL, [12, 12]),):
        audit = audits[_relative(path)]
        if audit["size"] != expected_size:
            failures.append(
                f"{audit['path']} must be exactly "
                f"{expected_size[0]}x{expected_size[1]}"
            )
        if not audit["non_empty"] or not audit["transparent_rgb_clean"]:
            failures.append(
                f"{audit['path']} must be non-empty with clean transparent RGB"
            )
        if not audit["binary_alpha"]:
            failures.append(f"{audit['path']} must use strict binary alpha")
        failed_import_keys = [
            key for key, passed in audit["import_contract"].items() if not passed
        ]
        if failed_import_keys:
            failures.append(
                f"{audit['path']} violates import contract: "
                f"{', '.join(failed_import_keys)}"
            )

    return failures


def build_report() -> dict[str, Any]:
    asset_audits = [_audit_png(path) for path in AUDITED_ASSETS]
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
            "bamboo_building_max_visible_colors": (
                BAMBOO_BUILDING_MAX_VISIBLE_COLORS
            ),
            "bamboo_building_union_max_visible_colors": (
                BAMBOO_BUILDING_UNION_MAX_VISIBLE_COLORS
            ),
            "bamboo_explosion_max_visible_colors": (
                BAMBOO_EXPLOSION_MAX_VISIBLE_COLORS
            ),
            "bamboo_idle_charge_subject_bbox": list(
                BAMBOO_IDLE_CHARGE_SUBJECT_BBOX
            ),
            "bamboo_fire_subject_bboxes": [
                list(bbox) for bbox in BAMBOO_FIRE_SUBJECT_BBOXES
            ],
            "bamboo_upper_storage_mutable_rect_exclusive": list(
                BAMBOO_UPPER_STORAGE_MUTABLE_RECT
            ),
            "bamboo_muzzle_mutable_rect_exclusive": list(
                BAMBOO_MUZZLE_MUTABLE_RECT
            ),
            "bamboo_fire_effect_mutable_rect_exclusive": list(
                BAMBOO_FIRE_EFFECT_MUTABLE_RECT
            ),
            "bamboo_charge_mutable_rects_exclusive": [
                list(rect) for rect in BAMBOO_CHARGE_MUTABLE_RECTS
            ],
            "bamboo_fire_mutable_rects_exclusive": [
                list(rect) for rect in BAMBOO_FIRE_MUTABLE_RECTS
            ],
            "bamboo_status_light_region_exclusive": list(
                BAMBOO_STATUS_LIGHT_REGION
            ),
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
        "bamboo_mortar_metrics": _bamboo_mortar_metrics(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scope",
        choices=("all", "bamboo"),
        default="all",
        help="Audit every plant asset or only the Bamboo Mortar family.",
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="Optionally write the full JSON audit report to this path.",
    )
    args = parser.parse_args()

    report = build_report()
    failures = (
        _collect_bamboo_failures(report)
        if args.scope == "bamboo"
        else _collect_failures(report)
    )
    report["scope"] = args.scope
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
