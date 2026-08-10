#!/usr/bin/env python3
"""Audit the approved elite shield-bearer runtime atlases and frame resources."""

from __future__ import annotations

import hashlib
import json
import re
from collections import deque
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    ROOT / "dev_assets" / "source_images" / "combat_robot_shield_bearer_elite"
)
RUNTIME_DIR = ROOT / "resources" / "texture" / "enemy" / "mechanical_life"
ANIMATION_DIR = ROOT / "resources" / "animation"

MANIFEST_PATH = enemy_asset_report_path("combat_robot_shield_bearer_elite_final_candidate_manifest.json")
REPORT_PATH = (
    enemy_asset_report_path("combat_robot_shield_bearer_elite_final_preview_report.json")
)
FINAL_MAIN_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_final_candidate.png"
FINAL_FX_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_fx_final_candidate.png"
RUNTIME_MAIN_PATH = RUNTIME_DIR / "combat_robot_shield_bearer_elite.png"
RUNTIME_FX_PATH = RUNTIME_DIR / "combat_robot_shield_bearer_elite_fx.png"
ORDINARY_MAIN_PATH = RUNTIME_DIR / "combat_robot_shield_bearer.png"

M1_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_move_m1_candidate_native.png"
R1_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_shield_states_r1_candidate_native.png"
D1_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_death_d1_candidate_native.png"
B1_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_block_b1_candidate_native.png"
X1_PATH = SOURCE_DIR / "combat_robot_shield_bearer_elite_break_x1_candidate_native.png"

MAIN_SHA256 = "7f36a88b08f5cdb3e37817f9aa4da3b53a09a8ffbef9863683db77dcd01bcf57"
FX_SHA256 = "7547a4a5993cfd9373875341afe615cded24967a464f41ba71a2f798721cb01f"
REPORT_SHA256 = "1703fa96a8db47eef05c9766e59761f35556f8e4d4da4d4bc610e4757984c07d"
TRANSPARENT = (0, 0, 0, 0)
MAIN_PALETTE = {
    TRANSPARENT,
    (0, 0, 0, 255),
    (21, 22, 19, 255),
    (29, 28, 30, 255),
    (55, 59, 63, 255),
    (74, 36, 105, 255),
    (82, 88, 94, 255),
    (112, 121, 128, 255),
    (151, 159, 164, 255),
    (157, 78, 221, 255),
    (190, 196, 198, 255),
    (197, 138, 255, 255),
}
FX_PALETTE = (MAIN_PALETTE - {(0, 0, 0, 255)}) | {(226, 229, 226, 255)}
ORDINARY_RED_ORANGE = {
    (102, 25, 20, 255),
    (185, 75, 80, 255),
    (190, 48, 31, 255),
    (236, 28, 36, 255),
    (239, 92, 34, 255),
    (255, 0, 0, 255),
    (255, 181, 71, 255),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba(path: Path) -> Image.Image:
    with Image.open(path) as image:
        if image.mode != "RGBA":
            raise AssertionError(f"{path.name}: expected RGBA, got {image.mode}")
        return image.copy()


def frame(sheet: Image.Image, column: int, row: int) -> Image.Image:
    return sheet.crop((column * 32, row * 32, (column + 1) * 32, (row + 1) * 32))


def assert_pixel_contract(
    image: Image.Image,
    expected_palette: set[tuple[int, int, int, int]],
    label: str,
) -> None:
    colors = set(image.getdata())
    if {pixel[3] for pixel in colors} - {0, 255}:
        raise AssertionError(f"{label}: alpha must be binary")
    if any(pixel[3] == 0 and pixel != TRANSPARENT for pixel in colors):
        raise AssertionError(f"{label}: transparent RGB must be zero")
    if colors != expected_palette:
        raise AssertionError(
            f"{label}: fixed palette drifted; missing={sorted(expected_palette - colors)} "
            f"extra={sorted(colors - expected_palette)}"
        )
    if colors.intersection(ORDINARY_RED_ORANGE):
        raise AssertionError(f"{label}: ordinary red-orange pixels remain")


def assert_main_frames(sheet: Image.Image) -> None:
    frames = [frame(sheet, column, row) for row in range(8) for column in range(8)]
    if len(frames) != 64:
        raise AssertionError("main atlas must expose exactly 64 frames")
    for index, image in enumerate(frames):
        bbox = image.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError(f"main frame {index} is empty")
        left, top, right, bottom = bbox
        if right - left > 28 or bottom - top > 28:
            raise AssertionError(f"main frame {index} exceeds 28x28: {bbox}")
        if bottom != 28:
            raise AssertionError(f"main frame {index} baseline drifted: {bbox}")

    leg_masks = {
        frame(sheet, index, 0).crop((8, 21, 24, 28)).getchannel("A").tobytes()
        for index in range(8)
    }
    if len(leg_masks) != 8:
        raise AssertionError("M1 must retain eight distinct leg phases")

    shield_masks: set[bytes] = set()
    for row in range(3):
        for column in range(8):
            live = frame(sheet, column, row)
            shield = live.crop((24, 8, 30, 26))
            if shield.getchannel("A").getbbox() != (0, 0, 6, 18):
                raise AssertionError(
                    f"shield row={row} frame={column} lost its strict 6x18 visual bbox"
                )
            shield_masks.add(shield.getchannel("A").tobytes())
    if len(shield_masks) != 1:
        raise AssertionError("intact/cracked/critical shield alpha must remain stable")
    for column in range(8):
        broken = frame(sheet, column, 3)
        if broken.crop((24, 8, 30, 26)).getchannel("A").getbbox() is not None:
            raise AssertionError(f"broken move frame {column} still contains shield pixels")


def components_8(image: Image.Image) -> list[set[tuple[int, int]]]:
    remaining = {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] == 255
    }
    result: list[set[tuple[int, int]]] = []
    while remaining:
        first = remaining.pop()
        component = {first}
        queue: deque[tuple[int, int]] = deque([first])
        while queue:
            x, y = queue.popleft()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    point = (x + dx, y + dy)
                    if point in remaining:
                        remaining.remove(point)
                        component.add(point)
                        queue.append(point)
        result.append(component)
    return sorted(result, key=len, reverse=True)


