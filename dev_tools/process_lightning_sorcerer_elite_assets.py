#!/usr/bin/env python3
"""Build the Elite Lightning Sorcerer with a deterministic violet palette swap.

The ordinary Lightning Sorcerer sheets are the only geometry and animation
sources.  The elite version follows the proven Frost Sorcerer contract: every
approved source-ramp color maps to one fixed elite-ramp color everywhere, while
alpha, silhouettes, poses, frame placement, and all other colors remain exact.
"""

from __future__ import annotations

import argparse
import hashlib
from collections import OrderedDict
from pathlib import Path

from PIL import Image

from process_frost_sorcerer_assets import (
    CHARACTER_FRAME_SIZE,
    MOVE_FRAME_COUNT,
    _assert_move_strip_contract,
)
from process_lightning_sorcerer_assets import _assert_lightning_gait_contract


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_DIR = ROOT / "resources/texture"
ANIMATION_DIR = ROOT / "resources/animation"

BASE_CHARACTER = TEXTURE_DIR / "lightning_sorcerer.png"
BASE_MOVE = TEXTURE_DIR / "lightning_sorcerer_move.png"
CHARACTER_OUTPUT = TEXTURE_DIR / "lightning_sorcerer_elite.png"
MOVE_OUTPUT = TEXTURE_DIR / "lightning_sorcerer_elite_move.png"
ANIMATION_OUTPUT = ANIMATION_DIR / "lightning_sorcerer_elite.tres"

CHARACTER_SIZE = (160, 160)
MOVE_SIZE = (320, 40)
GRID_COLUMNS = 4
GRID_ROWS = 4
MAX_RUNTIME_COLORS = 23

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
CHARACTER_OUTPUT_RGBA_SHA256 = (
    "4a8bebf01e2e5aa7c4357329809d31d00b07b9cd6942d48ebf906d28f90d8fd3"
)
MOVE_OUTPUT_RGBA_SHA256 = (
    "b01fecc50a83b526af526688a54f9878a4f96f3bba66c56bbeab1eaabb1f3992"
)

# As with the elite Frost Sorcerer, this is a true indexed-style ramp swap.
# The eight ordinary gold/yellow shades keep their saturation and value while
# moving to a single 275-degree violet hue.  Dark brown/neutral shading is not
# touched, so material depth and line work stay identical to the ordinary art.
VIOLET_PALETTE_MAP = {
    (154, 113, 33, 255): (104, 33, 154, 255),
    (223, 184, 42, 255): (148, 42, 223, 255),
    (248, 216, 56, 255): (168, 56, 248, 255),
    (251, 226, 70, 255): (176, 70, 251, 255),
    (253, 236, 80, 255): (181, 80, 253, 255),
    (248, 239, 171, 255): (216, 171, 248, 255),
    (253, 249, 173, 255): (220, 173, 253, 255),
    (253, 250, 203, 255): (232, 203, 253, 255),
}
ELITE_VIOLET_PALETTE = frozenset(VIOLET_PALETTE_MAP.values())

EXPECTED_CHARACTER_CHANGED_PER_FRAME = (
    167,
    155,
    172,
    151,
    147,
    119,
    126,
    163,
    187,
    117,
    143,
    165,
    138,
    145,
    186,
    75,
)
EXPECTED_MOVE_CHANGED_PER_FRAME = (
    178,
    150,
    154,
    175,
    165,
    144,
    146,
    169,
)

ANIMATIONS = OrderedDict(
    [
        ("move", (0, 12.0, True)),
        ("windup", (1, 6.0, False)),
        ("attack", (2, 8.0, False)),
        ("death", (3, 7.0, False)),
    ]
)


class EliteAssetContractError(RuntimeError):
    """Raised when the approved palette-swap asset contract drifts."""


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _alpha_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").getchannel("A").tobytes()).hexdigest()


