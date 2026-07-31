#!/usr/bin/env python3
"""Build the elite Fire Sorcerer from approved imagegen references.

The current Fire Sorcerer sheets are the only geometry sources.  Character
alpha, frame bounds, anchors, poses, and dark outlines remain byte-identical.
Two visually reviewed native overlays add narrow gold garment trim and blue
spell fire to the legacy atlas. The eight-pose move is built from its own
imagegen color reference, then projected onto the ordinary move strip so alpha,
frame bounds, anchors, and poses remain ordinary-version identical. The
projectile sheet keeps every source pixel in place and maps its warm hue ramp
to blue/cyan while preserving HSV value exactly.
"""

from __future__ import annotations

from collections import OrderedDict
import colorsys
import hashlib
from pathlib import Path

import numpy as np
from PIL import Image

from process_frost_sorcerer_assets import (
    MOVE_FRAME_COUNT,
    _assert_move_strip_contract,
    _build_move_strip,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/fire_sorcerer_elite"
TEXTURE_DIR = ROOT / "resources/texture"
ANIMATION_DIR = ROOT / "resources/animation"

BASE_CHARACTER = TEXTURE_DIR / "fire_sorcerer.png"
BASE_MOVE = TEXTURE_DIR / "fire_sorcerer_move.png"
BASE_FIREBALL = TEXTURE_DIR / "fire_sorcerer_fireball.png"
GOLD_TRIM_OVERLAY = (
    SOURCE_DIR / "fire_sorcerer_elite_gold_trim_overlay.png"
)
BLUE_SPELL_OVERLAY = (
    SOURCE_DIR / "fire_sorcerer_elite_blue_spell_overlay.png"
)
MOVE_DESIGN_SOURCE = (
    SOURCE_DIR / "fire_sorcerer_elite_move_8pose_alpha_reference.png"
)

CHARACTER_OUTPUT = TEXTURE_DIR / "fire_sorcerer_elite.png"
MOVE_OUTPUT = TEXTURE_DIR / "fire_sorcerer_elite_move.png"
FIREBALL_OUTPUT = TEXTURE_DIR / "fire_sorcerer_elite_fireball.png"
CHARACTER_ANIMATION_OUTPUT = (
    ANIMATION_DIR / "fire_sorcerer_elite.tres"
)
FIREBALL_ANIMATION_OUTPUT = (
    ANIMATION_DIR / "fire_sorcerer_elite_fireball.tres"
)
CHARACTER_ANIMATION_UID = "uid://cxfdrr74r2fs3"
CHARACTER_TEXTURE_UID = "uid://cugjgvssmflbk"
FIREBALL_ANIMATION_UID = "uid://dbks4i83dyqs"
FIREBALL_TEXTURE_UID = "uid://c37hu2lcntuax"

CHARACTER_SIZE = (160, 160)
FIREBALL_SIZE = (128, 128)
CHARACTER_FRAME_SIZE = 40
FIREBALL_FRAME_SIZE = 32
MOVE_TARGET_HEIGHTS = (29, 28, 29, 30, 30, 28, 29, 30)
GRID_COLUMNS = 4
GRID_ROWS = 4

BASE_CHARACTER_RGBA_SHA256 = (
    "3966c6167e8a986847eb91b912cb65f2531de6783e120d430d28172a3ba00d30"
)
BASE_CHARACTER_ALPHA_SHA256 = (
    "5cb916ca22f7c31a569b814e4f0fc2f39f88723e69f5d2ee59c0c0f9d6ffdb3f"
)
BASE_FIREBALL_RGBA_SHA256 = (
    "32e5d7202aefae8d1ce5e2d21c69d7c0e5bc393790d3f37a9f233dab22994c51"
)
BASE_FIREBALL_ALPHA_SHA256 = (
    "268864e914a754cf4190a611559e00633ef7bf01024897b372fe007529c3e43d"
)
GOLD_TRIM_OVERLAY_RGBA_SHA256 = (
    "a2da5833d8532b349aa651e2a469c746c714eb8f4a0f7e664015c742e8cd8a27"
)
BLUE_SPELL_OVERLAY_RGBA_SHA256 = (
    "909dac43f414d878dd29156ab6a363c799907bb87528d0eecce1be92f1edd8ef"
)
ELITE_CHARACTER_RGBA_SHA256 = (
    "60e9968d7925714bb9da373ab2e319cf9b296f3858d979c4625cba6dc0082b72"
)
ELITE_FIREBALL_RGBA_SHA256 = (
    "28694bc4d2780a432eea104d19614c4f878e76f0f368fb2755a1ec56c4f54aec"
)
ELITE_MOVE_RGBA_SHA256 = (
    "9b1f2f55a81011b1d42ef796ce3318ae3c668c530f2d455fb93558d9297a3699"
)
EXPECTED_MOVE_CHANGED_PIXELS = 585

GOLD_COLORS = {
    (132, 76, 8, 255),
    (218, 145, 20, 255),
    (255, 214, 92, 255),
}
EXPECTED_GOLD_PIXELS_PER_FRAME = (
    53,
    39,
    46,
    43,
    37,
    33,
    37,
    42,
    32,
    33,
    37,
    37,
    41,
    29,
    18,
    3,
)
EXPECTED_BLUE_SPELL_PIXELS_PER_FRAME = (
    16,
    14,
    9,
    9,
    20,
    14,
    15,
    25,
    41,
    97,
    86,
    18,
    0,
    0,
    0,
    0,
)

CHARACTER_ANIMATIONS = OrderedDict(
    [
        ("move", (0, 12.0, True)),
        ("windup", (1, 6.0, False)),
        ("attack", (2, 8.0, False)),
        ("death", (3, 7.0, False)),
    ]
)
FIREBALL_ANIMATIONS = OrderedDict(
    [
        ("fly", (0, 12.0, True)),
        ("spawn", (1, 8.0, False)),
        ("impact", (2, 12.0, False)),
        ("expire", (3, 12.0, False)),
    ]
)


class EliteAssetContractError(RuntimeError):
    """Raised when an elite visual would drift from the approved base."""


def _decoded_rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _alpha_sha256(image: Image.Image) -> str:
    return hashlib.sha256(
        image.convert("RGBA").getchannel("A").tobytes()
    ).hexdigest()


def _require_image(
    path: Path,
    expected_size: tuple[int, int],
    expected_rgba_sha256: str,
    label: str,
) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(f"Missing {label}: {path}")
    image = Image.open(path).convert("RGBA")
    if image.size != expected_size:
        raise EliteAssetContractError(
            f"{label} is {image.size}, expected {expected_size}"
        )
    actual_sha256 = _decoded_rgba_sha256(image)
    if actual_sha256 != expected_rgba_sha256:
        raise EliteAssetContractError(
            f"{label} RGBA fingerprint changed: {actual_sha256}"
        )
    return image


def _assert_binary_alpha(image: Image.Image, label: str) -> None:
    values = set(image.getchannel("A").getdata())
    if not values.issubset({0, 255}):
        raise EliteAssetContractError(
            f"{label} alpha must be binary, got {sorted(values)}"
        )


def _save_if_decoded_changed(image: Image.Image, path: Path) -> None:
    if path.is_file():
        existing = Image.open(path).convert("RGBA")
        if existing.size == image.size and existing.tobytes() == image.tobytes():
            return
    image.save(path, optimize=True)


def _frame_bbox(
    image: Image.Image,
    frame_size: int,
    frame_index: int,
) -> tuple[int, int, int, int] | None:
    row, column = divmod(frame_index, GRID_COLUMNS)
    frame = image.crop(
        (
            column * frame_size,
            row * frame_size,
            (column + 1) * frame_size,
            (row + 1) * frame_size,
        )
    )
    return frame.getchannel("A").getbbox()


def _overlay_positions(
    overlay: Image.Image,
) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(overlay.height)
        for x in range(overlay.width)
        if overlay.getpixel((x, y))[3] > 0
    }


