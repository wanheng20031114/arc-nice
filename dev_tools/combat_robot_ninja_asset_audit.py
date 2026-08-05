#!/usr/bin/env python3
"""Audit the approved ninja runtime art, animation resource and shader contract."""

from __future__ import annotations

from collections import deque
import hashlib
import json
import re
from pathlib import Path

from PIL import Image

from process_combat_robot_assets import PALETTE


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORY = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_ninja"
)
APPROVED_ANCHOR_PATH = (
    SOURCE_DIRECTORY / "combat_robot_ninja_anchor_c_approved_native40.png"
)
SHEET_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_ninja.png"
)
ANIMATION_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_ninja.tres"
)
BUILDER_PATH = PROJECT_ROOT / "dev_tools" / "build_combat_robot_ninja_runtime_assets.py"
SHADER_PATH = PROJECT_ROOT / "scene" / "entity_motion_status.gdshader"
PROJECT_SETTINGS_PATH = PROJECT_ROOT / "project.godot"
REPORT_PATH = (
    PROJECT_ROOT
    / "dev_assets"
    / "generated_previews"
    / "combat_robot_ninja_runtime_asset_report.json"
)

FRAME_SIZE = 40
FRAME_COUNT = 8
BASELINE_Y = 32
MAX_VISIBLE_SIZE = 28
TRAIL_MARGIN = 6
TRANSPARENT = (0, 0, 0, 0)
ALLOWED_PIXELS = set(PALETTE) | {TRANSPARENT}
BLADE_HIGHLIGHT = PALETTE[7]
EXPECTED_DASH_BLOCK_SHA256 = (
    "582818eeb5d43e880f90942b696184ddfcc9295d7f51582ec3ebf19614c9bc58"
)
ANIMATION_CONTRACT = {
    "move": {
        "source": "combat_robot_ninja_move_m1_candidate_native.png",
        "source_sha256": "07af3470d29a39c0d541b499fa671716153e3a673402caa692a6b9bde7e5efa6",
        "row": 0,
        "speed": 20.0,
        "loop": True,
    },
    "boost": {
        "source": "combat_robot_ninja_boost_s1_candidate_native.png",
        "source_sha256": "0caf9cef8ed8723c5b0e49f0c7dc2c78a2ccf6e252c71e6bf1eb5e99d7cb609f",
        "row": 1,
        "speed": 24.0,
        "loop": True,
    },
    "death": {
        "source": "combat_robot_ninja_death_d1_candidate_native.png",
        "source_sha256": "22c987eaf26692722ec0a77fc9a9720c4a6a1b785ddc97733c55748c13276b58",
        "row": 2,
        "speed": 12.0,
        "loop": False,
    },
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


def _component_count(frame: Image.Image) -> int:
    alpha = frame.getchannel("A")
    visible = {
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if alpha.getpixel((x, y)) > 0
    }
    components = 0
    while visible:
        components += 1
        pending: deque[tuple[int, int]] = deque([visible.pop()])
        while pending:
            x, y = pending.popleft()
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
                if neighbor in visible:
                    visible.remove(neighbor)
                    pending.append(neighbor)
    return components


def _fixed_core_reference() -> dict[tuple[int, int], tuple[int, int, int, int]]:
    frame = Image.open(APPROVED_ANCHOR_PATH).convert("RGBA")
    result = {}
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            keep = (
                y <= 17
                or (18 <= y <= 23 and 13 <= x <= 26)
                or (y == 24 and 15 <= x <= 24)
                or (y == 25 and 16 <= x <= 23)
            )
            pixel = frame.getpixel((x, y))
            if keep and pixel[3] > 0:
                result[(x, y)] = pixel
    return result


def _audit_animation_text() -> dict[str, object]:
    text = ANIMATION_PATH.read_text(encoding="utf-8")
    required_texture = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_ninja.png"'
    )
    if text.count(required_texture) != 1:
        raise AssertionError("SpriteFrames must reference the ninja sheet once")
    if text.count("filter_clip = true") != 24:
        raise AssertionError("All 24 AtlasTexture frames must enable filter_clip")
    parsed_contract = {}
    for name, contract in ANIMATION_CONTRACT.items():
        if text.count(f'id="AtlasTexture_{name}_') != FRAME_COUNT:
            raise AssertionError(f"SpriteFrames must declare eight {name} frames")
        pattern = re.compile(
            rf'"loop": {str(contract["loop"]).lower()},\s*'
            rf'"name": &"{name}",\s*'
            rf'"speed": {float(contract["speed"]):.1f}',
            re.MULTILINE,
        )
        if pattern.search(text) is None:
            raise AssertionError(
                f"{name} misses speed={contract['speed']} loop={contract['loop']}"
            )
        row = int(contract["row"])
        expected_regions = [
            f"region = Rect2({column * 40}, {row * 40}, 40, 40)"
            for column in range(FRAME_COUNT)
        ]
        if any(region not in text for region in expected_regions):
            raise AssertionError(f"{name} AtlasTexture regions are incomplete")
        parsed_contract[name] = {
            "frames": FRAME_COUNT,
            "speed": contract["speed"],
            "loop": contract["loop"],
            "row": row,
        }
    names = set(re.findall(r'"name": &"([^"]+)"', text))
    if names != set(ANIMATION_CONTRACT):
        raise AssertionError(f"Unexpected animation names: {sorted(names)}")
    return parsed_contract


