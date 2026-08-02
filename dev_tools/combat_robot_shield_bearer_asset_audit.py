#!/usr/bin/env python3
"""Independent runtime contract audit for the shield-bearing combat robot."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

from PIL import Image

import build_combat_robot_shield_bearer_previews as review
import process_combat_robot_shield_bearer_assets as processor
from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TRANSPARENT = (0, 0, 0, 0)
FRAME_SIZE = 32
STATE_ORDER = ("intact", "cracked", "critical", "broken")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _frame(sheet: Image.Image, column: int, row: int) -> Image.Image:
    return sheet.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )


def _audit_pixels(image: Image.Image, label: str) -> None:
    colors = set(image.getdata())
    if not colors.issubset(set(PALETTE) | {TRANSPARENT}):
        raise AssertionError(f"{label} contains colors outside fixed palette")
    alpha_values = {pixel[3] for pixel in colors}
    if not alpha_values.issubset({0, 255}):
        raise AssertionError(f"{label} contains non-binary alpha")
    if any(
        alpha == 0 and (red, green, blue) != (0, 0, 0)
        for red, green, blue, alpha in image.getdata()
    ):
        raise AssertionError(f"{label} contains dirty transparent RGB")


def _masked_bytes(image: Image.Image, rect: tuple[int, int, int, int]) -> bytes:
    copy = image.copy()
    copy.paste(TRANSPARENT, rect)
    return copy.tobytes()


def _audit_main_layout(sheet: Image.Image) -> None:
    moves = {
        state: [_frame(sheet, phase, row) for phase in range(8)]
        for row, state in enumerate(STATE_ORDER)
    }
    deaths = {
        state: [_frame(sheet, phase, row + 4) for phase in range(8)]
        for row, state in enumerate(STATE_ORDER)
    }

    for state in STATE_ORDER:
        for phase, frame in enumerate(moves[state]):
            review._frame_audit(frame, f"runtime/move/{state}[{phase}]", True)
        for phase, frame in enumerate(deaths[state]):
            review._frame_audit(frame, f"runtime/death/{state}[{phase}]", True)

    # All four move rows use the exact same M1 leg phase and differ only in the
    # selected S2 shield/arm region.
    for phase in range(8):
        leg_bytes = {
            moves[state][phase].crop(review.LEG_ROI).tobytes()
            for state in STATE_ORDER
        }
        if len(leg_bytes) != 1:
            raise AssertionError(f"Move phase {phase} differs in its M1 leg pixels")
        core_bytes = {
            _masked_bytes(moves[state][phase], review.SHIELD_ARM_ROI)
            for state in STATE_ORDER
        }
        if len(core_bytes) != 1:
            raise AssertionError(f"Move phase {phase} differs outside shield/arm ROI")

    leg_phases = {
        moves["intact"][phase].crop(review.LEG_ROI).tobytes()
        for phase in range(8)
    }
    if len(leg_phases) != 8:
        raise AssertionError("Runtime move atlas does not contain eight unique M1 phases")

    unbroken_masks = {
        moves[state][0].getchannel("A").crop(review.SHIELD_BBOX).tobytes()
        for state in STATE_ORDER[:3]
    }
    if len(unbroken_masks) != 1:
        raise AssertionError("S2 unbroken move shields changed alpha between stages")
    if moves["broken"][0].getchannel("A").crop(review.SHIELD_BBOX).getbbox() is not None:
        raise AssertionError("Broken move row still contains shield pixels")

    # D1 preserves each stage in frame zero.  The three unbroken rows keep one
    # shared body/shield silhouette for every phase while retaining distinct RGBA.
    for state in STATE_ORDER:
        if deaths[state][0].tobytes() == moves[state][0].tobytes():
            # M1 phase zero and standing D1 happen to use different leg poses;
            # equality would indicate an accidental row alias in a future build.
            raise AssertionError(f"Death/{state}[0] unexpectedly aliases move[0]")
    for phase in range(8):
        alpha_masks = {
            deaths[state][phase].getchannel("A").tobytes()
            for state in STATE_ORDER[:3]
        }
        if len(alpha_masks) != 1:
            raise AssertionError(
                f"Unbroken D1 phase {phase} changed alpha between damage stages"
            )
    if len({deaths[state][0].tobytes() for state in STATE_ORDER[:3]}) != 3:
        raise AssertionError("D1 frame zero does not retain three S2 damage appearances")
    if deaths["broken"][0].getchannel("A").crop(review.SHIELD_BBOX).getbbox() is not None:
        raise AssertionError("Broken D1 frame zero restored the shield")


def _audit_fx_layout(sheet: Image.Image) -> None:
    block = [_frame(sheet, frame, 0) for frame in range(3)]
    shield_break = [_frame(sheet, frame + 3, 0) for frame in range(5)]
    review._audit_fx(block, "runtime/shield_block")
    review._audit_fx(
        shield_break,
        "runtime/shield_break",
        require_terminal_contraction=True,
    )
    if len({frame.tobytes() for frame in [*block, *shield_break]}) != 8:
        raise AssertionError("FX atlas contains duplicate B1/X1 frames")


def _audit_state_sprite_frames(path: Path, state_row: int) -> None:
    if not path.is_file():
        raise AssertionError(f"Missing SpriteFrames resource: {path}")
    text = path.read_text(encoding="utf-8")
    required_texture = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_shield_bearer.png"'
    )
    if text.count(required_texture) != 1:
        raise AssertionError(f"{path.name} must reference the main texture once")
    for animation, row, speed, loop in (
        ("move", state_row, 14.0, True),
        ("death", state_row + 4, 12.0, False),
    ):
        if text.count(f'id="AtlasTexture_{animation}_') != 8:
            raise AssertionError(f"{path.name} must contain eight {animation} cells")
        for frame in range(8):
            region = f"region = Rect2({frame * 32}, {row * 32}, 32, 32)"
            if text.count(region) != 1:
                raise AssertionError(f"{path.name} misses {animation}[{frame}] {region}")
        pattern = re.compile(
            rf'"loop": {str(loop).lower()},\s*'
            rf'"name": &"{animation}",\s*'
            rf'"speed": {speed:.1f}',
            re.MULTILINE,
        )
        if pattern.search(text) is None:
            raise AssertionError(
                f"{path.name} misses {animation} speed={speed} loop={loop}"
            )


def _audit_fx_sprite_frames(path: Path) -> None:
    if not path.is_file():
        raise AssertionError(f"Missing FX SpriteFrames resource: {path}")
    text = path.read_text(encoding="utf-8")
    required_texture = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_shield_bearer_fx.png"'
    )
    if text.count(required_texture) != 1:
        raise AssertionError("FX SpriteFrames must reference the FX texture once")
    if text.count('id="AtlasTexture_shield_block_') != 3:
        raise AssertionError("FX SpriteFrames must declare three shield_block cells")
    if text.count('id="AtlasTexture_shield_break_') != 5:
        raise AssertionError("FX SpriteFrames must declare five shield_break cells")
    expected = (("shield_block", 24.0, False), ("shield_break", 18.0, False))
    for name, speed, loop in expected:
        pattern = re.compile(
            rf'"loop": {str(loop).lower()},\s*'
            rf'"name": &"{name}",\s*'
            rf'"speed": {speed:.1f}',
            re.MULTILINE,
        )
        if pattern.search(text) is None:
            raise AssertionError(
                f"FX SpriteFrames misses {name} speed={speed} loop={loop}"
            )


def main() -> None:
    expected_main, expected_fx, report = processor.construct_assets()
    if report["approved_selection"] != processor.APPROVED_SELECTION:
        raise AssertionError("Approved selection contract changed")

    if not processor.RUNTIME_SHEET_PATH.is_file():
        raise AssertionError("Missing combat_robot_shield_bearer.png")
    if not processor.RUNTIME_FX_PATH.is_file():
        raise AssertionError("Missing combat_robot_shield_bearer_fx.png")
    main_sheet = Image.open(processor.RUNTIME_SHEET_PATH).convert("RGBA")
    fx_sheet = Image.open(processor.RUNTIME_FX_PATH).convert("RGBA")
    if main_sheet.size != (256, 256):
        raise AssertionError(f"Main sheet is {main_sheet.size}, expected 256x256")
    if fx_sheet.size != (256, 32):
        raise AssertionError(f"FX sheet is {fx_sheet.size}, expected 256x32")
    _audit_pixels(main_sheet, "main runtime sheet")
    _audit_pixels(fx_sheet, "FX runtime sheet")
    if main_sheet.tobytes() != expected_main.tobytes():
        raise AssertionError("Runtime main sheet differs from locked deterministic build")
    if fx_sheet.tobytes() != expected_fx.tobytes():
        raise AssertionError("Runtime FX sheet differs from locked deterministic build")

    _audit_main_layout(main_sheet)
    _audit_fx_layout(fx_sheet)
    for row, state in enumerate(STATE_ORDER):
        _audit_state_sprite_frames(processor.STATE_SPRITE_FRAMES_PATHS[state], row)
    _audit_fx_sprite_frames(processor.FX_SPRITE_FRAMES_PATH)

    print(
        "COMBAT_ROBOT_SHIELD_BEARER_ASSET_AUDIT_OK "
        f"main_sha256={_sha256(processor.RUNTIME_SHEET_PATH)} "
        f"fx_sha256={_sha256(processor.RUNTIME_FX_PATH)} "
        "selection=M1/S2/D1/B1/X1 move=32 death=32 block=3 break=5"
    )


if __name__ == "__main__":
    main()
