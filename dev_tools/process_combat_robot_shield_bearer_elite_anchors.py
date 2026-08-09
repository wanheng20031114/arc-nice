#!/usr/bin/env python3
"""Build preview-only H1 anchors for the elite shield-bearing robot.

ImageGen sources are review references only. Native pixels come exclusively
from the locked ordinary runtime frame, a fixed red-to-purple mapping, the
shared A1 gray attachment table, and one explicit four-pixel shield table.
This script refuses outputs outside ``dev_assets`` and never writes runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets/source_images/combat_robot_shield_bearer_elite"
PREVIEW_DIR = ROOT / "dev_assets/generated_previews"
ANCHOR_MANIFEST = SOURCE_DIR / "combat_robot_shield_bearer_elite_anchor_manifest.json"
BASE_SHEET = ROOT / "resources/texture/enemy/mechanical_life/combat_robot_shield_bearer.png"
EXPECTED_BASE_SHA256 = "07e5996a7048f4a469e247ee4aa7ce3c9f9c54a829d6a839ff3c94b2cac72ab4"
EXPECTED_IMAGEGEN_SHA256 = {
    "h1a": "c012aedd54917d54d778c4ff61b189d29ee8b7535cd3586be10cbf74f11cc3b3",
    "h1b": "9aa3a29dd31725b8fc444ddd5a2ad106b212bdd5d9a9df372f2d7b6af3820a0c",
    "h1c": "d8654c42f782818d0b2c43fbdc667dea90577cc24211d599a696ac7782cdf362",
}

FRAME_SIZE = 32
SHIELD_RECT = (24, 8, 30, 26)
EXPECTED_SHIELD_OPAQUE = 102
MAX_VISIBLE = 28
BASELINE_BOTTOM = 28
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BG = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

OUTLINE = PALETTE[0]
DEEP = PALETTE[1]
MID = PALETTE[4]
HIGHLIGHT = PALETTE[5]
PURPLE_RAMP = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)
ACCENT_MAP = {
    (102, 25, 20, 255): PURPLE_RAMP[1],
    (190, 48, 31, 255): PURPLE_RAMP[4],
    (239, 92, 34, 255): PURPLE_RAMP[5],
}
EXPECTED_ACCENT_POINTS = {
    (13, 5),
    (15, 11), (16, 11), (17, 11),
    (15, 12), (16, 12), (17, 12),
    (27, 15), (27, 16), (27, 17), (27, 18),
    (27, 19), (27, 20), (27, 21), (27, 22),
}
COMMON_A1 = {
    (10, 8): OUTLINE,
    (21, 8): OUTLINE,
    (9, 12): OUTLINE,
    (10, 12): MID,
    (21, 12): MID,
    (22, 12): OUTLINE,
    (9, 13): OUTLINE,
    (22, 13): OUTLINE,
}
PROTECTED_POINTS = {
    (26, 12), (27, 12), (28, 12),
    (24, 16), (24, 17), (24, 18),
}
ALLOWED_COLORS = set(PALETTE[:8]) | set(PURPLE_RAMP) | {TRANSPARENT}


@dataclass(frozen=True)
class Candidate:
    key: str
    title: str
    summary: str
    shield_recolors: dict[tuple[int, int], tuple[int, int, int, int]]


CANDIDATES = (
    Candidate(
        "h1a",
        "H1A 对称平直锁扣",
        "纵脊上下两组平直对称锁扣",
        {(26, 17): HIGHLIGHT, (28, 17): DEEP, (26, 20): HIGHLIGHT, (28, 20): DEEP},
    ),
    Candidate(
        "h1b",
        "H1B 反向错位阶梯",
        "上、下锁扣沿纵脊反向错位",
        {(26, 16): HIGHLIGHT, (28, 17): DEEP, (28, 20): HIGHLIGHT, (26, 21): DEEP},
    ),
    Candidate(
        "h1c",
        "H1C 紧凑双端盖",
        "纵脊两端形成紧凑T形套环",
        {(26, 15): HIGHLIGHT, (28, 15): DEEP, (26, 22): HIGHLIGHT, (28, 22): DEEP},
    ),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def assert_dev_output(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents:
        raise AssertionError(f"Refusing non-dev output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def load_base() -> Image.Image:
    actual = sha256(BASE_SHEET)
    if actual != EXPECTED_BASE_SHA256:
        raise AssertionError(f"Ordinary runtime SHA changed: {actual}")
    sheet = Image.open(BASE_SHEET).convert("RGBA")
    if sheet.size != (256, 256):
        raise AssertionError(f"Unexpected runtime sheet size: {sheet.size}")
    return sheet.crop((0, 0, FRAME_SIZE, FRAME_SIZE))


def opaque_points(image: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] != 0
    }


def component_count_8(points: set[tuple[int, int]]) -> int:
    remaining = set(points)
    count = 0
    while remaining:
        count += 1
        stack = [remaining.pop()]
        while stack:
            x, y = stack.pop()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    point = (x + dx, y + dy)
                    if (dx or dy) and point in remaining:
                        remaining.remove(point)
                        stack.append(point)
    return count


def build_candidate(base: Image.Image, spec: Candidate) -> Image.Image:
    result = base.copy()
    pixels = result.load()
    for point in EXPECTED_ACCENT_POINTS:
        source = pixels[point]
        if source not in ACCENT_MAP:
            raise AssertionError(f"Unexpected accent at {point}: {source}")
        pixels[point] = ACCENT_MAP[source]
    for point, color in COMMON_A1.items():
        if base.getpixel(point) != TRANSPARENT:
            raise AssertionError(f"A1 point is not transparent: {point}")
        pixels[point] = color
    for point, color in spec.shield_recolors.items():
        if not (SHIELD_RECT[0] <= point[0] < SHIELD_RECT[2] and SHIELD_RECT[1] <= point[1] < SHIELD_RECT[3]):
            raise AssertionError(f"Shield point escaped rect: {point}")
        if base.getpixel(point)[3] != 255:
            raise AssertionError(f"Shield recolor point is transparent: {point}")
        pixels[point] = color
    return result


def audit_candidate(base: Image.Image, frame: Image.Image, spec: Candidate) -> dict:
    base_opaque = opaque_points(base)
    final_opaque = opaque_points(frame)
    added = final_opaque - base_opaque
    removed = base_opaque - final_opaque
    differences = {
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if base.getpixel((x, y)) != frame.getpixel((x, y))
    }
    expected_differences = EXPECTED_ACCENT_POINTS | set(COMMON_A1) | set(spec.shield_recolors)
    if differences != expected_differences:
        raise AssertionError(f"{spec.key} escaped diff whitelist: {sorted(differences ^ expected_differences)}")
    if added != set(COMMON_A1) or removed:
        raise AssertionError(f"{spec.key} alpha delta invalid: +{added} -{removed}")
    for pixel in frame.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{spec.key} has non-binary alpha")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{spec.key} has dirty transparent RGB")
        if pixel not in ALLOWED_COLORS:
            raise AssertionError(f"{spec.key} has unapproved color {pixel}")
    if any(pixel in ACCENT_MAP for pixel in frame.getdata()):
        raise AssertionError(f"{spec.key} retains old red/orange")
    shield_base = base.crop(SHIELD_RECT).getchannel("A")
    shield_final = frame.crop(SHIELD_RECT).getchannel("A")
    if shield_base.tobytes() != shield_final.tobytes():
        raise AssertionError(f"{spec.key} changed shield alpha")
    shield_opaque = sum(value == 255 for value in shield_final.getdata())
    if shield_opaque != EXPECTED_SHIELD_OPAQUE:
        raise AssertionError(f"{spec.key} shield alpha count={shield_opaque}")
    for point in PROTECTED_POINTS:
        if frame.getpixel(point) != base.getpixel(point):
            raise AssertionError(f"{spec.key} changed protected shield point {point}")
    if any(frame.getpixel((x, 7)) != base.getpixel((x, 7)) for x in range(FRAME_SIZE)):
        raise AssertionError(f"{spec.key} changed y=7")
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{spec.key} is empty")
    visible = (bbox[2] - bbox[0], bbox[3] - bbox[1])
    if visible[0] > MAX_VISIBLE or visible[1] > MAX_VISIBLE or bbox[3] != BASELINE_BOTTOM:
        raise AssertionError(f"{spec.key} violates registration: {bbox}")
    components = component_count_8(final_opaque)
    if components != 1:
        raise AssertionError(f"{spec.key} has {components} 8-connected components")
    return {
        "bbox": list(bbox),
        "visible_size": list(visible),
        "baseline_bottom": bbox[3],
        "registered_center_x": 16,
        "opaque_pixels": len(final_opaque),
        "added_alpha_pixels": len(added),
        "removed_alpha_pixels": len(removed),
        "total_rgba_differences": len(differences),
        "accent_differences": len(EXPECTED_ACCENT_POINTS),
        "a1_added_points": len(COMMON_A1),
        "shield_recolor_points": len(spec.shield_recolors),
        "shield_alpha_rect": list(SHIELD_RECT),
        "shield_alpha_opaque_pixels": shield_opaque,
        "shield_alpha_sha256": hashlib.sha256(shield_final.tobytes()).hexdigest(),
        "protected_slit_and_grip_exact": True,
        "y7_exactly_preserved": True,
        "connected_components_8": components,
        "red_orange_remaining": 0,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
    }


def on_background(image: Image.Image, scale: int = 1) -> Image.Image:
    if scale != 1:
        image = image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)
    result = Image.new("RGBA", image.size, REVIEW_BG)
    result.alpha_composite(image)
    return result


def delta_image(base: Image.Image, frame: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, TRANSPARENT)
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            before, after = base.getpixel((x, y)), frame.getpixel((x, y))
            if before == after:
                if before[3]:
                    result.putpixel((x, y), (82, 88, 94, 255))
            elif before[3] == 0:
                result.putpixel((x, y), (255, 67, 190, 255))
            else:
                result.putpixel((x, y), after)
    return result


def overlay_image(base: Image.Image, frame: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, TRANSPARENT)
    for point in opaque_points(base):
        result.putpixel(point, (60, 210, 235, 96))
    foreground = frame.copy()
    foreground.putalpha(foreground.getchannel("A").point(lambda value: 220 if value else 0))
    result.alpha_composite(foreground)
    return result


def review_font(size: int) -> ImageFont.ImageFont:
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/arial.ttf")):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def make_review_panel(raw: Image.Image, frame: Image.Image, delta: Image.Image, spec: Candidate) -> Image.Image:
    board = Image.new("RGBA", (1180, 650), REVIEW_BG)
    draw = ImageDraw.Draw(board)
    draw.text((24, 18), spec.title, fill=REVIEW_TEXT, font=review_font(24))
    draw.text((24, 52), spec.summary + "；ImageGen仅作语言参考", fill=REVIEW_MUTED, font=review_font(16))
    raw_thumb = raw.copy()
    raw_thumb.thumbnail((520, 520), Image.Resampling.LANCZOS)
    raw_panel = Image.new("RGBA", (540, 540), REVIEW_PANEL)
    raw_panel.alpha_composite(raw_thumb, ((540 - raw_thumb.width) // 2, (540 - raw_thumb.height) // 2))
    board.alpha_composite(raw_panel, (24, 92))
    board.alpha_composite(on_background(frame, 16), (594, 92))
    board.alpha_composite(on_background(delta, 8), (594, 368))
    board.alpha_composite(on_background(frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT), 8), (870, 368))
    draw.text((594, 608), "Native 16× / 差分8× / 左向8×", fill=REVIEW_MUTED, font=review_font(15))
    return board


def save_facing_gif(frame: Image.Image, path: Path) -> None:
    assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    right = on_background(frame, 16).convert("RGB")
    left = on_background(frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT), 16).convert("RGB")
    right.save(path, save_all=True, append_images=[left], duration=[700, 700], loop=0, disposal=2, optimize=False)


def prompt_manifest(imagegen_paths: dict[str, Path], approval: str | None) -> dict:
    common = (
        "单体精英举盾战斗机器人像素概念；冷灰方盒身体、线性四肢、A1平直肩盖与贴顶短护框；"
        "身前6x18窄高塔盾保持普通外轮廓，单条紫能纵脊；纯绿色背景；无文字、无特效。"
    )
    variants = {
        "h1a": "盾面采用上下对称的平直机械锁扣。",
        "h1b": "盾面采用上下反向错位的阶梯机械锁扣。",
        "h1c": "盾面采用紧凑双端盖与T形套环。",
    }
    return {
        "version": 1,
        "asset": "combat_robot_shield_bearer_elite_anchor_candidates",
        "stage": "first_human_gate",
        "mode": "built-in image_gen",
        "normalized_prompt_contract": {
            key: common + variants[key] for key in variants
        },
        "generated_sources": {
            key: {"path": relative(path), "sha256": sha256(path)} for key, path in imagegen_paths.items()
        },
        "pixel_policy": "ImageGen outputs are analyzed and displayed only; no generated pixel enters native32.",
        "approved_selection": approval,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        choices=tuple(spec.key for spec in CANDIDATES),
        help="Record the user's approved first-gate anchor.",
    )
    return parser.parse_args()


def resolve_approval(requested: str | None) -> str | None:
    if requested is not None:
        return requested
    if not ANCHOR_MANIFEST.is_file():
        return None
    existing = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    preserved = existing.get("approved_selection")
    valid = {spec.key for spec in CANDIDATES}
    if preserved is not None and preserved not in valid:
        raise AssertionError(f"Unknown preserved approval: {preserved}")
    return preserved


def main() -> None:
    args = parse_args()
    approval = resolve_approval(args.approve)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    base = load_base()
    base_opaque = opaque_points(base)
    imagegen_paths = {
        spec.key: SOURCE_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_imagegen.png"
        for spec in CANDIDATES
    }
    for key, path in imagegen_paths.items():
        if not path.is_file() or sha256(path) != EXPECTED_IMAGEGEN_SHA256[key]:
            raise AssertionError(f"ImageGen source missing or changed: {path}")

    reports: dict[str, dict] = {}
    for spec in CANDIDATES:
        first = build_candidate(base, spec)
        second = build_candidate(base, spec)
        if first.tobytes() != second.tobytes():
            raise AssertionError(f"{spec.key} in-memory rebuild is nondeterministic")
        metrics = audit_candidate(base, first, spec)
        raw = Image.open(imagegen_paths[spec.key]).convert("RGBA")
        source_analysis = analyze_image(raw)
        delta = delta_image(base, first)

        native = SOURCE_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_native32.png"
        preview = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_16x.png"
        mirrored = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_mirrored_16x.png"
        delta_path = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_ordinary_delta_16x.png"
        overlay_path = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_ordinary_overlay_16x.png"
        gif_path = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_facing.gif"
        review_path = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{spec.key}_review_panel.png"
        save_png(first, native)
        save_png(on_background(first, 16), preview)
        save_png(on_background(first.transpose(Image.Transpose.FLIP_LEFT_RIGHT), 16), mirrored)
        save_png(on_background(delta, 16), delta_path)
        save_png(on_background(overlay_image(base, first), 16), overlay_path)
        save_facing_gif(first, gif_path)
        save_png(make_review_panel(raw, first, delta, spec), review_path)
        reports[spec.key] = {
            "title": spec.title,
            "summary": spec.summary,
            "imagegen_reference": {"path": relative(imagegen_paths[spec.key]), "sha256": sha256(imagegen_paths[spec.key])},
            "imagegen_grid_analysis": source_analysis,
            "native32": {"path": relative(native), "sha256": sha256(native), "rgba_sha256": rgba_sha(first)},
            "preview_16x": {"path": relative(preview), "sha256": sha256(preview)},
            "mirrored_16x": {"path": relative(mirrored), "sha256": sha256(mirrored)},
            "ordinary_delta_16x": {"path": relative(delta_path), "sha256": sha256(delta_path)},
            "ordinary_overlay_16x": {"path": relative(overlay_path), "sha256": sha256(overlay_path)},
            "facing_gif": {"path": relative(gif_path), "sha256": sha256(gif_path)},
            "review_panel": {"path": relative(review_path), "sha256": sha256(review_path)},
            "shield_recolor_table": [
                {"point": list(point), "rgba": list(color)}
                for point, color in sorted(spec.shield_recolors.items())
            ],
            "audit": metrics,
            "deterministic_in_memory_rebuild": True,
            "imagegen_pixels_imported": False,
        }

    manifest_path = SOURCE_DIR / "imagegen_prompt_manifest.json"
    manifest = prompt_manifest(imagegen_paths, approval)
    assert_dev_output(manifest_path)
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    shield_alpha = base.crop(SHIELD_RECT).getchannel("A")
    approved_outputs = None
    if approval is not None:
        approved_native = SOURCE_DIR / f"combat_robot_shield_bearer_elite_anchor_{approval}_approved_native32.png"
        approved_preview = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{approval}_approved_16x.png"
        selected_native = SOURCE_DIR / f"combat_robot_shield_bearer_elite_anchor_{approval}_native32.png"
        selected_preview = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_anchor_{approval}_16x.png"
        shutil.copyfile(selected_native, approved_native)
        shutil.copyfile(selected_preview, approved_preview)
        if sha256(approved_native) != sha256(selected_native):
            raise AssertionError("Approved native copy drifted")
        if sha256(approved_preview) != sha256(selected_preview):
            raise AssertionError("Approved preview copy drifted")
        approved_outputs = {
            "native32": {
                "path": relative(approved_native),
                "sha256": sha256(approved_native),
                "rgba_sha256": reports[approval]["native32"]["rgba_sha256"],
            },
            "preview_16x": {
                "path": relative(approved_preview),
                "sha256": sha256(approved_preview),
            },
        }

    stage = (
        "anchor_approved_pending_animation_candidates"
        if approval is not None
        else "anchor_candidates_pending_first_human_gate"
    )
    report = {
        "asset": "combat_robot_shield_bearer_elite_anchor_candidates",
        "stage": stage,
        "preview_only": True,
        "approved_selection": approval,
        "approved_outputs": approved_outputs,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "builder": {"path": relative(SCRIPT), "sha256": sha256(SCRIPT)},
        "ordinary_runtime_source": {
            "path": relative(BASE_SHEET),
            "expected_sha256": EXPECTED_BASE_SHA256,
            "actual_sha256": sha256(BASE_SHEET),
            "frame_rect": [0, 0, 32, 32],
            "frame_rgba_sha256": rgba_sha(base),
            "opaque_pixels": len(base_opaque),
        },
        "contract": {
            "maximum_visible_size": [28, 28],
            "baseline_bottom": 28,
            "registered_center_x": 16,
            "ordinary_frame0_alpha_immutable": True,
            "expected_rgba_differences_per_candidate": 27,
            "expected_accent_differences": 15,
            "expected_added_alpha_pixels": 8,
            "expected_removed_alpha_pixels": 0,
            "common_a1_points": [list(point) for point in sorted(COMMON_A1)],
            "accent_points": [list(point) for point in sorted(EXPECTED_ACCENT_POINTS)],
            "authored_y7_pixels": 0,
            "shield_rect": list(SHIELD_RECT),
            "shield_alpha_opaque_pixels": EXPECTED_SHIELD_OPAQUE,
            "shield_alpha_sha256": hashlib.sha256(shield_alpha.tobytes()).hexdigest(),
            "protected_observation_slit": [[26, 12], [27, 12], [28, 12]],
            "protected_grip": [[24, 16], [24, 17], [24, 18]],
            "single_8_connected_component": True,
            "fixed_steel_palette_plus_six_purples": True,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
        },
        "candidates": reports,
        "prompt_manifest": relative(manifest_path),
    }
    report_path = PREVIEW_DIR / "combat_robot_shield_bearer_elite_anchor_report.json"
    assert_dev_output(report_path)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    anchor_manifest = {
        "asset": "combat_robot_shield_bearer_elite",
        "stage": stage,
        "approved_direction": "H1 纵脊增幅塔盾",
        "approved_selection": approval,
        "approved_outputs": approved_outputs,
        "final_human_approved": False,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "candidate_order": [spec.key for spec in CANDIDATES],
        "prompt_manifest": relative(manifest_path),
        "prompt_manifest_sha256": sha256(manifest_path),
        "report": relative(report_path),
        "report_sha256": sha256(report_path),
    }
    ANCHOR_MANIFEST.write_text(
        json.dumps(anchor_manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        "COMBAT_ROBOT_SHIELD_BEARER_ELITE_ANCHOR_PREVIEW_OK "
        f"candidates=h1a,h1b,h1c approved_selection={approval} runtime_written=false"
    )
    print(f"  {relative(report_path)}")
    print(f"  {relative(manifest_path)}")
    print(f"  {relative(ANCHOR_MANIFEST)}")


if __name__ == "__main__":
    main()
