#!/usr/bin/env python3
"""Build the fully redesigned Elite Lightning Sorcerer deterministically.

The runtime sprites are sampled from complete imagegen character redraws.  The
ordinary Lightning Sorcerer contributes only the established 40x40 frame
bounds, while purple is kept as coherent garment panels rather than an overlay.
"""

from __future__ import annotations

import argparse
import hashlib
from collections import Counter, OrderedDict
from pathlib import Path

from PIL import Image

from process_frost_sorcerer_assets import (
    CHARACTER_FRAME_SIZE,
    MOVE_BODY_MARKER,
    MOVE_FRAME_COUNT,
    MOVE_GROUND_Y,
    MOVE_TARGET_HEIGHTS,
    _assemble_horizontal_strip,
    _assemble_sheet,
    _assert_move_strip_contract,
    _frame_bbox,
    _load_grid_subjects,
    _normalize_alpha,
    _place_character_in_reference_bounds,
    _place_move_subject,
    _quantize_to_reference_palette,
    _quantize_visible_colors,
    _subject_crop,
)
from process_lightning_sorcerer_assets import _assert_lightning_gait_contract


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_DIR = ROOT / "resources/texture"
ANIMATION_DIR = ROOT / "resources/animation"
SOURCE_DIR = ROOT / "dev_assets/source_images/lightning_sorcerer_elite"

BASE_CHARACTER = TEXTURE_DIR / "lightning_sorcerer.png"
CHARACTER_SOURCE = (
    SOURCE_DIR / "lightning_sorcerer_elite_full_redesign_v3_alpha.png"
)
MOVE_SOURCE = (
    SOURCE_DIR
    / "lightning_sorcerer_elite_move_8pose_full_redesign_v4_alpha.png"
)
CHARACTER_OUTPUT = TEXTURE_DIR / "lightning_sorcerer_elite.png"
MOVE_OUTPUT = TEXTURE_DIR / "lightning_sorcerer_elite_move.png"
ANIMATION_OUTPUT = ANIMATION_DIR / "lightning_sorcerer_elite.tres"

CHARACTER_SIZE = (160, 160)
MOVE_SIZE = (320, 40)
GRID_COLUMNS = 4
GRID_ROWS = 4
MOVE_SOURCE_COLUMNS = 4
MOVE_SOURCE_ROWS = 2
CHARACTER_PALETTE_COLORS = 24
MIN_PURPLE_COMPONENT_PIXELS = 3
CHARACTER_PURPLE_RANGE = (45, 100)
MOVE_PURPLE_RANGE = (55, 100)

BASE_CHARACTER_ALPHA_SHA256 = (
    "4e277d4385f7f3169fed9da807b4f57c233aa350b2823ae6c5d1099a3805b073"
)
CHARACTER_SOURCE_RGBA_SHA256 = (
    "9e25caa41272426c44595f435fd253aa6ab132038cfb84bbafa02367319bdce4"
)
MOVE_SOURCE_RGBA_SHA256 = (
    "7a946cbc397212976238b1e7cad895c2c3df43547304ad4adc01bba509396ba4"
)
CHARACTER_OUTPUT_RGBA_SHA256 = (
    "3252f31e179def073230973afddc93116557353c1e939797ee92d80b4a78ee61"
)
MOVE_OUTPUT_RGBA_SHA256 = (
    "2ec6e135de41eb3343fcd9e00e9d23a169f721676fabd328f0e3d21d1f2b127d"
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
    """Raised when the approved full-redesign asset contract drifts."""


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _load_pinned_source(
    path: Path,
    expected_hash: str,
    label: str,
) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    image = Image.open(path).convert("RGBA")
    actual_hash = _rgba_sha256(image)
    if actual_hash != expected_hash:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {actual_hash}"
        )
    return image


def _load_base_character() -> Image.Image:
    if not BASE_CHARACTER.is_file():
        raise FileNotFoundError(BASE_CHARACTER)
    image = Image.open(BASE_CHARACTER).convert("RGBA")
    if image.size != CHARACTER_SIZE:
        raise EliteAssetContractError(
            f"base Lightning Sorcerer is {image.size}, expected {CHARACTER_SIZE}"
        )
    alpha_hash = hashlib.sha256(image.getchannel("A").tobytes()).hexdigest()
    if alpha_hash != BASE_CHARACTER_ALPHA_SHA256:
        raise EliteAssetContractError(
            f"base Lightning Sorcerer alpha fingerprint changed: {alpha_hash}"
        )
    return image


