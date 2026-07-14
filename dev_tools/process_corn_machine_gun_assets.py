#!/usr/bin/env python3
"""Build the audited Corn Machine Gun pixel family from one imagegen master.

The selected imagegen source already contains the final compact silhouette and
four-bore identity.  This processor removes only the connected magenta
background, measures the authored logical grid, and refuses any source that
would require fitting or unsafe compression.  Every runtime frame is then
derived deterministically from the same 64px registration and shared palette.
"""

from __future__ import annotations

import argparse
from collections import deque
import colorsys
import hashlib
import json
from pathlib import Path
from typing import Iterable

from PIL import Image

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    TRANSPARENT,
    WORLD_FOOTPRINT_SIDE,
    WORLD_SCALE,
    alpha_bbox,
    apply_palette,
    audit_image,
    build_shared_palette,
    clean_transparency,
    foot_anchor,
    normalize_imagegen_subject,
    place_at,
    portable_path,
    source_audit,
    validation_failures,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/corn_machine_gun"
DEFAULT_INPUT = SOURCE_DIR / "corn_machine_gun_selected_imagegen_magenta.png"
OUTPUT_DIR = ROOT / "resources/texture/plant_defense/corn_machine_gun"
AUDIT_PATH = SOURCE_DIR / "corn_asset_audit.json"
MANIFEST_PATH = SOURCE_DIR / "imagegen_prompt_manifest.json"

OUTPUT_FILES = {
    **{f"body_idle_{index}": f"corn_body_idle_{index}.png" for index in range(4)},
    "turret_idle_0": "corn_turret_idle_0.png",
    **{
        f"turret_spin_{index}": f"corn_turret_spin_{index}.png"
        for index in range(4)
    },
    **{
        f"muzzle_flash_{index}": f"corn_muzzle_flash_{index}.png"
        for index in range(2)
    },
    "icon": "icon.png",
}

FAMILY_VISIBLE_COLOR_LIMIT = 48
COMPOSITE_MAX_SUBJECT_SIZE = (58, 60)
BODY_MAX_SUBJECT_SIZE = (58, 60)
BODY_FOOT_TARGET = (32, 62)

# These coordinates are the single source of truth for both the generated
# manifest and processor audit.  Scene authors can apply the same registration
# equations used by the Agave Cannon without copying obsolete prose values.
TURRET_PIVOT_IN_BODY = (30, 31)
HEAD_TEXTURE_PIVOT = (32, 32)
MUZZLE_IN_HEAD_TEXTURE = (57, 33)
FLASH_TEXTURE_ANCHOR = (32, 32)

