#!/usr/bin/env python3
"""Build preview-only anchor candidates for the elite combat-robot gunner.

The ordinary runtime gunner's move frame 0 is the immutable pixel source.
ImageGen files are retained only as visual-language references in the review
board; no generated pixel is sampled, resized, traced, or copied into a native
candidate.  Every native change is one of two deterministic operations:

* map an existing hostile red/orange functional pixel to the shared elite
  purple ramp without changing its alpha mask; or
* add a neutral-gray pixel from the explicit A1 body / G1-G3 attachment tables.

This script is deliberately runtime-safe.  It writes exclusively below
``dev_assets``.  By default it is preview-only; ``--approve`` is the explicit
human-gate operation which promotes one already-built native candidate to an
approved anchor and locks its byte/RGBA hashes.  It never writes runtime data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, normalize_source


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
SOURCE_DIR = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_gunner_elite"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
BASE_SHEET_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_gunner.png"
)

FRAME_SIZE = 32
BASE_SHEET_SIZE = (256, 192)
BASE_FRAME_RECT = (0, 0, 32, 32)
MAX_VISIBLE_SIZE = 28
BASELINE_Y = 28
REGISTERED_CENTER = (16, 16)
MUZZLE_GRID = (30, 17)
MUZZLE_FLASH_RECT = (30, 16, 32, 18)
GUN_RECT = (21, 16, 30, 20)
EXPECTED_BASE_BBOX = (10, 4, 30, 28)
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
NEUTRAL_PALETTE = set(PALETTE[:8])

PURPLE_RAMP: tuple[tuple[int, int, int, int], ...] = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)

ACCENT_MAP: dict[tuple[int, int, int, int], tuple[int, int, int, int]] = {
    PALETTE[8]: PURPLE_RAMP[1],
    (255, 0, 0, 255): PURPLE_RAMP[3],
    PALETTE[9]: PURPLE_RAMP[4],
    PALETTE[10]: PURPLE_RAMP[5],
    PALETTE[11]: PURPLE_RAMP[5],
}
ORDINARY_ACCENT_COLORS = set(ACCENT_MAP)
EXPECTED_ACCENT_POINTS = {
    (13, 5),
    (15, 11),
    (16, 11),
    (17, 11),
    (15, 12),
    (16, 12),
    (17, 12),
    (24, 17),
    (25, 17),
}
EXPECTED_GUN_INDICATOR_POINTS = {(24, 17), (25, 17)}


@dataclass(frozen=True)
class CandidateSpec:
    key: str
    title: str
    summary: str
    attachment_points: dict[tuple[int, int], tuple[int, int, int, int]]


# Shared family identity from the approved sword-elite A1: low flat shoulder
# caps and a short straight crown rim.  The ordinary head already owns a
# continuous black top edge at y=8, x=11..20, so the elite rim extends that edge
# by exactly one black pixel on each side.  No detached y=7 gray/highlight pixels
# are permitted.  Every coordinate below is transparent in the ordinary frame.
COMMON_A1_BODY_ATTACHMENTS: dict[
    tuple[int, int], tuple[int, int, int, int]
] = {
    # One-pixel extension of the ordinary y=8 top edge; visually continuous.
    (10, 8): OUTLINE,
    (21, 8): OUTLINE,
    # One-pixel flat shoulder caps; the ordinary box remains untouched.
    (9, 12): OUTLINE,
    (10, 12): MID_STEEL,
    (21, 12): MID_STEEL,
    (22, 12): OUTLINE,
    (9, 13): OUTLINE,
    (22, 13): OUTLINE,
}
CLEAN_CROWN_EXTENSION_POINTS = {(10, 8), (21, 8)}

CANDIDATES: tuple[CandidateSpec, ...] = (
    CandidateSpec(
        key="g1",
        title="G1 RAIL + MAG GUARD",
        summary="A1平直机体 / 上导轨 + 弹匣护圈",
        attachment_points={
            # Low receiver rail, entirely above the ordinary 9x4 gun.
            (22, 15): OUTLINE,
            (23, 15): DARK_STEEL,
            (24, 15): MID_STEEL,
            (25, 15): DARK_STEEL,
            (26, 15): OUTLINE,
            # The ordinary magazine supplies the left/top edges; these new
            # right/bottom pixels close a small guard without overwriting it.
            (22, 21): OUTLINE,
            (22, 22): DARK_STEEL,
            (20, 23): OUTLINE,
            (21, 23): DARK_STEEL,
            (22, 23): OUTLINE,
        },
    ),
    CandidateSpec(
        key="g2",
        title="G2 UNDERSLUNG STABILIZER",
        summary="A1平直机体 / 下挂稳定器 + 短前握块",
        attachment_points={
            # Three-pixel stabilizer fixed below the forward barrel.
            (26, 20): OUTLINE,
            (27, 20): DARK_STEEL,
            (28, 20): OUTLINE,
            # Compact two-row foregrip block; it never enters the gun rect.
            (26, 21): MID_STEEL,
            (27, 21): OUTLINE,
            (26, 22): OUTLINE,
            (27, 22): DEEP_SHADOW,
        },
    ),
    CandidateSpec(
        key="g3",
        title="G3 STOCK DAMPER FRAME",
        summary="A1平直机体 / 枪托阻尼框 + 后接收机支撑",
        attachment_points={
            # Short L support above the rear receiver.
            (22, 14): OUTLINE,
            (22, 15): OUTLINE,
            (23, 15): MID_STEEL,
            (24, 15): OUTLINE,
            # Hollow 3x3 damper frame under the stock/receiver junction.
            (22, 21): OUTLINE,
            (23, 21): DARK_STEEL,
            (24, 21): OUTLINE,
            (22, 22): OUTLINE,
            (24, 22): OUTLINE,
            (22, 23): OUTLINE,
            (23, 23): JOINT_SHADOW,
            (24, 23): OUTLINE,
        },
    ),
)

IMAGEGEN_REFERENCE_PATHS: tuple[Path, ...] = (
    BASE_SHEET_PATH,
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_gunner"
    / "combat_robot_gunner_anchor_b_approved_32x.png",
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_elite"
    / "combat_robot_elite_anchor_a1_approved_native32.png",
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _assert_dev_output(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (PROJECT_ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents:
        raise AssertionError(f"Preview builder refused non-dev output: {path}")


def _save_png(image: Image.Image, path: Path) -> None:
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def _load_base_frame() -> Image.Image:
    sheet = Image.open(BASE_SHEET_PATH).convert("RGBA")
    if sheet.size != BASE_SHEET_SIZE:
        raise AssertionError(
            f"Ordinary gunner sheet must be {BASE_SHEET_SIZE}, got {sheet.size}"
        )
    return sheet.crop(BASE_FRAME_RECT)


def _normalize_binary_alpha(image: Image.Image) -> Image.Image:
    result = image.convert("RGBA")
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (
                (red, green, blue, 255) if alpha >= 128 else TRANSPARENT
            )
    return result


def _normalize_imagegen_reference(image: Image.Image) -> Image.Image:
    """Key and despill a source for display only, never for native pixels."""
    result = normalize_source(image)
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = TRANSPARENT
                continue
            strongest_non_green = max(red, blue)
            if green >= 64 and green >= strongest_non_green + 18:
                pixels[x, y] = TRANSPARENT
            elif green > strongest_non_green + 8:
                pixels[x, y] = (red, strongest_non_green, blue, 255)
    return result


def _visible_metrics(frame: Image.Image) -> dict:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Unexpected empty frame")
    visible_points = [
        (x, y)
        for y in range(frame.height)
        for x in range(frame.width)
        if frame.getpixel((x, y))[3] != 0
    ]
    alpha_center_x = sum(x + 0.5 for x, _y in visible_points) / len(
        visible_points
    )
    return {
        "bbox": list(bbox),
        "visible_width": bbox[2] - bbox[0],
        "visible_height": bbox[3] - bbox[1],
        "visible_pixels": len(visible_points),
        "alpha_center_x": round(alpha_center_x, 3),
        "baseline_bottom": bbox[3],
    }


def _assert_pixel_storage(frame: Image.Image, label: str) -> None:
    if frame.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"{label} must be 32x32, got {frame.size}")
    for red, green, blue, alpha in frame.getdata():
        if alpha not in (0, 255):
            raise AssertionError(f"{label} alpha must be binary")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} transparent RGB must be zero")


def _accent_points(frame: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(frame.height)
        for x in range(frame.width)
        if frame.getpixel((x, y)) in ORDINARY_ACCENT_COLORS
    }


def _assert_base_contract(base: Image.Image) -> dict:
    _assert_pixel_storage(base, "ordinary gunner frame0")
    metrics = _visible_metrics(base)
    if tuple(metrics["bbox"]) != EXPECTED_BASE_BBOX:
        raise AssertionError(f"Ordinary gunner registration drifted: {metrics}")
    if metrics["baseline_bottom"] != BASELINE_Y:
        raise AssertionError(f"Ordinary gunner baseline drifted: {metrics}")
    actual_accents = _accent_points(base)
    if actual_accents != EXPECTED_ACCENT_POINTS:
        raise AssertionError(
            "Ordinary gunner functional pixels drifted: "
            f"{sorted(actual_accents)}"
        )
    gun = base.crop(GUN_RECT)
    if gun.getchannel("A").getbbox() != (0, 0, 9, 4):
        raise AssertionError("Ordinary gunner must retain its strict 9x4 gun")
    gun_accents = {
        point for point in actual_accents if _point_in_rect(point, GUN_RECT)
    }
    if gun_accents != EXPECTED_GUN_INDICATOR_POINTS:
        raise AssertionError(
            f"Ordinary gun indicator drifted: {sorted(gun_accents)}"
        )
    if base.getpixel(MUZZLE_GRID) != TRANSPARENT:
        raise AssertionError("Move frame muzzle marker coordinate must remain clear")
    return metrics


def _point_in_rect(
    point: tuple[int, int], rect: tuple[int, int, int, int]
) -> bool:
    x, y = point
    left, top, right, bottom = rect
    return left <= x < right and top <= y < bottom


def _mapped_identity_base(base: Image.Image) -> Image.Image:
    result = base.copy()
    pixels = result.load()
    mapped = 0
    for y in range(result.height):
        for x in range(result.width):
            target = ACCENT_MAP.get(pixels[x, y])
            if target is None:
                continue
            pixels[x, y] = target
            mapped += 1
    if mapped != len(EXPECTED_ACCENT_POINTS):
        raise AssertionError(
            f"Expected {len(EXPECTED_ACCENT_POINTS)} mapped accents, got {mapped}"
        )
    return result


def _combined_attachments(
    spec: CandidateSpec,
) -> dict[tuple[int, int], tuple[int, int, int, int]]:
    crown_points = {
        point for point in COMMON_A1_BODY_ATTACHMENTS if point[1] <= 8
    }
    if crown_points != CLEAN_CROWN_EXTENSION_POINTS:
        raise AssertionError(
            f"Clean crown geometry drifted: {sorted(crown_points)}"
        )
    if any(point[1] == 7 for point in COMMON_A1_BODY_ATTACHMENTS):
        raise AssertionError("Detached y=7 crown pixels are forbidden")
    if any(
        COMMON_A1_BODY_ATTACHMENTS[point] != OUTLINE
        for point in CLEAN_CROWN_EXTENSION_POINTS
    ):
        raise AssertionError("Crown extensions must use continuous black OUTLINE")
    overlap = set(COMMON_A1_BODY_ATTACHMENTS) & set(spec.attachment_points)
    if overlap:
        raise AssertionError(f"{spec.key} duplicates common points: {overlap}")
    return {**COMMON_A1_BODY_ATTACHMENTS, **spec.attachment_points}


def _build_candidate(
    base: Image.Image, mapped_base: Image.Image, spec: CandidateSpec
) -> tuple[Image.Image, dict[tuple[int, int], tuple[int, int, int, int]]]:
    attachments = _combined_attachments(spec)
    candidate = mapped_base.copy()
    pixels = candidate.load()
    for point, color in attachments.items():
        if color not in NEUTRAL_PALETTE:
            raise AssertionError(f"{spec.key} attachment {point} is not neutral gray")
        if base.getpixel(point)[3] != 0:
            raise AssertionError(
                f"{spec.key} attachment {point} overwrites ordinary identity pixels"
            )
        if point[0] >= MUZZLE_GRID[0]:
            raise AssertionError(f"{spec.key} attachment reaches the muzzle corridor")
        if _point_in_rect(point, MUZZLE_FLASH_RECT):
            raise AssertionError(f"{spec.key} attachment occupies muzzle-flash space")
        if _point_in_rect(point, GUN_RECT):
            raise AssertionError(f"{spec.key} attachment alters the 9x4 gun base")
        pixels[point] = color
    return _normalize_binary_alpha(candidate), attachments


def _assert_candidate_contract(
    base: Image.Image,
    mapped_base: Image.Image,
    candidate: Image.Image,
    spec: CandidateSpec,
    attachments: dict[tuple[int, int], tuple[int, int, int, int]],
) -> dict:
    _assert_pixel_storage(candidate, spec.key)
    metrics = _visible_metrics(candidate)
    if metrics["visible_width"] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{spec.key} exceeds 28px width: {metrics}")
    if metrics["visible_height"] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{spec.key} exceeds 28px height: {metrics}")
    if metrics["baseline_bottom"] != BASELINE_Y:
        raise AssertionError(f"{spec.key} baseline drifted: {metrics}")

    allowed_palette = NEUTRAL_PALETTE | set(PURPLE_RAMP) | {TRANSPARENT}
    unexpected_colors = set(candidate.getdata()) - allowed_palette
    if unexpected_colors:
        raise AssertionError(
            f"{spec.key} uses colors outside the fixed palette: "
            f"{sorted(unexpected_colors)}"
        )
    if set(candidate.getdata()) & ORDINARY_ACCENT_COLORS:
        raise AssertionError(f"{spec.key} retains ordinary red/orange pixels")

    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            point = (x, y)
            expected = attachments.get(point, mapped_base.getpixel(point))
            if candidate.getpixel(point) != expected:
                raise AssertionError(
                    f"{spec.key} changed a non-whitelisted pixel at {point}"
                )

    base_alpha = base.getchannel("A")
    candidate_alpha = candidate.getchannel("A")
    added_points = {
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if base_alpha.getpixel((x, y)) == 0
        and candidate_alpha.getpixel((x, y)) == 255
    }
    removed_points = {
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if base_alpha.getpixel((x, y)) == 255
        and candidate_alpha.getpixel((x, y)) == 0
    }
    if added_points != set(attachments):
        raise AssertionError(
            f"{spec.key} additions differ from explicit table: "
            f"{sorted(added_points ^ set(attachments))}"
        )
    if removed_points:
        raise AssertionError(f"{spec.key} removed ordinary pixels: {removed_points}")

    if candidate.crop(GUN_RECT).getchannel("A").tobytes() != base.crop(
        GUN_RECT
    ).getchannel("A").tobytes():
        raise AssertionError(f"{spec.key} changed the strict 9x4 gun alpha mask")
    for y in range(GUN_RECT[1], GUN_RECT[3]):
        for x in range(GUN_RECT[0], GUN_RECT[2]):
            point = (x, y)
            if point in EXPECTED_GUN_INDICATOR_POINTS:
                if candidate.getpixel(point) != ACCENT_MAP[base.getpixel(point)]:
                    raise AssertionError(f"{spec.key} gun indicator mapping drifted")
            elif candidate.getpixel(point) != base.getpixel(point):
                raise AssertionError(f"{spec.key} changed gun pixel {point}")
    if candidate.getpixel(MUZZLE_GRID) != base.getpixel(MUZZLE_GRID):
        raise AssertionError(f"{spec.key} changed muzzle marker {MUZZLE_GRID}")

    metrics.update(
        {
            "ordinary_visible_pixels_preserved": sum(
                1 for alpha in base_alpha.getdata() if alpha == 255
            ),
            "functional_pixels_mapped": len(EXPECTED_ACCENT_POINTS),
            "gray_attachment_pixels_added": len(attachments),
            "common_a1_attachment_pixels": len(COMMON_A1_BODY_ATTACHMENTS),
            "variant_attachment_pixels": len(spec.attachment_points),
            "gun_base_bbox": [0, 0, 9, 4],
            "gun_alpha_mask_preserved": True,
            "muzzle_grid_preserved": list(MUZZLE_GRID),
            "muzzle_flash_rect_preserved": list(MUZZLE_FLASH_RECT),
            "registered_center": list(REGISTERED_CENTER),
        }
    )
    return metrics


def _save_scaled(
    frame: Image.Image, path: Path, scale: int, background: bool = False
) -> None:
    source = _on_background(frame) if background else frame
    _save_png(
        source.resize(
            (source.width * scale, source.height * scale),
            Image.Resampling.NEAREST,
        ),
        path,
    )


def _ordinary_delta(base: Image.Image, candidate: Image.Image) -> Image.Image:
    """Show only RGB/alpha differences from the ordinary runtime frame."""
    result = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    pixels = result.load()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            ordinary = base.getpixel((x, y))
            elite = candidate.getpixel((x, y))
            if ordinary == elite:
                continue
            if ordinary[3] == 0 and elite[3] != 0:
                pixels[x, y] = (238, 80, 205, 255)
            elif ordinary[3] != 0 and elite[3] == 0:
                pixels[x, y] = (60, 210, 235, 255)
            else:
                pixels[x, y] = elite
    return result


def _registration_overlay(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    pixels = result.load()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            if base.getpixel((x, y))[3] != 0:
                pixels[x, y] = (60, 210, 235, 88)
    foreground = candidate.copy()
    foreground.putalpha(
        foreground.getchannel("A").point(lambda alpha: 224 if alpha else 0)
    )
    result.alpha_composite(foreground)
    return result


def _on_background(
    image: Image.Image,
    color: tuple[int, int, int, int] = REVIEW_BACKGROUND,
) -> Image.Image:
    result = Image.new("RGBA", image.size, color)
    result.alpha_composite(image)
    return result


def _review_font(size: int) -> ImageFont.ImageFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _imagegen_thumbnail(
    transparent_reference: Image.Image, size: tuple[int, int]
) -> Image.Image:
    bbox = transparent_reference.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("ImageGen reference became empty after keying")
    subject = transparent_reference.crop(bbox)
    subject.thumbnail(
        (size[0] - 24, size[1] - 24), Image.Resampling.LANCZOS
    )
    panel = Image.new("RGBA", size, REVIEW_PANEL)
    panel.alpha_composite(
        subject,
        ((size[0] - subject.width) // 2, (size[1] - subject.height) // 2),
    )
    return panel


def _facing_pair(candidate: Image.Image) -> Image.Image:
    scale = 8
    sprite_size = FRAME_SIZE * scale
    gap = 34
    header = 34
    pair = Image.new(
        "RGBA",
        (sprite_size * 2 + gap, sprite_size + header),
        REVIEW_BACKGROUND,
    )
    right = _on_background(candidate).resize(
        (sprite_size, sprite_size), Image.Resampling.NEAREST
    )
    left_frame = candidate.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    left = _on_background(left_frame).resize(
        (sprite_size, sprite_size), Image.Resampling.NEAREST
    )
    pair.alpha_composite(right, (0, header))
    pair.alpha_composite(left, (sprite_size + gap, header))
    draw = ImageDraw.Draw(pair)
    font = _review_font(15)
    draw.text((8, 7), "RIGHT / 枪口(30,17)", fill=REVIEW_TEXT, font=font)
    draw.text(
        (sprite_size + gap + 8, 7),
        "LEFT / Sprite flip_h",
        fill=REVIEW_TEXT,
        font=font,
    )
    return pair


def _save_facing_gif(candidate: Image.Image, path: Path) -> None:
    """Alternate the approved right-facing anchor and Godot-style mirror."""
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    frames: list[Image.Image] = []
    for frame in (
        candidate,
        candidate.transpose(Image.Transpose.FLIP_LEFT_RIGHT),
    ):
        review_frame = _on_background(frame).resize(
            (FRAME_SIZE * 16, FRAME_SIZE * 16),
            Image.Resampling.NEAREST,
        )
        frames.append(review_frame.convert("RGB"))
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=[900, 900],
        loop=0,
        disposal=2,
        optimize=False,
    )


def _paste_centered(
    board: Image.Image,
    image: Image.Image,
    box: tuple[int, int, int, int],
) -> None:
    left, top, right, bottom = box
    board.alpha_composite(
        image,
        (
            left + (right - left - image.width) // 2,
            top + (bottom - top - image.height) // 2,
        ),
    )


def _build_comparison(
    base: Image.Image,
    candidates: dict[str, Image.Image],
    transparent_references: dict[str, Image.Image],
) -> Image.Image:
    cell_width = 350
    header_height = 88
    label_height = 44
    row_height = 292
    board = Image.new(
        "RGBA",
        (cell_width * 4, header_height + (label_height + row_height) * 4),
        REVIEW_BACKGROUND,
    )
    draw = ImageDraw.Draw(board)
    title_font = _review_font(21)
    font = _review_font(14)
    draw.text(
        (22, 15),
        "精英持枪战斗机器人 — 第一阶段确定性锚点",
        fill=REVIEW_TEXT,
        font=title_font,
    )
    draw.text(
        (22, 48),
        "ImageGen仅作语言参考；Native仅由普通frame0、紫色映射和显式灰色点表组成",
        fill=REVIEW_MUTED,
        font=font,
    )
    columns: list[tuple[str, str | None]] = [
        ("ORDINARY", None),
        *[(spec.title, spec.key) for spec in CANDIDATES],
    ]
    row_labels = [
        "IMAGEGEN REFERENCE",
        "NATIVE 32 / 8×",
        "ORDINARY DELTA / 8×",
        "RIGHT + LEFT MIRROR / 4×",
    ]
    for row, label in enumerate(row_labels):
        y = header_height + row * (label_height + row_height)
        draw.text((14, y + 10), label, fill=REVIEW_TEXT, font=font)

    for column, (title, key) in enumerate(columns):
        x0 = column * cell_width
        draw.text((x0 + 16, 68), title, fill=REVIEW_TEXT, font=font)
        if key is None:
            native = base
            reference = _on_background(base).resize(
                (256, 256), Image.Resampling.NEAREST
            )
            delta = _ordinary_delta(base, base)
        else:
            native = candidates[key]
            reference = _imagegen_thumbnail(
                transparent_references[key], (316, 260)
            )
            delta = _ordinary_delta(base, native)

        native_large = _on_background(native).resize(
            (256, 256), Image.Resampling.NEAREST
        )
        delta_large = _on_background(delta).resize(
            (256, 256), Image.Resampling.NEAREST
        )
        right = _on_background(native).resize(
            (128, 128), Image.Resampling.NEAREST
        )
        left = _on_background(
            native.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        ).resize((128, 128), Image.Resampling.NEAREST)
        pair = Image.new("RGBA", (272, 128), REVIEW_PANEL)
        pair.alpha_composite(right, (0, 0))
        pair.alpha_composite(left, (144, 0))
        visuals = [reference, native_large, delta_large, pair]
        for row, visual in enumerate(visuals):
            top = header_height + row * (label_height + row_height) + label_height
            _paste_centered(
                board,
                visual,
                (x0, top, x0 + cell_width, top + row_height),
            )
    return board


def _attachment_manifest(
    points: dict[tuple[int, int], tuple[int, int, int, int]]
) -> list[dict]:
    return [
        {"point": [x, y], "rgba": list(points[(x, y)])}
        for x, y in sorted(points)
    ]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="构建精英持枪战斗机器人第一阶段锚点候选"
    )
    parser.add_argument(
        "--approve",
        choices=tuple(spec.key for spec in CANDIDATES),
        help="仅在用户确认后提升指定候选；省略时维持预览模式",
    )
    args = parser.parse_args()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)

    base = _normalize_binary_alpha(_load_base_frame())
    base_metrics = _assert_base_contract(base)
    mapped_base = _mapped_identity_base(base)
    expected_paths = {
        spec.key: SOURCE_DIR
        / f"combat_robot_gunner_elite_anchor_{spec.key}_imagegen.png"
        for spec in CANDIDATES
    }
    missing = [str(path) for path in expected_paths.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            "Missing ImageGen language references; native generation was not run: "
            + ", ".join(missing)
        )
    missing_references = [
        str(path) for path in IMAGEGEN_REFERENCE_PATHS if not path.is_file()
    ]
    if missing_references:
        raise FileNotFoundError(
            "Missing declared ImageGen references: "
            + ", ".join(missing_references)
        )

    prompt_manifest_path = SOURCE_DIR / "imagegen_prompt_manifest.json"
    prompt_manifest = {
        "version": 1,
        "asset": "combat_robot_gunner_elite_anchor_candidates",
        "stage": "first_human_gate",
        "mode": "built-in image_gen",
        "reference_paths": [_relative(path) for path in IMAGEGEN_REFERENCE_PATHS],
        "generated_sources": {
            spec.key: {
                "path": _relative(expected_paths[spec.key]),
                "sha256": _sha256(expected_paths[spec.key]),
                "purpose": spec.summary,
            }
            for spec in CANDIDATES
        },
        "pixel_policy": (
            "All three ImageGen outputs are visual-language references only; "
            "native pixels come exclusively from ordinary runtime frame0, the "
            "fixed purple mapping, and explicit neutral-gray attachment tables."
        ),
        "pixels_imported": False,
        "approved_selection": args.approve.upper() if args.approve else None,
        "runtime_written": False,
    }
    _assert_dev_output(prompt_manifest_path)
    prompt_manifest_path.write_text(
        json.dumps(prompt_manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    ordinary_preview_path = (
        PREVIEW_DIR / "combat_robot_gunner_elite_ordinary_frame0_16x.png"
    )
    _save_scaled(base, ordinary_preview_path, 16)

    candidates: dict[str, Image.Image] = {}
    transparent_references: dict[str, Image.Image] = {}
    candidate_reports: dict[str, dict] = {}
    for spec in CANDIDATES:
        raw_path = expected_paths[spec.key]
        transparent_reference = _normalize_imagegen_reference(
            Image.open(raw_path).convert("RGBA")
        )
        transparent_path = SOURCE_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_"
            "transparent_reference.png"
        )
        _save_png(transparent_reference, transparent_path)
        source_analysis = analyze_image(transparent_reference)

        candidate, attachments = _build_candidate(base, mapped_base, spec)
        metrics = _assert_candidate_contract(
            base, mapped_base, candidate, spec, attachments
        )
        native_path = SOURCE_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_native32.png"
        )
        preview_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_16x.png"
        )
        mirrored_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_mirrored_16x.png"
        )
        delta_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_ordinary_delta_8x.png"
        )
        overlay_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_overlay_16x.png"
        )
        facing_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_facing_pair.png"
        )
        facing_gif_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{spec.key}_facing.gif"
        )
        _save_png(candidate, native_path)
        _save_scaled(candidate, preview_path, 16)
        _save_scaled(
            candidate.transpose(Image.Transpose.FLIP_LEFT_RIGHT),
            mirrored_path,
            16,
        )
        _save_scaled(_ordinary_delta(base, candidate), delta_path, 8)
        _save_scaled(_registration_overlay(base, candidate), overlay_path, 16)
        _save_png(_facing_pair(candidate), facing_path)
        _save_facing_gif(candidate, facing_gif_path)

        candidates[spec.key] = candidate
        transparent_references[spec.key] = transparent_reference
        candidate_reports[spec.key] = {
            "title": spec.title,
            "summary": spec.summary,
            "imagegen_reference": _relative(raw_path),
            "transparent_reference": _relative(transparent_path),
            "source_grid_analysis": source_analysis,
            "native32": _relative(native_path),
            "preview_16x": _relative(preview_path),
            "mirrored_16x": _relative(mirrored_path),
            "ordinary_delta_8x": _relative(delta_path),
            "ordinary_overlay_16x": _relative(overlay_path),
            "facing_pair": _relative(facing_path),
            "facing_gif": _relative(facing_gif_path),
            "metrics": metrics,
            "common_a1_attachment_table": _attachment_manifest(
                COMMON_A1_BODY_ATTACHMENTS
            ),
            "variant_attachment_table": _attachment_manifest(
                spec.attachment_points
            ),
            "all_attachment_table": _attachment_manifest(attachments),
            "native_png_sha256": _sha256(native_path),
            "native_rgba_sha256": _rgba_sha256(candidate),
            "ordinary_identity_preserved_outside_whitelist": True,
            "imagegen_pixels_imported": False,
        }

    approved_anchor: dict[str, object] | None = None
    if args.approve is not None:
        selected = args.approve
        source_native_path = SOURCE_DIR / (
            f"combat_robot_gunner_elite_anchor_{selected}_native32.png"
        )
        approved_native_path = SOURCE_DIR / (
            f"combat_robot_gunner_elite_anchor_{selected}_approved_native32.png"
        )
        source_preview_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{selected}_16x.png"
        )
        approved_preview_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_anchor_{selected}_approved_16x.png"
        )
        _assert_dev_output(approved_native_path)
        _assert_dev_output(approved_preview_path)
        shutil.copyfile(source_native_path, approved_native_path)
        shutil.copyfile(source_preview_path, approved_preview_path)
        source_sha256 = _sha256(source_native_path)
        approved_sha256 = _sha256(approved_native_path)
        if approved_sha256 != source_sha256:
            raise AssertionError("Approved anchor is not byte-identical to selection")
        selected_rgba_sha256 = candidate_reports[selected]["native_rgba_sha256"]
        approved_rgba_sha256 = _rgba_sha256(
            Image.open(approved_native_path).convert("RGBA")
        )
        if approved_rgba_sha256 != selected_rgba_sha256:
            raise AssertionError("Approved anchor RGBA hash differs from selection")
        approved_anchor = {
            "selection": selected.upper(),
            "source_candidate": _relative(source_native_path),
            "path": _relative(approved_native_path),
            "preview_16x": _relative(approved_preview_path),
            "sha256": approved_sha256,
            "rgba_sha256": approved_rgba_sha256,
            "copied_byte_identical": True,
        }
        prompt_manifest["approved_anchor"] = approved_anchor

    prompt_manifest_path.write_text(
        json.dumps(prompt_manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    comparison = _build_comparison(base, candidates, transparent_references)
    comparison_path = (
        PREVIEW_DIR / "combat_robot_gunner_elite_anchor_comparison.png"
    )
    _save_png(comparison, comparison_path)

    report = {
        "asset": "combat_robot_gunner_elite_anchor_candidates",
        "stage": "first_human_gate",
        "approved_selection": args.approve.upper() if args.approve else None,
        "approved_anchor": approved_anchor,
        "runtime_written": False,
        "preview_only": True,
        "pixel_policy": (
            "ImageGen is display-only; native candidates are ordinary frame0 "
            "+ fixed purple mapping + explicit neutral attachment tables"
        ),
        "builder": _relative(SCRIPT_PATH),
        "builder_sha256": _sha256(SCRIPT_PATH),
        "registration_source": _relative(BASE_SHEET_PATH),
        "registration_source_sha256": _sha256(BASE_SHEET_PATH),
        "registration_frame": list(BASE_FRAME_RECT),
        "registration_frame_rgba_sha256": _rgba_sha256(base),
        "ordinary_preview_16x": _relative(ordinary_preview_path),
        "contract": {
            "frame_size": [FRAME_SIZE, FRAME_SIZE],
            "max_visible_size": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "baseline_bottom": BASELINE_Y,
            "registered_center": list(REGISTERED_CENTER),
            "ordinary_base_immutable": True,
            "functional_pixel_positions_preserved": True,
            "ordinary_functional_pixels": len(EXPECTED_ACCENT_POINTS),
            "purple_mapping_only_on_existing_functional_pixels": True,
            "new_purple_pixels": 0,
            "gray_attachments_only": True,
            "gun_rect": list(GUN_RECT),
            "gun_base_visible_bbox": [9, 4],
            "gun_alpha_mask_preserved": True,
            "muzzle_grid": list(MUZZLE_GRID),
            "muzzle_flash_rect": list(MUZZLE_FLASH_RECT),
            "muzzle_flash_space_preserved": True,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "runtime_or_scene_writes": False,
            "clean_crown_extension_points": [
                list(point) for point in sorted(CLEAN_CROWN_EXTENSION_POINTS)
            ],
            "authored_y7_pixels": 0,
            "crown_extension_color": list(OUTLINE),
        },
        "base_metrics": base_metrics,
        "common_a1_body_attachment_table": _attachment_manifest(
            COMMON_A1_BODY_ATTACHMENTS
        ),
        "candidates": candidate_reports,
        "imagegen_prompt_manifest": _relative(prompt_manifest_path),
        "comparison": _relative(comparison_path),
    }
    report_path = (
        PREVIEW_DIR / "combat_robot_gunner_elite_anchor_report.json"
    )
    _assert_dev_output(report_path)
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        "COMBAT_ROBOT_GUNNER_ELITE_ANCHOR_PREVIEW_OK "
        f"candidates=3 approved_selection="
        f"{args.approve.upper() if args.approve else 'null'} "
        "runtime_written=false"
    )
    print(f"  {_relative(comparison_path)}")
    print(f"  {_relative(report_path)}")
    print(f"  {_relative(prompt_manifest_path)}")


if __name__ == "__main__":
    main()