def bbox_for_points(points: set[tuple[int, int]]) -> tuple[int, int, int, int]:
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def assert_death_frame6_detach(sheet: Image.Image, ordinary: Image.Image) -> None:
    expected_bbox = (16, 25, 20, 28)
    for row in range(4, 8):
        elite_frame = frame(sheet, 6, row)
        ordinary_frame = frame(ordinary, 6, row)
        elite_components = components_8(elite_frame)
        ordinary_components = components_8(ordinary_frame)
        if len(elite_components) != 2 or len(ordinary_components) != 2:
            raise AssertionError(f"death row {row} component structure drifted")
        detached = elite_components[1]
        ordinary_detached = ordinary_components[1]
        if len(detached) != 5 or bbox_for_points(detached) != expected_bbox:
            raise AssertionError(f"death row {row} lost the authored detached 5px part")
        if detached != ordinary_detached:
            raise AssertionError(f"death row {row} detached alpha differs from ordinary")
        for point in detached:
            if elite_frame.getpixel(point) != ordinary_frame.getpixel(point):
                raise AssertionError(
                    f"death row {row} detached pixel {point} was recolored or bridged"
                )


def assert_selected_sources(main: Image.Image, fx: Image.Image) -> None:
    if main.crop((0, 0, 256, 32)).tobytes() != rgba(M1_PATH).tobytes():
        raise AssertionError("runtime move row is not approved M1")
    r1 = rgba(R1_PATH)
    for stage in range(4):
        selected = r1.crop((stage * 32, 0, (stage + 1) * 32, 32))
        if frame(main, 0, stage).tobytes() != selected.tobytes():
            raise AssertionError(f"runtime shield stage {stage} is not approved R1")
    if main.crop((0, 128, 256, 160)).tobytes() != rgba(D1_PATH).tobytes():
        raise AssertionError("runtime intact death row is not approved D1")
    if fx.crop((0, 0, 96, 32)).tobytes() != rgba(B1_PATH).tobytes():
        raise AssertionError("runtime block frames are not approved B1")
    if fx.crop((96, 0, 256, 32)).tobytes() != rgba(X1_PATH).tobytes():
        raise AssertionError("runtime break frames are not approved X1")


def assert_animation_resource(
    path: Path,
    stage_row: int,
) -> None:
    text = path.read_text(encoding="utf-8")
    texture_path = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_shield_bearer_elite.png"'
    )
    if text.count(texture_path) != 1:
        raise AssertionError(f"{path.name}: elite atlas binding drifted")
    if text.count('id="AtlasTexture_move_') != 8:
        raise AssertionError(f"{path.name}: move frame count must be 8")
    if text.count('id="AtlasTexture_death_') != 8:
        raise AssertionError(f"{path.name}: death frame count must be 8")
    if text.count("filter_clip = true") != 16:
        raise AssertionError(f"{path.name}: AtlasTexture filter_clip contract drifted")
    for index in range(8):
        move_region = f"region = Rect2({index * 32}, {stage_row * 32}, 32, 32)"
        death_region = f"region = Rect2({index * 32}, {(stage_row + 4) * 32}, 32, 32)"
        if text.count(move_region) != 1 or text.count(death_region) != 1:
            raise AssertionError(f"{path.name}: atlas region {index} drifted")
    if re.search(r'"loop": true,\s*"name": &"move",\s*"speed": 14\.0', text) is None:
        raise AssertionError(f"{path.name}: move must loop at 14 FPS")
    if re.search(r'"loop": false,\s*"name": &"death",\s*"speed": 12\.0', text) is None:
        raise AssertionError(f"{path.name}: death must be non-looping at 12 FPS")


