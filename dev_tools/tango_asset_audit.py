#!/usr/bin/env python3
"""Strict pixel-contract audit for Tango's generated runtime assets."""

from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image
from process_tango_assets import (
    DEATH_OUTPUT_PATH,
    EYE_COORDINATES,
    EYE_CYAN,
    IDLE_OUTPUT_PATH,
    MOVE_BASELINE,
    MOVE_OUTPUT_PATH,
    PALETTE,
    PORTRAIT_OUTPUT_PATH,
    REFERENCE_PATH,
    UNIT_NATIVE_SOURCE_PATH,
    UNIT_OUTPUT_PATH,
)


FRAME_SIZE = 32
UNIT_FRAME_SIZE = 8
PROJECT_ROOT = Path(__file__).resolve().parents[1]
PLAYER_ANIMATION_PATH = PROJECT_ROOT / "resources" / "animation" / "player_tango.tres"
UNIT_ANIMATION_PATH = PROJECT_ROOT / "resources" / "animation" / "tango_cast_unit.tres"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _assert_binary_clean_alpha(image: Image.Image, label: str) -> None:
    rgba = image.convert("RGBA")
    for index, pixel in enumerate(rgba.getdata()):
        red, green, blue, alpha = pixel
        if alpha not in (0, 255):
            raise AssertionError(f"{label}: partial alpha at flat index {index}: {alpha}")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label}: transparent RGB residue at flat index {index}")


def _assert_palette(image: Image.Image, label: str) -> None:
    allowed = set(PALETTE)
    colors = {pixel for pixel in image.convert("RGBA").getdata() if pixel[3] > 0}
    unexpected = colors - allowed
    if unexpected:
        raise AssertionError(f"{label}: unexpected colors {sorted(unexpected)}")


def _frame_bboxes(
    image: Image.Image,
    *,
    columns: int,
    rows: int,
    frame_size: int,
) -> list[tuple[int, int, int, int]]:
    result: list[tuple[int, int, int, int]] = []
    for row in range(rows):
        for column in range(columns):
            frame = image.crop(
                (
                    column * frame_size,
                    row * frame_size,
                    (column + 1) * frame_size,
                    (row + 1) * frame_size,
                )
            )
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                raise AssertionError(f"empty frame at row={row}, column={column}")
            result.append(bbox)
    return result


def _assert_animation_resources() -> None:
    player_text = PLAYER_ANIMATION_PATH.read_text(encoding="utf-8")
    expected_player_animations = {
        "death",
        "idle_down",
        "idle_up",
        "idle_right",
        "idle_left",
        "normal_down",
        "normal_up",
        "normal_right",
        "normal_left",
    }
    for animation_name in expected_player_animations:
        marker = f'"name": &"{animation_name}"'
        if player_text.count(marker) != 1:
            raise AssertionError(f"player animation contract mismatch: {animation_name}")
    if player_text.count('"speed": 14.0') != 4:
        raise AssertionError("normal animations must all run at 14 FPS")
    if player_text.count('"speed": 12.0') != 1:
        raise AssertionError("death animation must run at 12 FPS")
    if player_text.count('[sub_resource type="AtlasTexture"') != 40:
        raise AssertionError("player SpriteFrames must contain 32 move + 8 death atlases")

    unit_text = UNIT_ANIMATION_PATH.read_text(encoding="utf-8")
    for animation_name in ("orbit", "charge", "fire"):
        marker = f'"name": &"{animation_name}"'
        if unit_text.count(marker) != 1:
            raise AssertionError(f"unit animation contract mismatch: {animation_name}")
    if unit_text.count('[sub_resource type="AtlasTexture"') != 12:
        raise AssertionError("unit SpriteFrames must contain 3 states x 4 frames")
    for speed in (6.0, 8.0, 12.0):
        if unit_text.count(f'"speed": {speed}') != 1:
            raise AssertionError(f"unit animation speed contract mismatch: {speed}")


