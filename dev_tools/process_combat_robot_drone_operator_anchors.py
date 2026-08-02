#!/usr/bin/env python3
"""Build deterministic review anchors for the drone-operator robot.

ImageGen establishes the controller design language, but its high-resolution
drafts are deliberately not squeezed into a 32px runtime cell.  The approved
gunner anchor is instead used as an immutable identity source: antenna, chassis,
eye, pelvis, legs, palette, centre, and baseline stay byte-identical.  Only the
gun/hand region is replaced with one of three coarse controller poses for the
first human review gate.

This script writes review/source artifacts only.  It never touches runtime
textures.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_drone_operator"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
BASE_ANCHOR_PATH = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_gunner"
    / "combat_robot_gunner_anchor_b_native32.png"
)
SWORD_REFERENCE_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot.png"
)
GUNNER_REFERENCE_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_gunner.png"
)

FRAME_SIZE = 32
IDENTITY_SHIFT_X = 4
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)

OUTLINE = PALETTE[0]
DEEP_SHADOW = PALETTE[1]
JOINT_SHADOW = PALETTE[2]
DARK_STEEL = PALETTE[3]
MID_STEEL = PALETTE[4]
PLATE_GRAY = PALETTE[5]
PLATE_HIGHLIGHT = PALETTE[6]
ACTIVE_RED = PALETTE[9]
HOT_ORANGE = PALETTE[10]


def _translated_identity() -> Image.Image:
    source = snap_palette(Image.open(BASE_ANCHOR_PATH).convert("RGBA"))
    if source.size != (FRAME_SIZE, FRAME_SIZE):
        raise ValueError(f"Base anchor must be 32x32, got {source.size}")
    result = Image.new("RGBA", source.size, TRANSPARENT)
    result.alpha_composite(source, (IDENTITY_SHIFT_X, 0))
    return result


def _clear_generated_weapon(frame: Image.Image) -> None:
    """Remove the rifle and its dangling magazine without touching the core."""
    pixels = frame.load()
    for y in range(16, 23):
        for x in range(20, FRAME_SIZE):
            pixels[x, y] = TRANSPARENT


def _set(frame: Image.Image, points: dict[tuple[int, int], tuple[int, int, int, int]]) -> None:
    pixels = frame.load()
    for point, color in points.items():
        pixels[point] = color


def _draw_controller(
    frame: Image.Image,
    *,
    left: int,
    top: int,
    antenna_x: int,
    status: tuple[int, int],
    seam_y: int,
    thumb: tuple[int, int] | None = None,
) -> None:
    """Draw one 8x5 logical-pixel controller with a stable hard silhouette."""
    draw = ImageDraw.Draw(frame)
    draw.rectangle((left, top, left + 7, top + 4), fill=OUTLINE)
    draw.rectangle((left + 1, top + 1, left + 6, top + 3), fill=DARK_STEEL)
    draw.line((left + 1, top + 1, left + 5, top + 1), fill=MID_STEEL)
    draw.line((left + 2, seam_y, left + 5, seam_y), fill=DEEP_SHADOW)
    frame.putpixel(status, HOT_ORANGE)
    frame.putpixel((antenna_x, top - 1), OUTLINE)
    frame.putpixel((antenna_x, top - 2), OUTLINE)
    if thumb is not None:
        frame.putpixel(thumb, PLATE_HIGHLIGHT)


def _candidate_a(identity: Image.Image) -> Image.Image:
    """Low, balanced two-hand hold with maximum torso readability."""
    frame = identity.copy()
    _clear_generated_weapon(frame)
    _draw_controller(
        frame,
        left=14,
        top=17,
        antenna_x=22,
        status=(19, 18),
        seam_y=20,
    )
    _set(
        frame,
        {
            (13, 17): OUTLINE,
            (13, 18): PLATE_HIGHLIGHT,
            (13, 19): PLATE_GRAY,
            (22, 17): OUTLINE,
            (22, 18): PLATE_HIGHLIGHT,
            (22, 19): PLATE_GRAY,
            (23, 17): OUTLINE,
            (23, 18): OUTLINE,
            (23, 19): OUTLINE,
            (12, 16): OUTLINE,
            (13, 16): MID_STEEL,
        },
    )
    return snap_palette(frame)


def _candidate_b(identity: Image.Image) -> Image.Image:
    """Controller tucked closer to the body with a clearly exposed antenna."""
    frame = identity.copy()
    _clear_generated_weapon(frame)
    _draw_controller(
        frame,
        left=15,
        top=17,
        antenna_x=23,
        status=(16, 18),
        seam_y=20,
    )
    _set(
        frame,
        {
            (14, 17): OUTLINE,
            (14, 18): PLATE_HIGHLIGHT,
            (14, 19): PLATE_GRAY,
            (23, 17): OUTLINE,
            (23, 18): PLATE_HIGHLIGHT,
            (23, 19): PLATE_GRAY,
            (24, 17): OUTLINE,
            (24, 18): JOINT_SHADOW,
            (24, 19): OUTLINE,
            (13, 16): OUTLINE,
            (14, 16): PLATE_GRAY,
        },
    )
    return snap_palette(frame)


def _candidate_c(identity: Image.Image) -> Image.Image:
    """Forward side-biased hold with one visible button-press thumb."""
    frame = identity.copy()
    _clear_generated_weapon(frame)
    _draw_controller(
        frame,
        left=14,
        top=16,
        antenna_x=22,
        status=(20, 17),
        seam_y=19,
        thumb=(15, 16),
    )
    _set(
        frame,
        {
            (13, 16): OUTLINE,
            (13, 17): PLATE_HIGHLIGHT,
            (13, 18): PLATE_GRAY,
            (22, 16): OUTLINE,
            (22, 17): PLATE_HIGHLIGHT,
            (22, 18): PLATE_GRAY,
            (23, 16): OUTLINE,
            (23, 17): OUTLINE,
            (23, 18): OUTLINE,
        },
    )
    return snap_palette(frame)


def _visible_bbox(frame: Image.Image) -> tuple[int, int, int, int]:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Anchor candidate is empty")
    return bbox


def _audit(label: str, frame: Image.Image, identity: Image.Image) -> dict:
    bbox = _visible_bbox(frame)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label} bbox {width}x{height} exceeds 28x28")
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"{label} baseline is {bbox[3]}, expected {BASELINE_Y}")

    allowed = set(PALETTE) | {TRANSPARENT}
    if set(frame.getdata()) - allowed:
        raise AssertionError(f"{label} contains colors outside the fixed palette")
    for red, green, blue, alpha in frame.getdata():
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} has dirty transparent RGB")
        if alpha not in (0, 255):
            raise AssertionError(f"{label} has non-binary alpha")

    # Core and legs are immutable; only the authored hand/prop band may differ.
    for y in list(range(0, 16)) + list(range(23, FRAME_SIZE)):
        for x in range(FRAME_SIZE):
            identity_pixel = identity.getpixel((x, y))
            if (
                identity_pixel[3] != 0
                and frame.getpixel((x, y)) != identity_pixel
            ):
                raise AssertionError(f"{label} changed identity pixel {(x, y)}")

    return {
        "bbox": list(bbox),
        "visible_size": [width, height],
        "baseline": bbox[3],
        "palette_colors": len({pixel for pixel in frame.getdata() if pixel[3]}),
    }


def _reference_frame(path: Path) -> Image.Image:
    sheet = Image.open(path).convert("RGBA")
    return sheet.crop((0, 0, FRAME_SIZE, FRAME_SIZE))


def _review_tile(frame: Image.Image, scale: int = 16) -> Image.Image:
    background = Image.new("RGBA", frame.size, REVIEW_BACKGROUND)
    background.alpha_composite(frame)
    return background.resize(
        (FRAME_SIZE * scale, FRAME_SIZE * scale),
        Image.Resampling.NEAREST,
    )


def _write_comparison(candidates: dict[str, Image.Image]) -> Path:
    scale = 12
    gutter = 12
    frames = [
        _reference_frame(SWORD_REFERENCE_PATH),
        _reference_frame(GUNNER_REFERENCE_PATH),
        *candidates.values(),
    ]
    tile_size = FRAME_SIZE * scale
    board = Image.new(
        "RGBA",
        (len(frames) * tile_size + (len(frames) - 1) * gutter, tile_size),
        REVIEW_BACKGROUND,
    )
    for index, frame in enumerate(frames):
        tile = _review_tile(frame, scale)
        board.alpha_composite(tile, (index * (tile_size + gutter), 0))
    path = PREVIEW_DIR / "combat_robot_drone_operator_anchor_comparison.png"
    board.save(path)
    return path


def main() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    identity = _translated_identity()
    candidates = {
        "a": _candidate_a(identity),
        "b": _candidate_b(identity),
        "c": _candidate_c(identity),
    }

    report: dict[str, object] = {
        "base_anchor": str(BASE_ANCHOR_PATH.relative_to(PROJECT_ROOT)),
        "identity_shift": [IDENTITY_SHIFT_X, 0],
        "runtime_written": False,
        "candidates": {},
    }
    for label, frame in candidates.items():
        native_path = SOURCE_DIR / (
            f"combat_robot_drone_operator_anchor_{label}_native32.png"
        )
        preview_path = PREVIEW_DIR / (
            f"combat_robot_drone_operator_anchor_{label}_16x.png"
        )
        frame.save(native_path)
        _review_tile(frame).save(preview_path)
        report["candidates"][label] = {
            **_audit(label, frame, identity),
            "native": str(native_path.relative_to(PROJECT_ROOT)),
            "preview": str(preview_path.relative_to(PROJECT_ROOT)),
        }

    comparison_path = _write_comparison(candidates)
    report["comparison"] = str(comparison_path.relative_to(PROJECT_ROOT))
    report_path = (
        PREVIEW_DIR / "combat_robot_drone_operator_anchor_report.json"
    )
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
