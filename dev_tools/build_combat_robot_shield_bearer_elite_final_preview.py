#!/usr/bin/env python3
"""Build the review-only final elite shield bearer atlases and GIFs.

The final candidate is assembled exclusively from the committed ordinary
runtime atlases and the human-approved H1C/M1/R1/D1/B1/X1 pixel contracts.
This script has no runtime writer and refuses every non-dev_assets output.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw

import build_combat_robot_shield_bearer_elite_animation_previews as anim
import build_combat_robot_shield_bearer_elite_fx_previews as fx


ROOT = anim.ROOT
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = anim.SOURCE_DIR
PREVIEW_DIR = anim.PREVIEW_DIR
RUNTIME_MAIN = anim.RUNTIME
RUNTIME_FX = fx.RUNTIME_FX
ANIMATION_MANIFEST = anim.ANIMATION_MANIFEST
FX_MANIFEST = enemy_asset_report_path("combat_robot_shield_bearer_elite_fx_manifest.json")

M1_NATIVE = SOURCE_DIR / "combat_robot_shield_bearer_elite_move_m1_candidate_native.png"
R1_NATIVE = SOURCE_DIR / "combat_robot_shield_bearer_elite_shield_states_r1_candidate_native.png"
D1_NATIVE = SOURCE_DIR / "combat_robot_shield_bearer_elite_death_d1_candidate_native.png"
B1_NATIVE = SOURCE_DIR / "combat_robot_shield_bearer_elite_block_b1_candidate_native.png"
X1_NATIVE = SOURCE_DIR / "combat_robot_shield_bearer_elite_break_x1_candidate_native.png"

FINAL_MAIN = SOURCE_DIR / "combat_robot_shield_bearer_elite_final_candidate.png"
FINAL_FX = SOURCE_DIR / "combat_robot_shield_bearer_elite_fx_final_candidate.png"
FINAL_MANIFEST = enemy_asset_report_path("combat_robot_shield_bearer_elite_final_candidate_manifest.json")
FINAL_REPORT = enemy_asset_report_path("combat_robot_shield_bearer_elite_final_preview_report.json")

EXPECTED_SHA = {
    RUNTIME_MAIN: "07e5996a7048f4a469e247ee4aa7ce3c9f9c54a829d6a839ff3c94b2cac72ab4",
    RUNTIME_FX: "366d362355555235b7e3bf49112392d29995a7282de14dc00750229467318f9b",
    M1_NATIVE: "e0060e75efa8f612de8b98750e25617c88fceee85150b3f2552607e141f724f5",
    R1_NATIVE: "2d2e312d2354af8ed62ac696b42be0731c7c715445c522c6f476b3267fe2ed04",
    D1_NATIVE: "93a3371c96ec0e083a46b38a94a71bf45982ebe50f71517ef1e99b4d088258df",
    B1_NATIVE: "fb3d4b63298ee3c76e9be55b93a133fb455d89af9bb156d97fff5baac897eb04",
    X1_NATIVE: "4eca90f590dd5119117bc9dcba38e4b409b4542c57603066bcf6e95f8ff35088",
    ANIMATION_MANIFEST: "84ec0aafbf5ca91ac2f2a38057d87c0b17b8a7b18928ec242c4d3848467b48e0",
    FX_MANIFEST: "bc9d1db4479ff3cbdee7b0b47a484974e9c77eb6a2e04af3e266536dd7dfda4f",
}

STATE_NAMES = ("intact", "cracked", "critical", "broken")
EXPECTED_MAIN_RGBA_SHA = "c81acdda9c70f4765051f40a709cc231463b704d83eb95543922d9ff2651978c"
BROKEN_DEATH_OVERLAPS = {
    1: frozenset(((10, 8), (10, 11), (10, 12), (9, 13))),
    7: frozenset(((8, 24), (12, 25), (11, 25), (12, 14), (13, 25))),
}
BROKEN_DEATH_RELOCATIONS = {
    0: {
        (21, 8): (20, 8),
        (21, 12): (20, 12),
        (22, 12): (21, 12),
        (22, 13): (21, 13),
    },
    1: {
        (20, 8): (19, 8),
        (20, 11): (19, 11),
        (20, 12): (19, 12),
        (20, 13): (19, 13),
    },
    7: {
        (11, 12): (10, 13),
        (12, 12): (11, 13),
    },
}
SHIELD_POLYGON_RIGHT = ((26, 8), (28, 8), (29, 9), (29, 24), (28, 25), (25, 25), (24, 24), (24, 10))
SHIELD_POLYGON_LOCAL = ((-1, -9), (1, -9), (2, -8), (2, 7), (1, 8), (-2, 8), (-3, 7), (-3, -7))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_inputs() -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for path, expected in EXPECTED_SHA.items():
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Final input SHA drifted: {anim.rel(path)} {actual}")
        records[anim.rel(path)] = {"sha256": actual, "locked": True}

    animation = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    if animation.get("approved_animation_selection") != {
        "move": "m1",
        "shield_states": "r1",
        "death": "d1",
    }:
        raise AssertionError("M1/R1/D1 is not the certified animation selection")
    fx_manifest = json.loads(FX_MANIFEST.read_text(encoding="utf-8"))
    if fx_manifest.get("approved_fx_selection") != {"block": "b1", "break": "x1"}:
        raise AssertionError("B1/X1 is not the certified FX selection")
    return records


def load_strip(path: Path, frame_count: int) -> list[Image.Image]:
    with Image.open(path) as source:
        strip = source.convert("RGBA")
    expected_size = (frame_count * anim.FRAME, anim.FRAME)
    if strip.size != expected_size:
        raise AssertionError(f"Strip size drifted: {anim.rel(path)} {strip.size}")
    return [
        strip.crop((index * anim.FRAME, 0, (index + 1) * anim.FRAME, anim.FRAME))
        for index in range(frame_count)
    ]


def _build_broken_death_body() -> tuple[dict[tuple[int, int], tuple[int, int, int, int]], ...]:
    tables: list[dict[tuple[int, int], tuple[int, int, int, int]]] = []
    for frame_index, ordinary_table in enumerate(anim.DEATH_BODY):
        table = dict(ordinary_table)
        for source, target in BROKEN_DEATH_RELOCATIONS.get(frame_index, {}).items():
            if source not in table or target in table:
                raise AssertionError(
                    f"Broken death explicit relocation drifted: frame={frame_index} source={source} target={target}"
                )
            table[target] = table.pop(source)
        if len(table) != 8:
            raise AssertionError(f"Broken death table must keep eight authored points: frame={frame_index}")
        tables.append(table)
    return tuple(tables)


BROKEN_DEATH_BODY = _build_broken_death_body()


def build_move_row(state: int) -> list[Image.Image]:
    result: list[Image.Image] = []
    for index, base in enumerate(anim.frames_from_runtime(state)):
        frame = anim.map_accents(base)
        anim.put_added(frame, base, anim.COMMON_A1, f"final_move[{state}][{index}]")
        if state < 3:
            anim.recolor_existing(frame, base, anim.STANDING_CAP, f"final_move[{state}][{index}]")
            if frame.crop(anim.SHIELD_BOX).getchannel("A").tobytes() != base.crop(anim.SHIELD_BOX).getchannel("A").tobytes():
                raise AssertionError(f"Move shield Alpha drifted: state={state} frame={index}")
        for point in (*anim.OBSERVATION, *anim.GRIP):
            if state < 3 and frame.getpixel(point) != base.getpixel(point):
                raise AssertionError(f"Protected shield point drifted: state={state} frame={index} point={point}")
        if any(y == 7 for x, y in anim.alpha_points(frame) - anim.alpha_points(base)):
            raise AssertionError(f"Move y=7 reinforcement artifact: state={state} frame={index}")
        anim.audit_frame(frame, f"final_move[{state}][{index}]")
        result.append(frame)
    return result


def _apply_death_body(frame: Image.Image, base: Image.Image, state: int, frame_index: int) -> None:
    points = BROKEN_DEATH_BODY[frame_index] if state == 3 else anim.DEATH_BODY[frame_index]
    overlaps = frozenset(point for point in points if base.getpixel(point)[3])
    expected = BROKEN_DEATH_OVERLAPS.get(frame_index, frozenset()) if state == 3 else frozenset()
    if overlaps != expected:
        raise AssertionError(
            f"Death body overlap drifted: state={state} frame={frame_index} actual={sorted(overlaps)} expected={sorted(expected)}"
        )
    for point, color in points.items():
        if point in overlaps:
            frame.putpixel(point, color)
        else:
            if base.getpixel(point) != anim.TRANSPARENT:
                raise AssertionError(f"Death authored add point is not transparent: state={state} frame={frame_index} point={point}")
            frame.putpixel(point, color)


def build_death_row(state: int) -> list[Image.Image]:
    result: list[Image.Image] = []
    for index, base in enumerate(anim.frames_from_runtime(state + 4)):
        frame = anim.map_accents(base)
        _apply_death_body(frame, base, state, index)
        if state < 3:
            anim.recolor_existing(frame, base, anim.DEATH_CAP[index], f"final_death[{state}][{index}]")

        if anim.alpha_points(base) - anim.alpha_points(frame):
            raise AssertionError(f"Ordinary death Alpha deleted: state={state} frame={index}")
        candidate_components = anim.components8(anim.alpha_points(frame))
        dominant = candidate_components[0]
        authored = set(BROKEN_DEATH_BODY[index] if state == 3 else anim.DEATH_BODY[index])
        if not authored <= dominant:
            raise AssertionError(f"Elite death reinforcement left dominant component: state={state} frame={index}")
        ordinary_components = anim.components8(anim.alpha_points(base))
        for component in ordinary_components[1:]:
            if any(frame.getpixel(point) != base.getpixel(point) for point in component):
                raise AssertionError(f"Ordinary detached death detail changed: state={state} frame={index}")
        anim.audit_frame(frame, f"final_death[{state}][{index}]")
        result.append(frame)
    return result


def make_atlas(rows: list[list[Image.Image]]) -> Image.Image:
    if len(rows) != 8 or any(len(row) != 8 for row in rows):
        raise AssertionError("Main atlas must contain exactly 8x8 frames")
    atlas = Image.new("RGBA", (256, 256), anim.TRANSPARENT)
    for row_index, row in enumerate(rows):
        for column, frame in enumerate(row):
            atlas.alpha_composite(frame, (column * 32, row_index * 32))
    return atlas


def build_final_main() -> tuple[Image.Image, dict[str, list[list[Image.Image]]]]:
    move_rows = [build_move_row(state) for state in range(4)]
    death_rows = [build_death_row(state) for state in range(4)]

    selected_m1 = load_strip(M1_NATIVE, 8)
    selected_r1 = load_strip(R1_NATIVE, 4)
    selected_d1 = load_strip(D1_NATIVE, 8)
    if any(a.tobytes() != b.tobytes() for a, b in zip(move_rows[0], selected_m1)):
        raise AssertionError("Final intact move row is not the approved M1 strip")
    if any(move_rows[state][0].tobytes() != selected_r1[state].tobytes() for state in range(4)):
        raise AssertionError("Final move state frame0 is not the approved R1 strip")
    if any(a.tobytes() != b.tobytes() for a, b in zip(death_rows[0], selected_d1)):
        raise AssertionError("Final intact death row is not the approved D1 strip")

    for frame_index in range(8):
        leg = move_rows[0][frame_index].crop((0, 22, 24, 32)).tobytes()
        if any(move_rows[state][frame_index].crop((0, 22, 24, 32)).tobytes() != leg for state in range(1, 4)):
            raise AssertionError(f"Shield-state transition changes leg phase {frame_index}")

    atlas = make_atlas([*move_rows, *death_rows])
    rgba = anim.rgba_sha(atlas)
    if rgba != EXPECTED_MAIN_RGBA_SHA:
        raise AssertionError(f"Final main RGBA certificate drifted: {rgba}")
    return atlas, {"move": move_rows, "death": death_rows}


def build_final_fx() -> tuple[Image.Image, dict[str, list[Image.Image]]]:
    block = load_strip(B1_NATIVE, 3)
    broken = load_strip(X1_NATIVE, 5)
    atlas = Image.new("RGBA", (256, 32), anim.TRANSPARENT)
    atlas.alpha_composite(anim.make_strip(block), (0, 0))
    atlas.alpha_composite(anim.make_strip(broken), (96, 0))
    if atlas.crop((0, 0, 96, 32)).tobytes() != anim.make_strip(block).tobytes():
        raise AssertionError("Final FX B1 byte copy drifted")
    if atlas.crop((96, 0, 256, 32)).tobytes() != anim.make_strip(broken).tobytes():
        raise AssertionError("Final FX X1 byte copy drifted")
    return atlas, {"block": block, "break": broken}


def ordinary_main() -> Image.Image:
    with Image.open(RUNTIME_MAIN) as source:
        return source.convert("RGBA")


def ordinary_fx() -> Image.Image:
    with Image.open(RUNTIME_FX) as source:
        return source.convert("RGBA")


def delta_image(candidate: Image.Image, ordinary: Image.Image) -> Image.Image:
    if candidate.size != ordinary.size:
        raise AssertionError("Delta inputs have different sizes")
    result = Image.new("RGBA", candidate.size, anim.TRANSPARENT)
    for y in range(candidate.height):
        for x in range(candidate.width):
            before = ordinary.getpixel((x, y))
            after = candidate.getpixel((x, y))
            if before == after:
                continue
            if before[3] == 0 and after[3]:
                color = (86, 224, 255, 255)
            elif before in anim.OLD_ACCENTS or before in fx.OLD_FX:
                color = (197, 138, 255, 255)
            else:
                color = (255, 210, 80, 255)
            result.putpixel((x, y), color)
    return result


def comparison_image(ordinary: Image.Image, candidate: Image.Image, factor: int) -> Image.Image:
    delta = delta_image(candidate, ordinary)
    panels = [anim.scaled(image, factor) for image in (ordinary, candidate, delta)]
    result = Image.new("RGB", (sum(panel.width for panel in panels), panels[0].height), anim.BACKGROUND[:3])
    offset = 0
    for panel in panels:
        result.paste(panel, (offset, 0))
        offset += panel.width
    return result


def collision_overlay(frame: Image.Image, mirrored: bool, shield_active: bool) -> Image.Image:
    source = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if mirrored else frame
    panel = anim.scaled(source, 16)
    draw = ImageDraw.Draw(panel)
    scale = 16

    body = (12 * scale, 9 * scale, 20 * scale, 25 * scale)
    draw.rectangle(body, outline=(86, 224, 255), width=3)
    draw.rectangle((body[0] + 4, body[1] + 4, body[2] - 4, body[3] - 4), outline=(255, 210, 80), width=2)
    if shield_active:
        polygon = SHIELD_POLYGON_RIGHT
        if mirrored:
            polygon = tuple((32 - x, y) for x, y in polygon)
        points = [(x * scale, y * scale) for x, y in polygon]
        draw.line([*points, points[0]], fill=(197, 138, 255), width=4, joint="curve")
    return panel


def build_collision_preview(move_rows: list[list[Image.Image]]) -> Image.Image:
    panels = (
        collision_overlay(move_rows[0][0], False, True),
        collision_overlay(move_rows[0][0], True, True),
        collision_overlay(move_rows[3][0], False, False),
    )
    result = Image.new("RGB", (panels[0].width * 3, panels[0].height), anim.BACKGROUND[:3])
    for index, panel in enumerate(panels):
        result.paste(panel, (index * panel.width, 0))
    return result


def save_state_gifs(rows: dict[str, list[list[Image.Image]]]) -> dict[str, object]:
    outputs: dict[str, object] = {}
    for action, state_rows in rows.items():
        duration = 70 if action == "move" else 80
        runtime_fps = 14 if action == "move" else 12
        runtime_loop = action == "move"
        for state, frames in zip(STATE_NAMES, state_rows):
            key = f"{state}_{action}"
            path = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_final_{key}.gif"
            mirror = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_final_{key}_mirrored.gif"
            anim.save_gif(frames, path, duration, False)
            anim.save_gif(frames, mirror, duration, True)
            outputs[key] = {
                "gif": anim.file_record(path),
                "mirrored_gif": anim.file_record(mirror),
                "runtime_fps": runtime_fps,
                "runtime_loop": runtime_loop,
                "review_duration_ms": duration,
                "frame_rgba_sha256": [anim.rgba_sha(frame) for frame in frames],
            }
    return outputs


def save_fx_gifs(rows: dict[str, list[Image.Image]]) -> dict[str, object]:
    outputs: dict[str, object] = {}
    for action, frames in rows.items():
        duration = 40 if action == "block" else 60
        runtime_fps = 24 if action == "block" else 18
        path = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_final_shield_{action}.gif"
        mirror = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_final_shield_{action}_mirrored.gif"
        anim.save_gif(frames, path, duration, False)
        anim.save_gif(frames, mirror, duration, True)
        outputs[action] = {
            "gif": anim.file_record(path),
            "mirrored_gif": anim.file_record(mirror),
            "runtime_fps": runtime_fps,
            "runtime_loop": False,
            "review_duration_ms": duration,
            "frame_rgba_sha256": [anim.rgba_sha(frame) for frame in frames],
        }
    return outputs


def save_transition_gifs(move_rows: list[list[Image.Image]]) -> dict[str, object]:
    frames = [row[0] for row in move_rows]
    path = PREVIEW_DIR / "combat_robot_shield_bearer_elite_final_stage_transition.gif"
    mirror = PREVIEW_DIR / "combat_robot_shield_bearer_elite_final_stage_transition_mirrored.gif"
    anim.save_gif(frames, path, 650, False)
    anim.save_gif(frames, mirror, 650, True)
    return {
        "gif": anim.file_record(path),
        "mirrored_gif": anim.file_record(mirror),
        "state_order": list(STATE_NAMES),
        "fixed_leg_phase": 0,
        "review_duration_ms": 650,
        "leg_phase_inherited_without_jump": True,
    }


def frame_metrics(rows: dict[str, list[list[Image.Image]]]) -> dict[str, object]:
    return {
        action: {
            state: [
                {
                    "rgba_sha256": anim.rgba_sha(frame),
                    "bbox": list(anim.bbox(frame)),
                    "opaque_pixels": len(anim.alpha_points(frame)),
                }
                for frame in frames
            ]
            for state, frames in zip(STATE_NAMES, state_rows)
        }
        for action, state_rows in rows.items()
    }


def main() -> None:
    inputs = verify_inputs()
    main_atlas, rows = build_final_main()
    fx_atlas, fx_rows = build_final_fx()
    rebuilt_main, rebuilt_rows = build_final_main()
    rebuilt_fx, rebuilt_fx_rows = build_final_fx()
    if main_atlas.tobytes() != rebuilt_main.tobytes() or fx_atlas.tobytes() != rebuilt_fx.tobytes():
        raise AssertionError("Final atlas in-memory deterministic rebuild drifted")
    if rows.keys() != rebuilt_rows.keys() or fx_rows.keys() != rebuilt_fx_rows.keys():
        raise AssertionError("Final row keys drifted")

    anim.save_png(main_atlas, FINAL_MAIN)
    anim.save_png(fx_atlas, FINAL_FX)
    main_preview = PREVIEW_DIR / "combat_robot_shield_bearer_elite_final_candidate_4x.png"
    fx_preview = PREVIEW_DIR / "combat_robot_shield_bearer_elite_fx_final_candidate_8x.png"
    main_delta = PREVIEW_DIR / "combat_robot_shield_bearer_elite_final_ordinary_delta_4x.png"
    fx_delta = PREVIEW_DIR / "combat_robot_shield_bearer_elite_fx_final_ordinary_delta_8x.png"
    main_comparison = PREVIEW_DIR / "combat_robot_shield_bearer_elite_final_comparison.png"
    fx_comparison = PREVIEW_DIR / "combat_robot_shield_bearer_elite_fx_final_comparison.png"
    collision = PREVIEW_DIR / "combat_robot_shield_bearer_elite_final_collision_overlay.png"

    anim.save_png(anim.scaled(main_atlas, 4), main_preview)
    anim.save_png(anim.scaled(fx_atlas, 8), fx_preview)
    anim.save_png(anim.scaled(delta_image(main_atlas, ordinary_main()), 4), main_delta)
    anim.save_png(anim.scaled(delta_image(fx_atlas, ordinary_fx()), 8), fx_delta)
    anim.save_png(comparison_image(ordinary_main(), main_atlas, 2), main_comparison)
    anim.save_png(comparison_image(ordinary_fx(), fx_atlas, 4), fx_comparison)
    anim.save_png(build_collision_preview(rows["move"]), collision)

    state_gifs = save_state_gifs(rows)
    fx_gifs = save_fx_gifs(fx_rows)
    transition = save_transition_gifs(rows["move"])

    outputs = {
        "main_atlas": anim.file_record(FINAL_MAIN),
        "fx_atlas": anim.file_record(FINAL_FX),
        "main_preview_4x": anim.file_record(main_preview),
        "fx_preview_8x": anim.file_record(fx_preview),
        "main_delta_4x": anim.file_record(main_delta),
        "fx_delta_8x": anim.file_record(fx_delta),
        "main_comparison": anim.file_record(main_comparison),
        "fx_comparison": anim.file_record(fx_comparison),
        "collision_overlay": anim.file_record(collision),
        "state_gifs": state_gifs,
        "fx_gifs": fx_gifs,
        "stage_transition": transition,
    }
    report = {
        "asset": "combat_robot_shield_bearer_elite_final_candidate",
        "stage": "final_runtime_candidate_pending_fourth_human_gate",
        "preview_only": True,
        "approved_anchor": "h1c",
        "approved_animation_selection": {"move": "m1", "shield_states": "r1", "death": "d1"},
        "approved_fx_selection": {"block": "b1", "break": "x1"},
        "final_human_approved": False,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "builder": {"path": anim.rel(SCRIPT), "sha256": sha256(SCRIPT)},
        "input_locks": inputs,
        "atlas_layout": {
            "main_size": [256, 256],
            "cell_size": [32, 32],
            "move_rows": {state: index for index, state in enumerate(STATE_NAMES)},
            "death_rows": {state: index + 4 for index, state in enumerate(STATE_NAMES)},
            "fx_size": [256, 32],
            "fx_cells": {"block": [0, 1, 2], "break": [3, 4, 5, 6, 7]},
        },
        "main_rgba_sha256": anim.rgba_sha(main_atlas),
        "fx_rgba_sha256": anim.rgba_sha(fx_atlas),
        "frame_metrics": frame_metrics(rows),
        "collision_contract": {
            "shield_facing_root": [11, 1],
            "polygon_local": [list(point) for point in SHIELD_POLYGON_LOCAL],
            "polygon_frame_right": [list(point) for point in SHIELD_POLYGON_RIGHT],
            "shield_visual_bbox": [24, 8, 30, 26],
            "shield_visual_size": [6, 18],
            "broken_state_has_no_shield_collision": True,
        },
        "broken_death_explicit_relocations": {
            str(frame): [
                {"source": list(source), "target": list(target)}
                for source, target in sorted(relocations.items())
            ]
            for frame, relocations in BROKEN_DEATH_RELOCATIONS.items()
        },
        "checks": {
            "row0_equals_approved_m1": True,
            "state_frame0_equals_approved_r1": True,
            "row4_equals_approved_d1": True,
            "fx_byte_copy_equals_b1_x1": True,
            "all_64_main_frames_present": True,
            "move_state_switch_leg_phase_stable": True,
            "broken_state_has_no_cap": True,
            "broken_death_overlap_whitelist_exact": True,
            "ordinary_death_detached_detail_preserved": True,
            "bbox_max_28_and_baseline_28": True,
            "no_added_y7_pixels": True,
            "binary_alpha_and_transparent_rgb_zero": True,
            "fixed_palette_and_no_old_red_orange": True,
            "gif_exact_native_nearest_neighbor": True,
            "in_memory_deterministic_rebuild": True,
        },
        "outputs": outputs,
    }
    anim.write_json(FINAL_REPORT, report)
    manifest = {
        "asset": "combat_robot_shield_bearer_elite",
        "stage": "final_runtime_candidate_pending_fourth_human_gate",
        "approved_anchor": "h1c",
        "approved_animation_selection": {"move": "m1", "shield_states": "r1", "death": "d1"},
        "approved_fx_selection": {"block": "b1", "break": "x1"},
        "final_human_approved": False,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "report": anim.rel(FINAL_REPORT),
        "report_sha256": sha256(FINAL_REPORT),
        "main_atlas": outputs["main_atlas"],
        "fx_atlas": outputs["fx_atlas"],
    }
    anim.write_json(FINAL_MANIFEST, manifest)
    print("COMBAT_ROBOT_SHIELD_BEARER_ELITE_FINAL_PREVIEW_OK")
    print(f"main={anim.rel(FINAL_MAIN)}")
    print(f"fx={anim.rel(FINAL_FX)}")
    print(f"report={anim.rel(FINAL_REPORT)}")
    print(f"manifest={anim.rel(FINAL_MANIFEST)}")


if __name__ == "__main__":
    main()
