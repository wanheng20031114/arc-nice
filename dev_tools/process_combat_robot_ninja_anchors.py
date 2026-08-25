#!/usr/bin/env python3
"""Build deterministic first-gate anchors for the ninja combat robot.

The three native-transparent ImageGen drafts define pose and blade language
only. Their pixels are never resized or copied into the native candidates. The
approved drone-operator anchor supplies the immutable antenna, head, box body
and line-leg identity. Only two dark side plates, wire arms, grips and blades
are authored on the native logical canvas.

This script writes review/source artifacts under ``dev_assets`` only. It never
touches runtime textures, animations, scenes or configuration.
"""

from __future__ import annotations

import hashlib
import json
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Iterable, Sequence

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_ninja"
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"

IDENTITY_SOURCE_PATH = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_drone_operator"
    / "combat_robot_drone_operator_anchor_c_approved_native32.png"
)
TANGO_REFERENCE_PATH = (
    PROJECT_ROOT / "resources" / "texture" / "player" / "tango" / "tango_cast_unit.png"
)
ROBOT_REFERENCE_PATHS: tuple[tuple[str, Path], ...] = (
    (
        "Sword",
        PROJECT_ROOT
        / "resources"
        / "texture"
        / "enemy"
        / "mechanical_life"
        / "combat_robot.png",
    ),
    (
        "Gunner",
        PROJECT_ROOT
        / "resources"
        / "texture"
        / "enemy"
        / "mechanical_life"
        / "combat_robot_gunner.png",
    ),
    (
        "Operator",
        PROJECT_ROOT
        / "resources"
        / "texture"
        / "enemy"
        / "mechanical_life"
        / "combat_robot_drone_operator.png",
    ),
    (
        "Shield",
        PROJECT_ROOT
        / "resources"
        / "texture"
        / "enemy"
        / "mechanical_life"
        / "combat_robot_shield_bearer.png",
    ),
)

FRAME_SIZE = 40
SOURCE_IDENTITY_SIZE = 32
IDENTITY_OFFSET = (4, 4)
REGISTERED_CENTER_X = 20.0
BASELINE_Y = 32
MAX_VISIBLE_SIZE = 28
TRAIL_PADDING = 6
APPROVED_STYLE = "c"

TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

OUTLINE = PALETTE[0]
DEEP_SHADOW = PALETTE[1]
JOINT_SHADOW = PALETTE[2]
DARK_STEEL = PALETTE[3]
MID_STEEL = PALETTE[4]
PLATE_GRAY = PALETTE[5]
PLATE_HIGHLIGHT = PALETTE[6]
BLADE_HIGHLIGHT = PALETTE[7]
ACTIVE_RED = PALETTE[9]
HOT_ORANGE = PALETTE[10]

SIDE_ARMOR_POINTS: dict[tuple[int, int], tuple[int, int, int, int]] = {
    (13, 19): DEEP_SHADOW,
    (13, 20): DARK_STEEL,
    (13, 21): DARK_STEEL,
    (13, 22): DEEP_SHADOW,
    (13, 23): OUTLINE,
    (25, 19): JOINT_SHADOW,
    (26, 19): DEEP_SHADOW,
    (26, 20): DARK_STEEL,
    (26, 21): DARK_STEEL,
    (26, 22): DEEP_SHADOW,
    (26, 23): OUTLINE,
}

STYLE_LABELS = {
    "a": "A 交叉护持 / opposing diagonals",
    "b": "B 双反手后掠 / layered reverse grips",
    "c": "C 前后平举 / near-horizontal guard",
}


@dataclass(frozen=True)
class SwordSpec:
    arm: tuple[tuple[int, int], ...]
    hand: tuple[int, int]
    guard: tuple[int, int]
    tip: tuple[int, int]
    edge_side: int
    front: bool


