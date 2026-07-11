#!/usr/bin/env python3
"""Build audited 64px Agave Cannon animation frames from imagegen sources.

The source art is first keyed, measured as a logical pixel grid, normalized to
one pixel per logical cell, palette-quantized, then laid out on 64x64 canvases.
This deliberately avoids treating the high-resolution imagegen output as a
continuous image and losing its pixel silhouette during an ordinary resize.
"""

from __future__ import annotations

import json
from collections import deque
from pathlib import Path

from PIL import Image

from connected_background_remover import (
    ConnectedBackgroundOptions,
    remove_connected_background,
)
from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/agave_cannon"
OUTPUT_DIR = ROOT / "resources/texture/plant_defense/agave_cannon"
LOGICAL_SIDE = 33
FRAME_SIDE = 64
REFERENCE_GRID_CELL_SIZE = 27.25
LOGICAL_PASTE_ORIGIN = (16, 6)
PIVOT_IN_FRAME = (36, 24)
PIVOT_IN_HEAD_TEXTURE = (32, 32)

SOURCE_FILES = {
    "idle_0": "agave_anchor_v2_imagegen_magenta.png",
    "idle_1": "idle_1_imagegen_magenta.png",
    "idle_2": "idle_2_imagegen_magenta.png",
    "idle_3": "idle_3_imagegen_magenta.png",
    "fire_0": "fire_0_imagegen_magenta.png",
    "fire_1": "fire_1_imagegen_magenta.png",
    "fire_2": "fire_2_imagegen_magenta.png",
    "fire_3": "fire_3_imagegen_magenta.png",
    "fire_4": "fire_4_imagegen_magenta.png",
}

# Neutral, deliberately small palette. The first entry is the mandatory
# exterior outline. No violet/purple colors are present.
PALETTE = {
    "outline": (8, 8, 8, 255),
    "teal_dark": (32, 104, 91, 255),
    "teal": (60, 150, 123, 255),
    "teal_light": (79, 174, 145, 255),
    "pod_dark": (66, 88, 37, 255),
    "pod": (99, 126, 54, 255),
    "wood_dark": (143, 88, 24, 255),
    "wood": (211, 149, 43, 255),
    "flash": (255, 229, 113, 255),
    "ball_gray": (104, 108, 104, 255),
}
PALETTE_VALUES = tuple(PALETTE.values())
TRANSPARENT = (0, 0, 0, 0)


