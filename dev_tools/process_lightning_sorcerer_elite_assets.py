#!/usr/bin/env python3
"""Build the clean-trim Elite Lightning Sorcerer deterministically.

The accepted imagegen sheets contribute garment-placement intent only.  Their
purple areas are registered against the ordinary Lightning Sorcerer's locked
40px geometry, then reduced to a stable eight-percent in-frame budget.  This
keeps gold lightning dominant and prevents purple coverage or brightness from
pulsing between animation frames.
"""

from __future__ import annotations

import argparse
import hashlib
from collections import OrderedDict
from pathlib import Path

import numpy as np
from PIL import Image

from process_frost_sorcerer_assets import (
    MOVE_FRAME_COUNT,
    MOVE_TARGET_HEIGHTS,
    _assert_move_strip_contract,
    _frame_bbox,
    _load_grid_subjects,
    _load_move_subjects,
    _place_move_subject,
)
from process_lightning_sorcerer_assets import (
    _assert_lightning_gait_contract,
)


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_DIR = ROOT / "resources/texture"
ANIMATION_DIR = ROOT / "resources/animation"
SOURCE_DIR = ROOT / "dev_assets/source_images/lightning_sorcerer_elite"

BASE_CHARACTER = TEXTURE_DIR / "lightning_sorcerer.png"
BASE_MOVE = TEXTURE_DIR / "lightning_sorcerer_move.png"
CHARACTER_OVERLAY = (
    SOURCE_DIR / "lightning_sorcerer_elite_purple_texture_overlay.png"
)
MOVE_OVERLAY = (
    SOURCE_DIR / "lightning_sorcerer_elite_move_purple_texture_overlay.png"
)
CHARACTER_DESIGN_REFERENCE = (
    SOURCE_DIR / "lightning_sorcerer_elite_clean_trim_v2_alpha_reference.png"
)
MOVE_DESIGN_REFERENCE = (
    SOURCE_DIR
    / "lightning_sorcerer_elite_move_8pose_clean_trim_v2_alpha_reference.png"
)
CHARACTER_OUTPUT = TEXTURE_DIR / "lightning_sorcerer_elite.png"
MOVE_OUTPUT = TEXTURE_DIR / "lightning_sorcerer_elite_move.png"
ANIMATION_OUTPUT = ANIMATION_DIR / "lightning_sorcerer_elite.tres"

CHARACTER_SIZE = (160, 160)
MOVE_SIZE = (320, 40)
FRAME_SIZE = 40
GRID_COLUMNS = 4
GRID_ROWS = 4

BASE_CHARACTER_RGBA_SHA256 = (
    "ea55cbc6a2bee4b1dd1b907d2b243329c91f1ccc9e34d873832d6d0f5ad1f8e7"
)
BASE_CHARACTER_ALPHA_SHA256 = (
    "4e277d4385f7f3169fed9da807b4f57c233aa350b2823ae6c5d1099a3805b073"
)
BASE_MOVE_RGBA_SHA256 = (
    "e23c18b453106180bf334f20ede653336e4ab58780e39b7f55522fdf8f52642f"
)
BASE_MOVE_ALPHA_SHA256 = (
    "0013a1deb45af87c9e5984ae3b8d96f5bbcfbef8117ff941f2f8bf33983f7662"
)
ELITE_CHARACTER_RGBA_SHA256 = (
    "2d7e02195beed074c97f296eb646bc88d6a79f11416293387efae4126a74d572"
)
ELITE_MOVE_RGBA_SHA256 = (
    "6bcecb2031bde9dfdf323dbf75b819d8d332f3349a131247185da46426c9b180"
)
EXPECTED_CHARACTER_CHANGED_PIXELS = 521
EXPECTED_MOVE_CHANGED_PIXELS = 248
CHARACTER_OVERLAY_RGBA_SHA256 = (
    "c68847de3ed103157eed095ce1f566db494d1d6fc9c0e089b39e7878b3ba081e"
)
MOVE_OVERLAY_RGBA_SHA256 = (
    "231b9e000b995398e4a96a77f7a371d41853779000c16dcad75d0b5672179a58"
)
CHARACTER_DESIGN_REFERENCE_SIZE = (1254, 1254)
MOVE_DESIGN_REFERENCE_SIZE = (1536, 1024)
CHARACTER_DESIGN_REFERENCE_RGBA_SHA256 = (
    "25b3522f790674fe1f03e14f5aaa2f74bfae8cbdba73bfa1090a6ea351be930a"
)
MOVE_DESIGN_REFERENCE_RGBA_SHA256 = (
    "bd9ff51283900e293e8e55d430f26390109a7e059360f0e8e0961bb812762263"
)
EXPECTED_CHARACTER_CHANGED_PER_FRAME = (
    37,
    33,
    37,
    33,
    32,
    31,
    27,
    33,
    40,
    31,
    34,
    37,
    29,
    31,
    37,
    19,
)
EXPECTED_MOVE_CHANGED_PER_FRAME = (33, 30, 29, 35, 31, 29, 28, 33)
PURPLE_COVERAGE_TARGET = 0.08
PURPLE_COVERAGE_TOLERANCE = 0.002
MAX_REFERENCE_DISTANCE = 2
BASE_BROWN_COLORS = {
    (25, 12, 8, 255),
    (33, 21, 15, 255),
    (52, 28, 20, 255),
    (64, 38, 26, 255),
    (80, 53, 35, 255),
    (97, 57, 40, 255),
    (102, 67, 40, 255),
}
PURPLE_COLORS = {
    (68, 20, 109, 255),
    (109, 39, 175, 255),
    (169, 68, 237, 255),
}
PURPLE_PALETTE = tuple(sorted(PURPLE_COLORS, key=lambda color: sum(color[:3])))

