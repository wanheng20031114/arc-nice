#!/usr/bin/env python3
"""Build preview-only first-gate anchors for the large cardboard monster.

ImageGen rasters are preserved as structural references.  Native 48px sprites
are rebuilt from a fixed palette and explicit coordinate masks on a blank RGBA
canvas; no source-image pixel is sampled into runtime-style candidate art.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageSequence

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "cardboard_monster_large"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"

# Filled after the three independent, byte-preserved ImageGen calls complete.
RAW_SHA256 = {
    "l1": "fb8a9cd73312942f2f2f8b77c545bb23ad4fe7ae27b6bb8c884c7e4c6d389afb",
    "l2": "99a54e1bf512c535e0571cf11d6d8fdb6a04443a0f518dc582a8cc5059b52e33",
    "l3": "ad18b4fd6fadf98e82d9ad148f6dfa53bc8187fa5a461da0f224e630f53372dd",
}

REFERENCE_PATHS = {
    "approved_regular_anchor": ROOT / "dev_assets/source_images/cardboard_monster/cardboard_monster_anchor_approved_native32.png",
    "approved_regular_atlas": ROOT / "dev_assets/source_images/cardboard_monster/cardboard_monster_final_candidate_atlas.png",
    "pale_parcel_icon": ROOT / "dev_assets/source_images/cardboard_monster/cardboard_monster_reference_icon.png",
    "in_game_cardboard_boxes": ROOT / "dev_assets/source_images/cardboard_monster/cardboard_monster_reference_ingame_boxes.png",
}

FRAME = 48
CENTER_X = 24
BASELINE_BOTTOM = 36
BODY_RECT = (14, 14, 34, 32)
FAN_CENTER = (24, 24)
FAN_INNER = 6.0
FAN_OUTER = 24.0
FAN_ANGLE = 60.0
FAN_SEGMENTS = 12

TRANSPARENT = (0, 0, 0, 0)
OUTLINE = (116, 87, 61, 255)
DEEP_BROWN = (88, 64, 45, 255)
LIMB_BROWN = (123, 87, 55, 255)
KRAFT_DARK = (177, 145, 102, 255)
KRAFT_MID = (210, 181, 137, 255)
KRAFT_LIGHT = (232, 213, 177, 255)
FOLD_HIGHLIGHT = (245, 234, 208, 255)
PAPER_EDGE = (154, 117, 78, 255)
PAPER_SWORD = (225, 202, 159, 255)
EYE_DARK = (79, 67, 59, 255)

PALETTE = (
    TRANSPARENT,
    OUTLINE,
    DEEP_BROWN,
    LIMB_BROWN,
    KRAFT_DARK,
    KRAFT_MID,
    KRAFT_LIGHT,
    FOLD_HIGHLIGHT,
    PAPER_EDGE,
    PAPER_SWORD,
    EYE_DARK,
)

REVIEW_BG = (14, 20, 29, 255)
REVIEW_PANEL = (23, 33, 46, 255)
REVIEW_TEXT = (235, 236, 232, 255)
REVIEW_MUTED = (164, 174, 177, 255)
BODY_COLOR = (61, 209, 235, 255)
FAN_COLOR = (255, 190, 78, 255)
BASELINE_COLOR = (108, 219, 151, 255)

Point = tuple[int, int]
Color = tuple[int, int, int, int]


@dataclass(frozen=True)
class CandidateSpec:
    key: str
    title: str
    summary: str


@dataclass
class BuiltCandidate:
    image: Image.Image
    body: set[Point]
    free_arm: set[Point]
    weapon_arm: set[Point]
    left_leg: set[Point]
    right_leg: set[Point]
    sword: set[Point]
    sword_endpoints: tuple[Point, Point]
    eyes: set[Point]


SPECS = (
    CandidateSpec("l1", "L1 直系放大箱剑士", "最贴近普通F2：近方大箱体、斜举折叠纸剑，家族辨识最强。"),
    CandidateSpec("l2", "L2 矮宽搬运箱重兵", "矮宽搬运箱、短稳纸脚与宽纸板剑，重量感最强。"),
    CandidateSpec("l3", "L3 高方封装箱卫士", "高方封装箱、贴身斜护层叠纸剑，守卫感最强。"),
)
VALID_SELECTIONS = {spec.key for spec in SPECS}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bytes_sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return bytes_sha(image.convert("RGBA").tobytes())


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT.resolve()).as_posix()


def ensure_preview_path(path: Path) -> None:
    resolved = path.resolve()
    if not (
        resolved.is_relative_to(SOURCE_DIR.resolve())
        or resolved.is_relative_to(PREVIEW_DIR.resolve())
        or is_enemy_asset_report_path(path)
    ):
        raise AssertionError(f"Refusing non-preview output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_preview_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def points_rect(left: int, top: int, right: int, bottom: int) -> set[Point]:
    return {(x, y) for y in range(top, bottom + 1) for x in range(left, right + 1)}


def row_points(rows: dict[int, tuple[int, int] | tuple[tuple[int, int], ...]]) -> set[Point]:
    result: set[Point] = set()
    for y, runs in rows.items():
        normalized = (runs,) if isinstance(runs[0], int) else runs
        for left, right in normalized:
            result.update((x, y) for x in range(left, right + 1))
    return result


def put_points(image: Image.Image, points: set[Point], color: Color) -> None:
    for x, y in points:
        if not (0 <= x < FRAME and 0 <= y < FRAME):
            raise AssertionError(f"Authored point outside frame: {(x, y)}")
        image.putpixel((x, y), color)


def paint_body(image: Image.Image, body: set[Point]) -> None:
    for point in body:
        x, y = point
        boundary = any((x + dx, y + dy) not in body for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))
        image.putpixel(point, OUTLINE if boundary else KRAFT_MID)


def paint_surface(image: Image.Image, body: set[Point], mapping: dict[Point, Color]) -> None:
    for point, color in mapping.items():
        if point not in body:
            raise AssertionError(f"Surface point outside body: {point}")
        image.putpixel(point, color)


def paint_sword(image: Image.Image, sword: set[Point], core: set[Point], hand: set[Point]) -> None:
    put_points(image, sword, PAPER_EDGE)
    put_points(image, core & sword, PAPER_SWORD)
    put_points(image, hand, DEEP_BROWN)


def build_l1() -> BuiltCandidate:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = points_rect(13, 13, 34, 31)
    paint_body(image, body)
    paint_surface(image, body, {
        **{(x, 13): FOLD_HIGHLIGHT for x in range(14, 34)},
        **{(x, 14): KRAFT_LIGHT for x in range(14, 34)},
        **{(33, y): KRAFT_DARK for y in range(16, 31)},
        (14, 16): KRAFT_LIGHT,
    })
    eyes = {(20, 21), (20, 22), (27, 21), (27, 22)}
    put_points(image, eyes, EYE_DARK)
    free_arm = {(13, 24), (12, 24), (11, 25), (10, 25), (10, 26), (11, 26)}
    weapon_arm = {(34, 24), (35, 24), (35, 25), (36, 25)}
    left_leg = {(19, 31), (19, 32), (18, 33), (18, 34), (17, 35), (18, 35)}
    right_leg = {(28, 31), (28, 32), (29, 33), (29, 34), (30, 35), (31, 35)}
    limbs = free_arm | weapon_arm | left_leg | right_leg
    put_points(image, limbs, LIMB_BROWN)
    put_points(image, {(10, 26), (11, 26), (35, 24), (35, 25), (17, 35), (18, 35), (30, 35), (31, 35)}, DEEP_BROWN)
    sword = row_points({
        14: (45, 45), 15: (44, 45), 16: (43, 45), 17: (42, 44), 18: (41, 43),
        19: (40, 42), 20: (39, 41), 21: (38, 40), 22: (37, 39), 23: (34, 38),
        24: (34, 37), 25: (34, 37),
    })
    sword |= {(33, 22), (34, 22), (33, 23), (34, 23), (35, 23), (34, 24), (35, 24), (36, 24), (35, 25), (36, 25), (37, 25), (36, 26), (37, 26), (38, 26)}
    sword_core = {(45, 15), (44, 16), (43, 17), (42, 18), (41, 19), (40, 20), (39, 21), (38, 22), (37, 23), (36, 24), (34, 23), (36, 25), (37, 26)}
    paint_sword(image, sword, sword_core, {(35, 24), (35, 25)})
    return BuiltCandidate(image, body, free_arm, weapon_arm, left_leg, right_leg, sword, ((35, 24), (45, 14)), eyes)


def build_l2() -> BuiltCandidate:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = points_rect(12, 15, 35, 31)
    paint_body(image, body)
    paint_surface(image, body, {
        **{(x, 15): FOLD_HIGHLIGHT for x in range(13, 35)},
        **{(x, 16): KRAFT_LIGHT for x in range(13, 35)},
        **{(34, y): KRAFT_DARK for y in range(18, 31)},
        (13, 18): KRAFT_LIGHT,
    })
    eyes = {(19, 22), (19, 23), (27, 22), (27, 23)}
    put_points(image, eyes, EYE_DARK)
    free_arm = {(12, 25), (11, 25), (10, 26), (9, 26), (9, 27), (10, 27)}
    weapon_arm = {(35, 25), (36, 25), (37, 25), (37, 26)}
    left_leg = {(19, 31), (19, 32), (18, 33), (18, 34), (17, 35), (18, 35)}
    right_leg = {(29, 31), (29, 32), (30, 33), (30, 34), (31, 35), (32, 35)}
    limbs = free_arm | weapon_arm | left_leg | right_leg
    put_points(image, limbs, LIMB_BROWN)
    put_points(image, {(9, 27), (10, 27), (37, 25), (37, 26), (17, 35), (18, 35), (31, 35), (32, 35)}, DEEP_BROWN)
    sword = row_points({
        12: (42, 44), 13: (42, 44), 14: (41, 44), 15: (41, 43), 16: (40, 43),
        17: (40, 42), 18: (39, 42), 19: (39, 41), 20: (38, 41), 21: (38, 40),
        22: (37, 40), 23: (36, 39), 24: (35, 39), 25: (35, 39), 26: (35, 39),
    })
    sword |= {(33, 23), (34, 23), (35, 23), (36, 23), (37, 23), (38, 23), (39, 23), (40, 23), (34, 24), (35, 24), (36, 24), (37, 24), (38, 24), (39, 24), (40, 24), (35, 25), (36, 25), (37, 25), (38, 25), (39, 25)}
    sword_core = {(43, 13), (42, 14), (42, 15), (41, 16), (41, 17), (40, 18), (40, 19), (39, 20), (39, 21), (38, 22), (38, 23), (37, 24), (34, 24), (35, 24), (36, 24), (38, 24), (39, 24)}
    paint_sword(image, sword, sword_core, {(37, 25), (37, 26)})
    return BuiltCandidate(image, body, free_arm, weapon_arm, left_leg, right_leg, sword, ((37, 25), (44, 12)), eyes)


def build_l3() -> BuiltCandidate:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = points_rect(14, 10, 33, 31)
    paint_body(image, body)
    paint_surface(image, body, {
        **{(x, 10): FOLD_HIGHLIGHT for x in range(15, 33)},
        **{(x, 11): KRAFT_LIGHT for x in range(15, 33)},
        **{(32, y): KRAFT_DARK for y in range(14, 31)},
        (15, 14): KRAFT_LIGHT,
    })
    eyes = {(20, 18), (20, 19), (27, 18), (27, 19)}
    put_points(image, eyes, EYE_DARK)
    free_arm = {(14, 23), (13, 23), (12, 22), (11, 22), (10, 21), (10, 20)}
    weapon_arm = {(33, 23), (34, 23), (35, 23), (35, 24)}
    left_leg = {(19, 31), (19, 32), (18, 33), (18, 34), (17, 35), (18, 35)}
    right_leg = {(28, 31), (28, 32), (29, 33), (29, 34), (30, 35), (31, 35)}
    limbs = free_arm | weapon_arm | left_leg | right_leg
    put_points(image, limbs, LIMB_BROWN)
    put_points(image, {(10, 20), (10, 21), (35, 23), (35, 24), (17, 35), (18, 35), (30, 35), (31, 35)}, DEEP_BROWN)
    sword = row_points({
        9: (42, 43), 10: (41, 43), 11: (41, 43), 12: (40, 42), 13: (40, 42),
        14: (39, 41), 15: (39, 41), 16: (38, 40), 17: (38, 40), 18: (37, 39),
        19: (37, 39), 20: (36, 38), 21: (36, 38), 22: (34, 38), 23: (34, 38), 24: (34, 37),
    })
    sword |= {(32, 21), (33, 21), (34, 21), (35, 21), (36, 21), (37, 21), (38, 21), (32, 22), (33, 22), (34, 22), (35, 22), (36, 22), (37, 22), (38, 22), (33, 23), (34, 23), (35, 23), (36, 23), (37, 23), (38, 23), (39, 23)}
    sword_core = {(42, 10), (42, 11), (41, 12), (41, 13), (40, 14), (40, 15), (39, 16), (39, 17), (38, 18), (38, 19), (37, 20), (37, 21), (36, 22), (33, 22), (34, 22), (35, 22), (36, 22), (37, 22), (38, 22)}
    paint_sword(image, sword, sword_core, {(35, 23), (35, 24)})
    return BuiltCandidate(image, body, free_arm, weapon_arm, left_leg, right_leg, sword, ((35, 23), (42, 9)), eyes)


BUILDERS = {"l1": build_l1, "l2": build_l2, "l3": build_l3}


def visible(image: Image.Image) -> set[Point]:
    return {(x, y) for y in range(image.height) for x in range(image.width) if image.getpixel((x, y))[3] == 255}


def components(points: set[Point], diagonal: bool = True) -> list[set[Point]]:
    remaining = set(points)
    result: list[set[Point]] = []
    offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    if diagonal:
        offsets += [(-1, -1), (1, -1), (-1, 1), (1, 1)]
    while remaining:
        start = remaining.pop()
        part = {start}
        queue = deque([start])
        while queue:
            x, y = queue.popleft()
            for dx, dy in offsets:
                nxt = (x + dx, y + dy)
                if nxt in remaining:
                    remaining.remove(nxt)
                    part.add(nxt)
                    queue.append(nxt)
        result.append(part)
    return result


def touches4(first: set[Point], second: set[Point]) -> bool:
    return bool(first & second) or any((x + dx, y + dy) in second for x, y in first for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))


def audit_candidate(key: str, built: BuiltCandidate) -> dict[str, object]:
    image = built.image
    if image.size != (FRAME, FRAME):
        raise AssertionError(f"{key}: size drift")
    for pixel in image.getdata():
        if pixel not in PALETTE:
            raise AssertionError(f"{key}: color outside fixed palette: {pixel}")
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{key}: non-binary alpha")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{key}: dirty transparent RGB")
    points = visible(image)
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{key}: empty candidate")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if width > 36 or height > 27 or bbox[3] != BASELINE_BOTTOM:
        raise AssertionError(f"{key}: move bbox/baseline contract failed: {bbox}")
    if len(components(points)) != 1:
        raise AssertionError(f"{key}: character is not one 8-connected component")
    if min(x for x, _ in built.body) + max(x for x, _ in built.body) != 47:
        raise AssertionError(f"{key}: body core is not centered on x=24 registration")
    body_bbox = [min(x for x, _ in built.body), min(y for _, y in built.body), max(x for x, _ in built.body) + 1, max(y for _, y in built.body) + 1]
    body_size = [body_bbox[2] - body_bbox[0], body_bbox[3] - body_bbox[1]]
    if not (20 <= body_size[0] <= 24 and 17 <= body_size[1] <= 22):
        raise AssertionError(f"{key}: body core size drift: {body_size}")
    for name, semantic in (
        ("free_arm", built.free_arm), ("weapon_arm", built.weapon_arm),
        ("left_leg", built.left_leg), ("right_leg", built.right_leg),
    ):
        if not semantic <= points or not touches4(semantic, built.body):
            raise AssertionError(f"{key}: disconnected or missing {name}")
    if not any(y == 35 for _, y in built.left_leg) or not any(y == 35 for _, y in built.right_leg):
        raise AssertionError(f"{key}: both feet must touch y=35")
    if len(components(built.sword)) != 1 or not touches4(built.sword, built.weapon_arm):
        raise AssertionError(f"{key}: paper sword is detached or fragmented")
    sword_length = math.dist(*built.sword_endpoints)
    if not (14.0 <= sword_length <= 16.0) or not (34 <= len(built.sword) <= 70):
        raise AssertionError(f"{key}: sword size drift: length={sword_length}, pixels={len(built.sword)}")
    if max(x for x, _ in built.sword) <= max(x for x, _ in built.weapon_arm):
        raise AssertionError(f"{key}: sword is not visibly in front of right-facing hand")
    if len(built.eyes) != 4 or len(components(built.eyes, diagonal=False)) != 2:
        raise AssertionError(f"{key}: eyes must be two separate 1x2 holes")
    for part in components(built.eyes, diagonal=False):
        if len(part) != 2 or len({x for x, _ in part}) != 1:
            raise AssertionError(f"{key}: eye shape drift")
    eye_bottom = max(y for _, y in built.eyes)
    forbidden_face_colors = {EYE_DARK, DEEP_BROWN, PAPER_EDGE}
    central_lower_face = {
        (x, y) for x in range(CENTER_X - 6, CENTER_X + 6)
        for y in range(eye_bottom + 2, max(y for _, y in built.body))
        if (x, y) in built.body
    }
    if any(image.getpixel(point) in forbidden_face_colors for point in central_lower_face):
        raise AssertionError(f"{key}: lower-face mark could read as a mouth")
    body_roi = {(x, y) for x in range(BODY_RECT[0], BODY_RECT[2]) for y in range(BODY_RECT[1], BODY_RECT[3])}
    coverage = len(body_roi & built.body) / len(body_roi)
    if coverage < 0.90:
        raise AssertionError(f"{key}: collision/body coverage too low: {coverage}")
    top_y = min(y for _, y in built.body)
    top_body_x = sorted(x for x, y in built.body if y == top_y)
    if top_body_x != list(range(min(top_body_x), max(top_body_x) + 1)):
        raise AssertionError(f"{key}: top edge is not a single flat line")
    if any(y < top_y for _, y in built.body):
        raise AssertionError(f"{key}: visible top plane is forbidden")
    return {
        "bbox": list(bbox), "visible_size": [width, height], "body_bbox": body_bbox,
        "body_size": body_size, "opaque_pixels": len(points), "components_8": 1,
        "registered_center_x": CENTER_X, "baseline_bottom_exclusive": BASELINE_BOTTOM,
        "body_collision_coverage": round(coverage, 4), "sword_pixel_count": len(built.sword),
        "sword_endpoint_distance": round(sword_length, 4), "sword_connected_to_hand": True,
        "sword_in_front_for_right_facing": True, "eye_holes": 2, "mouth_pixels": 0,
        "red_or_orange_accent_pixels": 0, "visible_top_plane": False,
        "flat_bright_top_edge": True, "rgba_sha256": rgba_sha(image),
    }


def load_transparent_reference(raw_path: Path, transparent_path: Path) -> Image.Image:
    alpha_source = transparent_path if transparent_path.is_file() else raw_path
    with Image.open(alpha_source) as opened:
        image = opened.convert("RGBA")
    alpha_min, alpha_max = image.getchannel("A").getextrema()
    if alpha_min == 255:
        raise AssertionError(
            f"{rel(alpha_source)} has no transparent Alpha pixels; "
            "provide a native-transparent ImageGen source or a pre-existing, "
            "approved matching Alpha derivative"
        )
    if alpha_max == 0:
        raise AssertionError(f"{rel(alpha_source)} is fully transparent")
    return image


def nearest(image: Image.Image, scale: int) -> Image.Image:
    return image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)


def on_bg(image: Image.Image, bg: Color = REVIEW_BG) -> Image.Image:
    canvas = Image.new("RGBA", image.size, bg)
    canvas.alpha_composite(image)
    return canvas


def silhouette(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, TRANSPARENT)
    put_points(result, visible(image), (241, 238, 223, 255))
    return result


def fan_polygon(center: tuple[float, float], direction: float) -> list[tuple[float, float]]:
    half = math.radians(FAN_ANGLE / 2.0)
    outer = [
        (center[0] + math.cos(direction - half + (2 * half * index / FAN_SEGMENTS)) * FAN_OUTER,
         center[1] + math.sin(direction - half + (2 * half * index / FAN_SEGMENTS)) * FAN_OUTER)
        for index in range(FAN_SEGMENTS + 1)
    ]
    inner = [
        (center[0] + math.cos(direction - half + (2 * half * index / FAN_SEGMENTS)) * FAN_INNER,
         center[1] + math.sin(direction - half + (2 * half * index / FAN_SEGMENTS)) * FAN_INNER)
        for index in reversed(range(FAN_SEGMENTS + 1))
    ]
    return outer + inner


def collision_overlay(image: Image.Image) -> Image.Image:
    logical_w, logical_h, scale = 64, 48, 10
    single = Image.new("RGBA", (logical_w * scale, logical_h * scale), REVIEW_BG)
    result = Image.new("RGBA", (logical_w * scale * 2, logical_h * scale), REVIEW_BG)
    for index, facing_left in enumerate((False, True)):
        panel = single.copy()
        sprite = ImageOps.mirror(image) if facing_left else image
        panel.alpha_composite(nearest(sprite, scale), (8 * scale, 0))
        draw = ImageDraw.Draw(panel, "RGBA")
        origin = (32.0, 24.0)
        direction = math.pi if facing_left else 0.0
        polygon = [(x * scale, y * scale) for x, y in fan_polygon(origin, direction)]
        draw.polygon(polygon, fill=(255, 190, 78, 54), outline=FAN_COLOR)
        left, top, right, bottom = BODY_RECT
        left += 8
        right += 8
        draw.rectangle((left * scale, top * scale, right * scale, bottom * scale), outline=BODY_COLOR, width=3)
        draw.ellipse((origin[0] * scale - 3, origin[1] * scale - 3, origin[0] * scale + 3, origin[1] * scale + 3), fill=(255, 255, 255, 255))
        draw.line((0, BASELINE_BOTTOM * scale, logical_w * scale, BASELINE_BOTTOM * scale), fill=BASELINE_COLOR, width=2)
        result.alpha_composite(panel, (index * logical_w * scale, 0))
    return result


def exact_palette(frames: list[Image.Image]) -> tuple[list[tuple[int, int, int]], dict[tuple[int, int, int], int]]:
    colors: list[tuple[int, int, int]] = []
    for frame in frames:
        for color in frame.convert("RGB").getdata():
            if color not in colors:
                colors.append(color)
    if len(colors) > 256:
        raise AssertionError("Exact GIF palette overflow")
    return colors, {color: index for index, color in enumerate(colors)}


def palettize(image: Image.Image, colors: list[tuple[int, int, int]], indices: dict[tuple[int, int, int], int]) -> Image.Image:
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    result.putpalette(palette)
    result.putdata([indices[color] for color in rgb.getdata()])
    return result


def save_facing_gif(image: Image.Image, path: Path) -> dict[str, object]:
    ensure_preview_path(path)
    expected = [nearest(on_bg(image), 12).convert("RGB"), nearest(on_bg(ImageOps.mirror(image)), 12).convert("RGB")]
    colors, indices = exact_palette(expected)
    frames = [palettize(frame, colors, indices) for frame in expected]
    path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=[650, 650], loop=0, disposal=2, optimize=False)
    decoded = [frame.convert("RGB").copy() for frame in ImageSequence.Iterator(Image.open(path))]
    if len(decoded) != 2 or any(a.tobytes() != b.tobytes() for a, b in zip(decoded, expected, strict=True)):
        raise AssertionError(f"Facing GIF decode mismatch: {path}")
    return {"path": rel(path), "sha256": sha256(path), "frames": 2, "duration_ms": [650, 650], "exact_decode": True}


def font(size: int) -> ImageFont.ImageFont:
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/simhei.ttf")):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    result = image.copy()
    result.thumbnail(size, Image.Resampling.NEAREST)
    return result


def paste_center(canvas: Image.Image, image: Image.Image, box: tuple[int, int, int, int]) -> None:
    left, top, right, bottom = box
    canvas.alpha_composite(image, (left + (right - left - image.width) // 2, top + (bottom - top - image.height) // 2))


def align_to_world_frame(image: Image.Image, target_size: tuple[int, int] | None = None) -> Image.Image:
    frame = image.convert("RGBA")
    if target_size is not None:
        frame = frame.resize(target_size, Image.Resampling.NEAREST)
    bbox = frame.getchannel("A").getbbox()
    result = Image.new("RGBA", (48, 48), TRANSPARENT)
    if bbox is None:
        return result
    crop = frame.crop(bbox)
    target_x = CENTER_X - crop.width // 2
    target_y = BASELINE_BOTTOM - crop.height
    result.alpha_composite(crop, (target_x, target_y))
    return result


def size_comparison(candidate: Image.Image, key: str) -> tuple[Image.Image, dict[str, object]]:
    regular_path = REFERENCE_PATHS["approved_regular_anchor"]
    capoo_path = ROOT / "resources/texture/enemy/capoo/capoo_swordsman.png"
    golem_path = ROOT / "resources/texture/enemy/artificial_creation/stone_golem.png"
    regular = align_to_world_frame(Image.open(regular_path))
    capoo = align_to_world_frame(Image.open(capoo_path).convert("RGBA").crop((0, 0, 96, 96)), (30, 30))
    golem = align_to_world_frame(Image.open(golem_path).convert("RGBA").crop((0, 0, 64, 64)))
    refs = [("普通纸箱怪", regular), ("剑客Capoo×0.31", capoo), ("石头人", golem), (key.upper(), candidate)]
    scale, cell_w = 7, 360
    canvas = Image.new("RGBA", (cell_w * len(refs), 420), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    for index, (label, frame) in enumerate(refs):
        base_x = index * cell_w
        rendered = nearest(on_bg(frame), scale)
        canvas.alpha_composite(rendered, (base_x + (cell_w - rendered.width) // 2, 28))
        draw.line((base_x + 8, 28 + BASELINE_BOTTOM * scale, base_x + cell_w - 8, 28 + BASELINE_BOTTOM * scale), fill=BASELINE_COLOR, width=2)
        draw.text((base_x + 18, 374), label, fill=REVIEW_TEXT, font=font(19))
    sources = {
        "regular_cardboard": {"path": rel(regular_path), "sha256": sha256(regular_path)},
        "capoo": {"path": rel(capoo_path), "sha256": sha256(capoo_path), "world_scale": 0.31},
        "stone_golem": {"path": rel(golem_path), "sha256": sha256(golem_path)},
        "baseline_bottom_exclusive": BASELINE_BOTTOM,
    }
    return canvas, sources


def review_panel(spec: CandidateSpec, raw_crop: Image.Image, native: Image.Image, overlay: Image.Image, comparison: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (1920, 1160), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    draw.text((32, 18), f"大纸箱怪第一门 — {spec.title}", fill=REVIEW_TEXT, font=font(34))
    draw.text((32, 68), spec.summary, fill=REVIEW_MUTED, font=font(20))
    boxes = ((24, 136, 460, 730), (484, 136, 920, 730), (944, 136, 1380, 730), (1404, 136, 1896, 730))
    labels = ("ImageGen结构原稿（仅参考）", "48px显式点表重建 ×9", "Alpha轮廓 ×9", "左右身体/6→24px扇形")
    images = (fit(raw_crop, (408, 550)), nearest(on_bg(native), 9), nearest(on_bg(silhouette(native)), 9), fit(overlay, (460, 550)))
    for box, label, item in zip(boxes, labels, images, strict=True):
        draw.text((box[0] + 4, 106), label, fill=REVIEW_TEXT, font=font(16))
        canvas.alpha_composite(Image.new("RGBA", (box[2] - box[0], box[3] - box[1]), REVIEW_PANEL), (box[0], box[1]))
        paste_center(canvas, item, box)
    draw.text((32, 752), "世界尺寸对照（统一中心 x=24 / 脚底 y=36）", fill=REVIEW_TEXT, font=font(18))
    paste_center(canvas, fit(comparison, (1840, 350)), (40, 792, 1880, 1146))
    return canvas


def file_record(path: Path) -> dict[str, object]:
    with Image.open(path) as image:
        return {"path": rel(path), "sha256": sha256(path), "size": list(image.size), "mode": image.mode}


def coordinate_certificate(built: BuiltCandidate) -> dict[str, list[list[int]]]:
    return {
        "body": sorted([list(point) for point in built.body]),
        "free_arm": sorted([list(point) for point in built.free_arm]),
        "weapon_arm": sorted([list(point) for point in built.weapon_arm]),
        "left_leg": sorted([list(point) for point in built.left_leg]),
        "right_leg": sorted([list(point) for point in built.right_leg]),
        "sword": sorted([list(point) for point in built.sword]),
        "eyes": sorted([list(point) for point in built.eyes]),
    }


def build_once(approved_selection: str | None) -> tuple[dict[str, object], dict[str, str]]:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for name, path in REFERENCE_PATHS.items():
        if not path.is_file():
            raise AssertionError(f"Missing locked reference {name}: {path}")
    candidates: dict[str, dict[str, object]] = {}
    built_candidates: dict[str, BuiltCandidate] = {}
    coordinate_tables: dict[str, object] = {}
    output_paths: list[Path] = []
    raw_records: dict[str, object] = {}
    comparison_sources: dict[str, object] | None = None

    for spec in SPECS:
        raw_path = SOURCE_DIR / f"cardboard_monster_large_anchor_{spec.key}_imagegen.png"
        expected_sha = RAW_SHA256[spec.key]
        if not raw_path.is_file() or sha256(raw_path) != expected_sha:
            raise AssertionError(f"{spec.key}: raw ImageGen SHA drift, expected {expected_sha}")
        raw = Image.open(raw_path).convert("RGBA")
        raw_records[spec.key] = {**file_record(raw_path), "analysis": analyze_image(raw)}
        transparent_path = SOURCE_DIR / f"cardboard_monster_large_anchor_{spec.key}_transparent_reference.png"
        crop_path = SOURCE_DIR / f"cardboard_monster_large_anchor_{spec.key}_crop_tool.png"
        transparent = load_transparent_reference(raw_path, transparent_path)
        crop = crop_to_square(transparent, padding=36, align_to_grid=False)
        save_png(transparent, transparent_path)
        save_png(crop, crop_path)

        built = BUILDERS[spec.key]()
        built_candidates[spec.key] = built
        metrics = audit_candidate(spec.key, built)
        native_path = SOURCE_DIR / f"cardboard_monster_large_anchor_{spec.key}_native48.png"
        preview_path = PREVIEW_DIR / f"cardboard_monster_large_anchor_{spec.key}_16x.png"
        silhouette_path = PREVIEW_DIR / f"cardboard_monster_large_anchor_{spec.key}_silhouette_16x.png"
        facing_path = PREVIEW_DIR / f"cardboard_monster_large_anchor_{spec.key}_facing.gif"
        overlay_path = PREVIEW_DIR / f"cardboard_monster_large_anchor_{spec.key}_collision_fan_overlay.png"
        comparison_path = PREVIEW_DIR / f"cardboard_monster_large_anchor_{spec.key}_size_comparison.png"
        panel_path = PREVIEW_DIR / f"cardboard_monster_large_anchor_{spec.key}_review_panel.png"
        overlay_image = collision_overlay(built.image)
        comparison_image, current_sources = size_comparison(built.image, spec.key)
        comparison_sources = current_sources
        save_png(built.image, native_path)
        save_png(nearest(on_bg(built.image), 16), preview_path)
        save_png(nearest(on_bg(silhouette(built.image)), 16), silhouette_path)
        facing = save_facing_gif(built.image, facing_path)
        save_png(overlay_image, overlay_path)
        save_png(comparison_image, comparison_path)
        save_png(review_panel(spec, crop, built.image, overlay_image, comparison_image), panel_path)
        output_paths.extend([transparent_path, crop_path, native_path, preview_path, silhouette_path, facing_path, overlay_path, comparison_path, panel_path])
        coordinate_tables[spec.key] = coordinate_certificate(built)
        candidates[spec.key] = {
            "title": spec.title, "summary": spec.summary,
            "imagegen_source": raw_records[spec.key],
            "transparent_reference": file_record(transparent_path),
            "pixel_crop_tool_reference": {
                **file_record(crop_path), "analysis": analyze_image(crop),
                "unsafe_for_direct_resize": True, "pixels_imported_into_native": False,
            },
            "native48": {**file_record(native_path), "rgba_sha256": rgba_sha(built.image)},
            "integer_16x": file_record(preview_path), "silhouette_16x": file_record(silhouette_path),
            "facing_gif": facing, "collision_fan_overlay": file_record(overlay_path),
            "size_comparison": file_record(comparison_path), "review_panel": file_record(panel_path),
            "metrics": metrics,
        }

    if len({candidates[key]["native48"]["rgba_sha256"] for key in candidates}) != 3:
        raise AssertionError("The three native candidate sprites must be distinct")
    approved_anchor: dict[str, object] | None = None
    if approved_selection is not None:
        if approved_selection not in VALID_SELECTIONS:
            raise AssertionError(f"Unknown approved anchor selection: {approved_selection}")
        chosen = built_candidates[approved_selection]
        approved_native_path = SOURCE_DIR / "cardboard_monster_large_anchor_approved_native48.png"
        approved_preview_path = PREVIEW_DIR / "cardboard_monster_large_anchor_approved_16x.png"
        approved_gif_path = PREVIEW_DIR / "cardboard_monster_large_anchor_approved_facing.gif"
        approved_overlay_path = PREVIEW_DIR / "cardboard_monster_large_anchor_approved_collision_fan_overlay.png"
        save_png(chosen.image, approved_native_path)
        save_png(nearest(on_bg(chosen.image), 16), approved_preview_path)
        approved_facing = save_facing_gif(chosen.image, approved_gif_path)
        save_png(collision_overlay(chosen.image), approved_overlay_path)
        output_paths.extend([approved_native_path, approved_preview_path, approved_gif_path, approved_overlay_path])
        approved_anchor = {
            "selection": approved_selection,
            "native48": {**file_record(approved_native_path), "rgba_sha256": rgba_sha(chosen.image)},
            "integer_16x": file_record(approved_preview_path),
            "facing_gif": approved_facing,
            "collision_fan_overlay": file_record(approved_overlay_path),
            "user_adjustments": {
                "identity": "direct_scaled_regular_cardboard_family",
                "paper_sword_pose": "diagonal_forward_for_current_facing",
                "paper_sword_has_point_and_guard": True,
                "visible_top_plane": False,
                "bright_flat_top_edge": True,
            },
        }
    palette_payload = json.dumps([list(color) for color in PALETTE], separators=(",", ":")).encode("utf-8")
    coordinate_payload = json.dumps(coordinate_tables, sort_keys=True, separators=(",", ":")).encode("utf-8")
    builder_path = Path(__file__).resolve()
    report = {
        "asset": "cardboard_monster_large_anchor_candidates",
        "stage": "first_human_gate_approved" if approved_selection else "anchor_candidates_pending_first_human_gate",
        "approved_selection": approved_selection, "first_human_approved": approved_selection is not None, "preview_only": True,
        "runtime_written": False, "runtime_paths_written": [], "imagegen_pixels_imported": False,
        "builder": {"path": rel(builder_path), "sha256": sha256(builder_path)},
        "raw_sha256": RAW_SHA256,
        "references": {name: {"path": rel(path), "sha256": sha256(path)} for name, path in REFERENCE_PATHS.items()},
        "palette": [list(color) for color in PALETTE], "palette_sha256": bytes_sha(palette_payload),
        "coordinate_table_sha256": bytes_sha(coordinate_payload), "coordinate_certificate": coordinate_tables,
        "approved_anchor": approved_anchor,
        "contract": {
            "frame_size": [48, 48], "registered_center_x": CENTER_X,
            "baseline_bottom_exclusive": BASELINE_BOTTOM, "max_move_visible_size": [36, 27],
            "max_attack_or_death_visible_size": [44, 32], "body_core_target_size": [22, 19],
            "paper_sword_length_pixels": [14, 16], "paper_sword_thickness_pixels": 3,
            "binary_alpha": True, "transparent_rgb_zero": True,
            "body_collision_rect_pixels": list(BODY_RECT),
            "body_collision_world": {"size": [20, 18], "position": [0, -1]},
            "fan": {"center": list(FAN_CENTER), "inner_radius": FAN_INNER, "outer_radius": FAN_OUTER, "angle_degrees": FAN_ANGLE, "segments": FAN_SEGMENTS},
            "paper_sword_visual_only": True, "paper_sword_runtime_rotation": False,
            "flat_front_face": True, "visible_top_plane": False, "bright_top_edge": True,
            "imagegen_structural_reference_only": True, "no_imagegen_pixels_in_native": True,
        },
        "size_comparison_sources": comparison_sources,
        "candidates": candidates,
    }
    report_path = enemy_asset_report_path("cardboard_monster_large_anchor_report.json")
    ensure_preview_path(report_path)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest = {
        "asset": "cardboard_monster_large", "stage": report["stage"],
        "approved_selection": approved_selection, "first_human_approved": approved_selection is not None, "preview_only": True,
        "runtime_written": False, "runtime_paths_written": [], "imagegen_pixels_imported": False,
        "builder": report["builder"], "raw_sha256": RAW_SHA256,
        "palette_sha256": report["palette_sha256"], "coordinate_table_sha256": report["coordinate_table_sha256"],
        "approved_anchor": approved_anchor,
        "report": {"path": rel(report_path), "sha256": sha256(report_path)},
        "stability_proof_path": rel(enemy_asset_report_path("cardboard_monster_large_anchor_stability.json")),
    }
    manifest_path = enemy_asset_report_path("cardboard_monster_large_anchor_manifest.json")
    ensure_preview_path(manifest_path)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output_paths.extend([report_path, manifest_path])
    snapshot = {rel(path): sha256(path) for path in sorted(output_paths)}
    return report, snapshot


def preserved_selection(requested: str | None) -> str | None:
    if requested is not None:
        return requested
    manifest_path = enemy_asset_report_path("cardboard_monster_large_anchor_manifest.json")
    if not manifest_path.is_file():
        return None
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    selection = manifest.get("approved_selection")
    if manifest.get("first_human_approved") is True and selection in VALID_SELECTIONS:
        return str(selection)
    return None


def build(requested_selection: str | None = None) -> dict[str, object]:
    approved_selection = preserved_selection(requested_selection)
    first_report, first_snapshot = build_once(approved_selection)
    second_report, second_snapshot = build_once(approved_selection)
    if first_report != second_report or first_snapshot != second_snapshot:
        changed = sorted(key for key in set(first_snapshot) | set(second_snapshot) if first_snapshot.get(key) != second_snapshot.get(key))
        raise AssertionError(f"Two-pass large-cardboard anchor build drifted: {changed}")
    stability_path = enemy_asset_report_path("cardboard_monster_large_anchor_stability.json")
    ensure_preview_path(stability_path)
    stability = {
        "asset": "cardboard_monster_large_anchor_candidates",
        "stage": "first_human_gate_approved" if approved_selection else "anchor_candidates_pending_first_human_gate",
        "builder_sha256": sha256(Path(__file__).resolve()), "passes": 2, "drift_count": 0,
        "snapshot_scope_count": len(first_snapshot),
        "snapshot_exclusions": {
            rel(stability_path): "self-referential certificate written after the two-pass snapshot; its final SHA is locked externally by the build result"
        },
        "first_snapshot": first_snapshot, "second_snapshot": second_snapshot,
        "report_sha256": first_snapshot[rel(enemy_asset_report_path("cardboard_monster_large_anchor_report.json"))],
        "manifest_sha256": first_snapshot[rel(enemy_asset_report_path("cardboard_monster_large_anchor_manifest.json"))],
        "approved_selection": approved_selection, "first_human_approved": approved_selection is not None, "preview_only": True,
        "runtime_written": False, "runtime_paths_written": [],
    }
    stability_path.write_text(json.dumps(stability, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    result = {
        "marker": "CARDBOARD_MONSTER_LARGE_ANCHOR_PREVIEW_OK",
        "report": rel(enemy_asset_report_path("cardboard_monster_large_anchor_report.json")),
        "report_sha256": stability["report_sha256"],
        "manifest": rel(enemy_asset_report_path("cardboard_monster_large_anchor_manifest.json")),
        "manifest_sha256": stability["manifest_sha256"],
        "stability": {"path": rel(stability_path), "sha256": sha256(stability_path), "passes": 2, "drift_count": 0},
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approve", choices=sorted(VALID_SELECTIONS), help="Record the approved first-gate anchor selection.")
    arguments = parser.parse_args()
    build(arguments.approve)
