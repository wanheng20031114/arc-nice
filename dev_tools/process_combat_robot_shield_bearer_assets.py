#!/usr/bin/env python3
"""Build the approved combat-robot shield-bearer runtime textures.

The second human gate approved exactly M1 / S2 / D1 / B1 / X1.  This file
locks the approved anchor and those five ImageGen reference boards by SHA-256.
The high-resolution boards remain motion/shape-language references only: no
source pixel is resized or copied into a runtime frame.  Every runtime pixel is
constructed from the native 32x32 anchor and deterministic integer-pixel
operations shared with the second-gate preview builder.

By default the command constructs, audits and writes review candidates only.
``--write-runtime`` additionally writes the two production PNGs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Sequence

from PIL import Image

import build_combat_robot_shield_bearer_previews as review
from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_shield_bearer"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
RUNTIME_DIR = PROJECT_ROOT / "resources" / "texture" / "enemy" / "mechanical_life"

ANCHOR_PATH = SOURCE_DIR / "combat_robot_shield_bearer_anchor_c_approved_native32.png"
PREVIEW_BUILDER_PATH = (
    PROJECT_ROOT / "dev_tools" / "build_combat_robot_shield_bearer_previews.py"
)
RUNTIME_SHEET_PATH = RUNTIME_DIR / "combat_robot_shield_bearer.png"
RUNTIME_FX_PATH = RUNTIME_DIR / "combat_robot_shield_bearer_fx.png"
ANIMATION_DIR = PROJECT_ROOT / "resources" / "animation"
STATE_SPRITE_FRAMES_PATHS = {
    state: ANIMATION_DIR / f"combat_robot_shield_bearer_{state}.tres"
    for state in ("intact", "cracked", "critical", "broken")
}
FX_SPRITE_FRAMES_PATH = ANIMATION_DIR / "combat_robot_shield_bearer_fx.tres"

CANDIDATE_SHEET_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_runtime_candidate.png"
)
CANDIDATE_SHEET_4X_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_runtime_candidate_4x.png"
)
CANDIDATE_FX_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_fx_runtime_candidate.png"
)
CANDIDATE_FX_8X_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_fx_runtime_candidate_8x.png"
)
SELECTED_MOVE_GIF_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_selected_move_states.gif"
)
SELECTED_DEATH_GIF_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_selected_death_states.gif"
)
REPORT_PATH = (
    enemy_asset_report_path("combat_robot_shield_bearer_asset_build_report.json")
)

FRAME_SIZE = 32
SHEET_COLUMNS = 8
SHEET_ROWS = 8
FX_COLUMNS = 8
STATE_ORDER = ("intact", "cracked", "critical", "broken")
MOVE_FPS = 14
DEATH_FPS = 12
BLOCK_FPS = 24
BREAK_FPS = 18
TRANSPARENT = (0, 0, 0, 0)

APPROVED_SELECTION = {
    "move": "M1",
    "shield_states": "S2",
    "death": "D1",
    "block_fx": "B1",
    "break_fx": "X1",
}

EXPECTED_PREVIEW_BUILDER_SHA256 = (
    "2fd9c11681effe821d32ae4b2b5321c6b442471f5f2285f86442294aab2223af"
)
LOCKED_INPUTS: dict[str, tuple[Path, str, str]] = {
    "anchor_c": (
        ANCHOR_PATH,
        "38d8b9410c5b74babb6b403ab44c2b668970d6af2af8217b12ba771600ee2149",
        "native_identity_and_pixel_source",
    ),
    "move_m1": (
        SOURCE_DIR / "combat_robot_shield_bearer_move_m1_imagegen.png",
        "67a45329b4bc331b7bf87c9ee24d9a544046a74d9f72fcde60a6ab889e36f414",
        "motion_language_only",
    ),
    "shield_states_s2": (
        SOURCE_DIR / "combat_robot_shield_bearer_shield_states_s2_imagegen.png",
        "bd9a32ccbb319a3ee151e68e4ecc5088489c61d54c8673a535a1305789fe866c",
        "damage_language_only",
    ),
    "death_d1": (
        SOURCE_DIR / "combat_robot_shield_bearer_death_d1_imagegen.png",
        "fc6cb57459836ac5413c1ef475050a11bc4845beabcc3eb554824728ab606b7f",
        "motion_language_only",
    ),
    "block_b1": (
        SOURCE_DIR / "combat_robot_shield_bearer_block_fx_b1_imagegen.png",
        "54afdec9f0fc2d566264b4ed5c0326b1b8635bfc89227c2755fee838beea34b0",
        "effect_language_only",
    ),
    "break_x1": (
        SOURCE_DIR / "combat_robot_shield_bearer_break_fx_x1_imagegen.png",
        "91765b709e8dbe3ea87bb75ec00176f1ae73180ffeea8241657d618863543b27",
        "effect_language_only",
    ),
}
SELECTED_SOURCE_GRIDS = {
    "move_m1": (4, 2),
    "shield_states_s2": (3, 1),
    "death_d1": (4, 2),
    "block_b1": (3, 1),
    "break_x1": (5, 1),
}

D1_BODY_ANGLES = (0, 0, -8, -16, -28, -43, -63, -90)
D1_BODY_CENTERS = (
    (14, 16),
    (14, 17),
    (14.5, 18),
    (15, 19),
    (15.5, 20),
    (16, 21),
    (16.5, 22),
    (16, 23),
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _verify_locked_inputs() -> dict[str, dict[str, str]]:
    if not PREVIEW_BUILDER_PATH.is_file():
        raise FileNotFoundError(PREVIEW_BUILDER_PATH)
    builder_hash = _sha256(PREVIEW_BUILDER_PATH)
    if builder_hash != EXPECTED_PREVIEW_BUILDER_SHA256:
        raise AssertionError(
            "Shield-bearer preview construction contract changed: "
            f"expected {EXPECTED_PREVIEW_BUILDER_SHA256}, got {builder_hash}"
        )

    report: dict[str, dict[str, str]] = {}
    for name, (path, expected_hash, role) in LOCKED_INPUTS.items():
        if not path.is_file():
            raise FileNotFoundError(path)
        actual_hash = _sha256(path)
        if actual_hash != expected_hash:
            raise AssertionError(
                f"Locked input {name} changed: expected {expected_hash}, got {actual_hash}"
            )
        report[name] = {
            "path": _relative(path),
            "sha256": actual_hash,
            "role": role,
        }
    return report


def _standing_leg_layer(anchor: Image.Image) -> Image.Image:
    layer = review._empty()
    left, top, right, bottom = review.LEG_ROI
    layer.alpha_composite(anchor.crop((left, top, right, bottom)), (left, top))
    return review._normalize_rgba(layer)


def _build_standing_states(
    state_uppers: dict[str, Image.Image],
    anchor: Image.Image,
) -> dict[str, Image.Image]:
    legs = _standing_leg_layer(anchor)
    states: dict[str, Image.Image] = {}
    for state in STATE_ORDER:
        frame = state_uppers[state].copy()
        frame.alpha_composite(legs)
        states[state] = review._normalize_rgba(frame)
    return states


def _build_broken_death(broken_anchor: Image.Image) -> list[Image.Image]:
    """Apply approved D1's integer fall to the shieldless full body."""
    source = review._crop_visible(broken_anchor)
    frames = [broken_anchor.copy()]
    for index in range(1, 8):
        rotated = review._rotate_native(source, D1_BODY_ANGLES[index])
        frame, _rect = review._place_crop(rotated, D1_BODY_CENTERS[index])
        bbox = review._bbox(frame)
        frame = review._translate(frame, 0, review.BASELINE_Y - bbox[3])
        frames.append(review._normalize_rgba(frame))
    return frames