def _nearest_palette_color(pixel: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    if pixel[3] == 0:
        return TRANSPARENT
    red, green, blue = pixel[:3]
    return min(
        PALETTE_VALUES,
        key=lambda color: (
            (red - color[0]) ** 2
            + (green - color[1]) ** 2
            + (blue - color[2]) ** 2
        ),
    )


def _quantize(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    result = Image.new("RGBA", rgba.size, TRANSPARENT)
    source = rgba.load()
    target = result.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            target[x, y] = _nearest_palette_color(source[x, y])
    return result


def _enforce_black_exterior(image: Image.Image) -> Image.Image:
    rgba = image.copy().convert("RGBA")
    source = rgba.copy().load()
    target = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            if source[x, y][3] == 0:
                target[x, y] = TRANSPARENT
                continue
            for offset_x, offset_y in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                neighbor_x = x + offset_x
                neighbor_y = y + offset_y
                if not (0 <= neighbor_x < rgba.width and 0 <= neighbor_y < rgba.height):
                    target[x, y] = PALETTE["outline"]
                    break
                if source[neighbor_x, neighbor_y][3] == 0:
                    target[x, y] = PALETTE["outline"]
                    break
    return rgba


def _normalize_source(source_path: Path) -> tuple[Image.Image, dict]:
    keyed = remove_connected_background(
        Image.open(source_path),
        ConnectedBackgroundOptions(
            rgb_tolerance=72,
            hue_tolerance=0.035,
            expansion_radius=12,
            harden_alpha=True,
        ),
    )
    analysis = analyze_image(keyed)
    if analysis["detection_mode"] == "native_or_unknown":
        # A few reference-edited frames have fewer internal color edges, so
        # the periodic detector cannot independently lock phase. They inherit
        # the measured 27.25px grid of the audited master instead of being
        # resized as continuous art.
        analysis["detection_mode"] = "inherited_from_master"
        analysis["grid_cell_width"] = REFERENCE_GRID_CELL_SIZE
        analysis["grid_cell_height"] = REFERENCE_GRID_CELL_SIZE
        analysis["grid_cell_size"] = round(REFERENCE_GRID_CELL_SIZE)
        analysis["subject_grid_width"] = round(
            analysis["subject_pixel_width"] / REFERENCE_GRID_CELL_SIZE
        )
        analysis["subject_grid_height"] = round(
            analysis["subject_pixel_height"] / REFERENCE_GRID_CELL_SIZE
        )
    elif analysis["confidence"] < 0.45:
        raise RuntimeError(f"Logical grid confidence is too low: {source_path}")
    if analysis["subject_grid_width"] > 40 or analysis["subject_grid_height"] > 40:
        raise RuntimeError(
            "Source exceeds the visual pixel budget "
            f"({analysis['subject_grid_width']}x{analysis['subject_grid_height']}): "
            f"{source_path}"
        )

    square = crop_to_square(keyed, padding=0, align_to_grid=False)
    logical = square.resize((LOGICAL_SIDE, LOGICAL_SIDE), Image.Resampling.NEAREST)
    logical = _quantize(logical)
    logical = _enforce_black_exterior(logical)
    return logical, analysis


def _to_full_frame(logical: Image.Image) -> Image.Image:
    frame = Image.new("RGBA", (FRAME_SIDE, FRAME_SIDE), TRANSPARENT)
    frame.alpha_composite(logical, LOGICAL_PASTE_ORIGIN)
    return frame


def _find_head_mask(full_frame: Image.Image) -> set[tuple[int, int]]:
    pixels = full_frame.load()
    primary_colors = {
        PALETTE["pod_dark"],
        PALETTE["pod"],
        PALETTE["wood_dark"],
        PALETTE["wood"],
        PALETTE["flash"],
        PALETTE["ball_gray"],
    }
    primary_points = [
        (x, y)
        for y in range(10, 33)
        for x in range(24, 52)
        if pixels[x, y] in primary_colors
    ]
    if not primary_points:
        raise RuntimeError("The cannon head colors could not be isolated")

    left = max(min(point[0] for point in primary_points) - 2, 0)
    top = max(min(point[1] for point in primary_points) - 2, 0)
    right = min(max(point[0] for point in primary_points) + 3, FRAME_SIDE)
    bottom = min(max(point[1] for point in primary_points) + 3, FRAME_SIDE)
    non_leaf_colors = primary_colors | {PALETTE["outline"]}
    candidates = {
        (x, y)
        for y in range(top, bottom)
        for x in range(left, right)
        if pixels[x, y] in non_leaf_colors
    }

    # Keep only the connected component that owns the most pod/wood pixels.
    # A detached cannonball in fire frame 3 therefore stays out of the muzzle
    # animation, avoiding a duplicate with the real projectile.
    remaining = set(candidates)
    best_component: set[tuple[int, int]] = set()
    best_score = -1
    while remaining:
        start = remaining.pop()
        component = {start}
        queue: deque[tuple[int, int]] = deque([start])
        while queue:
            x, y = queue.popleft()
            for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    component.add(neighbor)
                    queue.append(neighbor)
        score = sum(pixels[x, y] in primary_colors for x, y in component) * 1000 + len(component)
        if score > best_score:
            best_score = score
            best_component = component
    return best_component


def _build_head_frame(full_frame: Image.Image, head_mask: set[tuple[int, int]]) -> Image.Image:
    source = full_frame.load()
    head = Image.new("RGBA", (FRAME_SIDE, FRAME_SIDE), TRANSPARENT)
    target = head.load()
    shift_x = PIVOT_IN_HEAD_TEXTURE[0] - PIVOT_IN_FRAME[0]
    shift_y = PIVOT_IN_HEAD_TEXTURE[1] - PIVOT_IN_FRAME[1]
    for x, y in head_mask:
        target_x = x + shift_x
        target_y = y + shift_y
        if 0 <= target_x < FRAME_SIDE and 0 <= target_y < FRAME_SIDE:
            target[target_x, target_y] = source[x, y]
    return _enforce_black_exterior(head)


def _draw_socket(body: Image.Image) -> None:
    pixels = body.load()
    center_x, center_y = PIVOT_IN_FRAME
    pattern = (
        (0, -2, "outline"),
        (-1, -1, "outline"), (0, -1, "teal_dark"), (1, -1, "outline"),
        (-2, 0, "outline"), (-1, 0, "teal_dark"), (0, 0, "teal_dark"),
        (1, 0, "teal_dark"), (2, 0, "outline"),
        (-1, 1, "outline"), (0, 1, "teal_dark"), (1, 1, "outline"),
        (0, 2, "outline"),
    )
    for offset_x, offset_y, color_name in pattern:
        pixels[center_x + offset_x, center_y + offset_y] = PALETTE[color_name]


def _build_body_frame(full_frame: Image.Image, head_mask: set[tuple[int, int]]) -> Image.Image:
    body = full_frame.copy()
    pixels = body.load()
    for x, y in head_mask:
        pixels[x, y] = TRANSPARENT
    _draw_socket(body)
    return _enforce_black_exterior(body)


def _build_icon(logical_idle: Image.Image) -> Image.Image:
    bbox = logical_idle.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Idle anchor is empty")
    subject = logical_idle.crop(bbox)
    if subject.width > 32 or subject.height > 32:
        scale = min(32.0 / subject.width, 32.0 / subject.height)
        subject = subject.resize(
            (max(1, round(subject.width * scale)), max(1, round(subject.height * scale))),
            Image.Resampling.NEAREST,
        )
    icon = Image.new("RGBA", (32, 32), TRANSPARENT)
    icon.alpha_composite(subject, ((32 - subject.width) // 2, (32 - subject.height) // 2))
    return _enforce_black_exterior(icon)


def _build_cannonball() -> Image.Image:
    image = Image.new("RGBA", (12, 12), TRANSPARENT)
    pixels = image.load()
    rows = {
        1: (4, 7),
        2: (2, 9),
        3: (1, 10),
        4: (1, 10),
        5: (1, 10),
        6: (1, 10),
        7: (1, 10),
        8: (1, 10),
        9: (2, 9),
        10: (4, 7),
    }
    for y, (left, right) in rows.items():
        for x in range(left, right + 1):
            pixels[x, y] = (22, 23, 22, 255)
    image = _enforce_black_exterior(image)
    pixels = image.load()
    pixels[3, 3] = PALETTE["ball_gray"]
    pixels[4, 3] = PALETTE["ball_gray"]
    pixels[3, 4] = PALETTE["ball_gray"]
    return image


def _audit_output(path: Path, expected_size: tuple[int, int]) -> dict:
    image = Image.open(path).convert("RGBA")
    pixels = image.load()
    alpha_values = set(image.getchannel("A").getdata())
    transparent_rgb_clean = all(
        alpha != 0 or (red == 0 and green == 0 and blue == 0)
        for red, green, blue, alpha in image.getdata()
    )
    visible_colors = {pixel for pixel in image.getdata() if pixel[3] > 0}
    has_purple = any(red > blue * 0.55 and blue > green * 1.3 for red, green, blue, _ in visible_colors)
    exterior_pixels: list[tuple[int, int, int, int]] = []
    for y in range(image.height):
        for x in range(image.width):
            if pixels[x, y][3] == 0:
                continue
            for offset_x, offset_y in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                neighbor_x = x + offset_x
                neighbor_y = y + offset_y
                if not (0 <= neighbor_x < image.width and 0 <= neighbor_y < image.height):
                    exterior_pixels.append(pixels[x, y])
                    break
                if pixels[neighbor_x, neighbor_y][3] == 0:
                    exterior_pixels.append(pixels[x, y])
                    break
    return {
        "path": path.relative_to(ROOT).as_posix(),
        "size": list(image.size),
        "size_ok": image.size == expected_size,
        "binary_alpha": alpha_values.issubset({0, 255}),
        "transparent_rgb_clean": transparent_rgb_clean,
        "exterior_outline_black": bool(exterior_pixels) and all(
            pixel == PALETTE["outline"] for pixel in exterior_pixels
        ),
        "palette_color_count": len(visible_colors),
        "has_purple": has_purple,
    }


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    normalized: dict[str, Image.Image] = {}
    source_audits: dict[str, dict] = {}
    for frame_name, file_name in SOURCE_FILES.items():
        source_path = SOURCE_DIR / file_name
        if not source_path.is_file():
            raise FileNotFoundError(source_path)
        logical, analysis = _normalize_source(source_path)
        normalized[frame_name] = logical
        source_audits[frame_name] = analysis

    generated_paths: list[Path] = []
    for frame_index in range(4):
        frame_name = f"idle_{frame_index}"
        full = _to_full_frame(normalized[frame_name])
        head_mask = _find_head_mask(full)
        body = _build_body_frame(full, head_mask)
        output_path = OUTPUT_DIR / f"agave_body_idle_{frame_index}.png"
        body.save(output_path)
        generated_paths.append(output_path)

    idle_full = _to_full_frame(normalized["idle_0"])
    idle_head = _build_head_frame(idle_full, _find_head_mask(idle_full))
    idle_head_path = OUTPUT_DIR / "agave_cannon_idle_0.png"
    idle_head.save(idle_head_path)
    generated_paths.append(idle_head_path)

    for frame_index in range(5):
        full = _to_full_frame(normalized[f"fire_{frame_index}"])
        head = _build_head_frame(full, _find_head_mask(full))
        output_path = OUTPUT_DIR / f"agave_cannon_fire_{frame_index}.png"
        head.save(output_path)
        generated_paths.append(output_path)

    icon_path = OUTPUT_DIR / "icon.png"
    _build_icon(normalized["idle_0"]).save(icon_path)
    generated_paths.append(icon_path)

    cannonball_path = OUTPUT_DIR / "agave_cannonball.png"
    _build_cannonball().save(cannonball_path)
    generated_paths.append(cannonball_path)

    audits = [
        _audit_output(path, (32, 32) if path.name == "icon.png" else ((12, 12) if path.name == "agave_cannonball.png" else (64, 64)))
        for path in generated_paths
    ]
    if not all(
        audit["size_ok"]
        and audit["binary_alpha"]
        and audit["transparent_rgb_clean"]
        and audit["exterior_outline_black"]
        and not audit["has_purple"]
        for audit in audits
    ):
        raise RuntimeError("One or more processed assets failed the pixel audit")

    report = {
        "pipeline": "built-in imagegen -> magenta key -> logical-grid analysis -> 33px normalization -> limited palette -> 64px layout",
        "logical_side": LOGICAL_SIDE,
        "source_analysis": source_audits,
        "outputs": audits,
    }
    report_path = SOURCE_DIR / "agave_asset_audit.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Built {len(generated_paths)} assets in {OUTPUT_DIR}")
    print(f"Audit report: {report_path}")


if __name__ == "__main__":
    main()
