#!/usr/bin/env python3
"""Derive audited 64px Agave Cannon assets from one selected composite master.

Imagegen supplies the volumetric identity once.  This processor separates the
green/olive plant body from the amber cannon, registers one shared pivot, then
creates deliberately small deterministic pixel-only idle/recoil variations.
The cannonball remains an existing gameplay asset and is never rewritten.
"""

from __future__ import annotations

import argparse
import colorsys
from collections import deque
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    MAX_VISIBLE_COLORS,
    TRANSPARENT,
    WORLD_FOOTPRINT_SIDE,
    WORLD_SCALE,
    alpha_bbox,
    apply_palette,
    audit_image,
    build_shared_palette,
    clean_transparency,
    foot_anchor,
    max_visible_radius,
    normalize_imagegen_subject,
    place_at,
    place_bottom_center,
    portable_path,
    source_audit,
    validation_failures,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/agave_cannon"
DEFAULT_INPUT = SOURCE_DIR / "agave_cannon_selected_imagegen_transparent.png"
OUTPUT_DIR = ROOT / "resources/texture/plant_defense/agave_cannon"
AUDIT_PATH = ROOT / "dev_tools/output/plant_defense/agave_asset_audit.json"

OUTPUT_FILES = {
    **{f"body_idle_{index}": f"agave_body_idle_{index}.png" for index in range(4)},
    "head_idle_0": "agave_cannon_idle_0.png",
    **{
        f"head_fire_{index}": f"agave_cannon_fire_{index}.png"
        for index in range(5)
    },
    "icon": "icon.png",
}

# The selected full sprite is fitted slightly inside the maximum canvas.  The
# audited muzzle coordinate retains the source's slight three-quarter art angle
# while the head rotates around the solid rear half of the barrel.
COMPOSITE_MAX_SUBJECT_SIZE = (56, 58)
BODY_MAX_SUBJECT_SIZE = (60, 62)
BODY_FOOT_TARGET = (32, 62)
ROOT_PIVOT = (32, 32)
CANNON_PIVOT_IN_BODY = (36, 32)
HEAD_TEXTURE_PIVOT = (36, 38)
VISUAL_MUZZLE_EDGE_IN_HEAD_TEXTURE = (54, 39)
SCENE_MUZZLE_MARKER_IN_HEAD_TEXTURE = (50, 39)
HEAD_MAX_RADIUS = 19.0