def _build_sheet(rows: Sequence[Sequence[Image.Image]]) -> Image.Image:
    if len(rows) != SHEET_ROWS:
        raise AssertionError(f"Main atlas has {len(rows)} rows, expected {SHEET_ROWS}")
    sheet = review._empty((FRAME_SIZE * SHEET_COLUMNS, FRAME_SIZE * SHEET_ROWS))
    for row, frames in enumerate(rows):
        if len(frames) != SHEET_COLUMNS:
            raise AssertionError(
                f"Main atlas row {row} has {len(frames)} frames, expected 8"
            )
        for column, frame in enumerate(frames):
            sheet.alpha_composite(frame, (column * FRAME_SIZE, row * FRAME_SIZE))
    return review._normalize_rgba(sheet)


def _build_fx_sheet(
    block_frames: Sequence[Image.Image],
    break_frames: Sequence[Image.Image],
) -> Image.Image:
    frames = [*block_frames, *break_frames]
    if len(block_frames) != 3 or len(break_frames) != 5 or len(frames) != FX_COLUMNS:
        raise AssertionError("FX atlas must contain B1[0:3] followed by X1[0:5]")
    sheet = review._empty((FRAME_SIZE * FX_COLUMNS, FRAME_SIZE))
    for column, frame in enumerate(frames):
        sheet.alpha_composite(frame, (column * FRAME_SIZE, 0))
    return review._normalize_rgba(sheet)