def _per_frame_overlay_counts(
    overlay: Image.Image,
) -> tuple[int, ...]:
    counts: list[int] = []
    for frame_index in range(GRID_COLUMNS * GRID_ROWS):
        row, column = divmod(frame_index, GRID_COLUMNS)
        frame = overlay.crop(
            (
                column * CHARACTER_FRAME_SIZE,
                row * CHARACTER_FRAME_SIZE,
                (column + 1) * CHARACTER_FRAME_SIZE,
                (row + 1) * CHARACTER_FRAME_SIZE,
            )
        )
        counts.append(
            sum(1 for alpha in frame.getchannel("A").getdata() if alpha)
        )
    return tuple(counts)


def _luma(color: tuple[int, int, int]) -> float:
    red, green, blue = color
    return red * 0.2126 + green * 0.7152 + blue * 0.0722


def _validate_character_overlays(
    base: Image.Image,
    gold: Image.Image,
    blue: Image.Image,
) -> tuple[
    set[tuple[int, int]],
    set[tuple[int, int]],
]:
    _assert_binary_alpha(gold, "gold trim overlay")
    _assert_binary_alpha(blue, "blue spell overlay")
    gold_positions = _overlay_positions(gold)
    blue_positions = _overlay_positions(blue)
    if gold_positions & blue_positions:
        raise EliteAssetContractError(
            "Gold trim and blue spell overlays overlap"
        )
    if _per_frame_overlay_counts(gold) != EXPECTED_GOLD_PIXELS_PER_FRAME:
        raise EliteAssetContractError(
            "Gold trim per-frame pixel counts changed"
        )
    if (
        _per_frame_overlay_counts(blue)
        != EXPECTED_BLUE_SPELL_PIXELS_PER_FRAME
    ):
        raise EliteAssetContractError(
            "Blue spell per-frame pixel counts changed"
        )

    for position in gold_positions:
        base_pixel = base.getpixel(position)
        overlay_pixel = gold.getpixel(position)
        if base_pixel[3] == 0:
            raise EliteAssetContractError(
                f"Gold trim left the base silhouette at {position}"
            )
        if overlay_pixel not in GOLD_COLORS:
            raise EliteAssetContractError(
                f"Unapproved gold color {overlay_pixel} at {position}"
            )
        if _luma(base_pixel[:3]) <= 60.0:
            raise EliteAssetContractError(
                f"Gold trim covered a dark outline pixel at {position}"
            )

    for position in blue_positions:
        base_pixel = base.getpixel(position)
        overlay_pixel = blue.getpixel(position)
        if base_pixel[3] == 0:
            raise EliteAssetContractError(
                f"Blue spell left the base silhouette at {position}"
            )
        hue, saturation, value = colorsys.rgb_to_hsv(
            overlay_pixel[0] / 255.0,
            overlay_pixel[1] / 255.0,
            overlay_pixel[2] / 255.0,
        )
        if (
            value > 0.05
            and saturation >= 0.2
            and not 188.0 <= hue * 360.0 <= 232.0
        ):
            raise EliteAssetContractError(
                f"Blue spell hue drifted at {position}: {hue * 360.0:.2f}"
            )
        if max(overlay_pixel[:3]) != max(base_pixel[:3]):
            raise EliteAssetContractError(
                f"Blue spell value changed at {position}"
            )
    return gold_positions, blue_positions