def _is_warm_seed(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return (
        alpha > 0
        and red >= 72
        and red > green * 1.07
        and green > blue * 1.10
        and red > blue * 1.45
    )


def _is_confident_leaf(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return alpha > 0 and green > red * 1.03 and green > blue * 1.08


def _find_head_mask(composite: Image.Image) -> tuple[set[tuple[int, int]], dict]:
    """Find the amber head while explicitly excluding green/olive leaf planes."""
    rgba = composite.convert("RGBA")
    pixels = rgba.load()
    seeds = {
        (x, y)
        for y in range(rgba.height)
        for x in range(rgba.width)
        if x >= ROOT_PIVOT[0] - 4
        and y <= ROOT_PIVOT[1] + 8
        and _is_warm_seed(pixels[x, y])
    }
    if len(seeds) < 8:
        raise RuntimeError(
            "Selected Agave master has no substantial separable amber cannon "
            "region; regenerate or choose the other concept candidate"
        )

    seed_left = min(x for x, _y in seeds)
    seed_top = min(y for _x, y in seeds)
    seed_right = max(x for x, _y in seeds) + 1
    seed_bottom = max(y for _x, y in seeds) + 1
    search_bbox = (
        max(ROOT_PIVOT[0] - 4, seed_left - 2),
        max(0, seed_top - 2),
        min(CANVAS_SIDE, seed_right + 2),
        min(CANVAS_SIDE, seed_bottom + 2),
    )
    candidates = {
        (x, y)
        for y in range(search_bbox[1], search_bbox[3])
        for x in range(search_bbox[0], search_bbox[2])
        if pixels[x, y][3] > 0 and not _is_confident_leaf(pixels[x, y])
    }

    # Grow from every warm material seed through adjacent outline/shadow pixels.
    # This retains the barrel's black rim and seam while refusing the green body.
    remaining = set(candidates)
    mask: set[tuple[int, int]] = set()
    queue: deque[tuple[int, int]] = deque()
    for seed in seeds:
        if seed in remaining:
            remaining.remove(seed)
            mask.add(seed)
            queue.append(seed)
    while queue:
        x, y = queue.popleft()
        for neighbor in (
            (x - 1, y),
            (x + 1, y),
            (x, y - 1),
            (x, y + 1),
            (x - 1, y - 1),
            (x + 1, y - 1),
            (x - 1, y + 1),
            (x + 1, y + 1),
        ):
            if neighbor in remaining:
                remaining.remove(neighbor)
                mask.add(neighbor)
                queue.append(neighbor)

    # The selected pod intentionally reflects teal inside its dark muzzle.  A
    # pure hue split would misclassify those enclosed pixels as leaves and make
    # the muzzle transparent when the head rotates.  Recover the small opening
    # from the geometry of the rightmost warm ring, independent of its hue.
    rightmost_seed_x = max(x for x, _y in seeds)
    right_ring_ys = [
        y for x, y in seeds
        if x >= rightmost_seed_x - 2
    ]
    muzzle_center = (
        rightmost_seed_x - 4,
        round(sum(right_ring_ys) / len(right_ring_ys)),
    )
    muzzle_interior_added = 0
    for y in range(muzzle_center[1] - 3, muzzle_center[1] + 4):
        for x in range(muzzle_center[0] - 3, muzzle_center[0] + 4):
            if (x - muzzle_center[0]) ** 2 + (y - muzzle_center[1]) ** 2 > 9:
                continue
            if pixels[x, y][3] == 0 or (x, y) in mask:
                continue
            mask.add((x, y))
            muzzle_interior_added += 1
    if len(mask) < 16:
        raise RuntimeError("Amber cannon segmentation collapsed to an unusable mask")
    mask_bbox = (
        min(x for x, _y in mask),
        min(y for _x, y in mask),
        max(x for x, _y in mask) + 1,
        max(y for _x, y in mask) + 1,
    )
    return mask, {
        "method": (
            "warm-material seeded 8-connected mask excluding confident leaf hues, "
            "plus geometry-recovered enclosed muzzle reflection"
        ),
        "warm_seed_count": len(seeds),
        "mask_pixel_count": len(mask),
        "search_bbox_exclusive": list(search_bbox),
        "mask_bbox_exclusive": list(mask_bbox),
        "muzzle_interior_center": list(muzzle_center),
        "muzzle_interior_pixels_added": muzzle_interior_added,
    }


def _split_composite(
    composite: Image.Image,
    head_mask: set[tuple[int, int]],
) -> tuple[Image.Image, Image.Image]:
    source = composite.convert("RGBA")
    source_pixels = source.load()
    body = source.copy()
    body_pixels = body.load()
    head_full = Image.new("RGBA", source.size, TRANSPARENT)
    head_pixels = head_full.load()
    for x, y in head_mask:
        head_pixels[x, y] = source_pixels[x, y]
        body_pixels[x, y] = TRANSPARENT
    return clean_transparency(body), clean_transparency(head_full)


def _draw_recessed_socket(
    body: Image.Image,
    palette: tuple[tuple[int, int, int], ...],
    head_mask: set[tuple[int, int]],
) -> Image.Image:
    """Restore the circular socket hidden beneath the detachable cannon head.

    The imagegen master contains the complete installed turret, so separating the
    head naturally uncovers transparent pixels on the socket's lower-right side.
    Only those newly transparent pixels are reconstructed; the authored crescent
    ring and leaf planes stay byte-for-byte unchanged.
    """
    result = body.copy().convert("RGBA")
    pixels = result.load()
    # Reconstruct only genuinely occluded right-side leaf/ring pixels from the
    # corresponding authored left half.  Transparent pixels whose mirror is
    # also transparent remain outside the natural rosette silhouette.
    center_x, center_y = CANNON_PIVOT_IN_BODY
    for x, y in head_mask:
        if x <= center_x or pixels[x, y][3] > 0:
            continue
        mirror_x = center_x - (x - center_x)
        if mirror_x < 0:
            continue
        mirrored_pixel = pixels[mirror_x, y]
        if mirrored_pixel[3] > 0:
            pixels[x, y] = mirrored_pixel

    darkest = min(palette, key=lambda color: sum(color))
    green_colors = []
    for color in palette:
        hue, saturation, _value = colorsys.rgb_to_hsv(
            *(channel / 255.0 for channel in color)
        )
        if 0.16 <= hue <= 0.52 and saturation >= 0.18:
            green_colors.append(color)
    green_colors.sort(key=lambda color: sum(color))
    socket_fill = green_colors[0] if green_colors else darkest
    socket_rim = (
        green_colors[min(2, len(green_colors) - 1)]
        if green_colors
        else darkest
    )
    for offset_y in range(-11, 12):
        for offset_x in range(-11, 12):
            distance_sq = offset_x * offset_x + offset_y * offset_y
            if distance_sq > 121:
                continue
            x = center_x + offset_x
            y = center_y + offset_y
            if (x, y) not in head_mask:
                continue
            if pixels[x, y][3] > 0:
                continue
            if distance_sq >= 81:
                pixels[x, y] = (*socket_rim, 255)
            elif distance_sq >= 64:
                pixels[x, y] = (*socket_fill, 255)
            else:
                pixels[x, y] = (*darkest, 255)
    return clean_transparency(result)


def _register_head(head_full: Image.Image) -> tuple[Image.Image, dict]:
    bbox = alpha_bbox(head_full)
    subject = head_full.crop(bbox)
    # Preserve every pixel's position relative to the authored body pivot.  The
    # scene places HEAD_TEXTURE_PIVOT on CANNON_PIVOT_IN_BODY; translating by the
    # pivot delta therefore recreates the selected master exactly at rotation 0
    # and keeps every firing frame on one shared pivot.
    pivot_delta = (
        HEAD_TEXTURE_PIVOT[0] - CANNON_PIVOT_IN_BODY[0],
        HEAD_TEXTURE_PIVOT[1] - CANNON_PIVOT_IN_BODY[1],
    )
    origin_x = bbox[0] + pivot_delta[0]
    origin_y = bbox[1] + pivot_delta[1]
    registered = place_at(subject, (origin_x, origin_y))
    registered_bbox = alpha_bbox(registered)
    return registered, {
        "mode": "source-relative shared body/head pivot registration",
        "source_mask_bbox_exclusive": list(bbox),
        "paste_origin": [origin_x, origin_y],
        "body_pivot": list(CANNON_PIVOT_IN_BODY),
        "output_pivot": list(HEAD_TEXTURE_PIVOT),
        "visual_muzzle_edge": list(VISUAL_MUZZLE_EDGE_IN_HEAD_TEXTURE),
        "scene_muzzle_marker": list(SCENE_MUZZLE_MARKER_IN_HEAD_TEXTURE),
    }


def _green_palette_ramp(
    palette: tuple[tuple[int, int, int], ...],
) -> list[tuple[int, int, int]]:
    colors = []
    for color in palette:
        hue, saturation, value = colorsys.rgb_to_hsv(
            *(channel / 255.0 for channel in color)
        )
        if 0.16 <= hue <= 0.52 and saturation >= 0.18 and value >= 0.15:
            colors.append(color)
    return sorted(colors, key=lambda color: sum(color))


def _body_idle_frame(
    body: Image.Image,
    frame_index: int,
    palette: tuple[tuple[int, int, int], ...],
) -> Image.Image:
    if frame_index == 0:
        return body.copy()
    ramp = _green_palette_ramp(palette)
    if len(ramp) < 3:
        return body.copy()
    highlight = ramp[-1]
    replacement = ramp[-2]
    result = body.copy().convert("RGBA")
    source = body.load()
    target = result.load()
    for y in range(1, result.height - 1):
        for x in range(1, result.width - 1):
            if source[x, y][:3] != highlight or source[x, y][3] == 0:
                continue
            if any(
                source[x + dx, y + dy][3] == 0
                for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1))
            ):
                continue
            if (x * 3 + y * 5 + frame_index * 7) % 19 == 0:
                target[x, y] = (*replacement, 255)
    return clean_transparency(result)