SWORD_LAYOUTS: dict[str, tuple[SwordSpec, SwordSpec]] = {
    "a": (
        SwordSpec(
            arm=((13, 22), (12, 24), (11, 24)),
            hand=(11, 24),
            guard=(10, 25),
            tip=(7, 30),
            edge_side=-1,
            front=False,
        ),
        SwordSpec(
            arm=((26, 21), (27, 20), (27, 19)),
            hand=(27, 19),
            guard=(28, 19),
            tip=(32, 11),
            edge_side=1,
            front=True,
        ),
    ),
    "b": (
        SwordSpec(
            arm=((13, 20), (12, 19), (11, 18)),
            hand=(11, 18),
            guard=(10, 18),
            tip=(6, 15),
            edge_side=-1,
            front=False,
        ),
        SwordSpec(
            arm=((26, 22), (22, 24), (16, 25), (12, 25)),
            hand=(12, 25),
            guard=(11, 26),
            tip=(6, 28),
            edge_side=1,
            front=True,
        ),
    ),
    "c": (
        SwordSpec(
            arm=((13, 23), (13, 24)),
            hand=(13, 24),
            guard=(12, 24),
            tip=(6, 22),
            edge_side=1,
            front=False,
        ),
        SwordSpec(
            arm=((25, 21), (26, 21)),
            hand=(26, 21),
            guard=(27, 21),
            tip=(32, 19),
            edge_side=-1,
            front=True,
        ),
    ),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _empty(size: tuple[int, int] = (FRAME_SIZE, FRAME_SIZE)) -> Image.Image:
    return Image.new("RGBA", size, TRANSPARENT)


def _normalize(image: Image.Image) -> Image.Image:
    normalized = snap_palette(image.convert("RGBA"))
    pixels = normalized.load()
    for y in range(normalized.height):
        for x in range(normalized.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha < 128:
                pixels[x, y] = TRANSPARENT
            else:
                pixels[x, y] = (red, green, blue, 255)
    return normalized


def _is_identity_pixel(x: int, y: int) -> bool:
    if y <= 13:
        return True
    if 14 <= y <= 20:
        return 10 <= x <= 20
    if y == 21:
        return 12 <= x <= 19
    return y >= 22


def _load_identity_layers() -> tuple[Image.Image, Image.Image, int]:
    source = _normalize(Image.open(IDENTITY_SOURCE_PATH))
    if source.size != (SOURCE_IDENTITY_SIZE, SOURCE_IDENTITY_SIZE):
        raise AssertionError(
            f"Approved identity must be 32x32, got {source.size}"
        )
    if source.getchannel("A").getbbox() != (10, 4, 24, 28):
        raise AssertionError(
            "Approved operator identity registration changed: "
            f"{source.getchannel('A').getbbox()}"
        )

    identity = _empty()
    immutable_count = 0
    for source_y in range(SOURCE_IDENTITY_SIZE):
        for source_x in range(SOURCE_IDENTITY_SIZE):
            if not _is_identity_pixel(source_x, source_y):
                continue
            pixel = source.getpixel((source_x, source_y))
            if pixel[3] == 0:
                continue
            identity.putpixel(
                (
                    source_x + IDENTITY_OFFSET[0],
                    source_y + IDENTITY_OFFSET[1],
                ),
                pixel,
            )
            immutable_count += 1

    armored = identity.copy()
    for point, color in SIDE_ARMOR_POINTS.items():
        armored.putpixel(point, color)
    armored = _normalize(armored)

    bbox = armored.getchannel("A").getbbox()
    if bbox is None or bbox[3] != BASELINE_Y:
        raise AssertionError(f"Armored identity misses baseline y={BASELINE_Y}: {bbox}")
    torso_alpha = armored.getchannel("A").crop((10, 18, 30, 26))
    torso_bbox = torso_alpha.getbbox()
    if torso_bbox is None:
        raise AssertionError("Cannot locate the fixed ninja torso")
    torso_center_x = 10 + (torso_bbox[0] + torso_bbox[2]) * 0.5
    if abs(torso_center_x - REGISTERED_CENTER_X) > 0.5:
        raise AssertionError(
            f"Identity torso center x={torso_center_x}, expected 20±0.5"
        )
    return identity, armored, immutable_count


def _bresenham(start: tuple[int, int], end: tuple[int, int]) -> list[tuple[int, int]]:
    x0, y0 = start
    x1, y1 = end
    dx = abs(x1 - x0)
    sx = 1 if x0 < x1 else -1
    dy = -abs(y1 - y0)
    sy = 1 if y0 < y1 else -1
    error = dx + dy
    points: list[tuple[int, int]] = []
    while True:
        points.append((x0, y0))
        if x0 == x1 and y0 == y1:
            break
        doubled = error * 2
        if doubled >= dy:
            error += dy
            x0 += sx
        if doubled <= dx:
            error += dx
            y0 += sy
    return points


def _put_if_inside(
    image: Image.Image,
    point: tuple[int, int],
    color: tuple[int, int, int, int],
) -> None:
    x, y = point
    if 0 <= x < image.width and 0 <= y < image.height:
        image.putpixel(point, color)


def _blade_normal(
    guard: tuple[int, int],
    tip: tuple[int, int],
    side: int,
) -> tuple[int, int]:
    dx = tip[0] - guard[0]
    dy = tip[1] - guard[1]
    if abs(dx) >= abs(dy):
        return (0, side)
    return (side, 0)


def _draw_blade(layer: Image.Image, spec: SwordSpec) -> set[tuple[int, int]]:
    points = _bresenham(spec.guard, spec.tip)
    normal = _blade_normal(spec.guard, spec.tip, spec.edge_side)
    opposite = (-normal[0], -normal[1])
    blade_points: set[tuple[int, int]] = set()

    for x, y in points:
        for offset in (normal, (0, 0), opposite):
            point = (x + offset[0], y + offset[1])
            _put_if_inside(layer, point, OUTLINE)
            blade_points.add(point)
    for point in points:
        _put_if_inside(layer, point, DARK_STEEL)
    for x, y in points[1:]:
        edge = (x + normal[0], y + normal[1])
        _put_if_inside(layer, edge, BLADE_HIGHLIGHT)

    guard_normal = _blade_normal(spec.hand, spec.guard, 1)
    draw = ImageDraw.Draw(layer)
    draw.line((spec.hand, spec.guard), fill=OUTLINE, width=1)
    draw.line(
        (
            (spec.guard[0] - guard_normal[0], spec.guard[1] - guard_normal[1]),
            (spec.guard[0] + guard_normal[0], spec.guard[1] + guard_normal[1]),
        ),
        fill=JOINT_SHADOW,
        width=1,
    )
    _put_if_inside(layer, spec.hand, ACTIVE_RED)
    _put_if_inside(layer, spec.guard, HOT_ORANGE)
    return blade_points


def _draw_arm(layer: Image.Image, spec: SwordSpec) -> None:
    draw = ImageDraw.Draw(layer)
    draw.line(spec.arm, fill=OUTLINE, width=1)
    if len(spec.arm) > 2:
        draw.point(spec.arm[1], fill=MID_STEEL)
    draw.point(spec.hand, fill=PLATE_HIGHLIGHT if spec.front else PLATE_GRAY)


def _build_candidate(
    style: str,
    armored_identity: Image.Image,
) -> tuple[Image.Image, dict[str, list[list[int]]]]:
    specs = SWORD_LAYOUTS[style]
    weapon_layer = _empty()
    geometry: dict[str, list[list[int]]] = {"blade_points": [], "handle_points": []}
    for spec in specs:
        _draw_arm(weapon_layer, spec)
        blade_points = _draw_blade(weapon_layer, spec)
        geometry["blade_points"].extend([list(point) for point in sorted(blade_points)])
        geometry["handle_points"].extend(
            [list(spec.hand), list(spec.guard)]
        )

    candidate = weapon_layer.copy()
    candidate.alpha_composite(armored_identity)
    return _normalize(candidate), geometry


def _component_count(image: Image.Image) -> int:
    alpha = image.getchannel("A")
    visible = {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if alpha.getpixel((x, y)) > 0
    }
    components = 0
    while visible:
        components += 1
        queue: deque[tuple[int, int]] = deque([visible.pop()])
        while queue:
            x, y = queue.popleft()
            for next_point in (
                (x - 1, y),
                (x + 1, y),
                (x, y - 1),
                (x, y + 1),
                (x - 1, y - 1),
                (x + 1, y - 1),
                (x - 1, y + 1),
                (x + 1, y + 1),
            ):
                if next_point in visible:
                    visible.remove(next_point)
                    queue.append(next_point)
    return components


def _audit_pixels(image: Image.Image, label: str) -> None:
    allowed = set(PALETTE) | {TRANSPARENT}
    for pixel in image.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{label} contains non-binary alpha: {pixel}")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{label} contains dirty transparent RGB: {pixel}")
        if pixel not in allowed:
            raise AssertionError(f"{label} contains a color outside the robot palette: {pixel}")


def _audit_candidate(
    style: str,
    candidate: Image.Image,
    immutable_identity: Image.Image,
    armored_identity: Image.Image,
    immutable_count: int,
    geometry: dict[str, list[list[int]]],
) -> dict[str, object]:
    label = f"anchor_{style}"
    if candidate.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"{label} is {candidate.size}, expected 40x40")
    _audit_pixels(candidate, label)
    bbox = candidate.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{label} is empty")
    visible_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])
    if visible_size[0] > MAX_VISIBLE_SIZE or visible_size[1] > MAX_VISIBLE_SIZE:
        raise AssertionError(
            f"{label} bbox {bbox} exceeds {MAX_VISIBLE_SIZE}x{MAX_VISIBLE_SIZE}"
        )
    if (
        bbox[0] < TRAIL_PADDING
        or bbox[1] < TRAIL_PADDING
        or bbox[2] > FRAME_SIZE - TRAIL_PADDING
        or bbox[3] > FRAME_SIZE - TRAIL_PADDING
    ):
        raise AssertionError(
            f"{label} bbox {bbox} enters the {TRAIL_PADDING}px afterimage padding"
        )
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"{label} bbox {bbox} misses baseline y={BASELINE_Y}")

    preserved = 0
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            source_pixel = immutable_identity.getpixel((x, y))
            if source_pixel[3] == 0:
                continue
            if candidate.getpixel((x, y)) != source_pixel:
                raise AssertionError(
                    f"{label} changed immutable robot identity at {(x, y)}"
                )
            preserved += 1
    if preserved != immutable_count:
        raise AssertionError(
            f"{label} preserved {preserved} identity pixels, expected {immutable_count}"
        )
    for point, color in SIDE_ARMOR_POINTS.items():
        if candidate.getpixel(point) != color:
            raise AssertionError(f"{label} changed side armor at {point}")

    components = _component_count(candidate)
    if components != 1:
        raise AssertionError(f"{label} has {components} disconnected components")
    visible_colors = {pixel for pixel in candidate.getdata() if pixel[3]}
    required_blade_colors = {DARK_STEEL, BLADE_HIGHLIGHT, ACTIVE_RED, HOT_ORANGE}
    missing = required_blade_colors - visible_colors
    if missing:
        raise AssertionError(f"{label} misses required blade colors: {sorted(missing)}")

    torso_alpha = armored_identity.getchannel("A").crop((10, 18, 30, 26))
    torso_bbox = torso_alpha.getbbox()
    if torso_bbox is None:
        raise AssertionError("Cannot audit torso center")
    torso_center = 10 + (torso_bbox[0] + torso_bbox[2]) * 0.5
    return {
        "label": STYLE_LABELS[style],
        "native_size": [FRAME_SIZE, FRAME_SIZE],
        "bbox": list(bbox),
        "visible_size": list(visible_size),
        "baseline_y": bbox[3],
        "registered_torso_center_x": torso_center,
        "immutable_identity_pixels": preserved,
        "side_armor_pixels": len(SIDE_ARMOR_POINTS),
        "connected_components": components,
        "palette_colors": len(visible_colors),
        "blade_point_count": len(geometry["blade_points"]),
        "handle_points": geometry["handle_points"],
        "rgba_sha256": hashlib.sha256(candidate.tobytes()).hexdigest(),
    }