ANIMATIONS = OrderedDict(
    [
        ("move", (0, 12.0, True)),
        ("windup", (1, 6.0, False)),
        ("attack", (2, 8.0, False)),
        ("death", (3, 7.0, False)),
    ]
)


class EliteAssetContractError(RuntimeError):
    """Raised when elite visuals drift from the approved ordinary assets."""


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _alpha_sha256(image: Image.Image) -> str:
    return hashlib.sha256(
        image.convert("RGBA").getchannel("A").tobytes()
    ).hexdigest()


def _require_base(
    path: Path,
    expected_size: tuple[int, int],
    expected_rgba_sha256: str,
    expected_alpha_sha256: str,
    label: str,
) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    image = Image.open(path).convert("RGBA")
    if image.size != expected_size:
        raise EliteAssetContractError(
            f"{label} is {image.size}, expected {expected_size}"
        )
    rgba_hash = _rgba_sha256(image)
    if rgba_hash != expected_rgba_sha256:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {rgba_hash}"
        )
    alpha_hash = _alpha_sha256(image)
    if alpha_hash != expected_alpha_sha256:
        raise EliteAssetContractError(
            f"{label} alpha fingerprint changed: {alpha_hash}"
        )
    return image


def _require_design_reference(
    path: Path,
    expected_size: tuple[int, int],
    expected_rgba_sha256: str,
    label: str,
) -> None:
    if not path.is_file():
        raise FileNotFoundError(path)
    image = Image.open(path).convert("RGBA")
    if image.size != expected_size:
        raise EliteAssetContractError(
            f"{label} is {image.size}, expected {expected_size}"
        )
    rgba_hash = _rgba_sha256(image)
    if rgba_hash != expected_rgba_sha256:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {rgba_hash}"
        )


def _purple_reference_mask(image: Image.Image) -> np.ndarray:
    """Extract saturated violet intent without accepting brown or gold pixels."""
    rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8)
    red = rgba[:, :, 0].astype(np.int32)
    green = rgba[:, :, 1].astype(np.int32)
    blue = rgba[:, :, 2].astype(np.int32)
    alpha = rgba[:, :, 3]
    return (
        (alpha == 255)
        & (blue * 100 > red * 108)
        & (blue * 100 > green * 145)
        & (red * 100 > green * 105)
        & (blue - green > 20)
    )


def _frame_cloth_mask(rgba: np.ndarray) -> np.ndarray:
    mask = np.zeros((FRAME_SIZE, FRAME_SIZE), dtype=bool)
    for color in BASE_BROWN_COLORS:
        mask |= np.all(
            rgba == np.asarray(color, dtype=np.uint8),
            axis=2,
        )
    return mask