def _build_character_sheet(
    base: Image.Image,
    gold: Image.Image,
    blue: Image.Image,
) -> Image.Image:
    gold_positions, blue_positions = _validate_character_overlays(
        base,
        gold,
        blue,
    )
    result = base.copy()
    for position in gold_positions:
        result.putpixel(position, gold.getpixel(position))
    for position in blue_positions:
        result.putpixel(position, blue.getpixel(position))

    if result.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise EliteAssetContractError("Elite character alpha changed")
    for frame_index in range(GRID_COLUMNS * GRID_ROWS):
        if _frame_bbox(
            result,
            CHARACTER_FRAME_SIZE,
            frame_index,
        ) != _frame_bbox(base, CHARACTER_FRAME_SIZE, frame_index):
            raise EliteAssetContractError(
                f"Elite character frame {frame_index} bbox changed"
            )
    changed_positions = {
        (x, y)
        for y in range(base.height)
        for x in range(base.width)
        if result.getpixel((x, y)) != base.getpixel((x, y))
    }
    if changed_positions != gold_positions | blue_positions:
        raise EliteAssetContractError(
            "Elite character changes escaped the approved overlays"
        )
    result_sha256 = _decoded_rgba_sha256(result)
    if result_sha256 != ELITE_CHARACTER_RGBA_SHA256:
        raise EliteAssetContractError(
            f"Elite character fingerprint changed: {result_sha256}"
        )
    return result