def _font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/consola.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    result.alpha_composite(image)
    return result


def _save_candidate_outputs(
    style: str,
    candidate: Image.Image,
) -> dict[str, object]:
    native_path = SOURCE_DIR / f"combat_robot_ninja_anchor_{style}_native40.png"
    preview_path = PREVIEW_DIR / f"combat_robot_ninja_anchor_{style}_16x.png"
    candidate.save(native_path, optimize=True)
    _on_background(candidate).resize(
        (FRAME_SIZE * 16, FRAME_SIZE * 16),
        Image.Resampling.NEAREST,
    ).save(preview_path, optimize=True)
    return {
        "native40": _relative(native_path),
        "integer_16x": _relative(preview_path),
        "native_sha256": _sha256(native_path),
    }


def _save_approved_anchor(candidate: Image.Image) -> dict[str, object]:
    native_path = SOURCE_DIR / "combat_robot_ninja_anchor_c_approved_native40.png"
    preview_path = SOURCE_DIR / "combat_robot_ninja_anchor_c_approved_16x.png"
    candidate.save(native_path, optimize=True)
    _on_background(candidate).resize(
        (FRAME_SIZE * 16, FRAME_SIZE * 16),
        Image.Resampling.NEAREST,
    ).save(preview_path, optimize=True)
    return {
        "selection": APPROVED_STYLE.upper(),
        "native40": _relative(native_path),
        "integer_16x": _relative(preview_path),
        "native_sha256": _sha256(native_path),
    }