def _build_frame_overlay(
    base_frame: Image.Image,
    reference_mask: np.ndarray,
    label: str,
) -> tuple[Image.Image, int, int]:
    """Project clean design intent onto locked cloth with a stable color budget."""
    rgba = np.asarray(base_frame.convert("RGBA"), dtype=np.uint8)
    visible_pixels = int(np.count_nonzero(rgba[:, :, 3]))
    target_pixels = round(visible_pixels * PURPLE_COVERAGE_TARGET)
    reference_positions = np.argwhere(reference_mask)
    cloth_positions = np.argwhere(_frame_cloth_mask(rgba))
    if reference_positions.size == 0:
        raise EliteAssetContractError(f"{label} has no purple design reference")
    if len(cloth_positions) < target_pixels:
        raise EliteAssetContractError(
            f"{label} has {len(cloth_positions)} cloth pixels, "
            f"below the {target_pixels}-pixel purple target"
        )

    ranked_positions: list[tuple[int, int, int, int]] = []
    for y_value, x_value in cloth_positions:
        y = int(y_value)
        x = int(x_value)
        delta = np.abs(reference_positions - np.asarray((y, x)))
        chebyshev_distance = int(np.max(delta, axis=1).min())
        squared_distance = int(np.sum(delta * delta, axis=1).min())
        ranked_positions.append((chebyshev_distance, squared_distance, y, x))
    ranked_positions.sort()
    selected = ranked_positions[:target_pixels]
    max_distance = selected[-1][0]
    if max_distance > MAX_REFERENCE_DISTANCE:
        raise EliteAssetContractError(
            f"{label} needs purple pixels {max_distance}px from the accepted "
            f"design; maximum is {MAX_REFERENCE_DISTANCE}px"
        )

    selected_positions = [(y, x) for _, _, y, x in selected]
    selected_positions.sort(
        key=lambda position: (
            int(rgba[position[0], position[1], :3].sum()),
            position[0],
            position[1],
        )
    )
    bright_count = max(1, round(target_pixels * 0.05))
    mid_count = round(target_pixels * 0.35)
    deep_count = target_pixels - mid_count - bright_count
    overlay = Image.new(
        "RGBA",
        (FRAME_SIZE, FRAME_SIZE),
        (0, 0, 0, 0),
    )
    for index, (y, x) in enumerate(selected_positions):
        if index < deep_count:
            color = PURPLE_PALETTE[0]
        elif index < deep_count + mid_count:
            color = PURPLE_PALETTE[1]
        else:
            color = PURPLE_PALETTE[2]
        overlay.putpixel((x, y), color)
    return overlay, target_pixels, max_distance


def _build_character_overlay(base: Image.Image) -> Image.Image:
    _require_design_reference(
        CHARACTER_DESIGN_REFERENCE,
        CHARACTER_DESIGN_REFERENCE_SIZE,
        CHARACTER_DESIGN_REFERENCE_RGBA_SHA256,
        "elite Lightning Sorcerer character design reference",
    )
    subjects = _load_grid_subjects(
        CHARACTER_DESIGN_REFERENCE,
        "elite_lightning_clean_character",
    )
    overlay = Image.new("RGBA", CHARACTER_SIZE, (0, 0, 0, 0))
    frame_counts: list[int] = []
    reference_distances: list[int] = []
    for index, subject in enumerate(subjects):
        row, column = divmod(index, GRID_COLUMNS)
        bbox = _frame_bbox(base, row, column)
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        fitted_reference = subject.resize(
            (width, height),
            Image.Resampling.NEAREST,
        )
        reference_mask = np.zeros((FRAME_SIZE, FRAME_SIZE), dtype=bool)
        reference_mask[bbox[1] : bbox[3], bbox[0] : bbox[2]] = (
            _purple_reference_mask(fitted_reference)
        )
        frame = base.crop(
            (
                column * FRAME_SIZE,
                row * FRAME_SIZE,
                (column + 1) * FRAME_SIZE,
                (row + 1) * FRAME_SIZE,
            )
        )
        frame_overlay, changed, max_distance = _build_frame_overlay(
            frame,
            reference_mask,
            f"elite Lightning Sorcerer character frame {row}:{column}",
        )
        overlay.alpha_composite(
            frame_overlay,
            (column * FRAME_SIZE, row * FRAME_SIZE),
        )
        frame_counts.append(changed)
        reference_distances.append(max_distance)
    print(
        "ELITE_PURPLE_PLACEMENT character "
        f"counts={tuple(frame_counts)} "
        f"max_reference_distance={max(reference_distances)}"
    )
    return overlay


