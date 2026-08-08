#!/usr/bin/env python3
"""Audit the approved elite combat-robot runtime atlas and animation contract."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
CANDIDATE_PATH = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_elite"
    / "combat_robot_elite_final_candidate.png"
)
RUNTIME_PATH = (
    ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_elite.png"
)
ORDINARY_PATH = (
    ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot.png"
)
ANIMATION_PATH = ROOT / "resources" / "animation" / "combat_robot_elite.tres"
MANIFEST_PATH = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_elite"
    / "combat_robot_elite_animation_manifest.json"
)

APPROVED_SHA256 = "ef45598db927517c52024bd758b93bb2e3b7c1bc7cc21cc5dca399e775353688"
FRAME_SIZE = 32
SHEET_SIZE = (256, 128)
ROW_CONTRACT = {
    "move": (0, 8, 14.0, True),
    "windup": (1, 4, 10.0, False),
    "dash": (2, 4, 12.0, True),
    "death": (3, 8, 12.0, False),
}
STEEL_PALETTE = {
    (21, 22, 19, 255),
    (29, 28, 30, 255),
    (55, 59, 63, 255),
    (82, 88, 94, 255),
    (112, 121, 128, 255),
    (151, 159, 164, 255),
    (190, 196, 198, 255),
    (226, 229, 226, 255),
}
PURPLE_PALETTE = {
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
}
ORDINARY_ACCENTS = {
    (102, 25, 20, 255),
    (190, 48, 31, 255),
    (239, 92, 34, 255),
    (255, 181, 71, 255),
    (185, 75, 80, 255),
    (236, 28, 36, 255),
    (255, 0, 0, 255),
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _frame(sheet: Image.Image, row: int, column: int) -> Image.Image:
    return sheet.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )


def _assert_animation_resource() -> None:
    text = ANIMATION_PATH.read_text(encoding="utf-8")
    if "combat_robot_elite.png" not in text:
        raise AssertionError("SpriteFrames does not reference the elite runtime atlas")
    for animation, (row, frame_count, speed, loop) in ROW_CONTRACT.items():
        name_marker = f'"name": &"{animation}"'
        if name_marker not in text:
            raise AssertionError(f"Missing animation {animation}")
        block_start = text.rfind("\"frames\": [", 0, text.index(name_marker))
        block_end = text.index(name_marker) + len(name_marker)
        block = text[block_start:block_end]
        if block.count('"texture": SubResource(') != frame_count:
            raise AssertionError(f"{animation} frame count is not {frame_count}")
        if f'"loop": {str(loop).lower()}' not in block:
            raise AssertionError(f"{animation} loop contract changed")
        if f'"speed": {speed:.1f}' not in text[block_start:block_end + 64]:
            raise AssertionError(f"{animation} speed is not {speed}")
        for column in range(frame_count):
            region = f"region = Rect2({column * 32}, {row * 32}, 32, 32)"
            if region not in text:
                raise AssertionError(f"Missing atlas region for {animation}[{column}]")
    if len(re.findall(r'^filter_clip = true$', text, re.MULTILINE)) != 24:
        raise AssertionError("All 24 AtlasTexture frames must enable filter_clip")


def main() -> int:
    for path in (CANDIDATE_PATH, RUNTIME_PATH, ORDINARY_PATH, ANIMATION_PATH, MANIFEST_PATH):
        if not path.is_file():
            raise AssertionError(f"Missing required file: {path.relative_to(ROOT)}")

    if _sha256(CANDIDATE_PATH) != APPROVED_SHA256:
        raise AssertionError("Approved final candidate SHA-256 changed")
    if _sha256(RUNTIME_PATH) != APPROVED_SHA256:
        raise AssertionError("Runtime atlas is not byte-identical to the approved candidate")

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("approved_selection") != {
        "move": "M1",
        "windup": "W2",
        "dash": "C1",
        "death": "D2",
    }:
        raise AssertionError("Manifest selection is not M1/W2/C1/D2")
    if not manifest.get("final_human_approved") or not manifest.get("runtime_written"):
        raise AssertionError("Manifest has not recorded final approval/runtime integration")

    sheet = Image.open(RUNTIME_PATH).convert("RGBA")
    ordinary = Image.open(ORDINARY_PATH).convert("RGBA")
    if sheet.size != SHEET_SIZE or ordinary.size != SHEET_SIZE:
        raise AssertionError(f"Expected 256x128 atlases, got {sheet.size}/{ordinary.size}")

    allowed_palette = STEEL_PALETTE | PURPLE_PALETTE | {(0, 0, 0, 0)}
    visible_palette = {pixel for pixel in sheet.getdata() if pixel[3] > 0}
    unexpected = visible_palette - allowed_palette
    if unexpected:
        raise AssertionError(f"Unexpected elite palette colors: {sorted(unexpected)}")
    if not visible_palette.intersection(PURPLE_PALETTE):
        raise AssertionError("Elite atlas contains no purple functional pixels")

    non_empty = 0
    for animation, (row, frame_count, _speed, _loop) in ROW_CONTRACT.items():
        for column in range(8):
            frame = _frame(sheet, row, column)
            if column >= frame_count:
                if any(pixel != (0, 0, 0, 0) for pixel in frame.getdata()):
                    raise AssertionError(f"Unused {animation}[{column}] cell is not RGBA-zero")
                continue
            non_empty += 1
            bbox = frame.getbbox()
            if bbox is None:
                raise AssertionError(f"Empty runtime frame {animation}[{column}]")
            left, top, right, bottom = bbox
            if right - left > 28 or bottom - top > 28:
                raise AssertionError(f"Oversized runtime frame {animation}[{column}]: {bbox}")
            if bottom != 28:
                raise AssertionError(f"Baseline drift in {animation}[{column}]: bottom={bottom}")
            for pixel in frame.getdata():
                if pixel[3] not in (0, 255):
                    raise AssertionError(f"Partial alpha in {animation}[{column}]")
                if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
                    raise AssertionError(f"Transparent RGB residue in {animation}[{column}]")

            ordinary_frame = _frame(ordinary, row, column)
            ordinary_accent_count = sum(
                pixel in ORDINARY_ACCENTS for pixel in ordinary_frame.getdata()
            )
            purple_count = sum(pixel in PURPLE_PALETTE for pixel in frame.getdata())
            if purple_count != ordinary_accent_count:
                raise AssertionError(
                    f"Accent mask count changed in {animation}[{column}]: "
                    f"ordinary={ordinary_accent_count} elite={purple_count}"
                )

    if non_empty != 24:
        raise AssertionError(f"Expected 24 non-empty frames, found {non_empty}")
    _assert_animation_resource()
    print(
        "COMBAT_ROBOT_ELITE_ASSET_AUDIT_OK "
        f"sha256={APPROVED_SHA256} frames={non_empty}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
