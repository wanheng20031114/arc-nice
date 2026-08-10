#!/usr/bin/env python3
"""Build second-gate previews for the elite combat-robot gunner.

The user-approved G1 anchor is the immutable identity contract.  Eight
independent ImageGen outputs are required, but they are display-only design
references.  Native candidate pixels are derived exclusively from the ordinary
runtime gunner/bullet sheets, the fixed elite-purple mapping, and deterministic
G1 attachment transforms.

This builder is intentionally preview-only: every output is below
``dev_assets`` and there is no runtime-write option.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
import process_combat_robot_gunner_elite_anchors as anchor_pipeline


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
SOURCE_DIR = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_gunner_elite"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
ORDINARY_SHEET_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_gunner.png"
)
ORDINARY_BULLET_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_gunner_bullet.png"
)
ANCHOR_MANIFEST_PATH = enemy_asset_report_path("combat_robot_gunner_elite_anchor_prompt_manifest.json")
ANCHOR_REPORT_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_anchor_report.json")
)
APPROVED_ANCHOR_PATH = (
    SOURCE_DIR
    / "combat_robot_gunner_elite_anchor_g1_approved_native32.png"
)

EXPECTED_APPROVED_ANCHOR_SHA256 = (
    "f5ef499bad24267d1f06d84c3bedf1b1b590a409bf019736cbb0320c6e9f4cf5"
)
EXPECTED_APPROVED_ANCHOR_RGBA_SHA256 = (
    "0361a5df2ce2655fcb05250199723582b445e7b0ee446ea8eabc6b744cd54b3f"
)
EXPECTED_RUNTIME_SHEET_SHA256 = (
    "a8b656423ffd456f31b51905cd2f988d37ba73b0982f3c4faf5a9dd7ea677201"
)
EXPECTED_RUNTIME_BULLET_SHA256 = (
    "36d70c62bb19878ce0ad284093c6738b1cdd8985f4c65166695b662c39477974"
)

FRAME_SIZE = 32
SHEET_SIZE = (256, 192)
BULLET_SHEET_SIZE = (36, 8)
MAX_VISIBLE_SIZE = 28
BASELINE_Y = 28
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

PURPLE_RAMP = anchor_pipeline.PURPLE_RAMP
ACCENT_MAP = anchor_pipeline.ACCENT_MAP
ORDINARY_ACCENTS = set(ACCENT_MAP)
COMMON_A1_POINTS = dict(anchor_pipeline.COMMON_A1_BODY_ATTACHMENTS)
G1_SPEC = next(
    spec for spec in anchor_pipeline.CANDIDATES if spec.key == "g1"
)
G1_POINTS = dict(G1_SPEC.attachment_points)
G1_RAIL_POINTS = {
    point: color for point, color in G1_POINTS.items() if point[1] == 15
}
G1_GUARD_POINTS = {
    point: color for point, color in G1_POINTS.items() if point[1] != 15
}


@dataclass(frozen=True)
class SourceSpec:
    key: str
    filename: str
    design: str


SOURCE_SPECS: tuple[SourceSpec, ...] = (
    SourceSpec(
        "M1",
        "combat_robot_gunner_elite_move_m1_imagegen.png",
        "附件逐帧完全固定，八相腿部沿用普通枪手",
    ),
    SourceSpec(
        "M2",
        "combat_robot_gunner_elite_move_m2_imagegen.png",
        "附件轮廓固定，仅承重灰色高光受控移动",
    ),
    SourceSpec(
        "S1",
        "combat_robot_gunner_elite_fire_s1_imagegen.png",
        "开火后坐相中上导轨随枪后退一像素",
    ),
    SourceSpec(
        "S2",
        "combat_robot_gunner_elite_fire_s2_imagegen.png",
        "附件轮廓固定，仅导轨内部阻尼高光压缩一像素",
    ),
    SourceSpec(
        "D1",
        "combat_robot_gunner_elite_death_d1_imagegen.png",
        "G1强化件完整连接并随普通死亡姿态倒地",
    ),
    SourceSpec(
        "D2",
        "combat_robot_gunner_elite_death_d2_imagegen.png",
        "G1强化件保持连接，后半程逐渐被机体遮挡",
    ),
    SourceSpec(
        "B1",
        "combat_robot_gunner_elite_bullet_b1_imagegen.png",
        "固定9×3紫弹轮廓，亮芯逐帧向前移动",
    ),
    SourceSpec(
        "B2",
        "combat_robot_gunner_elite_bullet_b2_imagegen.png",
        "固定9×3紫弹轮廓，内部紫能作受控明暗脉冲",
    ),
)

ANIMATION_MANIFEST_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_manifest.json")
)
ANIMATION_PROMPT_MANIFEST_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_prompt_manifest.json")
)
REPORT_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_preview_report.json")
)
STABILITY_REPORT_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_stability_report.json")
)
COMPARISON_PATH = (
    PREVIEW_DIR / "combat_robot_gunner_elite_animation_comparison.png"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _assert_dev_output(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (PROJECT_ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Preview builder refused non-dev output: {path}")


def _save_png(image: Image.Image, path: Path) -> None:
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def _save_json(payload: dict, path: Path) -> None:
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def _save_gif(
    frames: list[Image.Image],
    path: Path,
    duration_ms: int,
    scale: int = 8,
) -> None:
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    prepared = [
        _on_background(frame).resize(
            (frame.width * scale, frame.height * scale),
            Image.Resampling.NEAREST,
        ).convert("RGB")
        for frame in frames
    ]
    prepared[0].save(
        path,
        save_all=True,
        append_images=prepared[1:],
        duration=duration_ms,
        loop=0,
        disposal=2,
        optimize=False,
    )


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _validate_first_gate() -> dict:
    required = (
        ANCHOR_MANIFEST_PATH,
        ANCHOR_REPORT_PATH,
        APPROVED_ANCHOR_PATH,
    )
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            "FIRST_GATE_LOCK_MISSING: " + ", ".join(missing)
        )
    manifest = _load_json(ANCHOR_MANIFEST_PATH)
    report = _load_json(ANCHOR_REPORT_PATH)
    if manifest.get("approved_selection") != "G1":
        raise AssertionError("First-gate manifest is not locked to G1")
    if report.get("approved_selection") != "G1":
        raise AssertionError("First-gate report is not locked to G1")
    if manifest.get("runtime_written") is not False:
        raise AssertionError("First-gate manifest unexpectedly wrote runtime")
    if report.get("runtime_written") is not False:
        raise AssertionError("First-gate report unexpectedly wrote runtime")
    actual_sha = _sha256(APPROVED_ANCHOR_PATH)
    actual_rgba_sha = _rgba_sha256(
        Image.open(APPROVED_ANCHOR_PATH).convert("RGBA")
    )
    if actual_sha != EXPECTED_APPROVED_ANCHOR_SHA256:
        raise AssertionError(
            f"Approved G1 byte hash drifted: {actual_sha}"
        )
    if actual_rgba_sha != EXPECTED_APPROVED_ANCHOR_RGBA_SHA256:
        raise AssertionError(
            f"Approved G1 RGBA hash drifted: {actual_rgba_sha}"
        )
    for payload in (manifest, report):
        locked = payload.get("approved_anchor") or {}
        if locked.get("sha256") != actual_sha:
            raise AssertionError("Approved G1 hash is not locked in both gates")
        if locked.get("rgba_sha256") != actual_rgba_sha:
            raise AssertionError("Approved G1 RGBA hash is not locked in both gates")
    return {
        "selection": "G1",
        "path": _relative(APPROVED_ANCHOR_PATH),
        "sha256": actual_sha,
        "rgba_sha256": actual_rgba_sha,
    }


def _required_source_paths() -> dict[str, Path]:
    return {spec.key: SOURCE_DIR / spec.filename for spec in SOURCE_SPECS}


def _validate_runtime_sources() -> dict[str, str]:
    if not ORDINARY_SHEET_PATH.is_file() or not ORDINARY_BULLET_PATH.is_file():
        raise FileNotFoundError("Checked-in ordinary runtime gunner assets are missing")
    sheet_sha256 = _sha256(ORDINARY_SHEET_PATH)
    bullet_sha256 = _sha256(ORDINARY_BULLET_PATH)
    if sheet_sha256 != EXPECTED_RUNTIME_SHEET_SHA256:
        raise AssertionError(
            "Ordinary runtime gunner sheet SHA drifted: "
            f"expected {EXPECTED_RUNTIME_SHEET_SHA256}, got {sheet_sha256}"
        )
    if bullet_sha256 != EXPECTED_RUNTIME_BULLET_SHA256:
        raise AssertionError(
            "Ordinary runtime gunner bullet SHA drifted: "
            f"expected {EXPECTED_RUNTIME_BULLET_SHA256}, got {bullet_sha256}"
        )
    return {"sheet": sheet_sha256, "bullet": bullet_sha256}


def _require_second_gate_sources(paths: dict[str, Path]) -> None:
    missing = [
        f"{key}={_relative(path)}"
        for key, path in paths.items()
        if not path.is_file()
    ]
    if missing:
        raise FileNotFoundError(
            "SECOND_GATE_INPUTS_MISSING: independent ImageGen references are "
            "required before native previews can be built:\n  "
            + "\n  ".join(missing)
        )


def _normalize_storage(image: Image.Image) -> Image.Image:
    result = image.convert("RGBA")
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (
                (red, green, blue, 255) if alpha >= 128 else TRANSPARENT
            )
    return result


def _map_purple(image: Image.Image) -> Image.Image:
    result = _normalize_storage(image)
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            mapped = ACCENT_MAP.get(pixels[x, y])
            if mapped is not None:
                pixels[x, y] = mapped
    if set(result.getdata()) & ORDINARY_ACCENTS:
        raise AssertionError("Purple mapping left ordinary red/orange pixels")
    return result


def _extract_sheet_frames(sheet: Image.Image) -> list[list[Image.Image]]:
    if sheet.size != SHEET_SIZE:
        raise AssertionError(
            f"Ordinary gunner sheet must be {SHEET_SIZE}, got {sheet.size}"
        )
    return [
        [
            _map_purple(
                sheet.crop(
                    (
                        column * FRAME_SIZE,
                        row * FRAME_SIZE,
                        (column + 1) * FRAME_SIZE,
                        (row + 1) * FRAME_SIZE,
                    )
                )
            )
            for column in range(8)
        ]
        for row in range(6)
    ]


def _extract_raw_sheet_frames(sheet: Image.Image) -> list[list[Image.Image]]:
    if sheet.size != SHEET_SIZE:
        raise AssertionError(
            f"Ordinary gunner sheet must be {SHEET_SIZE}, got {sheet.size}"
        )
    return [
        [
            sheet.crop(
                (
                    column * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (column + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            for column in range(8)
        ]
        for row in range(6)
    ]


def _assert_storage(image: Image.Image, label: str) -> None:
    for red, green, blue, alpha in image.getdata():
        if alpha not in (0, 255):
            raise AssertionError(f"{label} alpha is not binary")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} transparent RGB is not zero")


def _visible_metrics(image: Image.Image) -> dict:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Unexpected empty candidate frame")
    return {
        "bbox": list(bbox),
        "width": bbox[2] - bbox[0],
        "height": bbox[3] - bbox[1],
        "baseline_bottom": bbox[3],
        "visible_pixels": sum(
            1 for alpha in image.getchannel("A").getdata() if alpha
        ),
    }


def _add_points(
    frame: Image.Image,
    points: dict[tuple[int, int], tuple[int, int, int, int]],
    label: str,
    *,
    skip_occupied: bool = False,
) -> tuple[Image.Image, list[tuple[int, int]]]:
    result = frame.copy()
    pixels = result.load()
    added: list[tuple[int, int]] = []
    for (x, y), color in sorted(points.items()):
        if not (0 <= x < result.width and 0 <= y < result.height):
            if skip_occupied:
                continue
            raise AssertionError(f"{label} point {(x, y)} is out of bounds")
        if pixels[x, y][3] != 0:
            if skip_occupied:
                continue
            raise AssertionError(f"{label} overwrites ordinary pixel {(x, y)}")
        pixels[x, y] = color
        added.append((x, y))
    return result, added


def _move_attachment_points(option: str, phase: int) -> dict:
    points = {**COMMON_A1_POINTS, **G1_POINTS}
    if option == "M2":
        highlight_cycle = (
            anchor_pipeline.MID_STEEL,
            anchor_pipeline.PLATE_GRAY,
            anchor_pipeline.PLATE_HIGHLIGHT,
            anchor_pipeline.PLATE_GRAY,
            anchor_pipeline.MID_STEEL,
            anchor_pipeline.PLATE_GRAY,
            anchor_pipeline.PLATE_HIGHLIGHT,
            anchor_pipeline.PLATE_GRAY,
        )
        points[(24, 15)] = highlight_cycle[phase]
    return points


def _build_move_candidates(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    candidates: dict[str, list[Image.Image]] = {}
    for option in ("M1", "M2"):
        frames: list[Image.Image] = []
        for phase, ordinary in enumerate(rows[0]):
            frame, _added = _add_points(
                ordinary,
                _move_attachment_points(option, phase),
                f"{option}[{phase}]",
            )
            frames.append(frame)
        candidates[option] = frames
    return candidates


def _shift_points(
    points: dict[tuple[int, int], tuple[int, int, int, int]],
    offset_x: int,
    offset_y: int = 0,
) -> dict[tuple[int, int], tuple[int, int, int, int]]:
    return {
        (x + offset_x, y + offset_y): color
        for (x, y), color in points.items()
    }


def _fire_attachment_points(option: str, upper_phase: int) -> dict:
    recoil = upper_phase in (1, 3)
    rail = dict(G1_RAIL_POINTS)
    guard = dict(G1_GUARD_POINTS)
    if option == "S1" and recoil:
        rail = _shift_points(rail, -1)
    elif option == "S2" and recoil:
        # Alpha silhouette stays fixed; the three-pixel rail carriage visibly
        # compresses left by moving its neutral highlight one logical pixel.
        rail[(23, 15)] = anchor_pipeline.PLATE_HIGHLIGHT
        rail[(24, 15)] = anchor_pipeline.MID_STEEL
        rail[(25, 15)] = anchor_pipeline.DARK_STEEL
    return {**COMMON_A1_POINTS, **guard, **rail}


def _build_fire_candidates(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    candidates: dict[str, list[Image.Image]] = {}
    for option in ("S1", "S2"):
        frames: list[Image.Image] = []
        for upper_phase in range(4):
            for leg_phase, ordinary in enumerate(rows[upper_phase + 1]):
                frame, _added = _add_points(
                    ordinary,
                    _fire_attachment_points(option, upper_phase),
                    f"{option}[{upper_phase}][{leg_phase}]",
                )
                frames.append(frame)
        candidates[option] = frames
    return candidates


# Death reinforcement is authored as eight explicit native point tables.  No
# pose rotation, alpha inference, nearest-pixel search, or connectivity filter
# may alter these coordinates.  The validator below only rejects a bad table.
DEATH_BODY_POINT_TABLES: tuple[dict, ...] = (
    {
        (10, 8): anchor_pipeline.OUTLINE,
        (21, 8): anchor_pipeline.OUTLINE,
        (9, 12): anchor_pipeline.OUTLINE,
        (10, 12): anchor_pipeline.MID_STEEL,
        (21, 12): anchor_pipeline.MID_STEEL,
        (22, 12): anchor_pipeline.OUTLINE,
        (9, 13): anchor_pipeline.OUTLINE,
        (22, 13): anchor_pipeline.OUTLINE,
    },
    {
        (10, 9): anchor_pipeline.OUTLINE,
        (21, 9): anchor_pipeline.OUTLINE,
        (9, 13): anchor_pipeline.OUTLINE,
        (10, 13): anchor_pipeline.MID_STEEL,
        (21, 13): anchor_pipeline.MID_STEEL,
        (22, 13): anchor_pipeline.OUTLINE,
        (9, 14): anchor_pipeline.OUTLINE,
        (22, 14): anchor_pipeline.OUTLINE,
    },
    {
        (14, 9): anchor_pipeline.OUTLINE,
        (18, 9): anchor_pipeline.OUTLINE,
        (12, 13): anchor_pipeline.OUTLINE,
        (23, 13): anchor_pipeline.OUTLINE,
        (11, 14): anchor_pipeline.MID_STEEL,
        (23, 14): anchor_pipeline.DARK_STEEL,
    },
    {
        (15, 10): anchor_pipeline.OUTLINE,
        (19, 10): anchor_pipeline.OUTLINE,
        (14, 13): anchor_pipeline.OUTLINE,
        (22, 13): anchor_pipeline.MID_STEEL,
        (13, 14): anchor_pipeline.OUTLINE,
        (24, 14): anchor_pipeline.OUTLINE,
    },
    {
        (16, 10): anchor_pipeline.OUTLINE,
        (21, 10): anchor_pipeline.OUTLINE,
        (14, 13): anchor_pipeline.OUTLINE,
        (21, 13): anchor_pipeline.MID_STEEL,
        (13, 14): anchor_pipeline.OUTLINE,
        (24, 14): anchor_pipeline.OUTLINE,
    },
    {
        (19, 13): anchor_pipeline.OUTLINE,
        (24, 13): anchor_pipeline.OUTLINE,
        (17, 14): anchor_pipeline.OUTLINE,
        (22, 14): anchor_pipeline.MID_STEEL,
        (15, 15): anchor_pipeline.OUTLINE,
        (22, 15): anchor_pipeline.OUTLINE,
    },
    {
        (15, 16): anchor_pipeline.OUTLINE,
        (23, 16): anchor_pipeline.OUTLINE,
        (13, 17): anchor_pipeline.OUTLINE,
        (22, 17): anchor_pipeline.MID_STEEL,
        (9, 18): anchor_pipeline.OUTLINE,
        (23, 18): anchor_pipeline.OUTLINE,
    },
    {
        (12, 17): anchor_pipeline.OUTLINE,
        (20, 17): anchor_pipeline.OUTLINE,
        (9, 18): anchor_pipeline.OUTLINE,
        (26, 18): anchor_pipeline.OUTLINE,
        (8, 19): anchor_pipeline.OUTLINE,
        (26, 19): anchor_pipeline.OUTLINE,
    },
)

DEATH_RAIL_POINT_TABLES: tuple[dict, ...] = (
    {(22, 15): anchor_pipeline.OUTLINE, (23, 15): anchor_pipeline.DARK_STEEL, (24, 15): anchor_pipeline.MID_STEEL, (25, 15): anchor_pipeline.DARK_STEEL, (26, 15): anchor_pipeline.OUTLINE},
    {(22, 16): anchor_pipeline.OUTLINE, (23, 16): anchor_pipeline.DARK_STEEL, (24, 16): anchor_pipeline.MID_STEEL, (25, 16): anchor_pipeline.DARK_STEEL, (26, 16): anchor_pipeline.OUTLINE},
    {(22, 20): anchor_pipeline.OUTLINE, (23, 20): anchor_pipeline.DARK_STEEL, (24, 20): anchor_pipeline.MID_STEEL, (25, 20): anchor_pipeline.DARK_STEEL, (26, 20): anchor_pipeline.OUTLINE},
    {(24, 22): anchor_pipeline.OUTLINE, (25, 22): anchor_pipeline.DARK_STEEL, (26, 22): anchor_pipeline.MID_STEEL, (27, 22): anchor_pipeline.DARK_STEEL, (28, 22): anchor_pipeline.OUTLINE},
    {(24, 21): anchor_pipeline.OUTLINE, (25, 21): anchor_pipeline.DARK_STEEL, (26, 21): anchor_pipeline.MID_STEEL, (27, 21): anchor_pipeline.DARK_STEEL, (28, 21): anchor_pipeline.OUTLINE},
    {(24, 21): anchor_pipeline.OUTLINE, (25, 21): anchor_pipeline.DARK_STEEL, (26, 21): anchor_pipeline.MID_STEEL, (27, 21): anchor_pipeline.DARK_STEEL, (28, 21): anchor_pipeline.OUTLINE},
    {(24, 20): anchor_pipeline.OUTLINE, (25, 20): anchor_pipeline.DARK_STEEL, (26, 20): anchor_pipeline.MID_STEEL, (27, 20): anchor_pipeline.DARK_STEEL, (28, 20): anchor_pipeline.OUTLINE},
    {(26, 20): anchor_pipeline.OUTLINE, (27, 20): anchor_pipeline.DARK_STEEL, (28, 20): anchor_pipeline.MID_STEEL, (29, 20): anchor_pipeline.DARK_STEEL, (30, 20): anchor_pipeline.OUTLINE},
)

DEATH_GUARD_POINT_TABLES: tuple[dict, ...] = (
    {(22, 21): anchor_pipeline.OUTLINE, (22, 22): anchor_pipeline.DARK_STEEL, (20, 23): anchor_pipeline.OUTLINE, (21, 23): anchor_pipeline.DARK_STEEL, (22, 23): anchor_pipeline.OUTLINE},
    {(22, 22): anchor_pipeline.OUTLINE, (22, 23): anchor_pipeline.DARK_STEEL, (20, 24): anchor_pipeline.OUTLINE, (21, 24): anchor_pipeline.DARK_STEEL, (22, 24): anchor_pipeline.OUTLINE},
    {(24, 24): anchor_pipeline.OUTLINE, (24, 25): anchor_pipeline.DARK_STEEL, (25, 25): anchor_pipeline.OUTLINE, (24, 26): anchor_pipeline.DARK_STEEL, (25, 26): anchor_pipeline.OUTLINE},
    {(24, 25): anchor_pipeline.OUTLINE, (24, 26): anchor_pipeline.DARK_STEEL, (22, 27): anchor_pipeline.OUTLINE, (23, 27): anchor_pipeline.DARK_STEEL, (24, 27): anchor_pipeline.OUTLINE},
    {(24, 25): anchor_pipeline.OUTLINE, (24, 26): anchor_pipeline.DARK_STEEL, (22, 27): anchor_pipeline.OUTLINE, (23, 27): anchor_pipeline.DARK_STEEL, (24, 27): anchor_pipeline.OUTLINE},
    {(27, 25): anchor_pipeline.OUTLINE, (27, 26): anchor_pipeline.DARK_STEEL, (25, 27): anchor_pipeline.OUTLINE, (26, 27): anchor_pipeline.DARK_STEEL, (27, 27): anchor_pipeline.OUTLINE},
    {(27, 25): anchor_pipeline.OUTLINE, (27, 26): anchor_pipeline.DARK_STEEL, (25, 27): anchor_pipeline.OUTLINE, (26, 27): anchor_pipeline.DARK_STEEL, (27, 27): anchor_pipeline.OUTLINE},
    {(27, 25): anchor_pipeline.OUTLINE, (27, 26): anchor_pipeline.DARK_STEEL, (25, 27): anchor_pipeline.OUTLINE, (26, 27): anchor_pipeline.DARK_STEEL, (27, 27): anchor_pipeline.OUTLINE},
)

DEATH_D2_VISIBLE_POINT_TABLES: tuple[frozenset[tuple[int, int]], ...] = (
    frozenset({**DEATH_BODY_POINT_TABLES[0], **DEATH_RAIL_POINT_TABLES[0], **DEATH_GUARD_POINT_TABLES[0]}),
    frozenset({**DEATH_BODY_POINT_TABLES[1], **DEATH_RAIL_POINT_TABLES[1], **DEATH_GUARD_POINT_TABLES[1]}),
    frozenset({**DEATH_BODY_POINT_TABLES[2], **DEATH_RAIL_POINT_TABLES[2], **DEATH_GUARD_POINT_TABLES[2]}),
    frozenset({**DEATH_BODY_POINT_TABLES[3], **DEATH_RAIL_POINT_TABLES[3], **DEATH_GUARD_POINT_TABLES[3]}),
    frozenset({(16, 10), (21, 10), (24, 21), (25, 21), (26, 21), (27, 21), (28, 21), (24, 25)}),
    frozenset({(19, 13), (24, 13), (24, 21), (25, 21), (26, 21), (27, 25)}),
    frozenset({(15, 16), (24, 20), (25, 20), (27, 25)}),
    frozenset({(12, 17), (26, 20), (27, 25)}),
)

DEATH_D1_EXPECTED_COUNTS = (18, 18, 16, 16, 16, 16, 16, 16)
DEATH_D2_EXPECTED_COUNTS = (18, 18, 16, 16, 8, 6, 4, 3)
ALIVE_CROWN_EXTENSION_POINTS = {(10, 8), (21, 8)}
DEATH_CROWN_ENDPOINTS: tuple[frozenset[tuple[int, int]], ...] = (
    frozenset({(10, 8), (21, 8)}),
    frozenset({(10, 9), (21, 9)}),
    frozenset({(14, 9), (18, 9)}),
    frozenset({(15, 10), (19, 10)}),
    frozenset({(16, 10), (21, 10)}),
    frozenset({(19, 13), (24, 13)}),
    frozenset({(15, 16), (23, 16)}),
    frozenset({(12, 17), (20, 17)}),
)


def _validate_clean_crown_geometry() -> None:
    alive_crown = {point for point in COMMON_A1_POINTS if point[1] <= 8}
    if alive_crown != ALIVE_CROWN_EXTENSION_POINTS:
        raise AssertionError(f"Alive crown geometry drifted: {sorted(alive_crown)}")
    if any(point[1] == 7 for point in COMMON_A1_POINTS):
        raise AssertionError("Alive animations may not add detached y=7 pixels")
    if any(
        COMMON_A1_POINTS[point] != anchor_pipeline.OUTLINE
        for point in ALIVE_CROWN_EXTENSION_POINTS
    ):
        raise AssertionError("Alive crown extensions must be black OUTLINE")
    for frame_index, endpoints in enumerate(DEATH_CROWN_ENDPOINTS):
        body = DEATH_BODY_POINT_TABLES[frame_index]
        if not endpoints <= set(body):
            raise AssertionError(
                f"Death frame {frame_index} lost clean crown endpoints"
            )
        if any(body[point] != anchor_pipeline.OUTLINE for point in endpoints):
            raise AssertionError(
                f"Death frame {frame_index} crown endpoints are not OUTLINE"
            )
        crown_y = min(point[1] for point in endpoints)
        if any(point[1] < crown_y for point in body):
            raise AssertionError(
                f"Death frame {frame_index} has floating body reinforcement"
            )
        if any(point[1] == 7 for point in body):
            raise AssertionError(
                f"Death frame {frame_index} has forbidden authored y=7 pixels"
            )


def _serialize_point_table(points: dict) -> list[dict]:
    return [
        {"point": [x, y], "rgba": list(points[(x, y)])}
        for x, y in sorted(points)
    ]


def _death_point_table_report() -> dict:
    return {
        "policy": (
            "eight explicit body/rail/guard tables; validation only, with no "
            "rotation, inferred placement, filtering, or fallback"
        ),
        "d1_expected_counts": list(DEATH_D1_EXPECTED_COUNTS),
        "d2_expected_counts": list(DEATH_D2_EXPECTED_COUNTS),
        "d2_frames_0_to_3_equal_d1": True,
        "clean_crown_policy": (
            "two black OUTLINE endpoints attached to each frame's body top; "
            "no detached gray/highlight crown pixels"
        ),
        "frames": [
            {
                "frame": frame_index,
                "body": _serialize_point_table(DEATH_BODY_POINT_TABLES[frame_index]),
                "rail": _serialize_point_table(DEATH_RAIL_POINT_TABLES[frame_index]),
                "guard": _serialize_point_table(DEATH_GUARD_POINT_TABLES[frame_index]),
                "crown_endpoints": [
                    list(point)
                    for point in sorted(DEATH_CROWN_ENDPOINTS[frame_index])
                ],
                "d1_visible_points": [
                    list(point) for point in sorted(_death_all_points(frame_index))
                ],
                "d2_visible_points": [
                    list(point)
                    for point in sorted(DEATH_D2_VISIBLE_POINT_TABLES[frame_index])
                ],
            }
            for frame_index in range(8)
        ],
    }


def _death_all_points(frame_index: int) -> dict:
    body = DEATH_BODY_POINT_TABLES[frame_index]
    rail = DEATH_RAIL_POINT_TABLES[frame_index]
    guard = DEATH_GUARD_POINT_TABLES[frame_index]
    if (set(body) & set(rail)) or (set(body) & set(guard)) or (set(rail) & set(guard)):
        raise AssertionError(f"Death frame {frame_index} point-table categories overlap")
    return {**body, **rail, **guard}


def _death_attachment_points(option: str, frame_index: int) -> dict:
    all_points = _death_all_points(frame_index)
    if option == "D1":
        return all_points
    visible = DEATH_D2_VISIBLE_POINT_TABLES[frame_index]
    if not visible <= set(all_points):
        raise AssertionError(f"D2[{frame_index}] includes a point outside D1")
    return {point: all_points[point] for point in visible}


def _assert_explicit_death_points(
    ordinary: Image.Image,
    points: dict,
    label: str,
) -> None:
    for point in points:
        x, y = point
        if not (0 <= x < FRAME_SIZE and 0 <= y < BASELINE_Y):
            raise AssertionError(f"{label} point {point} is outside the frame contract")
        if ordinary.getpixel(point)[3] != 0:
            raise AssertionError(f"{label} point {point} overwrites runtime alpha")

    def neighbours(point: tuple[int, int]) -> tuple[tuple[int, int], ...]:
        x, y = point
        return ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1))

    frontier = [
        point
        for point in points
        if any(
            0 <= adjacent[0] < FRAME_SIZE
            and 0 <= adjacent[1] < FRAME_SIZE
            and ordinary.getpixel(adjacent)[3] != 0
            for adjacent in neighbours(point)
        )
    ]
    connected = set(frontier)
    while frontier:
        current = frontier.pop()
        for adjacent in neighbours(current):
            if adjacent in points and adjacent not in connected:
                connected.add(adjacent)
                frontier.append(adjacent)
    if connected != set(points):
        raise AssertionError(
            f"{label} has disconnected authored points: {sorted(set(points) - connected)}"
        )


def _build_death_candidates(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    candidates: dict[str, list[Image.Image]] = {}
    for option, expected_counts in (
        ("D1", DEATH_D1_EXPECTED_COUNTS),
        ("D2", DEATH_D2_EXPECTED_COUNTS),
    ):
        frames: list[Image.Image] = []
        for frame_index, ordinary in enumerate(rows[5]):
            points = _death_attachment_points(option, frame_index)
            if len(points) != expected_counts[frame_index]:
                raise AssertionError(
                    f"{option}[{frame_index}] authored-point count drifted: {len(points)}"
                )
            _assert_explicit_death_points(ordinary, points, f"{option}[{frame_index}]")
            frame, added = _add_points(
                ordinary,
                points,
                f"{option}[{frame_index}]",
            )
            if len(added) != expected_counts[frame_index]:
                raise AssertionError(f"{option}[{frame_index}] lost an authored point")
            frames.append(frame)
        candidates[option] = frames
    return candidates


def _extract_bullet_frames(sheet: Image.Image) -> list[Image.Image]:
    if sheet.size != BULLET_SHEET_SIZE:
        raise AssertionError(
            f"Ordinary gunner bullet must be {BULLET_SHEET_SIZE}, got {sheet.size}"
        )
    return [
        _map_purple(sheet.crop((index * 12, 0, (index + 1) * 12, 8)))
        for index in range(3)
    ]


def _extract_raw_bullet_frames(sheet: Image.Image) -> list[Image.Image]:
    if sheet.size != BULLET_SHEET_SIZE:
        raise AssertionError(
            f"Ordinary gunner bullet must be {BULLET_SHEET_SIZE}, got {sheet.size}"
        )
    return [sheet.crop((index * 12, 0, (index + 1) * 12, 8)) for index in range(3)]


def _build_bullet_candidates(frames: list[Image.Image]) -> dict[str, list[Image.Image]]:
    b1 = [frame.copy() for frame in frames]
    b2: list[Image.Image] = []
    pulse_ramps = (
        (PURPLE_RAMP[1], PURPLE_RAMP[3], PURPLE_RAMP[4]),
        (PURPLE_RAMP[1], PURPLE_RAMP[4], PURPLE_RAMP[5]),
        (PURPLE_RAMP[1], PURPLE_RAMP[3], PURPLE_RAMP[4]),
    )
    for phase, frame in enumerate(frames):
        result = frame.copy()
        pixels = result.load()
        dark, middle, bright = pulse_ramps[phase]
        for y in range(result.height):
            for x in range(result.width):
                if pixels[x, y][3] == 0:
                    continue
                if pixels[x, y] in (PURPLE_RAMP[4], PURPLE_RAMP[5]):
                    pixels[x, y] = bright
                elif pixels[x, y] == PURPLE_RAMP[1]:
                    pixels[x, y] = dark
                else:
                    pixels[x, y] = middle
        b2.append(result)
    return {"B1": b1, "B2": b2}


def _assert_frame_contract(frame: Image.Image, label: str) -> dict:
    if frame.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"{label} must be 32x32")
    _assert_storage(frame, label)
    metrics = _visible_metrics(frame)
    if metrics["width"] > MAX_VISIBLE_SIZE or metrics["height"] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label} exceeds 28x28: {metrics}")
    if metrics["baseline_bottom"] > BASELINE_Y:
        raise AssertionError(f"{label} crosses y=28 baseline: {metrics}")
    return metrics


def _assert_bullet_contract(frames: list[Image.Image], label: str) -> list[dict]:
    masks: list[bytes] = []
    reports: list[dict] = []
    for index, frame in enumerate(frames):
        if frame.size != (12, 8):
            raise AssertionError(f"{label}[{index}] must be 12x8")
        _assert_storage(frame, f"{label}[{index}]")
        bbox = frame.getchannel("A").getbbox()
        if bbox is None or (bbox[2] - bbox[0], bbox[3] - bbox[1]) != (9, 3):
            raise AssertionError(f"{label}[{index}] is not strict 9x3: {bbox}")
        alpha_bytes = frame.getchannel("A").tobytes()
        visible_pixels = sum(1 for alpha in alpha_bytes if alpha)
        if visible_pixels != 23:
            raise AssertionError(
                f"{label}[{index}] must preserve the 23-pixel capsule mask, "
                f"got {visible_pixels}"
            )
        masks.append(alpha_bytes)
        reports.append(
            {
                "frame": index,
                "bbox": list(bbox),
                "visible_pixels": visible_pixels,
                "alpha_mask_sha256": hashlib.sha256(alpha_bytes).hexdigest(),
            }
        )
    if len(set(masks)) != 1:
        raise AssertionError(f"{label} bullet alpha mask flickers")
    return reports


def _assemble_strip(frames: list[Image.Image], columns: int) -> Image.Image:
    rows = math.ceil(len(frames) / columns)
    strip = Image.new(
        "RGBA", (columns * frames[0].width, rows * frames[0].height), TRANSPARENT
    )
    for index, frame in enumerate(frames):
        strip.alpha_composite(
            frame,
            (
                (index % columns) * frames[0].width,
                (index // columns) * frames[0].height,
            ),
        )
    return strip


def _delta_frame(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, TRANSPARENT)
    pixels = result.load()
    for y in range(base.height):
        for x in range(base.width):
            before = base.getpixel((x, y))
            after = candidate.getpixel((x, y))
            if before == after:
                continue
            pixels[x, y] = after if after[3] else (60, 210, 235, 255)
    return result


def _on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    result.alpha_composite(image)
    return result


def _review_font(size: int) -> ImageFont.ImageFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _mirror_frames(frames: Iterable[Image.Image]) -> list[Image.Image]:
    return [
        frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) for frame in frames
    ]


FIRE_TIMELINE_FPS = 25
FIRE_LEG_FPS = 7
FIRE_TIMELINE_SECONDS = 8
FIRE_TIMELINE_TICKS = FIRE_TIMELINE_FPS * FIRE_TIMELINE_SECONDS


def _build_fire_runtime_timeline(
    matrix_frames: list[Image.Image],
) -> tuple[list[Image.Image], list[dict]]:
    if len(matrix_frames) != 32:
        raise AssertionError("Fire candidate must contain a 4x8 phase matrix")
    timeline: list[Image.Image] = []
    schedule: list[dict] = []
    for tick in range(FIRE_TIMELINE_TICKS):
        upper_phase = tick % 4
        leg_phase = ((tick * FIRE_LEG_FPS) // FIRE_TIMELINE_FPS) % 8
        matrix_index = upper_phase * 8 + leg_phase
        timeline.append(matrix_frames[matrix_index])
        schedule.append(
            {
                "tick": tick,
                "upper_phase": upper_phase,
                "leg_phase": leg_phase,
                "matrix_index": matrix_index,
            }
        )
    next_upper = FIRE_TIMELINE_TICKS % 4
    next_leg = (
        (FIRE_TIMELINE_TICKS * FIRE_LEG_FPS) // FIRE_TIMELINE_FPS
    ) % 8
    if (next_upper, next_leg) != (0, 0):
        raise AssertionError("Fire timeline does not close on its initial state")
    return timeline, schedule


def _save_candidate_outputs(
    key: str,
    frames: list[Image.Image],
    bases: list[Image.Image],
    columns: int,
    duration_ms: int,
    scale: int,
    playback_frames: list[Image.Image] | None = None,
) -> dict:
    slug = key.lower()
    strip_path = PREVIEW_DIR / (
        f"combat_robot_gunner_elite_{slug}_candidate_strip.png"
    )
    strip_large_path = PREVIEW_DIR / (
        f"combat_robot_gunner_elite_{slug}_candidate_strip_8x.png"
    )
    delta_path = PREVIEW_DIR / (
        f"combat_robot_gunner_elite_{slug}_ordinary_delta.png"
    )
    gif_path = PREVIEW_DIR / f"combat_robot_gunner_elite_{slug}.gif"
    mirrored_gif_path = (
        PREVIEW_DIR / f"combat_robot_gunner_elite_{slug}_mirrored.gif"
    )
    strip = _assemble_strip(frames, columns)
    delta = _assemble_strip(
        [_delta_frame(base, frame) for base, frame in zip(bases, frames)],
        columns,
    )
    _save_png(strip, strip_path)
    _save_png(
        _on_background(strip).resize(
            (strip.width * 8, strip.height * 8),
            Image.Resampling.NEAREST,
        ),
        strip_large_path,
    )
    _save_png(delta, delta_path)
    playback = playback_frames if playback_frames is not None else frames
    _save_gif(playback, gif_path, duration_ms, scale)
    _save_gif(_mirror_frames(playback), mirrored_gif_path, duration_ms, scale)
    robot_frames = frames[0].size == (32, 32)
    metrics = [
        _assert_frame_contract(frame, f"{key}[{index}]")
        if robot_frames
        else {}
        for index, frame in enumerate(frames)
    ]
    if robot_frames:
        for index, (base, candidate) in enumerate(zip(bases, frames)):
            for y in range(base.height):
                for x in range(base.width):
                    if base.getpixel((x, y))[3] == 0:
                        continue
                    if candidate.getpixel((x, y)) != base.getpixel((x, y)):
                        raise AssertionError(
                            f"{key}[{index}] changed inherited runtime pixel {(x, y)}"
                        )
    attachment_pixels_added = []
    if robot_frames:
        attachment_pixels_added = [
            sum(
                1
                for y in range(base.height)
                for x in range(base.width)
                if base.getpixel((x, y))[3] == 0
                and candidate.getpixel((x, y))[3] == 255
            )
            for base, candidate in zip(bases, frames)
        ]
    core_hashes = []
    if robot_frames:
        core_hashes = [
            _rgba_sha256(frame.crop((10, 4, 22, 22))) for frame in frames
        ]
    return {
        "strip": _relative(strip_path),
        "strip_8x": _relative(strip_large_path),
        "ordinary_delta": _relative(delta_path),
        "gif": _relative(gif_path),
        "mirrored_gif": _relative(mirrored_gif_path),
        "gif_frame_count": len(playback),
        "gif_duration_ms_per_frame": duration_ms,
        "frame_rgba_sha256": [_rgba_sha256(frame) for frame in frames],
        "core_rgba_sha256": core_hashes,
        "unique_core_states": len(set(core_hashes)),
        "ordinary_runtime_opaque_pixels_preserved_exactly": robot_frames,
        "attachment_pixels_added": attachment_pixels_added,
        "metrics": metrics,
    }


def _thumbnail(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    preview = image.copy().convert("RGBA")
    preview.thumbnail(size, Image.Resampling.LANCZOS)
    panel = Image.new("RGBA", size, REVIEW_PANEL)
    panel.alpha_composite(
        preview,
        ((size[0] - preview.width) // 2, (size[1] - preview.height) // 2),
    )
    return panel


def _build_comparison(
    source_paths: dict[str, Path],
    candidates: dict[str, list[Image.Image]],
) -> Image.Image:
    keys = ("M1", "M2", "S1", "S2", "D1", "D2", "B1", "B2")
    cell_width = 300
    cell_height = 390
    board = Image.new(
        "RGBA", (cell_width * 4, 78 + cell_height * 2), REVIEW_BACKGROUND
    )
    draw = ImageDraw.Draw(board)
    title_font = _review_font(22)
    font = _review_font(14)
    draw.text(
        (20, 14),
        "精英持枪战斗机器人 — 第二阶段动画候选",
        fill=REVIEW_TEXT,
        font=title_font,
    )
    draw.text(
        (20, 46),
        "G1已锁定；ImageGen仅作结构语言参考，Native像素全部确定性继承",
        fill=REVIEW_MUTED,
        font=font,
    )
    spec_by_key = {spec.key: spec for spec in SOURCE_SPECS}
    for index, key in enumerate(keys):
        column = index % 4
        row = index // 4
        x = column * cell_width
        y = 78 + row * cell_height
        draw.rectangle(
            (x + 8, y + 8, x + cell_width - 8, y + cell_height - 8),
            fill=REVIEW_PANEL,
        )
        draw.text((x + 18, y + 16), key, fill=REVIEW_TEXT, font=title_font)
        draw.text(
            (x + 18, y + 49),
            spec_by_key[key].design,
            fill=REVIEW_MUTED,
            font=font,
        )
        reference = _thumbnail(
            Image.open(source_paths[key]).convert("RGBA"), (264, 174)
        )
        board.alpha_composite(reference, (x + 18, y + 82))
        representative = candidates[key][0]
        scale = 4 if representative.width == 32 else 16
        native = _on_background(representative).resize(
            (representative.width * scale, representative.height * scale),
            Image.Resampling.NEAREST,
        )
        board.alpha_composite(native, (x + 18, y + 258))
    return board


def _manifest_source_report(source_paths: dict[str, Path]) -> dict:
    spec_by_key = {spec.key: spec for spec in SOURCE_SPECS}
    return {
        key: {
            "path": _relative(path),
            "sha256": _sha256(path),
            "purpose": spec_by_key[key].design,
            "grid_analysis": analyze_image(Image.open(path).convert("RGBA")),
            "pixels_imported": False,
        }
        for key, path in source_paths.items()
    }


def main() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    approved_anchor = _validate_first_gate()
    runtime_hashes = _validate_runtime_sources()
    _validate_clean_crown_geometry()
    source_paths = _required_source_paths()
    _require_second_gate_sources(source_paths)

    ordinary_sheet = _normalize_storage(
        Image.open(ORDINARY_SHEET_PATH).convert("RGBA")
    )
    ordinary_runtime_rows = _extract_raw_sheet_frames(ordinary_sheet)
    ordinary_rows = _extract_sheet_frames(ordinary_sheet)
    ordinary_bullet_sheet = _normalize_storage(
        Image.open(ORDINARY_BULLET_PATH).convert("RGBA")
    )
    ordinary_runtime_bullets = _extract_raw_bullet_frames(ordinary_bullet_sheet)
    ordinary_bullets = _extract_bullet_frames(ordinary_bullet_sheet)

    # The approved anchor must be reproducible from ordinary move frame0 and
    # the exact tables used below before any animation candidate is emitted.
    rebuilt_g1, _added = _add_points(
        ordinary_rows[0][0],
        {**COMMON_A1_POINTS, **G1_POINTS},
        "approved G1 reconstruction",
    )
    approved_image = Image.open(APPROVED_ANCHOR_PATH).convert("RGBA")
    if rebuilt_g1.tobytes() != approved_image.tobytes():
        raise AssertionError("Stage-two G1 reconstruction differs from approved anchor")

    moves = _build_move_candidates(ordinary_rows)
    fires = _build_fire_candidates(ordinary_rows)
    deaths = _build_death_candidates(ordinary_rows)
    death_point_tables = _death_point_table_report()
    bullets = _build_bullet_candidates(ordinary_bullets)
    for key in ("D1", "D2"):
        # The checked-in runtime death0 deliberately has a different leg phase
        # from move0.  Its rigid upper/G1 reinforcement must match the approved
        # anchor, while every runtime death-leg pixel remains byte-identical.
        if deaths[key][0].crop((0, 0, 32, 23)).tobytes() != approved_image.crop(
            (0, 0, 32, 23)
        ).tobytes():
            raise AssertionError(
                f"{key} death frame0 upper must equal the approved G1 anchor"
            )
    candidates = {**moves, **fires, **deaths, **bullets}

    candidate_reports: dict[str, dict] = {}
    for key in ("M1", "M2"):
        candidate_reports[key] = _save_candidate_outputs(
            key, candidates[key], ordinary_rows[0], 8, 71, 8
        )
    fire_bases = [frame for row in ordinary_rows[1:5] for frame in row]
    fire_timeline_schedule: list[dict] | None = None
    for key in ("S1", "S2"):
        timeline, schedule = _build_fire_runtime_timeline(candidates[key])
        if fire_timeline_schedule is None:
            fire_timeline_schedule = schedule
        elif schedule != fire_timeline_schedule:
            raise AssertionError("S1/S2 fire timeline schedules differ")
        candidate_reports[key] = _save_candidate_outputs(
            key,
            candidates[key],
            fire_bases,
            8,
            40,
            8,
            playback_frames=timeline,
        )
        standing_frames = [candidates[key][upper_phase * 8] for upper_phase in range(4)]
        standing_path = (
            PREVIEW_DIR / f"combat_robot_gunner_elite_{key.lower()}_standing.gif"
        )
        standing_mirrored_path = PREVIEW_DIR / (
            f"combat_robot_gunner_elite_{key.lower()}_standing_mirrored.gif"
        )
        _save_gif(standing_frames, standing_path, 160, 8)
        _save_gif(_mirror_frames(standing_frames), standing_mirrored_path, 160, 8)
        candidate_reports[key].update(
            {
                "gif_preview_purpose": (
                    "runtime timing: upper=floor(t*25)%4, "
                    "leg=floor(t*7)%8; full 8-second closed loop"
                ),
                "standing_gif": _relative(standing_path),
                "standing_mirrored_gif": _relative(standing_mirrored_path),
                "standing_gif_preview_purpose": (
                    "design comparison only: fixed leg0, four upper phases at "
                    "160ms each; not runtime timing"
                ),
            }
        )
    if fire_timeline_schedule is None:
        raise AssertionError("Fire timeline schedule was not built")
    fire_schedule_sha256 = hashlib.sha256(
        json.dumps(
            fire_timeline_schedule,
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("utf-8")
    ).hexdigest()
    fire_timing_contract = {
        "runtime_formula": {
            "upper_phase": "floor(t * 25) % 4",
            "leg_phase": "floor(t * 7) % 8",
            "matrix_index": "upper_phase * 8 + leg_phase",
        },
        "gif_fps": FIRE_TIMELINE_FPS,
        "upper_fps": FIRE_TIMELINE_FPS,
        "leg_fps": FIRE_LEG_FPS,
        "loop_seconds": FIRE_TIMELINE_SECONDS,
        "gif_frames": FIRE_TIMELINE_TICKS,
        "closed_loop": True,
        "schedule_sha256": fire_schedule_sha256,
        "primary_gif_purpose": "runtime timing preview",
        "standing_gif_purpose": (
            "fixed-leg four-phase attachment comparison; not runtime timing"
        ),
    }
    for key in ("D1", "D2"):
        candidate_reports[key] = _save_candidate_outputs(
            key, candidates[key], ordinary_rows[5], 8, 83, 8
        )
    for key in ("B1", "B2"):
        bullet_metrics = _assert_bullet_contract(candidates[key], key)
        for index, (ordinary, candidate) in enumerate(
            zip(ordinary_bullets, candidates[key])
        ):
            ordinary_mask = ordinary.getchannel("A").tobytes()
            candidate_mask = candidate.getchannel("A").tobytes()
            if candidate_mask != ordinary_mask:
                raise AssertionError(
                    f"{key}[{index}] changed the runtime bullet alpha mask"
                )
        candidate_reports[key] = _save_candidate_outputs(
            key, candidates[key], ordinary_bullets, 3, 40, 16
        )
        candidate_reports[key]["bullet_metrics"] = bullet_metrics
        candidate_reports[key]["alpha_mask_stable"] = True

    comparison = _build_comparison(source_paths, candidates)
    _save_png(comparison, COMPARISON_PATH)
    imagegen_sources = _manifest_source_report(source_paths)
    prompt_manifest = {
        "version": 1,
        "asset": "combat_robot_gunner_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "generation_mode": "built-in image_gen",
        "approved_anchor": approved_anchor,
        "identity_references": [
            _relative(APPROVED_ANCHOR_PATH),
            _relative(ORDINARY_SHEET_PATH),
            "resources/texture/enemy/mechanical_life/combat_robot_elite.png",
        ],
        "shared_prompt_contract": (
            "同款冷灰方盒机体、A1平直肩盖与直顶框、普通9×4枪体；"
            "只探索G1附件的动作语言。绿色背景，最近邻像素草图；"
            "生成像素不进入Native候选。"
        ),
        "imagegen_sources": imagegen_sources,
        "source_sha256_locked": True,
        "pixel_policy": (
            "ImageGen is display-only; native candidates derive from ordinary "
            "runtime sheets, fixed purple mapping, and explicit per-frame G1 "
            "point tables"
        ),
        "pixels_imported": False,
        "approved_selection": None,
        "runtime_written": False,
    }
    _save_json(prompt_manifest, ANIMATION_PROMPT_MANIFEST_PATH)
    manifest = {
        "version": 1,
        "asset": "combat_robot_gunner_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "approved_anchor": approved_anchor,
        "prompt_manifest": _relative(ANIMATION_PROMPT_MANIFEST_PATH),
        "prompt_manifest_sha256": _sha256(ANIMATION_PROMPT_MANIFEST_PATH),
        "candidate_outputs": {
            key: {
                "strip": payload["strip"],
                "gif": payload["gif"],
                "mirrored_gif": payload["mirrored_gif"],
                "ordinary_delta": payload["ordinary_delta"],
                **(
                    {
                        "standing_gif": payload["standing_gif"],
                        "standing_mirrored_gif": payload[
                            "standing_mirrored_gif"
                        ],
                        "gif_preview_purpose": payload["gif_preview_purpose"],
                        "standing_gif_preview_purpose": payload[
                            "standing_gif_preview_purpose"
                        ],
                    }
                    if key in ("S1", "S2")
                    else {}
                ),
            }
            for key, payload in candidate_reports.items()
        },
        "fire_timing_contract": fire_timing_contract,
        "death_point_table_contract": {
            "explicit_per_frame": True,
            "d1_expected_counts": list(DEATH_D1_EXPECTED_COUNTS),
            "d2_expected_counts": list(DEATH_D2_EXPECTED_COUNTS),
            "d2_frames_0_to_3_equal_d1": True,
            "alive_crown_extension_points": [
                list(point) for point in sorted(ALIVE_CROWN_EXTENSION_POINTS)
            ],
            "authored_alive_y7_pixels": 0,
            "death_crown_endpoints_are_black_outline": True,
        },
        "approved_selection": None,
        "runtime_written": False,
    }
    _save_json(manifest, ANIMATION_MANIFEST_PATH)
    stability_report = {
        "asset": "combat_robot_gunner_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "approved_anchor": approved_anchor,
        "approved_selection": None,
        "runtime_written": False,
        "ordinary_runtime_sheet_sha256": _sha256(ORDINARY_SHEET_PATH),
        "ordinary_runtime_bullet_sha256": _sha256(ORDINARY_BULLET_PATH),
        "checks": {
            "native_pixels_come_from_runtime_pngs": True,
            "runtime_sheet_sha_locked": runtime_hashes["sheet"]
            == EXPECTED_RUNTIME_SHEET_SHA256,
            "runtime_bullet_sha_locked": runtime_hashes["bullet"]
            == EXPECTED_RUNTIME_BULLET_SHA256,
            "old_preview_processor_not_imported_or_executed": True,
            "runtime_opaque_pixels_preserved_per_robot_frame": True,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "max_visible_size": [28, 28],
            "baseline_bottom": BASELINE_Y,
            "bullet_alpha_mask_byte_identical_to_runtime": True,
            "bullet_visible_pixels": 23,
            "bullet_visible_bbox": [9, 3],
            "fire_gif_uses_runtime_25x7_timing": True,
            "fire_gif_full_loop_seconds": FIRE_TIMELINE_SECONDS,
            "fire_standing_gif_is_design_only": True,
            "death_uses_explicit_per_frame_point_tables": True,
            "death_authored_points_four_connected_to_runtime": True,
            "death_d2_late_visible_counts": [8, 6, 4, 3],
            "alive_crown_is_continuous_black_top_edge": True,
            "authored_alive_y7_pixels": 0,
            "death_crown_has_no_floating_gray_highlights": True,
        },
        "fire_timing_contract": fire_timing_contract,
        "death_point_tables": death_point_tables,
        "candidates": {
            key: {
                "frame_rgba_sha256": payload["frame_rgba_sha256"],
                "core_rgba_sha256": payload["core_rgba_sha256"],
                "unique_core_states": payload["unique_core_states"],
                "attachment_pixels_added": payload["attachment_pixels_added"],
                "metrics": payload["metrics"],
                **(
                    {
                        "bullet_metrics": payload["bullet_metrics"],
                        "alpha_mask_stable": payload["alpha_mask_stable"],
                    }
                    if key in ("B1", "B2")
                    else {}
                ),
            }
            for key, payload in candidate_reports.items()
        },
    }
    _save_json(stability_report, STABILITY_REPORT_PATH)
    report = {
        "asset": "combat_robot_gunner_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "approved_anchor": approved_anchor,
        "approved_selection": None,
        "runtime_written": False,
        "preview_only": True,
        "builder": _relative(SCRIPT_PATH),
        "builder_sha256": _sha256(SCRIPT_PATH),
        "ordinary_sheet": {
            "path": _relative(ORDINARY_SHEET_PATH),
            "sha256": runtime_hashes["sheet"],
            "expected_sha256": EXPECTED_RUNTIME_SHEET_SHA256,
            "sha256_locked": True,
            "size": list(SHEET_SIZE),
            "frame_rgba_sha256": [
                _rgba_sha256(frame)
                for row in ordinary_runtime_rows
                for frame in row
            ],
        },
        "ordinary_bullet": {
            "path": _relative(ORDINARY_BULLET_PATH),
            "sha256": runtime_hashes["bullet"],
            "expected_sha256": EXPECTED_RUNTIME_BULLET_SHA256,
            "sha256_locked": True,
            "size": list(BULLET_SHEET_SIZE),
            "frame_rgba_sha256": [
                _rgba_sha256(frame) for frame in ordinary_runtime_bullets
            ],
            "alpha_mask_sha256": [
                hashlib.sha256(frame.getchannel("A").tobytes()).hexdigest()
                for frame in ordinary_runtime_bullets
            ],
            "visible_pixels_per_frame": [
                sum(1 for alpha in frame.getchannel("A").getdata() if alpha)
                for frame in ordinary_runtime_bullets
            ],
        },
        "contract": {
            "frame_size": [32, 32],
            "move_frames": 8,
            "fire_matrix": [4, 8],
            "death_frames": 8,
            "bullet_cells": [3, 12, 8],
            "bullet_visible_bbox": [9, 3],
            "bullet_visible_pixels": 23,
            "bullet_alpha_mask_byte_identical_to_runtime": True,
            "max_visible_size": [28, 28],
            "baseline_bottom": BASELINE_Y,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "fixed_purple_mapping": True,
            "approved_g1_reconstructed_byte_identical": True,
            "ordinary_runtime_opaque_pixels_preserved_per_frame": True,
            "alive_crown_extension_points": [
                list(point) for point in sorted(ALIVE_CROWN_EXTENSION_POINTS)
            ],
            "authored_alive_y7_pixels": 0,
            "death_crown_endpoints_are_black_outline": True,
            "runtime_or_scene_writes": False,
        },
        "fire_timing_contract": {
            **fire_timing_contract,
            "schedule": fire_timeline_schedule,
        },
        "death_point_tables": death_point_tables,
        "candidates": candidate_reports,
        "imagegen_sources": imagegen_sources,
        "comparison": _relative(COMPARISON_PATH),
        "animation_manifest": _relative(ANIMATION_MANIFEST_PATH),
        "prompt_manifest": _relative(ANIMATION_PROMPT_MANIFEST_PATH),
        "stability_report": _relative(STABILITY_REPORT_PATH),
    }
    _save_json(report, REPORT_PATH)
    print(
        "COMBAT_ROBOT_GUNNER_ELITE_ANIMATION_PREVIEW_OK "
        "approved_anchor=G1 candidates=8 approved_selection=null "
        "runtime_written=false"
    )
    print(f"  {_relative(COMPARISON_PATH)}")
    print(f"  {_relative(REPORT_PATH)}")
    print(f"  {_relative(ANIMATION_MANIFEST_PATH)}")
    print(f"  {_relative(ANIMATION_PROMPT_MANIFEST_PATH)}")
    print(f"  {_relative(STABILITY_REPORT_PATH)}")


if __name__ == "__main__":
    main()