def _build_move_overlay(base: Image.Image) -> Image.Image:
    _require_design_reference(
        MOVE_DESIGN_REFERENCE,
        MOVE_DESIGN_REFERENCE_SIZE,
        MOVE_DESIGN_REFERENCE_RGBA_SHA256,
        "elite Lightning Sorcerer move design reference",
    )
    subjects = _load_move_subjects(
        MOVE_DESIGN_REFERENCE,
        "elite_lightning_clean_move",
    )
    overlay = Image.new("RGBA", MOVE_SIZE, (0, 0, 0, 0))
    frame_counts: list[int] = []
    reference_distances: list[int] = []
    for index, subject in enumerate(subjects):
        registered_reference = _place_move_subject(
            subject,
            MOVE_TARGET_HEIGHTS[index],
            0,
            f"elite_lightning_clean_move_{index}",
        )
        frame = base.crop(
            (
                index * FRAME_SIZE,
                0,
                (index + 1) * FRAME_SIZE,
                FRAME_SIZE,
            )
        )
        frame_overlay, changed, max_distance = _build_frame_overlay(
            frame,
            _purple_reference_mask(registered_reference),
            f"elite Lightning Sorcerer move frame {index}",
        )
        overlay.alpha_composite(frame_overlay, (index * FRAME_SIZE, 0))
        frame_counts.append(changed)
        reference_distances.append(max_distance)
    print(
        "ELITE_PURPLE_PLACEMENT move "
        f"counts={tuple(frame_counts)} "
        f"max_reference_distance={max(reference_distances)}"
    )
    return overlay


def _overlay_positions(overlay: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(overlay.height)
        for x in range(overlay.width)
        if overlay.getpixel((x, y))[3] > 0
    }


