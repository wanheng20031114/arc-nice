from __future__ import annotations

import argparse
import hashlib
from collections import OrderedDict
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
BASE_CHARACTER = ROOT / "resources/texture/frost_sorcerer.png"
CHARACTER_OUTPUT = ROOT / "resources/texture/frost_sorcerer_elite.png"
ANIMATION_OUTPUT = ROOT / "resources/animation/frost_sorcerer_elite.tres"

CHARACTER_SIZE = (160, 160)
FRAME_SIZE = 40
GRID_COLUMNS = 4
GRID_ROWS = 4

BASE_RGBA_SHA256 = (
    "6051e5c62bebf29148afff7d4f4e80f779e27dcbb69976612f20c4b0f63bb5d0"
)
BASE_ALPHA_SHA256 = (
    "801535eb97bc6b23dad07ba1e16b2ac131bb059b21e8065bd9817fe23a8fa691"
)
ELITE_RGBA_SHA256 = (
    "e9760aa252ae498be826db57027b0aeab7bdbbe7689b53271dbc8469414a78dc"
)
EXPECTED_CHANGED_PIXELS = 1594

# The ordinary Frost Sorcerer's approved geometry is authoritative. Only six
# internal blue highlight ramps become the brighter cyan/pale-cyan elite ramp.
CYAN_PALETTE_MAP = {
    (30, 145, 201, 255): (12, 205, 220, 255),
    (90, 158, 192, 255): (8, 166, 190, 255),
    (86, 200, 242, 255): (35, 236, 242, 255),
    (84, 217, 251, 255): (69, 246, 250, 255),
    (126, 224, 251, 255): (184, 251, 255, 255),
    (181, 234, 249, 255): (222, 254, 255, 255),
}

ANIMATIONS = OrderedDict(
    [
        ("move", (0, 6.0, True)),
        ("windup", (1, 6.0, False)),
        ("attack", (2, 8.0, False)),
        ("death", (3, 7.0, False)),
    ]
)


class EliteAssetContractError(RuntimeError):
    """Raised when the elite atlas drifts from the approved base atlas."""


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _alpha_sha256(image: Image.Image) -> str:
    return hashlib.sha256(
        image.convert("RGBA").getchannel("A").tobytes()
    ).hexdigest()


def _frame_bbox(image: Image.Image, frame_index: int):
    row, column = divmod(frame_index, GRID_COLUMNS)
    frame = image.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )
    return frame.getchannel("A").getbbox()


def _load_base() -> Image.Image:
    if not BASE_CHARACTER.is_file():
        raise FileNotFoundError(f"Missing Frost Sorcerer atlas: {BASE_CHARACTER}")
    image = Image.open(BASE_CHARACTER).convert("RGBA")
    if image.size != CHARACTER_SIZE:
        raise EliteAssetContractError(
            f"Base atlas is {image.size}, expected {CHARACTER_SIZE}"
        )
    rgba_hash = _rgba_sha256(image)
    if rgba_hash != BASE_RGBA_SHA256:
        raise EliteAssetContractError(
            f"Base Frost Sorcerer RGBA fingerprint changed: {rgba_hash}"
        )
    alpha_hash = _alpha_sha256(image)
    if alpha_hash != BASE_ALPHA_SHA256:
        raise EliteAssetContractError(
            f"Base Frost Sorcerer alpha fingerprint changed: {alpha_hash}"
        )
    return image


def _build_elite(base: Image.Image) -> Image.Image:
    result = base.copy()
    changed_pixels = 0
    source_pixels = base.load()
    result_pixels = result.load()
    for y in range(base.height):
        for x in range(base.width):
            mapped = CYAN_PALETTE_MAP.get(source_pixels[x, y])
            if mapped is None:
                continue
            result_pixels[x, y] = mapped
            changed_pixels += 1

    if changed_pixels != EXPECTED_CHANGED_PIXELS:
        raise EliteAssetContractError(
            "Elite cyan pixel count changed: "
            f"{changed_pixels}, expected {EXPECTED_CHANGED_PIXELS}"
        )
    if result.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise EliteAssetContractError("Elite character alpha changed")
    for frame_index in range(GRID_COLUMNS * GRID_ROWS):
        if _frame_bbox(result, frame_index) != _frame_bbox(base, frame_index):
            raise EliteAssetContractError(
                f"Elite frame {frame_index} alpha bounds changed"
            )
    result_hash = _rgba_sha256(result)
    if result_hash != ELITE_RGBA_SHA256:
        raise EliteAssetContractError(
            f"Elite Frost Sorcerer RGBA fingerprint changed: {result_hash}"
        )
    return result


def _animation_entry(name: str, speed: float, loop: bool) -> str:
    frames = [
        "{\n"
        '"duration": 1.0,\n'
        f'"texture": SubResource("AtlasTexture_{name}_{column}")\n'
        "}"
        for column in range(GRID_COLUMNS)
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
            'path="res://resources/texture/frost_sorcerer_elite.png" '
            'id="1_texture"]'
        ),
        "",
    ]
    for name in sorted(ANIMATIONS):
        row = ANIMATIONS[name][0]
        for column in range(GRID_COLUMNS):
            lines.extend(
                [
                    (
                        '[sub_resource type="AtlasTexture" '
                        f'id="AtlasTexture_{name}_{column}"]'
                    ),
                    'atlas = ExtResource("1_texture")',
                    (
                        f"region = Rect2({column * FRAME_SIZE}, "
                        f"{row * FRAME_SIZE}, {FRAME_SIZE}, {FRAME_SIZE})"
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


def _validate_outputs(elite: Image.Image, expected_animation: str) -> None:
    if not CHARACTER_OUTPUT.is_file():
        raise EliteAssetContractError(
            f"Missing generated elite atlas: {CHARACTER_OUTPUT}"
        )
    existing = Image.open(CHARACTER_OUTPUT).convert("RGBA")
    if existing.tobytes() != elite.tobytes():
        raise EliteAssetContractError("Generated elite atlas is stale")
    if not ANIMATION_OUTPUT.is_file():
        raise EliteAssetContractError(
            f"Missing generated SpriteFrames: {ANIMATION_OUTPUT}"
        )
    if ANIMATION_OUTPUT.read_text(encoding="utf-8") != expected_animation:
        raise EliteAssetContractError("Generated elite SpriteFrames is stale")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the deterministic Elite Frost Sorcerer atlas."
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate committed outputs without rewriting them.",
    )
    args = parser.parse_args()

    base = _load_base()
    elite = _build_elite(base)
    animation_text = _sprite_frames_text()
    if args.check_only:
        _validate_outputs(elite, animation_text)
        print(
            "FROST_SORCERER_ELITE_ASSETS_CHECK_OK "
            f"changed_pixels={EXPECTED_CHANGED_PIXELS}"
        )
        return

    CHARACTER_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    ANIMATION_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    elite.save(CHARACTER_OUTPUT, optimize=True)
    ANIMATION_OUTPUT.write_text(
        animation_text,
        encoding="utf-8",
        newline="\n",
    )
    print(
        "FROST_SORCERER_ELITE_ASSETS_OK "
        f"character={elite.width}x{elite.height} "
        f"changed_pixels={EXPECTED_CHANGED_PIXELS} "
        f"rgba_sha256={ELITE_RGBA_SHA256} "
        "alpha_and_frame_bounds=base_identical"
    )


if __name__ == "__main__":
    main()
