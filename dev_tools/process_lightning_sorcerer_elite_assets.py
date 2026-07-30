#!/usr/bin/env python3
"""Build the purple-textured Elite Lightning Sorcerer deterministically."""

from __future__ import annotations

import argparse
import hashlib
from collections import OrderedDict
from pathlib import Path

from PIL import Image

from process_frost_sorcerer_assets import (
    MOVE_FRAME_COUNT,
    _assert_move_strip_contract,
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
    "c5a395e6bb769877f9671293edb6331867549162ac3ac29bcd08c9721e8315cd"
)
ELITE_MOVE_RGBA_SHA256 = (
    "3fd76b5fee1112f80bf19ac6abb97038e099fca60e46b6eebe9676fe7add06b3"
)
EXPECTED_CHARACTER_CHANGED_PIXELS = 1216
EXPECTED_MOVE_CHANGED_PIXELS = 729
CHARACTER_OVERLAY_RGBA_SHA256 = (
    "9762068a0f679f5b51922d3623760fa2c34cdd1508a387504b91a30017691771"
)
MOVE_OVERLAY_RGBA_SHA256 = (
    "1e7e202ee64b8d74029e0bb9c1c60327fe1d1b88dd3c50bf05d48f1b0f28d453"
)
EXPECTED_CHARACTER_CHANGED_PER_FRAME = (
    90,
    78,
    92,
    85,
    71,
    70,
    66,
    72,
    95,
    89,
    98,
    80,
    71,
    65,
    70,
    24,
)
EXPECTED_MOVE_CHANGED_PER_FRAME = (95, 93, 89, 101, 88, 86, 74, 103)
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
    (34, 10, 52, 255),
    (50, 14, 80, 255),
    (68, 20, 109, 255),
    (83, 26, 133, 255),
    (109, 39, 175, 255),
    (139, 55, 207, 255),
    (169, 68, 237, 255),
    (247, 233, 252, 255),
}

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


def _require_overlay(
    path: Path,
    expected_size: tuple[int, int],
    expected_rgba_sha256: str,
    label: str,
) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    overlay = Image.open(path).convert("RGBA")
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
    return overlay


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
    if not 0.15 <= coverage <= 0.25:
        raise EliteAssetContractError(
            f"{label} purple coverage {coverage:.3f} escaped 15%-25%"
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
        '[gd_resource type="SpriteFrames" format=3]',
        "",
        (
            '[ext_resource type="Texture2D" '
            'path="res://resources/texture/lightning_sorcerer_elite.png" '
            'id="1_texture"]'
        ),
        (
            '[ext_resource type="Texture2D" '
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
    animation_text: str,
) -> None:
    for path, expected, label in (
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
    character_overlay = _require_overlay(
        CHARACTER_OVERLAY,
        CHARACTER_SIZE,
        CHARACTER_OVERLAY_RGBA_SHA256,
        "elite Lightning Sorcerer character overlay",
    )
    move_overlay = _require_overlay(
        MOVE_OVERLAY,
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
        _validate_outputs(character, move, animation_text)
        print(
            "LIGHTNING_SORCERER_ELITE_ASSETS_CHECK_OK "
            f"character_changed={EXPECTED_CHARACTER_CHANGED_PIXELS} "
            f"move_changed={EXPECTED_MOVE_CHANGED_PIXELS}"
        )
        return

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
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
