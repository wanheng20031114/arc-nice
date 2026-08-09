#!/usr/bin/env python3
"""Audit the approved elite-gunner atlases and their runtime frame contract."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = (
    ROOT / "dev_assets" / "source_images" / "combat_robot_gunner_elite"
)
MANIFEST_PATH = SOURCE_ROOT / "combat_robot_gunner_elite_final_candidate_manifest.json"
APPROVED_SHEET_PATH = SOURCE_ROOT / "combat_robot_gunner_elite_final_candidate.png"
APPROVED_BULLET_PATH = (
    SOURCE_ROOT / "combat_robot_gunner_elite_bullet_final_candidate.png"
)
RUNTIME_ROOT = ROOT / "resources" / "texture" / "enemy" / "mechanical_life"
RUNTIME_SHEET_PATH = RUNTIME_ROOT / "combat_robot_gunner_elite.png"
RUNTIME_BULLET_PATH = RUNTIME_ROOT / "combat_robot_gunner_elite_bullet.png"
ANIMATION_PATH = ROOT / "resources" / "animation" / "combat_robot_gunner_elite.tres"
BULLET_ANIMATION_PATH = (
    ROOT / "resources" / "animation" / "combat_robot_gunner_elite_bullet.tres"
)

APPROVED_SELECTION = {
    "move": "M1",
    "fire": "S2",
    "death": "D2",
    "bullet": "B1",
}
APPROVED_SHEET_SHA256 = (
    "5c19a616ab277c27df25089a20ba9260deb37428bd531856a48b844f8284b03f"
)
APPROVED_BULLET_SHA256 = (
    "600016b26f904bdde24485474100ed91757c3a8bc479be6e8337e25d6a7fb830"
)
TRANSPARENT = (0, 0, 0, 0)
OUTLINE = (21, 22, 19, 255)
STEEL_AND_PURPLE_PALETTE = {
    TRANSPARENT,
    (21, 22, 19, 255),
    (29, 28, 30, 255),
    (55, 59, 63, 255),
    (74, 36, 105, 255),
    (82, 88, 94, 255),
    (112, 121, 128, 255),
    (125, 54, 179, 255),
    (151, 159, 164, 255),
    (157, 78, 221, 255),
    (190, 196, 198, 255),
    (197, 138, 255, 255),
}
PURPLE_PALETTE = {
    (74, 36, 105, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
}
ORDINARY_RED_ORANGE = {
    (102, 25, 20, 255),
    (185, 75, 80, 255),
    (190, 48, 31, 255),
    (236, 28, 36, 255),
    (239, 92, 34, 255),
    (255, 0, 0, 255),
    (255, 181, 71, 255),
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _frame(sheet: Image.Image, column: int, row: int) -> Image.Image:
    return sheet.crop((column * 32, row * 32, (column + 1) * 32, (row + 1) * 32))


def _assert_pixel_contract(image: Image.Image, label: str) -> None:
    if image.mode != "RGBA":
        raise AssertionError(f"{label}: expected RGBA, got {image.mode}")
    unexpected: set[tuple[int, int, int, int]] = set()
    for pixel in image.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{label}: alpha must be binary")
        if pixel[3] == 0 and pixel != TRANSPARENT:
            raise AssertionError(f"{label}: transparent RGB must be zero")
        if pixel not in STEEL_AND_PURPLE_PALETTE:
            unexpected.add(pixel)
    if unexpected:
        raise AssertionError(f"{label}: colors outside fixed palette: {sorted(unexpected)}")


def _assert_robot_frames(sheet: Image.Image) -> None:
    frames: list[Image.Image] = []
    for row in range(6):
        for column in range(8):
            frame = _frame(sheet, column, row)
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                raise AssertionError(f"Empty robot frame row={row} column={column}")
            left, top, right, bottom = bbox
            if right - left > 28 or bottom - top > 28:
                raise AssertionError(
                    f"Robot frame row={row} column={column} exceeds 28x28: {bbox}"
                )
            if bottom != 28:
                raise AssertionError(
                    f"Robot frame row={row} column={column} baseline drifted: {bbox}"
                )
            frames.append(frame)
    if len(frames) != 48:
        raise AssertionError(f"Expected 48 robot frames, found {len(frames)}")

    move_frames = frames[:8]
    leg_alpha = {
        frame.crop((9, 22, 23, 28)).getchannel("A").tobytes()
        for frame in move_frames
    }
    if len(leg_alpha) != 8:
        raise AssertionError("M1 must preserve eight unique move leg phases")
    # The corrected G1 crown is an attached flat lip at y=8. It must not add
    # detached gray pixels above the chassis in either movement or firing rows.
    for index, frame in enumerate(frames[:40]):
        forbidden = [
            frame.getpixel((x, 7))
            for x in range(10, 22)
            if x not in (12, 13, 14)
        ]
        if any(pixel != TRANSPARENT for pixel in forbidden):
            raise AssertionError(f"Living frame {index} restored detached crown pixels")
        if any(frame.getpixel((x, 8)) != OUTLINE for x in range(10, 22)):
            raise AssertionError(f"Living frame {index} lost the attached flat crown lip")

    visible_colors = {pixel for pixel in sheet.getdata() if pixel[3] > 0}
    if not visible_colors.intersection(PURPLE_PALETTE):
        raise AssertionError("Elite robot atlas contains no purple functional pixels")
    if visible_colors.intersection(ORDINARY_RED_ORANGE):
        raise AssertionError("Elite robot atlas still contains ordinary red-orange accents")


def _assert_bullet_frames(sheet: Image.Image) -> None:
    masks: list[bytes] = []
    for index in range(3):
        frame = sheet.crop((index * 12, 0, index * 12 + 12, 8))
        bbox = frame.getchannel("A").getbbox()
        if bbox != (2, 3, 11, 6):
            raise AssertionError(f"Bullet {index} must keep strict 9x3 bbox, got {bbox}")
        masks.append(frame.getchannel("A").tobytes())
    if len(set(masks)) != 1:
        raise AssertionError("B1 bullet alpha silhouette must stay identical across frames")
    visible_colors = {pixel for pixel in sheet.getdata() if pixel[3] > 0}
    if not visible_colors or not visible_colors.issubset(PURPLE_PALETTE):
        raise AssertionError("B1 bullet must use only the approved purple palette")


def _assert_animation_contract() -> None:
    text = ANIMATION_PATH.read_text(encoding="utf-8")
    required_texture = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_gunner_elite.png"'
    )
    if text.count(required_texture) != 1:
        raise AssertionError("Elite SpriteFrames must bind the elite atlas exactly once")
    if text.count('id="AtlasTexture_move_') != 8:
        raise AssertionError("Elite move must declare eight atlas frames")
    if text.count('id="AtlasTexture_fire_') != 32:
        raise AssertionError("Elite fire matrix must declare 32 atlas frames")
    if text.count('id="AtlasTexture_death_') != 8:
        raise AssertionError("Elite death must declare eight atlas frames")
    expected = {
        "move": (14.0, True),
        "fire": (25.0, True),
        "fire_walk": (25.0, True),
        "death": (12.0, False),
    }
    for name, (speed, loop) in expected.items():
        pattern = re.compile(
            rf'"loop": {str(loop).lower()},\s*"name": &"{name}",\s*"speed": {speed:.1f}',
            re.MULTILINE,
        )
        if pattern.search(text) is None:
            raise AssertionError(
                f"Animation {name} changed speed={speed} loop={loop}"
            )

    bullet_text = BULLET_ANIMATION_PATH.read_text(encoding="utf-8")
    bullet_texture = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_gunner_elite_bullet.png"'
    )
    if bullet_text.count(bullet_texture) != 1:
        raise AssertionError("Elite bullet SpriteFrames must bind its atlas once")
    if bullet_text.count('id="AtlasTexture_gunner_bullet_') != 3:
        raise AssertionError("Elite bullet must declare three atlas frames")
    if not re.search(
        r'"loop": true,\s*"name": &"fly",\s*"speed": 25\.0', bullet_text
    ):
        raise AssertionError("Elite bullet fly animation must remain 3 frames at 25 FPS")


def _assert_manifest() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("approved_anchor") != "G1":
        raise AssertionError("Final runtime must retain the approved G1 anchor")
    if manifest.get("approved_selection") != APPROVED_SELECTION:
        raise AssertionError("Final runtime selection is not M1/S2/D2/B1")
    if (
        manifest.get("stage") != "runtime_integrated"
        or manifest.get("final_human_approved") is not True
        or manifest.get("runtime_written") is not True
        or manifest.get("preview_only") is not False
    ):
        raise AssertionError("Final approval/runtime integration was not recorded")
    runtime_approval = manifest.get("runtime_approval", {})
    if runtime_approval.get("imagegen_pixels_imported") is not False:
        raise AssertionError("Runtime pixels must remain deterministic, not ImageGen imports")


def main() -> int:
    required = (
        MANIFEST_PATH,
        APPROVED_SHEET_PATH,
        APPROVED_BULLET_PATH,
        RUNTIME_SHEET_PATH,
        RUNTIME_BULLET_PATH,
        ANIMATION_PATH,
        BULLET_ANIMATION_PATH,
    )
    for path in required:
        if not path.is_file():
            raise AssertionError(f"Missing required file: {path.relative_to(ROOT)}")
    _assert_manifest()
    if _sha256(APPROVED_SHEET_PATH) != APPROVED_SHEET_SHA256:
        raise AssertionError("Approved M1/S2/D2 sheet SHA changed")
    if _sha256(RUNTIME_SHEET_PATH) != APPROVED_SHEET_SHA256:
        raise AssertionError("Runtime robot atlas is not byte-identical to approval")
    if _sha256(APPROVED_BULLET_PATH) != APPROVED_BULLET_SHA256:
        raise AssertionError("Approved B1 bullet SHA changed")
    if _sha256(RUNTIME_BULLET_PATH) != APPROVED_BULLET_SHA256:
        raise AssertionError("Runtime bullet atlas is not byte-identical to approval")

    sheet = Image.open(RUNTIME_SHEET_PATH).convert("RGBA")
    bullet = Image.open(RUNTIME_BULLET_PATH).convert("RGBA")
    if sheet.size != (256, 192):
        raise AssertionError(f"Robot atlas must be 256x192, got {sheet.size}")
    if bullet.size != (36, 8):
        raise AssertionError(f"Bullet atlas must be 36x8, got {bullet.size}")
    _assert_pixel_contract(sheet, "robot atlas")
    _assert_pixel_contract(bullet, "bullet atlas")
    _assert_robot_frames(sheet)
    _assert_bullet_frames(bullet)
    _assert_animation_contract()
    print(
        "COMBAT_ROBOT_GUNNER_ELITE_ASSET_AUDIT_OK "
        f"sheet={APPROVED_SHEET_SHA256} bullet={APPROVED_BULLET_SHA256} "
        "robot_frames=48 bullet_frames=3"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