def _is_purple(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return alpha == 255 and blue >= red + 15 and blue >= green + 40


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


def _replacement_color(
    frame: Image.Image,
    component: set[tuple[int, int]],
) -> tuple[int, int, int, int]:
    neighbours: list[tuple[int, int, int, int]] = []
    for radius in range(1, 5):
        for x, y in component:
            for candidate_y in range(max(0, y - radius), min(40, y + radius + 1)):
                for candidate_x in range(
                    max(0, x - radius), min(40, x + radius + 1)
                ):
                    position = (candidate_x, candidate_y)
                    pixel = frame.getpixel(position)
                    if position in component or pixel[3] != 255 or _is_purple(pixel):
                        continue
                    neighbours.append(pixel)
        if neighbours:
            break
    if not neighbours:
        raise EliteAssetContractError("isolated purple has no visible neighbour")
    counts = Counter(neighbours)
    return sorted(counts, key=lambda color: (-counts[color], color))[0]


def _remove_isolated_purple(
    image: Image.Image,
    columns: int,
    rows: int,
    label: str,
) -> Image.Image:
    result = image.copy()
    removed = 0
    for row in range(rows):
        for column in range(columns):
            left = column * CHARACTER_FRAME_SIZE
            top = row * CHARACTER_FRAME_SIZE
            frame = result.crop(
                (left, top, left + CHARACTER_FRAME_SIZE, top + CHARACTER_FRAME_SIZE)
            )
            purple = {
                (x, y)
                for y in range(CHARACTER_FRAME_SIZE)
                for x in range(CHARACTER_FRAME_SIZE)
                if _is_purple(frame.getpixel((x, y)))
            }
            for component in _connected_components(purple):
                if len(component) >= MIN_PURPLE_COMPONENT_PIXELS:
                    continue
                replacement = _replacement_color(frame, component)
                for position in component:
                    frame.putpixel(position, replacement)
                    removed += 1
            result.paste(frame, (left, top))
    print(f"PURPLE_SPECK_CLEANUP {label} removed={removed}")
    return result


def _assert_binary_alpha(image: Image.Image, label: str) -> None:
    alpha_values = set(image.getchannel("A").getdata())
    if not alpha_values.issubset({0, 255}):
        raise EliteAssetContractError(
            f"{label} alpha must be binary, got {sorted(alpha_values)}"
        )
    if any(
        pixel[3] == 0 and pixel[:3] != (0, 0, 0)
        for pixel in image.getdata()
    ):
        raise EliteAssetContractError(
            f"{label} transparent RGB payload must be zero"
        )


def _assert_purple_garments(
    image: Image.Image,
    columns: int,
    rows: int,
    expected_range: tuple[int, int],
    label: str,
) -> tuple[int, ...]:
    counts: list[int] = []
    for row in range(rows):
        for column in range(columns):
            frame = image.crop(
                (
                    column * CHARACTER_FRAME_SIZE,
                    row * CHARACTER_FRAME_SIZE,
                    (column + 1) * CHARACTER_FRAME_SIZE,
                    (row + 1) * CHARACTER_FRAME_SIZE,
                )
            )
            purple = {
                (x, y)
                for y in range(CHARACTER_FRAME_SIZE)
                for x in range(CHARACTER_FRAME_SIZE)
                if _is_purple(frame.getpixel((x, y)))
            }
            components = _connected_components(purple)
            if any(len(component) < MIN_PURPLE_COMPONENT_PIXELS for component in components):
                raise EliteAssetContractError(
                    f"{label} frame {len(counts)} has an isolated purple speck"
                )
            count = len(purple)
            if not expected_range[0] <= count <= expected_range[1]:
                raise EliteAssetContractError(
                    f"{label} frame {len(counts)} has {count} purple pixels, "
                    f"expected {expected_range[0]}..{expected_range[1]}"
                )
            counts.append(count)
    print(f"PURPLE_GARMENT_CONTRACT {label} counts={tuple(counts)}")
    return tuple(counts)


def _build_character_sheet(base: Image.Image) -> Image.Image:
    _load_pinned_source(
        CHARACTER_SOURCE,
        CHARACTER_SOURCE_RGBA_SHA256,
        "elite character imagegen source",
    )
    subjects = _load_grid_subjects(
        CHARACTER_SOURCE,
        "elite_lightning_character",
    )
    frames: list[Image.Image] = []
    for index, subject in enumerate(subjects):
        row, column = divmod(index, GRID_COLUMNS)
        bbox = _frame_bbox(base, row, column)
        frames.append(
            _place_character_in_reference_bounds(
                subject,
                bbox,
                f"elite_lightning_character_{row}_{column}",
            )
        )
    sheet = _quantize_visible_colors(
        _assemble_sheet(frames, CHARACTER_FRAME_SIZE),
        CHARACTER_PALETTE_COLORS,
    )
    sheet = _remove_isolated_purple(sheet, GRID_COLUMNS, GRID_ROWS, "character")
    _assert_binary_alpha(sheet, "elite Lightning Sorcerer character")
    for row in range(GRID_ROWS):
        for column in range(GRID_COLUMNS):
            if _frame_bbox(sheet, row, column) != _frame_bbox(base, row, column):
                raise EliteAssetContractError(
                    f"character frame {row}:{column} escaped ordinary bounds"
                )
    _assert_purple_garments(
        sheet,
        GRID_COLUMNS,
        GRID_ROWS,
        CHARACTER_PURPLE_RANGE,
        "character",
    )
    return sheet


def _load_move_subjects() -> list[Image.Image]:
    sheet = _load_pinned_source(
        MOVE_SOURCE,
        MOVE_SOURCE_RGBA_SHA256,
        "elite move imagegen source",
    )
    subjects: list[Image.Image] = []
    for row in range(MOVE_SOURCE_ROWS):
        for column in range(MOVE_SOURCE_COLUMNS):
            left = round(column * sheet.width / MOVE_SOURCE_COLUMNS)
            right = round((column + 1) * sheet.width / MOVE_SOURCE_COLUMNS)
            top = round(row * sheet.height / MOVE_SOURCE_ROWS)
            bottom = round((row + 1) * sheet.height / MOVE_SOURCE_ROWS)
            cell = _normalize_alpha(sheet.crop((left, top, right, bottom)))
            bbox = cell.getchannel("A").getbbox()
            if bbox is None:
                raise EliteAssetContractError(
                    f"elite move source frame {row}:{column} is empty"
                )
            if bbox[0] < 4 or bbox[1] < 4 or bbox[2] > cell.width - 4 or bbox[3] > cell.height - 4:
                raise EliteAssetContractError(
                    f"elite move source frame {row}:{column} touches its cell edge"
                )
            subjects.append(
                _subject_crop(cell, f"elite_lightning_move_{row}_{column}")
            )
    if len(subjects) != MOVE_FRAME_COUNT:
        raise EliteAssetContractError(
            f"elite move source has {len(subjects)} frames, expected {MOVE_FRAME_COUNT}"
        )
    return subjects


def _repair_move_contacts(strip: Image.Image) -> Image.Image:
    """Preserve the authored gait while making F2/F5 ground contacts explicit."""
    result = strip.copy()

    frame_two = result.crop((80, 0, 120, 40))
    raised_boot = frame_two.crop((20, 34, 25, 39))
    for y in range(34, 39):
        for x in range(20, 25):
            frame_two.putpixel((x, y), (0, 0, 0, 0))
    frame_two.alpha_composite(raised_boot, (22, 31))
    result.paste(frame_two, (80, 0))

    frame_five_left = 5 * CHARACTER_FRAME_SIZE
    result.putpixel(
        (frame_five_left + 13, MOVE_GROUND_Y),
        result.getpixel((frame_five_left + 12, MOVE_GROUND_Y)),
    )
    return result


def _build_move_strip(character: Image.Image) -> Image.Image:
    subjects = _load_move_subjects()
    frames = [
        _place_move_subject(
            subject,
            MOVE_TARGET_HEIGHTS[index],
            0,
            f"elite_lightning_move_{index}",
        )
        for index, subject in enumerate(subjects)
    ]
    strip = _quantize_to_reference_palette(
        _assemble_horizontal_strip(frames),
        character,
    )
    strip = _remove_isolated_purple(strip, MOVE_FRAME_COUNT, 1, "move")
    strip = _repair_move_contacts(strip)
    _assert_binary_alpha(strip, "elite Lightning Sorcerer move")
    _assert_move_strip_contract(strip, "elite lightning sorcerer move")
    _assert_lightning_gait_contract(strip)
    _assert_purple_garments(
        strip,
        MOVE_FRAME_COUNT,
        1,
        MOVE_PURPLE_RANGE,
        "move",
    )
    return strip


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
    base = _load_base_character()
    character = _build_character_sheet(base)
    move = _build_move_strip(character)
    character_hash = _rgba_sha256(character)
    move_hash = _rgba_sha256(move)
    if character_hash != CHARACTER_OUTPUT_RGBA_SHA256:
        raise EliteAssetContractError(
            f"elite character fingerprint changed: {character_hash}"
        )
    if move_hash != MOVE_OUTPUT_RGBA_SHA256:
        raise EliteAssetContractError(
            f"elite move fingerprint changed: {move_hash}"
        )
    animation_text = _sprite_frames_text()

    if check_only:
        _validate_outputs(character, move, animation_text)
        print(
            "LIGHTNING_SORCERER_ELITE_ASSETS_CHECK_OK "
            f"character_sha256={character_hash} "
            f"move_sha256={move_hash}"
        )
        return

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
    character.save(CHARACTER_OUTPUT, optimize=True)
    move.save(MOVE_OUTPUT, optimize=True)
    ANIMATION_OUTPUT.write_text(animation_text, encoding="utf-8", newline="\n")
    print(
        "LIGHTNING_SORCERER_ELITE_ASSETS_OK "
        f"character_sha256={character_hash} "
        f"move_sha256={move_hash} "
        f"body_marker={MOVE_BODY_MARKER}"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()
    main(arguments.check_only)