def _load_base(
    path: Path,
    expected_size: tuple[int, int],
    expected_rgba_hash: str,
    expected_alpha_hash: str,
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
    if rgba_hash != expected_rgba_hash:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {rgba_hash}"
        )
    alpha_hash = _alpha_sha256(image)
    if alpha_hash != expected_alpha_hash:
        raise EliteAssetContractError(
            f"{label} alpha fingerprint changed: {alpha_hash}"
        )
    alpha_values = set(image.getchannel("A").getdata())
    if not alpha_values.issubset({0, 255}):
        raise EliteAssetContractError(
            f"{label} must use binary alpha, got {sorted(alpha_values)}"
        )
    return image


def _apply_violet_palette(base: Image.Image) -> Image.Image:
    result = base.copy()
    result.putdata(
        [VIOLET_PALETTE_MAP.get(pixel, pixel) for pixel in base.getdata()]
    )
    return result


def _frame_changed_counts(
    base: Image.Image,
    elite: Image.Image,
    columns: int,
    rows: int,
) -> tuple[int, ...]:
    counts: list[int] = []
    for index in range(columns * rows):
        row, column = divmod(index, columns)
        bounds = (
            column * CHARACTER_FRAME_SIZE,
            row * CHARACTER_FRAME_SIZE,
            (column + 1) * CHARACTER_FRAME_SIZE,
            (row + 1) * CHARACTER_FRAME_SIZE,
        )
        base_frame = base.crop(bounds)
        elite_frame = elite.crop(bounds)
        counts.append(
            sum(
                base_pixel != elite_pixel
                for base_pixel, elite_pixel in zip(
                    base_frame.getdata(), elite_frame.getdata()
                )
            )
        )
    return tuple(counts)


def _assert_palette_swap(
    base: Image.Image,
    elite: Image.Image,
    columns: int,
    rows: int,
    expected_changed_per_frame: tuple[int, ...],
    expected_output_hash: str,
    label: str,
) -> None:
    if elite.size != base.size:
        raise EliteAssetContractError(f"{label} output size changed")
    if elite.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise EliteAssetContractError(f"{label} alpha differs from the normal sprite")

    for index, (base_pixel, elite_pixel) in enumerate(
        zip(base.getdata(), elite.getdata())
    ):
        expected = VIOLET_PALETTE_MAP.get(base_pixel, base_pixel)
        if elite_pixel != expected:
            x = index % base.width
            y = index // base.width
            raise EliteAssetContractError(
                f"{label} pixel {(x, y)} violates the fixed palette map"
            )

    actual_counts = _frame_changed_counts(base, elite, columns, rows)
    if actual_counts != expected_changed_per_frame:
        raise EliteAssetContractError(
            f"{label} changed-per-frame counts are {actual_counts}, "
            f"expected {expected_changed_per_frame}"
        )

    visible_colors = {pixel for pixel in elite.getdata() if pixel[3] == 255}
    if len(visible_colors) != MAX_RUNTIME_COLORS:
        raise EliteAssetContractError(
            f"{label} uses {len(visible_colors)} visible colors, "
            f"expected {MAX_RUNTIME_COLORS}"
        )
    used_violets = visible_colors.intersection(ELITE_VIOLET_PALETTE)
    if used_violets != ELITE_VIOLET_PALETTE:
        raise EliteAssetContractError(
            f"{label} does not use the complete eight-color violet ramp"
        )
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in elite.getdata()):
        raise EliteAssetContractError(
            f"{label} transparent RGB payload must remain zero"
        )

    output_hash = _rgba_sha256(elite)
    if output_hash != expected_output_hash:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {output_hash}"
        )
    print(
        f"VIOLET_PALETTE_SWAP {label} "
        f"changed_per_frame={actual_counts} changed_total={sum(actual_counts)} "
        f"violet_levels={len(used_violets)} alpha=identical"
    )


def _build_character(base: Image.Image) -> Image.Image:
    elite = _apply_violet_palette(base)
    _assert_palette_swap(
        base,
        elite,
        GRID_COLUMNS,
        GRID_ROWS,
        EXPECTED_CHARACTER_CHANGED_PER_FRAME,
        CHARACTER_OUTPUT_RGBA_SHA256,
        "elite Lightning Sorcerer character",
    )
    return elite


