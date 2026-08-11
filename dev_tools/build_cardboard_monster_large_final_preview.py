#!/usr/bin/env python3
"""Build the preview-only third-gate candidate for the large cardboard monster.

The builder consumes the frozen M1/A1/D2 second-gate certificate.  It only
writes review artifacts under dev_assets and ignored certificates under
dev_tools/output; runtime resources are deliberately outside its allowlist.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageSequence

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
DEV_ASSETS = ROOT / "dev_assets"
SOURCE_DIR = DEV_ASSETS / "source_images/cardboard_monster_large"
PREVIEW_DIR = DEV_ASSETS / "generated_previews"

APPROVED_BUILDER = ROOT / "dev_tools/build_cardboard_monster_large_animation_previews.py"
APPROVED_REPORT = enemy_asset_report_path("cardboard_monster_large_animation_preview_report.json")
APPROVED_MANIFEST = enemy_asset_report_path("cardboard_monster_large_animation_manifest.json")
APPROVED_STABILITY = enemy_asset_report_path("cardboard_monster_large_animation_stability.json")
APPROVED_ANCHOR = SOURCE_DIR / "cardboard_monster_large_anchor_approved_native48.png"
NORMAL_CARDBOARD_ATLAS = ROOT / "resources/texture/enemy/artificial_creation/cardboard_monster.png"
CAPOO_SWORDSMAN_ATLAS = ROOT / "resources/texture/enemy/capoo/capoo_swordsman.png"
STONE_GOLEM_ATLAS = ROOT / "resources/texture/enemy/artificial_creation/stone_golem.png"

APPROVED_SELECTION = {"move": "m1", "attack": "a1", "death": "d2"}
INPUT_LOCKS = {
    APPROVED_BUILDER: "2826a28ed8d75b3c3de1b195df273a912fa28c0708777802818aa2fe5cd719cd",
    APPROVED_REPORT: "e1518560f1eceeb38fe2d7838fc12d30fdc684486dbf812126d448828d90e6c1",
    APPROVED_MANIFEST: "786ee4a2cfc9f298904a3e396a6ebb561169c1e0acbc728f272758ffed7785e3",
    APPROVED_STABILITY: "2c9d1762364fb9a0be77e27233ab7d7e019e9f52c1434a023320b8e7dd6bea05",
    APPROVED_ANCHOR: "9e4422e1090ea35e97824b694a11335ef600e26d9b6a6a8a135af52e7e255529",
    NORMAL_CARDBOARD_ATLAS: "73bad923829c873b83c808954d610735826884e2786a5fb1da21a04240578f2c",
    CAPOO_SWORDSMAN_ATLAS: "ed4b098b73e8ed5678e13b7c507a899679e949e210a21f00a25fd60a7d516d00",
    STONE_GOLEM_ATLAS: "18450c64715320adaa937ac52f09b97497127e22645346b1ad9d6c8a90623111",
}
SELECTED_PATHS = {
    "m1": SOURCE_DIR / "cardboard_monster_large_move_m1_candidate_native.png",
    "a1": SOURCE_DIR / "cardboard_monster_large_attack_a1_candidate_native.png",
    "d2": SOURCE_DIR / "cardboard_monster_large_death_d2_candidate_native.png",
}
SELECTED_LOCKS = {
    "m1": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_move_m1_candidate_native.png",
        "sha256": "1509a178104e40422ca4b53b00d89a97bee2fbfbf01138a304ce9e835042f03d",
        "rgba_sha256": "f765ca2aa317d789cb90c2251ace81f3f9d36ef1fffa91ef068760445b7ebbdc",
    },
    "a1": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_attack_a1_candidate_native.png",
        "sha256": "b2d2514bd632eb19fd260855dd4dec3278ed977e56fa8bcfa5892f486690fd88",
        "rgba_sha256": "ca101c63d033bc28aa81c927ef63390ed8ebc7dd6d9fdf95f3c0293c5352ef7e",
    },
    "d2": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_death_d2_candidate_native.png",
        "sha256": "de4e3c39746b8743a21b99cd091102ab75fffc8188f9ecc029c896e1a728e4f1",
        "rgba_sha256": "1973382d0e5ad008d1ec2975e0faf1f53c084978a4fff2c7c3cd358f8b6bb8e9",
    },
}

FRAME = 48
COUNT = 8
ATLAS_SIZE = (384, 144)
EXPECTED_ATLAS_RGBA_SHA256 = "c15ce57637c39800d78024404d1a9a093fd9b48194f17fa1b65b9d451f561999"
PENDING_STAGE = "final_candidate_pending_third_human_gate"
APPROVED_STAGE = "final_candidate_third_human_gate_approved"
PENDING_FINAL_CERTIFICATE = {
    "builder_sha256": "e5a79b625d94e2375ccd346a01f24276fbdd7d8b7b9335125e477cc894d73641",
    "report_sha256": "7d55e4003093d68f60a572c95a6cf57f0ce5bad329d1b5a14e0ed59a145a12de",
    "manifest_sha256": "7dbac959d06cc24178f3d7a32126da7429c1506eae4f0b7e88c3bc7ad0c58c3c",
    "stability_sha256": "6139a44e337b8c50eabac99b0e0b4ee9bbf186fa416358a0a514e2c1c4dfa337",
    "atlas_sha256": "0c883183710140c2923877447db46f14c19c19ce61b7c92f388e3574f2f161e6",
    "atlas_rgba_sha256": EXPECTED_ATLAS_RGBA_SHA256,
}
TRANSPARENT = (0, 0, 0, 0)
BACKGROUND = (14, 20, 29, 255)
PALETTE = frozenset(
    (
        TRANSPARENT,
        (116, 87, 61, 255),
        (88, 64, 45, 255),
        (123, 87, 55, 255),
        (177, 145, 102, 255),
        (210, 181, 137, 255),
        (232, 213, 177, 255),
        (245, 234, 208, 255),
        (154, 117, 78, 255),
        (225, 202, 159, 255),
        (79, 67, 59, 255),
    )
)

ANIMATION_SPECS = {
    "move": {"cells": [(0, index) for index in range(8)], "fps": 9, "durations": [110] * 8, "loop": True},
    "windup": {"cells": [(1, index) for index in range(3)], "fps": 9, "durations": [110] * 3, "loop": False},
    "slash": {"cells": [(1, index) for index in range(3, 8)], "fps": 15, "durations": [70] * 5, "loop": False},
    "death": {"cells": [(2, index) for index in range(8)], "fps": 8, "durations": [120] * 8, "loop": False},
}

ATLAS_PATH = SOURCE_DIR / "cardboard_monster_large_final_candidate_atlas.png"
ATLAS_PREVIEW_PATH = PREVIEW_DIR / "cardboard_monster_large_final_candidate_atlas_8x.png"
DELTA_PATH = PREVIEW_DIR / "cardboard_monster_large_final_candidate_anchor_delta_6x.png"
SIZE_COMPARISON_PATH = PREVIEW_DIR / "cardboard_monster_large_final_candidate_size_comparison.png"
COLLISION_PATHS = {
    facing: PREVIEW_DIR / f"cardboard_monster_large_final_candidate_collision_fan_{facing}.png"
    for facing in ("right", "left")
}
CHAIN_PATHS = {
    facing: PREVIEW_DIR / f"cardboard_monster_large_final_candidate_tracking_windup_lock_behind_{facing}.gif"
    for facing in ("right", "left")
}
ANIMATION_PATHS = {
    (name, facing): PREVIEW_DIR / f"cardboard_monster_large_final_candidate_{name}_{facing}.gif"
    for name in ANIMATION_SPECS
    for facing in ("right", "left")
}
REPORT_PATH = enemy_asset_report_path("cardboard_monster_large_final_candidate_report.json")
MANIFEST_PATH = enemy_asset_report_path("cardboard_monster_large_final_candidate_manifest.json")
STABILITY_PATH = enemy_asset_report_path("cardboard_monster_large_final_candidate_stability.json")

VISUAL_OUTPUTS = [
    ATLAS_PATH,
    ATLAS_PREVIEW_PATH,
    *[ANIMATION_PATHS[(name, facing)] for name in ANIMATION_SPECS for facing in ("right", "left")],
    CHAIN_PATHS["right"],
    CHAIN_PATHS["left"],
    COLLISION_PATHS["right"],
    COLLISION_PATHS["left"],
    SIZE_COMPARISON_PATH,
    DELTA_PATH,
]
CERTIFICATE_OUTPUTS = [REPORT_PATH, MANIFEST_PATH, STABILITY_PATH]
ALLOWLIST = VISUAL_OUTPUTS + CERTIFICATE_OUTPUTS


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def json_text(payload: object) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def ensure_output(path: Path) -> None:
    if path not in ALLOWLIST:
        raise AssertionError(f"Output is not in the final-candidate allowlist: {path}")
    resolved = path.resolve()
    dev_root = DEV_ASSETS.resolve()
    if resolved != dev_root and dev_root in resolved.parents:
        return
    if is_enemy_asset_report_path(path):
        return
    raise AssertionError(f"Refused output outside dev_assets/dev_tools output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def write_json(path: Path, payload: object) -> None:
    ensure_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json_text(payload), encoding="utf-8", newline="\n")


def file_record(path: Path) -> dict[str, object]:
    result: dict[str, object] = {"path": rel(path), "sha256": sha256(path)}
    if path.suffix.lower() in (".png", ".gif"):
        with Image.open(path) as opened:
            result.update({"size": list(opened.size), "mode": opened.mode})
            if path.suffix.lower() == ".gif":
                result["frames"] = opened.n_frames
    return result


def approval_source() -> dict[str, object]:
    return {
        **PENDING_FINAL_CERTIFICATE,
        "decision": "approved",
        "approved_anchor": "l1",
        "approved_animation_selection": APPROVED_SELECTION,
        "damage_frame_source_cell": {"row": 1, "column": 4},
        "runtime_written": False,
    }


def resolve_final_approval(requested: bool) -> tuple[bool, dict[str, object]]:
    if not all(path.is_file() for path in CERTIFICATE_OUTPUTS):
        raise AssertionError("Final candidate certificate chain is incomplete")
    payloads = {
        "report": json.loads(REPORT_PATH.read_text(encoding="utf-8")),
        "manifest": json.loads(MANIFEST_PATH.read_text(encoding="utf-8")),
        "stability": json.loads(STABILITY_PATH.read_text(encoding="utf-8")),
    }
    stages = {payload.get("stage") for payload in payloads.values()}
    expected_source = approval_source()
    if stages == {APPROVED_STAGE}:
        for label, payload in payloads.items():
            if (
                payload.get("third_human_approved") is not True
                or payload.get("final_human_approved") is not True
                or payload.get("runtime_written") is not False
                or payload.get("runtime_paths_written") != []
                or payload.get("final_human_approval") != expected_source
            ):
                raise AssertionError(f"Persisted approved {label} certificate drifted")
        return True, expected_source
    if stages != {PENDING_STAGE}:
        raise AssertionError(f"Mixed or unknown final-candidate stages: {stages}")
    if not requested:
        raise AssertionError(
            "Pending third gate is frozen; rerun with explicit --approve"
        )
    locked_paths = {
        "report_sha256": REPORT_PATH,
        "manifest_sha256": MANIFEST_PATH,
        "stability_sha256": STABILITY_PATH,
        "atlas_sha256": ATLAS_PATH,
    }
    for key, path in locked_paths.items():
        actual = sha256(path)
        if actual != PENDING_FINAL_CERTIFICATE[key]:
            raise AssertionError(
                f"Pending third-gate lock drifted: {key} "
                f"expected={PENDING_FINAL_CERTIFICATE[key]} actual={actual}"
            )
    with Image.open(ATLAS_PATH) as opened:
        if rgba_sha(opened.convert("RGBA")) != PENDING_FINAL_CERTIFICATE["atlas_rgba_sha256"]:
            raise AssertionError("Pending third-gate atlas RGBA drifted")
    for label, payload in payloads.items():
        builder_sha = (
            payload.get("builder_sha256")
            if label == "stability"
            else payload.get("builder", {}).get("sha256")
        )
        if builder_sha != PENDING_FINAL_CERTIFICATE["builder_sha256"]:
            raise AssertionError(f"Pending {label} builder lock drifted")
        if (
            payload.get("approved_animation_selection") != APPROVED_SELECTION
            or payload.get("third_human_approved") is not False
            or payload.get("final_human_approved") is not False
            or payload.get("runtime_written") is not False
            or payload.get("runtime_paths_written") != []
        ):
            raise AssertionError(f"Pending {label} approval flags drifted")
    if payloads["report"].get("gameplay_visual_contract", {}).get("damage_frame") != {
        "global_attack_index": 4,
        "slash_local_index": 1,
        "atlas_cell": [1, 4],
    }:
        raise AssertionError("Pending third-gate damage-frame contract drifted")
    return True, expected_source


def verify_inputs() -> tuple[dict[str, object], dict[str, object]]:
    input_records: dict[str, object] = {}
    for path, expected in INPUT_LOCKS.items():
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Locked input drifted: {rel(path)} expected={expected} actual={actual}")
        input_records[rel(path)] = {"sha256": actual, "locked": True}

    payloads = {
        "report": json.loads(APPROVED_REPORT.read_text(encoding="utf-8")),
        "manifest": json.loads(APPROVED_MANIFEST.read_text(encoding="utf-8")),
        "stability": json.loads(APPROVED_STABILITY.read_text(encoding="utf-8")),
    }
    for label, payload in payloads.items():
        expected = {
            "stage": "second_human_gate_approved",
            "approved_animation_selection": APPROVED_SELECTION,
            "second_human_approved": True,
            "final_human_approved": False,
            "runtime_written": False,
        }
        for key, value in expected.items():
            if payload.get(key) != value:
                raise AssertionError(f"Approved {label} {key} drifted")
        if payload.get("approved_selected_locks") != {
            "move": SELECTED_LOCKS["m1"],
            "attack": SELECTED_LOCKS["a1"],
            "death": SELECTED_LOCKS["d2"],
        }:
            raise AssertionError(f"Approved {label} selected locks drifted")

    for key, path in SELECTED_PATHS.items():
        lock = SELECTED_LOCKS[key]
        if rel(path) != lock["path"] or sha256(path) != lock["sha256"]:
            raise AssertionError(f"Selected {key} PNG drifted")
        with Image.open(path) as opened:
            strip = opened.convert("RGBA")
        if strip.size != (384, 48) or rgba_sha(strip) != lock["rgba_sha256"]:
            raise AssertionError(f"Selected {key} decoded strip drifted")
        input_records[rel(path)] = {**lock, "locked": True}
    return input_records, payloads["report"]


def load_strips() -> dict[str, Image.Image]:
    strips: dict[str, Image.Image] = {}
    for key, path in SELECTED_PATHS.items():
        with Image.open(path) as opened:
            strips[key] = opened.convert("RGBA")
    return strips


def build_atlas(strips: dict[str, Image.Image]) -> Image.Image:
    atlas = Image.new("RGBA", ATLAS_SIZE, TRANSPARENT)
    for row, key in enumerate(("m1", "a1", "d2")):
        atlas.alpha_composite(strips[key], (0, row * FRAME))
    actual = rgba_sha(atlas)
    if actual != EXPECTED_ATLAS_RGBA_SHA256:
        raise AssertionError(f"Final atlas decoded RGBA drifted: {actual}")
    return atlas


def frame_from(atlas: Image.Image, row: int, column: int) -> Image.Image:
    return atlas.crop((column * FRAME, row * FRAME, (column + 1) * FRAME, (row + 1) * FRAME))


def opaque_points(image: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3]
    }


def components_8(points: set[tuple[int, int]]) -> list[set[tuple[int, int]]]:
    pending_points = set(points)
    components: list[set[tuple[int, int]]] = []
    while pending_points:
        start = pending_points.pop()
        component = {start}
        queue = deque((start,))
        while queue:
            x, y = queue.popleft()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == dy == 0:
                        continue
                    neighbor = (x + dx, y + dy)
                    if neighbor in pending_points:
                        pending_points.remove(neighbor)
                        component.add(neighbor)
                        queue.append(neighbor)
        components.append(component)
    return components


def audit_atlas(
    atlas: Image.Image,
    strips: dict[str, Image.Image],
    approved_report: dict[str, object],
) -> dict[str, object]:
    if atlas.size != ATLAS_SIZE or atlas.mode != "RGBA":
        raise AssertionError("Final atlas geometry drifted")
    pixels = list(atlas.getdata())
    if not set(pixels) <= PALETTE:
        raise AssertionError("Final atlas palette drifted")
    if any(pixel[3] not in (0, 255) for pixel in pixels):
        raise AssertionError("Final atlas alpha is not binary")
    if any(pixel[:3] != (0, 0, 0) for pixel in pixels if pixel[3] == 0):
        raise AssertionError("Final atlas transparent RGB is not zero")

    rows: list[dict[str, object]] = []
    frames: list[dict[str, object]] = []
    for row, key in enumerate(("m1", "a1", "d2")):
        atlas_row = atlas.crop((0, row * FRAME, ATLAS_SIZE[0], (row + 1) * FRAME))
        if atlas_row.tobytes() != strips[key].tobytes():
            raise AssertionError(f"Final atlas row {row} differs from {key}")
        source_metrics = approved_report["candidates"][key]["frames"]
        rows.append(
            {
                "row": row,
                "source": key,
                "source_lock": SELECTED_LOCKS[key],
                "changed_pixels_source_vs_atlas": 0,
            }
        )
        for column in range(COUNT):
            frame = frame_from(atlas, row, column)
            bbox = frame.getbbox()
            if bbox is None or bbox[3] != 36:
                raise AssertionError(f"r{row}c{column} baseline drifted: {bbox}")
            if len(components_8(opaque_points(frame))) != 1:
                raise AssertionError(f"r{row}c{column} disconnected")
            metric = source_metrics[column]
            if rgba_sha(frame) != metric["rgba_sha256"] or list(bbox) != metric["bbox"]:
                raise AssertionError(f"r{row}c{column} differs from approved coordinate certificate")
            if metric.get("sword_in_front_for_right_facing") is not True:
                raise AssertionError(f"r{row}c{column} paper sword left the current-facing foreground")
            frames.append(
                {
                    "source_cell": {"row": row, "column": column},
                    "source_candidate": key,
                    "rgba_sha256": rgba_sha(frame),
                    "bbox": list(bbox),
                    "visible_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
                    "registered_center_x": 24,
                    "baseline_bottom_exclusive": 36,
                    "components_8": 1,
                    "paper_sword_in_current_facing_foreground": True,
                    "paper_sword_connected_to_hand": metric["sword_connected_to_hand"],
                    "paper_sword_endpoint_distance": metric["sword_endpoint_distance"],
                    "paper_sword_has_collision": False,
                }
            )
    return {
        "size": list(ATLAS_SIZE),
        "mode": "RGBA",
        "rgba_sha256": rgba_sha(atlas),
        "expected_rgba_sha256": EXPECTED_ATLAS_RGBA_SHA256,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
        "palette_rgba": [list(color) for color in sorted(PALETTE)],
        "rows": rows,
        "frames": frames,
    }


def composite_character(frame: Image.Image, facing: str, scale: int = 8) -> Image.Image:
    actor = ImageOps.mirror(frame) if facing == "left" else frame
    canvas = Image.new("RGBA", (FRAME, FRAME), BACKGROUND)
    canvas.alpha_composite(actor)
    return canvas.resize((FRAME * scale, FRAME * scale), Image.Resampling.NEAREST).convert("RGB")


def encode_exact_gif(
    frames: list[Image.Image], durations: list[int], loop: bool
) -> tuple[bytes, dict[str, object]]:
    rgb_frames = [frame.convert("RGB") for frame in frames]
    colors = sorted({pixel for frame in rgb_frames for pixel in frame.getdata()})
    if len(colors) > 256:
        raise AssertionError(f"GIF requires {len(colors)} colors")
    indices = {color: index for index, color in enumerate(colors)}
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * ((256 - len(colors)) * 3))
    paletted: list[Image.Image] = []
    for frame in rgb_frames:
        converted = Image.new("P", frame.size)
        converted.putpalette(palette)
        converted.putdata([indices[pixel] for pixel in frame.getdata()])
        paletted.append(converted)

    def encode() -> bytes:
        buffer = io.BytesIO()
        options: dict[str, object] = {
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

    first = encode()
    second = encode()
    if first != second:
        raise AssertionError("GIF double encoding drifted")
    with Image.open(io.BytesIO(first)) as opened:
        decoded = [frame.convert("RGB") for frame in ImageSequence.Iterator(opened)]
        decoded_durations = [frame.info.get("duration") for frame in ImageSequence.Iterator(opened)]
        decoded_loop = opened.info.get("loop")
    if len(decoded) != len(rgb_frames) or decoded_durations != durations:
        raise AssertionError("GIF frame count/timebase drifted")
    if any(actual.tobytes() != expected.tobytes() for actual, expected in zip(decoded, rgb_frames)):
        raise AssertionError("GIF decoded pixels differ from source")
    if (decoded_loop == 0) is not loop:
        raise AssertionError("GIF loop extension drifted")
    return first, {
        "frames": len(frames),
        "durations_ms": durations,
        "loop": loop,
        "unique_rgb_colors": len(colors),
        "decoded_matches_source_rgb": True,
        "deterministic_double_encode": True,
    }


def save_exact_gif(
    frames: list[Image.Image], path: Path, durations: list[int], loop: bool
) -> dict[str, object]:
    ensure_output(path)
    payload, audit = encode_exact_gif(frames, durations, loop)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return {**file_record(path), **audit}


def sector_vertices(
    origin: tuple[int, int], center_degrees: float, inner: int = 6,
    outer: int = 24, angle: int = 60, segments: int = 12,
) -> list[tuple[int, int]]:
    angles = [center_degrees - angle / 2 + index * angle / segments for index in range(segments + 1)]
    outer_points = [
        (
            round(origin[0] + math.cos(math.radians(value)) * outer),
            round(origin[1] + math.sin(math.radians(value)) * outer),
        )
        for value in angles
    ]
    inner_points = [
        (
            round(origin[0] + math.cos(math.radians(value)) * inner),
            round(origin[1] + math.sin(math.radians(value)) * inner),
        )
        for value in reversed(angles)
    ]
    return outer_points + inner_points


def draw_fan(canvas: Image.Image, origin: tuple[int, int], center_degrees: float) -> None:
    overlay = Image.new("RGBA", canvas.size, TRANSPARENT)
    draw = ImageDraw.Draw(overlay)
    draw.polygon(
        sector_vertices(origin, center_degrees),
        fill=(255, 177, 65, 54),
        outline=(255, 203, 92, 255),
    )
    canvas.alpha_composite(overlay)


def draw_target(canvas: Image.Image, point: tuple[int, int], locked: bool) -> None:
    color = (255, 102, 151, 255) if locked else (97, 226, 246, 255)
    draw = ImageDraw.Draw(canvas)
    x, y = point
    draw.ellipse((x - 4, y - 4, x + 4, y + 4), outline=color, width=1)
    draw.line((x - 2, y, x + 2, y), fill=(255, 255, 255, 255), width=1)
    draw.line((x, y - 2, x, y + 2), fill=(255, 255, 255, 255), width=1)


def normalize_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def angle_to(origin: tuple[int, int], target: tuple[int, int]) -> float:
    return math.degrees(math.atan2(target[1] - origin[1], target[0] - origin[0]))


def target_in_fan(
    origin: tuple[int, int], target: tuple[int, int], center_degrees: float
) -> tuple[bool, bool, float, float]:
    dx, dy = target[0] - origin[0], target[1] - origin[1]
    distance = math.hypot(dx, dy)
    delta = abs(normalize_degrees(math.degrees(math.atan2(dy, dx)) - center_degrees))
    radial = 6 <= distance <= 24
    return radial, radial and delta <= 30, distance, delta


def build_chain(
    atlas: Image.Image, facing: str
) -> tuple[list[Image.Image], list[int], list[dict[str, object]]]:
    source = [
        ("tracking", 0, 6, 110),
        ("tracking", 0, 7, 110),
        ("windup", 1, 0, 110),
        ("windup", 1, 1, 110),
        ("windup", 1, 2, 110),
        ("slash", 1, 3, 70),
        ("slash", 1, 4, 70),
        ("slash", 1, 5, 70),
        ("slash", 1, 6, 70),
        ("slash", 1, 7, 70),
    ]
    right_targets = [(79, 33), (77, 30), (76, 33), (79, 29), (78, 31), (78, 31), (46, 31), (36, 34), (26, 36), (16, 38)]
    canvas_size = (112, 72)
    actor_offset = (32, 12)
    origin = (56, 36)
    final_windup_angle = angle_to(origin, right_targets[4])
    frames: list[Image.Image] = []
    durations: list[int] = []
    timeline: list[dict[str, object]] = []
    windup_angles: list[float] = []
    slash_angles: list[float] = []
    native_right_frames: list[Image.Image] = []

    for preview_index, ((phase, row, column, duration), target) in enumerate(zip(source, right_targets)):
        direction = angle_to(origin, target) if phase != "slash" else final_windup_angle
        if phase == "windup":
            windup_angles.append(round(direction, 4))
        if phase == "slash":
            slash_angles.append(round(direction, 4))
        native = Image.new("RGBA", canvas_size, BACKGROUND)
        if phase in ("windup", "slash"):
            draw_fan(native, origin, direction)
        native.alpha_composite(frame_from(atlas, row, column), actor_offset)
        draw_target(native, target, phase == "slash")
        native_right_frames.append(native)

        radial, inside, distance, delta = target_in_fan(origin, target, direction)
        target_behind = target[0] < origin[0] if phase == "slash" else False
        display_target = target if facing == "right" else (canvas_size[0] - 1 - target[0], target[1])
        display_direction = direction if facing == "right" else normalize_degrees(180.0 - direction)
        timeline.append(
            {
                "preview_frame": preview_index,
                "phase": phase,
                "source_cell": {"row": row, "column": column},
                "duration_ms": duration,
                "facing": facing,
                "target_id": "review_target_A",
                "target_position": list(display_target),
                "host_direction_degrees": round(display_direction, 4),
                "committed_target_identity_fixed": True,
                "host_windup_direction_tracks_position": phase == "windup",
                "slash_direction_locked": phase == "slash",
                "proxy_windup_continuous_tracking": False,
                "radial_distance": round(distance, 4),
                "within_6_to_24_radial_band": radial,
                "angle_delta_from_active_direction": round(delta, 4),
                "inside_active_fan": inside,
                "target_is_behind_locked_direction": phase == "slash" and target_behind,
                "legal_miss_after_lock": phase == "slash" and target_behind and radial and not inside,
                "damage_frame": row == 1 and column == 4,
            }
        )

    if len(set(windup_angles)) != 3:
        raise AssertionError("Host windup direction did not track the moving committed target")
    if len(set(slash_angles)) != 1:
        raise AssertionError("Slash direction did not remain locked")
    damage_record = next(item for item in timeline if item["damage_frame"])
    if not damage_record["legal_miss_after_lock"]:
        raise AssertionError("Damage frame does not prove a legal behind-target miss")
    if facing == "left":
        native_frames = [ImageOps.mirror(frame) for frame in native_right_frames]
    else:
        native_frames = native_right_frames
    for native, (_phase, _row, _column, duration) in zip(native_frames, source):
        frames.append(native.resize((896, 576), Image.Resampling.NEAREST).convert("RGB"))
        durations.append(duration)
    return frames, durations, timeline


def build_collision_overlay(frame: Image.Image, facing: str) -> tuple[Image.Image, dict[str, object]]:
    canvas = Image.new("RGBA", (96, 72), BACKGROUND)
    actor = ImageOps.mirror(frame) if facing == "left" else frame
    actor_offset = (24, 12)
    world_origin = (48, 36)
    direction = 0.0 if facing == "right" else 180.0
    draw_fan(canvas, world_origin, direction)
    canvas.alpha_composite(actor, actor_offset)
    draw = ImageDraw.Draw(canvas)
    body_center = (world_origin[0], world_origin[1] - 1)
    body_half_open = [body_center[0] - 10, body_center[1] - 9, body_center[0] + 10, body_center[1] + 9]
    draw.rectangle(tuple(body_half_open), outline=(76, 231, 241, 255), width=1)
    draw.point(world_origin, fill=(255, 255, 255, 255))
    vertices = sector_vertices(world_origin, direction)
    return canvas.resize((768, 576), Image.Resampling.NEAREST), {
        "facing": facing,
        "frame_center_world_origin_on_canvas": list(world_origin),
        "body_center_on_canvas": list(body_center),
        "body_half_open_pixel_box_on_canvas": body_half_open,
        "body_half_open_pixel_box_in_frame": [14, 14, 34, 32],
        "fan_vertices_native": [list(point) for point in vertices],
    }


def registered_sample(
    image: Image.Image,
    sample_id: str,
    label: str,
    source: Path,
    source_cell: list[int],
    source_crop: list[int],
    source_scale: float,
) -> tuple[Image.Image, dict[str, object]]:
    bbox = image.getbbox()
    if bbox is None:
        raise AssertionError(f"Comparison sample is empty: {sample_id}")
    registered = Image.new("RGBA", (72, 72), TRANSPARENT)
    offset = (36 - image.width // 2, 60 - bbox[3])
    registered.alpha_composite(image, offset)
    registered_bbox = registered.getbbox()
    if registered_bbox is None or registered_bbox[3] != 60:
        raise AssertionError(f"Comparison baseline drifted: {sample_id}")
    opaque = sum(pixel[3] != 0 for pixel in image.getdata())
    return registered, {
        "id": sample_id,
        "label": label,
        "source_path": rel(source),
        "source_cell": source_cell,
        "source_crop": source_crop,
        "source_scale": source_scale,
        "source_frame_size": list(image.size),
        "source_rgba_sha256": rgba_sha(image),
        "registration_offset": list(offset),
        "registered_bbox": list(registered_bbox),
        "visible_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        "opaque_pixels": opaque,
        "shared_baseline_bottom_exclusive": 60,
    }


def build_size_comparison(atlas: Image.Image) -> tuple[Image.Image, dict[str, object]]:
    with Image.open(NORMAL_CARDBOARD_ATLAS) as opened:
        normal = opened.convert("RGBA").crop((0, 0, 32, 32))
    with Image.open(CAPOO_SWORDSMAN_ATLAS) as opened:
        capoo = opened.convert("RGBA").crop((0, 0, 96, 96)).resize(
            (30, 30), Image.Resampling.NEAREST
        )
    with Image.open(STONE_GOLEM_ATLAS) as opened:
        stone = opened.convert("RGBA").crop((0, 0, 64, 64))
    large = frame_from(atlas, 0, 0)
    expected_rgba = {
        "normal_cardboard": "df9d86e7cc661bdd566e6d067a061863581aab59fa72524025d713159be8aa8d",
        "capoo_swordsman_x031": "b43f86ea66a1426d25f105f9984373abf58df443d84ab89fbd37f2c7fcb88df5",
        "stone_golem": "2e81e2aec1f23c00280b89041e22e11830167e80128d5cf63e2581eee9865e23",
        "large_cardboard": "10591c058dfd3461973c1399e082af43fdbc1a29697cb282cbba3dcaf6cc9c3a",
    }
    if (
        rgba_sha(normal) != expected_rgba["normal_cardboard"]
        or rgba_sha(capoo) != expected_rgba["capoo_swordsman_x031"]
        or rgba_sha(stone) != expected_rgba["stone_golem"]
        or rgba_sha(large) != expected_rgba["large_cardboard"]
    ):
        raise AssertionError("Size-comparison frame lock drifted")
    sources = (
        (normal, "normal_cardboard", "NORMAL CARDBOARD", NORMAL_CARDBOARD_ATLAS, [0, 0], [0, 0, 32, 32], 1.0),
        (large, "large_cardboard", "LARGE CARDBOARD", ATLAS_PATH, [0, 0], [0, 0, 48, 48], 1.0),
        (capoo, "capoo_swordsman_x031", "CAPOO x0.31", CAPOO_SWORDSMAN_ATLAS, [0, 0], [0, 0, 96, 96], 0.3125),
        (stone, "stone_golem", "STONE GOLEM", STONE_GOLEM_ATLAS, [0, 0], [0, 0, 64, 64], 1.0),
    )
    samples: list[tuple[Image.Image, dict[str, object]]] = [
        registered_sample(*source) for source in sources
    ]
    metrics = {record["id"]: record for _image, record in samples}
    normal_metric, large_metric, stone_metric = (
        metrics["normal_cardboard"], metrics["large_cardboard"], metrics["stone_golem"]
    )
    if not (
        normal_metric["visible_size"][1] < large_metric["visible_size"][1] < stone_metric["visible_size"][1]
        and normal_metric["opaque_pixels"] < large_metric["opaque_pixels"] < stone_metric["opaque_pixels"]
    ):
        raise AssertionError("Large-cardboard visual scale is not between normal cardboard and stone golem")

    slot_width = 112
    native = Image.new("RGBA", (slot_width * len(samples), 92), BACKGROUND)
    draw = ImageDraw.Draw(native)
    font = ImageFont.load_default()
    for index, (sample, record) in enumerate(samples):
        slot_x = index * slot_width
        x = slot_x + (slot_width - 72) // 2
        native.alpha_composite(sample, (x, 4))
        draw.line((x + 36, 4, x + 36, 76), fill=(76, 131, 148, 255), width=1)
        draw.line((x, 64, x + 71, 64), fill=(255, 193, 74, 255), width=1)
        label_bbox = draw.textbbox((0, 0), record["label"], font=font)
        label_width = label_bbox[2] - label_bbox[0]
        draw.text(
            (slot_x + (slot_width - label_width) // 2, 79),
            record["label"],
            font=font,
            fill=(238, 238, 232, 255),
        )
    return native.resize((native.width * 6, native.height * 6), Image.Resampling.NEAREST), {
        "samples": [record for _image, record in samples],
        "native_scale_preserved": True,
        "preview_scale": 6,
        "large_taller_and_more_opaque_than_normal": True,
        "large_shorter_and_less_opaque_than_stone_golem": True,
        "large_width_includes_forward_paper_sword": True,
        "capoo_gate1_world_scale_display": 0.31,
        "capoo_source_scale_exact": 0.3125,
        "capoo_resampling": "NEAREST",
        "capoo_gate1_extraction_contract_reused": True,
        "all_samples_share_center_and_baseline_registration": True,
        "reasonable_relative_size": True,
    }


def build_anchor_delta(atlas: Image.Image, anchor: Image.Image) -> tuple[Image.Image, list[dict[str, object]]]:
    delta = Image.new("RGBA", ATLAS_SIZE, TRANSPARENT)
    records: list[dict[str, object]] = []
    for row in range(3):
        for column in range(COUNT):
            frame = frame_from(atlas, row, column)
            changed = 0
            removed = 0
            for y in range(FRAME):
                for x in range(FRAME):
                    current = frame.getpixel((x, y))
                    base = anchor.getpixel((x, y))
                    if current == base:
                        continue
                    changed += 1
                    output = current
                    if current[3] == 0 and base[3] != 0:
                        removed += 1
                        output = (238, 92, 139, 255)
                    delta.putpixel((column * FRAME + x, row * FRAME + y), output)
            records.append(
                {
                    "source_cell": {"row": row, "column": column},
                    "changed_pixels_vs_approved_anchor": changed,
                    "removed_pixels_marked_pink": removed,
                }
            )
    return delta.resize((ATLAS_SIZE[0] * 6, ATLAS_SIZE[1] * 6), Image.Resampling.NEAREST), records


def render_outputs(atlas: Image.Image, anchor: Image.Image) -> tuple[dict[str, object], dict[str, str]]:
    save_png(atlas, ATLAS_PATH)
    save_png(atlas.resize((ATLAS_SIZE[0] * 8, ATLAS_SIZE[1] * 8), Image.Resampling.NEAREST), ATLAS_PREVIEW_PATH)
    animations: dict[str, object] = {}
    for name, spec in ANIMATION_SPECS.items():
        source_frames = [frame_from(atlas, row, column) for row, column in spec["cells"]]
        facing_records: dict[str, object] = {}
        facing_frames: dict[str, list[Image.Image]] = {}
        for facing in ("right", "left"):
            frames = [composite_character(frame, facing) for frame in source_frames]
            facing_frames[facing] = frames
            facing_records[facing] = save_exact_gif(
                frames, ANIMATION_PATHS[(name, facing)], list(spec["durations"]), bool(spec["loop"])
            )
        if any(
            ImageOps.mirror(right).tobytes() != left.tobytes()
            for right, left in zip(facing_frames["right"], facing_frames["left"])
        ):
            raise AssertionError(f"{name} left-facing review is not an exact horizontal mirror")
        record: dict[str, object] = {
            "source_cells": [{"row": row, "column": column} for row, column in spec["cells"]],
            "frame_count": len(source_frames),
            "fps": spec["fps"],
            "durations_ms": spec["durations"],
            "loop": spec["loop"],
            "facings": facing_records,
            "left_exact_horizontal_mirror_of_right": True,
        }
        if name == "slash":
            record.update(
                {
                    "damage_frame_local_index": 1,
                    "damage_frame_global_attack_index": 4,
                    "damage_frame_source_cell": {"row": 1, "column": 4},
                    "damage_delay_seconds": 1 / 15,
                }
            )
        animations[name] = record

    chains: dict[str, object] = {}
    chain_frames: dict[str, list[Image.Image]] = {}
    for facing in ("right", "left"):
        frames, durations, timeline = build_chain(atlas, facing)
        chain_frames[facing] = frames
        chains[facing] = {
            "gif": save_exact_gif(frames, CHAIN_PATHS[facing], durations, True),
            "timeline": timeline,
            "committed_target_identity_fixed": True,
            "host_windup_direction_tracks_position": True,
            "slash_direction_locked": True,
            "proxy_windup_continuous_tracking": False,
            "damage_frame_behind_target_legal_miss": True,
            "strict_vertical_direction_retains_existing_left_or_right_facing": True,
        }
    if any(
        ImageOps.mirror(right).tobytes() != left.tobytes()
        for right, left in zip(chain_frames["right"], chain_frames["left"])
    ):
        raise AssertionError("Left tracking chain is not an exact horizontal mirror of right")
    chains["right"]["opposite_facing_chain_exact_horizontal_mirror"] = True
    chains["left"]["opposite_facing_chain_exact_horizontal_mirror"] = True

    collision_records: dict[str, object] = {}
    damage_frame = frame_from(atlas, 1, 4)
    for facing in ("right", "left"):
        overlay, geometry = build_collision_overlay(damage_frame, facing)
        save_png(overlay, COLLISION_PATHS[facing])
        collision_records[facing] = {**file_record(COLLISION_PATHS[facing]), **geometry}
    comparison, comparison_contract = build_size_comparison(atlas)
    save_png(comparison, SIZE_COMPARISON_PATH)
    delta, delta_cells = build_anchor_delta(atlas, anchor)
    save_png(delta, DELTA_PATH)

    review = {
        "animations": animations,
        "tracking_windup_lock_behind": chains,
        "collision_fan": {
            "source_cell": {"row": 1, "column": 4},
            "body_collision": {"shape": "RectangleShape2D", "size": [20, 18], "world_position": [0, -1]},
            "touch_damage_collision": {"shape": "RectangleShape2D", "size": [20, 18], "world_position": [0, -1]},
            "frame_space_mapping": {
                "frame_center": [24, 24],
                "body_center": [24, 23],
                "body_half_open_pixel_box": [14, 14, 34, 32],
            },
            "fan": {
                "inner_radius": 6,
                "outer_radius": 24,
                "angle_degrees": 60,
                "half_angle_degrees": 30,
                "segments": 12,
                "angular_step_degrees": 5,
                "arc_vertex_count": 13,
            },
            "paper_sword_is_visual_only": True,
            "paper_sword_has_body_collision": False,
            "paper_sword_has_touch_damage_collision": False,
            "paper_sword_has_world_collision": False,
            "facings": collision_records,
        },
        "size_comparison": {**file_record(SIZE_COMPARISON_PATH), **comparison_contract},
        "approved_anchor_delta": {"file": file_record(DELTA_PATH), "cells": delta_cells},
    }
    return review, {rel(path): sha256(path) for path in VISUAL_OUTPUTS}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        action="store_true",
        help="Record the confirmed third/final human gate without writing runtime assets.",
    )
    args = parser.parse_args()
    final_human_approved, final_approval = resolve_final_approval(args.approve)
    stage = APPROVED_STAGE if final_human_approved else PENDING_STAGE
    if len(VISUAL_OUTPUTS) != 16 or len(ALLOWLIST) != 19 or len(set(ALLOWLIST)) != 19:
        raise AssertionError("Final-candidate output allowlist drifted")
    inputs, approved_report = verify_inputs()
    strips = load_strips()
    first_atlas = build_atlas(strips)
    second_atlas = build_atlas(strips)
    if first_atlas.tobytes() != second_atlas.tobytes():
        raise AssertionError("In-memory atlas assembly drifted")
    atlas_audit = audit_atlas(first_atlas, strips, approved_report)
    with Image.open(APPROVED_ANCHOR) as opened:
        anchor = opened.convert("RGBA")

    first_review, first_snapshot = render_outputs(first_atlas, anchor)
    first_records = {rel(path): file_record(path) for path in VISUAL_OUTPUTS}
    second_review, second_snapshot = render_outputs(second_atlas, anchor)
    second_records = {rel(path): file_record(path) for path in VISUAL_OUTPUTS}
    if first_snapshot != second_snapshot or first_records != second_records:
        changed = sorted(
            key for key in set(first_snapshot) | set(second_snapshot)
            if first_snapshot.get(key) != second_snapshot.get(key)
        )
        raise AssertionError(f"Two-pass final preview drifted: {changed}")
    if json.dumps(first_review, sort_keys=True) != json.dumps(second_review, sort_keys=True):
        raise AssertionError("Two-pass final review record drifted")

    builder_record = {"path": rel(SCRIPT), "sha256": sha256(SCRIPT)}
    common = {
        "schema_version": 1,
        "asset": "cardboard_monster_large_final_candidate",
        "stage": stage,
        "preview_only": True,
        "approved_anchor": "l1",
        "approved_animation_selection": APPROVED_SELECTION,
        "first_human_approved": True,
        "second_human_approved": True,
        "third_human_approved": final_human_approved,
        "final_human_approved": final_human_approved,
        "runtime_written": False,
        "runtime_paths_written": [],
        "p1c_written": False,
        "protocol_written": False,
        "imagegen_pixels_imported": False,
        "builder": builder_record,
        "second_gate_certificate": {
            "builder_sha256": INPUT_LOCKS[APPROVED_BUILDER],
            "report_sha256": INPUT_LOCKS[APPROVED_REPORT],
            "manifest_sha256": INPUT_LOCKS[APPROVED_MANIFEST],
            "stability_sha256": INPUT_LOCKS[APPROVED_STABILITY],
            "coordinate_table_sha256": approved_report["coordinate_table_sha256"],
        },
        "selected_locks": SELECTED_LOCKS,
        "output_allowlist": [rel(path) for path in ALLOWLIST],
        "final_human_approval": final_approval,
    }
    stability = {
        **common,
        "builder_sha256": builder_record["sha256"],
        "passes": 2,
        "drift_count": 0,
        "drift_paths": [],
        "snapshot_scope_count": len(VISUAL_OUTPUTS),
        "snapshot_exclusions": [rel(path) for path in CERTIFICATE_OUTPUTS],
        "snapshot_1": first_snapshot,
        "snapshot_2": second_snapshot,
    }
    stability_sha = hashlib.sha256(json_text(stability).encode("utf-8")).hexdigest()
    report = {
        **common,
        "inputs": inputs,
        "atlas": {**file_record(ATLAS_PATH), **atlas_audit},
        "atlas_preview": file_record(ATLAS_PREVIEW_PATH),
        **first_review,
        "gameplay_visual_contract": {
            "health": 15,
            "attack": 40,
            "move_speed": 22,
            "body_and_touch_shape": {"size": [20, 18], "world_position": [0, -1]},
            "slash": {"inner_radius": 6, "outer_radius": 24, "angle_degrees": 60, "segments": 12},
            "windup_seconds": 1 / 3,
            "slash_seconds": 1 / 3,
            "damage_delay_seconds": 1 / 15,
            "damage_frame": {"global_attack_index": 4, "slash_local_index": 1, "atlas_cell": [1, 4]},
            "paper_sword_visual_only": True,
            "committed_target_identity_fixed": True,
            "host_windup_direction_tracks_position": True,
            "slash_direction_locked": True,
            "proxy_windup_continuous_tracking": False,
        },
        "determinism": {"passes": 2, "drift_count": 0, "snapshot_scope_count": len(VISUAL_OUTPUTS)},
        "stability": {"path": rel(STABILITY_PATH), "sha256": stability_sha},
    }
    report_sha = hashlib.sha256(json_text(report).encode("utf-8")).hexdigest()
    manifest = {
        **common,
        "report": {"path": rel(REPORT_PATH), "sha256": report_sha},
        "stability": {"path": rel(STABILITY_PATH), "sha256": stability_sha},
        "source_atlas": {**file_record(ATLAS_PATH), "rgba_sha256": rgba_sha(first_atlas)},
        "outputs": first_records,
        "passes": 2,
        "drift_count": 0,
    }
    write_json(STABILITY_PATH, stability)
    write_json(REPORT_PATH, report)
    write_json(MANIFEST_PATH, manifest)
    if sha256(STABILITY_PATH) != stability_sha or sha256(REPORT_PATH) != report_sha:
        raise AssertionError("Final certificate bytes differ from their prewrite locks")

    print("CARDBOARD_MONSTER_LARGE_FINAL_PREVIEW_OK")
    print(f"atlas={rel(ATLAS_PATH)} file_sha256={sha256(ATLAS_PATH)} rgba_sha256={rgba_sha(first_atlas)}")
    print(f"report={rel(REPORT_PATH)} sha256={sha256(REPORT_PATH)}")
    print(f"manifest={rel(MANIFEST_PATH)} sha256={sha256(MANIFEST_PATH)}")
    print(f"stability={rel(STABILITY_PATH)} sha256={sha256(STABILITY_PATH)}")


if __name__ == "__main__":
    main()
