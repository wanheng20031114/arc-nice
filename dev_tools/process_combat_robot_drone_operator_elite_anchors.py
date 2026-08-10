#!/usr/bin/env python3
"""Build first-gate anchor previews for the elite drone operator.

The current ordinary runtime frame is the only source of native pixels.
ImageGen drafts are displayed as structural references, never sampled into the
32 px candidates.  This tool is intentionally preview-only and refuses every
output outside ``dev_assets``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "combat_robot_drone_operator_elite"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"
BASE_SHEET = (
    ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_drone_operator.png"
)

EXPECTED_BASE_SHA256 = "9f987244da55ed3d89bae38a3eda40998518dcd3935f2bb7a1551eb94cd15395"
EXPECTED_BASE_SIZE = (256, 96)
FRAME_SIZE = 32
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BG = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)
DELTA_NEW = (255, 67, 190, 255)
DELTA_ACCENT = (157, 78, 221, 255)

OUTLINE = PALETTE[0]
DEEP_SHADOW = PALETTE[1]
JOINT_SHADOW = PALETTE[2]
DARK_STEEL = PALETTE[3]
MID_STEEL = PALETTE[4]
PLATE_GRAY = PALETTE[5]

PURPLE_RAMP = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)
ACCENT_MAP = {
    PALETTE[8]: PURPLE_RAMP[1],
    (255, 0, 0, 255): PURPLE_RAMP[3],
    PALETTE[9]: PURPLE_RAMP[3],
    PALETTE[10]: PURPLE_RAMP[4],
    PALETTE[11]: PURPLE_RAMP[5],
}
OLD_ACCENTS = set(ACCENT_MAP)
ALLOWED_COLORS = set(PALETTE[:8]) | set(PURPLE_RAMP)

# A1 family identity: a crown extension that touches the ordinary y=8 top
# edge, plus shallow one-pixel shoulder caps.  There are deliberately no new
# pixels at y=7, preventing the detached gray crown artifact found earlier.
COMMON_A1 = {
    (10, 8): OUTLINE,
    (21, 8): OUTLINE,
    (9, 12): OUTLINE,
    (10, 12): MID_STEEL,
    (21, 12): MID_STEEL,
    (22, 12): OUTLINE,
    (9, 13): OUTLINE,
    (22, 13): OUTLINE,
}


@dataclass(frozen=True)
class Candidate:
    key: str
    title: str
    subtitle: str
    additions: dict[tuple[int, int], tuple[int, int, int, int]]


CANDIDATES = (
    Candidate(
        "o1",
        "O1  上置指挥导轨",
        "短导轨 + 天线护耳；轮廓集中在控制器右上",
        {
            (23, 13): DARK_STEEL,
            (24, 13): OUTLINE,
            (24, 14): OUTLINE,
            (23, 15): MID_STEEL,
            (24, 15): OUTLINE,
        },
    ),
    Candidate(
        "o2",
        "O2  侧框加固终端",
        "薄 U 形侧框 + 握持护圈；控制器主体不变",
        {
            (24, 15): OUTLINE,
            (25, 15): OUTLINE,
            (25, 16): DARK_STEEL,
            (25, 17): MID_STEEL,
            (25, 18): OUTLINE,
            (22, 19): OUTLINE,
            (23, 19): DARK_STEEL,
            (24, 19): MID_STEEL,
            (25, 19): OUTLINE,
        },
    ),
    Candidate(
        "o3",
        "O3  下置信号增幅器",
        "贴底中空稳定模块；不悬垂、不进入腿区",
        {
            (20, 21): OUTLINE,
            (21, 21): MID_STEEL,
            (22, 21): OUTLINE,
            (20, 22): OUTLINE,
            (22, 22): DARK_STEEL,
            (23, 22): OUTLINE,
            (20, 23): OUTLINE,
            (21, 23): OUTLINE,
            (22, 23): OUTLINE,
            (23, 23): OUTLINE,
        },
    ),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def assert_dev_path(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Refusing non-dev output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    assert_dev_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def load_base() -> Image.Image:
    if sha256(BASE_SHEET) != EXPECTED_BASE_SHA256:
        raise AssertionError("Ordinary operator runtime sheet SHA changed")
    sheet = Image.open(BASE_SHEET).convert("RGBA")
    if sheet.size != EXPECTED_BASE_SIZE:
        raise AssertionError(f"Unexpected ordinary sheet size: {sheet.size}")
    return sheet.crop((0, 0, FRAME_SIZE, FRAME_SIZE))


def map_accents(frame: Image.Image) -> tuple[Image.Image, set[tuple[int, int]]]:
    result = frame.copy()
    pixels = result.load()
    points: set[tuple[int, int]] = set()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            source = pixels[x, y]
            if source in ACCENT_MAP:
                pixels[x, y] = ACCENT_MAP[source]
                points.add((x, y))
    return result, points


def build_candidate(base: Image.Image, spec: Candidate) -> tuple[Image.Image, dict]:
    frame, accent_points = map_accents(base)
    additions = dict(COMMON_A1)
    overlap = set(additions) & set(spec.additions)
    if overlap:
        raise AssertionError(f"{spec.key} duplicates common points: {sorted(overlap)}")
    additions.update(spec.additions)
    pixels = frame.load()
    for point, color in additions.items():
        if base.getpixel(point)[3] != 0:
            raise AssertionError(f"{spec.key} addition overwrites ordinary pixel {point}")
        pixels[point] = color
    metrics = audit_candidate(base, frame, spec, additions, accent_points)
    return frame, metrics


def opaque_points(image: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] == 255
    }


def component_count(points: set[tuple[int, int]]) -> int:
    remaining = set(points)
    count = 0
    while remaining:
        count += 1
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
    return count


def audit_candidate(
    base: Image.Image,
    frame: Image.Image,
    spec: Candidate,
    additions: dict[tuple[int, int], tuple[int, int, int, int]],
    accent_points: set[tuple[int, int]],
) -> dict:
    for pixel in frame.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{spec.key} has non-binary alpha")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{spec.key} has dirty transparent RGB")
        if pixel[3] and pixel not in ALLOWED_COLORS:
            raise AssertionError(f"{spec.key} uses unapproved color {pixel}")
    base_opaque = opaque_points(base)
    final_opaque = opaque_points(frame)
    if not base_opaque <= final_opaque:
        raise AssertionError(f"{spec.key} deleted ordinary alpha")
    if final_opaque - base_opaque != set(additions):
        raise AssertionError(f"{spec.key} alpha delta escaped the whitelist")
    for point in base_opaque:
        before = base.getpixel(point)
        after = frame.getpixel(point)
        expected = ACCENT_MAP.get(before, before)
        if after != expected:
            raise AssertionError(f"{spec.key} changed ordinary pixel {point}")
    if any(pixel in OLD_ACCENTS for pixel in frame.getdata()):
        raise AssertionError(f"{spec.key} retains red/orange accents")
    if {(x, y) for x, y in additions if y == 7}:
        raise AssertionError(f"{spec.key} introduced a detached y=7 crown")
    if {(10, 8), (21, 8)} - set(additions):
        raise AssertionError(f"{spec.key} lost the attached crown endpoints")
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{spec.key} is empty")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if width > 28 or height > 28 or bbox[3] != 28:
        raise AssertionError(f"{spec.key} violates 28x28/y=28: {bbox}")
    components = component_count(final_opaque)
    if components != 1:
        raise AssertionError(f"{spec.key} has {components} components")
    return {
        "bbox": list(bbox),
        "visible_size": [width, height],
        "baseline_y": bbox[3],
        "registered_center_x": 16,
        "opaque_pixels": len(final_opaque),
        "ordinary_pixels_preserved": len(base_opaque),
        "accent_points": [list(point) for point in sorted(accent_points)],
        "added_points": [list(point) for point in sorted(additions)],
        "added_pixel_count": len(additions),
        "new_y7_pixels": 0,
        "connected_components_8": components,
        "red_orange_remaining": 0,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
    }


def on_background(image: Image.Image, scale: int = 1) -> Image.Image:
    rgba = image.convert("RGBA")
    if scale != 1:
        rgba = rgba.resize((rgba.width * scale, rgba.height * scale), Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", rgba.size, REVIEW_BG)
    canvas.alpha_composite(rgba)
    return canvas


def remove_green_for_review(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            red, green, blue, _alpha = pixels[x, y]
            if green >= 80 and green >= red + 20 and green >= blue + 20:
                pixels[x, y] = TRANSPARENT
            elif green > max(red, blue):
                # Deterministic despill for antialiased reference edges.  These
                # pixels remain review-only and never enter a native sprite.
                pixels[x, y] = (red, max(red, blue), blue, 255)
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"ImageGen reference became empty: {path}")
    return image.crop(bbox)


def nearest_fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    ratio = min(size[0] / image.width, size[1] / image.height)
    scaled = image.resize(
        (max(1, round(image.width * ratio)), max(1, round(image.height * ratio))),
        Image.Resampling.NEAREST,
    )
    canvas = Image.new("RGBA", size, REVIEW_PANEL)
    canvas.alpha_composite(scaled, ((size[0] - scaled.width) // 2, (size[1] - scaled.height) // 2))
    return canvas


def make_overlay(base: Image.Image, candidate: Image.Image) -> Image.Image:
    base_scaled = on_background(base, 16)
    elite = candidate.resize((512, 512), Image.Resampling.NEAREST)
    elite.putalpha(128)
    base_scaled.alpha_composite(elite)
    return base_scaled


def make_delta(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", (32, 32), TRANSPARENT)
    for y in range(32):
        for x in range(32):
            before = base.getpixel((x, y))
            after = candidate.getpixel((x, y))
            if before == after:
                if before[3]:
                    result.putpixel((x, y), (82, 88, 94, 255))
            elif before[3] == 0 and after[3]:
                result.putpixel((x, y), DELTA_NEW)
            else:
                result.putpixel((x, y), DELTA_ACCENT)
    return on_background(result, 16)


def exact_palette_frame(image: Image.Image, palette: list[tuple[int, int, int]]) -> Image.Image:
    lookup = {color: index for index, color in enumerate(palette)}
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    flat = []
    for pixel in rgb.getdata():
        if pixel not in lookup:
            raise AssertionError(f"GIF color missing from exact palette: {pixel}")
        flat.append(lookup[pixel])
    result.putdata(flat)
    raw_palette: list[int] = []
    for color in palette:
        raw_palette.extend(color)
    raw_palette.extend([0] * (768 - len(raw_palette)))
    result.putpalette(raw_palette)
    return result


def save_facing_gif(candidate: Image.Image, path: Path) -> None:
    right = on_background(candidate, 16)
    left = right.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    colors = sorted(set(right.convert("RGB").getdata()) | set(left.convert("RGB").getdata()))
    frames = [exact_palette_frame(right, colors), exact_palette_frame(left, colors)]
    assert_dev_path(path)
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=500, loop=0, disposal=2)


def font() -> ImageFont.ImageFont:
    for candidate in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if candidate.is_file():
            return ImageFont.truetype(str(candidate), 25)
    return ImageFont.load_default()


def build_comparison(
    base: Image.Image,
    built: dict[str, Image.Image],
    transparent_refs: dict[str, Image.Image],
) -> Image.Image:
    board = Image.new("RGBA", (2100, 2600), REVIEW_BG)
    draw = ImageDraw.Draw(board)
    text_font = font()
    draw.text((42, 28), "精英爆炸无人机操作员 · 第一门强化锚点", fill=REVIEW_TEXT, font=text_font)
    draw.text((42, 70), "ImageGen仅作结构语言；Native候选全部从当前普通运行帧确定性重建", fill=REVIEW_MUTED, font=text_font)
    columns = [42, 724, 1406]
    for column, spec in zip(columns, CANDIDATES):
        draw.text((column, 126), spec.title, fill=REVIEW_TEXT, font=text_font)
        draw.text((column, 164), spec.subtitle, fill=REVIEW_MUTED, font=text_font)
        ref = nearest_fit(transparent_refs[spec.key], (640, 640))
        board.alpha_composite(ref, (column, 214))
        candidate_16x = on_background(built[spec.key], 16)
        board.alpha_composite(candidate_16x, (column + 64, 900))
        mirrored = candidate_16x.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        board.alpha_composite(mirrored, (column + 64, 1422))
        draw.text((column + 64, 866), "Native 32px → 16×", fill=REVIEW_MUTED, font=text_font)
        draw.text((column + 64, 1388), "水平镜像预览", fill=REVIEW_MUTED, font=text_font)
        board.alpha_composite(make_delta(base, built[spec.key]), (column + 64, 2020))
        draw.text(
            (column + 64, 1986),
            "普通差分：灰=继承 / 紫=功能色 / 粉=新增结构",
            fill=REVIEW_MUTED,
            font=text_font,
        )
    return board


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        choices=[spec.key for spec in CANDIDATES],
        help="Record the explicit first-gate human choice without writing runtime assets.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    base = load_base()
    imagegen_paths = {
        spec.key: SOURCE_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_imagegen.png"
        for spec in CANDIDATES
    }
    for path in imagegen_paths.values():
        if not path.is_file():
            raise FileNotFoundError(path)

    built: dict[str, Image.Image] = {}
    metrics: dict[str, dict] = {}
    outputs: dict[str, dict] = {}
    transparent_refs: dict[str, Image.Image] = {}
    for spec in CANDIDATES:
        candidate, audit = build_candidate(base, spec)
        built[spec.key] = candidate
        metrics[spec.key] = audit
        native = SOURCE_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_native32.png"
        preview = PREVIEW_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_16x.png"
        mirrored = PREVIEW_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_mirrored_16x.png"
        overlay = PREVIEW_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_ordinary_overlay_16x.png"
        delta = PREVIEW_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_ordinary_delta_16x.png"
        facing_pair = PREVIEW_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_facing_pair.png"
        facing_gif = PREVIEW_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_facing.gif"
        transparent_ref_path = SOURCE_DIR / f"combat_robot_drone_operator_elite_anchor_{spec.key}_transparent_reference.png"
        ref = remove_green_for_review(imagegen_paths[spec.key])
        transparent_refs[spec.key] = ref
        save_png(ref, transparent_ref_path)
        save_png(candidate, native)
        right = on_background(candidate, 16)
        left = right.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        save_png(right, preview)
        save_png(left, mirrored)
        save_png(make_overlay(base, candidate), overlay)
        save_png(make_delta(base, candidate), delta)
        pair = Image.new("RGBA", (1036, 512), REVIEW_PANEL)
        pair.alpha_composite(right, (0, 0))
        pair.alpha_composite(left, (524, 0))
        save_png(pair, facing_pair)
        save_facing_gif(candidate, facing_gif)
        outputs[spec.key] = {
            "native": {"path": rel(native), "sha256": sha256(native), "rgba_sha256": rgba_sha(candidate)},
            "preview_16x": {"path": rel(preview), "sha256": sha256(preview)},
            "mirrored_16x": {"path": rel(mirrored), "sha256": sha256(mirrored)},
            "overlay": {"path": rel(overlay), "sha256": sha256(overlay)},
            "delta": {"path": rel(delta), "sha256": sha256(delta)},
            "facing_pair": {"path": rel(facing_pair), "sha256": sha256(facing_pair)},
            "facing_gif": {"path": rel(facing_gif), "sha256": sha256(facing_gif)},
            "imagegen_reference": {"path": rel(imagegen_paths[spec.key]), "sha256": sha256(imagegen_paths[spec.key])},
            "transparent_reference": {"path": rel(transparent_ref_path), "sha256": sha256(transparent_ref_path)},
        }

    comparison = PREVIEW_DIR / "combat_robot_drone_operator_elite_anchor_comparison.png"
    save_png(build_comparison(base, built, transparent_refs), comparison)
    manifest_path = enemy_asset_report_path("combat_robot_drone_operator_elite_anchor_manifest.json")
    existing_selection: str | None = None
    if manifest_path.is_file():
        existing_payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        existing_approval = existing_payload.get("approved_selection")
        if isinstance(existing_approval, dict):
            existing_selection = str(existing_approval.get("selection", "")) or None
    selection = args.approve or existing_selection
    if args.approve and existing_selection and args.approve != existing_selection:
        raise AssertionError(
            f"Anchor already approved as {existing_selection}; refusing silent replacement"
        )
    approved_selection = None
    if selection:
        approved_native = (
            SOURCE_DIR
            / f"combat_robot_drone_operator_elite_anchor_{selection}_approved_native32.png"
        )
        approved_preview = (
            PREVIEW_DIR
            / f"combat_robot_drone_operator_elite_anchor_{selection}_approved_16x.png"
        )
        save_png(built[selection], approved_native)
        save_png(on_background(built[selection], 16), approved_preview)
        approved_selection = {
            "selection": selection,
            "native": {
                "path": rel(approved_native),
                "sha256": sha256(approved_native),
                "rgba_sha256": rgba_sha(built[selection]),
            },
            "preview_16x": {
                "path": rel(approved_preview),
                "sha256": sha256(approved_preview),
            },
        }
    report = {
        "stage": (
            "anchor_approved_pending_animation_candidates"
            if approved_selection
            else "anchor_candidates_pending_first_human_gate"
        ),
        "approved_selection": approved_selection,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "ordinary_runtime_source": {
            "path": rel(BASE_SHEET),
            "expected_sha256": EXPECTED_BASE_SHA256,
            "actual_sha256": sha256(BASE_SHEET),
            "frame_rect": [0, 0, 32, 32],
            "pixel_grid_analysis": analyze_image(base),
        },
        "construction": "current runtime frame0 + fixed accent map + explicit transparent-point attachments",
        "registered_center": [16, 16],
        "maximum_visible_size": [28, 28],
        "baseline_y": 28,
        "common_a1_points": [list(point) for point in sorted(COMMON_A1)],
        "candidates": {
            spec.key: {
                "title": spec.title,
                "subtitle": spec.subtitle,
                "candidate_only_points": [list(point) for point in sorted(spec.additions)],
                "audit": metrics[spec.key],
                "outputs": outputs[spec.key],
            }
            for spec in CANDIDATES
        },
        "comparison": {"path": rel(comparison), "sha256": sha256(comparison)},
        "script": {"path": rel(SCRIPT_PATH), "sha256": sha256(SCRIPT_PATH)},
    }
    report_path = enemy_asset_report_path("combat_robot_drone_operator_elite_anchor_report.json")
    for path, payload in ((report_path, report), (manifest_path, report)):
        assert_dev_path(path)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(
        "COMBAT_ROBOT_DRONE_OPERATOR_ELITE_ANCHOR_PREVIEW_OK "
        f"base={EXPECTED_BASE_SHA256} candidates={','.join(spec.key for spec in CANDIDATES)}"
    )


if __name__ == "__main__":
    main()