def main() -> None:
    _assert_animation_resources()
    reference = Image.open(REFERENCE_PATH).convert("RGBA")
    for coordinate in EYE_COORDINATES:
        if reference.getpixel(coordinate) != EYE_CYAN:
            raise AssertionError(
                f"reference eye {coordinate} is {reference.getpixel(coordinate)}, "
                f"expected {EYE_CYAN}"
            )
    reference_bbox = reference.getchannel("A").getbbox()
    if reference_bbox is None or reference_bbox[3] - reference_bbox[1] > 24:
        raise AssertionError(f"reference violates 24px height: {reference_bbox}")

    idle = Image.open(IDLE_OUTPUT_PATH).convert("RGBA")
    portrait = Image.open(PORTRAIT_OUTPUT_PATH).convert("RGBA")
    if idle.size != (32, 32):
        raise AssertionError(f"idle size is {idle.size}, expected 32x32")
    if list(idle.getdata()) != list(reference.getdata()):
        raise AssertionError("runtime idle does not exactly match the corrected reference")
    if portrait.size != (160, 160):
        raise AssertionError(f"portrait size is {portrait.size}, expected 160x160")

    move = Image.open(MOVE_OUTPUT_PATH).convert("RGBA")
    death = Image.open(DEATH_OUTPUT_PATH).convert("RGBA")
    unit = Image.open(UNIT_OUTPUT_PATH).convert("RGBA")
    unit_native = Image.open(UNIT_NATIVE_SOURCE_PATH).convert("RGBA")
    if move.size != (256, 128):
        raise AssertionError(f"move sheet size is {move.size}, expected 256x128")
    if death.size != (256, 32):
        raise AssertionError(f"death sheet size is {death.size}, expected 256x32")
    if unit.size != (32, 24):
        raise AssertionError(f"unit sheet size is {unit.size}, expected 32x24")
    if unit_native.size != (8, 8):
        raise AssertionError(
            f"native unit source size is {unit_native.size}, expected 8x8"
        )
    if list(unit.crop((0, 0, 8, 8)).getdata()) != list(unit_native.getdata()):
        raise AssertionError("first orbit frame must match the native 8x8 unit source")

    for image, label in (
        (idle, "idle"),
        (portrait, "portrait"),
        (move, "move"),
        (death, "death"),
        (unit, "unit"),
        (unit_native, "unit_native"),
    ):
        _assert_binary_clean_alpha(image, label)
        _assert_palette(image, label)

    move_bboxes = _frame_bboxes(move, columns=8, rows=4, frame_size=FRAME_SIZE)
    death_bboxes = _frame_bboxes(death, columns=8, rows=1, frame_size=FRAME_SIZE)
    unit_bboxes = _frame_bboxes(unit, columns=4, rows=3, frame_size=UNIT_FRAME_SIZE)

    for bbox in move_bboxes:
        if bbox[3] - bbox[1] > 24:
            raise AssertionError(f"move frame exceeds 24px: {bbox}")
        if bbox[3] != MOVE_BASELINE:
            raise AssertionError(f"move frame baseline drift: {bbox}")
    for bbox in death_bboxes:
        if bbox[3] - bbox[1] > 24:
            raise AssertionError(f"death frame exceeds 24px: {bbox}")
        if bbox[2] - bbox[0] > 30:
            raise AssertionError(f"death frame exceeds 30px width: {bbox}")
    for bbox in unit_bboxes:
        if bbox[2] - bbox[0] > 8 or bbox[3] - bbox[1] > 8:
            raise AssertionError(f"unit frame exceeds native 8x8: {bbox}")
    unit_masks: list[bytes] = []
    for row in range(3):
        for column in range(4):
            frame = unit.crop(
                (
                    column * UNIT_FRAME_SIZE,
                    row * UNIT_FRAME_SIZE,
                    (column + 1) * UNIT_FRAME_SIZE,
                    (row + 1) * UNIT_FRAME_SIZE,
                )
            )
            unit_masks.append(frame.getchannel("A").tobytes())
    if any(mask != unit_masks[0] for mask in unit_masks[1:]):
        raise AssertionError("unit animation frames must keep one stable silhouette")

    print("Tango asset audit: PASS")
    print(f"reference bbox: {reference_bbox}")
    print("move bboxes:", move_bboxes)
    print("death bboxes:", death_bboxes)
    print("unit bboxes:", unit_bboxes)
    print("sheet analyses:")
    for path in (
        IDLE_OUTPUT_PATH,
        PORTRAIT_OUTPUT_PATH,
        MOVE_OUTPUT_PATH,
        DEATH_OUTPUT_PATH,
        UNIT_OUTPUT_PATH,
        UNIT_NATIVE_SOURCE_PATH,
    ):
        analysis = analyze_image(Image.open(path))
        print(
            f"  {path.name}: {analysis['image_width']}x{analysis['image_height']}, "
            f"mode={analysis['detection_mode']}, sha256={_sha256(path)}"
        )


if __name__ == "__main__":
    main()
