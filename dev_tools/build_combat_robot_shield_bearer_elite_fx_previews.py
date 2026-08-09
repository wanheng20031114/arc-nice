#!/usr/bin/env python3
"""Build the review-only B1/B2/X1/X2 elite shield FX candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

import build_combat_robot_shield_bearer_elite_animation_previews as anim


ROOT = anim.ROOT
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = anim.SOURCE_DIR
PREVIEW_DIR = anim.PREVIEW_DIR
RUNTIME_FX = ROOT / "resources/texture/enemy/mechanical_life/combat_robot_shield_bearer_fx.png"
R1_NATIVE = SOURCE_DIR / "combat_robot_shield_bearer_elite_shield_states_r1_candidate_native.png"
ANIMATION_MANIFEST = SOURCE_DIR / "combat_robot_shield_bearer_elite_animation_manifest.json"
FX_MANIFEST = SOURCE_DIR / "combat_robot_shield_bearer_elite_fx_manifest.json"

EXPECTED_SHA = {
    RUNTIME_FX: "366d362355555235b7e3bf49112392d29995a7282de14dc00750229467318f9b",
    R1_NATIVE: "2d2e312d2354af8ed62ac696b42be0731c7c715445c522c6f476b3267fe2ed04",
    ANIMATION_MANIFEST: "84ec0aafbf5ca91ac2f2a38057d87c0b17b8a7b18928ec242c4d3848467b48e0",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_block_b1_imagegen.png": "84107c20d20f3472916e4a2026010a2be7a5533e0b01167ab10f5cf1a26d7d8b",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_block_b2_imagegen.png": "6385619e8962ec1992a547a281c19d670055ae4e5fa11b1a8ab9ad090b58c04d",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_break_x1_imagegen.png": "10774f98a0a650af64fa7332263d7fa43fbe9ee0af02773eef3f63e89c03aecd",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_break_x2_imagegen.png": "2c766903894df61cd2946985ed9888c49b6c4938c39d40464d7448b6857e6ff0",
}

TRANSPARENT = anim.TRANSPARENT
STEEL = anim.STEEL
PURPLE = anim.PURPLE
WHITE = STEEL[7]
P0, P1, P3, P4, P5 = PURPLE[0], PURPLE[1], PURPLE[3], PURPLE[4], PURPLE[5]
OLD_DARK = (102, 25, 20, 255)
OLD_RED = (190, 48, 31, 255)
OLD_ORANGE = (239, 92, 34, 255)
OLD_YELLOW = (255, 181, 71, 255)
OLD_FX = frozenset((OLD_DARK, OLD_RED, OLD_ORANGE, OLD_YELLOW))
DEFAULT_MAP = {OLD_DARK: P1, OLD_RED: P4, OLD_ORANGE: P5, OLD_YELLOW: P5}
ALLOWED = frozenset((*STEEL, *PURPLE, TRANSPARENT))
FX_FRAME = 32
CRITICAL_SHIELD_SOURCE_BOX = (64 + 24, 8, 64 + 30, 26)
X0_TARGET_BOX = (13, 7, 19, 25)
X0_SPARKS = frozenset(((15, 6), (12, 15), (12, 16), (19, 15), (19, 16), (16, 25)))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        nargs=2,
        metavar=("BLOCK", "BREAK"),
        help="Record the user's third-gate choice, for example: b1 x1.",
    )
    return parser.parse_args()


def resolve_selection(requested: list[str] | None) -> dict[str, str] | None:
    existing_selection: dict[str, str] | None = None
    if FX_MANIFEST.is_file():
        existing = json.loads(FX_MANIFEST.read_text(encoding="utf-8"))
        existing_selection = existing.get("approved_fx_selection")
    if requested is not None:
        selection = {
            "block": requested[0].lower(),
            "break": requested[1].lower(),
        }
        if existing_selection is not None and selection != existing_selection:
            raise AssertionError(
                f"FX selection already certified as {existing_selection}; "
                f"refusing replacement with {selection}"
            )
    else:
        selection = existing_selection
    if selection is None:
        return None
    if set(selection) != {"block", "break"}:
        raise AssertionError(f"Malformed FX selection: {selection}")
    normalized = {key: str(value).lower() for key, value in selection.items()}
    if normalized["block"] not in {"b1", "b2"}:
        raise AssertionError(f"Invalid block selection: {normalized['block']}")
    if normalized["break"] not in {"x1", "x2"}:
        raise AssertionError(f"Invalid break selection: {normalized['break']}")
    return normalized


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_inputs() -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for path, expected in EXPECTED_SHA.items():
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Input SHA drifted: {anim.rel(path)} {actual}")
        records[anim.rel(path)] = {"sha256": actual, "locked": True}
    manifest = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("approved_animation_selection") != {
        "move": "m1",
        "shield_states": "r1",
        "death": "d1",
    }:
        raise AssertionError("M1/R1/D1 is not the certified second-gate choice")
    return records


def load_fx() -> tuple[list[Image.Image], list[Image.Image]]:
    with Image.open(RUNTIME_FX) as source:
        sheet = source.convert("RGBA")
    frames = [sheet.crop((i * FX_FRAME, 0, (i + 1) * FX_FRAME, FX_FRAME)) for i in range(8)]
    return frames[:3], frames[3:]


def recolor(frame: Image.Image, mapping: dict[tuple[int, int, int, int], tuple[int, int, int, int]]) -> Image.Image:
    result = frame.copy()
    for y in range(FX_FRAME):
        for x in range(FX_FRAME):
            replacement = mapping.get(result.getpixel((x, y)))
            if replacement is not None:
                result.putpixel((x, y), replacement)
    return result


def build_b1(base: list[Image.Image]) -> list[Image.Image]:
    return [recolor(frame, DEFAULT_MAP) for frame in base]


def put_existing(frame: Image.Image, base: Image.Image, point: tuple[int, int], color: tuple[int, int, int, int], label: str) -> None:
    if base.getpixel(point)[3] == 0:
        raise AssertionError(f"{label}: color point lost Alpha: {point}")
    frame.putpixel(point, color)


def build_b2(base: list[Image.Image]) -> list[Image.Image]:
    frames = [recolor(frame, DEFAULT_MAP) for frame in base]
    for y in range(15, 18):
        for x in range(15, 18):
            put_existing(frames[0], base[0], (x, y), WHITE if x in (15, 16) else P4, "b2[0]")
    for y in range(14, 19):
        for x in range(14, 19):
            put_existing(frames[1], base[1], (x, y), WHITE if x in (15, 16) else P4, "b2[1]")
    center = (16, 16)
    neighbors = {(16, 15), (15, 16), (17, 16), (16, 17)}
    for y in range(15, 18):
        for x in range(15, 18):
            point = (x, y)
            color = WHITE if point == center else (P5 if point in neighbors else P3)
            put_existing(frames[2], base[2], point, color, "b2[2]")
    return frames


def critical_shield() -> Image.Image:
    with Image.open(R1_NATIVE) as source:
        strip = source.convert("RGBA")
    shield = strip.crop(CRITICAL_SHIELD_SOURCE_BOX)
    if shield.size != (6, 18) or sum(1 for pixel in shield.getdata() if pixel[3]) != 102:
        raise AssertionError("Selected R1 critical shield ROI drifted")
    return shield


def build_x0(base: Image.Image) -> Image.Image:
    result = recolor(base, DEFAULT_MAP)
    shield = critical_shield()
    result.paste(shield, X0_TARGET_BOX[:2])
    if result.crop(X0_TARGET_BOX).tobytes() != shield.tobytes():
        raise AssertionError("X0 critical shield ROI copy drifted")
    if result.getchannel("A").tobytes() != base.getchannel("A").tobytes():
        raise AssertionError("X0 Alpha changed")
    outside = anim.alpha_points(base) - {
        (x, y)
        for y in range(X0_TARGET_BOX[1], X0_TARGET_BOX[3])
        for x in range(X0_TARGET_BOX[0], X0_TARGET_BOX[2])
    }
    if outside != set(X0_SPARKS):
        raise AssertionError(f"X0 spark contract drifted: {outside}")
    return result


def build_x1(base: list[Image.Image]) -> list[Image.Image]:
    return [build_x0(base[0]), *[recolor(frame, DEFAULT_MAP) for frame in base[1:]]]


def build_x2(base: list[Image.Image]) -> list[Image.Image]:
    mappings = (
        DEFAULT_MAP,
        {OLD_RED: P3, OLD_ORANGE: P4, OLD_YELLOW: P4, OLD_DARK: P1},
        {OLD_ORANGE: P1, OLD_RED: P1, OLD_YELLOW: P3, OLD_DARK: P0},
        {OLD_DARK: P0, OLD_RED: P1, OLD_ORANGE: P1, OLD_YELLOW: P1},
    )
    return [build_x0(base[0]), *[recolor(frame, mappings[index]) for index, frame in enumerate(base[1:])]]


def audit_candidate(frames: list[Image.Image], base: list[Image.Image], label: str) -> list[dict[str, object]]:
    metrics: list[dict[str, object]] = []
    for index, (frame, ordinary) in enumerate(zip(frames, base)):
        if frame.getchannel("A").tobytes() != ordinary.getchannel("A").tobytes():
            raise AssertionError(f"{label}[{index}]: Alpha changed")
        box = anim.bbox(frame)
        left, top, right, bottom = box
        center = ((left + right - 1) / 2.0, (top + bottom - 1) / 2.0)
        if center != (15.5, 15.5):
            raise AssertionError(f"{label}[{index}]: center drifted: {center}")
        colors = set(frame.getdata())
        if not colors <= ALLOWED:
            raise AssertionError(f"{label}[{index}]: palette drift: {colors - ALLOWED}")
        if colors & OLD_FX:
            raise AssertionError(f"{label}[{index}]: old red/orange/yellow remains")
        for pixel in frame.getdata():
            if pixel[3] not in (0, 255):
                raise AssertionError(f"{label}[{index}]: non-binary Alpha")
            if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
                raise AssertionError(f"{label}[{index}]: dirty transparent RGB")
        metrics.append(
            {
                "rgba_sha256": anim.rgba_sha(frame),
                "alpha_sha256": hashlib.sha256(frame.getchannel("A").tobytes()).hexdigest(),
                "bbox": list(box),
                "center": list(center),
                "opaque_pixels": len(anim.alpha_points(frame)),
            }
        )
    return metrics


def build_all() -> tuple[dict[str, list[Image.Image]], dict[str, list[dict[str, object]]]]:
    base_b, base_x = load_fx()
    candidates = {
        "b1": build_b1(base_b),
        "b2": build_b2(base_b),
        "x1": build_x1(base_x),
        "x2": build_x2(base_x),
    }
    audits = {
        "b1": audit_candidate(candidates["b1"], base_b, "b1"),
        "b2": audit_candidate(candidates["b2"], base_b, "b2"),
        "x1": audit_candidate(candidates["x1"], base_x, "x1"),
        "x2": audit_candidate(candidates["x2"], base_x, "x2"),
    }
    if candidates["x1"][0].tobytes() != candidates["x2"][0].tobytes():
        raise AssertionError("X1/X2 first frames must share the selected R1 critical shield")
    return candidates, audits


def write_outputs(candidates: dict[str, list[Image.Image]]) -> dict[str, object]:
    base_b, base_x = load_fx()
    outputs: dict[str, object] = {}
    for key, frames in candidates.items():
        base = base_b if key.startswith("b") else base_x
        prefix = "block" if key.startswith("b") else "break"
        native = SOURCE_DIR / f"combat_robot_shield_bearer_elite_{prefix}_{key}_candidate_native.png"
        preview = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{prefix}_{key}_candidate_16x.png"
        delta = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{prefix}_{key}_ordinary_delta_16x.png"
        gif = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{prefix}_{key}_candidate.gif"
        mirror = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{prefix}_{key}_candidate_mirrored.gif"
        strip = anim.make_strip(frames)
        anim.save_png(strip, native)
        anim.save_png(anim.scaled(strip, 16), preview)
        anim.save_png(anim.scaled(anim.delta_strip(frames, base), 16), delta)
        duration = 40 if key.startswith("b") else 60
        anim.save_gif(frames, gif, duration, False)
        anim.save_gif(frames, mirror, duration, True)
        outputs[key] = {
            "native": anim.file_record(native),
            "preview_16x": anim.file_record(preview),
            "ordinary_delta_16x": anim.file_record(delta),
            "gif": anim.file_record(gif),
            "mirrored_gif": anim.file_record(mirror),
            "runtime_fps": 24 if key.startswith("b") else 18,
            "runtime_loop": False,
            "review_duration_ms": duration,
            "frame_rgba_sha256": [anim.rgba_sha(frame) for frame in frames],
        }
    return outputs


def main() -> None:
    args = parse_args()
    selection = resolve_selection(args.approve)
    inputs = verify_inputs()
    candidates, audits = build_all()
    rebuilt, rebuilt_audits = build_all()
    for key in candidates:
        if any(a.tobytes() != b.tobytes() for a, b in zip(candidates[key], rebuilt[key])):
            raise AssertionError(f"{key}: in-memory deterministic rebuild drifted")
        if audits[key] != rebuilt_audits[key]:
            raise AssertionError(f"{key}: audit drifted")
    outputs = write_outputs(candidates)
    stage = (
        "fx_approved_pending_final_candidate"
        if selection is not None
        else "fx_candidates_pending_third_human_gate"
    )
    selected_outputs = None
    if selection is not None:
        selected_outputs = {
            "block": outputs[selection["block"]],
            "break": outputs[selection["break"]],
        }
    stability = {
        "asset": "combat_robot_shield_bearer_elite_fx_candidates",
        "stage": stage,
        "approved_animation_selection": {"move": "m1", "shield_states": "r1", "death": "d1"},
        "approved_fx_selection": selection,
        "runtime_written": False,
        "audits": audits,
        "x0": {
            "critical_shield_source": anim.rel(R1_NATIVE),
            "source_box": list(CRITICAL_SHIELD_SOURCE_BOX),
            "target_box": list(X0_TARGET_BOX),
            "shield_rgba_sha256": anim.rgba_sha(critical_shield()),
            "ordinary_sparks": [list(point) for point in sorted(X0_SPARKS)],
            "roi_exact_copy": True,
            "whole_frame_alpha_inherited": True,
        },
    }
    stability_path = PREVIEW_DIR / "combat_robot_shield_bearer_elite_fx_stability_report.json"
    anim.write_json(stability_path, stability)
    report = {
        "asset": "combat_robot_shield_bearer_elite_fx_candidates",
        "stage": stage,
        "preview_only": True,
        "approved_animation_selection": {"move": "m1", "shield_states": "r1", "death": "d1"},
        "approved_fx_selection": selection,
        "approved_outputs": selected_outputs,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "builder": {"path": anim.rel(SCRIPT), "sha256": sha256(SCRIPT)},
        "input_locks": inputs,
        "outputs": outputs,
        "stability_report": anim.rel(stability_path),
        "stability_report_sha256": sha256(stability_path),
        "checks": {
            "ordinary_fx_alpha_inherited_per_frame": True,
            "center_15_5_15_5_preserved": True,
            "x0_selected_r1_critical_roi_exact": True,
            "x0_six_sparks_preserved": True,
            "fixed_steel_purple_white_palette": True,
            "old_red_orange_yellow_remaining": 0,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "gif_exact_native_nearest_neighbor": True,
            "deterministic_in_memory_rebuild": True,
        },
    }
    report_path = PREVIEW_DIR / "combat_robot_shield_bearer_elite_fx_preview_report.json"
    anim.write_json(report_path, report)
    manifest = {
        "asset": "combat_robot_shield_bearer_elite",
        "stage": stage,
        "approved_anchor": "h1c",
        "approved_animation_selection": {"move": "m1", "shield_states": "r1", "death": "d1"},
        "approved_fx_selection": selection,
        "approved_outputs": selected_outputs,
        "final_human_approved": False,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "candidate_order": ["b1", "b2", "x1", "x2"],
        "report": anim.rel(report_path),
        "report_sha256": sha256(report_path),
        "stability_report": anim.rel(stability_path),
        "stability_report_sha256": sha256(stability_path),
    }
    anim.write_json(FX_MANIFEST, manifest)
    print("COMBAT_ROBOT_SHIELD_BEARER_ELITE_FX_PREVIEWS_OK")
    print(f"report={anim.rel(report_path)}")
    print(f"approved={selection}")
    print(f"manifest={anim.rel(FX_MANIFEST)}")


if __name__ == "__main__":
    main()