def _warm_palette_ramp(
    palette: tuple[tuple[int, int, int], ...],
) -> list[tuple[int, int, int]]:
    colors = []
    for color in palette:
        red, green, blue = color
        if red > green * 1.04 and green > blue * 1.05:
            colors.append(color)
    return sorted(colors, key=lambda color: sum(color))


def _fire_head_frame(
    head: Image.Image,
    recoil: int,
    heat_columns: int,
    palette: tuple[tuple[int, int, int], ...],
) -> Image.Image:
    source = head.convert("RGBA")
    source_pixels = source.load()
    result = Image.new("RGBA", source.size, TRANSPARENT)
    target = result.load()
    fixed_mount_right = HEAD_TEXTURE_PIVOT[0] + 3
    for y in range(source.height):
        for x in range(source.width):
            pixel = source_pixels[x, y]
            if pixel[3] == 0:
                continue
            target_x = x if x <= fixed_mount_right else x - recoil
            target[target_x, y] = pixel

    warm_ramp = _warm_palette_ramp(palette)
    if heat_columns > 0 and warm_ramp:
        bbox = alpha_bbox(result)
        hottest = warm_ramp[-1]
        for y in range(bbox[1], bbox[3]):
            for x in range(max(bbox[0], bbox[2] - heat_columns - 1), bbox[2] - 1):
                red, green, blue, alpha = target[x, y]
                if alpha > 0 and red > green * 1.04 and green > blue * 1.05:
                    target[x, y] = (*hottest, 255)
    return clean_transparency(result)