def _build_move(base: Image.Image) -> Image.Image:
    elite = _apply_violet_palette(base)
    _assert_palette_swap(
        base,
        elite,
        MOVE_FRAME_COUNT,
        1,
        EXPECTED_MOVE_CHANGED_PER_FRAME,
        MOVE_OUTPUT_RGBA_SHA256,
        "elite Lightning Sorcerer move",
    )
    _assert_move_strip_contract(elite, "elite lightning sorcerer move")
    _assert_lightning_gait_contract(elite)
    return elite


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
        '[gd_resource type="SpriteFrames" format=3 uid="uid://cwdlo03coum0b"]',
        "",
        '[ext_resource type="Texture2D" uid="uid://b36yt8ewr3axr" path="res://resources/texture/lightning_sorcerer_elite.png" id="1_texture"]',
        '[ext_resource type="Texture2D" uid="uid://dql2aoi5h4ivq" path="res://resources/texture/lightning_sorcerer_elite_move.png" id="2_move"]',
        "",
    ]
    for name in sorted(ANIMATIONS):
        row = ANIMATIONS[name][0]
        frame_count = MOVE_FRAME_COUNT if name == "move" else GRID_COLUMNS
        texture_id = "2_move" if name == "move" else "1_texture"
        for column in range(frame_count):
            lines.extend(
                [
                    f'[sub_resource type="AtlasTexture" id="AtlasTexture_{name}_{column}"]',
                    f'atlas = ExtResource("{texture_id}")',
                    f"region = Rect2({column * CHARACTER_FRAME_SIZE}, {0 if name == 'move' else row * CHARACTER_FRAME_SIZE}, {CHARACTER_FRAME_SIZE}, {CHARACTER_FRAME_SIZE})",
                    "filter_clip = true",
                    "",
                ]
            )
    entries = [
        _animation_entry(name, values[1], values[2])
        for name, values in sorted(ANIMATIONS.items())
    ]
    lines.extend(["[resource]", f"animations = [{', '.join(entries)}]", ""])
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
        raise EliteAssetContractError(f"Missing SpriteFrames: {ANIMATION_OUTPUT}")
    if ANIMATION_OUTPUT.read_text(encoding="utf-8") != animation_text:
        raise EliteAssetContractError("Generated elite SpriteFrames is stale")


def main(check_only: bool = False) -> None:
    base_character = _load_base(
        BASE_CHARACTER,
        CHARACTER_SIZE,
        BASE_CHARACTER_RGBA_SHA256,
        BASE_CHARACTER_ALPHA_SHA256,
        "normal Lightning Sorcerer character",
    )
    base_move = _load_base(
        BASE_MOVE,
        MOVE_SIZE,
        BASE_MOVE_RGBA_SHA256,
        BASE_MOVE_ALPHA_SHA256,
        "normal Lightning Sorcerer move",
    )
    character = _build_character(base_character)
    move = _build_move(base_move)
    animation_text = _sprite_frames_text()

    if check_only:
        _validate_outputs(character, move, animation_text)
        print(
            "LIGHTNING_SORCERER_ELITE_ASSETS_CHECK_OK "
            f"character_sha256={_rgba_sha256(character)} "
            f"move_sha256={_rgba_sha256(move)}"
        )
        return

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
    character.save(CHARACTER_OUTPUT, optimize=True)
    move.save(MOVE_OUTPUT, optimize=True)
    ANIMATION_OUTPUT.write_text(animation_text, encoding="utf-8", newline="\n")
    print(
        "LIGHTNING_SORCERER_ELITE_ASSETS_OK "
        f"character_sha256={_rgba_sha256(character)} "
        f"move_sha256={_rgba_sha256(move)} "
        "palette_swap=fixed_8_level_h275 alpha_and_geometry=base_identical"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()
    main(arguments.check_only)
