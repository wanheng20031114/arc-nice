#!/usr/bin/env python3
"""Deterministic contract audit for the combat-robot gunner art."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

from PIL import Image

from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_TEXTURE_DIR = (
    PROJECT_ROOT / "resources/texture/enemy/mechanical_life"
)
SHEET_PATH = RUNTIME_TEXTURE_DIR / "combat_robot_gunner.png"
BULLET_PATH = RUNTIME_TEXTURE_DIR / "combat_robot_gunner_bullet.png"
FRAMES_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_gunner.tres"
)
PROCESSOR_PATH = PROJECT_ROOT / "dev_tools" / "process_combat_robot_gunner_assets.py"
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_gunner"
)

FRAME_SIZE = 32
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
TRANSPARENT = (0, 0, 0, 0)
ATTACK_ALERT_RED = (255, 0, 0, 255)
BASE_DARK_RED = PALETTE[8]
ATTACK_ALERT_POINTS = {
    (13, 5),
    (15, 11),
    (16, 11),
    (17, 11),
    (15, 12),
    (16, 12),
    (17, 12),
}
ATTACK_ACCENT_COLORS = {ATTACK_ALERT_RED}
PALETTE_SET = set(PALETTE) | ATTACK_ACCENT_COLORS


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _frame(sheet: Image.Image, column: int, row: int) -> Image.Image:
    return sheet.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )


def _bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Unexpected empty sprite frame")
    return bbox


def _points_with_color(
    image: Image.Image, color: tuple[int, int, int, int]
) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y)) == color
    }


def _normalized_chassis_bytes(
    image: Image.Image,
) -> tuple[tuple[int, int, int, int], ...]:
    chassis = image.crop((11, 4, 21, 22))
    return tuple(
        BASE_DARK_RED if pixel == ATTACK_ALERT_RED else pixel
        for pixel in chassis.getdata()
    )


def _audit_pixels(image: Image.Image, label: str) -> None:
    alphas = set(image.getchannel("A").getdata())
    if not alphas.issubset({0, 255}):
        raise AssertionError(f"{label}: alpha is not binary: {sorted(alphas)}")
    colors = set()
    for red, green, blue, alpha in image.getdata():
        if alpha == 0:
            if (red, green, blue) != (0, 0, 0):
                raise AssertionError(f"{label}: transparent RGB is not zero")
        else:
            colors.add((red, green, blue, alpha))
    if not colors.issubset(PALETTE_SET):
        raise AssertionError(
            f"{label}: colors outside fixed palette: {sorted(colors - PALETTE_SET)}"
        )


def _audit_robot_frame(image: Image.Image, label: str) -> None:
    _audit_pixels(image, label)
    left, top, right, bottom = _bbox(image)
    if right - left > MAX_VISIBLE_SIZE or bottom - top > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label}: bbox {(left, top, right, bottom)} exceeds 28x28")
    if bottom != BASELINE_Y:
        raise AssertionError(f"{label}: bottom {bottom} != baseline {BASELINE_Y}")


def _component_count(image: Image.Image) -> int:
    alpha = image.getchannel("A")
    visible = alpha.load()
    visited: set[tuple[int, int]] = set()
    count = 0
    for y in range(image.height):
        for x in range(image.width):
            if visible[x, y] == 0 or (x, y) in visited:
                continue
            count += 1
            pending = [(x, y)]
            visited.add((x, y))
            while pending:
                current_x, current_y = pending.pop()
                for next_y in range(max(0, current_y - 1), min(image.height, current_y + 2)):
                    for next_x in range(max(0, current_x - 1), min(image.width, current_x + 2)):
                        point = (next_x, next_y)
                        if visible[next_x, next_y] > 0 and point not in visited:
                            visited.add(point)
                            pending.append(point)
    return count


def _masked_bytes(
    image: Image.Image,
    clear_rect: tuple[int, int, int, int],
) -> bytes:
    copy = image.copy()
    copy.paste(TRANSPARENT, clear_rect)
    return copy.tobytes()


def _accent_points(
    image: Image.Image,
    rect: tuple[int, int, int, int],
) -> set[tuple[int, int]]:
    left, top, right, bottom = rect
    accents = set(PALETTE[-4:])
    return {
        (x, y)
        for y in range(top, bottom)
        for x in range(left, right)
        if image.getpixel((x, y)) in accents
    }


def _audit_sprite_frames_text() -> None:
    text = FRAMES_PATH.read_text(encoding="utf-8")
    if text.count('id="AtlasTexture_move_') != 8:
        raise AssertionError("SpriteFrames must declare exactly 8 move atlas cells")
    if text.count('id="AtlasTexture_fire_') != 32:
        raise AssertionError("SpriteFrames must declare exactly 32 fire matrix cells")
    if text.count('id="AtlasTexture_death_') != 8:
        raise AssertionError("SpriteFrames must declare exactly 8 death atlas cells")
    expected = {
        "move": (14.0, True),
        "fire": (25.0, True),
        "fire_walk": (25.0, True),
        "death": (12.0, False),
    }
    for name, (speed, loop) in expected.items():
        pattern = re.compile(
            rf'"loop": {str(loop).lower()},\s*"name": &"{name}",\s*"speed": {speed:.1f}',
            re.MULTILINE,
        )
        if pattern.search(text) is None:
            raise AssertionError(
                f"SpriteFrames animation {name} misses speed={speed} loop={loop}"
            )
    required_texture = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_gunner.png"'
    )
    if text.count(required_texture) != 1:
        raise AssertionError("SpriteFrames must reference the gunner sheet exactly once")


def main() -> None:
    required_sources = (
        "combat_robot_gunner_anchor_b_native32.png",
        "combat_robot_gunner_move_m2_imagegen.png",
        "combat_robot_gunner_fire_f2_imagegen.png",
        "combat_robot_gunner_death_d1_imagegen.png",
        "combat_robot_gunner_bullet_b2_imagegen.png",
    )
    for filename in required_sources:
        if not (SOURCE_DIR / filename).is_file():
            raise AssertionError(f"Missing approved source: {filename}")
    if not PROCESSOR_PATH.is_file():
        raise AssertionError("Missing deterministic gunner asset processor")

    sheet = Image.open(SHEET_PATH).convert("RGBA")
    bullet_sheet = Image.open(BULLET_PATH).convert("RGBA")
    if sheet.size != (256, 192):
        raise AssertionError(f"Main sheet is {sheet.size}, expected 256x192")
    if bullet_sheet.size != (36, 8):
        raise AssertionError(f"Bullet sheet is {bullet_sheet.size}, expected 36x8")
    _audit_pixels(sheet, "main sheet")
    _audit_pixels(bullet_sheet, "bullet sheet")

    move = [_frame(sheet, column, 0) for column in range(8)]
    fire = [[_frame(sheet, column, upper + 1) for column in range(8)] for upper in range(4)]
    death = [_frame(sheet, column, 5) for column in range(8)]

    for index, frame in enumerate(move):
        _audit_robot_frame(frame, f"move[{index}]")
    for upper, row in enumerate(fire):
        for leg, frame in enumerate(row):
            _audit_robot_frame(frame, f"fire[{upper}][{leg}]")
    for index, frame in enumerate(death):
        _audit_robot_frame(frame, f"death[{index}]")

    for index, frame in enumerate(move):
        if _points_with_color(frame, ATTACK_ALERT_RED):
            raise AssertionError(f"move[{index}] unexpectedly uses attack alert red")
    for upper, row in enumerate(fire):
        expected_alert = ATTACK_ALERT_POINTS if upper in (0, 2) else set()
        for leg, frame in enumerate(row):
            alert_points = _points_with_color(frame, ATTACK_ALERT_RED)
            if alert_points != expected_alert:
                raise AssertionError(
                    f"fire[{upper}][{leg}] attack alert pixels differ: "
                    f"{sorted(alert_points)}"
                )
    for index, frame in enumerate(death):
        if _points_with_color(frame, ATTACK_ALERT_RED):
            raise AssertionError(f"death[{index}] unexpectedly uses attack alert red")

    stable_move_upper = {
        _masked_bytes(frame, (9, 22, 23, 28)) for frame in move
    }
    if len(stable_move_upper) != 1:
        raise AssertionError("Move rigid upper changes between leg phases")
    leg_masks = {
        frame.crop((9, 22, 23, 28)).getchannel("A").tobytes()
        for frame in move
    }
    if len(leg_masks) != 8:
        raise AssertionError("Move does not contain eight unique leg phases")

    # The chassis itself is immutable across move and all 32 fire combinations.
    core = _normalized_chassis_bytes(move[0])
    if any(_normalized_chassis_bytes(frame) != core for frame in move):
        raise AssertionError("Move chassis/core flickers")
    if any(
        _normalized_chassis_bytes(frame) != core
        for row in fire
        for frame in row
    ):
        raise AssertionError("Fire chassis/core flickers")

    base_gun_bbox = move[0].crop((21, 16, 30, 20)).getchannel("A").getbbox()
    if base_gun_bbox != (0, 0, 9, 4):
        raise AssertionError(f"Gun bbox is not 9x4: {base_gun_bbox}")
    base_indicator = {(24, 17), (25, 17)}
    recoil_indicator = {(23, 17), (24, 17)}
    for upper, row in enumerate(fire):
        for frame in row:
            accents = _accent_points(frame, (18, 13, 30, 23))
            expected_indicator = base_indicator if upper in (0, 2) else recoil_indicator
            if accents != expected_indicator:
                raise AssertionError(
                    f"Fire F{upper} indicator/recoil mismatch: {sorted(accents)}"
                )
            flash = {
                (x, y)
                for y in range(16, 18)
                for x in range(30, 32)
                if frame.getpixel((x, y))[3] > 0
            }
            expected_flash = (
                {(30, 16), (31, 16), (30, 17), (31, 17)}
                if upper in (0, 2)
                else set()
            )
            if flash != expected_flash:
                raise AssertionError(f"Fire F{upper} muzzle flash mismatch")

    if death[0].tobytes() != Image.open(
        SOURCE_DIR / "combat_robot_gunner_anchor_b_native32.png"
    ).convert("RGBA").transform(
        (32, 32),
        Image.Transform.AFFINE,
        (1, 0, -4, 0, 1, 0),
        resample=Image.Resampling.NEAREST,
    ).tobytes():
        # Palette snapping changes RGB but not alpha; exact runtime identity is
        # independently guaranteed by death[0] == move-source aligned anchor in
        # the processor.  Keep this branch alpha-focused for the raw approval PNG.
        approved_alpha = Image.open(
            SOURCE_DIR / "combat_robot_gunner_anchor_b_native32.png"
        ).convert("RGBA").transform(
            (32, 32),
            Image.Transform.AFFINE,
            (1, 0, -4, 0, 1, 0),
            resample=Image.Resampling.NEAREST,
        ).getchannel("A").tobytes()
        if death[0].getchannel("A").tobytes() != approved_alpha:
            raise AssertionError("death[0] alpha does not equal aligned approved B")
    for index, frame in enumerate(death):
        if _component_count(frame) != 1:
            raise AssertionError(f"death[{index}] contains detached body/gun pieces")

    bullet_masks = []
    hot_centers = []
    for index in range(3):
        frame = bullet_sheet.crop((index * 12, 0, index * 12 + 12, 8))
        bbox = _bbox(frame)
        if bbox != (2, 3, 11, 6):
            raise AssertionError(f"bullet[{index}] bbox {bbox} != strict 9x3")
        bullet_masks.append(frame.getchannel("A").tobytes())
        hot = [
            x
            for y in range(8)
            for x in range(12)
            if frame.getpixel((x, y)) == PALETTE[-1]
        ]
        hot_centers.append(sum(hot) / len(hot))
    if len(set(bullet_masks)) != 1:
        raise AssertionError("Bullet silhouette changes between frames")
    if not hot_centers[0] < hot_centers[1] < hot_centers[2]:
        raise AssertionError("Bullet hot core does not move forward")

    _audit_sprite_frames_text()
    print(
        "COMBAT_ROBOT_GUNNER_ASSET_AUDIT_OK "
        f"sheet_sha256={_sha256(SHEET_PATH)} "
        f"bullet_sha256={_sha256(BULLET_PATH)} "
        "move=8 fire_matrix=32 death=8 bullet=3"
    )


if __name__ == "__main__":
    main()
