#!/usr/bin/env python3
"""Build first-gate review anchors for the elite ninja combat robot.

ImageGen supplies wrist-lock shape language only.  Native candidates are rebuilt
from the current ordinary runtime move frame, with an explicit accent map and
small gray add/recolor masks.  This script is preview-only: every generated
artifact stays under dev_assets, and no runtime/config/scene file is touched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw, ImageFont, ImageSequence

from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_ninja_elite"
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
RUNTIME_SHEET = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_ninja.png"
)

EXPECTED_RUNTIME_SHA256 = "f34f15083e48af0179c1d2669a3d22bdfdb33de266d9373cbaa9defa2b434ceb"
EXPECTED_IMAGEGEN_SHA256 = {
    "n1a": "fef75142ba9338d3ca07347247822f2b8253801b050f65d625b1f4d6b2eec596",
    "n1b": "d138a24c35c15adff3cd6d38b6a91b587258b42bd85de913a9be70ae40eb92d0",
    "n1c": "af4457740b5cdfade3a4bde3954388f1a9956d44a525dc1a6ad474e9e6e222e2",
}

FRAME_SIZE = 40
MAX_VISIBLE_SIZE = 28
REGISTERED_CENTER_X = 20
BASELINE_Y = 32
SAFETY_MARGIN = 6
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

# Steel palette inherited byte-for-byte from the ordinary ninja runtime sheet.
OUTLINE = (21, 22, 19, 255)
DEEP_SHADOW = (29, 28, 30, 255)
DARK_STEEL = (55, 59, 63, 255)
MID_STEEL = (82, 88, 94, 255)
PLATE_GRAY = (112, 121, 128, 255)
PLATE_HIGHLIGHT = (151, 159, 164, 255)
PALE_STEEL = (190, 196, 198, 255)
WHITE_STEEL = (226, 229, 226, 255)

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
OLD_ACCENTS = set(ACCENT_MAP)

# The 32px A1 family reinforcement translated by (+4,+4) into the ninja 40px cell.
# The crown touches the existing y=12 top edge; y=11 must remain ordinary pixels.
COMMON_A1 = {
    (14, 12): OUTLINE,
    (25, 12): OUTLINE,
    (13, 16): OUTLINE,
    (14, 16): MID_STEEL,
    (25, 16): MID_STEEL,
    (26, 16): OUTLINE,
    (13, 17): OUTLINE,
    (26, 17): OUTLINE,
}


@dataclass(frozen=True)
class CandidateSpec:
    key: str
    title: str
    summary: str
    wrist_points: dict[tuple[int, int], tuple[int, int, int, int]]


CANDIDATES = (
    CandidateSpec(
        "n1a",
        "N1A 对称平直矩形双腕闭环",
        "借普通护格补齐冷灰闭合框，轮廓最完整、强化感最明显。",
        {
            (27, 19): PLATE_GRAY,
            (28, 19): OUTLINE,
            (25, 20): PLATE_GRAY,
            (11, 22): OUTLINE,
            (12, 22): PLATE_GRAY,
            (25, 22): MID_STEEL,
            (14, 23): OUTLINE,
            (27, 23): PLATE_GRAY,
            (28, 23): OUTLINE,
            (14, 24): MID_STEEL,
            (13, 25): PLATE_GRAY,
            (14, 25): OUTLINE,
        },
    ),
    CandidateSpec(
        "n1b",
        "N1B 前后腕反向错位单像素卡扣",
        "从完整框中收掉四个端点，保留前后反向错位的阶梯卡扣。",
        {
            (27, 19): PLATE_GRAY,
            (25, 20): PLATE_GRAY,
            (12, 22): PLATE_GRAY,
            (25, 22): MID_STEEL,
            (14, 23): OUTLINE,
            (27, 23): PLATE_GRAY,
            (14, 24): MID_STEEL,
            (13, 25): PLATE_GRAY,
        },
    ),
    CandidateSpec(
        "n1c",
        "N1C 最紧凑双端盖锁环",
        "每腕只保留贴手的两像素端盖，速度轮廓最克制。",
        {
            (25, 20): PLATE_GRAY,
            (25, 22): MID_STEEL,
            (14, 24): MID_STEEL,
            (13, 25): PLATE_GRAY,
        },
    ),
)

ALLOWED_COLORS = {
    TRANSPARENT,
    OUTLINE,
    DEEP_SHADOW,
    DARK_STEEL,
    MID_STEEL,
    PLATE_GRAY,
    PLATE_HIGHLIGHT,
    PALE_STEEL,
    WHITE_STEEL,
    *PURPLE_RAMP,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def ensure_review_path(path: Path) -> None:
    resolved = path.resolve()
    if not (
        resolved.is_relative_to(SOURCE_DIR.resolve())
        or resolved.is_relative_to(PREVIEW_DIR.resolve())
        or is_enemy_asset_report_path(path)
    ):
        raise AssertionError(f"Preview-only builder refused non-dev_assets output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_review_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def load_base() -> Image.Image:
    actual = sha256(RUNTIME_SHEET)
    if actual != EXPECTED_RUNTIME_SHA256:
        raise AssertionError(
            f"Ordinary ninja runtime SHA drifted: expected {EXPECTED_RUNTIME_SHA256}, got {actual}"
        )
    sheet = Image.open(RUNTIME_SHEET).convert("RGBA")
    if sheet.size != (320, 120):
        raise AssertionError(f"Unexpected ordinary ninja sheet size: {sheet.size}")
    return sheet.crop((0, 0, FRAME_SIZE, FRAME_SIZE))


def load_transparent_imagegen_source(
    source_path: Path, transparent_path: Path
) -> tuple[Image.Image, Path]:
    alpha_source = transparent_path if transparent_path.is_file() else source_path
    with Image.open(alpha_source) as opened:
        image = opened.convert("RGBA")
    alpha_min, alpha_max = image.getchannel("A").getextrema()
    if alpha_min == 255:
        raise AssertionError(
            f"{relative(alpha_source)} has no transparent Alpha pixels; "
            "provide a native-transparent ImageGen source or a pre-existing, "
            "approved matching Alpha derivative"
        )
    if alpha_max == 0:
        raise AssertionError(f"{relative(alpha_source)} is fully transparent")
    return image, alpha_source


def audit_reference_alpha(image: Image.Image, label: str) -> None:
    alpha_min, alpha_max = image.getchannel("A").getextrema()
    if alpha_min == 255:
        raise AssertionError(f"{label}: reference has no transparent Alpha pixels")
    if alpha_max == 0:
        raise AssertionError(f"{label}: reference is fully transparent")


def map_accents(frame: Image.Image) -> set[tuple[int, int]]:
    mapped: set[tuple[int, int]] = set()
    pixels = frame.load()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            target = ACCENT_MAP.get(pixels[x, y])
            if target is not None:
                pixels[x, y] = target
                mapped.add((x, y))
    return mapped


def build_candidate(base: Image.Image, spec: CandidateSpec) -> tuple[Image.Image, set[tuple[int, int]]]:
    candidate = base.copy()
    accent_points = map_accents(candidate)
    for point, color in COMMON_A1.items():
        if base.getpixel(point) != TRANSPARENT:
            raise AssertionError(f"COMMON_A1 must be add-only at {point}")
        candidate.putpixel(point, color)
    for point, color in spec.wrist_points.items():
        candidate.putpixel(point, color)
    return candidate, accent_points


def visible_points(image: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] == 255
    }


def components(image: Image.Image) -> list[set[tuple[int, int]]]:
    remaining = visible_points(image)
    result: list[set[tuple[int, int]]] = []
    while remaining:
        start = remaining.pop()
        component = {start}
        queue = deque([start])
        while queue:
            x, y = queue.popleft()
            for point in (
                (x - 1, y),
                (x + 1, y),
                (x, y - 1),
                (x, y + 1),
                (x - 1, y - 1),
                (x + 1, y - 1),
                (x - 1, y + 1),
                (x + 1, y + 1),
            ):
                if point in remaining:
                    remaining.remove(point)
                    component.add(point)
                    queue.append(point)
        result.append(component)
    return result


def audit_candidate(
    base: Image.Image,
    candidate: Image.Image,
    spec: CandidateSpec,
    accent_points: set[tuple[int, int]],
) -> dict[str, object]:
    if candidate.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"{spec.key}: native frame is not 40x40")
    if len(accent_points) != 11:
        raise AssertionError(f"{spec.key}: expected 11 source accent pixels, got {len(accent_points)}")

    base_alpha = visible_points(base)
    candidate_alpha = visible_points(candidate)
    allowed_change_points = accent_points | set(COMMON_A1) | set(spec.wrist_points)
    changed = {
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if candidate.getpixel((x, y)) != base.getpixel((x, y))
    }
    if not changed <= allowed_change_points:
        raise AssertionError(f"{spec.key}: changed pixels outside whitelist: {sorted(changed - allowed_change_points)}")
    if not allowed_change_points <= changed:
        raise AssertionError(f"{spec.key}: declared points made no change: {sorted(allowed_change_points - changed)}")
    if base_alpha - candidate_alpha:
        raise AssertionError(f"{spec.key}: deleted ordinary alpha pixels")
    added_alpha = candidate_alpha - base_alpha
    expected_added = {
        point for point in set(COMMON_A1) | set(spec.wrist_points) if point not in base_alpha
    }
    if added_alpha != expected_added:
        raise AssertionError(f"{spec.key}: authored alpha mismatch")
    if any(y == 11 for _, y in added_alpha):
        raise AssertionError(f"{spec.key}: added forbidden floating crown pixels at y=11")
    if any(candidate.getpixel(point) not in PURPLE_RAMP for point in accent_points):
        raise AssertionError(f"{spec.key}: source accent mask was not fully purple-mapped")
    if any(pixel in OLD_ACCENTS for pixel in candidate.getdata()):
        raise AssertionError(f"{spec.key}: old red/orange remains")
    if any(pixel not in ALLOWED_COLORS for pixel in candidate.getdata()):
        unexpected = sorted(set(candidate.getdata()) - ALLOWED_COLORS)
        raise AssertionError(f"{spec.key}: colors outside fixed steel/purple palette: {unexpected}")
    for red, green, blue, alpha in candidate.getdata():
        if alpha not in (0, 255):
            raise AssertionError(f"{spec.key}: alpha is not binary")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{spec.key}: transparent RGB is dirty")

    bbox = candidate.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{spec.key}: empty candidate")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{spec.key}: bbox exceeds 28x28: {bbox}")
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"{spec.key}: baseline drift: {bbox}")
    if bbox[0] < SAFETY_MARGIN or bbox[1] < SAFETY_MARGIN:
        raise AssertionError(f"{spec.key}: enters leading 6px safety margin: {bbox}")
    if bbox[2] > FRAME_SIZE - SAFETY_MARGIN or bbox[3] > FRAME_SIZE - SAFETY_MARGIN:
        raise AssertionError(f"{spec.key}: enters trailing 6px safety margin: {bbox}")
    component_sizes = sorted((len(item) for item in components(candidate)), reverse=True)
    if component_sizes != [len(candidate_alpha)]:
        raise AssertionError(f"{spec.key}: disconnected sprite components: {component_sizes}")

    # The blades, arms, body and legs are immutable outside the declared masks.
    inherited_points = base_alpha - accent_points - set(spec.wrist_points)
    for point in inherited_points:
        if point not in COMMON_A1 and candidate.getpixel(point) != base.getpixel(point):
            raise AssertionError(f"{spec.key}: changed ordinary geometry/color at {point}")

    return {
        "bbox": list(bbox),
        "visible_size": [width, height],
        "registered_center_x": REGISTERED_CENTER_X,
        "baseline_bottom": bbox[3],
        "safety_margin_px": SAFETY_MARGIN,
        "source_accent_pixels_mapped": len(accent_points),
        "common_a1_added_pixels": len(COMMON_A1),
        "wrist_authored_points": len(spec.wrist_points),
        "added_alpha_pixels": len(added_alpha),
        "recolored_opaque_pixels": len(changed & base_alpha),
        "changed_pixels": len(changed),
        "connected_components": len(component_sizes),
        "rgba_sha256": rgba_sha(candidate),
        "forbidden_y11_added": 0,
    }


def on_background(image: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    canvas.alpha_composite(image)
    return canvas


def nearest(image: Image.Image, scale: int) -> Image.Image:
    return image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)


def delta_image(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, TRANSPARENT)
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            source = base.getpixel((x, y))
            target = candidate.getpixel((x, y))
            if source == target and source[3]:
                result.putpixel((x, y), (55, 59, 63, 180))
            elif source[3] == 0 and target[3]:
                result.putpixel((x, y), (238, 80, 205, 255))
            elif source[3] and target[3]:
                result.putpixel((x, y), (197, 138, 255, 255))
            elif source[3] and target[3] == 0:
                result.putpixel((x, y), (60, 210, 235, 255))
    return result


def registration_overlay(base: Image.Image, candidate: Image.Image) -> Image.Image:
    result = Image.new("RGBA", base.size, TRANSPARENT)
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            if base.getpixel((x, y))[3]:
                result.putpixel((x, y), (60, 210, 235, 88))
    foreground = candidate.copy()
    foreground.putalpha(foreground.getchannel("A").point(lambda alpha: 224 if alpha else 0))
    result.alpha_composite(foreground)
    return result


def fixed_palette(images: list[Image.Image]) -> tuple[list[tuple[int, int, int]], dict[tuple[int, int, int], int]]:
    colors: list[tuple[int, int, int]] = []
    for image in images:
        for color in image.convert("RGB").getdata():
            if color not in colors:
                colors.append(color)
    if len(colors) > 256:
        raise AssertionError(f"Exact review GIF needs {len(colors)} colors")
    return colors, {color: index for index, color in enumerate(colors)}


def to_paletted(
    image: Image.Image,
    colors: list[tuple[int, int, int]],
    indices: dict[tuple[int, int, int], int],
) -> Image.Image:
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    result.putpalette(palette)
    result.putdata([indices[color] for color in rgb.getdata()])
    return result


def save_facing_gif(candidate: Image.Image, path: Path) -> dict[str, object]:
    ensure_review_path(path)
    right = nearest(on_background(candidate), 16).convert("RGB")
    left = nearest(on_background(candidate.transpose(Image.Transpose.FLIP_LEFT_RIGHT)), 16).convert("RGB")
    expected = [right, left]
    colors, indices = fixed_palette(expected)
    paletted = [to_paletted(frame, colors, indices) for frame in expected]
    path.parent.mkdir(parents=True, exist_ok=True)
    paletted[0].save(
        path,
        save_all=True,
        append_images=paletted[1:],
        duration=[650, 650],
        loop=0,
        optimize=False,
        disposal=2,
    )
    decoded = [frame.convert("RGB").copy() for frame in ImageSequence.Iterator(Image.open(path))]
    if len(decoded) != 2 or any(a.tobytes() != b.tobytes() for a, b in zip(decoded, expected, strict=True)):
        raise AssertionError(f"Exact facing GIF decode failed: {path}")
    return {
        "path": relative(path),
        "sha256": sha256(path),
        "frames": 2,
        "duration_ms": [650, 650],
        "sequence": ["right", "left_mirrored"],
        "exact_fixed_palette_decode": True,
    }


def font(size: int) -> ImageFont.ImageFont:
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/simhei.ttf")):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def fit_image(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    result = image.copy()
    result.thumbnail(size, Image.Resampling.NEAREST)
    return result


def paste_center(canvas: Image.Image, image: Image.Image, box: tuple[int, int, int, int]) -> None:
    left, top, right, bottom = box
    canvas.alpha_composite(
        image,
        (left + (right - left - image.width) // 2, top + (bottom - top - image.height) // 2),
    )


def save_review_panel(
    spec: CandidateSpec,
    cropped_source: Image.Image,
    candidate: Image.Image,
    delta: Image.Image,
    overlay: Image.Image,
    path: Path,
) -> dict[str, object]:
    canvas = Image.new("RGBA", (1760, 760), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    draw.text((28, 18), f"精英忍者第一门 — {spec.title}", fill=REVIEW_TEXT, font=font(28))
    draw.text((28, 56), spec.summary, fill=REVIEW_MUTED, font=font(18))
    labels = ("ImageGen结构原稿（仅参考）", "40px确定性重建 ×12", "普通版差分 ×12", "注册叠加 ×12")
    boxes = ((20, 110, 440, 730), (450, 110, 870, 730), (880, 110, 1300, 730), (1310, 110, 1730, 730))
    images = (
        fit_image(cropped_source, (390, 560)),
        nearest(on_background(candidate), 12),
        nearest(on_background(delta), 12),
        nearest(on_background(overlay), 12),
    )
    for label, box, image in zip(labels, boxes, images, strict=True):
        draw.text((box[0] + 8, 84), label, fill=REVIEW_TEXT, font=font(15))
        panel = Image.new("RGBA", (box[2] - box[0], box[3] - box[1]), REVIEW_PANEL)
        canvas.alpha_composite(panel, (box[0], box[1]))
        paste_center(canvas, image, box)
    save_png(canvas, path)
    return {"path": relative(path), "sha256": sha256(path), "size": list(canvas.size)}


def build(approval: str | None) -> dict[str, object]:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    base = load_base()
    base_grid = analyze_image(base)
    raw_paths = {
        spec.key: SOURCE_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_imagegen.png"
        for spec in CANDIDATES
    }
    for key, path in raw_paths.items():
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256(path)
        if actual != EXPECTED_IMAGEGEN_SHA256[key]:
            raise AssertionError(f"{key}: ImageGen source SHA drifted: {actual}")

    outputs: dict[str, dict[str, object]] = {}
    candidates: dict[str, Image.Image] = {}
    for spec in CANDIDATES:
        raw_path = raw_paths[spec.key]
        transparent_path = SOURCE_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_transparent.png"
        transparent_source, alpha_source = load_transparent_imagegen_source(
            raw_path, transparent_path
        )
        audit_reference_alpha(transparent_source, spec.key)
        if alpha_source != transparent_path:
            save_png(transparent_source, transparent_path)
        cropped_source = crop_to_square(transparent_source, padding=24, align_to_grid=False)
        crop_path = SOURCE_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_crop_tool.png"
        save_png(cropped_source, crop_path)

        candidate, accent_points = build_candidate(base, spec)
        metrics = audit_candidate(base, candidate, spec, accent_points)
        candidates[spec.key] = candidate
        native_path = SOURCE_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_native40.png"
        preview_path = PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_16x.png"
        delta_path = PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_ordinary_delta_16x.png"
        overlay_path = PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_ordinary_overlay_16x.png"
        gif_path = PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_facing.gif"
        panel_path = PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{spec.key}_review_panel.png"
        delta = delta_image(base, candidate)
        overlay = registration_overlay(base, candidate)
        save_png(candidate, native_path)
        save_png(nearest(on_background(candidate), 16), preview_path)
        save_png(nearest(on_background(delta), 16), delta_path)
        save_png(nearest(on_background(overlay), 16), overlay_path)
        facing = save_facing_gif(candidate, gif_path)
        panel = save_review_panel(spec, cropped_source, candidate, delta, overlay, panel_path)
        outputs[spec.key] = {
            "title": spec.title,
            "summary": spec.summary,
            "imagegen_source": {"path": relative(raw_path), "sha256": sha256(raw_path)},
            "transparent_reference": {"path": relative(transparent_path), "sha256": sha256(transparent_path), "alpha_source": relative(alpha_source)},
            "pixel_crop_tool_reference": {
                "path": relative(crop_path),
                "sha256": sha256(crop_path),
                "analysis": analyze_image(cropped_source),
                "unsafe_for_direct_resize": True,
                "pixels_imported_into_native": False,
            },
            "native40": {"path": relative(native_path), "sha256": sha256(native_path), "rgba_sha256": rgba_sha(candidate)},
            "integer_16x": {"path": relative(preview_path), "sha256": sha256(preview_path)},
            "ordinary_delta_16x": {"path": relative(delta_path), "sha256": sha256(delta_path)},
            "registration_overlay_16x": {"path": relative(overlay_path), "sha256": sha256(overlay_path)},
            "facing_gif": facing,
            "review_panel": panel,
            "wrist_points": {
                f"{x},{y}": list(color) for (x, y), color in spec.wrist_points.items()
            },
            "metrics": metrics,
        }

    approved_outputs: dict[str, str] | None = None
    if approval is not None:
        candidate = candidates[approval]
        approved_native = SOURCE_DIR / f"combat_robot_ninja_elite_anchor_{approval}_approved_native40.png"
        approved_preview = PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{approval}_approved_16x.png"
        ensure_review_path(approved_native)
        ensure_review_path(approved_preview)
        shutil.copyfile(SOURCE_DIR / f"combat_robot_ninja_elite_anchor_{approval}_native40.png", approved_native)
        shutil.copyfile(PREVIEW_DIR / f"combat_robot_ninja_elite_anchor_{approval}_16x.png", approved_preview)
        if rgba_sha(Image.open(approved_native)) != rgba_sha(candidate):
            raise AssertionError("Approved anchor copy changed pixels")
        approved_outputs = {
            "selection": approval.upper(),
            "native40": relative(approved_native),
            "integer_16x": relative(approved_preview),
            "native_sha256": sha256(approved_native),
            "rgba_sha256": rgba_sha(candidate),
        }

    report = {
        "asset": "combat_robot_ninja_elite_anchor_candidates",
        "stage": "first_human_gate_approved" if approval else "anchor_candidates_pending_first_human_gate",
        "approved_selection": approval.upper() if approval else None,
        "approved_outputs": approved_outputs,
        "first_human_approved": approval is not None,
        "preview_only": True,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "runtime_source": {
            "path": relative(RUNTIME_SHEET),
            "sha256": EXPECTED_RUNTIME_SHA256,
            "frame": [0, 0, 40, 40],
            "frame_rgba_sha256": rgba_sha(base),
            "frame_alpha_sha256": hashlib.sha256(base.getchannel("A").tobytes()).hexdigest(),
            "frame_leg_region_rgba_sha256": rgba_sha(base.crop((0, 26, 40, 32))),
            "pixel_grid_analysis": base_grid,
        },
        "contract": {
            "frame_size": [40, 40],
            "registered_center_x": REGISTERED_CENTER_X,
            "baseline_bottom": BASELINE_Y,
            "max_visible_size": [28, 28],
            "minimum_transparent_margin": SAFETY_MARGIN,
            "forbidden_new_pixel_row": 11,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "ordinary_geometry_inherited_outside_whitelist": True,
            "common_a1_points": {f"{x},{y}": list(color) for (x, y), color in COMMON_A1.items()},
            "purple_ramp": [list(color) for color in PURPLE_RAMP],
        },
        "candidates": outputs,
    }
    report_path = enemy_asset_report_path("combat_robot_ninja_elite_anchor_report.json")
    save_report = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    ensure_review_path(report_path)
    report_path.write_text(save_report, encoding="utf-8")

    manifest = {
        "asset": "combat_robot_ninja_elite",
        "stage": report["stage"],
        "approved_selection": report["approved_selection"],
        "first_human_approved": report["first_human_approved"],
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "source_imagegen": {
            key: {"path": relative(raw_paths[key]), "sha256": EXPECTED_IMAGEGEN_SHA256[key]}
            for key in EXPECTED_IMAGEGEN_SHA256
        },
        "runtime_source_sha256": EXPECTED_RUNTIME_SHA256,
        "report": {"path": relative(report_path), "sha256": sha256(report_path)},
    }
    manifest_path = enemy_asset_report_path("combat_robot_ninja_elite_anchor_manifest.json")
    ensure_review_path(manifest_path)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report["report_path"] = relative(report_path)
    report["report_sha256"] = sha256(report_path)
    report["manifest_path"] = relative(manifest_path)
    report["manifest_sha256"] = sha256(manifest_path)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="构建精英忍者第一门N1腕锁环锚点")
    parser.add_argument(
        "--approve",
        choices=[spec.key for spec in CANDIDATES],
        help="仅在用户选择后提升一个锚点；省略时保持第一门待确认",
    )
    args = parser.parse_args()
    print(json.dumps(build(args.approve), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
