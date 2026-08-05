#!/usr/bin/env python3
"""Build the approved ninja robot runtime sheet and SpriteFrames deterministically.

Only the user-approved native M1/S1/D1 strips are copied. ImageGen source
pixels are never sampled here, and no resize, resample or palette conversion is
performed during the runtime build.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import Image

from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORY = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_ninja"
)
TEXTURE_OUTPUT = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_ninja.png"
)
ANIMATION_OUTPUT = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_ninja.tres"
)
RESOURCE_TEXTURE_PATH = (
    "res://resources/texture/enemy/mechanical_life/combat_robot_ninja.png"
)
RESOURCE_TEXTURE_UID = "uid://cir5jg41q8dif"
SPRITE_FRAMES_UID = "uid://d4k7v2qpbm9s1"

FRAME_SIZE = 40
FRAME_COUNT = 8
SHEET_SIZE = (FRAME_SIZE * FRAME_COUNT, FRAME_SIZE * 3)
BASELINE_Y = 32
MAX_VISIBLE_SIZE = 28
TRANSPARENT = (0, 0, 0, 0)
ALLOWED_PIXELS = set(PALETTE) | {TRANSPARENT}

ANIMATIONS = (
    {
        "name": "move",
        "source": "combat_robot_ninja_move_m1_candidate_native.png",
        "sha256": "07af3470d29a39c0d541b499fa671716153e3a673402caa692a6b9bde7e5efa6",
        "row": 0,
        "speed": 20.0,
        "loop": True,
    },
    {
        "name": "boost",
        "source": "combat_robot_ninja_boost_s1_candidate_native.png",
        "sha256": "0caf9cef8ed8723c5b0e49f0c7dc2c78a2ccf6e252c71e6bf1eb5e99d7cb609f",
        "row": 1,
        "speed": 24.0,
        "loop": True,
    },
    {
        "name": "death",
        "source": "combat_robot_ninja_death_d1_candidate_native.png",
        "sha256": "22c987eaf26692722ec0a77fc9a9720c4a6a1b785ddc97733c55748c13276b58",
        "row": 2,
        "speed": 12.0,
        "loop": False,
    },
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_approved_strip(spec: dict[str, object]) -> Image.Image:
    path = SOURCE_DIRECTORY / str(spec["source"])
    if not path.is_file():
        raise FileNotFoundError(f"Missing approved ninja strip: {path}")
    actual_hash = _sha256(path)
    if actual_hash != spec["sha256"]:
        raise AssertionError(
            f"Approved {spec['name']} strip changed: {actual_hash}"
        )
    image = Image.open(path).convert("RGBA")
    if image.size != (FRAME_SIZE * FRAME_COUNT, FRAME_SIZE):
        raise AssertionError(
            f"Approved {spec['name']} strip is {image.size}, expected 320x40"
        )
    unexpected = set(image.getdata()) - ALLOWED_PIXELS
    if unexpected:
        raise AssertionError(
            f"Approved {spec['name']} strip has pixels outside the fixed palette: "
            f"{sorted(unexpected)}"
        )
    for frame_index in range(FRAME_COUNT):
        frame = image.crop(
            (
                frame_index * FRAME_SIZE,
                0,
                (frame_index + 1) * FRAME_SIZE,
                FRAME_SIZE,
            )
        )
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError(f"{spec['name']}[{frame_index}] is empty")
        visible_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])
        if max(visible_size) > MAX_VISIBLE_SIZE:
            raise AssertionError(
                f"{spec['name']}[{frame_index}] bbox {bbox} exceeds 28x28"
            )
        if bbox[3] != BASELINE_Y:
            raise AssertionError(
                f"{spec['name']}[{frame_index}] baseline {bbox[3]} != 32"
            )
    return image


def _sprite_frames_text() -> str:
    lines = [
        (
            '[gd_resource type="SpriteFrames" format=3 '
            f'uid="{SPRITE_FRAMES_UID}"]'
        ),
        "",
        (
            f'[ext_resource type="Texture2D" uid="{RESOURCE_TEXTURE_UID}" '
            f'path="{RESOURCE_TEXTURE_PATH}" id="1_texture"]'
        ),
        "",
    ]
    for spec in ANIMATIONS:
        name = str(spec["name"])
        row = int(spec["row"])
        for frame_index in range(FRAME_COUNT):
            lines.extend(
                [
                    (
                        '[sub_resource type="AtlasTexture" '
                        f'id="AtlasTexture_{name}_{frame_index}"]'
                    ),
                    'atlas = ExtResource("1_texture")',
                    (
                        "region = Rect2("
                        f"{frame_index * FRAME_SIZE}, {row * FRAME_SIZE}, "
                        f"{FRAME_SIZE}, {FRAME_SIZE})"
                    ),
                    "filter_clip = true",
                    "",
                ]
            )
    lines.extend(["[resource]", "animations = ["])
    animation_blocks: list[str] = []
    for spec in ANIMATIONS:
        name = str(spec["name"])
        frame_blocks = [
            (
                '{\n"duration": 1.0,\n'
                f'"texture": SubResource("AtlasTexture_{name}_{frame_index}")\n}}'
            )
            for frame_index in range(FRAME_COUNT)
        ]
        animation_blocks.append(
            "{\n"
            '"frames": ['
            + ", ".join(frame_blocks)
            + "],\n"
            + f'"loop": {str(bool(spec["loop"])).lower()},\n'
            + f'"name": &"{name}",\n'
            + f'"speed": {float(spec["speed"]):.1f}\n'
            + "}"
        )
    lines.append(", ".join(animation_blocks))
    lines.append("]")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    approved_strips = [_load_approved_strip(spec) for spec in ANIMATIONS]
    runtime_sheet = Image.new("RGBA", SHEET_SIZE, TRANSPARENT)
    for spec, strip in zip(ANIMATIONS, approved_strips):
        runtime_sheet.alpha_composite(strip, (0, int(spec["row"]) * FRAME_SIZE))

    TEXTURE_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    ANIMATION_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    runtime_sheet.save(
        TEXTURE_OUTPUT,
        format="PNG",
        optimize=False,
        compress_level=9,
    )
    ANIMATION_OUTPUT.write_text(_sprite_frames_text(), encoding="utf-8")
    print(
        "COMBAT_ROBOT_NINJA_RUNTIME_ASSETS_OK "
        f"texture_sha256={_sha256(TEXTURE_OUTPUT)} "
        f"texture={TEXTURE_OUTPUT} animation={ANIMATION_OUTPUT}"
    )


if __name__ == "__main__":
    main()
