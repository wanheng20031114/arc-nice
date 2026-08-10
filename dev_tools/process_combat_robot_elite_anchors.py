#!/usr/bin/env python3
"""Build first-gate review anchors for the elite sword combat robot.

ImageGen establishes three restrained reinforcement languages only. Generated
pixels are never resized into the native candidates. The audited ordinary
combat-robot move frame is the immutable registration source; this script only
maps its functional red/orange pixels to the approved purple ramp and authors
small gray shoulder, crown, and sword-guard reinforcements.

This script writes review assets under ``dev_assets`` only. An approved copy is
created only when a human-selected candidate is passed explicitly through
``--approve``; runtime textures, animations, scenes, and configuration are
never touched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, normalize_source


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_elite"
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
BASE_SHEET_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot.png"
)

FRAME_SIZE = 32
MAX_VISIBLE_SIZE = 28
BASELINE_Y = 28
REGISTERED_CENTER_X = 16.0
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

OUTLINE = PALETTE[0]
DEEP_SHADOW = PALETTE[1]
JOINT_SHADOW = PALETTE[2]
DARK_STEEL = PALETTE[3]
MID_STEEL = PALETTE[4]
PLATE_GRAY = PALETTE[5]
PLATE_HIGHLIGHT = PALETTE[6]

PURPLE_RAMP: tuple[tuple[int, int, int, int], ...] = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)

# Exact source colors found across the ordinary combat-robot runtime sheet.
ACCENT_MAP: dict[tuple[int, int, int, int], tuple[int, int, int, int]] = {
    (102, 25, 20, 255): PURPLE_RAMP[1],
    (255, 0, 0, 255): PURPLE_RAMP[1],
    (236, 28, 36, 255): PURPLE_RAMP[3],
    (185, 75, 80, 255): PURPLE_RAMP[2],
    (190, 48, 31, 255): PURPLE_RAMP[4],
    (239, 92, 34, 255): PURPLE_RAMP[5],
    (255, 181, 71, 255): PURPLE_RAMP[5],
}


@dataclass(frozen=True)
class CandidateSpec:
    key: str
    title: str
    summary: str
    points: dict[tuple[int, int], tuple[int, int, int, int]]


COMMON_SHOULDER_RECOLOR = {
    (10, 15): DARK_STEEL,
    (11, 15): MID_STEEL,
    (21, 16): DARK_STEEL,
}

CANDIDATES: tuple[CandidateSpec, ...] = (
    CandidateSpec(
        "a1",
        "A1 STRAIGHT",
        "平直肩盖 / 直顶框 / 矩形剑格",
        {
            **COMMON_SHOULDER_RECOLOR,
            (9, 15): OUTLINE,
            (9, 16): OUTLINE,
            (10, 14): OUTLINE,
            (21, 15): MID_STEEL,
            (22, 15): OUTLINE,
            (22, 16): OUTLINE,
            (15, 9): OUTLINE,
            (16, 9): DARK_STEEL,
            (17, 9): MID_STEEL,
            (18, 9): DARK_STEEL,
            (19, 9): OUTLINE,
            (22, 19): OUTLINE,
            (23, 19): DARK_STEEL,
            (24, 19): OUTLINE,
            (22, 22): OUTLINE,
            (23, 22): DARK_STEEL,
        },
    ),
    CandidateSpec(
        "a2",
        "A2 CHAMFER",
        "单切角肩盖 / 轻切角顶框 / 收角剑格",
        {
            **COMMON_SHOULDER_RECOLOR,
            (9, 16): OUTLINE,
            (10, 14): OUTLINE,
            (10, 15): MID_STEEL,
            (21, 15): MID_STEEL,
            (22, 16): OUTLINE,
            (16, 9): OUTLINE,
            (17, 8): DARK_STEEL,
            (18, 8): DARK_STEEL,
            (19, 9): OUTLINE,
            (22, 20): OUTLINE,
            (23, 19): DARK_STEEL,
            (24, 20): OUTLINE,
            (22, 22): OUTLINE,
            (23, 23): DARK_STEEL,
        },
    ),
    CandidateSpec(
        "a3",
        "A3 STEPPED",
        "内收阶梯肩盖 / 分段顶框 / 阶梯T形剑格",
        {
            **COMMON_SHOULDER_RECOLOR,
            (9, 16): OUTLINE,
            (10, 14): OUTLINE,
            (10, 15): MID_STEEL,
            (21, 14): OUTLINE,
            (21, 15): MID_STEEL,
            (22, 16): OUTLINE,
            (15, 9): OUTLINE,
            (16, 9): DARK_STEEL,
            (17, 8): MID_STEEL,
            (18, 8): MID_STEEL,
            (19, 9): DARK_STEEL,
            (20, 9): OUTLINE,
            (22, 20): OUTLINE,
            (23, 19): DARK_STEEL,
            (24, 19): OUTLINE,
            (22, 22): OUTLINE,
            (23, 22): DARK_STEEL,
            (24, 23): OUTLINE,
        },
    ),
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _load_base_frame() -> Image.Image:
    sheet = Image.open(BASE_SHEET_PATH).convert("RGBA")
    if sheet.size != (256, 128):
        raise ValueError(f"Unexpected ordinary combat robot sheet: {sheet.size}")
    return sheet.crop((0, 0, FRAME_SIZE, FRAME_SIZE))


def _map_accents(frame: Image.Image) -> int:
    pixels = frame.load()
    replaced = 0
    for y in range(frame.height):
        for x in range(frame.width):
            source = pixels[x, y]
            target = ACCENT_MAP.get(source)
            if target is not None:
                pixels[x, y] = target
                replaced += 1
    return replaced


def _normalize_binary_alpha(frame: Image.Image) -> Image.Image:
    result = frame.convert("RGBA")
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (
                (red, green, blue, 255) if alpha >= 128 else TRANSPARENT
            )
    return result


def _normalize_imagegen_source(image: Image.Image) -> Image.Image:
    """Apply the shared key removal plus a hard pixel-art green despill."""
    result = normalize_source(image)
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                continue
            strongest_non_green = max(red, blue)
            if green >= 64 and green >= strongest_non_green + 18:
                pixels[x, y] = TRANSPARENT
            elif green > strongest_non_green + 8:
                pixels[x, y] = (red, strongest_non_green, blue, 255)
    return result


def _build_candidate(base: Image.Image, spec: CandidateSpec) -> tuple[Image.Image, int]:
    frame = base.copy()
    accent_count = _map_accents(frame)
    pixels = frame.load()
    for point, color in spec.points.items():
        pixels[point] = color
    return _normalize_binary_alpha(frame), accent_count


def _visible_metrics(frame: Image.Image) -> dict:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Candidate is empty")
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    points = [
        (x, y)
        for y in range(frame.height)
        for x in range(frame.width)
        if frame.getpixel((x, y))[3] != 0
    ]
    center_x = sum(x + 0.5 for x, _ in points) / len(points)
    return {
        "bbox": list(bbox),
        "visible_width": width,
        "visible_height": height,
        "visible_pixels": len(points),
        "alpha_center_x": round(center_x, 3),
        "baseline_bottom": bbox[3],
    }


def _assert_native_contract(frame: Image.Image) -> dict:
    if frame.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"Expected 32x32 candidate, got {frame.size}")
    metrics = _visible_metrics(frame)
    if metrics["visible_width"] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"Candidate too wide: {metrics}")
    if metrics["visible_height"] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"Candidate too tall: {metrics}")
    if metrics["baseline_bottom"] != BASELINE_Y:
        raise AssertionError(f"Candidate baseline drift: {metrics}")
    for red, green, blue, alpha in frame.getdata():
        if alpha not in (0, 255):
            raise AssertionError("Candidate alpha must be binary")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError("Transparent candidate pixels must have zero RGB")
    return metrics


def _save_large(frame: Image.Image, path: Path, scale: int = 16) -> None:
    frame.resize(
        (frame.width * scale, frame.height * scale),
        Image.Resampling.NEAREST,
    ).save(path)


def _difference_overlay(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    pixels = result.load()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            base_visible = base.getpixel((x, y))[3] != 0
            candidate_visible = candidate.getpixel((x, y))[3] != 0
            if base_visible and candidate_visible:
                pixels[x, y] = (151, 159, 164, 255)
            elif base_visible:
                pixels[x, y] = (60, 210, 235, 255)
            elif candidate_visible:
                pixels[x, y] = (238, 80, 205, 255)
    return result


def _registration_overlay(base: Image.Image, candidate: Image.Image) -> Image.Image:
    """Overlay true candidate colors on a translucent cyan ordinary silhouette."""
    result = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    pixels = result.load()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            if base.getpixel((x, y))[3] != 0:
                pixels[x, y] = (60, 210, 235, 96)
    foreground = candidate.copy()
    foreground.putalpha(
        foreground.getchannel("A").point(lambda alpha: 224 if alpha else 0)
    )
    result.alpha_composite(foreground)
    return result


def _imagegen_thumbnail(path: Path, size: tuple[int, int]) -> Image.Image:
    source = _normalize_imagegen_source(Image.open(path))
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"ImageGen source is empty: {path}")
    subject = source.crop(bbox)
    subject.thumbnail((size[0] - 24, size[1] - 24), Image.Resampling.NEAREST)
    panel = Image.new("RGBA", size, REVIEW_PANEL)
    panel.alpha_composite(
        subject,
        ((size[0] - subject.width) // 2, (size[1] - subject.height) // 2),
    )
    return panel


def _paste_centered(board: Image.Image, image: Image.Image, box: tuple[int, int, int, int]) -> None:
    left, top, right, bottom = box
    board.alpha_composite(
        image,
        (left + (right - left - image.width) // 2, top + (bottom - top - image.height) // 2),
    )


def _review_font(size: int) -> ImageFont.ImageFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _build_comparison(
    base: Image.Image,
    candidates: dict[str, Image.Image],
    raw_paths: dict[str, Path],
) -> Path:
    cell_width = 360
    row_height = 360
    header_height = 74
    label_height = 36
    board = Image.new(
        "RGBA",
        (cell_width * 4, header_height + row_height * 3 + label_height * 3),
        REVIEW_BACKGROUND,
    )
    draw = ImageDraw.Draw(board)
    title_font = _review_font(20)
    font = _review_font(14)
    draw.text((24, 16), "精英战斗机器人 — 第一阶段锚点确认", fill=REVIEW_TEXT, font=title_font)
    draw.text(
        (24, 40),
        "ImageGen造型稿 / 注册后的32像素草稿 / 与普通版的轮廓差分",
        fill=REVIEW_MUTED,
        font=font,
    )

    columns = [("BASE", None), *[(spec.title, spec.key) for spec in CANDIDATES]]
    for column, (title, key) in enumerate(columns):
        x0 = column * cell_width
        draw.text((x0 + 16, header_height + 10), title, fill=REVIEW_TEXT, font=font)
        if key is None:
            native = base
            raw = base.resize((256, 256), Image.Resampling.NEAREST)
            overlay = _difference_overlay(base, base)
            summary = "ordinary move[0] registration source"
        else:
            native = candidates[key]
            raw = _imagegen_thumbnail(raw_paths[key], (320, 320))
            overlay = _difference_overlay(base, native)
            summary = next(spec.summary for spec in CANDIDATES if spec.key == key)
        draw.text((x0 + 16, header_height + 28), summary, fill=REVIEW_MUTED, font=font)
        _paste_centered(
            board,
            raw,
            (x0, header_height + label_height, x0 + cell_width, header_height + label_height + row_height),
        )
        native_large = native.resize((320, 320), Image.Resampling.NEAREST)
        _paste_centered(
            board,
            native_large,
            (
                x0,
                header_height + label_height + row_height + label_height,
                x0 + cell_width,
                header_height + label_height + row_height * 2 + label_height,
            ),
        )
        overlay_large = overlay.resize((320, 320), Image.Resampling.NEAREST)
        _paste_centered(
            board,
            overlay_large,
            (
                x0,
                header_height + label_height + row_height * 2 + label_height * 2,
                x0 + cell_width,
                header_height + label_height + row_height * 3 + label_height * 2,
            ),
        )
    draw.text((16, header_height), "IMAGEGEN 原稿", fill=REVIEW_TEXT, font=font)
    draw.text((16, header_height + label_height + row_height), "原生32×32草稿（16倍）", fill=REVIEW_TEXT, font=font)
    draw.text((16, header_height + label_height * 2 + row_height * 2), "轮廓差分（16倍）", fill=REVIEW_TEXT, font=font)
    path = PREVIEW_DIR / "combat_robot_elite_anchor_comparison.png"
    board.save(path)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description="构建精英战斗机器人第一阶段锚点候选")
    parser.add_argument(
        "--approve",
        choices=tuple(spec.key for spec in CANDIDATES),
        help="在用户确认后提升指定候选；省略时只生成评审素材",
    )
    args = parser.parse_args()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    base = _normalize_binary_alpha(_load_base_frame())
    base_metrics = _assert_native_contract(base)
    allowed_palette = set(PALETTE[:8]) | set(PURPLE_RAMP) | {TRANSPARENT}

    raw_paths = {
        spec.key: SOURCE_DIR / f"combat_robot_elite_anchor_{spec.key}_imagegen.png"
        for spec in CANDIDATES
    }
    missing = [str(path) for path in raw_paths.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"Missing ImageGen anchors: {missing}")

    candidates: dict[str, Image.Image] = {}
    report_candidates: dict[str, dict] = {}
    for spec in CANDIDATES:
        raw_path = raw_paths[spec.key]
        transparent_path = SOURCE_DIR / f"combat_robot_elite_anchor_{spec.key}_transparent.png"
        normalized_source = _normalize_imagegen_source(Image.open(raw_path))
        normalized_source.save(transparent_path)
        source_analysis = analyze_image(normalized_source)

        candidate, accent_count = _build_candidate(base, spec)
        unexpected = sorted(set(candidate.getdata()) - allowed_palette)
        if unexpected:
            raise AssertionError(f"{spec.key} uses colors outside the fixed palette: {unexpected}")
        metrics = _assert_native_contract(candidate)
        native_path = SOURCE_DIR / f"combat_robot_elite_anchor_{spec.key}_native32.png"
        candidate.save(native_path)
        preview_path = PREVIEW_DIR / f"combat_robot_elite_anchor_{spec.key}_16x.png"
        _save_large(candidate, preview_path)
        mask_path = PREVIEW_DIR / f"combat_robot_elite_anchor_{spec.key}_mask_diff_16x.png"
        _save_large(_difference_overlay(base, candidate), mask_path)
        overlay_path = PREVIEW_DIR / f"combat_robot_elite_anchor_{spec.key}_overlay_16x.png"
        _save_large(_registration_overlay(base, candidate), overlay_path)
        candidates[spec.key] = candidate
        report_candidates[spec.key] = {
            "title": spec.title,
            "summary": spec.summary,
            "imagegen_source": _relative(raw_path),
            "transparent_source": _relative(transparent_path),
            "native": _relative(native_path),
            "preview_16x": _relative(preview_path),
            "overlay_16x": _relative(overlay_path),
            "mask_difference_16x": _relative(mask_path),
            "source_grid_analysis": source_analysis,
            "metrics": metrics,
            "accent_pixels_mapped": accent_count,
            "authored_reinforcement_points": len(spec.points),
            "rgba_sha256": _sha256(native_path),
        }

    comparison_path = _build_comparison(base, candidates, raw_paths)
    approved_outputs: dict[str, str] | None = None
    if args.approve is not None:
        approved_native_path = (
            SOURCE_DIR / f"combat_robot_elite_anchor_{args.approve}_approved_native32.png"
        )
        approved_preview_path = (
            PREVIEW_DIR / f"combat_robot_elite_anchor_{args.approve}_approved_16x.png"
        )
        shutil.copyfile(
            SOURCE_DIR / f"combat_robot_elite_anchor_{args.approve}_native32.png",
            approved_native_path,
        )
        shutil.copyfile(
            PREVIEW_DIR / f"combat_robot_elite_anchor_{args.approve}_16x.png",
            approved_preview_path,
        )
        approved_outputs = {
            "native": _relative(approved_native_path),
            "preview_16x": _relative(approved_preview_path),
        }

    report = {
        "asset": "combat_robot_elite_anchor_candidates",
        "stage": "first_human_gate",
        "approval": args.approve,
        "approved_outputs": approved_outputs,
        "pixel_policy": "ImageGen pixels are never downscaled into native review art",
        "registration_source": _relative(BASE_SHEET_PATH),
        "registration_frame": [0, 0, 32, 32],
        "contract": {
            "frame_size": [32, 32],
            "max_visible_size": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "baseline_bottom": BASELINE_Y,
            "registered_center_x": REGISTERED_CENTER_X,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "fixed_palette": [list(color) for color in sorted(allowed_palette)],
        },
        "base_metrics": base_metrics,
        "candidates": report_candidates,
        "comparison": _relative(comparison_path),
    }
    report_path = enemy_asset_report_path("combat_robot_elite_anchor_report.json")
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