def _stack_state_phase(
    state_frames: dict[str, list[Image.Image]],
    phase: int,
) -> Image.Image:
    stacked = review._empty((FRAME_SIZE, FRAME_SIZE * len(STATE_ORDER)))
    for row, state in enumerate(STATE_ORDER):
        stacked.alpha_composite(state_frames[state][phase], (0, row * FRAME_SIZE))
    return stacked


def _audit_broken_death(
    frames: Sequence[Image.Image],
    broken_anchor: Image.Image,
) -> dict[str, object]:
    if len(frames) != 8:
        raise AssertionError(f"Broken death has {len(frames)} frames, expected 8")
    if frames[0].tobytes() != broken_anchor.tobytes():
        raise AssertionError("Broken death[0] does not equal its standing state")
    if frames[0].getchannel("A").crop(review.SHIELD_BBOX).getbbox() is not None:
        raise AssertionError("Broken death[0] unexpectedly restores shield pixels")
    frame_audits = [
        review._frame_audit(frame, f"death/broken[{index}]", True)
        for index, frame in enumerate(frames)
    ]
    if len({frame.tobytes() for frame in frames}) != 8:
        raise AssertionError("Broken death does not contain eight unique frames")
    return {
        "frames": frame_audits,
        "first_frame_equals_broken_state": True,
        "shield_absent_at_start": True,
        "unique_frames": 8,
        "source_board_resized": False,
    }


def _audit_sheet_pixels(image: Image.Image, label: str) -> dict[str, object]:
    allowed = set(PALETTE) | {TRANSPARENT}
    colors = set(image.getdata())
    unexpected = colors - allowed
    if unexpected:
        raise AssertionError(f"{label} contains colors outside fixed palette")
    alpha_values = sorted({pixel[3] for pixel in colors})
    if alpha_values != [0, 255]:
        raise AssertionError(f"{label} alpha is not binary: {alpha_values}")
    if any(
        alpha == 0 and (red, green, blue) != (0, 0, 0)
        for red, green, blue, alpha in image.getdata()
    ):
        raise AssertionError(f"{label} has dirty transparent RGB")
    return {
        "size": list(image.size),
        "sha256_rgba": hashlib.sha256(image.tobytes()).hexdigest(),
        "palette_colors": len({pixel for pixel in colors if pixel[3]}),
        "binary_alpha": True,
        "transparent_rgb_zero": True,
    }