HEAD_SEARCH_BBOX = (27, 18, 58, 44)
SPIN_MUTABLE_BBOX = (33, 24, 55, 41)
LOCATOR_SOURCE_BBOX = (33, 32, 37, 37)
LOCATOR_TARGET_ORIGINS = (
    (33, 32),
    (36, 25),
    (41, 28),
    (37, 35),
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def _is_warm_head_seed(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return (
        alpha > 0
        and red >= 90
        and red > green * 1.08
        and green > blue * 1.18
        and red > blue * 1.45
    )


def _is_green(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return alpha > 0 and green > red * 1.03 and green > blue * 1.10


def _is_locator_color(color: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = color
    return alpha > 0 and (
        _is_green(color)
        or (red + green + blue > 600 and blue < 160 and green >= red * 0.88)
    )


def _exact_bottom_center(subject: Image.Image) -> tuple[Image.Image, tuple[int, int]]:
    """Register the inclusive bbox centre exactly at BODY_FOOT_TARGET."""
    paste_origin = (
        round(BODY_FOOT_TARGET[0] - (subject.width - 1) * 0.5),
        BODY_FOOT_TARGET[1] - subject.height + 1,
    )
    registered = place_at(subject, paste_origin)
    if foot_anchor(registered) != tuple(float(value) for value in BODY_FOOT_TARGET):
        raise RuntimeError(
            "Corn master cannot be registered to the exact (32,62) foot without "
            "altering its measured logical pixels"
        )
    return registered, paste_origin


def _fill_enclosed_cells(
    coverage: set[tuple[int, int]],
) -> set[tuple[int, int]]:
    left = min(x for x, _y in coverage)
    top = min(y for _x, y in coverage)
    right = max(x for x, _y in coverage)
    bottom = max(y for _x, y in coverage)
    exterior: set[tuple[int, int]] = set()
    queue: deque[tuple[int, int]] = deque()
    for x in range(left, right + 1):
        for y in (top, bottom):
            point = (x, y)
            if point not in coverage and point not in exterior:
                exterior.add(point)
                queue.append(point)
    for y in range(top, bottom + 1):
        for x in (left, right):
            point = (x, y)
            if point not in coverage and point not in exterior:
                exterior.add(point)
                queue.append(point)
    while queue:
        x, y = queue.popleft()
        for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            neighbor_x, neighbor_y = neighbor
            if not (
                left <= neighbor_x <= right and top <= neighbor_y <= bottom
            ):
                continue
            if neighbor in coverage or neighbor in exterior:
                continue
            exterior.add(neighbor)
            queue.append(neighbor)
    return {
        (x, y)
        for y in range(top, bottom + 1)
        for x in range(left, right + 1)
        if (x, y) not in exterior
    }


def _find_head_mask(composite: Image.Image) -> tuple[set[tuple[int, int]], dict]:
    """Separate the warm corn turret without treating its four bores as holes."""
    pixels = composite.convert("RGBA").load()
    left, top, right, bottom = HEAD_SEARCH_BBOX
    seeds = {
        (x, y)
        for y in range(top, bottom)
        for x in range(left, right)
        if _is_warm_head_seed(pixels[x, y])
    }
    if len(seeds) < 100:
        raise RuntimeError(
            "Selected Corn Machine Gun master has no substantial separable "
            "golden turret region"
        )

    # One Chebyshev pixel retains the dark outline around the golden material.
    # Filling the bounded interior then preserves all four dark aperture faces
    # and the intentionally asymmetric pale-green locator patch.
    coverage = {
        (x + offset_x, y + offset_y)
        for x, y in seeds
        for offset_y in (-1, 0, 1)
        for offset_x in (-1, 0, 1)
        if left <= x + offset_x < right and top <= y + offset_y < bottom
    }
    filled = _fill_enclosed_cells(coverage)
    mask = {
        (x, y)
        for x, y in filled
        if pixels[x, y][3] > 0
    }
    mask_bbox = (
        min(x for x, _y in mask),
        min(y for _x, y in mask),
        max(x for x, _y in mask) + 1,
        max(y for _x, y in mask) + 1,
    )
    if len(mask) < 350 or mask_bbox[2] - mask_bbox[0] < 20:
        raise RuntimeError("Corn turret segmentation collapsed to an unusable mask")
    return mask, {
        "method": (
            "warm-material seeds, one logical-pixel outline dilation, and "
            "bounded-interior recovery for the four dark apertures and locator"
        ),
        "search_bbox_exclusive": list(HEAD_SEARCH_BBOX),
        "warm_seed_count": len(seeds),
        "mask_pixel_count": len(mask),
        "mask_bbox_exclusive": list(mask_bbox),
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


def _green_palette_ramp(
    palette: tuple[tuple[int, int, int], ...],
) -> list[tuple[int, int, int]]:
    colors = []
    for color in palette:
        hue, saturation, value = colorsys.rgb_to_hsv(
            *(channel / 255.0 for channel in color)
        )
        if 0.15 <= hue <= 0.38 and saturation >= 0.30 and value >= 0.10:
            colors.append(color)
    return sorted(colors, key=sum)


def _warm_palette_ramp(
    palette: tuple[tuple[int, int, int], ...],
) -> list[tuple[int, int, int]]:
    return sorted(
        (
            color
            for color in palette
            if color[0] >= 90
            and color[0] > color[1] * 1.08
            and color[1] > color[2] * 1.18
            and color[0] > color[2] * 1.45
        ),
        key=sum,
    )


def _draw_recessed_socket(
    body: Image.Image,
    head_mask: set[tuple[int, int]],
    palette: tuple[tuple[int, int, int], ...],
) -> tuple[Image.Image, dict]:
    """Rebuild only the compact green socket hidden by the installed turret."""
    result = body.copy().convert("RGBA")
    pixels = result.load()
    center_x, center_y = TURRET_PIVOT_IN_BODY

    mirrored_pixels = 0
    for x, y in sorted(head_mask):
        if x <= center_x or pixels[x, y][3] > 0:
            continue
        mirror_x = center_x - (x - center_x)
        if mirror_x < 0:
            continue
        mirrored_pixel = pixels[mirror_x, y]
        if mirrored_pixel[3] > 0:
            pixels[x, y] = mirrored_pixel
            mirrored_pixels += 1

    green_ramp = _green_palette_ramp(palette)
    if len(green_ramp) < 10:
        raise RuntimeError("Corn shared palette lacks a usable green socket ramp")
    socket_colors = (green_ramp[2], green_ramp[5], green_ramp[9])
    filled_pixels = 0
    for x, y in head_mask:
        if pixels[x, y][3] > 0:
            continue
        distance_squared = (x - center_x) ** 2 + (y - center_y) ** 2
        if distance_squared > 121:
            continue
        if distance_squared < 49:
            color = socket_colors[0]
        elif distance_squared < 81:
            color = socket_colors[1]
        else:
            color = socket_colors[2]
        pixels[x, y] = (*color, 255)
        filled_pixels += 1
    return clean_transparency(result), {
        "mode": "authored-left-shell mirror plus compact 11px recessed socket",
        "pivot": list(TURRET_PIVOT_IN_BODY),
        "mirrored_pixels": mirrored_pixels,
        "radial_fill_pixels": filled_pixels,
        "maximum_radius_source_px": 11,
    }


def _register_head(head_full: Image.Image) -> tuple[Image.Image, dict]:
    bbox = alpha_bbox(head_full)
    subject = head_full.crop(bbox)
    pivot_delta = (
        HEAD_TEXTURE_PIVOT[0] - TURRET_PIVOT_IN_BODY[0],
        HEAD_TEXTURE_PIVOT[1] - TURRET_PIVOT_IN_BODY[1],
    )
    paste_origin = (bbox[0] + pivot_delta[0], bbox[1] + pivot_delta[1])
    registered = place_at(subject, paste_origin)
    if registered.getpixel(MUZZLE_IN_HEAD_TEXTURE)[3] == 0:
        raise RuntimeError(
            f"Declared Corn muzzle {MUZZLE_IN_HEAD_TEXTURE} is not on the front rim"
        )
    return registered, {
        "mode": "source-relative shared body/head pivot registration",
        "source_mask_bbox_exclusive": list(bbox),
        "paste_origin": list(paste_origin),
        "body_turret_pivot": list(TURRET_PIVOT_IN_BODY),
        "head_texture_pivot": list(HEAD_TEXTURE_PIVOT),
        "muzzle_in_head_texture": list(MUZZLE_IN_HEAD_TEXTURE),
        "muzzle_local_to_head_pivot": [
            MUZZLE_IN_HEAD_TEXTURE[0] - HEAD_TEXTURE_PIVOT[0],
            MUZZLE_IN_HEAD_TEXTURE[1] - HEAD_TEXTURE_PIVOT[1],
        ],
    }


def _alpha_points(image: Image.Image) -> set[tuple[int, int]]:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    return {
        (x, y)
        for y in range(rgba.height)
        for x in range(rgba.width)
        if pixels[x, y][3] > 0
    }


def _is_interior(alpha_points: set[tuple[int, int]], x: int, y: int) -> bool:
    return all(
        neighbor in alpha_points
        for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1))
    )


def _body_highlight_candidates(
    body: Image.Image,
    palette: tuple[tuple[int, int, int], ...],
) -> list[tuple[tuple[int, int], tuple[int, int, int]]]:
    green_ramp = _green_palette_ramp(palette)
    if len(green_ramp) < 2:
        raise RuntimeError("Corn shared palette lacks body highlight colors")
    ramp_indices = {color: index for index, color in enumerate(green_ramp)}
    alpha_points = _alpha_points(body)
    pixels = body.load()
    candidates = [
        ((x, y), green_ramp[ramp_indices[pixels[x, y][:3]] - 1])
        for x, y in alpha_points
        if y >= 40
        and pixels[x, y][:3] in ramp_indices
        and ramp_indices[pixels[x, y][:3]] >= max(1, len(green_ramp) - 8)
        and _is_interior(alpha_points, x, y)
    ]
    candidates.sort(
        key=lambda item: (
            (item[0][0] * 17 + item[0][1] * 29) % 97,
            item[0],
        )
    )
    if len(candidates) < 3:
        raise RuntimeError("Corn body has fewer than three safe 1px highlight cells")
    return candidates


def _body_idle_frames(
    body: Image.Image,
    palette: tuple[tuple[int, int, int], ...],
) -> tuple[dict[str, Image.Image], list[list[int]]]:
    candidates = _body_highlight_candidates(body, palette)
    frames = {"body_idle_0": body.copy()}
    changed_cells: list[list[int]] = []
    for frame_index in range(1, 4):
        frame = body.copy().convert("RGBA")
        (x, y), replacement = candidates[frame_index - 1]
        frame.putpixel((x, y), (*replacement, 255))
        frames[f"body_idle_{frame_index}"] = clean_transparency(frame)
        changed_cells.append([x, y])
    return frames, changed_cells


def _connected_components(
    points: set[tuple[int, int]],
) -> list[set[tuple[int, int]]]:
    remaining = set(points)
    components: list[set[tuple[int, int]]] = []
    while remaining:
        first = remaining.pop()
        component = {first}
        queue = deque([first])
        while queue:
            x, y = queue.popleft()
            for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if neighbor not in remaining:
                    continue
                remaining.remove(neighbor)
                component.add(neighbor)
                queue.append(neighbor)
        components.append(component)
    return components


def _find_apertures(head: Image.Image) -> tuple[list[set[tuple[int, int]]], dict]:
    pixels = head.convert("RGBA").load()
    candidates = {
        (x, y)
        for y in range(24, 40)
        for x in range(44, 59)
        if pixels[x, y][3] > 0 and sum(pixels[x, y][:3]) < 100
    }
    components = [
        component
        for component in _connected_components(candidates)
        if len(component) >= 10
    ]
    components.sort(
        key=lambda component: (
            0
            if sum(y for _x, y in component) / len(component)
            < HEAD_TEXTURE_PIVOT[1] + 1
            else 1,
            sum(x for x, _y in component) / len(component),
        )
    )
    if len(components) != 4:
        raise RuntimeError(
            f"Expected four visual Corn apertures; detected {len(components)}"
        )
    centers = [
        [
            round(sum(x for x, _y in component) / len(component), 3),
            round(sum(y for _x, y in component) / len(component), 3),
        ]
        for component in components
    ]
    return components, {
        "visual_aperture_count": len(components),
        "visual_aperture_centroids": centers,
        "gameplay_muzzle_count": 1,
        "gameplay_muzzle": list(MUZZLE_IN_HEAD_TEXTURE),
        "note": "The four aperture centroids are image detail, not gameplay markers.",
    }


def _nearest_warm_replacement(
    head: Image.Image,
    coordinate: tuple[int, int],
) -> tuple[int, int, int, int]:
    source_x, source_y = coordinate
    pixels = head.load()
    for radius in range(1, 10):
        candidates = []
        for y in range(max(0, source_y - radius), min(CANVAS_SIDE, source_y + radius + 1)):
            for x in range(max(0, source_x - radius), min(CANVAS_SIDE, source_x + radius + 1)):
                color = pixels[x, y]
                if _is_warm_head_seed(color):
                    candidates.append((abs(x - source_x) + abs(y - source_y), x, y, color))
        if candidates:
            return min(candidates)[3]
    raise RuntimeError(f"No warm replacement near Corn locator cell {coordinate}")


def _locator_pattern(head: Image.Image) -> list[tuple[int, int, tuple[int, int, int, int]]]:
    left, top, right, bottom = LOCATOR_SOURCE_BBOX
    pixels = head.load()
    pattern = [
        (x - left, y - top, pixels[x, y])
        for y in range(top, bottom)
        for x in range(left, right)
        if _is_locator_color(pixels[x, y])
    ]
    if len(pattern) < 8:
        raise RuntimeError("Corn pale-green locator extraction is unexpectedly sparse")
    return pattern


def _rotate_row_colors(
    result: Image.Image,
    source: Image.Image,
    phase: int,
) -> None:
    alpha_points = _alpha_points(source)
    source_pixels = source.load()
    target_pixels = result.load()
    left, top, right, bottom = SPIN_MUTABLE_BBOX
    for y in range(top, bottom):
        cells = [
            x
            for x in range(left, min(right, 47))
            if _is_warm_head_seed(source_pixels[x, y])
            and _is_interior(alpha_points, x, y)
        ]
        if len(cells) < 3:
            continue
        colors = [source_pixels[x, y] for x in cells]
        shift = (phase * 2) % len(colors)
        rotated = colors[-shift:] + colors[:-shift]
        for x, color in zip(cells, rotated):
            target_pixels[x, y] = color


def _aperture_highlight_cell(
    component: set[tuple[int, int]],
    phase: int,
) -> tuple[int, int]:
    center_x = sum(x for x, _y in component) / len(component)
    center_y = sum(y for _x, y in component) / len(component)
    directions = ((-1, -1), (1, -1), (1, 1), (-1, 1))
    direction_x, direction_y = directions[phase]
    return max(
        component,
        key=lambda point: (
            (point[0] - center_x) * direction_x
            + (point[1] - center_y) * direction_y,
            -abs(point[0] - center_x) - abs(point[1] - center_y),
        ),
    )


def _turret_spin_frame(
    head: Image.Image,
    phase: int,
    palette: tuple[tuple[int, int, int], ...],
    apertures: list[set[tuple[int, int]]],
    locator_pattern: list[tuple[int, int, tuple[int, int, int, int]]],
) -> Image.Image:
    if phase == 0:
        return head.copy()
    result = head.copy().convert("RGBA")
    _rotate_row_colors(result, head, phase)

    source_left, source_top, _right, _bottom = LOCATOR_SOURCE_BBOX
    source_locator_cells = [
        (source_left + offset_x, source_top + offset_y)
        for offset_x, offset_y, _color in locator_pattern
    ]
    for coordinate in source_locator_cells:
        result.putpixel(coordinate, _nearest_warm_replacement(head, coordinate))

    target_left, target_top = LOCATOR_TARGET_ORIGINS[phase]
    alpha_points = _alpha_points(head)
    for offset_x, offset_y, color in locator_pattern:
        target = (target_left + offset_x, target_top + offset_y)
        if target not in alpha_points:
            raise RuntimeError(
                f"Corn locator phase {phase} escapes the fixed head alpha at {target}"
            )
        result.putpixel(target, color)

    green_ramp = _green_palette_ramp(palette)
    hole_highlight = green_ramp[3]
    for component in apertures:
        result.putpixel(
            _aperture_highlight_cell(component, phase),
            (*hole_highlight, 255),
        )
    return clean_transparency(result)


def _build_flash(
    frame_index: int,
    palette: tuple[tuple[int, int, int], ...],
) -> Image.Image:
    warm_ramp = _warm_palette_ramp(palette)
    if len(warm_ramp) < 5:
        raise RuntimeError("Corn shared palette lacks muzzle-flash colors")
    core = max(palette, key=sum)
    hot = warm_ramp[-1]
    bright = warm_ramp[-2]
    medium = warm_ramp[-4]
    image = Image.new("RGBA", (CANVAS_SIDE, CANVAS_SIDE), TRANSPARENT)
    pixels = image.load()
    if frame_index == 0:
        layers = (
            (medium, ((29, 32), (35, 32), (32, 29), (32, 35))),
            (bright, ((30, 32), (34, 32), (32, 30), (32, 34), (31, 31), (33, 33))),
            (hot, ((31, 32), (33, 32), (32, 31), (32, 33))),
            (core, (FLASH_TEXTURE_ANCHOR,)),
        )
    else:
        layers = (
            (medium, ((29, 32), (36, 31), (36, 33), (38, 32))),
            (bright, ((30, 32), (34, 31), (34, 33), (35, 32), (37, 32))),
            (hot, ((31, 32), (33, 31), (33, 32), (33, 33), (34, 32))),
            (core, (FLASH_TEXTURE_ANCHOR,)),
        )
    for color, coordinates in layers:
        for x, y in coordinates:
            pixels[x, y] = (*color, 255)
    return clean_transparency(image)


def _build_icon(body: Image.Image, head: Image.Image) -> Image.Image:
    icon = body.copy().convert("RGBA")
    offset = (
        TURRET_PIVOT_IN_BODY[0] - HEAD_TEXTURE_PIVOT[0],
        TURRET_PIVOT_IN_BODY[1] - HEAD_TEXTURE_PIVOT[1],
    )
    icon.alpha_composite(head, offset)
    return clean_transparency(icon)


def _pixel_differences(
    first: Image.Image,
    second: Image.Image,
) -> set[tuple[int, int]]:
    if first.size != second.size:
        raise RuntimeError("Cannot compare Corn frames with different sizes")
    first_pixels = first.convert("RGBA").load()
    second_pixels = second.convert("RGBA").load()
    return {
        (x, y)
        for y in range(first.height)
        for x in range(first.width)
        if first_pixels[x, y] != second_pixels[x, y]
    }


def _family_visible_colors(images: Iterable[Image.Image]) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for image in images
        for red, green, blue, alpha in image.convert("RGBA").getdata()
        if alpha > 0
    }


def build_assets(input_path: Path) -> tuple[dict[str, Image.Image], dict]:
    master = normalize_imagegen_subject(
        input_path,
        max_subject_size=COMPOSITE_MAX_SUBJECT_SIZE,
        fit_oversized=False,
    )
    if master.logical_fit_scale != 1.0 or "fit_to_contract" in master.normalization_mode:
        raise RuntimeError(
            "Corn source must enter the 64px contract at its measured logical "
            "resolution; fitting is forbidden"
        )
    registered_master, master_origin = _exact_bottom_center(master.image)
    palette = build_shared_palette(
        [registered_master],
        max_colors=FAMILY_VISIBLE_COLOR_LIMIT,
    )
    registered_master = apply_palette(registered_master, palette)

    head_mask, segmentation = _find_head_mask(registered_master)
    body_without_head, head_full = _split_composite(registered_master, head_mask)
    body, socket_audit = _draw_recessed_socket(
        body_without_head,
        head_mask,
        palette,
    )
    head_idle, head_registration = _register_head(head_full)
    apertures, aperture_audit = _find_apertures(head_idle)
    locator_pattern = _locator_pattern(head_idle)

    body_frames, body_changed_cells = _body_idle_frames(body, palette)
    assets: dict[str, Image.Image] = dict(body_frames)
    assets["turret_idle_0"] = head_idle
    for phase in range(4):
        assets[f"turret_spin_{phase}"] = _turret_spin_frame(
            head_idle,
            phase,
            palette,
            apertures,
            locator_pattern,
        )
    for frame_index in range(2):
        assets[f"muzzle_flash_{frame_index}"] = _build_flash(frame_index, palette)
    assets["icon"] = _build_icon(assets["body_idle_0"], head_idle)
    assets = {name: apply_palette(image, palette) for name, image in assets.items()}

    body_alpha = _alpha_points(assets["body_idle_0"])
    body_feet = [foot_anchor(assets[f"body_idle_{index}"]) for index in range(4)]
    body_differences = {
        f"body_idle_{index}": len(
            _pixel_differences(assets["body_idle_0"], assets[f"body_idle_{index}"])
        )
        for index in range(4)
    }
    for index in range(4):
        frame_name = f"body_idle_{index}"
        if _alpha_points(assets[frame_name]) != body_alpha:
            raise RuntimeError(f"{frame_name} changes the Corn body alpha silhouette")
        if body_feet[index] != tuple(float(value) for value in BODY_FOOT_TARGET):
            raise RuntimeError(f"{frame_name} does not retain foot (32,62)")
    if list(body_differences.values()) != [0, 1, 1, 1]:
        raise RuntimeError(
            "Corn body idle frames must change exactly one interior highlight "
            f"pixel each; got {body_differences}"
        )

    head_alpha = _alpha_points(head_idle)
    spin_differences: dict[str, int] = {}
    changed_outside_mutable: dict[str, int] = {}
    mutable_left, mutable_top, mutable_right, mutable_bottom = SPIN_MUTABLE_BBOX
    for phase in range(4):
        frame_name = f"turret_spin_{phase}"
        frame = assets[frame_name]
        if _alpha_points(frame) != head_alpha:
            raise RuntimeError(f"{frame_name} changes the fixed Corn head silhouette")
        differences = _pixel_differences(head_idle, frame)
        spin_differences[frame_name] = len(differences)
        outside = {
            point
            for point in differences
            if not (
                mutable_left <= point[0] < mutable_right
                and mutable_top <= point[1] < mutable_bottom
            )
        }
        changed_outside_mutable[frame_name] = len(outside)
        if outside:
            raise RuntimeError(
                f"{frame_name} changes {len(outside)} fixed outer-shell pixels"
            )
    if spin_differences["turret_spin_0"] != 0 or any(
        spin_differences[f"turret_spin_{phase}"] == 0 for phase in range(1, 4)
    ):
        raise RuntimeError(f"Corn spin phases are not distinct: {spin_differences}")

    icon_recomposition_diff = len(
        _pixel_differences(assets["icon"], registered_master)
    )
    if icon_recomposition_diff != 0:
        raise RuntimeError(
            "Corn body/head recomposition differs from the selected master by "
            f"{icon_recomposition_diff} pixels"
        )
    for frame_index in range(2):
        if assets[f"muzzle_flash_{frame_index}"].getpixel(FLASH_TEXTURE_ANCHOR)[3] == 0:
            raise RuntimeError("Corn muzzle flash lost its shared (32,32) anchor")

    family_colors = _family_visible_colors(assets.values())
    if len(family_colors) > FAMILY_VISIBLE_COLOR_LIMIT:
        raise RuntimeError(
            f"Corn family uses {len(family_colors)} colors; limit is "
            f"{FAMILY_VISIBLE_COLOR_LIMIT}"
        )

    return assets, {
        "source": {
            **source_audit(master),
            "sha256": _sha256(input_path),
        },
        "master_registration": {
            "mode": "exact inclusive-bbox bottom center",
            "paste_origin": list(master_origin),
            "output_foot_target": list(BODY_FOOT_TARGET),
        },
        "segmentation": segmentation,
        "socket_reconstruction": socket_audit,
        "head_registration": head_registration,
        "aperture_audit": aperture_audit,
        "animation_derivation": {
            "body": (
                "fixed alpha and geometry; one deterministic interior 1px "
                "highlight substitution in each nonzero idle frame"
            ),
            "body_changed_highlight_cells": body_changed_cells,
            "turret": (
                "fixed alpha, outer shell, and mount; only internal kernel row "
                "colors, four aperture interior highlights, and the asymmetric "
                "pale-green locator change by phase"
            ),
            "spin_mutable_bbox_exclusive": list(SPIN_MUTABLE_BBOX),
            "locator_source_bbox_exclusive": list(LOCATOR_SOURCE_BBOX),
            "locator_target_origins": [list(origin) for origin in LOCATOR_TARGET_ORIGINS],
            "flash_frame_count": 2,
            "flash_texture_anchor": list(FLASH_TEXTURE_ANCHOR),
            "detached_flash_in_turret_frames": False,
        },
        "shared_palette": {
            "visible_color_limit": FAMILY_VISIBLE_COLOR_LIMIT,
            "actual_color_count": len(family_colors),
            "rgb": [list(color) for color in palette],
        },
        "cross_frame_audit": {
            "body_foot_anchors": [list(anchor) for anchor in body_feet],
            "body_foot_max_drift_source_px": 0,
            "body_alpha_silhouette_drift_pixels": 0,
            "body_pixel_differences_from_idle_0": body_differences,
            "head_texture_pivots": {
                name: list(HEAD_TEXTURE_PIVOT)
                for name in assets
                if name.startswith("turret_")
            },
            "head_pivot_max_drift_source_px": 0,
            "head_alpha_silhouette_drift_pixels": 0,
            "spin_pixel_differences_from_idle_0": spin_differences,
            "spin_changed_pixels_outside_mutable_bbox": changed_outside_mutable,
            "icon_recomposition_diff_pixels": icon_recomposition_diff,
            "flash_common_anchor": list(FLASH_TEXTURE_ANCHOR),
        },
    }


def _build_manifest(input_path: Path) -> dict:
    managed_outputs = [
        portable_path(OUTPUT_DIR / filename)
        for filename in OUTPUT_FILES.values()
    ]
    return {
        "schema_version": 2,
        "generation_mode": "built-in imagegen",
        "use_case": "stylized-concept",
        "asset_family": "corn_machine_gun",
        "common_contract": {
            "logical_canvas": [CANVAS_SIDE, CANVAS_SIDE],
            "world_scale": [WORLD_SCALE, WORLD_SCALE],
            "world_footprint": [WORLD_FOOTPRINT_SIDE, WORLD_FOOTPRINT_SIDE],
            "maximum_subject": list(COMPOSITE_MAX_SUBJECT_SIZE),
            "foot": list(BODY_FOOT_TARGET),
            "visible_color_limit": FAMILY_VISIBLE_COLOR_LIMIT,
            "pixel_style": (
                "measured native logical cells, nearest center sampling only, "
                "no antialiasing, no dithering, and no unsafe compression"
            ),
            "palette": (
                "dark forest green through saturated warm green with restrained "
                "yellow-green highlights; golden corn turret and dark bores"
            ),
            "background": "connected flat #FF00FF chroma key",
            "alpha_after_processing": "binary; transparent RGB zero",
        },
        "selection": {
            "selected_source": portable_path(input_path),
            "selected_sha256": _sha256(input_path),
            "selection_constraint": (
                "Preserve the compact low rosette silhouette and four-bore corn "
                "turret exactly; recolor foliage only, never convert it into a "
                "tall-stalk corn plant."
            ),
        },
        "production_derivation": {
            "single_master": True,
            "strict_measured_grid_without_fit": True,
            "body_head_split": (
                "Warm golden material seeds retain one outline pixel; enclosed "
                "dark bores and the pale-green locator remain part of the turret."
            ),
            "body_idle_frames": (
                "Four frames share identical alpha and foot; frames 1-3 each "
                "change one internal highlight pixel."
            ),
            "turret_spin_frames": (
                "Four phases keep the outer shell and mount fixed while internal "
                "kernel colors, bore highlights, and locator phase rotate."
            ),
            "body_turret_pivot": list(TURRET_PIVOT_IN_BODY),
            "head_texture_pivot": list(HEAD_TEXTURE_PIVOT),
            "muzzle_in_head_texture": list(MUZZLE_IN_HEAD_TEXTURE),
            "muzzle_local_to_head_pivot": [
                MUZZLE_IN_HEAD_TEXTURE[0] - HEAD_TEXTURE_PIVOT[0],
                MUZZLE_IN_HEAD_TEXTURE[1] - HEAD_TEXTURE_PIVOT[1],
            ],
            "visual_four_bores_are_gameplay_muzzles": False,
            "gameplay_muzzle_count": 1,
            "flash_texture_anchor": list(FLASH_TEXTURE_ANCHOR),
            "icon": (
                "Recompose body idle 0 and turret idle 0 using the declared "
                "body/head pivots."
            ),
            "shared_palette": (
                "One <=48-color palette from the selected composite is reused by "
                "every body, turret, flash, and icon output."
            ),
        },
        "processor": {
            "path": "dev_tools/process_corn_machine_gun_assets.py",
            "check_command": (
                "python dev_tools/process_corn_machine_gun_assets.py --check-only"
            ),
            "write_command": "python dev_tools/process_corn_machine_gun_assets.py",
            "unsafe_grid_compression": False,
            "managed_outputs": managed_outputs,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build audited 64px Corn Machine Gun assets from one master",
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    parser.add_argument("--audit-path", type=Path, default=AUDIT_PATH)
    parser.add_argument("--manifest-path", type=Path, default=MANIFEST_PATH)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate entirely in memory; do not write PNG, audit, or manifest files",
    )
    args = parser.parse_args()

    assets, context = build_assets(args.input)
    outputs = [
        audit_image(
            image,
            label=name,
            path=portable_path(args.output_dir / OUTPUT_FILES[name]),
            max_subject_size=(
                BODY_MAX_SUBJECT_SIZE if name.startswith("body_") else (58, 60)
            ),
        )
        for name, image in assets.items()
    ]
    failures = validation_failures(outputs)
    report = {
        "schema_version": 1,
        "asset_family": "corn_machine_gun",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen selected compact composite master",
            "connected flat #FF00FF chroma key removal",
            "reliable logical-grid analysis with fit forbidden",
            "nearest measured logical-cell center sampling into 64px contract",
            "shared <=48-color median-cut palette without dithering",
            "material-aware body/turret separation with socket reconstruction",
            "fixed-shell deterministic idle/spin/flash derivation",
            "binary-alpha, transparent-RGB, footprint, pivot, and drift audit",
        ],
        "visual_contract": {
            "source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "static_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "world_footprint_px": [WORLD_FOOTPRINT_SIDE, WORLD_FOOTPRINT_SIDE],
            "maximum_subject_px": list(COMPOSITE_MAX_SUBJECT_SIZE),
            "body_foot": list(BODY_FOOT_TARGET),
            "body_turret_pivot": list(TURRET_PIVOT_IN_BODY),
            "head_texture_pivot": list(HEAD_TEXTURE_PIVOT),
            "muzzle_in_head_texture": list(MUZZLE_IN_HEAD_TEXTURE),
            "flash_texture_anchor": list(FLASH_TEXTURE_ANCHOR),
            "alpha": "binary",
            "transparent_rgb": [0, 0, 0],
            "visible_color_limit": FAMILY_VISIBLE_COLOR_LIMIT,
        },
        **context,
        "outputs": outputs,
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    manifest = _build_manifest(args.input)
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
    args.manifest_path.parent.mkdir(parents=True, exist_ok=True)
    args.manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built {len(assets)} Corn Machine Gun assets in {args.output_dir}")
    print(f"Audit report: {args.audit_path}")
    print(f"Manifest: {args.manifest_path}")


if __name__ == "__main__":
    main()
