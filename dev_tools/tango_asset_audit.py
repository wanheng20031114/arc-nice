#!/usr/bin/env python3
"""Strict pixel-contract audit for Tango's generated runtime assets."""

from __future__ import annotations

import hashlib
from pathlib import Path
from statistics import pstdev

from PIL import Image

from pixel_grid_analyzer import analyze_image
from process_tango_assets import (
    DEATH_BASELINE,
    DEATH_OUTPUT_PATH,
    DIRECTION_REFERENCE_PATHS,
    DOWN_BODY_X_OFFSETS,
    DOWN_GAIT_PHASES,
    EYE_COORDINATES,
    EYE_CYAN,
    IDLE_OUTPUT_PATH,
    MOVE_BASELINE,
    MOVE_BOB_OFFSETS,
    MOVE_OUTPUT_PATH,
    MOVE_STABLE_BODY_BOTTOM,
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

EXPECTED_DOWN_CONTACTS = (
    (10, 11, 12, 13, 14, 17, 18, 19, 20),
    (10, 11, 12, 13, 14, 17),
    (11, 12, 13, 14, 15),
    (14, 15, 20, 21),
    (14, 15, 18, 19, 20, 21, 22),
    (15, 18, 19, 20, 21, 22),
    (17, 18, 19, 20, 21),
    (11, 12, 17, 18),
)


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


def _frame_at(image: Image.Image, row: int, column: int) -> Image.Image:
    return image.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )


def _assert_single_component(frame: Image.Image, label: str) -> None:
    opaque = {
        (x, y)
        for y in range(frame.height)
        for x in range(frame.width)
        if frame.getpixel((x, y))[3] > 0
    }
    if not opaque:
        raise AssertionError(f"{label}: empty frame")
    pending = [next(iter(opaque))]
    visited: set[tuple[int, int]] = set()
    while pending:
        point = pending.pop()
        if point in visited:
            continue
        visited.add(point)
        x, y = point
        for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if neighbor in opaque and neighbor not in visited:
                pending.append(neighbor)
    if visited != opaque:
        raise AssertionError(
            f"{label}: {len(opaque - visited)} opaque pixels are disconnected"
        )