def _per_frame_overlay_counts(overlay: Image.Image) -> tuple[int, ...]:
    counts: list[int] = []
    frame_rows = overlay.height // FRAME_SIZE
    frame_columns = overlay.width // FRAME_SIZE
    for row in range(frame_rows):
        for column in range(frame_columns):
            frame = overlay.crop(
                (
                    column * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (column + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            counts.append(
                sum(1 for alpha in frame.getchannel("A").getdata() if alpha)
            )
    return tuple(counts)


def _assert_overlay_contract(
    overlay: Image.Image,
    expected_size: tuple[int, int],
    expected_rgba_sha256: str,
    label: str,
) -> None:
    if overlay.size != expected_size:
        raise EliteAssetContractError(
            f"{label} is {overlay.size}, expected {expected_size}"
        )
    _assert_binary_alpha(overlay, label)
    if any(
        pixel[3] == 0 and pixel[:3] != (0, 0, 0)
        for pixel in overlay.getdata()
    ):
        raise EliteAssetContractError(
            f"{label} transparent RGB payload must be zero"
        )
    overlay_hash = _rgba_sha256(overlay)
    if overlay_hash != expected_rgba_sha256:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {overlay_hash}"
        )


def _assert_binary_alpha(image: Image.Image, label: str) -> None:
    values = set(image.getchannel("A").getdata())
    if not values.issubset({0, 255}):
        raise EliteAssetContractError(
            f"{label} alpha must be binary, got {sorted(values)}"
        )


def _build_elite(
    base: Image.Image,
    overlay: Image.Image,
    expected_per_frame: tuple[int, ...],
    expected_rgba_sha256: str,
    label: str,
) -> Image.Image:
    positions = _overlay_positions(overlay)
    changed_pixels = len(positions)
    expected_changed_pixels = sum(expected_per_frame)
    if changed_pixels != expected_changed_pixels:
        raise EliteAssetContractError(
            f"{label} changed {changed_pixels} pixels, "
            f"expected {expected_changed_pixels}"
        )
    if _per_frame_overlay_counts(overlay) != expected_per_frame:
        raise EliteAssetContractError(f"{label} per-frame purple counts changed")
    result = base.copy()
    for position in positions:
        source_pixel = base.getpixel(position)
        purple_pixel = overlay.getpixel(position)
        if source_pixel not in BASE_BROWN_COLORS:
            raise EliteAssetContractError(
                f"{label} overlay covered non-cloth color at {position}: "
                f"{source_pixel}"
            )
        if purple_pixel not in PURPLE_COLORS:
            raise EliteAssetContractError(
                f"{label} overlay used unapproved purple at {position}: "
                f"{purple_pixel}"
            )
        result.putpixel(position, purple_pixel)

    if result.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise EliteAssetContractError(f"{label} alpha changed")
    actual_changed_positions = {
        (x, y)
        for y in range(base.height)
        for x in range(base.width)
        if result.getpixel((x, y)) != base.getpixel((x, y))
    }
    if actual_changed_positions != positions:
        raise EliteAssetContractError(
            f"{label} changes escaped the approved overlay"
        )
    visible_pixels = sum(
        1 for alpha in base.getchannel("A").getdata() if alpha
    )
    coverage = changed_pixels / float(visible_pixels)
    if abs(coverage - PURPLE_COVERAGE_TARGET) > PURPLE_COVERAGE_TOLERANCE:
        raise EliteAssetContractError(
            f"{label} purple coverage {coverage:.3f} escaped "
            f"{PURPLE_COVERAGE_TARGET:.1%}±"
            f"{PURPLE_COVERAGE_TOLERANCE:.1%}"
        )
    frame_rows = base.height // FRAME_SIZE
    frame_columns = base.width // FRAME_SIZE
    frame_index = 0
    frame_coverages: list[float] = []
    for row in range(frame_rows):
        for column in range(frame_columns):
            frame = base.crop(
                (
                    column * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (column + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            frame_visible = sum(
                1 for alpha in frame.getchannel("A").getdata() if alpha
            )
            frame_coverage = expected_per_frame[frame_index] / float(
                frame_visible
            )
            if (
                abs(frame_coverage - PURPLE_COVERAGE_TARGET)
                > PURPLE_COVERAGE_TOLERANCE
            ):
                raise EliteAssetContractError(
                    f"{label} frame {frame_index} purple coverage "
                    f"{frame_coverage:.3f} is unstable"
                )
            frame_coverages.append(frame_coverage)
            frame_index += 1
    print(
        "ELITE_PURPLE_STABILITY "
        f"{label} coverage_min={min(frame_coverages):.4f} "
        f"coverage_max={max(frame_coverages):.4f} "
        f"palette_colors={len(PURPLE_COLORS)}"
    )
    rgba_hash = _rgba_sha256(result)
    if rgba_hash != expected_rgba_sha256:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {rgba_hash}"
        )
    _assert_binary_alpha(result, label)
    return result


def _animation_entry(name: str, speed: float, loop: bool) -> str:
    frame_count = MOVE_FRAME_COUNT if name == "move" else GRID_COLUMNS
    frames = [
        "{\n"
        '"duration": 1.0,\n'
        f'"texture": SubResource("AtlasTexture_{name}_{column}")\n'
        "}"
        for column in range(frame_count)
    ]
    return (
        "{\n"
        f'"frames": [{", ".join(frames)}],\n'
        f'"loop": {str(loop).lower()},\n'
        f'"name": &"{name}",\n'
        f'"speed": {speed:.1f}\n'
        "}"
    )


def _sprite_frames_text() -> str:
    lines = [
        (
            '[gd_resource type="SpriteFrames" format=3 '
            'uid="uid://cwdlo03coum0b"]'
        ),
        "",
        (
            '[ext_resource type="Texture2D" '
            'uid="uid://b36yt8ewr3axr" '
            'path="res://resources/texture/lightning_sorcerer_elite.png" '
            'id="1_texture"]'
        ),
        (
            '[ext_resource type="Texture2D" '
            'uid="uid://dql2aoi5h4ivq" '
            'path="res://resources/texture/lightning_sorcerer_elite_move.png" '
            'id="2_move"]'
        ),
        "",
    ]
    for name in sorted(ANIMATIONS):
        row = ANIMATIONS[name][0]
        frame_count = MOVE_FRAME_COUNT if name == "move" else GRID_COLUMNS
        texture_id = "2_move" if name == "move" else "1_texture"
        for column in range(frame_count):
            lines.extend(
                [
                    (
                        '[sub_resource type="AtlasTexture" '
                        f'id="AtlasTexture_{name}_{column}"]'
                    ),
                    f'atlas = ExtResource("{texture_id}")',
                    (
                        f"region = Rect2({column * FRAME_SIZE}, "
                        f"{0 if name == 'move' else row * FRAME_SIZE}, "
                        f"{FRAME_SIZE}, {FRAME_SIZE})"
                    ),
                    "filter_clip = true",
                    "",
                ]
            )
    entries = [
        _animation_entry(name, values[1], values[2])
        for name, values in sorted(ANIMATIONS.items())
    ]
    lines.extend(
        [
            "[resource]",
            f"animations = [{', '.join(entries)}]",
            "",
        ]
    )
    return "\n".join(lines)


def _validate_outputs(
    character: Image.Image,
    move: Image.Image,
    character_overlay: Image.Image,
    move_overlay: Image.Image,
    animation_text: str,
) -> None:
    for path, expected, label in (
        (CHARACTER_OVERLAY, character_overlay, "elite character overlay"),
        (MOVE_OVERLAY, move_overlay, "elite move overlay"),
        (CHARACTER_OUTPUT, character, "elite character"),
        (MOVE_OUTPUT, move, "elite move"),
    ):
        if not path.is_file():
            raise EliteAssetContractError(f"Missing {label}: {path}")
        actual = Image.open(path).convert("RGBA")
        if actual.tobytes() != expected.tobytes():
            raise EliteAssetContractError(f"Generated {label} is stale")
    if not ANIMATION_OUTPUT.is_file():
        raise EliteAssetContractError(
            f"Missing generated SpriteFrames: {ANIMATION_OUTPUT}"
        )
    if ANIMATION_OUTPUT.read_text(encoding="utf-8") != animation_text:
        raise EliteAssetContractError("Generated elite SpriteFrames is stale")


def main(check_only: bool = False) -> None:
    base_character = _require_base(
        BASE_CHARACTER,
        CHARACTER_SIZE,
        BASE_CHARACTER_RGBA_SHA256,
        BASE_CHARACTER_ALPHA_SHA256,
        "base Lightning Sorcerer character",
    )
    base_move = _require_base(
        BASE_MOVE,
        MOVE_SIZE,
        BASE_MOVE_RGBA_SHA256,
        BASE_MOVE_ALPHA_SHA256,
        "base Lightning Sorcerer move",
    )
    character_overlay = _build_character_overlay(base_character)
    _assert_overlay_contract(
        character_overlay,
        CHARACTER_SIZE,
        CHARACTER_OVERLAY_RGBA_SHA256,
        "elite Lightning Sorcerer character overlay",
    )
    move_overlay = _build_move_overlay(base_move)
    _assert_overlay_contract(
        move_overlay,
        MOVE_SIZE,
        MOVE_OVERLAY_RGBA_SHA256,
        "elite Lightning Sorcerer move overlay",
    )
    character = _build_elite(
        base_character,
        character_overlay,
        EXPECTED_CHARACTER_CHANGED_PER_FRAME,
        ELITE_CHARACTER_RGBA_SHA256,
        "elite Lightning Sorcerer character",
    )
    move = _build_elite(
        base_move,
        move_overlay,
        EXPECTED_MOVE_CHANGED_PER_FRAME,
        ELITE_MOVE_RGBA_SHA256,
        "elite Lightning Sorcerer move",
    )
    _assert_move_strip_contract(move, "elite lightning sorcerer move")
    _assert_lightning_gait_contract(move)
    animation_text = _sprite_frames_text()

    if check_only:
        _validate_outputs(
            character,
            move,
            character_overlay,
            move_overlay,
            animation_text,
        )
        print(
            "LIGHTNING_SORCERER_ELITE_ASSETS_CHECK_OK "
            f"character_changed={EXPECTED_CHARACTER_CHANGED_PIXELS} "
            f"move_changed={EXPECTED_MOVE_CHANGED_PIXELS}"
        )
        return

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    character_overlay.save(CHARACTER_OVERLAY, optimize=True)
    move_overlay.save(MOVE_OVERLAY, optimize=True)
    character.save(CHARACTER_OUTPUT, optimize=True)
    move.save(MOVE_OUTPUT, optimize=True)
    ANIMATION_OUTPUT.write_text(
        animation_text,
        encoding="utf-8",
        newline="\n",
    )
    print(
        "LIGHTNING_SORCERER_ELITE_ASSETS_OK "
        f"character_changed={EXPECTED_CHARACTER_CHANGED_PIXELS} "
        f"move_changed={EXPECTED_MOVE_CHANGED_PIXELS} "
        "alpha_and_gait=base_identical"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()
    main(arguments.check_only)
