#!/usr/bin/env python3
"""Build the second human-gate previews for the elite drone operator.

The approved O3 anchor and the checked-in ordinary runtime sheet are the only
native-pixel sources.  The six independent ImageGen images are hash-locked and
shown beside the deterministic candidates, but no ImageGen pixel is ever
sampled into a candidate.  This tool is deliberately preview-only: it refuses
to write outside ``dev_assets``.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
import process_combat_robot_drone_operator_elite_anchors as anchor_pipeline


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
SOURCE_DIR = (
    ROOT / "dev_assets" / "source_images" / "combat_robot_drone_operator_elite"
)
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"
RUNTIME_SHEET = (
    ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_drone_operator.png"
)
APPROVED_ANCHOR = (
    SOURCE_DIR / "combat_robot_drone_operator_elite_anchor_o3_approved_native32.png"
)
ANCHOR_MANIFEST = SOURCE_DIR / "combat_robot_drone_operator_elite_anchor_manifest.json"
ANCHOR_REPORT = PREVIEW_DIR / "combat_robot_drone_operator_elite_anchor_report.json"

EXPECTED_RUNTIME_SHA256 = (
    "9f987244da55ed3d89bae38a3eda40998518dcd3935f2bb7a1551eb94cd15395"
)
EXPECTED_ANCHOR_SHA256 = (
    "0a85f0f78adcbff8ad827a47b291fb20420070b2e87bbb9098875cee33df536e"
)
EXPECTED_ANCHOR_RGBA_SHA256 = (
    "a4dd5561ba7953f487afbd1be746df075e63290911ee03f2d12e295f5dfe18dc"
)

FRAME_SIZE = 32
RUNTIME_SIZE = (256, 96)
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BG = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)
DELTA_REMOVED = (60, 210, 235, 255)
DELTA_NEW = (255, 67, 190, 255)

PURPLE = anchor_pipeline.PURPLE_RAMP
ACCENT_MAP = anchor_pipeline.ACCENT_MAP
OLD_ACCENTS = set(ACCENT_MAP)
ALLOWED_COLORS = set(anchor_pipeline.ALLOWED_COLORS)
COMMON_A1 = dict(anchor_pipeline.COMMON_A1)
O3_POINTS = dict(
    next(spec for spec in anchor_pipeline.CANDIDATES if spec.key == "o3").additions
)
ALIVE_POINTS = {**COMMON_A1, **O3_POINTS}


@dataclass(frozen=True)
class SourceSpec:
    key: str
    filename: str
    sha256: str
    design: str
    fps: int
    loop: bool


SOURCE_SPECS: tuple[SourceSpec, ...] = (
    SourceSpec(
        "M1",
        "combat_robot_drone_operator_elite_move_m1_imagegen.png",
        "61a337916a6fed1922ddbed6517d5695dc619bdecea264d0ad8a56e7f62df96b",
        "强化件与冷灰高光逐帧完全刚性；继承普通八相腿部",
        14,
        True,
    ),
    SourceSpec(
        "M2",
        "combat_robot_drone_operator_elite_move_m2_imagegen.png",
        "85c7b938096af38483e3a76edf20bf94b339463c05a77503d9a5eba330a22f19",
        "强化轮廓不动；增幅器承重灰色高光按腿相受控换相",
        14,
        True,
    ),
    SourceSpec(
        "P1",
        "combat_robot_drone_operator_elite_deploy_p1_imagegen.png",
        "b43eee43ea447a646f71815d2ebe70c5c1baff468c9aa5b26b72ede6bfaea0ac",
        "眼槽稳定；遥控器紫能逐级充亮，第三帧完成按键",
        30,
        False,
    ),
    SourceSpec(
        "P2",
        "combat_robot_drone_operator_elite_deploy_p2_imagegen.png",
        "047d48c734af76372c6a0b090100b68bd909ac29920f9a7db481fd84f65cda1f",
        "眼槽亮列与遥控器同步由左至右扫描，第三帧完成按键",
        30,
        False,
    ),
    SourceSpec(
        "K1",
        "combat_robot_drone_operator_elite_death_k1_imagegen.png",
        "6e5002267c12353bd70d252b32637df62f5a863bc324cbfb9d064df6111373bc",
        "强化件与增幅器完整连接并沿普通死亡轨迹倒下",
        12,
        False,
    ),
    SourceSpec(
        "K2",
        "combat_robot_drone_operator_elite_death_k2_imagegen.png",
        "f3e29c4c7ff81e003d008ab779e1ec38d804d68c82f834bcfd10771f700b69bc",
        "前四帧同K1；后四帧保持连接并逐步被机体遮挡",
        12,
        False,
    ),
)

MANIFEST_PATH = SOURCE_DIR / "combat_robot_drone_operator_elite_animation_manifest.json"
PROMPT_MANIFEST_PATH = (
    SOURCE_DIR / "combat_robot_drone_operator_elite_animation_prompt_manifest.json"
)
REPORT_PATH = (
    PREVIEW_DIR / "combat_robot_drone_operator_elite_animation_preview_report.json"
)
STABILITY_PATH = (
    PREVIEW_DIR / "combat_robot_drone_operator_elite_animation_stability_report.json"
)
COMPARISON_PATH = (
    PREVIEW_DIR / "combat_robot_drone_operator_elite_animation_comparison.png"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def assert_dev_path(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents:
        raise AssertionError(f"Preview-only builder refused non-dev output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    assert_dev_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def save_json(payload: dict, path: Path) -> None:
    assert_dev_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize(image: Image.Image) -> Image.Image:
    result = image.convert("RGBA")
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (red, green, blue, 255) if alpha >= 128 else TRANSPARENT
    return result


def map_accents(frame: Image.Image) -> Image.Image:
    result = normalize(frame)
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            mapped = ACCENT_MAP.get(pixels[x, y])
            if mapped is not None:
                pixels[x, y] = mapped
    if set(result.getdata()) & OLD_ACCENTS:
        raise AssertionError("Purple mapping left ordinary red/orange pixels")
    return result


def source_paths() -> dict[str, Path]:
    return {spec.key: SOURCE_DIR / spec.filename for spec in SOURCE_SPECS}


def validate_inputs() -> tuple[dict, dict[str, Path], Image.Image]:
    if sha256(RUNTIME_SHEET) != EXPECTED_RUNTIME_SHA256:
        raise AssertionError("Ordinary operator runtime sheet SHA drifted")
    sheet = normalize(Image.open(RUNTIME_SHEET))
    if sheet.size != RUNTIME_SIZE:
        raise AssertionError(f"Ordinary runtime sheet must be {RUNTIME_SIZE}")
    if sha256(APPROVED_ANCHOR) != EXPECTED_ANCHOR_SHA256:
        raise AssertionError("Approved O3 PNG SHA drifted")
    approved = normalize(Image.open(APPROVED_ANCHOR))
    if rgba_sha(approved) != EXPECTED_ANCHOR_RGBA_SHA256:
        raise AssertionError("Approved O3 RGBA SHA drifted")
    for gate_path in (ANCHOR_MANIFEST, ANCHOR_REPORT):
        payload = load_json(gate_path)
        selection = payload.get("approved_selection") or {}
        if selection.get("selection") != "o3":
            raise AssertionError(f"{gate_path.name} is not approved as O3")
        native = selection.get("native") or {}
        if native.get("sha256") != EXPECTED_ANCHOR_SHA256:
            raise AssertionError(f"{gate_path.name} does not lock O3 PNG SHA")
        if native.get("rgba_sha256") != EXPECTED_ANCHOR_RGBA_SHA256:
            raise AssertionError(f"{gate_path.name} does not lock O3 RGBA SHA")
        if payload.get("runtime_written") is not False:
            raise AssertionError(f"{gate_path.name} unexpectedly wrote runtime")
        if payload.get("imagegen_pixels_imported") is not False:
            raise AssertionError(f"{gate_path.name} imported ImageGen pixels")
    paths = source_paths()
    for spec in SOURCE_SPECS:
        path = paths[spec.key]
        if not path.is_file():
            raise FileNotFoundError(f"Missing independent ImageGen source: {rel(path)}")
        actual = sha256(path)
        if actual != spec.sha256:
            raise AssertionError(
                f"ImageGen source {spec.key} SHA drifted: {actual} != {spec.sha256}"
            )
    return {
        "selection": "O3",
        "path": rel(APPROVED_ANCHOR),
        "sha256": EXPECTED_ANCHOR_SHA256,
        "rgba_sha256": EXPECTED_ANCHOR_RGBA_SHA256,
    }, paths, sheet


def extract_rows(sheet: Image.Image, *, purple: bool) -> list[list[Image.Image]]:
    rows: list[list[Image.Image]] = []
    for row in range(3):
        frames = []
        for column in range(8):
            frame = sheet.crop(
                (
                    column * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (column + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            frames.append(map_accents(frame) if purple else normalize(frame))
        rows.append(frames)
    return rows


def add_points(
    base: Image.Image,
    points: dict[tuple[int, int], tuple[int, int, int, int]],
    label: str,
) -> Image.Image:
    result = base.copy()
    pixels = result.load()
    for (x, y), color in sorted(points.items()):
        if not (0 <= x < FRAME_SIZE and 0 <= y < FRAME_SIZE):
            raise AssertionError(f"{label} point {(x, y)} is out of bounds")
        if pixels[x, y][3] != 0:
            raise AssertionError(f"{label} overwrites inherited runtime pixel {(x, y)}")
        pixels[x, y] = color
    return result


def alive_points(option: str, phase: int) -> dict:
    points = dict(ALIVE_POINTS)
    if option == "M2":
        # The approved O3 alpha silhouette is immutable.  Only two authored
        # cold-gray pixels exchange a restrained support highlight in sync
        # with the eight inherited leg phases.
        cycle = (
            anchor_pipeline.MID_STEEL,
            anchor_pipeline.PLATE_GRAY,
            anchor_pipeline.MID_STEEL,
            anchor_pipeline.DARK_STEEL,
            anchor_pipeline.MID_STEEL,
            anchor_pipeline.PLATE_GRAY,
            anchor_pipeline.MID_STEEL,
            anchor_pipeline.DARK_STEEL,
        )
        points[(21, 21)] = cycle[phase]
        points[(22, 22)] = cycle[(phase + 2) % 8]
    return points


def build_move(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    return {
        option: [
            add_points(frame, alive_points(option, phase), f"{option}[{phase}]")
            for phase, frame in enumerate(rows[0])
        ]
        for option in ("M1", "M2")
    }


def set_pixel(
    frame: Image.Image,
    point: tuple[int, int],
    color: tuple[int, int, int, int],
    label: str,
) -> None:
    if frame.getpixel(point)[3] != 255:
        raise AssertionError(f"{label} expected an inherited accent at {point}")
    frame.putpixel(point, color)


def build_deploy(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    candidates: dict[str, list[Image.Image]] = {"P1": [], "P2": []}
    p1_status = (PURPLE[1], PURPLE[3], PURPLE[5])
    p2_status = (PURPLE[3], PURPLE[4], PURPLE[5])
    eye_points = {(x, y) for x in range(15, 18) for y in (11, 12)}
    for phase, base in enumerate(rows[1][:3]):
        p1 = add_points(base, ALIVE_POINTS, f"P1[{phase}]")
        set_pixel(p1, (20, 17), p1_status[phase], f"P1[{phase}]")
        candidates["P1"].append(p1)

        p2 = add_points(base, ALIVE_POINTS, f"P2[{phase}]")
        for point in sorted(eye_points):
            set_pixel(
                p2,
                point,
                PURPLE[5] if point[0] == 15 + phase else PURPLE[1],
                f"P2[{phase}]",
            )
        set_pixel(p2, (20, 17), p2_status[phase], f"P2[{phase}]")
        candidates["P2"].append(p2)
    return candidates


# K1/K2 reinforcement coordinates are inserted below as eight explicit tables
# after an independent frame-by-frame audit.  They must never be replaced by
# rotation, inferred placement, nearest-pixel search, or a fallback transform.
O = anchor_pipeline.OUTLINE
M = anchor_pipeline.MID_STEEL
D = anchor_pipeline.DARK_STEEL
DEATH_K1_POINT_TABLES: tuple[dict, ...] = (
    {
        (10, 8): O, (21, 8): O, (9, 12): O, (10, 12): M,
        (21, 12): M, (22, 12): O, (9, 13): O, (22, 13): O,
        (20, 21): O, (21, 21): M, (22, 21): O, (20, 22): O,
        (22, 22): D, (23, 22): O, (20, 23): O, (21, 23): O,
        (22, 23): O, (23, 23): O,
    },
    {
        (10, 9): O, (21, 9): O, (9, 13): O, (10, 13): M,
        (21, 13): M, (22, 13): O, (9, 14): O, (22, 14): O,
        (20, 22): O, (21, 22): M, (22, 22): O, (20, 23): O,
        (22, 23): D, (23, 23): O, (20, 24): O, (21, 24): O,
        (22, 24): O, (23, 24): O,
    },
    {
        (11, 10): O, (22, 10): O, (10, 14): O, (11, 14): M,
        (22, 14): M, (23, 14): O, (10, 15): O, (23, 15): O,
        (21, 23): O, (22, 23): M, (23, 23): O, (21, 24): O,
        (23, 24): D, (24, 24): O, (22, 25): O, (23, 25): O,
        (24, 25): O,
    },
    {
        (19, 9): O, (9, 11): O, (22, 12): O, (21, 13): M,
        (22, 13): O, (9, 15): O, (10, 15): M, (9, 16): O,
        (24, 21): O, (22, 22): O, (24, 22): D, (25, 22): O,
        (22, 23): O, (23, 23): O, (24, 23): O, (25, 23): O,
    },
    {
        (17, 10): O, (20, 13): M, (21, 13): O, (21, 14): O,
        (8, 15): O, (9, 19): O, (10, 19): M, (9, 20): O,
        (25, 21): O, (26, 21): O, (23, 22): O, (25, 22): D,
        (26, 22): O, (27, 22): O, (23, 23): O, (24, 23): O,
        (25, 23): O,
    },
    {
        (17, 11): O, (20, 14): M, (21, 14): O, (22, 14): O,
        (10, 19): O, (29, 19): O, (27, 20): M, (28, 20): O,
        (29, 20): D, (30, 20): O, (26, 21): O, (27, 21): O,
        (29, 21): O, (28, 22): O, (29, 22): O, (12, 23): O,
        (13, 23): O,
    },
    {
        (15, 12): O, (19, 13): O, (20, 13): O, (29, 16): O,
        (30, 16): O, (27, 17): O, (28, 17): D, (29, 17): O,
        (26, 18): O, (27, 18): O, (29, 18): O, (29, 19): O,
        (11, 22): O, (14, 24): M, (14, 25): O, (15, 25): O,
    },
    {
        (17, 13): O, (18, 13): O, (18, 14): M, (22, 14): O,
        (7, 24): O, (8, 24): O, (9, 24): O, (7, 25): O,
        (9, 25): M, (18, 25): M, (22, 25): O, (7, 26): O,
        (8, 26): D, (9, 26): O, (17, 26): O, (18, 26): O,
        (7, 27): O, (8, 27): O,
    },
)
DEATH_K2_VISIBLE_POINTS: tuple[frozenset[tuple[int, int]], ...] = (
    frozenset(DEATH_K1_POINT_TABLES[0]),
    frozenset(DEATH_K1_POINT_TABLES[1]),
    frozenset(DEATH_K1_POINT_TABLES[2]),
    frozenset(DEATH_K1_POINT_TABLES[3]),
    frozenset({
        (17, 10), (25, 21), (26, 21), (23, 22), (25, 22),
        (26, 22), (27, 22), (23, 23), (24, 23), (25, 23),
    }),
    frozenset({(27, 20), (28, 20), (29, 20), (30, 20), (26, 21), (27, 21)}),
    frozenset({(27, 17), (28, 17), (26, 18), (27, 18)}),
    frozenset({(9, 24), (9, 25)}),
)
EXPECTED_K1_COUNTS = (18, 18, 17, 16, 17, 17, 16, 18)
EXPECTED_K2_COUNTS = (18, 18, 17, 16, 10, 6, 4, 2)


def build_death(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    if len(DEATH_K1_POINT_TABLES) != 8 or len(DEATH_K2_VISIBLE_POINTS) != 8:
        raise AssertionError("Eight explicit K1/K2 death tables are required")
    candidates: dict[str, list[Image.Image]] = {"K1": [], "K2": []}
    for index, base in enumerate(rows[2]):
        full = DEATH_K1_POINT_TABLES[index]
        visible = DEATH_K2_VISIBLE_POINTS[index]
        if not visible <= set(full):
            raise AssertionError(f"K2[{index}] includes a non-K1 point")
        candidates["K1"].append(add_points(base, full, f"K1[{index}]"))
        candidates["K2"].append(
            add_points(
                base,
                {point: full[point] for point in visible},
                f"K2[{index}]",
            )
        )
    if any(
        candidates["K1"][index].tobytes() != candidates["K2"][index].tobytes()
        for index in range(4)
    ):
        raise AssertionError("K2 frames 0-3 must equal K1 exactly")
    return candidates


def opaque_points(image: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] == 255
    }


def component_count(points: set[tuple[int, int]]) -> int:
    remaining = set(points)
    components = 0
    while remaining:
        components += 1
        stack = [remaining.pop()]
        while stack:
            x, y = stack.pop()
            for neighbor in (
                (x - 1, y),
                (x + 1, y),
                (x, y - 1),
                (x, y + 1),
                (x - 1, y - 1),
                (x + 1, y - 1),
                (x - 1, y + 1),
                (x + 1, y + 1),
            ):
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    stack.append(neighbor)
    return components


def expected_added_points(key: str, index: int) -> set[tuple[int, int]]:
    if key in ("M1", "M2", "P1", "P2"):
        return set(ALIVE_POINTS)
    if key == "K1":
        return set(DEATH_K1_POINT_TABLES[index])
    if key == "K2":
        return set(DEATH_K2_VISIBLE_POINTS[index])
    raise AssertionError(f"Unknown candidate {key}")


def audit_frame(
    key: str,
    index: int,
    raw_base: Image.Image,
    purple_base: Image.Image,
    candidate: Image.Image,
) -> dict:
    for pixel in candidate.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{key}[{index}] alpha is not binary")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{key}[{index}] transparent RGB is dirty")
        if pixel[3] and pixel not in ALLOWED_COLORS:
            raise AssertionError(f"{key}[{index}] uses unapproved color {pixel}")
    if set(candidate.getdata()) & OLD_ACCENTS:
        raise AssertionError(f"{key}[{index}] retains ordinary red/orange")

    raw_opaque = opaque_points(raw_base)
    final_opaque = opaque_points(candidate)
    expected_added = expected_added_points(key, index)
    if not raw_opaque <= final_opaque:
        raise AssertionError(f"{key}[{index}] deleted inherited alpha")
    if final_opaque - raw_opaque != expected_added:
        raise AssertionError(f"{key}[{index}] escaped its explicit alpha whitelist")
    for point in raw_opaque:
        before = raw_base.getpixel(point)
        after = candidate.getpixel(point)
        expected = purple_base.getpixel(point)
        if before not in ACCENT_MAP and after != expected:
            raise AssertionError(
                f"{key}[{index}] changed non-accent inherited pixel {point}"
            )
        if before in ACCENT_MAP and after not in PURPLE:
            raise AssertionError(
                f"{key}[{index}] mapped accent outside fixed purple ramp at {point}"
            )
        if key not in ("P1", "P2") and after != expected:
            raise AssertionError(
                f"{key}[{index}] changed mapped inherited accent at {point}"
            )

    bbox = candidate.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{key}[{index}] is empty")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if width > 28 or height > 28 or bbox[3] != 28:
        raise AssertionError(f"{key}[{index}] violates 28x28/y=28: {bbox}")
    components = component_count(final_opaque)
    if components != 1:
        raise AssertionError(f"{key}[{index}] has {components} components")
    return {
        "frame": index,
        "bbox": list(bbox),
        "visible_size": [width, height],
        "baseline_y": bbox[3],
        "registered_center_x": 16,
        "visible_pixels": len(final_opaque),
        "inherited_pixels": len(raw_opaque),
        "added_pixels": len(expected_added),
        "added_points": [list(point) for point in sorted(expected_added)],
        "connected_components_8": components,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
        "red_orange_remaining": 0,
        "nonaccent_runtime_pixels_preserved_exactly": True,
    }


def assemble_strip(frames: list[Image.Image]) -> Image.Image:
    strip = Image.new(
        "RGBA", (len(frames) * FRAME_SIZE, FRAME_SIZE), TRANSPARENT
    )
    for index, frame in enumerate(frames):
        strip.alpha_composite(frame, (index * FRAME_SIZE, 0))
    return strip


def on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BG)
    result.alpha_composite(image)
    return result


def delta_frame(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, TRANSPARENT)
    pixels = result.load()
    for y in range(base.height):
        for x in range(base.width):
            before = base.getpixel((x, y))
            after = candidate.getpixel((x, y))
            if before == after:
                continue
            if after[3] == 0:
                pixels[x, y] = DELTA_REMOVED
            elif before[3] == 0:
                pixels[x, y] = DELTA_NEW
            else:
                pixels[x, y] = after
    return result


def mirror_frames(frames: Iterable[Image.Image]) -> list[Image.Image]:
    return [frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) for frame in frames]


def gif_palette() -> tuple[list[tuple[int, int, int]], list[int]]:
    colors: list[tuple[int, int, int]] = [REVIEW_BG[:3]]
    for rgba in sorted(ALLOWED_COLORS):
        rgb = rgba[:3]
        if rgb not in colors:
            colors.append(rgb)
    if len(colors) > 256:
        raise AssertionError("Fixed GIF palette unexpectedly exceeds 256 colors")
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    return colors, palette


def palettize_exact(image: Image.Image) -> Image.Image:
    colors, palette = gif_palette()
    index = {color: position for position, color in enumerate(colors)}
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    try:
        result.putdata([index[pixel] for pixel in rgb.getdata()])
    except KeyError as error:
        raise AssertionError(f"GIF contains a color outside fixed palette: {error}")
    result.putpalette(palette)
    return result


def save_exact_gif(
    frames: list[Image.Image], path: Path, duration_ms: int, scale: int = 8
) -> dict:
    assert_dev_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    prepared_rgb = [
        on_background(frame)
        .resize(
            (frame.width * scale, frame.height * scale),
            Image.Resampling.NEAREST,
        )
        .convert("RGB")
        for frame in frames
    ]
    encoded = [palettize_exact(frame) for frame in prepared_rgb]
    encoded[0].save(
        path,
        save_all=True,
        append_images=encoded[1:],
        duration=duration_ms,
        loop=0,
        disposal=2,
        optimize=False,
    )
    with Image.open(path) as decoded:
        if decoded.n_frames != len(prepared_rgb):
            raise AssertionError(
                f"{path.name} frame count changed: {decoded.n_frames}"
            )
        decoded_hashes: list[str] = []
        for index, expected in enumerate(prepared_rgb):
            decoded.seek(index)
            actual = decoded.convert("RGB")
            if actual.tobytes() != expected.tobytes():
                raise AssertionError(
                    f"{path.name} frame {index} did not decode losslessly"
                )
            decoded_hashes.append(hashlib.sha256(actual.tobytes()).hexdigest())
    return {
        "path": rel(path),
        "sha256": sha256(path),
        "frame_count": len(frames),
        "duration_ms_per_frame": duration_ms,
        "fixed_palette": True,
        "decoded_frames_exact": True,
        "decoded_rgb_sha256": decoded_hashes,
    }


def remove_green_reference(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            red, green, blue, _alpha = pixels[x, y]
            if green >= 80 and green >= red + 20 and green >= blue + 20:
                pixels[x, y] = TRANSPARENT
            elif green > max(red, blue):
                pixels[x, y] = (red, max(red, blue), blue, 255)
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"ImageGen review reference became empty: {path}")
    return image.crop(bbox)


def fit_reference(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    ratio = min(size[0] / image.width, size[1] / image.height)
    resized = image.resize(
        (max(1, round(image.width * ratio)), max(1, round(image.height * ratio))),
        Image.Resampling.NEAREST,
    )
    panel = Image.new("RGBA", size, REVIEW_PANEL)
    panel.alpha_composite(
        resized, ((size[0] - resized.width) // 2, (size[1] - resized.height) // 2)
    )
    return panel


def review_font(size: int) -> ImageFont.ImageFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def candidate_bases(
    key: str, raw_rows: list[list[Image.Image]], purple_rows: list[list[Image.Image]]
) -> tuple[list[Image.Image], list[Image.Image]]:
    if key in ("M1", "M2"):
        return raw_rows[0], purple_rows[0]
    if key in ("P1", "P2"):
        return raw_rows[1][:3], purple_rows[1][:3]
    if key in ("K1", "K2"):
        return raw_rows[2], purple_rows[2]
    raise AssertionError(f"Unknown candidate {key}")


def save_candidate_outputs(
    spec: SourceSpec,
    frames: list[Image.Image],
    raw_bases: list[Image.Image],
    purple_bases: list[Image.Image],
    imagegen_path: Path,
) -> dict:
    key = spec.key
    slug = key.lower()
    if not (len(frames) == len(raw_bases) == len(purple_bases)):
        raise AssertionError(f"{key} frame/base counts differ")
    metrics = [
        audit_frame(key, index, raw_bases[index], purple_bases[index], frame)
        for index, frame in enumerate(frames)
    ]
    strip = assemble_strip(frames)
    native_path = SOURCE_DIR / (
        f"combat_robot_drone_operator_elite_{slug}_candidate_native_strip.png"
    )
    preview_path = PREVIEW_DIR / (
        f"combat_robot_drone_operator_elite_{slug}_candidate_16x.png"
    )
    delta_path = PREVIEW_DIR / (
        f"combat_robot_drone_operator_elite_{slug}_ordinary_delta_8x.png"
    )
    gif_path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_{slug}.gif"
    mirrored_path = (
        PREVIEW_DIR / f"combat_robot_drone_operator_elite_{slug}_mirrored.gif"
    )
    reference_path = PREVIEW_DIR / (
        f"combat_robot_drone_operator_elite_{slug}_imagegen_transparent_preview.png"
    )
    save_png(strip, native_path)
    save_png(
        on_background(strip).resize(
            (strip.width * 16, strip.height * 16), Image.Resampling.NEAREST
        ),
        preview_path,
    )
    delta_strip = assemble_strip(
        [delta_frame(base, frame) for base, frame in zip(raw_bases, frames)]
    )
    save_png(
        on_background(delta_strip).resize(
            (delta_strip.width * 8, delta_strip.height * 8),
            Image.Resampling.NEAREST,
        ),
        delta_path,
    )
    reference = remove_green_reference(imagegen_path)
    reference_preview = fit_reference(reference, (360, 210))
    save_png(reference_preview, reference_path)

    duration_ms = round(100 / spec.fps) * 10
    gif_report = save_exact_gif(frames, gif_path, duration_ms)
    mirrored_report = save_exact_gif(
        mirror_frames(frames), mirrored_path, duration_ms
    )
    return {
        "design": spec.design,
        "runtime_contract": {
            "frames": len(frames),
            "fps": spec.fps,
            "loop": spec.loop,
        },
        "native_strip": {
            "path": rel(native_path),
            "sha256": sha256(native_path),
            "rgba_sha256": rgba_sha(strip),
            "size": list(strip.size),
        },
        "preview_16x": {"path": rel(preview_path), "sha256": sha256(preview_path)},
        "ordinary_delta_8x": {
            "path": rel(delta_path),
            "sha256": sha256(delta_path),
        },
        "gif": gif_report,
        "mirrored_gif": mirrored_report,
        "imagegen_transparent_preview": {
            "path": rel(reference_path),
            "sha256": sha256(reference_path),
        },
        "frame_rgba_sha256": [rgba_sha(frame) for frame in frames],
        "frame_metrics": metrics,
        "imagegen_pixels_imported": False,
    }


def build_comparison(
    paths: dict[str, Path],
    candidates: dict[str, list[Image.Image]],
    reports: dict[str, dict],
) -> Image.Image:
    keys = ("M1", "M2", "P1", "P2", "K1", "K2")
    cell_width = 440
    cell_height = 420
    board = Image.new(
        "RGBA", (cell_width * 3, 92 + cell_height * 2), REVIEW_BG
    )
    draw = ImageDraw.Draw(board)
    title_font = review_font(24)
    label_font = review_font(16)
    small_font = review_font(13)
    draw.text(
        (20, 14),
        "精英爆炸无人机操作员 — 第二阶段动画候选（O3）",
        fill=REVIEW_TEXT,
        font=title_font,
    )
    draw.text(
        (20, 52),
        "上：独立ImageGen动作语言参考；下：确定性Native候选与普通版差分。生图像素未导入。",
        fill=REVIEW_MUTED,
        font=label_font,
    )
    specs = {spec.key: spec for spec in SOURCE_SPECS}
    for index, key in enumerate(keys):
        column, row = index % 3, index // 3
        x, y = column * cell_width, 92 + row * cell_height
        draw.rectangle(
            (x + 8, y + 8, x + cell_width - 8, y + cell_height - 8),
            fill=REVIEW_PANEL,
        )
        draw.text((x + 18, y + 16), key, fill=REVIEW_TEXT, font=title_font)
        draw.text(
            (x + 68, y + 22),
            f"{len(candidates[key])}帧 @ {specs[key].fps} FPS",
            fill=REVIEW_MUTED,
            font=label_font,
        )
        draw.text(
            (x + 18, y + 54),
            specs[key].design,
            fill=REVIEW_MUTED,
            font=small_font,
        )
        reference = Image.open(
            ROOT / reports[key]["imagegen_transparent_preview"]["path"]
        ).convert("RGBA")
        board.alpha_composite(reference, (x + 40, y + 84))
        representative = on_background(candidates[key][0]).resize(
            (96, 96), Image.Resampling.NEAREST
        )
        board.alpha_composite(representative, (x + 18, y + 298))
        # A one-pixel-per-logical-pixel timeline preserves the exact phase
        # arrangement without resampling it into a fake native grid.
        strip = assemble_strip(candidates[key])
        timeline_panel = Image.new("RGBA", (256, 64), REVIEW_BG)
        timeline_panel.alpha_composite(strip, (0, 16))
        board.alpha_composite(timeline_panel, (x + 150, y + 314))
        draw.text((x + 278, y + 382), "右向Native时间条", fill=REVIEW_MUTED, font=small_font)
    return board


def source_report(paths: dict[str, Path]) -> dict:
    specs = {spec.key: spec for spec in SOURCE_SPECS}
    return {
        key: {
            "path": rel(path),
            "sha256": sha256(path),
            "expected_sha256": specs[key].sha256,
            "purpose": specs[key].design,
            "pixel_grid_analysis": analyze_image(Image.open(path).convert("RGBA")),
            "pixels_imported": False,
        }
        for key, path in paths.items()
    }


def point_table_report() -> dict:
    return {
        "policy": (
            "eight explicit K1 point/color tables plus eight explicit K2 visible "
            "subsets; no rotation, inference, nearest-pixel search, or fallback"
        ),
        "k1_added_counts": [len(points) for points in DEATH_K1_POINT_TABLES],
        "k2_added_counts": [len(points) for points in DEATH_K2_VISIBLE_POINTS],
        "k2_frames_0_to_3_equal_k1": all(
            DEATH_K2_VISIBLE_POINTS[index] == set(DEATH_K1_POINT_TABLES[index])
            for index in range(4)
        ),
        "frames": [
            {
                "frame": index,
                "k1": [
                    {"point": list(point), "rgba": list(table[point])}
                    for point in sorted(table)
                ],
                "k2_visible": [list(point) for point in sorted(DEATH_K2_VISIBLE_POINTS[index])],
            }
            for index, table in enumerate(DEATH_K1_POINT_TABLES)
        ],
    }


def build_candidates(
    purple_rows: list[list[Image.Image]],
) -> dict[str, list[Image.Image]]:
    return {
        **build_move(purple_rows),
        **build_deploy(purple_rows),
        **build_death(purple_rows),
    }


def candidate_memory_hashes(
    candidates: dict[str, list[Image.Image]],
) -> dict[str, list[str]]:
    return {
        key: [rgba_sha(frame) for frame in frames]
        for key, frames in sorted(candidates.items())
    }


def main() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    approved_anchor, paths, sheet = validate_inputs()
    raw_rows = extract_rows(sheet, purple=False)
    purple_rows = extract_rows(sheet, purple=True)

    first_build = build_candidates(purple_rows)
    second_build = build_candidates(purple_rows)
    first_hashes = candidate_memory_hashes(first_build)
    second_hashes = candidate_memory_hashes(second_build)
    if first_hashes != second_hashes:
        raise AssertionError("Two in-memory deterministic builds produced different pixels")
    candidates = first_build

    approved = normalize(Image.open(APPROVED_ANCHOR))
    if candidates["M1"][0].tobytes() != approved.tobytes():
        raise AssertionError("M1 frame0 does not reproduce the approved O3 anchor")
    for left, right in zip(candidates["M1"], candidates["M2"]):
        if left.getchannel("A").tobytes() != right.getchannel("A").tobytes():
            raise AssertionError("M1/M2 alpha silhouettes differ")
    for left, right in zip(candidates["P1"], candidates["P2"]):
        if left.getchannel("A").tobytes() != right.getchannel("A").tobytes():
            raise AssertionError("P1/P2 alpha silhouettes differ")
    for index in range(4):
        if candidates["K1"][index].tobytes() != candidates["K2"][index].tobytes():
            raise AssertionError(f"K1/K2 frame {index} must be byte-identical")

    candidate_reports: dict[str, dict] = {}
    for spec in SOURCE_SPECS:
        raw_bases, purple_bases = candidate_bases(spec.key, raw_rows, purple_rows)
        candidate_reports[spec.key] = save_candidate_outputs(
            spec,
            candidates[spec.key],
            raw_bases,
            purple_bases,
            paths[spec.key],
        )

    comparison = build_comparison(paths, candidates, candidate_reports)
    save_png(comparison, COMPARISON_PATH)
    imagegen_sources = source_report(paths)
    death_tables = point_table_report()

    move_leg_hashes = [
        hashlib.sha256(frame.crop((0, 23, 32, 32)).tobytes()).hexdigest()
        for frame in raw_rows[0]
    ]
    if len(set(move_leg_hashes)) != 8:
        raise AssertionError("Ordinary move row no longer exposes eight unique leg phases")
    k1_counts = [len(table) for table in DEATH_K1_POINT_TABLES]
    k2_counts = [len(points) for points in DEATH_K2_VISIBLE_POINTS]
    if tuple(k1_counts) != EXPECTED_K1_COUNTS:
        raise AssertionError(f"K1 explicit count contract drifted: {k1_counts}")
    if tuple(k2_counts) != EXPECTED_K2_COUNTS:
        raise AssertionError(f"K2 explicit count contract drifted: {k2_counts}")
    if k2_counts[:4] != k1_counts[:4]:
        raise AssertionError("K2 frames 0-3 do not preserve every K1 reinforcement")
    if any(k2_counts[index] < k2_counts[index + 1] for index in range(3, 7)):
        raise AssertionError("K2 late-frame occlusion is not monotonic")

    prompt_manifest = {
        "version": 1,
        "asset": "combat_robot_drone_operator_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "generation_mode": "built-in ImageGen; six independent calls",
        "approved_anchor": approved_anchor,
        "identity_references": [
            rel(APPROVED_ANCHOR),
            rel(RUNTIME_SHEET),
            "resources/texture/enemy/mechanical_life/combat_robot_elite.png",
        ],
        "shared_prompt_contract": (
            "同款冷灰方盒机体、A1平直肩盖、贴顶短护框与O3下置信号增幅器；"
            "紫色仅用于眼槽、天线灯和遥控器状态。每种动画独立生成。"
        ),
        "imagegen_sources": imagegen_sources,
        "source_sha256_locked": True,
        "pixel_policy": (
            "ImageGen is display-only; every native pixel derives from the current "
            "ordinary runtime sheet, fixed purple mapping, approved O3 alive table, "
            "and explicit per-frame death tables"
        ),
        "pixels_imported": False,
        "approved_selection": None,
        "runtime_written": False,
    }
    save_json(prompt_manifest, PROMPT_MANIFEST_PATH)

    stability_report = {
        "asset": "combat_robot_drone_operator_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "approved_anchor": approved_anchor,
        "runtime_source": {
            "path": rel(RUNTIME_SHEET),
            "sha256_before": EXPECTED_RUNTIME_SHA256,
            "sha256_after": sha256(RUNTIME_SHEET),
            "unchanged": sha256(RUNTIME_SHEET) == EXPECTED_RUNTIME_SHA256,
        },
        "determinism": {
            "in_memory_builds": 2,
            "frame_hashes_equal": first_hashes == second_hashes,
            "frame_rgba_sha256": first_hashes,
        },
        "contracts": {
            "frame_size": [32, 32],
            "maximum_visible_size": [28, 28],
            "registered_center_x": 16,
            "living_baseline_y": 28,
            "fixed_palette": True,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "ordinary_nonaccent_pixels_preserved_exactly": True,
            "imagegen_pixels_imported": False,
            "m1_m2_alpha_identical": True,
            "p1_p2_alpha_identical": True,
            "k1_k2_frames_0_to_3_identical": True,
            "move_leg_phase_count": len(set(move_leg_hashes)),
            "move_leg_phase_rgba_sha256": move_leg_hashes,
            "m1_attachment_color_states": len(
                {
                    tuple(frame.getpixel(point) for point in sorted(ALIVE_POINTS))
                    for frame in candidates["M1"]
                }
            ),
            "m2_attachment_color_states": len(
                {
                    tuple(frame.getpixel(point) for point in sorted(ALIVE_POINTS))
                    for frame in candidates["M2"]
                }
            ),
            "k2_late_occlusion_monotonic": True,
        },
        "death_point_tables": death_tables,
        "candidate_metrics": {
            key: payload["frame_metrics"] for key, payload in candidate_reports.items()
        },
        "approved_selection": None,
        "runtime_written": False,
    }
    if stability_report["contracts"]["m1_attachment_color_states"] != 1:
        raise AssertionError("M1 reinforcement unexpectedly changed colors")
    if not 1 < stability_report["contracts"]["m2_attachment_color_states"] <= 4:
        raise AssertionError("M2 support highlight does not have controlled phases")
    save_json(stability_report, STABILITY_PATH)

    report = {
        "asset": "combat_robot_drone_operator_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "approved_anchor": approved_anchor,
        "ordinary_runtime_source": {
            "path": rel(RUNTIME_SHEET),
            "expected_sha256": EXPECTED_RUNTIME_SHA256,
            "actual_sha256": sha256(RUNTIME_SHEET),
        },
        "animation_contract": {
            "M1/M2": "move 8 frames @ 14 FPS loop",
            "P1/P2": "deploy 3 frames @ 30 FPS non-loop (exactly 0.10 s)",
            "K1/K2": "death 8 frames @ 12 FPS non-loop",
        },
        "candidate_outputs": candidate_reports,
        "comparison": {
            "path": rel(COMPARISON_PATH),
            "sha256": sha256(COMPARISON_PATH),
            "size": list(comparison.size),
        },
        "prompt_manifest": {
            "path": rel(PROMPT_MANIFEST_PATH),
            "sha256": sha256(PROMPT_MANIFEST_PATH),
        },
        "stability_report": {
            "path": rel(STABILITY_PATH),
            "sha256": sha256(STABILITY_PATH),
        },
        "script": {"path": rel(SCRIPT_PATH), "sha256": sha256(SCRIPT_PATH)},
        "two_builds_equal": True,
        "fixed_gif_palette_and_exact_decode": True,
        "imagegen_pixels_imported": False,
        "approved_selection": None,
        "runtime_written": False,
    }
    save_json(report, REPORT_PATH)

    manifest = {
        "version": 1,
        "asset": "combat_robot_drone_operator_elite_animation_candidates",
        "stage": "animation_candidates_pending_second_human_gate",
        "approved_anchor": approved_anchor,
        "runtime_source_sha256": EXPECTED_RUNTIME_SHA256,
        "prompt_manifest": {
            "path": rel(PROMPT_MANIFEST_PATH),
            "sha256": sha256(PROMPT_MANIFEST_PATH),
        },
        "preview_report": {"path": rel(REPORT_PATH), "sha256": sha256(REPORT_PATH)},
        "stability_report": {
            "path": rel(STABILITY_PATH),
            "sha256": sha256(STABILITY_PATH),
        },
        "comparison": {"path": rel(COMPARISON_PATH), "sha256": sha256(COMPARISON_PATH)},
        "candidate_native_strips": {
            key: payload["native_strip"] for key, payload in candidate_reports.items()
        },
        "death_point_table_contract": {
            "explicit_per_frame": True,
            "no_rotation_inference_or_fallback": True,
            "k1_added_counts": k1_counts,
            "k2_added_counts": k2_counts,
            "k2_frames_0_to_3_equal_k1": True,
        },
        "approved_selection": None,
        "imagegen_pixels_imported": False,
        "runtime_written": False,
    }
    save_json(manifest, MANIFEST_PATH)

    if sha256(RUNTIME_SHEET) != EXPECTED_RUNTIME_SHA256:
        raise AssertionError("Runtime sheet changed while building previews")
    print(
        json.dumps(
            {
                "ok": True,
                "stage": manifest["stage"],
                "approved_anchor": "O3",
                "comparison": rel(COMPARISON_PATH),
                "manifest": rel(MANIFEST_PATH),
                "report": rel(REPORT_PATH),
                "stability": rel(STABILITY_PATH),
                "runtime_written": False,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
