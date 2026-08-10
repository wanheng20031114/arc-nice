#!/usr/bin/env python3
"""Build the preview-only final cardboard-monster animation candidate.

This tool consumes the approved M2/A2/D2 second-gate certificate.  It writes
only review artifacts under ``dev_assets``; it never writes runtime resources.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
from collections import deque
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageSequence


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
DEV_ASSETS = ROOT / "dev_assets"
SOURCE_DIR = DEV_ASSETS / "source_images" / "cardboard_monster"
PREVIEW_DIR = DEV_ASSETS / "generated_previews"

APPROVED_BUILDER = ROOT / "dev_tools" / "build_cardboard_monster_animation_previews.py"
APPROVED_REPORT = enemy_asset_report_path("cardboard_monster_animation_preview_report.json")
APPROVED_MANIFEST = enemy_asset_report_path("cardboard_monster_animation_manifest.json")
APPROVED_STABILITY = enemy_asset_report_path("cardboard_monster_animation_stability.json")
APPROVED_ANCHOR = SOURCE_DIR / "cardboard_monster_anchor_approved_native32.png"

SELECTED_PATHS = {
    "m2": SOURCE_DIR / "cardboard_monster_move_m2_candidate_native.png",
    "a2": SOURCE_DIR / "cardboard_monster_attack_a2_candidate_native.png",
    "d2": SOURCE_DIR / "cardboard_monster_death_d2_candidate_native.png",
}
INPUT_FILE_LOCKS = {
    APPROVED_BUILDER: "7bf3d2a732f7d0f933cf3ecfa555bad1470eab74c9b356d19d15d03ef6b91e1e",
    APPROVED_REPORT: "d7356d0fd96cf0f7a36853b4b244a7929d453af60574e4f1d1ad0aca08d03c6b",
    APPROVED_MANIFEST: "2afae47a73c52383bc4fe154fae02fc0fb7ff144f6d3d568589e7d47af62c845",
    APPROVED_STABILITY: "5737a67188df8057c20e3f9fb5e9373597982efa6b17302edfd035946b2fe44f",
    APPROVED_ANCHOR: "745cc7ec73e3d2268a91f6fb97db996821f32c49b3dc80eb1a4b122ebc298a3d",
    ROOT / "resources/texture/enemy/yuanshi_insect/源石虫.png": "7ff17f9299180beed21ba8a692beb12ed8f86b852607ce9c5ac25d2edc19ed39",
    ROOT / "resources/texture/enemy/slime/slime.png": "65060d4fb5b29cbebbb5bd8fd1116d398ab166351ed433010686bfe78e1fb462",
    ROOT / "resources/texture/enemy/mechanical_life/combat_robot.png": "5cba75330a8e9fe8035cc8fe0a07c9b688e70a170cd34ed4532ecf03773bdb1a",
    ROOT / "resources/texture/enemy/capoo/capoo_swordsman.png": "ed4b098b73e8ed5678e13b7c507a899679e949e210a21f00a25fd60a7d516d00",
}
SELECTED_LOCKS = {
    "m2": {
        "file_sha256": "d3ceed3890ea35e7650ff4143fec139392c49c0c02bd389c1ae11713731840b5",
        "rgba_sha256": "57f6c81d3c2f0f02d4fca07037553d581648d91f6c4066ad0f8ef20b4637fe6f",
    },
    "a2": {
        "file_sha256": "591f9d8c0d4578691b10251407d887961b72655c400e996369c9783e73d1bb08",
        "rgba_sha256": "902dc0a494cf00df383757872ff7d2ac1e9308623310b73820241cff2911fed8",
    },
    "d2": {
        "file_sha256": "b785d42a4ea07773c8931193baec43e10b50405bc8b29bb7ff3833e1540a822c",
        "rgba_sha256": "1caafb0e2db08c15e99fc87ab88c80b493a939b3af601d9a74266715804fb169",
    },
}

APPROVED_SELECTION = {"move": "m2", "attack": "a2", "death": "d2"}
PENDING_STAGE = "final_candidate_pending_third_human_gate"
APPROVED_STAGE = "final_candidate_third_human_gate_approved"
EXPECTED_ATLAS_RGBA_SHA256 = "81e4a17fc6288a6204df5e67af864b4fc02e3644eaef92d1ca01b6b7504a44cf"
FINAL_ATLAS_FILE_SHA256 = "73bad923829c873b83c808954d610735826884e2786a5fb1da21a04240578f2c"
PENDING_CERTIFICATE_LOCKS = {
    "builder_sha256": "29754589660f938c10d6b14a52dff01bcb29f4c944b6d42450599fe2addb30e1",
    "report_sha256": "2d6124b627afd3c0543bf9d1aed796f93b9f4b6b7d8e41be488d14d3b5b909f8",
    "manifest_sha256": "1e11998a5df2e2d8a357f4e37ec3cf55b4c8dabd1ba1bc3bb68532a99a8a3bfe",
    "stability_sha256": "a65ec805de4d7b0fb5cae4323fdc26b0c7b260ab769182a16a860a4e05ba9460",
    "atlas_sha256": FINAL_ATLAS_FILE_SHA256,
    "atlas_rgba_sha256": EXPECTED_ATLAS_RGBA_SHA256,
}

ATLAS_PATH = SOURCE_DIR / "cardboard_monster_final_candidate_atlas.png"
ATLAS_16X_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_atlas_16x.png"
DELTA_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_anchor_frame_delta_8x.png"
SIZE_COMPARISON_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_size_comparison.png"
COLLISION_RIGHT_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_collision_fan_right.png"
COLLISION_LEFT_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_collision_fan_left.png"
CHAIN_RIGHT_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_tracking_windup_slash_right.gif"
CHAIN_LEFT_PATH = PREVIEW_DIR / "cardboard_monster_final_candidate_tracking_windup_slash_left.gif"
REPORT_PATH = enemy_asset_report_path("cardboard_monster_final_candidate_report.json")
MANIFEST_PATH = enemy_asset_report_path("cardboard_monster_final_candidate_manifest.json")
STABILITY_PATH = enemy_asset_report_path("cardboard_monster_final_candidate_stability.json")

ANIMATION_GIF_PATHS = {
    (animation, facing): PREVIEW_DIR / f"cardboard_monster_final_candidate_{animation}_{facing}.gif"
    for animation in ("move", "windup", "slash", "death")
    for facing in ("right", "left")
}

VISUAL_OUTPUTS = [
    ATLAS_PATH,
    ATLAS_16X_PATH,
    ANIMATION_GIF_PATHS[("move", "right")],
    ANIMATION_GIF_PATHS[("move", "left")],
    ANIMATION_GIF_PATHS[("windup", "right")],
    ANIMATION_GIF_PATHS[("windup", "left")],
    ANIMATION_GIF_PATHS[("slash", "right")],
    ANIMATION_GIF_PATHS[("slash", "left")],
    ANIMATION_GIF_PATHS[("death", "right")],
    ANIMATION_GIF_PATHS[("death", "left")],
    CHAIN_RIGHT_PATH,
    CHAIN_LEFT_PATH,
    COLLISION_RIGHT_PATH,
    COLLISION_LEFT_PATH,
    SIZE_COMPARISON_PATH,
    DELTA_PATH,
]
ALLOWLIST = VISUAL_OUTPUTS + [REPORT_PATH, MANIFEST_PATH, STABILITY_PATH]

FRAME = 32
COUNT = 8
TRANSPARENT = (0, 0, 0, 0)
BACKGROUND = (14, 20, 29, 255)
OUTLINE = (116, 87, 61, 255)
DEEP_BROWN = (88, 64, 45, 255)
LIMB_BROWN = (123, 87, 55, 255)
KRAFT_DARK = (177, 145, 102, 255)
KRAFT_MID = (210, 181, 137, 255)
KRAFT_LIGHT = (232, 213, 177, 255)
FOLD_HIGHLIGHT = (245, 234, 208, 255)
PAPER_EDGE = (154, 117, 78, 255)
PAPER_STICK = (225, 202, 159, 255)
EYE_DARK = (79, 67, 59, 255)
FIXED_PALETTE = (
    TRANSPARENT,
    OUTLINE,
    DEEP_BROWN,
    LIMB_BROWN,
    KRAFT_DARK,
    KRAFT_MID,
    KRAFT_LIGHT,
    FOLD_HIGHLIGHT,
    PAPER_EDGE,
    PAPER_STICK,
    EYE_DARK,
)
FIXED_PALETTE_SET = frozenset(FIXED_PALETTE)

ANIMATION_SPECS = {
    "move": {"cells": [(0, index) for index in range(8)], "runtime_fps": 12, "preview_ms": [80] * 8},
    "windup": {"cells": [(1, index) for index in range(3)], "runtime_fps": 9, "preview_ms": [110] * 3},
    "slash": {"cells": [(1, index) for index in range(3, 8)], "runtime_fps": 15, "preview_ms": [70] * 5},
    "death": {"cells": [(2, index) for index in range(8)], "runtime_fps": 8, "preview_ms": [120] * 8},
}

COMPARISON_REFERENCE_SPECS = (
    {
        "id": "yuanshi_insect",
        "label": "YUANSHI INSECT",
        "path": ROOT / "resources/texture/enemy/yuanshi_insect/源石虫.png",
        "crop": (0, 32, 32, 64),
        "target_size": None,
        "source_scale": 1.0,
        "frame_rgba_sha256": "e231f3f3a73740246bfbb92e8dbbe309048d5c0bf0c3afb49454d72bfea22119",
    },
    {
        "id": "slime",
        "label": "SLIME",
        "path": ROOT / "resources/texture/enemy/slime/slime.png",
        "crop": (0, 0, 32, 32),
        "target_size": None,
        "source_scale": 1.0,
        "frame_rgba_sha256": "15ba2a5721138358b78037b993fa4786096c75c2deb503401204d4c1c22ee805",
    },
    {
        "id": "combat_robot",
        "label": "COMBAT ROBOT",
        "path": ROOT / "resources/texture/enemy/mechanical_life/combat_robot.png",
        "crop": (0, 0, 32, 32),
        "target_size": None,
        "source_scale": 1.0,
        "frame_rgba_sha256": "72ad7f301c24a1f5b5e6c25b97ec071c59406401e8307413b71bfef38b0501f5",
    },
    {
        "id": "capoo_swordsman",
        "label": "CAPOO x0.31",
        "path": ROOT / "resources/texture/enemy/capoo/capoo_swordsman.png",
        "crop": (0, 0, 96, 96),
        "target_size": (30, 30),
        "source_scale": 0.3125,
        "frame_rgba_sha256": "b43f86ea66a1426d25f105f9984373abf58df443d84ab89fbd37f2c7fcb88df5",
    },
)

ALLOWLIST_COUNT = 19
DETERMINISM_SNAPSHOT_SCOPE = "16 visual outputs"
CERTIFICATE_JSON_PATHS = (REPORT_PATH, MANIFEST_PATH, STABILITY_PATH)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def json_text(payload: object) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def ensure_dev_asset(path: Path) -> None:
    resolved = path.resolve()
    root = DEV_ASSETS.resolve()
    if resolved != root and root not in resolved.parents:
        raise AssertionError(f"Refused non-dev_assets output: {path}")
    if not path.name.startswith("cardboard_monster_final_candidate_"):
        raise AssertionError(f"Refused non-final-candidate output name: {path.name}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_dev_asset(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def write_json(path: Path, payload: object) -> None:
    ensure_dev_asset(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json_text(payload), encoding="utf-8", newline="\n")


def file_record(path: Path) -> dict[str, object]:
    record: dict[str, object] = {"path": rel(path), "sha256": sha256(path)}
    if path.suffix.lower() in (".png", ".gif"):
        with Image.open(path) as opened:
            record["size"] = list(opened.size)
            record["mode"] = opened.mode
            if path.suffix.lower() == ".gif":
                record["frames"] = opened.n_frames
    return record


def verify_inputs() -> dict[str, object]:
    records: dict[str, object] = {}
    for path, expected in INPUT_FILE_LOCKS.items():
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Locked input drifted: {rel(path)} expected={expected} actual={actual}")
        records[rel(path)] = {"sha256": actual, "locked": True}
    approved_report = json.loads(APPROVED_REPORT.read_text(encoding="utf-8"))
    approved_manifest = json.loads(APPROVED_MANIFEST.read_text(encoding="utf-8"))
    approved_stability = json.loads(APPROVED_STABILITY.read_text(encoding="utf-8"))
    for payload, label in (
        (approved_report, "report"),
        (approved_manifest, "manifest"),
        (approved_stability, "stability"),
    ):
        if payload.get("stage") != "second_human_gate_approved":
            raise AssertionError(f"Approved {label} stage drifted")
        if payload.get("approved_animation_selection") != APPROVED_SELECTION:
            raise AssertionError(f"Approved {label} selection drifted")
        if payload.get("second_human_approved") is not True:
            raise AssertionError(f"Approved {label} boolean drifted")
        if payload.get("final_human_approved") is not False:
            raise AssertionError(f"Approved {label} unexpectedly claims final approval")
        if payload.get("runtime_written") is not False:
            raise AssertionError(f"Approved {label} unexpectedly claims runtime output")
        if payload.get("imagegen_pixels_imported", False) is not False:
            raise AssertionError(f"Approved {label} claims ImageGen pixels")
    for key, path in SELECTED_PATHS.items():
        actual_file = sha256(path)
        if actual_file != SELECTED_LOCKS[key]["file_sha256"]:
            raise AssertionError(f"Selected {key} file drifted")
        with Image.open(path) as opened:
            image = opened.convert("RGBA")
        actual_rgba = rgba_sha(image)
        if actual_rgba != SELECTED_LOCKS[key]["rgba_sha256"]:
            raise AssertionError(f"Selected {key} decoded RGBA drifted")
        records[rel(path)] = {
            "sha256": actual_file,
            "rgba_sha256": actual_rgba,
            "locked": True,
            "imagegen_pixels_imported": False,
        }
    return records


def resolve_final_approval(requested: bool) -> tuple[bool, dict[str, object] | None]:
    certificate_paths = (REPORT_PATH, MANIFEST_PATH, STABILITY_PATH)
    if not all(path.is_file() for path in certificate_paths):
        if requested:
            raise AssertionError("Cannot approve a missing third-gate certificate chain")
        return False, None
    report = json.loads(REPORT_PATH.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    stability = json.loads(STABILITY_PATH.read_text(encoding="utf-8"))
    payloads = (report, manifest, stability)

    if all(payload.get("stage") == APPROVED_STAGE for payload in payloads):
        approval_source = manifest.get("final_human_approval")
        if not isinstance(approval_source, dict):
            raise AssertionError("Approved final manifest lost its human-approval record")
        for key, expected in PENDING_CERTIFICATE_LOCKS.items():
            if approval_source.get(key) != expected:
                raise AssertionError(f"Approved third-gate source lock drifted: {key}")
        for payload in payloads:
            if (
                payload.get("third_human_approved") is not True
                or payload.get("final_human_approved") is not True
                or payload.get("runtime_written") is not False
                or payload.get("runtime_paths_written") != []
            ):
                raise AssertionError("Approved third-gate certificate flags drifted")
        return True, approval_source

    if not all(payload.get("stage") == PENDING_STAGE for payload in payloads):
        raise AssertionError("Mixed or unknown third-gate certificate stages")
    if not requested:
        return False, None
    actual_locks = {
        "report_sha256": sha256(REPORT_PATH),
        "manifest_sha256": sha256(MANIFEST_PATH),
        "stability_sha256": sha256(STABILITY_PATH),
        "atlas_sha256": sha256(ATLAS_PATH),
    }
    for key, actual in actual_locks.items():
        if actual != PENDING_CERTIFICATE_LOCKS[key]:
            raise AssertionError(f"Pending third-gate certificate drifted: {key}")
    with Image.open(ATLAS_PATH) as opened:
        atlas_rgba = rgba_sha(opened.convert("RGBA"))
    if atlas_rgba != PENDING_CERTIFICATE_LOCKS["atlas_rgba_sha256"]:
        raise AssertionError("Pending third-gate atlas decoded RGBA drifted")
    if stability.get("builder_sha256") != PENDING_CERTIFICATE_LOCKS["builder_sha256"]:
        raise AssertionError("Pending third-gate builder certificate drifted")
    for payload in payloads:
        if (
            payload.get("approved_animation_selection") != APPROVED_SELECTION
            or payload.get("final_human_approved") is not False
            or payload.get("runtime_written") is not False
            or payload.get("runtime_paths_written") != []
        ):
            raise AssertionError("Pending third-gate contract drifted")
    slash = report.get("animations", {}).get("slash", {})
    collision = report.get("collision_fan", {})
    if (
        slash.get("damage_frame_local_index") != 1
        or slash.get("damage_frame_source_cell") != {"row": 1, "column": 4}
        or collision.get("source_cell") != {"row": 1, "column": 4}
    ):
        raise AssertionError("Pending slash damage-frame certificate drifted")
    approval_source = {
        **PENDING_CERTIFICATE_LOCKS,
        "decision": "approved",
        "approved_animation_selection": APPROVED_SELECTION,
        "damage_frame_local_index": 1,
        "damage_frame_source_cell": {"row": 1, "column": 4},
        "runtime_written": False,
        "imagegen_pixels_imported": False,
    }
    return True, approval_source


def load_selected_strips() -> dict[str, Image.Image]:
    strips: dict[str, Image.Image] = {}
    for key, path in SELECTED_PATHS.items():
        with Image.open(path) as opened:
            strip = opened.convert("RGBA")
        if strip.size != (256, 32):
            raise AssertionError(f"Selected {key} strip geometry drifted: {strip.size}")
        strips[key] = strip
    return strips


def build_atlas(strips: dict[str, Image.Image]) -> Image.Image:
    atlas = Image.new("RGBA", (256, 96), TRANSPARENT)
    for row, key in enumerate(("m2", "a2", "d2")):
        atlas.alpha_composite(strips[key], (0, row * 32))
    if rgba_sha(atlas) != EXPECTED_ATLAS_RGBA_SHA256:
        raise AssertionError(f"Final atlas RGBA drifted: {rgba_sha(atlas)}")
    return atlas


def frame_from(atlas: Image.Image, row: int, column: int) -> Image.Image:
    return atlas.crop((column * FRAME, row * FRAME, (column + 1) * FRAME, (row + 1) * FRAME))


def animation_frames(atlas: Image.Image, animation: str) -> list[Image.Image]:
    return [frame_from(atlas, row, column) for row, column in ANIMATION_SPECS[animation]["cells"]]


def opaque_points(image: Image.Image) -> set[tuple[int, int]]:
    return {(x, y) for y in range(image.height) for x in range(image.width) if image.getpixel((x, y))[3]}


def components_8(points: set[tuple[int, int]]) -> list[set[tuple[int, int]]]:
    remaining = set(points)
    result: list[set[tuple[int, int]]] = []
    while remaining:
        start = remaining.pop()
        component = {start}
        pending = deque((start,))
        while pending:
            x, y = pending.popleft()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    point = (x + dx, y + dy)
                    if point in remaining:
                        remaining.remove(point)
                        component.add(point)
                        pending.append(point)
        result.append(component)
    return result


def audit_frame(image: Image.Image, row: int, column: int) -> dict[str, object]:
    if image.size != (32, 32) or image.mode != "RGBA":
        raise AssertionError(f"Frame r{row}c{column} geometry drifted")
    pixels = list(image.getdata())
    colors = set(pixels)
    if not colors <= FIXED_PALETTE_SET:
        raise AssertionError(f"Frame r{row}c{column} off-palette colors: {colors - FIXED_PALETTE_SET}")
    if any(pixel[3] not in (0, 255) for pixel in pixels):
        raise AssertionError(f"Frame r{row}c{column} non-binary alpha")
    if any(pixel[:3] != (0, 0, 0) for pixel in pixels if pixel[3] == 0):
        raise AssertionError(f"Frame r{row}c{column} transparent RGB drifted")
    bbox = image.getbbox()
    if bbox is None:
        raise AssertionError(f"Frame r{row}c{column} is empty")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    limit = (24, 23) if row == 0 else (28, 24)
    if width > limit[0] or height > limit[1] or bbox[3] != 28:
        raise AssertionError(f"Frame r{row}c{column} bbox drifted: {bbox}")
    connected = components_8(opaque_points(image))
    if len(connected) != 1:
        raise AssertionError(f"Frame r{row}c{column} disconnected: {len(connected)}")
    eye_points = {(x, y) for y in range(32) for x in range(32) if image.getpixel((x, y)) == EYE_DARK}
    eye_components = components_8(eye_points) if eye_points else []
    mouth_like = 0
    for y in range(32):
        run = 0
        for x in range(32):
            if (x, y) in eye_points:
                run += 1
                mouth_like = max(mouth_like, run)
            else:
                run = 0
    if mouth_like >= 3:
        raise AssertionError(f"Frame r{row}c{column} contains a mouth-like dark run")
    if any(
        max(x for x, _ in component) - min(x for x, _ in component) + 1 > 2
        or max(y for _, y in component) - min(y for _, y in component) + 1 > 2
        for component in eye_components
    ):
        raise AssertionError(f"Frame r{row}c{column} eye component drifted")
    stick_pixels = [
        (x, y)
        for y in range(32)
        for x in range(22, 32)
        if image.getpixel((x, y)) in (PAPER_EDGE, PAPER_STICK, FOLD_HIGHLIGHT)
    ]
    if not stick_pixels:
        raise AssertionError(f"Frame r{row}c{column} lost the paper stick")
    return {
        "source_cell": {"row": row, "column": column},
        "rgba_sha256": rgba_sha(image),
        "bbox": list(bbox),
        "visible_size": [width, height],
        "registered_center_x": 16,
        "baseline_bottom_exclusive": 28,
        "connected_components_8": 1,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
        "fixed_palette": True,
        "eye_component_count": len(eye_components),
        "mouth_like_horizontal_run": mouth_like,
        "mouth_authored": False,
        "paper_stick_pixels": len(stick_pixels),
        "paper_stick_connected_to_character": True,
        "paper_stick_has_collision": False,
    }


def composite_character(frame: Image.Image, mirrored: bool, scale: int = 16) -> Image.Image:
    native = ImageOps.mirror(frame) if mirrored else frame
    canvas = Image.new("RGBA", (32, 32), BACKGROUND)
    canvas.alpha_composite(native)
    return canvas.resize((32 * scale, 32 * scale), Image.Resampling.NEAREST).convert("RGB")


def encode_exact_gif(
    frames: list[Image.Image], durations: list[int], loop: bool
) -> tuple[bytes, dict[str, object]]:
    rgb_frames = [frame.convert("RGB") for frame in frames]
    colors = sorted({pixel for frame in rgb_frames for pixel in frame.getdata()})
    if len(colors) > 256:
        raise AssertionError(f"GIF requires {len(colors)} colors")
    index = {color: value for value, color in enumerate(colors)}
    palette = [channel for color in colors for channel in color] + [0] * ((256 - len(colors)) * 3)
    paletted: list[Image.Image] = []
    for frame in rgb_frames:
        converted = Image.new("P", frame.size)
        converted.putpalette(palette)
        converted.putdata([index[pixel] for pixel in frame.getdata()])
        paletted.append(converted)

    def encode() -> bytes:
        buffer = io.BytesIO()
        options = {
            "format": "GIF",
            "save_all": True,
            "append_images": paletted[1:],
            "duration": durations,
            "optimize": False,
            "disposal": 2,
        }
        if loop:
            options["loop"] = 0
        paletted[0].save(buffer, **options)
        return buffer.getvalue()

    first, second = encode(), encode()
    if first != second:
        raise AssertionError("GIF double-encode drifted")
    with Image.open(io.BytesIO(first)) as opened:
        decoded = [frame.convert("RGB") for frame in ImageSequence.Iterator(opened)]
        decoded_durations = [frame.info.get("duration") for frame in ImageSequence.Iterator(opened)]
        decoded_loop = opened.info.get("loop")
    if len(decoded) != len(rgb_frames) or decoded_durations != durations:
        raise AssertionError("GIF frame count or timing drifted")
    if any(actual.tobytes() != expected.tobytes() for actual, expected in zip(decoded, rgb_frames)):
        raise AssertionError("GIF palette projection changed review pixels")
    if (decoded_loop == 0) is not loop:
        raise AssertionError(f"GIF loop contract drifted: loop={loop} decoded={decoded_loop}")
    return first, {
        "frames": len(rgb_frames),
        "durations_ms": durations,
        "unique_rgb_colors": len(colors),
        "decoded_matches_source_rgb": True,
        "deterministic_double_encode": True,
        "loop": loop,
        "decoded_loop_extension": decoded_loop,
    }


def save_exact_gif(
    frames: list[Image.Image], path: Path, durations: list[int], loop: bool
) -> dict[str, object]:
    ensure_dev_asset(path)
    payload, audit = encode_exact_gif(frames, durations, loop)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return {**file_record(path), **audit}


def sector_points(
    origin: tuple[int, int],
    facing: str,
    inner: int = 5,
    outer: int = 16,
    segments: int = 12,
) -> list[tuple[int, int]]:
    center_angle = 0.0 if facing == "right" else 180.0
    angles = [
        center_angle - 22.5 + index * (45.0 / segments)
        for index in range(segments + 1)
    ]
    outer_points = [
        (round(origin[0] + math.cos(math.radians(angle)) * outer), round(origin[1] + math.sin(math.radians(angle)) * outer))
        for angle in angles
    ]
    inner_points = [
        (round(origin[0] + math.cos(math.radians(angle)) * inner), round(origin[1] + math.sin(math.radians(angle)) * inner))
        for angle in reversed(angles)
    ]
    return outer_points + inner_points


def draw_fan(
    canvas: Image.Image, origin: tuple[int, int], facing: str, segments: int = 12
) -> None:
    overlay = Image.new("RGBA", canvas.size, TRANSPARENT)
    draw = ImageDraw.Draw(overlay)
    points = sector_points(origin, facing, segments=segments)
    draw.polygon(points, fill=(255, 174, 44, 56), outline=(255, 194, 72, 255))
    canvas.alpha_composite(overlay)


def draw_target(canvas: Image.Image, point: tuple[int, int], locked: bool) -> None:
    draw = ImageDraw.Draw(canvas)
    color = (255, 103, 145, 255) if locked else (103, 226, 255, 255)
    x, y = point
    draw.line((x - 3, y, x + 3, y), fill=color, width=1)
    draw.line((x, y - 3, x, y + 3), fill=color, width=1)
    draw.rectangle((x - 1, y - 1, x + 1, y + 1), outline=(255, 255, 255, 255))


def build_chain(atlas: Image.Image, facing: str) -> tuple[list[Image.Image], list[int], list[dict[str, object]]]:
    source = [
        ("tracking", 0, 6, 80),
        ("tracking", 0, 7, 80),
        ("windup", 1, 0, 110),
        ("windup", 1, 1, 110),
        ("windup", 1, 2, 110),
        ("slash", 1, 3, 70),
        ("slash", 1, 4, 70),
        ("slash", 1, 5, 70),
        ("slash", 1, 6, 70),
        ("slash", 1, 7, 70),
    ]
    right_target_x = [56, 58, 60, 60, 60, 60, 52, 34, 24, 16]
    frames: list[Image.Image] = []
    durations: list[int] = []
    timeline: list[dict[str, object]] = []
    for index, ((phase, row, column, duration), target_right) in enumerate(zip(source, right_target_x)):
        actor = frame_from(atlas, row, column)
        mirrored = facing == "left"
        actor = ImageOps.mirror(actor) if mirrored else actor
        native = Image.new("RGBA", (80, 48), BACKGROUND)
        native.alpha_composite(actor, (24, 8))
        if phase in ("windup", "slash"):
            draw_fan(native, (40, 24), facing)
        target_x = 79 - target_right if mirrored else target_right
        facing_locked = phase == "slash"
        draw_target(native, (target_x, 18), facing_locked)
        rendered = native.resize((640, 384), Image.Resampling.NEAREST).convert("RGB")
        frames.append(rendered)
        durations.append(duration)
        target_behind = target_x > 40 if mirrored else target_x < 40
        timeline.append({
            "preview_frame": index,
            "phase": phase,
            "source_cell": {"row": row, "column": column},
            "source_animation": "move" if row == 0 else ("windup" if column < 3 else "slash"),
            "facing": facing,
            "duration_ms": duration,
            "target_review_x": target_x,
            "committed_target_fixed_during_windup": phase != "windup" or target_right == 60,
            "facing_lock_active": facing_locked,
            "target_is_behind_locked_facing": facing_locked and target_behind,
            "fan_segments": 12 if phase in ("windup", "slash") else None,
            "fan_angular_step_degrees": 3.75 if phase in ("windup", "slash") else None,
        })
    if len({item["target_review_x"] for item in timeline if item["phase"] == "windup"}) != 1:
        raise AssertionError(f"{facing} windup target is not committed")
    if not any(item["target_is_behind_locked_facing"] for item in timeline):
        raise AssertionError(f"{facing} chain never proves behind-target facing lock")
    if len({item["facing"] for item in timeline if item["phase"] == "slash"}) != 1:
        raise AssertionError(f"{facing} slash facing reversed")
    return frames, durations, timeline


def build_collision_overlay(frame: Image.Image, facing: str) -> Image.Image:
    actor = ImageOps.mirror(frame) if facing == "left" else frame
    native = Image.new("RGBA", (64, 48), BACKGROUND)
    native.alpha_composite(actor, (16, 8))
    draw_fan(native, (32, 24), facing)
    required_arc_pixels = ((48, 21), (48, 27)) if facing == "right" else ((16, 21), (16, 27))
    if not all(native.getpixel(point) == (255, 194, 72, 255) for point in required_arc_pixels):
        raise AssertionError(f"{facing} 12-segment attack-fan raster lost required arc pixels")
    draw = ImageDraw.Draw(native)
    draw.rectangle((25, 20, 38, 31), outline=(67, 227, 238, 255), width=1)
    draw.point((32, 24), fill=(255, 255, 255, 255))
    return native.resize((512, 384), Image.Resampling.NEAREST)


def load_registered_comparison_reference(spec: dict[str, object]) -> tuple[Image.Image, dict[str, object]]:
    path = spec["path"]
    if not isinstance(path, Path):
        raise AssertionError("Comparison reference path contract drifted")
    with Image.open(path) as opened:
        frame = opened.convert("RGBA").crop(tuple(spec["crop"]))
    target_size = spec["target_size"]
    if target_size is not None:
        frame = frame.resize(tuple(target_size), Image.Resampling.NEAREST)
    if rgba_sha(frame) != spec["frame_rgba_sha256"]:
        raise AssertionError(f"Comparison reference frame drifted: {spec['id']}")
    bbox = frame.getbbox()
    if bbox is None:
        raise AssertionError(f"Comparison reference is empty: {spec['id']}")
    offset = ((32 - frame.width) // 2, 28 - bbox[3])
    registered = Image.new("RGBA", (32, 32), TRANSPARENT)
    registered.alpha_composite(frame, offset)
    registered_bbox = registered.getbbox()
    if registered_bbox is None or registered_bbox[3] != 28:
        raise AssertionError(f"Comparison baseline registration drifted: {spec['id']}")
    record = {
        "id": spec["id"],
        "label": spec["label"],
        "source_path": rel(path),
        "source_file_sha256": sha256(path),
        "source_crop": list(spec["crop"]),
        "source_scale": spec["source_scale"],
        "target_size": list(frame.size),
        "frame_rgba_sha256": rgba_sha(frame),
        "registration_offset": list(offset),
        "registered_bbox": list(registered_bbox),
        "baseline_bottom_exclusive": 28,
    }
    return registered, record


def build_size_comparison(atlas: Image.Image) -> tuple[Image.Image, dict[str, object]]:
    samples: list[tuple[str, Image.Image]] = []
    records: list[dict[str, object]] = []
    for spec in COMPARISON_REFERENCE_SPECS:
        registered, record = load_registered_comparison_reference(spec)
        samples.append((str(spec["label"]), registered))
        records.append(record)
    move_frame = frame_from(atlas, 0, 0)
    move_bbox = move_frame.getbbox()
    if move_bbox is None or move_bbox[3] != 28:
        raise AssertionError("Final move F0 baseline drifted")
    samples.append(("FINAL MOVE F0", move_frame))
    records.append({
        "id": "cardboard_monster_final_move_f0",
        "label": "FINAL MOVE F0",
        "source_path": rel(ATLAS_PATH),
        "source_cell": {"row": 0, "column": 0},
        "source_scale": 1.0,
        "target_size": [32, 32],
        "frame_rgba_sha256": rgba_sha(move_frame),
        "registration_offset": [0, 0],
        "registered_bbox": list(move_bbox),
        "baseline_bottom_exclusive": 28,
    })
    slot_width, height = 290, 330
    canvas = Image.new("RGBA", (slot_width * len(samples), height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    for index, (label, frame) in enumerate(samples):
        x0 = index * slot_width + 17
        y0 = 20
        rendered = Image.new("RGBA", (32, 32), BACKGROUND)
        rendered.alpha_composite(frame)
        rendered = rendered.resize((256, 256), Image.Resampling.NEAREST)
        canvas.alpha_composite(rendered, (x0, y0))
        center_x = x0 + 16 * 8
        baseline_y = y0 + 28 * 8
        draw.line((center_x, y0, center_x, y0 + 256), fill=(68, 125, 143, 255), width=1)
        draw.line((x0, baseline_y, x0 + 256, baseline_y), fill=(255, 188, 69, 255), width=1)
        draw.text((x0, 290), label, font=font, fill=(238, 238, 232, 255))
    return canvas, {
        "labels": [label for label, _frame in samples],
        "preview_scale": 8,
        "resampling": "NEAREST",
        "shared_baseline_bottom_exclusive": 28,
        "gate1_extraction_contract_reused": True,
        "samples": records,
    }


def build_anchor_delta(atlas: Image.Image, anchor: Image.Image) -> tuple[Image.Image, list[dict[str, object]]]:
    delta = Image.new("RGBA", atlas.size, TRANSPARENT)
    records: list[dict[str, object]] = []
    for row in range(3):
        for column in range(8):
            frame = frame_from(atlas, row, column)
            changed = 0
            removed = 0
            for y in range(32):
                for x in range(32):
                    current = frame.getpixel((x, y))
                    base = anchor.getpixel((x, y))
                    if current == base:
                        continue
                    changed += 1
                    output = current
                    if current[3] == 0 and base[3] != 0:
                        removed += 1
                        output = (232, 86, 76, 255)
                    delta.putpixel((column * 32 + x, row * 32 + y), output)
            records.append({"source_cell": {"row": row, "column": column}, "changed_pixels": changed, "removed_pixels_marked_red": removed})
    return delta.resize((2048, 768), Image.Resampling.NEAREST), records


def render_visual_outputs(atlas: Image.Image, anchor: Image.Image) -> tuple[dict[str, object], dict[str, object]]:
    save_png(atlas, ATLAS_PATH)
    save_png(atlas.resize((4096, 1536), Image.Resampling.NEAREST), ATLAS_16X_PATH)
    animation_records: dict[str, object] = {}
    for animation, spec in ANIMATION_SPECS.items():
        frames = animation_frames(atlas, animation)
        facing_records: dict[str, object] = {}
        for facing in ("right", "left"):
            rendered = [composite_character(frame, facing == "left") for frame in frames]
            path = ANIMATION_GIF_PATHS[(animation, facing)]
            facing_records[facing] = save_exact_gif(
                rendered, path, list(spec["preview_ms"]), animation == "move"
            )
        animation_record: dict[str, object] = {
            "source_cells": [{"row": row, "column": column} for row, column in spec["cells"]],
            "frame_count": len(frames),
            "runtime_fps": spec["runtime_fps"],
            "preview_durations_ms": spec["preview_ms"],
            "loop": animation == "move",
            "facings": facing_records,
        }
        if animation == "slash":
            damage_frame_local_index = 1
            damage_row, damage_column = spec["cells"][damage_frame_local_index]
            if (damage_row, damage_column) != (1, 4):
                raise AssertionError("Slash damage frame no longer maps local index 1 to source row 1 column 4")
            animation_record.update({
                "damage_frame_local_index": damage_frame_local_index,
                "damage_frame_source_cell": {"row": damage_row, "column": damage_column},
            })
        animation_records[animation] = animation_record
    chain_records: dict[str, object] = {}
    for facing, path in (("right", CHAIN_RIGHT_PATH), ("left", CHAIN_LEFT_PATH)):
        frames, durations, timeline = build_chain(atlas, facing)
        chain_records[facing] = {
            "gif": save_exact_gif(frames, path, durations, True),
            "timeline": timeline,
            "fan_segments": 12,
            "fan_angular_step_degrees": 3.75,
            "windup_committed_target_fixed": True,
            "slash_facing_locked": True,
            "target_crosses_behind_without_reverse": True,
        }
    slash_frame = frame_from(atlas, 1, 4)
    save_png(build_collision_overlay(slash_frame, "right"), COLLISION_RIGHT_PATH)
    save_png(build_collision_overlay(slash_frame, "left"), COLLISION_LEFT_PATH)
    size_comparison, size_comparison_contract = build_size_comparison(atlas)
    save_png(size_comparison, SIZE_COMPARISON_PATH)
    delta, delta_records = build_anchor_delta(atlas, anchor)
    save_png(delta, DELTA_PATH)
    return {
        "animations": animation_records,
        "tracking_windup_slash": chain_records,
        "collision_fan": {
            "source_cell": {"row": 1, "column": 4},
            "body_shape": {"size": [14, 12], "world_position": [0, 2]},
            "fan": {
                "world_origin": [0, 0],
                "inner_radius": 5,
                "outer_radius": 16,
                "angle_degrees": 45,
                "segments": 12,
                "angular_step_degrees": 3.75,
                "arc_vertex_count": 13,
                "right_required_raster_arc_pixels": [[48, 21], [48, 27]],
                "left_required_raster_arc_pixels": [[16, 21], [16, 27]],
            },
            "paper_stick_has_collision": False,
            "right": {**file_record(COLLISION_RIGHT_PATH), "source_cell": {"row": 1, "column": 4}},
            "left": {**file_record(COLLISION_LEFT_PATH), "source_cell": {"row": 1, "column": 4}},
        },
        "size_comparison": {**file_record(SIZE_COMPARISON_PATH), **size_comparison_contract},
        "anchor_frame_delta": {"file": file_record(DELTA_PATH), "cells": delta_records},
    }, {rel(path): sha256(path) for path in VISUAL_OUTPUTS}


def audit_atlas(atlas: Image.Image, strips: dict[str, Image.Image]) -> dict[str, object]:
    if atlas.size != (256, 96) or atlas.mode != "RGBA":
        raise AssertionError(f"Atlas geometry drifted: {atlas.size}/{atlas.mode}")
    row_records: list[dict[str, object]] = []
    frame_records: list[dict[str, object]] = []
    for row, key in enumerate(("m2", "a2", "d2")):
        atlas_row = atlas.crop((0, row * 32, 256, (row + 1) * 32))
        changed = sum(
            1
            for actual, expected in zip(atlas_row.getdata(), strips[key].getdata())
            if actual != expected
        )
        if changed != 0:
            raise AssertionError(f"Atlas row {row} differs from {key}: {changed}")
        row_records.append({
            "row": row,
            "source": key,
            "source_path": rel(SELECTED_PATHS[key]),
            "source_file_sha256": SELECTED_LOCKS[key]["file_sha256"],
            "source_rgba_sha256": SELECTED_LOCKS[key]["rgba_sha256"],
            "changed_pixels_source_vs_atlas": 0,
        })
        for column in range(8):
            frame_records.append(audit_frame(frame_from(atlas, row, column), row, column))
    pixels = list(atlas.getdata())
    if not set(pixels) <= FIXED_PALETTE_SET:
        raise AssertionError("Atlas palette drifted")
    return {
        "size": [256, 96],
        "mode": "RGBA",
        "rgba_sha256": rgba_sha(atlas),
        "expected_rgba_sha256": EXPECTED_ATLAS_RGBA_SHA256,
        "fixed_palette_rgba": [list(color) for color in FIXED_PALETTE],
        "fixed_palette_size": 11,
        "actual_palette_size": len(set(pixels)),
        "binary_alpha": all(pixel[3] in (0, 255) for pixel in pixels),
        "transparent_rgb_zero": all(pixel[:3] == (0, 0, 0) for pixel in pixels if pixel[3] == 0),
        "rows": row_records,
        "frames": frame_records,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        action="store_true",
        help="Record the already-confirmed third/final human approval without writing runtime assets.",
    )
    args = parser.parse_args()
    final_human_approved, approval_source = resolve_final_approval(args.approve)
    stage = APPROVED_STAGE if final_human_approved else PENDING_STAGE

    input_records = verify_inputs()
    strips = load_selected_strips()
    atlas_first = build_atlas(strips)
    atlas_second = build_atlas(strips)
    if atlas_first.tobytes() != atlas_second.tobytes():
        raise AssertionError("In-memory atlas reconstruction drifted")
    with Image.open(APPROVED_ANCHOR) as opened:
        anchor = opened.convert("RGBA")
    atlas_audit = audit_atlas(atlas_first, strips)

    if len(ALLOWLIST) != ALLOWLIST_COUNT or len(VISUAL_OUTPUTS) != 16:
        raise AssertionError("Final-candidate allowlist/snapshot scope drifted")
    if len(set(ALLOWLIST)) != ALLOWLIST_COUNT:
        raise AssertionError("Final-candidate allowlist contains duplicates")

    review_first, snapshot_first = render_visual_outputs(atlas_first, anchor)
    output_records_first = {rel(path): file_record(path) for path in VISUAL_OUTPUTS}
    review_second, snapshot_second = render_visual_outputs(atlas_second, anchor)
    output_records_second = {rel(path): file_record(path) for path in VISUAL_OUTPUTS}
    if snapshot_first != snapshot_second:
        drift = sorted(path for path in set(snapshot_first) | set(snapshot_second) if snapshot_first.get(path) != snapshot_second.get(path))
        raise AssertionError(f"Final preview output drifted: {drift}")
    if output_records_first != output_records_second:
        raise AssertionError("Final preview file records drifted")
    if json.dumps(review_first, sort_keys=True, ensure_ascii=False) != json.dumps(review_second, sort_keys=True, ensure_ascii=False):
        raise AssertionError("Final preview review records drifted")

    excluded_json_paths = [rel(path) for path in CERTIFICATE_JSON_PATHS]
    determinism_contract = {
        "allowlist_count": ALLOWLIST_COUNT,
        "determinism_snapshot_scope": DETERMINISM_SNAPSHOT_SCOPE,
        "determinism_snapshot_count": len(VISUAL_OUTPUTS),
        "self_referential_json_excluded_from_snapshot": True,
        "snapshot_excluded_json_paths": excluded_json_paths,
        "certificate_structure_comparison": {
            "report_full_payload_equal": True,
            "manifest_full_payload_equal": True,
            "comparison_method": "canonical_prewrite_json_bytes",
        },
    }
    stability = {
        "asset": "cardboard_monster_final_candidate",
        "stage": stage,
        "preview_only": True,
        "approved_animation_selection": APPROVED_SELECTION,
        "first_human_approved": True,
        "second_human_approved": True,
        "third_human_approved": final_human_approved,
        "final_human_approved": final_human_approved,
        "runtime_written": False,
        "runtime_paths_written": [],
        "imagegen_pixels_imported": False,
        "builder_sha256": sha256(SCRIPT),
        "passes": 2,
        "drift_count": 0,
        "drift_paths": [],
        **determinism_contract,
        "output_allowlist": [rel(path) for path in ALLOWLIST],
        "snapshot_1": snapshot_first,
        "snapshot_2": snapshot_second,
    }
    if approval_source is not None:
        stability["final_human_approval"] = approval_source
    stability_sha256 = hashlib.sha256(json_text(stability).encode("utf-8")).hexdigest()

    def make_report(review: dict[str, object]) -> dict[str, object]:
        return {
            "schema_version": 1,
            "asset": "cardboard_monster_final_candidate",
            "stage": stage,
            "preview_only": True,
            "approved_animation_selection": APPROVED_SELECTION,
            "first_human_approved": True,
            "second_human_approved": True,
            "third_human_approved": final_human_approved,
            "final_human_approved": final_human_approved,
            "runtime_written": False,
            "runtime_paths_written": [],
            "imagegen_pixels_imported": False,
            "builder": {"path": rel(SCRIPT), "sha256": sha256(SCRIPT)},
            "inputs": input_records,
            "selected_locks": SELECTED_LOCKS,
            "atlas": {**file_record(ATLAS_PATH), **atlas_audit},
            "atlas_16x": file_record(ATLAS_16X_PATH),
            **review,
            **determinism_contract,
            "stability": {"path": rel(STABILITY_PATH), "sha256": stability_sha256, "passes": 2, "drift_count": 0},
            "output_allowlist": [rel(path) for path in ALLOWLIST],
            **({"final_human_approval": approval_source} if approval_source is not None else {}),
        }

    report_first = make_report(review_first)
    report_second = make_report(review_second)
    if json_text(report_first) != json_text(report_second):
        raise AssertionError("Final report full payload drifted")
    report_sha256 = hashlib.sha256(json_text(report_first).encode("utf-8")).hexdigest()

    def make_manifest(output_records: dict[str, object]) -> dict[str, object]:
        return {
            "schema_version": 1,
            "asset": "cardboard_monster_final_candidate",
            "stage": stage,
            "preview_only": True,
            "approved_animation_selection": APPROVED_SELECTION,
            "first_human_approved": True,
            "second_human_approved": True,
            "third_human_approved": final_human_approved,
            "final_human_approved": final_human_approved,
            "runtime_written": False,
            "runtime_paths_written": [],
            "imagegen_pixels_imported": False,
            "builder": {"path": rel(SCRIPT), "sha256": sha256(SCRIPT)},
            "report": {"path": rel(REPORT_PATH), "sha256": report_sha256},
            "stability": {"path": rel(STABILITY_PATH), "sha256": stability_sha256},
            "source_atlas": {**file_record(ATLAS_PATH), "rgba_sha256": rgba_sha(atlas_first)},
            "selected_locks": SELECTED_LOCKS,
            "outputs": output_records,
            **determinism_contract,
            "output_allowlist": [rel(path) for path in ALLOWLIST],
            **({"final_human_approval": approval_source} if approval_source is not None else {}),
        }

    manifest_first = make_manifest(output_records_first)
    manifest_second = make_manifest(output_records_second)
    if json_text(manifest_first) != json_text(manifest_second):
        raise AssertionError("Final manifest full payload drifted")

    write_json(STABILITY_PATH, stability)
    write_json(REPORT_PATH, report_first)
    write_json(MANIFEST_PATH, manifest_first)
    if sha256(STABILITY_PATH) != stability_sha256 or sha256(REPORT_PATH) != report_sha256:
        raise AssertionError("Certificate bytes differ from prewrite determinism proof")
    print("CARDBOARD_MONSTER_FINAL_PREVIEW_OK")
    print(f"atlas={rel(ATLAS_PATH)} file_sha256={sha256(ATLAS_PATH)} rgba_sha256={rgba_sha(atlas_first)}")
    print(f"report={rel(REPORT_PATH)} sha256={sha256(REPORT_PATH)}")
    print(f"manifest={rel(MANIFEST_PATH)} sha256={sha256(MANIFEST_PATH)}")
    print(f"stability={rel(STABILITY_PATH)} sha256={sha256(STABILITY_PATH)}")


if __name__ == "__main__":
    main()