def _reference_frame(path: Path) -> Image.Image:
    image = _normalize(Image.open(path))
    frame = image.crop((0, 0, SOURCE_IDENTITY_SIZE, SOURCE_IDENTITY_SIZE))
    registered = _empty()
    registered.alpha_composite(frame, IDENTITY_OFFSET)
    return registered


def _tango_density_frame() -> Image.Image:
    tango = Image.open(TANGO_REFERENCE_PATH).convert("RGBA").crop((0, 0, 8, 8))
    tango = tango.resize((32, 32), Image.Resampling.NEAREST)
    registered = _empty()
    registered.alpha_composite(tango, IDENTITY_OFFSET)
    return registered


def _source_thumbnail(path: Path, size: int) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    image.thumbnail((size, size), Image.Resampling.LANCZOS)
    result = Image.new("RGBA", (size, size), REVIEW_PANEL)
    left = (size - image.width) // 2
    top = (size - image.height) // 2
    result.alpha_composite(image, (left, top))
    return result


def _write_comparison(candidates: dict[str, Image.Image]) -> Path:
    canvas = Image.new("RGBA", (1840, 1440), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title_font = _font(28)
    label_font = _font(18)
    small_font = _font(15)
    draw.text(
        (24, 16),
        "Ninja robot — deterministic first-gate anchors",
        fill=REVIEW_TEXT,
        font=title_font,
    )
    draw.text(
        (24, 54),
        "ImageGen = silhouette language only; runtime-scale candidates use approved native robot pixels",
        fill=REVIEW_MUTED,
        font=small_font,
    )

    references: list[tuple[str, Image.Image]] = [
        (label, _reference_frame(path)) for label, path in ROBOT_REFERENCE_PATHS
    ]
    references.append(("Tango 8x8 density ×4", _tango_density_frame()))
    reference_scale = 8
    reference_tile = FRAME_SIZE * reference_scale
    for index, (label, frame) in enumerate(references):
        left = 24 + index * 356
        draw.text((left, 92), label, fill=REVIEW_TEXT, font=small_font)
        canvas.alpha_composite(
            _on_background(frame).resize(
                (reference_tile, reference_tile), Image.Resampling.NEAREST
            ),
            (left, 118),
        )

    source_size = 280
    candidate_scale = 12
    candidate_tile = FRAME_SIZE * candidate_scale
    for index, style in enumerate(("a", "b", "c")):
        left = 80 + index * 580
        draw.text((left, 468), STYLE_LABELS[style], fill=REVIEW_TEXT, font=label_font)
        source_path = (
            SOURCE_DIR / f"combat_robot_ninja_anchor_{style}_transparent.png"
        )
        draw.text((left, 500), "ImageGen concept", fill=REVIEW_MUTED, font=small_font)
        canvas.alpha_composite(_source_thumbnail(source_path, source_size), (left, 526))
        draw.text(
            (left, 820),
            "Native 40×40 candidate — 12× nearest-neighbor",
            fill=REVIEW_MUTED,
            font=small_font,
        )
        canvas.alpha_composite(
            _on_background(candidates[style]).resize(
                (candidate_tile, candidate_tile), Image.Resampling.NEAREST
            ),
            (left, 850),
        )

    output_path = PREVIEW_DIR / "combat_robot_ninja_anchor_comparison.png"
    canvas.save(output_path, optimize=True)
    return output_path


def _source_grid_report(style: str) -> dict[str, object]:
    source_path = SOURCE_DIR / f"combat_robot_ninja_anchor_{style}_transparent.png"
    if not source_path.is_file():
        raise FileNotFoundError(
            f"Missing native-transparent ImageGen source for ninja anchor {style.upper()}"
        )
    source = Image.open(source_path).convert("RGBA")
    alpha_min, alpha_max = source.getchannel("A").getextrema()
    if alpha_max == 0 or alpha_min == 255:
        raise AssertionError(
            f"ImageGen source must contain native transparency: {source_path.name}"
        )
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"Transparent source {source_path.name} is empty")
    cropped = source.crop(bbox)
    analysis = analyze_image(cropped)
    return {
        "source": _relative(source_path),
        "source_sha256": _sha256(source_path),
        "source_size": list(source.size),
        "subject_bbox": list(bbox),
        "subject_crop_size": list(cropped.size),
        "grid_cell_width": float(analysis["grid_cell_width"]),
        "grid_cell_height": float(analysis["grid_cell_height"]),
        "confidence": float(analysis["confidence"]),
        "detection_mode": str(analysis["detection_mode"]),
        "unsafe_for_direct_resize": (
            str(analysis["detection_mode"]) == "native_or_unknown"
            or float(analysis["confidence"]) < 0.65
        ),
        "source_pixels_imported": False,
    }