def _audit_shader() -> dict[str, object]:
    source = SHADER_PATH.read_text(encoding="utf-8")
    declarations = (
        "instance uniform float ninja_afterimage_strength",
        "instance uniform vec2 ninja_afterimage_direction",
        "uniform float ninja_afterimage_pixels",
    )
    if any(declaration not in source for declaration in declarations):
        raise AssertionError("Production shader misses ninja instance uniforms")
    marker = "// Ninja afterimages preserve the source body"
    if marker not in source:
        raise AssertionError("Production shader misses the reviewed ninja block")
    start = source.index(marker)
    end = source.index("\n\tif (slow_overlay_strength", start)
    ninja_block = source[start:end]
    for forbidden in ("scan", "leading_edge", "body_mask", "dash_color"):
        if forbidden in ninja_block:
            raise AssertionError(f"Ninja block unexpectedly contains {forbidden}")
    required_fragments = (
        "texture_color.a <= 0.0",
        "near_sample",
        "middle_sample",
        "far_sample",
        "0.48",
        "0.34",
        "0.22",
        "premultiplied_rgb",
    )
    if any(fragment not in ninja_block for fragment in required_fragments):
        raise AssertionError("Ninja block no longer implements original-color layers")
    dash_start = source.index("\n\tif (dash_effect_strength > 0.0) {")
    dash_end = source.index("\n\t// Ninja afterimages preserve", dash_start)
    dash_hash = hashlib.sha256(source[dash_start:dash_end].encode()).hexdigest()
    if dash_hash != EXPECTED_DASH_BLOCK_SHA256:
        raise AssertionError(f"Existing dash shader block changed: {dash_hash}")
    return {
        "shader_sha256": _sha256(SHADER_PATH),
        "instance_uniforms": [
            "ninja_afterimage_strength",
            "ninja_afterimage_direction",
        ],
        "sample_offsets": [0.45, 0.9, 1.35],
        "sample_alpha_near_middle_far": [0.48, 0.34, 0.22],
        "sample_rgb": "original texture RGB",
        "body_tint": False,
        "body_scan": False,
        "dash_block_sha256": dash_hash,
    }