def _build_elite_move(palette_reference: Image.Image) -> Image.Image:
    if not BASE_MOVE.is_file():
        raise FileNotFoundError(f"Missing base Fire Sorcerer move: {BASE_MOVE}")
    base = Image.open(BASE_MOVE).convert("RGBA")
    _assert_move_strip_contract(base, "base fire sorcerer move")

    design = _build_move_strip(
        MOVE_DESIGN_SOURCE,
        palette_reference,
        "elite fire sorcerer move design",
        target_heights=MOVE_TARGET_HEIGHTS,
    )
    _assert_move_strip_contract(design, "elite fire sorcerer move design")

    base_rgba = np.asarray(base, dtype=np.uint8)
    design_rgba = np.asarray(design, dtype=np.uint8)
    base_visible = base_rgba[:, :, 3] == 255
    design_visible = design_rgba[:, :, 3] == 255
    overlap = base_visible & design_visible
    union = base_visible | design_visible
    overlap_ratio = float(np.count_nonzero(overlap)) / float(
        np.count_nonzero(union)
    )
    if overlap_ratio < 0.95:
        raise EliteAssetContractError(
            "Elite move design drifted too far from the base geometry: "
            f"IoU={overlap_ratio:.3f}"
        )

    approved_color_mask = np.zeros(base_visible.shape, dtype=bool)
    for y, x in np.argwhere(overlap):
        pixel = tuple(int(value) for value in design_rgba[y, x])
        hue, saturation, value = colorsys.rgb_to_hsv(
            pixel[0] / 255.0,
            pixel[1] / 255.0,
            pixel[2] / 255.0,
        )
        is_blue_spell = (
            value > 0.05
            and saturation >= 0.2
            and 188.0 <= hue * 360.0 <= 232.0
        )
        if pixel in GOLD_COLORS or is_blue_spell:
            approved_color_mask[y, x] = True

    result_rgba = base_rgba.copy()
    result_rgba[:, :, :3][approved_color_mask] = design_rgba[:, :, :3][
        approved_color_mask
    ]
    result_rgba[~base_visible] = (0, 0, 0, 0)
    result = Image.fromarray(result_rgba)
    if result.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise EliteAssetContractError("Elite move alpha changed")
    _assert_move_strip_contract(result, "elite fire sorcerer move")
    changed_pixels = int(
        np.count_nonzero(np.any(result_rgba != base_rgba, axis=2))
    )
    if changed_pixels != EXPECTED_MOVE_CHANGED_PIXELS:
        raise EliteAssetContractError(
            "Elite move color projection changed: "
            f"{changed_pixels}, expected {EXPECTED_MOVE_CHANGED_PIXELS}"
        )
    result_hash = _decoded_rgba_sha256(result)
    if result_hash != ELITE_MOVE_RGBA_SHA256:
        raise EliteAssetContractError(
            f"Elite move fingerprint changed: {result_hash}"
        )
    print(
        "ELITE_MOVE_COLOR_PROJECTION "
        f"design_iou={overlap_ratio:.3f} changed_pixels={changed_pixels}"
    )
    return result