def assert_fx_resource() -> None:
    path = ANIMATION_DIR / "combat_robot_shield_bearer_elite_fx.tres"
    text = path.read_text(encoding="utf-8")
    texture_path = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_shield_bearer_elite_fx.png"'
    )
    if text.count(texture_path) != 1:
        raise AssertionError("elite FX SpriteFrames atlas binding drifted")
    if text.count('id="AtlasTexture_shield_block_') != 3:
        raise AssertionError("B1 must declare exactly 3 block frames")
    if text.count('id="AtlasTexture_shield_break_') != 5:
        raise AssertionError("X1 must declare exactly 5 break frames")
    if text.count("filter_clip = true") != 8:
        raise AssertionError("elite FX AtlasTexture filter_clip contract drifted")
    if re.search(
        r'"loop": false,\s*"name": &"shield_block",\s*"speed": 24\.0', text
    ) is None:
        raise AssertionError("B1 must be non-looping at 24 FPS")
    if re.search(
        r'"loop": false,\s*"name": &"shield_break",\s*"speed": 18\.0', text
    ) is None:
        raise AssertionError("X1 must be non-looping at 18 FPS")


def assert_manifest() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    expected = {
        "approved_anchor": "h1c",
        "approved_animation_selection": {
            "move": "m1",
            "shield_states": "r1",
            "death": "d1",
        },
        "approved_fx_selection": {"block": "b1", "break": "x1"},
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise AssertionError(f"approved selection drifted: {key}")
    if manifest.get("report") != REPORT_PATH.relative_to(ROOT).as_posix():
        raise AssertionError("final preview report path drifted")
    if manifest.get("report_sha256") != REPORT_SHA256:
        raise AssertionError("final preview report manifest certificate drifted")
    if sha256(REPORT_PATH) != REPORT_SHA256:
        raise AssertionError("final preview report file certificate drifted")
    if (
        manifest.get("stage") != "final_candidate_approved_runtime_written"
        or manifest.get("final_human_approved") is not True
        or manifest.get("runtime_written") is not True
        or manifest.get("preview_only") is not False
        or manifest.get("imagegen_pixels_imported") is not False
    ):
        raise AssertionError("fourth-gate approval/runtime manifest is incomplete")
    runtime_assets = manifest.get("runtime_assets", {})
    for key, expected_sha in (("main_atlas", MAIN_SHA256), ("fx_atlas", FX_SHA256)):
        record = runtime_assets.get(key, {})
        if record.get("sha256") != expected_sha or record.get("byte_identical") is not True:
            raise AssertionError(f"runtime asset certificate drifted: {key}")


def main() -> int:
    required = (
        MANIFEST_PATH,
        REPORT_PATH,
        FINAL_MAIN_PATH,
        FINAL_FX_PATH,
        RUNTIME_MAIN_PATH,
        RUNTIME_FX_PATH,
        ORDINARY_MAIN_PATH,
        M1_PATH,
        R1_PATH,
        D1_PATH,
        B1_PATH,
        X1_PATH,
    )
    required += tuple(
        ANIMATION_DIR / f"combat_robot_shield_bearer_elite_{stage}.tres"
        for stage in ("intact", "cracked", "critical", "broken", "fx")
    )
    for path in required:
        if not path.is_file():
            raise AssertionError(f"missing required file: {path.relative_to(ROOT)}")

    assert_manifest()
    if sha256(FINAL_MAIN_PATH) != MAIN_SHA256 or sha256(RUNTIME_MAIN_PATH) != MAIN_SHA256:
        raise AssertionError("runtime main atlas is not the byte-identical approved candidate")
    if sha256(FINAL_FX_PATH) != FX_SHA256 or sha256(RUNTIME_FX_PATH) != FX_SHA256:
        raise AssertionError("runtime FX atlas is not the byte-identical approved candidate")
    if FINAL_MAIN_PATH.read_bytes() != RUNTIME_MAIN_PATH.read_bytes():
        raise AssertionError("main candidate/runtime byte streams differ")
    if FINAL_FX_PATH.read_bytes() != RUNTIME_FX_PATH.read_bytes():
        raise AssertionError("FX candidate/runtime byte streams differ")

    main_image = rgba(RUNTIME_MAIN_PATH)
    fx_image = rgba(RUNTIME_FX_PATH)
    ordinary_image = rgba(ORDINARY_MAIN_PATH)
    if main_image.size != (256, 256):
        raise AssertionError(f"main atlas must be 256x256, got {main_image.size}")
    if fx_image.size != (256, 32):
        raise AssertionError(f"FX atlas must be 256x32, got {fx_image.size}")
    assert_pixel_contract(main_image, MAIN_PALETTE, "main atlas")
    assert_pixel_contract(fx_image, FX_PALETTE, "FX atlas")
    assert_main_frames(main_image)
    assert_death_frame6_detach(main_image, ordinary_image)
    assert_selected_sources(main_image, fx_image)

    for row, stage in enumerate(("intact", "cracked", "critical", "broken")):
        assert_animation_resource(
            ANIMATION_DIR / f"combat_robot_shield_bearer_elite_{stage}.tres", row
        )
    assert_fx_resource()
    print(
        "COMBAT_ROBOT_SHIELD_BEARER_ELITE_ASSET_AUDIT_OK "
        f"main={MAIN_SHA256} fx={FX_SHA256} frames=64+8 selection=H1C/M1/R1/D1/B1/X1"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