def construct_assets() -> tuple[Image.Image, Image.Image, dict[str, object]]:
    locked_inputs = _verify_locked_inputs()
    anchor = review._load_anchor()

    # M1 + S2: one stable upper per durability state over the same eight legs.
    state_uppers = review._build_state_uppers(anchor, "s2")
    move_frames = {
        state: review._compose_move(state_uppers[state], review._long_stride_layers())
        for state in STATE_ORDER
    }
    move_audit = {
        state: review._audit_move(
            move_frames[state], state_uppers[state], f"move/{state}"
        )
        for state in STATE_ORDER
    }
    move_state_audit = review._audit_state_moves(move_frames, "s2")

    # D1 is rebuilt from a standing copy of each selected S2 state.  Unbroken
    # stages retain the shield and hand as one component; broken uses the same
    # integer fall but carries only its empty downward hand.
    standing_states = _build_standing_states(state_uppers, anchor)
    death_frames: dict[str, list[Image.Image]] = {}
    death_audit: dict[str, object] = {}
    for state in STATE_ORDER[:3]:
        frames, semantic_pairs = review._build_death(standing_states[state], "d1")
        death_frames[state] = frames
        death_audit[state] = review._audit_death(
            frames,
            standing_states[state],
            f"death/{state}",
            semantic_pairs,
        )
    death_frames["broken"] = _build_broken_death(standing_states["broken"])
    death_audit["broken"] = _audit_broken_death(
        death_frames["broken"], standing_states["broken"]
    )

    unbroken_alpha_equal = True
    for phase in range(8):
        masks = {
            death_frames[state][phase].getchannel("A").tobytes()
            for state in STATE_ORDER[:3]
        }
        if len(masks) != 1:
            unbroken_alpha_equal = False
            raise AssertionError(
                f"Unbroken death phase {phase} changed shield/body alpha by stage"
            )
    if len({death_frames[state][0].tobytes() for state in STATE_ORDER[:3]}) != 3:
        raise AssertionError("Death starts do not retain three distinct shield damage states")

    # B1 + X1.  X1 starts from the exact selected S2 critical shield pixels.
    block_frames = review._build_block_b1()
    break_frames = review._build_break_x1(state_uppers["critical"])
    block_audit = review._audit_fx(block_frames, "block_b1")
    break_audit = review._audit_fx(
        break_frames, "break_x1", require_terminal_contraction=True
    )
    break_audit["critical_origin"] = review._assert_break_origin(
        break_frames[0], state_uppers["critical"], "break_x1/s2"
    )

    main_rows = [
        *(move_frames[state] for state in STATE_ORDER),
        *(death_frames[state] for state in STATE_ORDER),
    ]
    main_sheet = _build_sheet(main_rows)
    fx_sheet = _build_fx_sheet(block_frames, break_frames)
    if main_sheet.size != (256, 256):
        raise AssertionError(f"Main runtime sheet is {main_sheet.size}, expected 256x256")
    if fx_sheet.size != (256, 32):
        raise AssertionError(f"FX runtime sheet is {fx_sheet.size}, expected 256x32")

    source_grid_analysis = {
        name: review._source_grid_report(LOCKED_INPUTS[name][0], grid)
        for name, grid in SELECTED_SOURCE_GRIDS.items()
    }
    report: dict[str, object] = {
        "asset": "combat_robot_shield_bearer",
        "approved_selection": APPROVED_SELECTION,
        "locked_inputs": locked_inputs,
        "construction_contract": {
            "preview_builder": _relative(PREVIEW_BUILDER_PATH),
            "preview_builder_sha256": EXPECTED_PREVIEW_BUILDER_SHA256,
            "imagegen_pixels_imported": False,
            "imagegen_boards_used_as_language_only": True,
            "native_anchor_resized": False,
            "cell_size": [32, 32],
            "main_layout": [
                "move_intact",
                "move_cracked",
                "move_critical",
                "move_broken",
                "death_intact",
                "death_cracked",
                "death_critical",
                "death_broken",
            ],
            "fx_layout": [
                "shield_block_0",
                "shield_block_1",
                "shield_block_2",
                "shield_break_0",
                "shield_break_1",
                "shield_break_2",
                "shield_break_3",
                "shield_break_4",
            ],
            "fps": {
                "move": MOVE_FPS,
                "death": DEATH_FPS,
                "shield_block": BLOCK_FPS,
                "shield_break": BREAK_FPS,
            },
            "state_order": list(STATE_ORDER),
        },
        "main_sheet": _audit_sheet_pixels(main_sheet, "main sheet"),
        "fx_sheet": _audit_sheet_pixels(fx_sheet, "FX sheet"),
        "move_audit": move_audit,
        "move_state_audit": move_state_audit,
        "death_audit": death_audit,
        "unbroken_death_alpha_equal_by_phase": unbroken_alpha_equal,
        "block_audit": block_audit,
        "break_audit": break_audit,
        "source_grid_analysis": source_grid_analysis,
    }
    return main_sheet, fx_sheet, report


