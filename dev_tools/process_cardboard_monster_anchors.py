#!/usr/bin/env python3
"""Build preview-only first-gate anchors for the cardboard monster.

The three ImageGen files are structural references only.  Every native 32px
candidate below is reconstructed from a fixed palette and explicit masks; no
generated source pixel is sampled into the native art.
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

from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "cardboard_monster"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"

RAW_SHA256 = {
    "f1": "6f41e87ef425392ae5d2ab0852194f8a9e7cfb7f3a2e558e51e5c3fe2eddd7f1",
    "f2": "08f085fa69243c8fa75511c8ca1e0dd5e81f9c4213ae88c711f7bb737c794ff2",
    "f3": "11ad0796fe27562258046475934098d5bdc1027c11dbda549a8b227fd8a38524",
}

REFERENCE_SHA256 = {
    "pale_parcel_icon": "1658e415a72e73e5141061f01ed760d8f1a25849a51d3e43075b0c01f23bd0cf",
    "in_game_cardboard_boxes": "1308085a4a8b64f5f847fcafcf3f8281eb4cb496bb8cdfa4a32c236c3eac598a",
}

FRAME = 32
BASELINE_BOTTOM = 28
CENTER_X = 16
BODY_RECT = (9, 12, 23, 24)
FAN_CENTER = (16, 16)
FAN_INNER = 5.0
FAN_OUTER = 16.0
FAN_ANGLE = 45.0

TRANSPARENT = (0, 0, 0, 0)
OUTLINE = (116, 87, 61, 255)
DEEP_BROWN = (88, 64, 45, 255)
LIMB_BROWN = (123, 87, 55, 255)
KRAFT_DARK = (177, 145, 102, 255)
KRAFT_MID = (210, 181, 137, 255)
KRAFT_LIGHT = (232, 213, 177, 255)
FOLD_HIGHLIGHT = (245, 234, 208, 255)
PAPER_EDGE = (154, 117, 78, 255)
PAPER_STICK = (225, 202, 159, 255)
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
    PAPER_STICK,
    EYE_DARK,
)

REVIEW_BG = (14, 20, 29, 255)
REVIEW_PANEL = (23, 33, 46, 255)
REVIEW_TEXT = (235, 236, 232, 255)
REVIEW_MUTED = (164, 174, 177, 255)
BODY_COLOR = (61, 209, 235, 255)
FAN_COLOR = (255, 190, 78, 255)


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
    stick: set[Point]
    stick_endpoints: tuple[Point, Point]
    eye: set[Point]
    tape: set[Point]


SPECS = (
    CandidateSpec("f1", "F1 原型方箱", "最贴近游戏实物：浅牛皮纸近方盒、正面双孔眼、弱透视。"),
    CandidateSpec("f2", "F2 矮方纸包", "略矮略宽、眼孔略低；平直亮顶边与右上斜持纸棒。"),
    CandidateSpec("f3", "F3 高方纸包", "略高略窄、眼孔稍高、极淡折痕与斜护纸棒。"),
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
    return path.relative_to(ROOT).as_posix()


def ensure_preview_path(path: Path) -> None:
    resolved = path.resolve()
    if not (
        resolved.is_relative_to(SOURCE_DIR.resolve())
        or resolved.is_relative_to(PREVIEW_DIR.resolve())
    ):
        raise AssertionError(f"Refusing non-preview output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_preview_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def put(image: Image.Image, point: Point, color: Color) -> None:
    x, y = point
    if not (0 <= x < FRAME and 0 <= y < FRAME):
        raise AssertionError(f"Point outside native frame: {point}")
    image.putpixel(point, color)


def put_points(image: Image.Image, points: set[Point] | list[Point] | tuple[Point, ...], color: Color) -> None:
    for point in points:
        put(image, point, color)


def row_points(rows: dict[int, tuple[int, int] | tuple[tuple[int, int], ...]]) -> set[Point]:
    result: set[Point] = set()
    for y, runs in rows.items():
        normalized = (runs,) if isinstance(runs[0], int) else runs
        for left, right in normalized:
            result.update((x, y) for x in range(left, right + 1))
    return result


def paint_body(image: Image.Image, mask: set[Point]) -> None:
    for point in mask:
        x, y = point
        boundary = any((x + dx, y + dy) not in mask for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))
        put(image, point, OUTLINE if boundary else KRAFT_MID)


def set_if_body(image: Image.Image, body: set[Point], points: dict[Point, Color]) -> None:
    for point, color in points.items():
        if point not in body:
            raise AssertionError(f"Authored surface point is outside body: {point}")
        put(image, point, color)


def build_f1() -> BuiltCandidate:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = row_points({10: (11, 20), 11: (9, 22), **{y: (9, 22) for y in range(12, 25)}})
    paint_body(image, body)
    set_if_body(image, body, {
        **{(x, 10): FOLD_HIGHLIGHT for x in range(12, 20)},
        **{(x, 11): KRAFT_LIGHT for x in range(10, 21)},
        **{(21, y): KRAFT_DARK for y in range(12, 24)},
        (10, 12): KRAFT_LIGHT,
        (10, 22): PAPER_EDGE,
    })
    eye = {(13, 15), (13, 16), (18, 15), (18, 16)}
    put_points(image, eye, EYE_DARK)

    free_arm = {(9, 19), (8, 19), (8, 20), (7, 20), (7, 21), (8, 21)}
    weapon_arm = {(22, 19), (23, 19), (23, 20)}
    left_leg = {(12, 24), (12, 25), (11, 26), (11, 27), (10, 27)}
    right_leg = {(19, 24), (19, 25), (20, 26), (20, 27), (21, 27)}
    put_points(image, free_arm | weapon_arm | left_leg | right_leg, LIMB_BROWN)
    put_points(image, {(7, 21), (8, 21), (23, 19), (23, 20), (10, 27), (21, 27)}, DEEP_BROWN)

    centerline = [(23, 19), (24, 18), (25, 17), (26, 16), (27, 15), (28, 14), (29, 13), (30, 12)]
    stick = set(centerline) | {(x, y - 1) for x, y in centerline}
    put_points(image, stick, PAPER_STICK)
    put_points(image, centerline, PAPER_EDGE)
    put_points(image, {(29, 12), (29, 11), (30, 11)}, FOLD_HIGHLIGHT)
    return BuiltCandidate(image, body, free_arm, weapon_arm, left_leg, right_leg, stick, ((23, 19), (30, 12)), eye, set())


def build_f2() -> BuiltCandidate:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = row_points({y: (8, 23) for y in range(12, 25)})
    paint_body(image, body)
    set_if_body(image, body, {
        **{(x, 12): FOLD_HIGHLIGHT for x in range(9, 23)},
        **{(x, 13): KRAFT_LIGHT for x in range(9, 22)},
        **{(22, y): KRAFT_DARK for y in range(14, 24)},
        (9, 14): KRAFT_MID,
    })
    eye = {(13, 17), (13, 18), (17, 17), (17, 18)}
    put_points(image, eye, EYE_DARK)

    free_arm = {(8, 19), (7, 19), (7, 20), (7, 21), (8, 21)}
    weapon_arm = {(23, 20), (24, 20), (24, 21)}
    left_leg = {(12, 24), (12, 25), (11, 26), (11, 27), (10, 27)}
    right_leg = {(19, 24), (19, 25), (20, 26), (20, 27), (21, 27)}
    put_points(image, free_arm | weapon_arm | left_leg | right_leg, LIMB_BROWN)
    put_points(image, {(7, 21), (8, 21), (24, 20), (24, 21), (10, 27), (21, 27)}, DEEP_BROWN)

    centerline = [(23, 20), (24, 19), (25, 18), (26, 17), (27, 16), (28, 15), (29, 14), (30, 13)]
    stick = set(centerline) | {(x, y - 1) for x, y in centerline}
    put_points(image, stick, PAPER_STICK)
    put_points(image, centerline, PAPER_EDGE)
    put_points(image, {(29, 13), (29, 12), (30, 12)}, FOLD_HIGHLIGHT)
    put_points(image, weapon_arm, DEEP_BROWN)
    return BuiltCandidate(image, body, free_arm, weapon_arm, left_leg, right_leg, stick, ((23, 20), (30, 13)), eye, set())


def build_f3() -> BuiltCandidate:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = row_points({8: (12, 19), 9: (10, 21), **{y: (10, 21) for y in range(10, 25)}})
    paint_body(image, body)
    set_if_body(image, body, {
        **{(x, 8): FOLD_HIGHLIGHT for x in range(13, 19)},
        **{(x, 9): KRAFT_LIGHT for x in range(11, 20)},
        **{(20, y): KRAFT_DARK for y in range(10, 24)},
        (11, 10): KRAFT_LIGHT,
    })
    eye = {(13, 13), (13, 14), (18, 13), (18, 14)}
    put_points(image, eye, EYE_DARK)

    free_arm = {(10, 18), (9, 18), (8, 17), (7, 17), (7, 16)}
    weapon_arm = {(21, 19), (22, 19), (22, 20), (23, 20)}
    left_leg = {(13, 24), (13, 25), (12, 26), (12, 27), (11, 27)}
    right_leg = {(18, 24), (18, 25), (19, 26), (19, 27), (20, 27)}
    put_points(image, free_arm | weapon_arm | left_leg | right_leg, LIMB_BROWN)
    put_points(image, {(7, 16), (7, 17), (23, 20), (11, 27), (20, 27)}, DEEP_BROWN)

    centerline = [(22, 20), (23, 19), (24, 18), (25, 17), (26, 16), (27, 15), (28, 14), (29, 13)]
    stick = set(centerline) | {(x, y - 1) for x, y in centerline}
    put_points(image, stick, PAPER_STICK)
    put_points(image, centerline, PAPER_EDGE)
    put_points(image, {(28, 13), (28, 12), (29, 12)}, FOLD_HIGHLIGHT)
    return BuiltCandidate(image, body, free_arm, weapon_arm, left_leg, right_leg, stick, ((22, 20), (29, 13)), eye, set())


BUILDERS = {"f1": build_f1, "f2": build_f2, "f3": build_f3}


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
    return any((x + dx, y + dy) in second for x, y in first for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))


def audit_candidate(key: str, built: BuiltCandidate) -> dict[str, object]:
    image = built.image
    if image.size != (FRAME, FRAME):
        raise AssertionError(f"{key}: native size drift")
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
        raise AssertionError(f"{key}: empty sprite")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if width > 24 or height > 23 or bbox[3] != BASELINE_BOTTOM:
        raise AssertionError(f"{key}: bbox contract failed: {bbox}")
    if not (4 <= bbox[0] and bbox[2] <= 31 and 5 <= bbox[1]):
        raise AssertionError(f"{key}: unsafe frame padding: {bbox}")
    sizes = sorted((len(part) for part in components(points)), reverse=True)
    if sizes != [len(points)]:
        raise AssertionError(f"{key}: sprite is not one 8-connected component: {sizes}")
    for name, semantic in (
        ("free_arm", built.free_arm),
        ("weapon_arm", built.weapon_arm),
        ("left_leg", built.left_leg),
        ("right_leg", built.right_leg),
    ):
        if not semantic <= points:
            raise AssertionError(f"{key}: missing {name} pixels")
        if not touches4(semantic, built.body):
            raise AssertionError(f"{key}: {name} is not 4-connected to body")
    if not touches4(built.stick, built.weapon_arm) and not (built.stick & built.weapon_arm):
        raise AssertionError(f"{key}: stick is detached from weapon hand")
    if not any(y == 27 for _, y in built.left_leg) or not any(y == 27 for _, y in built.right_leg):
        raise AssertionError(f"{key}: both feet must touch baseline")
    start, end = built.stick_endpoints
    length = math.dist(start, end)
    if not (9.0 <= length <= 11.25):
        raise AssertionError(f"{key}: paper stick length drift: {length}")
    if len(built.stick) < 16 or len(built.stick) > 24:
        raise AssertionError(f"{key}: paper stick thickness/area drift: {len(built.stick)}")
    if len(components(built.stick, diagonal=False)) != 1:
        raise AssertionError(f"{key}: paper stick is not one 4-connected mask")
    body_roi = {(x, y) for x in range(BODY_RECT[0], BODY_RECT[2]) for y in range(BODY_RECT[1], BODY_RECT[3])}
    coverage = len(body_roi & built.body) / len(body_roi)
    if coverage < 0.85:
        raise AssertionError(f"{key}: body/collision coverage too low: {coverage}")
    if built.tape:
        raise AssertionError(f"{key}: final plain-box family must not contain tape")
    if len(built.eye) != 4 or len(components(built.eye, diagonal=False)) != 2:
        raise AssertionError(f"{key}: eyes must be two separate 1x2 hole masks")
    for eye_part in components(built.eye, diagonal=False):
        if len(eye_part) != 2 or len({x for x, _ in eye_part}) != 1:
            raise AssertionError(f"{key}: each eye hole must be a vertical 1x2 pair")
    if any(image.getpixel(point) != EYE_DARK for point in built.eye):
        raise AssertionError(f"{key}: eye holes must use neutral gray-brown only")
    eye_bottom = max(y for _, y in built.eye)
    mouth_like_colors = {EYE_DARK, DEEP_BROWN, PAPER_EDGE}
    central_lower_face = {
        (x, y)
        for x in range(CENTER_X - 5, CENTER_X + 4)
        for y in range(eye_bottom + 2, 24)
        if (x, y) in built.body
    }
    if any(image.getpixel(point) in mouth_like_colors for point in central_lower_face):
        raise AssertionError(f"{key}: isolated lower-face mark could read as a mouth")
    return {
        "bbox": list(bbox),
        "visible_size": [width, height],
        "opaque_pixels": len(points),
        "registered_center_x": CENTER_X,
        "baseline_bottom_exclusive": BASELINE_BOTTOM,
        "components_8": len(sizes),
        "body_collision_coverage": round(coverage, 4),
        "stick_pixel_count": len(built.stick),
        "stick_endpoint_distance": round(length, 4),
        "stick_connected_to_hand": True,
        "eye_holes": 2,
        "mouth_pixels": 0,
        "central_lower_face_marks": 0,
        "red_or_orange_accent_pixels": 0,
        "rgba_sha256": rgba_sha(image),
    }


def normalize_reference(raw: Image.Image) -> Image.Image:
    rgba = raw.convert("RGBA")
    result = Image.new("RGBA", rgba.size, TRANSPARENT)
    source = rgba.load()
    target = result.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source[x, y]
            if alpha <= 8 or (green >= max(red, blue) + 34 and green >= 115):
                continue
            if green > max(red, blue) + 8:
                green = max(red, blue)
            target[x, y] = (red, green, blue, 255)
    return result


def nearest(image: Image.Image, scale: int) -> Image.Image:
    return image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)


def on_bg(image: Image.Image, bg: Color = REVIEW_BG) -> Image.Image:
    canvas = Image.new("RGBA", image.size, bg)
    canvas.alpha_composite(image)
    return canvas


def silhouette(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, TRANSPARENT)
    for point in visible(image):
        result.putpixel(point, (241, 238, 223, 255))
    return result


def overlay(image: Image.Image) -> Image.Image:
    scale = 16
    canvas = nearest(on_bg(image), scale)
    draw = ImageDraw.Draw(canvas, "RGBA")
    left, top, right, bottom = BODY_RECT
    draw.rectangle((left * scale, top * scale, right * scale, bottom * scale), outline=BODY_COLOR, width=3)
    cx, cy = FAN_CENTER
    half = math.radians(FAN_ANGLE * 0.5)
    for radius in (FAN_INNER, FAN_OUTER):
        box = ((cx - radius) * scale, (cy - radius) * scale, (cx + radius) * scale, (cy + radius) * scale)
        draw.arc(box, start=-math.degrees(half), end=math.degrees(half), fill=FAN_COLOR, width=3)
    for angle in (-half, half):
        start = (cx + math.cos(angle) * FAN_INNER, cy + math.sin(angle) * FAN_INNER)
        end = (cx + math.cos(angle) * FAN_OUTER, cy + math.sin(angle) * FAN_OUTER)
        draw.line((start[0] * scale, start[1] * scale, end[0] * scale, end[1] * scale), fill=FAN_COLOR, width=3)
    draw.ellipse(((cx * scale) - 3, (cy * scale) - 3, (cx * scale) + 3, (cy * scale) + 3), fill=(255, 255, 255, 255))
    return canvas


def fixed_palette(frames: list[Image.Image]) -> tuple[list[tuple[int, int, int]], dict[tuple[int, int, int], int]]:
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
    expected = [nearest(on_bg(image), 16).convert("RGB"), nearest(on_bg(ImageOps.mirror(image)), 16).convert("RGB")]
    colors, indices = fixed_palette(expected)
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


def load_reference_frame(path: Path, crop: tuple[int, int, int, int], target_size: tuple[int, int] | None = None) -> Image.Image:
    frame = Image.open(path).convert("RGBA").crop(crop)
    if target_size is not None:
        frame = frame.resize(target_size, Image.Resampling.NEAREST)
    return frame


def size_comparison(candidate: Image.Image, key: str) -> Image.Image:
    refs = [
        ("源石虫", load_reference_frame(ROOT / "resources/texture/enemy/yuanshi_insect/源石虫.png", (0, 32, 32, 64))),
        ("史莱姆", load_reference_frame(ROOT / "resources/texture/enemy/slime/slime.png", (0, 0, 32, 32))),
        ("战斗机器人", load_reference_frame(ROOT / "resources/texture/enemy/mechanical_life/combat_robot.png", (0, 0, 32, 32))),
        ("剑客Capoo×0.31", load_reference_frame(ROOT / "resources/texture/enemy/capoo/capoo_swordsman.png", (0, 0, 96, 96), (30, 30))),
        (key.upper(), candidate),
    ]
    scale = 7
    cell_w = 240
    canvas = Image.new("RGBA", (cell_w * len(refs), 300), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    for index, (label, frame) in enumerate(refs):
        base_x = index * cell_w
        cell = Image.new("RGBA", (32, 32), TRANSPARENT)
        cell.alpha_composite(frame, ((32 - frame.width) // 2, 0 if frame.height == 32 else (32 - frame.height) // 2))
        rendered = nearest(on_bg(cell), scale)
        canvas.alpha_composite(rendered, (base_x + (cell_w - rendered.width) // 2, 42))
        draw.text((base_x + 12, 260), label, fill=REVIEW_TEXT, font=font(16))
    return canvas


def review_panel(spec: CandidateSpec, raw_crop: Image.Image, native: Image.Image, comparison: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (1760, 940), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    draw.text((28, 18), f"纸箱怪第一门 — {spec.title}", fill=REVIEW_TEXT, font=font(30))
    draw.text((28, 62), spec.summary, fill=REVIEW_MUTED, font=font(18))
    boxes = ((20, 120, 440, 700), (460, 120, 880, 700), (900, 120, 1320, 700), (1340, 120, 1740, 700))
    labels = ("ImageGen结构原稿（仅参考）", "32px确定性重建 ×12", "Alpha轮廓 ×12", "身体/扇形叠加")
    images = (fit(raw_crop, (390, 530)), nearest(on_bg(native), 12), nearest(on_bg(silhouette(native)), 12), fit(overlay(native), (390, 530)))
    for box, label, item in zip(boxes, labels, images, strict=True):
        draw.text((box[0] + 6, 92), label, fill=REVIEW_TEXT, font=font(15))
        panel = Image.new("RGBA", (box[2] - box[0], box[3] - box[1]), REVIEW_PANEL)
        canvas.alpha_composite(panel, (box[0], box[1]))
        paste_center(canvas, item, box)
    comp = fit(comparison, (1680, 190))
    paste_center(canvas, comp, (40, 730, 1720, 925))
    return canvas


def file_record(path: Path) -> dict[str, object]:
    with Image.open(path) as image:
        return {"path": rel(path), "sha256": sha256(path), "size": list(image.size), "mode": image.mode}


def build_once(approved_selection: str | None) -> tuple[dict[str, object], dict[str, object]]:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    reference_paths = {
        "pale_parcel_icon": SOURCE_DIR / "cardboard_monster_reference_icon.png",
        "in_game_cardboard_boxes": SOURCE_DIR / "cardboard_monster_reference_ingame_boxes.png",
    }
    for key, path in reference_paths.items():
        if not path.is_file() or sha256(path).lower() != REFERENCE_SHA256[key]:
            raise AssertionError(f"{key}: user reference SHA drift")
    candidates: dict[str, dict[str, object]] = {}
    built_candidates: dict[str, BuiltCandidate] = {}
    coordinate_certificate: dict[str, object] = {}
    output_paths: list[Path] = []

    for spec in SPECS:
        raw_path = SOURCE_DIR / f"cardboard_monster_anchor_{spec.key}_imagegen.png"
        if not raw_path.is_file() or sha256(raw_path) != RAW_SHA256[spec.key]:
            raise AssertionError(f"{spec.key}: raw ImageGen SHA drift")
        raw = Image.open(raw_path).convert("RGBA")
        transparent = normalize_reference(raw)
        if transparent.getchannel("A").getbbox() is None:
            raise AssertionError(f"{spec.key}: normalized reference is empty")
        transparent_path = SOURCE_DIR / f"cardboard_monster_anchor_{spec.key}_transparent_reference.png"
        crop = crop_to_square(transparent, padding=28, align_to_grid=False)
        crop_path = SOURCE_DIR / f"cardboard_monster_anchor_{spec.key}_crop_tool.png"
        save_png(transparent, transparent_path)
        save_png(crop, crop_path)

        built = BUILDERS[spec.key]()
        built_candidates[spec.key] = built
        metrics = audit_candidate(spec.key, built)
        native_path = SOURCE_DIR / f"cardboard_monster_anchor_{spec.key}_native32.png"
        preview_path = PREVIEW_DIR / f"cardboard_monster_anchor_{spec.key}_16x.png"
        silhouette_path = PREVIEW_DIR / f"cardboard_monster_anchor_{spec.key}_silhouette_16x.png"
        overlay_path = PREVIEW_DIR / f"cardboard_monster_anchor_{spec.key}_collision_fan_overlay.png"
        gif_path = PREVIEW_DIR / f"cardboard_monster_anchor_{spec.key}_facing.gif"
        comparison_path = PREVIEW_DIR / f"cardboard_monster_anchor_{spec.key}_size_comparison.png"
        panel_path = PREVIEW_DIR / f"cardboard_monster_anchor_{spec.key}_review_panel.png"

        comparison = size_comparison(built.image, spec.key)
        save_png(built.image, native_path)
        save_png(nearest(on_bg(built.image), 16), preview_path)
        save_png(nearest(on_bg(silhouette(built.image)), 16), silhouette_path)
        save_png(overlay(built.image), overlay_path)
        facing = save_facing_gif(built.image, gif_path)
        save_png(comparison, comparison_path)
        save_png(review_panel(spec, crop, built.image, comparison), panel_path)
        output_paths.extend([transparent_path, crop_path, native_path, preview_path, silhouette_path, overlay_path, gif_path, comparison_path, panel_path])

        coordinate_certificate[spec.key] = {
            "body": sorted([list(point) for point in built.body]),
            "free_arm": sorted([list(point) for point in built.free_arm]),
            "weapon_arm": sorted([list(point) for point in built.weapon_arm]),
            "left_leg": sorted([list(point) for point in built.left_leg]),
            "right_leg": sorted([list(point) for point in built.right_leg]),
            "stick": sorted([list(point) for point in built.stick]),
            "eye": sorted([list(point) for point in built.eye]),
            "tape": sorted([list(point) for point in built.tape]),
        }
        candidates[spec.key] = {
            "title": spec.title,
            "summary": spec.summary,
            "imagegen_source": file_record(raw_path),
            "transparent_reference": file_record(transparent_path),
            "pixel_crop_tool_reference": {
                **file_record(crop_path),
                "analysis": analyze_image(crop),
                "unsafe_for_direct_resize": True,
                "pixels_imported_into_native": False,
            },
            "native32": {**file_record(native_path), "rgba_sha256": rgba_sha(built.image)},
            "integer_16x": file_record(preview_path),
            "silhouette_16x": file_record(silhouette_path),
            "collision_fan_overlay": file_record(overlay_path),
            "facing_gif": facing,
            "size_comparison": file_record(comparison_path),
            "review_panel": file_record(panel_path),
            "metrics": metrics,
        }

    if len({candidates[key]["native32"]["rgba_sha256"] for key in candidates}) != 3:
        raise AssertionError("Candidate native sprites are not distinct")

    approved_anchor: dict[str, object] | None = None
    if approved_selection is not None:
        if approved_selection not in VALID_SELECTIONS:
            raise AssertionError(f"Unknown anchor selection: {approved_selection}")
        chosen = built_candidates[approved_selection]
        approved_native_path = SOURCE_DIR / "cardboard_monster_anchor_approved_native32.png"
        approved_preview_path = PREVIEW_DIR / "cardboard_monster_anchor_approved_16x.png"
        approved_gif_path = PREVIEW_DIR / "cardboard_monster_anchor_approved_facing.gif"
        approved_overlay_path = PREVIEW_DIR / "cardboard_monster_anchor_approved_collision_fan_overlay.png"
        save_png(chosen.image, approved_native_path)
        save_png(nearest(on_bg(chosen.image), 16), approved_preview_path)
        approved_facing = save_facing_gif(chosen.image, approved_gif_path)
        save_png(overlay(chosen.image), approved_overlay_path)
        output_paths.extend([approved_native_path, approved_preview_path, approved_gif_path, approved_overlay_path])
        approved_anchor = {
            "selection": approved_selection,
            "revision": "flat_bright_top_edge_and_diagonal_paper_stick" if approved_selection == "f2" else "selected_without_revision",
            "native32": {**file_record(approved_native_path), "rgba_sha256": rgba_sha(chosen.image)},
            "integer_16x": file_record(approved_preview_path),
            "facing_gif": approved_facing,
            "collision_fan_overlay": file_record(approved_overlay_path),
            "user_adjustments": {
                "visible_top_plane": False,
                "flat_top_silhouette": True,
                "bright_top_lighting_band": True,
                "paper_stick_pose": "diagonal_up_right",
                "paper_stick_runtime_rotation": False,
            },
        }

    builder_path = Path(__file__).resolve()
    palette_payload = json.dumps([list(color) for color in PALETTE], separators=(",", ":")).encode("utf-8")
    coordinate_payload = json.dumps(coordinate_certificate, sort_keys=True, separators=(",", ":")).encode("utf-8")
    report = {
        "asset": "cardboard_monster_anchor_candidates",
        "stage": "first_human_gate_approved" if approved_selection else "anchor_candidates_pending_first_human_gate",
        "approved_selection": approved_selection,
        "first_human_approved": approved_selection is not None,
        "preview_only": True,
        "runtime_written": False,
        "runtime_paths_written": [],
        "imagegen_pixels_imported": False,
        "stability_proof_path": "dev_assets/generated_previews/cardboard_monster_anchor_stability.json",
        "builder": {"path": rel(builder_path), "sha256": sha256(builder_path)},
        "raw_sha256": RAW_SHA256,
        "user_references": {
            key: {"path": rel(path), "sha256": REFERENCE_SHA256[key]}
            for key, path in reference_paths.items()
        },
        "palette": [list(color) for color in PALETTE],
        "palette_sha256": bytes_sha(palette_payload),
        "coordinate_table_sha256": bytes_sha(coordinate_payload),
        "coordinate_certificate": coordinate_certificate,
        "approved_anchor": approved_anchor,
        "contract": {
            "frame_size": [32, 32],
            "registered_center_x": CENTER_X,
            "baseline_bottom_exclusive": BASELINE_BOTTOM,
            "max_move_visible_size": [24, 23],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "body_collision_rect_pixels": list(BODY_RECT),
            "body_collision_world": {"size": [14, 12], "position": [0, 2]},
            "fan": {"center": list(FAN_CENTER), "inner_radius": FAN_INNER, "outer_radius": FAN_OUTER, "angle_degrees": FAN_ANGLE},
            "imagegen_structural_reference_only": True,
            "in_game_reference_has_priority": True,
            "plain_light_kraft_box_family": True,
            "neutral_gray_brown_eye_holes": True,
            "red_or_orange_accents": False,
            "no_imagegen_pixels_in_native": True,
            "paper_stick_visual_only": True,
        },
        "candidates": candidates,
    }
    report_path = PREVIEW_DIR / "cardboard_monster_anchor_report.json"
    ensure_preview_path(report_path)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output_paths.append(report_path)
    manifest = {
        "asset": "cardboard_monster",
        "stage": report["stage"],
        "approved_selection": approved_selection,
        "first_human_approved": approved_selection is not None,
        "runtime_written": False,
        "runtime_paths_written": [],
        "imagegen_pixels_imported": False,
        "stability_proof_path": report["stability_proof_path"],
        "builder": report["builder"],
        "raw_sha256": RAW_SHA256,
        "user_references": report["user_references"],
        "palette_sha256": report["palette_sha256"],
        "coordinate_table_sha256": report["coordinate_table_sha256"],
        "approved_anchor": approved_anchor,
        "report": {"path": rel(report_path), "sha256": sha256(report_path)},
    }
    manifest_path = SOURCE_DIR / "cardboard_monster_anchor_manifest.json"
    ensure_preview_path(manifest_path)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output_paths.append(manifest_path)
    result = {
        "marker": "CARDBOARD_MONSTER_ANCHOR_PREVIEW_OK",
        "report": rel(report_path),
        "report_sha256": sha256(report_path),
        "manifest": rel(manifest_path),
        "manifest_sha256": sha256(manifest_path),
        "outputs": {rel(path): sha256(path) for path in output_paths},
    }
    return report, result


def snapshot_outputs() -> dict[str, str]:
    paths = [
        SOURCE_DIR / "cardboard_monster_reference_icon.png",
        SOURCE_DIR / "cardboard_monster_reference_ingame_boxes.png",
        SOURCE_DIR / "cardboard_monster_anchor_approved_native32.png",
        SOURCE_DIR / "cardboard_monster_anchor_manifest.json",
        PREVIEW_DIR / "cardboard_monster_anchor_approved_16x.png",
        PREVIEW_DIR / "cardboard_monster_anchor_approved_facing.gif",
        PREVIEW_DIR / "cardboard_monster_anchor_approved_collision_fan_overlay.png",
        PREVIEW_DIR / "cardboard_monster_anchor_report.json",
    ]
    for spec in SPECS:
        paths.extend(SOURCE_DIR.glob(f"cardboard_monster_anchor_{spec.key}_*"))
        paths.extend(PREVIEW_DIR.glob(f"cardboard_monster_anchor_{spec.key}_*"))
    paths = [path for path in paths if path.is_file()]
    return {rel(path): sha256(path) for path in sorted(paths)}


def preserved_selection(requested: str | None) -> str | None:
    if requested is not None:
        return requested
    manifest_path = SOURCE_DIR / "cardboard_monster_anchor_manifest.json"
    if not manifest_path.is_file():
        return None
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    selection = manifest.get("approved_selection")
    if manifest.get("first_human_approved") is True and selection in VALID_SELECTIONS:
        return str(selection)
    return None


def build(requested_selection: str | None = None) -> dict[str, object]:
    approved_selection = preserved_selection(requested_selection)
    first_report, _ = build_once(approved_selection)
    first_snapshot = snapshot_outputs()
    second_report, result = build_once(approved_selection)
    second_snapshot = snapshot_outputs()
    if first_snapshot != second_snapshot:
        changed = sorted(
            key
            for key in set(first_snapshot) | set(second_snapshot)
            if first_snapshot.get(key) != second_snapshot.get(key)
        )
        raise AssertionError(f"Two-pass anchor rebuild drifted: {changed}")
    stability_path = PREVIEW_DIR / "cardboard_monster_anchor_stability.json"
    ensure_preview_path(stability_path)
    stability = {
        "asset": "cardboard_monster_anchor_candidates",
        "builder_sha256": sha256(Path(__file__).resolve()),
        "passes": 2,
        "drift_count": 0,
        "first_snapshot": first_snapshot,
        "second_snapshot": second_snapshot,
        "report_sha256": second_snapshot["dev_assets/generated_previews/cardboard_monster_anchor_report.json"],
        "manifest_sha256": second_snapshot["dev_assets/source_images/cardboard_monster/cardboard_monster_anchor_manifest.json"],
        "approved_selection": approved_selection,
        "runtime_written": False,
    }
    stability_path.write_text(json.dumps(stability, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    result["stability"] = {
        "path": rel(stability_path),
        "sha256": sha256(stability_path),
        "passes": 2,
        "drift_count": 0,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if first_report != second_report:
        raise AssertionError("In-memory two-pass reports differ")
    return second_report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approve", choices=sorted(VALID_SELECTIONS), help="Record the approved first-gate anchor selection.")
    arguments = parser.parse_args()
    build(arguments.approve)
