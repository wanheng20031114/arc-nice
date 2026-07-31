#!/usr/bin/env python3
"""Build the yellow-edge Elite Lightning Sorcerer deterministically.

Purple is derived only from continuous yellow garment-edge components in a
fixed body-relative region.  Brown cloth, the crown, staff and lightning magic
remain untouched, so no independently authored purple pixels can blink between
animation frames.
"""

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
    "ed4093c1dc27cd0177927cc83382e5d10aeadfb1a7a378007fc4a71fc37dfdb1"
)
ELITE_MOVE_RGBA_SHA256 = (
    "21d02156ce08cfddf0f36b00cba074a593b30923dd8075e4cc3c6dbad629fa3b"
)
EXPECTED_CHARACTER_CHANGED_PIXELS = 762
EXPECTED_MOVE_CHANGED_PIXELS = 327
CHARACTER_OVERLAY_RGBA_SHA256 = (
    "a4d7d928fc614f88af2954a338e8f9c869390a88e3d13bcae69bdda2b342ab78"
)
MOVE_OVERLAY_RGBA_SHA256 = (
    "4b9ca500d8895ab3f62981ba978ee899fcc3662e427cd93791d9bbe1d8c164d5"
)
EXPECTED_CHARACTER_CHANGED_PER_FRAME = (
    49,
    43,
    58,
    48,
    48,
    52,
    65,
    48,
    49,
    27,
    37,
    48,
    44,
    39,
    69,
    38,
)
EXPECTED_MOVE_CHANGED_PER_FRAME = (54, 42, 41, 48, 41, 24, 31, 46)
GARMENT_EDGE_RECT = (7, 18, 18, 36)
MIN_EDGE_COMPONENT_PIXELS = 3
YELLOW_EDGE_COLORS = {
    (154, 113, 33, 255),
    (223, 184, 42, 255),
    (248, 216, 56, 255),
    (251, 226, 70, 255),
    (253, 236, 80, 255),
    (248, 239, 171, 255),
    (253, 249, 173, 255),
}
PURPLE_COLORS = {
    (68, 20, 109, 255),
    (109, 39, 175, 255),
}
YELLOW_TO_PURPLE = {
    color: (68, 20, 109, 255)
    if sum(color[:3]) < 500
    else (109, 39, 175, 255)
    for color in YELLOW_EDGE_COLORS
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


def _connected_components(
    positions: set[tuple[int, int]],
) -> list[set[tuple[int, int]]]:
    remaining = set(positions)
    components: list[set[tuple[int, int]]] = []
    while remaining:
        seed = remaining.pop()
        component = {seed}
        frontier = [seed]
        while frontier:
            x, y = frontier.pop()
            for offset_y in (-1, 0, 1):
                for offset_x in (-1, 0, 1):
                    neighbour = (x + offset_x, y + offset_y)
                    if neighbour not in remaining:
                        continue
                    remaining.remove(neighbour)
                    component.add(neighbour)
                    frontier.append(neighbour)
        components.append(component)
    return components


def _build_frame_edge_overlay(base_frame: Image.Image) -> Image.Image:
    left, top, right, bottom = GARMENT_EDGE_RECT
    edge_positions = {
        (x, y)
        for y in range(top, bottom)
        for x in range(left, right)
        if base_frame.getpixel((x, y)) in YELLOW_EDGE_COLORS
    }
    accepted_positions = set().union(
        *(
            component
            for component in _connected_components(edge_positions)
            if len(component) >= MIN_EDGE_COMPONENT_PIXELS
        )
    )
    overlay = Image.new(
        "RGBA",
        (FRAME_SIZE, FRAME_SIZE),
        (0, 0, 0, 0),
    )
    for position in accepted_positions:
        overlay.putpixel(
            position,
            YELLOW_TO_PURPLE[base_frame.getpixel(position)],
        )
    return overlay


def _build_edge_overlay(base: Image.Image, label: str) -> Image.Image:
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    frame_counts: list[int] = []
    frame_rows = base.height // FRAME_SIZE
    frame_columns = base.width // FRAME_SIZE
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
            frame_overlay = _build_frame_edge_overlay(frame)
            overlay.alpha_composite(
                frame_overlay,
                (column * FRAME_SIZE, row * FRAME_SIZE),
            )
            frame_counts.append(len(_overlay_positions(frame_overlay)))
    print(
        "ELITE_PURPLE_EDGE_PLACEMENT "
        f"{label} counts={tuple(frame_counts)} "
        f"region={GARMENT_EDGE_RECT} "
        f"minimum_component={MIN_EDGE_COMPONENT_PIXELS}"
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
        if source_pixel not in YELLOW_EDGE_COLORS:
            raise EliteAssetContractError(
                f"{label} overlay covered non-yellow-edge color at {position}: "
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
    print(
        "ELITE_PURPLE_EDGE_CONTRACT "
        f"{label} changed={changed_pixels} "
        f"palette_colors={len(PURPLE_COLORS)} "
        "source=continuous_yellow_garment_edges"
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
    character_overlay = _build_edge_overlay(
        base_character,
        "character",
    )
    _assert_overlay_contract(
        character_overlay,
        CHARACTER_SIZE,
        CHARACTER_OVERLAY_RGBA_SHA256,
        "elite Lightning Sorcerer character overlay",
    )
    move_overlay = _build_edge_overlay(
        base_move,
        "move",
    )
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