def _map_fireball_pixel(
    pixel: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    red, green, blue, alpha = pixel
    if alpha == 0:
        return 0, 0, 0, 0
    hue, saturation, value = colorsys.rgb_to_hsv(
        red / 255.0,
        green / 255.0,
        blue / 255.0,
    )
    hue_degrees = hue * 360.0
    if hue_degrees >= 300.0:
        hue_degrees -= 360.0
    ramp_position = max(
        0.0,
        min(1.0, (hue_degrees + 15.0) / 90.0),
    )
    blue_hue = (230.0 - 40.0 * ramp_position) / 360.0
    mapped = colorsys.hsv_to_rgb(
        blue_hue,
        max(saturation, 0.55),
        value,
    )
    return (
        round(mapped[0] * 255.0),
        round(mapped[1] * 255.0),
        round(mapped[2] * 255.0),
        255,
    )


def _build_fireball_sheet(base: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, (0, 0, 0, 0))
    source_pixels = base.load()
    result_pixels = result.load()
    for y in range(base.height):
        for x in range(base.width):
            result_pixels[x, y] = _map_fireball_pixel(
                source_pixels[x, y]
            )

    if result.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise EliteAssetContractError("Elite fireball alpha changed")
    for frame_index in range(GRID_COLUMNS * GRID_ROWS):
        if _frame_bbox(
            result,
            FIREBALL_FRAME_SIZE,
            frame_index,
        ) != _frame_bbox(base, FIREBALL_FRAME_SIZE, frame_index):
            raise EliteAssetContractError(
                f"Elite fireball frame {frame_index} bbox changed"
            )
    for source_pixel, result_pixel in zip(
        base.getdata(),
        result.getdata(),
        strict=True,
    ):
        if source_pixel[3] == 0:
            if result_pixel != (0, 0, 0, 0):
                raise EliteAssetContractError(
                    "Elite fireball transparent RGB payload changed"
                )
            continue
        if max(source_pixel[:3]) != max(result_pixel[:3]):
            raise EliteAssetContractError(
                "Elite fireball HSV value changed"
            )
        hue, saturation, value = colorsys.rgb_to_hsv(
            result_pixel[0] / 255.0,
            result_pixel[1] / 255.0,
            result_pixel[2] / 255.0,
        )
        if (
            value > 0.05
            and saturation >= 0.2
            and not 188.0 <= hue * 360.0 <= 232.0
        ):
            raise EliteAssetContractError(
                f"Elite fireball hue is not blue/cyan: {hue * 360.0:.2f}"
            )
    result_sha256 = _decoded_rgba_sha256(result)
    if result_sha256 != ELITE_FIREBALL_RGBA_SHA256:
        raise EliteAssetContractError(
            f"Elite fireball fingerprint changed: {result_sha256}"
        )
    return result


def _animation_entry(
    name: str,
    speed: float,
    loop: bool,
    frame_count: int,
) -> str:
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


def _write_sprite_frames(
    output_path: Path,
    texture_path: str,
    frame_size: int,
    animations: OrderedDict[str, tuple[int, float, bool]],
    resource_uid: str,
    texture_uid: str,
    move_texture_path: str | None = None,
) -> None:
    lines = [
        (
            '[gd_resource type="SpriteFrames" format=3 '
            f'uid="{resource_uid}"]'
        ),
        "",
        (
            f'[ext_resource type="Texture2D" uid="{texture_uid}" '
            f'path="{texture_path}" '
            'id="1_texture"]'
        ),
        "",
    ]
    if move_texture_path is not None:
        lines.extend(
            [
                (
                    '[ext_resource type="Texture2D" '
                    f'path="{move_texture_path}" id="2_move"]'
                ),
                "",
            ]
        )
    animation_names = sorted(animations)
    for name in animation_names:
        row = animations[name][0]
        uses_move_strip = name == "move" and move_texture_path is not None
        frame_count = MOVE_FRAME_COUNT if uses_move_strip else GRID_COLUMNS
        texture_id = "2_move" if uses_move_strip else "1_texture"
        for column in range(frame_count):
            lines.extend(
                [
                    (
                        '[sub_resource type="AtlasTexture" '
                        f'id="AtlasTexture_{name}_{column}"]'
                    ),
                    f'atlas = ExtResource("{texture_id}")',
                    (
                        f"region = Rect2({column * frame_size}, "
                        f"{0 if uses_move_strip else row * frame_size}, "
                        f"{frame_size}, {frame_size})"
                    ),
                    "filter_clip = true",
                    "",
                ]
            )
    entries = [
        _animation_entry(
            name,
            animations[name][1],
            animations[name][2],
            (
                MOVE_FRAME_COUNT
                if name == "move" and move_texture_path is not None
                else GRID_COLUMNS
            ),
        )
        for name in animation_names
    ]
    lines.extend(
        [
            "[resource]",
            f"animations = [{', '.join(entries)}]",
            "",
        ]
    )
    output_path.write_text(
        "\n".join(lines),
        encoding="utf-8",
        newline="\n",
    )


def main() -> None:
    base_character = _require_image(
        BASE_CHARACTER,
        CHARACTER_SIZE,
        BASE_CHARACTER_RGBA_SHA256,
        "base Fire Sorcerer sheet",
    )
    base_fireball = _require_image(
        BASE_FIREBALL,
        FIREBALL_SIZE,
        BASE_FIREBALL_RGBA_SHA256,
        "base Fire Sorcerer fireball sheet",
    )
    if _alpha_sha256(base_character) != BASE_CHARACTER_ALPHA_SHA256:
        raise EliteAssetContractError(
            "Base Fire Sorcerer character alpha fingerprint changed"
        )
    if _alpha_sha256(base_fireball) != BASE_FIREBALL_ALPHA_SHA256:
        raise EliteAssetContractError(
            "Base Fire Sorcerer fireball alpha fingerprint changed"
        )
    gold_overlay = _require_image(
        GOLD_TRIM_OVERLAY,
        CHARACTER_SIZE,
        GOLD_TRIM_OVERLAY_RGBA_SHA256,
        "gold trim overlay",
    )
    blue_spell_overlay = _require_image(
        BLUE_SPELL_OVERLAY,
        CHARACTER_SIZE,
        BLUE_SPELL_OVERLAY_RGBA_SHA256,
        "blue spell overlay",
    )

    character_sheet = _build_character_sheet(
        base_character,
        gold_overlay,
        blue_spell_overlay,
    )
    move_strip = _build_elite_move(character_sheet)
    fireball_sheet = _build_fireball_sheet(base_fireball)
    _assert_binary_alpha(character_sheet, "elite character sheet")
    _assert_binary_alpha(fireball_sheet, "elite fireball sheet")

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
    _save_if_decoded_changed(character_sheet, CHARACTER_OUTPUT)
    _save_if_decoded_changed(move_strip, MOVE_OUTPUT)
    _save_if_decoded_changed(fireball_sheet, FIREBALL_OUTPUT)
    _write_sprite_frames(
        CHARACTER_ANIMATION_OUTPUT,
        "res://resources/texture/fire_sorcerer_elite.png",
        CHARACTER_FRAME_SIZE,
        CHARACTER_ANIMATIONS,
        CHARACTER_ANIMATION_UID,
        CHARACTER_TEXTURE_UID,
        "res://resources/texture/fire_sorcerer_elite_move.png",
    )
    _write_sprite_frames(
        FIREBALL_ANIMATION_OUTPUT,
        "res://resources/texture/fire_sorcerer_elite_fireball.png",
        FIREBALL_FRAME_SIZE,
        FIREBALL_ANIMATIONS,
        FIREBALL_ANIMATION_UID,
        FIREBALL_TEXTURE_UID,
    )

    print(
        "FIRE_SORCERER_ELITE_ASSETS_OK "
        f"character={character_sheet.width}x{character_sheet.height} "
        f"gold_pixels={sum(EXPECTED_GOLD_PIXELS_PER_FRAME)} "
        f"blue_spell_pixels={sum(EXPECTED_BLUE_SPELL_PIXELS_PER_FRAME)} "
        f"character_sha256={ELITE_CHARACTER_RGBA_SHA256} "
        f"move={move_strip.width}x{move_strip.height} "
        f"move_sha256={ELITE_MOVE_RGBA_SHA256} "
        f"fireball={fireball_sheet.width}x{fireball_sheet.height} "
        f"fireball_sha256={ELITE_FIREBALL_RGBA_SHA256} "
        "alpha_and_frame_bounds=base_identical"
    )


if __name__ == "__main__":
    main()