def _assert_move_stability(
    move: Image.Image,
    direction_references: list[Image.Image],
) -> None:
    if MOVE_BOB_OFFSETS != (0, 1, 1, 0, 0, 1, 1, 0):
        raise AssertionError(f"unexpected rigid bob sequence: {MOVE_BOB_OFFSETS}")
    if DOWN_BODY_X_OFFSETS != (0, -1, -1, -1, 0, 1, 1, 1):
        raise AssertionError(
            f"unexpected down-facing weight transfer: {DOWN_BODY_X_OFFSETS}"
        )
    if len(DOWN_GAIT_PHASES) != 8:
        raise AssertionError(f"unexpected down gait phases: {DOWN_GAIT_PHASES}")

    for row in range(4):
        frames = [_frame_at(move, row, column) for column in range(8)]
        canonical = direction_references[row]
        canonical_upper = canonical.crop(
            (0, 0, FRAME_SIZE, MOVE_STABLE_BODY_BOTTOM)
        )
        if frames[0].tobytes() != canonical.tobytes():
            raise AssertionError(
                f"move row {row}: frame 0 differs from the repaired reference"
            )
        for column, (frame, bob_offset) in enumerate(
            zip(frames, MOVE_BOB_OFFSETS, strict=True)
        ):
            _assert_single_component(frame, f"move row {row} frame {column}")
            body_x = DOWN_BODY_X_OFFSETS[column] if row == 0 else 0
            expected_body = Image.new(
                "RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0)
            )
            expected_body.alpha_composite(
                canonical_upper,
                (body_x, bob_offset),
            )
            for y in range(MOVE_STABLE_BODY_BOTTOM + bob_offset):
                for x in range(FRAME_SIZE):
                    expected_pixel = expected_body.getpixel((x, y))
                    actual_pixel = frame.getpixel((x, y))
                    if expected_pixel[3] > 0 and actual_pixel != expected_pixel:
                        raise AssertionError(
                            f"move row {row} frame {column}: rigid body changed "
                            f"at {(x, y)}, offset={(body_x, bob_offset)}"
                        )
                    if (
                        expected_pixel[3] == 0
                        and y < MOVE_STABLE_BODY_BOTTOM
                        and actual_pixel[3] != 0
                    ):
                        raise AssertionError(
                            f"move row {row} frame {column}: body remnant at "
                            f"{(x, y)}"
                        )
            for y in range(bob_offset):
                vacated_row = frame.crop((0, y, FRAME_SIZE, y + 1))
                if vacated_row.getchannel("A").getbbox() is not None:
                    raise AssertionError(
                        f"move row {row} frame {column}: bob row {y} is not empty"
                    )
        lower_bodies = {
            frame.crop(
                (0, MOVE_STABLE_BODY_BOTTOM + 1, FRAME_SIZE, FRAME_SIZE)
            ).tobytes()
            for frame in frames
        }
        if len(lower_bodies) < 4:
            raise AssertionError(
                f"move row {row}: gait has only {len(lower_bodies)} lower-body poses"
            )

    for column, bob_offset in enumerate(MOVE_BOB_OFFSETS):
        down_frame = _frame_at(move, 0, column)
        expected_eye_x = [
            15 + DOWN_BODY_X_OFFSETS[column],
            18 + DOWN_BODY_X_OFFSETS[column],
        ]
        for base_y in (11, 12):
            eye_y = base_y + bob_offset
            bright_x = [
                x for x in range(FRAME_SIZE)
                if down_frame.getpixel((x, eye_y)) == EYE_CYAN
            ]
            if bright_x != expected_eye_x:
                raise AssertionError(
                    f"down frame {column}: eyes at y={eye_y} must be two "
                    f"1px columns, got x={bright_x}"
                )

    down_frames = [_frame_at(move, 0, column) for column in range(8)]
    alpha_changes: list[int] = []
    rgba_changes: list[int] = []
    for column in range(8):
        current = down_frames[column].crop((0, 24, FRAME_SIZE, FRAME_SIZE))
        following = down_frames[(column + 1) % 8].crop(
            (0, 24, FRAME_SIZE, FRAME_SIZE)
        )
        current_pixels = list(current.getdata())
        following_pixels = list(following.getdata())
        alpha_changes.append(
            sum(
                (left[3] > 0) != (right[3] > 0)
                for left, right in zip(current_pixels, following_pixels, strict=True)
            )
        )
        rgba_changes.append(
            sum(
                left != right
                for left, right in zip(current_pixels, following_pixels, strict=True)
            )
        )
    mean_alpha_change = sum(alpha_changes) / len(alpha_changes)
    alpha_cv = pstdev(alpha_changes) / mean_alpha_change
    if min(alpha_changes) < 5 or max(alpha_changes) > 15 or alpha_cv > 0.35:
        raise AssertionError(
            "down gait timing is uneven: "
            f"alpha={alpha_changes}, cv={alpha_cv:.3f}"
        )
    if max(rgba_changes) > 32:
        raise AssertionError(f"down gait has a color jump: {rgba_changes}")

    actual_contacts = tuple(
        tuple(
            x for x in range(FRAME_SIZE)
            if frame.getpixel((x, MOVE_BASELINE - 1))[3] > 0
        )
        for frame in down_frames
    )
    if actual_contacts != EXPECTED_DOWN_CONTACTS:
        raise AssertionError(
            "down gait lost its contact/load/roll/push footprints: "
            f"{actual_contacts}"
        )

    # A walking support leg must deform while it bears weight. These checks are
    # intentionally confined to the planted side, so moving only the swing leg
    # can never satisfy them again.
    support_transitions = (
        (1, 2, (9, 24, 17, 28), "left load-to-roll"),
        (5, 6, (16, 24, 24, 28), "right load-to-roll"),
    )
    for first, second, bounds, label in support_transitions:
        first_silhouette = down_frames[first].crop(bounds).getchannel("A")
        second_silhouette = down_frames[second].crop(bounds).getchannel("A")
        if first_silhouette.tobytes() == second_silhouette.tobytes():
            raise AssertionError(f"down gait {label} leaves the support leg static")

    left_load_center = sum(EXPECTED_DOWN_CONTACTS[1][:5]) / 5.0
    left_roll_center = sum(EXPECTED_DOWN_CONTACTS[2]) / 5.0
    right_load_center = sum(EXPECTED_DOWN_CONTACTS[5][1:]) / 5.0
    right_roll_center = sum(EXPECTED_DOWN_CONTACTS[6]) / 5.0
    if left_roll_center <= left_load_center or right_roll_center >= right_load_center:
        raise AssertionError(
            "down gait support feet must roll one pixel toward the center line"
        )

    down_core_poses = {
        frame.crop((0, 24, FRAME_SIZE, FRAME_SIZE)).tobytes()
        for frame in down_frames
    }
    if len(down_core_poses) != 8:
        raise AssertionError(
            f"down gait must keep eight distinct leg poses, got {len(down_core_poses)}"
        )


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
    direction_references = [
        Image.open(path).convert("RGBA") for path in DIRECTION_REFERENCE_PATHS
    ]
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
    _assert_move_stability(move, direction_references)

    for image, label in (
        (idle, "idle"),
        (portrait, "portrait"),
        (move, "move"),
        (death, "death"),
        (unit, "unit"),
        (unit_native, "unit_native"),
        *(
            (direction_reference, f"direction_reference_{index}")
            for index, direction_reference in enumerate(direction_references)
        ),
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
        if bbox[3] != DEATH_BASELINE:
            raise AssertionError(f"death frame baseline drift: {bbox}")
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