def _write_manifest(source_reports: dict[str, dict[str, object]]) -> Path:
    manifest = {
        "version": 1,
        "mode": "built-in image_gen",
        "use_case": "stylized-concept",
        "background": "native transparent alpha",
        "identity_references": [
            _relative(path) for _label, path in ROBOT_REFERENCE_PATHS
        ],
        "density_reference": _relative(TANGO_REFERENCE_PATH),
        "source_candidates": {
            style: {
                "file": Path(report["source"]).name,
                "role": "pose and blade silhouette language only",
                "selection_label": STYLE_LABELS[style],
            }
            for style, report in source_reports.items()
        },
        "approved_anchor": {
            "selection": APPROVED_STYLE.upper(),
            "native40": "combat_robot_ninja_anchor_c_approved_native40.png",
            "integer_16x": "combat_robot_ninja_anchor_c_approved_16x.png",
            "role": "approved immutable identity and pose source for deterministic second-stage animation previews",
        },
        "native_reconstruction_contract": {
            "identity_source": _relative(IDENTITY_SOURCE_PATH),
            "imagegen_pixels_imported": False,
            "canvas": [FRAME_SIZE, FRAME_SIZE],
            "visible_bbox_max": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "body_center_x": REGISTERED_CENTER_X,
            "baseline_y": BASELINE_Y,
            "afterimage_padding": TRAIL_PADDING,
            "palette": [list(color) for color in PALETTE],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "side_armor": "one-to-two-pixel dark cold-steel plates",
            "blades": "cold steel with cold-white edge and red-orange grip points",
            "runtime_written": False,
        },
    }
    path = enemy_asset_report_path("combat_robot_ninja_anchor_prompt_manifest.json")
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return path