def _write_review_outputs(
    main_sheet: Image.Image,
    fx_sheet: Image.Image,
    move_frames: dict[str, list[Image.Image]] | None = None,
) -> None:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    main_sheet.save(CANDIDATE_SHEET_PATH, optimize=True)
    review._on_background(main_sheet).resize(
        (main_sheet.width * 4, main_sheet.height * 4),
        Image.Resampling.NEAREST,
    ).save(CANDIDATE_SHEET_4X_PATH, optimize=True)
    fx_sheet.save(CANDIDATE_FX_PATH, optimize=True)
    review._on_background(fx_sheet).resize(
        (fx_sheet.width * 8, fx_sheet.height * 8),
        Image.Resampling.NEAREST,
    ).save(CANDIDATE_FX_8X_PATH, optimize=True)


def _write_state_gifs(main_sheet: Image.Image) -> None:
    move_states = {
        state: [
            main_sheet.crop(
                (
                    phase * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (phase + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            for phase in range(8)
        ]
        for row, state in enumerate(STATE_ORDER)
    }
    death_states = {
        state: [
            main_sheet.crop(
                (
                    phase * FRAME_SIZE,
                    (row + 4) * FRAME_SIZE,
                    (phase + 1) * FRAME_SIZE,
                    (row + 5) * FRAME_SIZE,
                )
            )
            for phase in range(8)
        ]
        for row, state in enumerate(STATE_ORDER)
    }
    review._save_gif(
        [_stack_state_phase(move_states, phase) for phase in range(8)],
        SELECTED_MOVE_GIF_PATH,
        fps=MOVE_FPS,
        scale=5,
    )
    review._save_gif(
        [_stack_state_phase(death_states, phase) for phase in range(8)],
        SELECTED_DEATH_GIF_PATH,
        fps=DEATH_FPS,
        scale=5,
    )


def _atlas_subresource(animation: str, frame: int, row: int) -> str:
    return (
        f'[sub_resource type="AtlasTexture" id="AtlasTexture_{animation}_{frame}"]\n'
        'atlas = ExtResource("1_texture")\n'
        f"region = Rect2({frame * FRAME_SIZE}, {row * FRAME_SIZE}, 32, 32)\n"
        "filter_clip = true\n"
    )


def _animation_entry(name: str, frame_count: int, speed: int, loop: bool) -> str:
    frame_entries = ", ".join(
        "{\n"
        '"duration": 1.0,\n'
        f'"texture": SubResource("AtlasTexture_{name}_{frame}")\n'
        "}"
        for frame in range(frame_count)
    )
    return (
        "{\n"
        f'"frames": [{frame_entries}],\n'
        f'"loop": {str(loop).lower()},\n'
        f'"name": &"{name}",\n'
        f'"speed": {float(speed):.1f}\n'
        "}"
    )


def _state_sprite_frames_text(state_row: int) -> str:
    texture_path = (
        "res://resources/texture/enemy/mechanical_life/"
        "combat_robot_shield_bearer.png"
    )
    sections = [
        '[gd_resource type="SpriteFrames" format=3]',
        "",
        f'[ext_resource type="Texture2D" path="{texture_path}" id="1_texture"]',
        "",
    ]
    for animation, row in (("move", state_row), ("death", state_row + 4)):
        for frame in range(8):
            sections.append(_atlas_subresource(animation, frame, row).rstrip())
            sections.append("")
    animations = ", ".join(
        (
            _animation_entry("move", 8, MOVE_FPS, True),
            _animation_entry("death", 8, DEATH_FPS, False),
        )
    )
    sections.append("[resource]")
    sections.append(f"animations = [{animations}]")
    return "\n".join(sections) + "\n"


def _fx_sprite_frames_text() -> str:
    texture_path = (
        "res://resources/texture/enemy/mechanical_life/"
        "combat_robot_shield_bearer_fx.png"
    )
    sections = [
        '[gd_resource type="SpriteFrames" format=3]',
        "",
        f'[ext_resource type="Texture2D" path="{texture_path}" id="1_texture"]',
        "",
    ]
    for frame in range(3):
        sections.append(_atlas_subresource("shield_block", frame, 0).rstrip())
        sections.append("")
    for frame in range(5):
        sections.append(
            (
                f'[sub_resource type="AtlasTexture" '
                f'id="AtlasTexture_shield_break_{frame}"]\n'
                'atlas = ExtResource("1_texture")\n'
                f"region = Rect2({(frame + 3) * FRAME_SIZE}, 0, 32, 32)\n"
                "filter_clip = true"
            )
        )
        sections.append("")
    animations = ", ".join(
        (
            _animation_entry("shield_block", 3, BLOCK_FPS, False),
            _animation_entry("shield_break", 5, BREAK_FPS, False),
        )
    )
    sections.append("[resource]")
    sections.append(f"animations = [{animations}]")
    return "\n".join(sections) + "\n"


def _write_animation_resources() -> None:
    ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
    for row, state in enumerate(STATE_ORDER):
        STATE_SPRITE_FRAMES_PATHS[state].write_text(
            _state_sprite_frames_text(row),
            encoding="utf-8",
        )
    FX_SPRITE_FRAMES_PATH.write_text(
        _fx_sprite_frames_text(),
        encoding="utf-8",
    )


def build(write_runtime: bool = False) -> dict[str, object]:
    main_sheet, fx_sheet, report = construct_assets()
    _write_review_outputs(main_sheet, fx_sheet)
    _write_state_gifs(main_sheet)

    runtime_outputs = {
        "main": _relative(RUNTIME_SHEET_PATH),
        "fx": _relative(RUNTIME_FX_PATH),
        "sprite_frames": {
            state: _relative(path)
            for state, path in STATE_SPRITE_FRAMES_PATHS.items()
        },
        "fx_sprite_frames": _relative(FX_SPRITE_FRAMES_PATH),
    }
    if write_runtime:
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        main_sheet.save(RUNTIME_SHEET_PATH, optimize=True)
        fx_sheet.save(RUNTIME_FX_PATH, optimize=True)
        _write_animation_resources()
    report["runtime_written"] = write_runtime
    report["runtime_outputs"] = runtime_outputs
    report["review_outputs"] = {
        "main_candidate": _relative(CANDIDATE_SHEET_PATH),
        "main_candidate_4x": _relative(CANDIDATE_SHEET_4X_PATH),
        "fx_candidate": _relative(CANDIDATE_FX_PATH),
        "fx_candidate_8x": _relative(CANDIDATE_FX_8X_PATH),
        "move_states_gif": _relative(SELECTED_MOVE_GIF_PATH),
        "death_states_gif": _relative(SELECTED_DEATH_GIF_PATH),
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser(
        description="构建并审计举盾战斗机器人正式像素素材"
    )
    parser.add_argument(
        "--write-runtime",
        action="store_true",
        help="审计通过后写入两张运行时纹理",
    )
    args = parser.parse_args()
    report = build(write_runtime=args.write_runtime)
    print(
        "COMBAT_ROBOT_SHIELD_BEARER_ASSETS_OK "
        f"selection={APPROVED_SELECTION} "
        f"main_rgba={report['main_sheet']['sha256_rgba']} "
        f"fx_rgba={report['fx_sheet']['sha256_rgba']} "
        f"runtime_written={report['runtime_written']}"
    )


if __name__ == "__main__":
    main()
