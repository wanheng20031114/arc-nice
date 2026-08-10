#!/usr/bin/env python3
"""Finalize the approved combat-robot drone-operator pixel assets.

The review gate approved M2 / D1 / K1 / V2 / X1.  Those candidates already
live on their native logical grids, so this script only validates and composes
them.  It never rescales a runtime frame.  The animated target marker is a
native 16 px interpretation of X2's orthogonal mechanical-flash language.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image

from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
RUNTIME_DIR = PROJECT_ROOT / "resources" / "texture" / "enemy" / "mechanical_life"

MOVE_PATH = PREVIEW_DIR / "combat_robot_drone_operator_move_m2_candidate.png"
DEPLOY_PATH = PREVIEW_DIR / "combat_robot_drone_operator_deploy_d1_candidate.png"
DEATH_PATH = PREVIEW_DIR / "combat_robot_drone_operator_death_k1_candidate.png"
DRONE_PATH = PREVIEW_DIR / "combat_robot_suicide_drone_v2_strip_candidate.png"
EXPLOSION_PATH = PREVIEW_DIR / "combat_robot_mechanical_explosion_x1_strip_candidate.png"

OPERATOR_OUTPUT = RUNTIME_DIR / "combat_robot_drone_operator.png"
DRONE_OUTPUT = RUNTIME_DIR / "combat_robot_suicide_drone.png"
MARKER_OUTPUT = RUNTIME_DIR / "combat_robot_drone_target_marker.png"
EXPLOSION_OUTPUT = RUNTIME_DIR / "combat_robot_mechanical_explosion.png"

MARKER_PREVIEW = PREVIEW_DIR / "combat_robot_drone_target_marker_x2_animated_16x.png"
MARKER_GIF = PREVIEW_DIR / "combat_robot_drone_target_marker_x2_animated.gif"
REPORT_PATH = enemy_asset_report_path("combat_robot_drone_operator_runtime_asset_report.json")

EXPECTED_HASHES = {
    MOVE_PATH.name: "1a822675f7103749da50ff25f004e1926db0b47c60faae2f0f31672223a9b534",
    DEPLOY_PATH.name: "9d51a8cc17bd2df643a1d442d11ee8f95d064d261b6cf93d314197c8ba83365d",
    DEATH_PATH.name: "dae8a94de86266cd95813047ee82c17da2e0dddcdbd335c250df64982f15a91c",
    DRONE_PATH.name: "af85ef0ef4facfbf51a4513bbbb5e157f528a266b94b549fb00ea62faae2662e",
    EXPLOSION_PATH.name: "61f3b7fe87623c32853f3e96c2615f1a63618d6cbd3287c129606d3398e7b7cf",
}

TRANSPARENT = (0, 0, 0, 0)
DEEP_RED = (102, 25, 20, 255)
ACTIVE_RED = (190, 48, 31, 255)
ORANGE = (239, 92, 34, 255)
HOT = (255, 181, 71, 255)
WHITE = (226, 229, 226, 255)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_locked(path: Path, expected_size: tuple[int, int]) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    actual_hash = _sha256(path)
    expected_hash = EXPECTED_HASHES[path.name]
    if actual_hash != expected_hash:
        raise ValueError(f"Approved candidate changed: {path.name}: {actual_hash}")
    image = Image.open(path).convert("RGBA")
    if image.size != expected_size:
        raise ValueError(f"{path.name} must be {expected_size}, got {image.size}")
    _validate_pixel_contract(image, path.name)
    return image


def _validate_pixel_contract(image: Image.Image, label: str) -> None:
    palette = set(PALETTE)
    for pixel in image.getdata():
        if pixel[3] not in (0, 255):
            raise ValueError(f"{label} contains non-binary alpha: {pixel}")
        if pixel[3] == 0:
            if pixel[:3] != (0, 0, 0):
                raise ValueError(f"{label} contains nonzero transparent RGB: {pixel}")
        elif pixel not in palette:
            raise ValueError(f"{label} contains a color outside the robot palette: {pixel}")


def _frame(sheet: Image.Image, index: int, cell_size: int) -> Image.Image:
    left = index * cell_size
    return sheet.crop((left, 0, left + cell_size, cell_size))


def _validate_operator_strip(
    sheet: Image.Image,
    frame_count: int,
    label: str,
) -> list[dict]:
    audit: list[dict] = []
    for index in range(frame_count):
        frame = _frame(sheet, index, 32)
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise ValueError(f"{label}[{index}] is empty")
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        baseline = bbox[3]
        if width > 28 or height > 28 or baseline != 28:
            raise ValueError(
                f"{label}[{index}] violates 28x28/y=28: bbox={bbox}"
            )
        audit.append(
            {
                "frame": index,
                "bbox": list(bbox),
                "visible_size": [width, height],
                "baseline_y": baseline,
            }
        )
    return audit


def _compose_operator() -> tuple[Image.Image, dict]:
    move = _load_locked(MOVE_PATH, (256, 32))
    deploy = _load_locked(DEPLOY_PATH, (96, 32))
    death = _load_locked(DEATH_PATH, (256, 32))
    sheet = Image.new("RGBA", (256, 96), TRANSPARENT)
    sheet.alpha_composite(move, (0, 0))
    sheet.alpha_composite(deploy, (0, 32))
    sheet.alpha_composite(death, (0, 64))
    _validate_pixel_contract(sheet, "combat_robot_drone_operator.png")
    return sheet, {
        "size": list(sheet.size),
        "move": _validate_operator_strip(move, 8, "move_m2"),
        "deploy": _validate_operator_strip(deploy, 3, "deploy_d1"),
        "death": _validate_operator_strip(death, 8, "death_k1"),
        "empty_deploy_padding_cells": 5,
    }


def _compose_drone() -> tuple[Image.Image, dict]:
    sheet = _load_locked(DRONE_PATH, (64, 16))
    masks: list[bytes] = []
    bboxes: list[list[int]] = []
    for index in range(4):
        frame = _frame(sheet, index, 16)
        alpha = frame.getchannel("A")
        bbox = alpha.getbbox()
        if bbox is None or (bbox[2] - bbox[0], bbox[3] - bbox[1]) != (12, 9):
            raise ValueError(f"drone_v2[{index}] must have a 12x9 bbox, got {bbox}")
        masks.append(bytes(alpha.getdata()))
        bboxes.append(list(bbox))
    if len(set(masks)) != 1:
        raise ValueError("Drone V2 alpha mask must remain identical across four frames")
    return sheet, {
        "size": list(sheet.size),
        "frame_count": 4,
        "cell_size": [16, 16],
        "visible_size": [12, 9],
        "visible_bboxes": bboxes,
        "alpha_mask_identical": True,
    }


def _set_pixels(
    frame: Image.Image,
    points: set[tuple[int, int]],
    color: tuple[int, int, int, int],
) -> None:
    pixels = frame.load()
    for x, y in points:
        if 0 <= x < 16 and 0 <= y < 16:
            pixels[x, y] = color


def _build_marker_frame(phase: int) -> Image.Image:
    """Draw one center-stable X2-like orthogonal targeting pulse."""
    frame = Image.new("RGBA", (16, 16), TRANSPARENT)
    center = {(7, 7), (8, 7), (7, 8), (8, 8)}
    _set_pixels(frame, center, WHITE if phase in (1, 2) else HOT)

    if phase == 0:
        _set_pixels(frame, {(6, 7), (9, 7), (7, 6), (7, 9)}, DEEP_RED)
        _set_pixels(frame, {(6, 8), (9, 8), (8, 6), (8, 9)}, ACTIVE_RED)
    elif phase == 1:
        _set_pixels(
            frame,
            {(x, 7) for x in range(4, 12)} | {(7, y) for y in range(4, 12)},
            ACTIVE_RED,
        )
        _set_pixels(
            frame,
            {(x, 8) for x in range(5, 11)} | {(8, y) for y in range(5, 11)},
            ORANGE,
        )
        _set_pixels(frame, center, WHITE)
    elif phase == 2:
        _set_pixels(
            frame,
            {(x, 7) for x in range(2, 14)} | {(7, y) for y in range(2, 14)},
            DEEP_RED,
        )
        _set_pixels(
            frame,
            {(x, 8) for x in range(3, 13)} | {(8, y) for y in range(3, 13)},
            ACTIVE_RED,
        )
        _set_pixels(
            frame,
            {(4, 4), (11, 4), (4, 11), (11, 11)},
            ORANGE,
        )
        _set_pixels(frame, center, WHITE)
    else:
        _set_pixels(
            frame,
            {(3, 7), (4, 7), (11, 7), (12, 7), (7, 3), (7, 4), (7, 11), (7, 12)},
            ACTIVE_RED,
        )
        _set_pixels(
            frame,
            {(4, 4), (11, 4), (4, 11), (11, 11)},
            DEEP_RED,
        )
        _set_pixels(frame, center, HOT)
    return frame


def _compose_marker() -> tuple[Image.Image, dict]:
    frames = [_build_marker_frame(index) for index in range(4)]
    strip = Image.new("RGBA", (64, 16), TRANSPARENT)
    bboxes: list[list[int]] = []
    for index, frame in enumerate(frames):
        _validate_pixel_contract(frame, f"target_marker[{index}]")
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise ValueError(f"target_marker[{index}] is empty")
        if bbox[2] - bbox[0] > 12 or bbox[3] - bbox[1] > 12:
            raise ValueError(f"target_marker[{index}] exceeds 12x12: {bbox}")
        if not all(frame.getpixel(point)[3] == 255 for point in ((7, 7), (8, 8))):
            raise ValueError("Target marker center must stay occupied")
        strip.alpha_composite(frame, (index * 16, 0))
        bboxes.append(list(bbox))
    return strip, {
        "size": list(strip.size),
        "frame_count": 4,
        "cell_size": [16, 16],
        "fps": 12,
        "loop": True,
        "x2_orthogonal_pulse": True,
        "center_stable": True,
        "radius_ring": False,
        "visible_bboxes": bboxes,
    }


def _compose_explosion() -> tuple[Image.Image, dict]:
    sheet = _load_locked(EXPLOSION_PATH, (512, 64))
    bboxes: list[list[int]] = []
    centers: list[list[float]] = []
    maximum_diameter = 0
    for index in range(8):
        frame = _frame(sheet, index, 64)
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise ValueError(f"explosion_x1[{index}] is empty")
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        maximum_diameter = max(maximum_diameter, width, height)
        bboxes.append(list(bbox))
        centers.append([(bbox[0] + bbox[2] - 1) / 2, (bbox[1] + bbox[3] - 1) / 2])
    if maximum_diameter != 56 or len({tuple(center) for center in centers}) != 1:
        raise ValueError(
            f"Explosion must be center-stable with max diameter 56: {maximum_diameter}, {centers}"
        )
    return sheet, {
        "size": list(sheet.size),
        "frame_count": 8,
        "cell_size": [64, 64],
        "fps": 14,
        "loop": False,
        "visible_bboxes": bboxes,
        "centers": centers,
        "maximum_visible_diameter": maximum_diameter,
    }


def _save_marker_previews(marker: Image.Image) -> None:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    marker.resize((marker.width * 16, marker.height * 16), Image.Resampling.NEAREST).save(
        MARKER_PREVIEW,
        optimize=False,
    )
    frames = [
        _frame(marker, index, 16).resize((256, 256), Image.Resampling.NEAREST)
        for index in range(4)
    ]
    frames[0].save(
        MARKER_GIF,
        save_all=True,
        append_images=frames[1:],
        duration=80,
        loop=0,
        disposal=2,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write-runtime",
        action="store_true",
        help="Write the four approved production textures.",
    )
    args = parser.parse_args()

    operator, operator_audit = _compose_operator()
    drone, drone_audit = _compose_drone()
    marker, marker_audit = _compose_marker()
    explosion, explosion_audit = _compose_explosion()
    _save_marker_previews(marker)

    outputs: list[str] = []
    if args.write_runtime:
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        for image, path in (
            (operator, OPERATOR_OUTPUT),
            (drone, DRONE_OUTPUT),
            (marker, MARKER_OUTPUT),
            (explosion, EXPLOSION_OUTPUT),
        ):
            image.save(path, optimize=False)
            outputs.append(str(path.relative_to(PROJECT_ROOT)).replace("\\", "/"))

    report = {
        "approved_selection": {
            "move": "M2",
            "deploy": "D1",
            "death": "K1",
            "drone": "V2",
            "explosion": "X1",
            "target_marker": "animated native-16px X2 interpretation",
        },
        "runtime_written": args.write_runtime,
        "ordinary_resize_used": False,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
        "fixed_palette": [list(color) for color in PALETTE],
        "operator": operator_audit,
        "drone": drone_audit,
        "target_marker": marker_audit,
        "explosion": explosion_audit,
        "source_hashes": {
            path.name: _sha256(path)
            for path in (MOVE_PATH, DEPLOY_PATH, DEATH_PATH, DRONE_PATH, EXPLOSION_PATH)
        },
        "outputs": outputs,
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("COMBAT_ROBOT_DRONE_OPERATOR_ASSETS_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