def _ensure_review_only() -> None:
    runtime_root = (PROJECT_ROOT / "resources").resolve()
    for output_root in (SOURCE_DIR.resolve(), PREVIEW_DIR.resolve()):
        if output_root == runtime_root or runtime_root in output_root.parents:
            raise AssertionError("Ninja anchor output overlaps runtime resources")


def build() -> dict[str, object]:
    _ensure_review_only()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for required in (
        IDENTITY_SOURCE_PATH,
        TANGO_REFERENCE_PATH,
        *(path for _label, path in ROBOT_REFERENCE_PATHS),
    ):
        if not required.is_file():
            raise FileNotFoundError(required)

    immutable_identity, armored_identity, immutable_count = _load_identity_layers()
    candidates: dict[str, Image.Image] = {}
    candidate_reports: dict[str, dict[str, object]] = {}
    outputs: dict[str, dict[str, object]] = {}
    for style in ("a", "b", "c"):
        candidate, geometry = _build_candidate(style, armored_identity)
        candidates[style] = candidate
        candidate_reports[style] = _audit_candidate(
            style,
            candidate,
            immutable_identity,
            armored_identity,
            immutable_count,
            geometry,
        )
        outputs[style] = _save_candidate_outputs(style, candidate)

    source_reports = {
        style: _source_grid_report(style) for style in ("a", "b", "c")
    }
    approved_anchor = _save_approved_anchor(candidates[APPROVED_STYLE])
    manifest_path = _write_manifest(source_reports)
    comparison_path = _write_comparison(candidates)
    report: dict[str, object] = {
        "asset": "combat_robot_ninja_anchor_candidates",
        "stage": "first_human_review_gate",
        "runtime_written": False,
        "construction": {
            "identity_source": _relative(IDENTITY_SOURCE_PATH),
            "identity_source_sha256": _sha256(IDENTITY_SOURCE_PATH),
            "immutable_identity_pixels": immutable_count,
            "identity_offset": list(IDENTITY_OFFSET),
            "imagegen_source_pixels_imported": False,
            "native_identity_resized": False,
            "palette": [list(color) for color in PALETTE],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "canvas": [FRAME_SIZE, FRAME_SIZE],
            "maximum_visible_bbox": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "registered_center_x": REGISTERED_CENTER_X,
            "baseline_y": BASELINE_Y,
        },
        "source_grid_analysis": source_reports,
        "candidate_audit": candidate_reports,
        "outputs": outputs,
        "approved_anchor": approved_anchor,
        "comparison": _relative(comparison_path),
        "manifest": _relative(manifest_path),
    }
    report_path = enemy_asset_report_path("combat_robot_ninja_anchor_report.json")
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report["report"] = _relative(report_path)
    return report


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(build(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