def main() -> None:
    if not BUILDER_PATH.is_file():
        raise AssertionError("Missing deterministic ninja runtime builder")
    if not SHEET_PATH.is_file() or not ANIMATION_PATH.is_file():
        raise AssertionError("Missing ninja runtime texture or animation resource")
    sheet = Image.open(SHEET_PATH).convert("RGBA")
    if sheet.size != (320, 120):
        raise AssertionError(f"Ninja runtime sheet is {sheet.size}, expected 320x120")
    unexpected = set(sheet.getdata()) - ALLOWED_PIXELS
    if unexpected:
        raise AssertionError(f"Runtime sheet uses unexpected pixels: {unexpected}")

    core_reference = _fixed_core_reference()
    if len(core_reference) != 168:
        raise AssertionError(f"Ninja fixed core has {len(core_reference)} pixels")
    frame_reports: dict[str, list[dict[str, object]]] = {}
    source_hashes = {}
    for name, contract in ANIMATION_CONTRACT.items():
        source_path = SOURCE_DIRECTORY / str(contract["source"])
        actual_source_hash = _sha256(source_path)
        if actual_source_hash != contract["source_sha256"]:
            raise AssertionError(f"Approved {name} source hash changed")
        source = Image.open(source_path).convert("RGBA")
        runtime_row = sheet.crop(
            (0, int(contract["row"]) * 40, 320, (int(contract["row"]) + 1) * 40)
        )
        if runtime_row.tobytes() != source.tobytes():
            raise AssertionError(f"Runtime {name} row is not an exact source copy")
        source_hashes[name] = actual_source_hash
        reports = []
        for frame_index in range(FRAME_COUNT):
            frame = _frame(sheet, int(contract["row"]), frame_index)
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                raise AssertionError(f"{name}[{frame_index}] is empty")
            visible_size = [bbox[2] - bbox[0], bbox[3] - bbox[1]]
            if max(visible_size) > MAX_VISIBLE_SIZE:
                raise AssertionError(f"{name}[{frame_index}] exceeds 28x28")
            margins = [bbox[0], bbox[1], 40 - bbox[2], 40 - bbox[3]]
            if min(margins) < TRAIL_MARGIN:
                raise AssertionError(
                    f"{name}[{frame_index}] lacks six-pixel shader margin: {bbox}"
                )
            if bbox[3] != BASELINE_Y:
                raise AssertionError(f"{name}[{frame_index}] baseline is not y=32")
            components = _component_count(frame)
            if components != 1:
                raise AssertionError(f"{name}[{frame_index}] has {components} parts")
            if name in ("move", "boost"):
                for point, expected_pixel in core_reference.items():
                    if frame.getpixel(point) != expected_pixel:
                        raise AssertionError(
                            f"{name}[{frame_index}] fixed core flickers at {point}"
                        )
            reports.append(
                {
                    "frame": frame_index,
                    "bbox": list(bbox),
                    "visible_size": visible_size,
                    "margins": margins,
                    "connected_components": components,
                    "blade_highlight_pixels": sum(
                        pixel == BLADE_HIGHLIGHT for pixel in frame.getdata()
                    ),
                    "rgba_sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
                }
            )
        if len({report["rgba_sha256"] for report in reports}) != FRAME_COUNT:
            raise AssertionError(f"{name} does not contain eight unique frames")
        if name in ("move", "boost"):
            leg_phases = {
                _frame(sheet, int(contract["row"]), index)
                .crop((0, 26, 40, 40))
                .tobytes()
                for index in range(FRAME_COUNT)
            }
            if len(leg_phases) != FRAME_COUNT:
                raise AssertionError(f"{name} lacks eight unique leg phases")
        if name == "death":
            approved_anchor = Image.open(APPROVED_ANCHOR_PATH).convert("RGBA")
            if _frame(sheet, 2, 0).tobytes() != approved_anchor.tobytes():
                raise AssertionError("D1 frame zero must equal approved C anchor")
            if min(report["blade_highlight_pixels"] for report in reports) < 8:
                raise AssertionError("D1 loses a blade highlight during death")
        frame_reports[name] = reports

    settings = PROJECT_SETTINGS_PATH.read_text(encoding="utf-8")
    if "textures/canvas_textures/default_texture_filter=0" not in settings:
        raise AssertionError("Project nearest-neighbor canvas filter contract changed")
    animation_report = _audit_animation_text()
    shader_report = _audit_shader()
    report = {
        "asset": "combat_robot_ninja",
        "approved_selection": {"move": "M1", "boost": "S1", "death": "D1"},
        "runtime_written": True,
        "runtime_texture": SHEET_PATH.relative_to(PROJECT_ROOT).as_posix(),
        "runtime_texture_sha256": _sha256(SHEET_PATH),
        "runtime_size": [320, 120],
        "frame_size": [40, 40],
        "frame_count": 24,
        "source_hashes": source_hashes,
        "fixed_palette": [list(color) for color in PALETTE],
        "binary_alpha": True,
        "transparent_rgb_zero": True,
        "maximum_visible_bbox": [28, 28],
        "minimum_transparent_margin": TRAIL_MARGIN,
        "baseline_y": BASELINE_Y,
        "fixed_core_pixels": len(core_reference),
        "animation_contract": animation_report,
        "frames": frame_reports,
        "nearest_neighbor_contract": {
            "project_default_texture_filter": 0,
            "atlas_filter_clip": True,
            "mipmaps": False,
        },
        "shader_contract": shader_report,
    }
    import_path = SHEET_PATH.with_suffix(".png.import")
    if import_path.is_file():
        import_text = import_path.read_text(encoding="utf-8")
        if "mipmaps/generate=false" not in import_text:
            raise AssertionError("Ninja runtime import unexpectedly enables mipmaps")
        report["nearest_neighbor_contract"]["import_uid"] = re.search(
            r'uid="([^"]+)"', import_text
        ).group(1)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        "COMBAT_ROBOT_NINJA_ASSET_AUDIT_OK "
        f"texture_sha256={report['runtime_texture_sha256']} frames=24 core=168"
    )


if __name__ == "__main__":
    main()