def _build_icon(body: Image.Image, head: Image.Image) -> Image.Image:
    icon = body.copy().convert("RGBA")
    offset = (
        CANNON_PIVOT_IN_BODY[0] - HEAD_TEXTURE_PIVOT[0],
        CANNON_PIVOT_IN_BODY[1] - HEAD_TEXTURE_PIVOT[1],
    )
    icon.alpha_composite(head, offset)
    return clean_transparency(icon)


def _maximum_anchor_drift(anchors: list[tuple[float, float]]) -> float:
    first_x, first_y = anchors[0]
    return max(
        max(abs(anchor_x - first_x), abs(anchor_y - first_y))
        for anchor_x, anchor_y in anchors
    )


def _pixel_difference_count(first: Image.Image, second: Image.Image) -> int:
    if first.size != second.size:
        raise RuntimeError("Cannot compare Agave anchor images with different sizes")
    return sum(
        first_pixel != second_pixel
        for first_pixel, second_pixel in zip(first.getdata(), second.getdata())
    )


def build_assets(input_path: Path) -> tuple[dict[str, Image.Image], dict]:
    master = normalize_imagegen_subject(
        input_path,
        max_subject_size=COMPOSITE_MAX_SUBJECT_SIZE,
    )
    registered_master, master_origin = place_bottom_center(
        master.image,
        target=BODY_FOOT_TARGET,
    )
    palette = build_shared_palette([registered_master], max_colors=MAX_VISIBLE_COLORS)
    registered_master = apply_palette(registered_master, palette)
    head_mask, segmentation = _find_head_mask(registered_master)
    body_base, head_full = _split_composite(registered_master, head_mask)
    body_base = _draw_recessed_socket(body_base, palette, head_mask)
    head_idle, head_registration = _register_head(head_full)

    assets = {
        f"body_idle_{index}": _body_idle_frame(body_base, index, palette)
        for index in range(4)
    }
    assets["head_idle_0"] = head_idle
    fire_sequence = ((0, 1), (1, 2), (1, 3), (1, 1), (0, 0))
    for index, (recoil, heat_columns) in enumerate(fire_sequence):
        assets[f"head_fire_{index}"] = _fire_head_frame(
            head_idle,
            recoil,
            heat_columns,
            palette,
        )
    assets["icon"] = _build_icon(assets["body_idle_0"], head_idle)
    assets = {name: apply_palette(image, palette) for name, image in assets.items()}
    anchor_recomposition_diff = _pixel_difference_count(
        assets["icon"],
        registered_master,
    )

    body_feet = [foot_anchor(assets[f"body_idle_{index}"]) for index in range(4)]
    body_foot_drift = _maximum_anchor_drift(body_feet)
    head_radii = {
        name: round(max_visible_radius(image, HEAD_TEXTURE_PIVOT), 3)
        for name, image in assets.items()
        if name.startswith("head_")
    }
    maximum_head_radius = max(head_radii.values())
    muzzle_tips = {
        name: alpha_bbox(image)[2]
        for name, image in assets.items()
        if name.startswith("head_")
    }
    muzzle_tip_drift = max(muzzle_tips.values()) - min(muzzle_tips.values())
    if body_foot_drift > 1.0:
        raise RuntimeError(
            f"Agave body foot drift is {body_foot_drift:.3f}px; limit is 1px"
        )
    if maximum_head_radius > HEAD_MAX_RADIUS:
        raise RuntimeError(
            f"Agave head radius is {maximum_head_radius:.3f}px; "
            f"limit is {HEAD_MAX_RADIUS}px. Regenerate instead of shrinking it."
        )
    if muzzle_tip_drift > 1:
        raise RuntimeError(
            f"Agave firing muzzle drifts {muzzle_tip_drift}px; limit is 1px"
        )
    if anchor_recomposition_diff != 0:
        raise RuntimeError(
            "Agave body/head anchor recomposition differs from the selected "
            f"master by {anchor_recomposition_diff} pixels"
        )

    return assets, {
        "source": source_audit(master),
        "master_registration": {
            "mode": "bottom_center",
            "paste_origin": list(master_origin),
            "output_foot_target": list(BODY_FOOT_TARGET),
        },
        "segmentation": segmentation,
        "head_registration": head_registration,
        "animation_derivation": {
            "body": "stationary geometry; deterministic interior highlight substitutions only",
            "head_fire_recoil_source_px": [item[0] for item in fire_sequence],
            "head_fire_heat_columns": [item[1] for item in fire_sequence],
            "detached_projectile_or_flash_in_frames": False,
        },
        "shared_palette": {
            "visible_color_limit": MAX_VISIBLE_COLORS,
            "actual_color_count": len(palette),
            "rgb": [list(color) for color in palette],
        },
        "cross_frame_audit": {
            "body_foot_anchors": [list(anchor) for anchor in body_feet],
            "body_foot_max_drift_source_px": round(body_foot_drift, 3),
            "body_foot_drift_limit_source_px": 1.0,
            "head_output_pivots": {
                name: list(HEAD_TEXTURE_PIVOT) for name in head_radii
            },
            "head_pivot_max_drift_source_px": 0,
            "head_radius_by_frame_source_px": head_radii,
            "head_maximum_radius_source_px": round(maximum_head_radius, 3),
            "head_radius_limit_source_px": HEAD_MAX_RADIUS,
            "muzzle_edge_x_by_frame": muzzle_tips,
            "muzzle_tip_max_drift_source_px": muzzle_tip_drift,
            "anchor_recomposition_diff_pixels": anchor_recomposition_diff,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build audited true-64px Agave Cannon assets from one master",
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    parser.add_argument("--audit-path", type=Path, default=AUDIT_PATH)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate entirely in memory; do not write PNG or audit files",
    )
    args = parser.parse_args()

    assets, context = build_assets(args.input)
    outputs = []
    for name, image in assets.items():
        max_size = BODY_MAX_SUBJECT_SIZE if name.startswith("body_") else (64, 64)
        outputs.append(
            audit_image(
                image,
                label=name,
                path=portable_path(args.output_dir / OUTPUT_FILES[name]),
                max_subject_size=max_size,
            )
        )
    failures = validation_failures(outputs)
    report = {
        "schema_version": 2,
        "asset_family": "agave_cannon",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen selected composite master with native transparent Alpha",
            "reliable logical-grid analysis",
            "nearest logical-cell selection into 64px contract",
            "shared <=64-color palette without dithering",
            "material-aware body/head separation",
            "deterministic stationary idle and fixed-pivot recoil derivation",
            "binary-alpha and footprint audit",
        ],
        "visual_contract": {
            "source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "static_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "world_footprint_px": [WORLD_FOOTPRINT_SIDE, WORLD_FOOTPRINT_SIDE],
            "camera_zoom": 2,
            "screen_px_per_source_px": 1,
            "root_pivot_in_source_canvas": list(ROOT_PIVOT),
            "cannon_pivot_in_body_canvas": list(CANNON_PIVOT_IN_BODY),
            "head_texture_pivot": list(HEAD_TEXTURE_PIVOT),
            "visual_muzzle_edge_in_head_texture": list(
                VISUAL_MUZZLE_EDGE_IN_HEAD_TEXTURE
            ),
            "scene_muzzle_marker_in_head_texture": list(
                SCENE_MUZZLE_MARKER_IN_HEAD_TEXTURE
            ),
            "alpha": "binary",
            "transparent_rgb": [0, 0, 0],
            "visible_color_limit": MAX_VISIBLE_COLORS,
        },
        **context,
        "outputs": outputs,
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    if args.check_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, image in assets.items():
        image.save(args.output_dir / OUTPUT_FILES[name])
    args.audit_path.parent.mkdir(parents=True, exist_ok=True)
    args.audit_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built {len(assets)} Agave assets in {args.output_dir}")
    print(f"Audit report: {args.audit_path}")


if __name__ == "__main__":
    main()
