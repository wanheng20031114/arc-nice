#!/usr/bin/env python3
"""Build the third human-gate effect candidates for the elite drone operator.

ImageGen outputs are review references only.  Every native candidate starts
from the checked-in ordinary runtime texture and preserves its alpha mask.
This builder is deliberately preview-only and refuses writes outside
``dev_assets``.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw, ImageFont, ImageSequence


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "combat_robot_drone_operator_elite"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"

LOCKED_ANIMATION_SELECTION = {
    "move": {
        "selection": "M1",
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_m1_candidate_native_strip.png",
        "sha256": "baa1e2dbd34a74dd91c1bd2a885640804d0d251fbeec29603e0a975fa163cb03",
        "rgba_sha256": "6038dff07b83674bf2488b42afb06fc5cc86f9f321341eab3adbf1f4777e0b83",
    },
    "deploy": {
        "selection": "P1",
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_p1_candidate_native_strip.png",
        "sha256": "5ba012793ee2389ced8bb6d1e39eb7e3231fc44b94de1c0115e36013fb468272",
        "rgba_sha256": "92e070440c613473c0b29d9bf4312e91fb3a4f3253d9d01c0b330a82ebee4c50",
    },
    "death": {
        "selection": "K2",
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_k2_candidate_native_strip.png",
        "sha256": "b0e6ac9606e0806aff0b5b5782cb0060b80ce63c5915e035611b3c8022a7998f",
        "rgba_sha256": "376841f107b75da78691c883b607b7296d0862495fd9db15e5eb245fa825c0e6",
    },
}

DRONE_PATH = ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_suicide_drone.png"
MARKER_PATH = ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_drone_target_marker.png"
EXPLOSION_PATH = ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_mechanical_explosion.png"

EXPECTED_RUNTIME_SHA = {
    "drone": "21fe9ddf09a72b080a06d346cb47ab4f3572852d9f0dae3242bc4476a7b1e06b",
    "target": "a2694c49e2dc04a5a7a46ebc7be5fb4078ea78c1dc4282e68ad4f6557b501436",
    "explosion": "6edc04d40612bb626b9d0880c250f869cd7f7bdd892296887dd0b57dd058e589",
}


@dataclass(frozen=True)
class CandidateSpec:
    key: str
    group: str
    imagegen_name: str
    imagegen_sha: str
    design: str
    fps: int
    runtime_loop: bool
    cell_size: int
    frame_count: int
    preview_scale: int


SPECS = (
    CandidateSpec("V1", "drone", "combat_robot_drone_operator_elite_drone_v1_imagegen.png", "5807896ba6dddde37bb63d54de434fb0840bcc3477e1f11347c9d67441379cf1", "purple core scans toward the nose", 12, True, 16, 4, 16),
    CandidateSpec("V2", "drone", "combat_robot_drone_operator_elite_drone_v2_imagegen.png", "e5c70927f9d40736993dde892f156d12bb597c4d21a8424dd6029544c0e55cb4", "purple core contracts inward and relaxes", 12, True, 16, 4, 16),
    CandidateSpec("T1", "target", "combat_robot_drone_operator_elite_target_t1_imagegen.png", "ed7d9a253d2136862822c5cb990f3b4afb3f6f1e74599770d440ef5c4b2111bb", "constant cold-white center with orthogonal purple pulse", 12, True, 16, 4, 16),
    CandidateSpec("T2", "target", "combat_robot_drone_operator_elite_target_t2_imagegen.png", "6ad8003e7873ea27d4149428942d679be754aaf8518e4dbafcff72379bd124a4", "cold-white confirmation then sequential outer-corner emphasis", 12, True, 16, 4, 16),
    CandidateSpec("X1", "explosion", "combat_robot_drone_operator_elite_explosion_x1_imagegen.png", "2b3f8f8f40007f4e79bf22d1e394700f5feba28c21d3574d54cc58cb047b090b", "cold-white hot core and concentric violet mechanical rings", 14, False, 64, 8, 4),
    CandidateSpec("X2", "explosion", "combat_robot_drone_operator_elite_explosion_x2_imagegen.png", "a88936d7318f805bb02884209be5a3682bcf5817fe3f080094fc7e75f4d2da73", "cold-white hot core with segmented orthogonal violet rhythm", 14, False, 64, 8, 4),
)

PROMPT_MANIFEST = enemy_asset_report_path("combat_robot_drone_operator_elite_effect_prompt_manifest.json")
MANIFEST = enemy_asset_report_path("combat_robot_drone_operator_elite_effect_manifest.json")
REPORT = enemy_asset_report_path("combat_robot_drone_operator_elite_effect_preview_report.json")
STABILITY = enemy_asset_report_path("combat_robot_drone_operator_elite_effect_stability_report.json")
COMPARISON = PREVIEW_DIR / "combat_robot_drone_operator_elite_effect_comparison.png"

TRANSPARENT = (0, 0, 0, 0)
REVIEW_BG = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)

OUTLINE = (21, 22, 19, 255)
STEEL = {
    (55, 59, 63, 255),
    (82, 88, 94, 255),
    (112, 121, 128, 255),
    (151, 159, 164, 255),
    (190, 196, 198, 255),
}
WHITE = (226, 229, 226, 255)
PURPLE = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)
OLD_ACCENTS = {
    (102, 25, 20, 255),
    (190, 48, 31, 255),
    (239, 92, 34, 255),
    (255, 181, 71, 255),
}
ALLOWED = {TRANSPARENT, OUTLINE, WHITE, *STEEL, *PURPLE}


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


def assert_dev_output(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"preview-only builder refused output {path}")


def save_png(image: Image.Image, path: Path) -> None:
    assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def save_json(payload: dict, path: Path) -> None:
    assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_runtime(path: Path, expected_size: tuple[int, int]) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    if image.size != expected_size:
        raise AssertionError(f"{path.name} size {image.size} != {expected_size}")
    alphas = {pixel[3] for pixel in image.getdata()}
    if not alphas <= {0, 255}:
        raise AssertionError(f"{path.name} alpha is not binary")
    if any(pixel[:3] != (0, 0, 0) for pixel in image.getdata() if pixel[3] == 0):
        raise AssertionError(f"{path.name} has dirty transparent RGB")
    return image


def split_frames(sheet: Image.Image, cell: int, count: int) -> list[Image.Image]:
    return [sheet.crop((index * cell, 0, (index + 1) * cell, cell)) for index in range(count)]


def build_strip(frames: list[Image.Image], cell: int) -> Image.Image:
    strip = Image.new("RGBA", (cell * len(frames), cell), TRANSPARENT)
    for index, frame in enumerate(frames):
        strip.alpha_composite(frame, (index * cell, 0))
    return strip


def validate_selection() -> dict:
    for item in LOCKED_ANIMATION_SELECTION.values():
        path = item["path"]
        if sha256(path) != item["sha256"] or rgba_sha(Image.open(path)) != item["rgba_sha256"]:
            raise AssertionError(f"selected animation strip drifted: {path.name}")
    return {
        key: item["selection"]
        for key, item in LOCKED_ANIMATION_SELECTION.items()
    }


def validate_inputs() -> tuple[dict[str, list[Image.Image]], dict]:
    selection = validate_selection()
    runtime_paths = {"drone": DRONE_PATH, "target": MARKER_PATH, "explosion": EXPLOSION_PATH}
    expected_sizes = {"drone": (64, 16), "target": (64, 16), "explosion": (512, 64)}
    cells = {"drone": (16, 4), "target": (16, 4), "explosion": (64, 8)}
    frames: dict[str, list[Image.Image]] = {}
    for group, path in runtime_paths.items():
        actual = sha256(path)
        if actual != EXPECTED_RUNTIME_SHA[group]:
            raise AssertionError(f"ordinary {group} runtime SHA drifted: {actual}")
        image = load_runtime(path, expected_sizes[group])
        frames[group] = split_frames(image, *cells[group])
    for spec in SPECS:
        path = SOURCE_DIR / spec.imagegen_name
        if not path.is_file() or sha256(path) != spec.imagegen_sha:
            raise AssertionError(f"ImageGen source drifted: {spec.key}")
    return frames, selection


def copy_with_colors(base: Image.Image, updates: dict[tuple[int, int], tuple[int, int, int, int]]) -> Image.Image:
    result = base.copy()
    for point, color in updates.items():
        if result.getpixel(point)[3] != 255:
            raise AssertionError(f"attempted color update outside inherited alpha at {point}")
        result.putpixel(point, color)
    return result


def build_drone(ordinary: list[Image.Image]) -> dict[str, list[Image.Image]]:
    wing = {(2, 4), (2, 10)}
    core_left = {(8, 7), (8, 8)}
    core_right = {(9, 7), (9, 8)}
    accent_points = wing | core_left | core_right
    for index, frame in enumerate(ordinary):
        actual = {point for point in accent_points if frame.getpixel(point) in OLD_ACCENTS}
        if actual != accent_points:
            raise AssertionError(f"ordinary drone accent coordinates drifted in frame {index}")

    v1_pairs = ((PURPLE[5], PURPLE[1]), (PURPLE[4], PURPLE[5]), (PURPLE[1], PURPLE[5]), (PURPLE[5], PURPLE[1]))
    v1_wings = (PURPLE[1], PURPLE[3], PURPLE[5], PURPLE[3])
    v2_core = (PURPLE[1], PURPLE[3], PURPLE[5], PURPLE[3])
    v2_wings = (PURPLE[4], PURPLE[2], PURPLE[1], PURPLE[2])
    candidates = {"V1": [], "V2": []}
    for index, base in enumerate(ordinary):
        left, right = v1_pairs[index]
        updates_v1 = {point: v1_wings[index] for point in wing}
        updates_v1.update({point: left for point in core_left})
        updates_v1.update({point: right for point in core_right})
        updates_v2 = {point: v2_wings[index] for point in wing}
        updates_v2.update({point: v2_core[index] for point in core_left | core_right})
        candidates["V1"].append(copy_with_colors(base, updates_v1))
        candidates["V2"].append(copy_with_colors(base, updates_v2))
    return candidates


def marker_center() -> set[tuple[int, int]]:
    return {(7, 7), (8, 7), (7, 8), (8, 8)}


def quadrant(point: tuple[int, int]) -> int:
    x, y = point
    return (2 if y >= 8 else 0) + (1 if x >= 8 else 0)


def build_marker(ordinary: list[Image.Image]) -> dict[str, list[Image.Image]]:
    candidates = {"T1": [], "T2": []}
    pulse = (PURPLE[1], PURPLE[3], PURPLE[5], PURPLE[3])
    center = marker_center()
    for index, base in enumerate(ordinary):
        alpha_points = {(x, y) for y in range(16) for x in range(16) if base.getpixel((x, y))[3]}
        if not center <= alpha_points:
            raise AssertionError(f"ordinary target center drifted in frame {index}")
        t1_updates = {point: (WHITE if point in center else pulse[index]) for point in alpha_points}
        t2_updates = {}
        for point in alpha_points:
            if point in center:
                t2_updates[point] = WHITE
                continue
            if index == 0:
                t2_updates[point] = PURPLE[0]
            else:
                q = quadrant(point)
                t2_updates[point] = PURPLE[5] if q < index else (PURPLE[3] if q == index else PURPLE[1])
        candidates["T1"].append(copy_with_colors(base, t1_updates))
        candidates["T2"].append(copy_with_colors(base, t2_updates))
    return candidates


def source_level(color: tuple[int, int, int, int]) -> int:
    return {
        (102, 25, 20, 255): 1,
        (190, 48, 31, 255): 2,
        (239, 92, 34, 255): 4,
        (255, 181, 71, 255): 5,
    }.get(color, 3)


def build_explosion(ordinary: list[Image.Image]) -> dict[str, list[Image.Image]]:
    candidates = {"X1": [], "X2": []}
    for frame_index, base in enumerate(ordinary):
        x1_updates = {}
        x2_updates = {}
        for y in range(64):
            for x in range(64):
                color = base.getpixel((x, y))
                if color[3] == 0:
                    continue
                if color == OUTLINE:
                    x1_updates[(x, y)] = OUTLINE
                    x2_updates[(x, y)] = OUTLINE
                    continue
                dx = x - 31.5
                dy = y - 31.5
                radius = math.hypot(dx, dy)
                if color == WHITE or radius <= max(1.5, min(5.5, frame_index + 1.0)):
                    x1_updates[(x, y)] = WHITE
                    x2_updates[(x, y)] = WHITE
                    continue
                level = source_level(color)
                x1_updates[(x, y)] = PURPLE[max(0, min(5, level))]
                angle = math.atan2(dy, dx) + math.pi
                sector = int(angle / (math.pi / 4.0)) % 8
                adjustment = 1 if (sector + frame_index) % 2 == 0 else -1
                if abs(dx) <= 1.5 or abs(dy) <= 1.5:
                    adjustment = 2
                x2_updates[(x, y)] = PURPLE[max(0, min(5, level + adjustment))]
        candidates["X1"].append(copy_with_colors(base, x1_updates))
        candidates["X2"].append(copy_with_colors(base, x2_updates))
    return candidates


def alpha_bytes(frame: Image.Image) -> bytes:
    return frame.getchannel("A").tobytes()


def opaque_points(frame: Image.Image) -> set[tuple[int, int]]:
    return {(x, y) for y in range(frame.height) for x in range(frame.width) if frame.getpixel((x, y))[3]}


def audit_candidate(spec: CandidateSpec, ordinary: list[Image.Image], frames: list[Image.Image]) -> dict:
    if len(frames) != spec.frame_count:
        raise AssertionError(f"{spec.key} frame count drifted")
    metrics = []
    for index, (base, frame) in enumerate(zip(ordinary, frames, strict=True)):
        if frame.size != (spec.cell_size, spec.cell_size):
            raise AssertionError(f"{spec.key}[{index}] cell size drifted")
        if alpha_bytes(frame) != alpha_bytes(base):
            raise AssertionError(f"{spec.key}[{index}] alpha mask changed")
        colors = set(frame.getdata())
        if colors & OLD_ACCENTS or not colors <= ALLOWED:
            raise AssertionError(f"{spec.key}[{index}] palette contract failed")
        if any(pixel[:3] != (0, 0, 0) for pixel in frame.getdata() if pixel[3] == 0):
            raise AssertionError(f"{spec.key}[{index}] dirty transparent RGB")
        bbox = frame.getchannel("A").getbbox()
        metrics.append({
            "index": index,
            "bbox": list(bbox) if bbox else None,
            "opaque_pixels": len(opaque_points(frame)),
            "alpha_sha256": hashlib.sha256(alpha_bytes(frame)).hexdigest(),
            "rgba_sha256": rgba_sha(frame),
        })
    if spec.group == "drone":
        masks = {metric["alpha_sha256"] for metric in metrics}
        if len(masks) != 1 or any(metric["bbox"] != [2, 3, 14, 12] or metric["opaque_pixels"] != 71 for metric in metrics):
            raise AssertionError(f"{spec.key} 12x9 shared-mask contract failed")
        accent = {(2, 4), (2, 10), (8, 7), (8, 8), (9, 7), (9, 8)}
        for base, frame in zip(ordinary, frames, strict=True):
            for point in opaque_points(base) - accent:
                if frame.getpixel(point) != base.getpixel(point):
                    raise AssertionError(f"{spec.key} changed inherited cold-gray pixel {point}")
    if spec.group == "target":
        if any(frame.getpixel(point) != WHITE for frame in frames for point in marker_center()):
            raise AssertionError(f"{spec.key} cold-white target center drifted")
    if spec.group == "explosion":
        expected_bbox = [list(frame.getchannel("A").getbbox()) for frame in ordinary]
        if [metric["bbox"] for metric in metrics] != expected_bbox or metrics[4]["bbox"] != [4, 4, 60, 60]:
            raise AssertionError(f"{spec.key} explosion center/56px contract failed")
    return {
        "frames": metrics,
        "frame_count": spec.frame_count,
        "fps": spec.fps,
        "runtime_loop": spec.runtime_loop,
        "alpha_masks_equal_ordinary": True,
        "transparent_rgb_zero": True,
        "old_red_or_orange_pixels": 0,
    }


def exact_palette() -> tuple[list[tuple[int, int, int]], dict[tuple[int, int, int], int]]:
    colors = [REVIEW_BG[:3], OUTLINE[:3], *sorted(color[:3] for color in STEEL), WHITE[:3], *(color[:3] for color in PURPLE)]
    unique = []
    for color in colors:
        if color not in unique:
            unique.append(color)
    return unique, {color: index for index, color in enumerate(unique)}


def composite_scaled(frame: Image.Image, scale: int, mirrored: bool = False) -> Image.Image:
    source = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if mirrored else frame
    canvas = Image.new("RGBA", source.size, REVIEW_BG)
    canvas.alpha_composite(source)
    return canvas.convert("RGB").resize((source.width * scale, source.height * scale), Image.Resampling.NEAREST)


def to_palette(image: Image.Image) -> Image.Image:
    colors, index = exact_palette()
    rgb = image.convert("RGB")
    unknown = set(rgb.getdata()) - set(colors)
    if unknown:
        raise AssertionError(f"GIF input contains colors outside fixed palette: {unknown}")
    result = Image.new("P", rgb.size)
    flat = []
    for color in colors:
        flat.extend(color)
    flat.extend([0] * (768 - len(flat)))
    result.putpalette(flat)
    result.putdata([index[color] for color in rgb.getdata()])
    return result


def save_gif(frames: list[Image.Image], path: Path, fps: int, scale: int, mirrored: bool = False) -> dict:
    assert_dev_output(path)
    expected = [composite_scaled(frame, scale, mirrored) for frame in frames]
    paletted = [to_palette(frame) for frame in expected]
    duration = max(10, round(1000 / fps / 10) * 10)
    path.parent.mkdir(parents=True, exist_ok=True)
    paletted[0].save(path, save_all=True, append_images=paletted[1:], duration=duration, loop=0, optimize=False, disposal=2)
    decoded = [frame.convert("RGB") for frame in ImageSequence.Iterator(Image.open(path))]
    if len(decoded) != len(expected) or any(left.tobytes() != right.tobytes() for left, right in zip(decoded, expected, strict=True)):
        raise AssertionError(f"GIF exact-decode contract failed: {path.name}")
    return {"path": rel(path), "sha256": sha256(path), "frames": len(frames), "duration_ms": duration, "mirrored": mirrored}


def save_upscaled(strip: Image.Image, path: Path, scale: int) -> dict:
    image = strip.resize((strip.width * scale, strip.height * scale), Image.Resampling.NEAREST)
    save_png(image, path)
    return {"path": rel(path), "sha256": sha256(path), "scale": scale, "size": list(image.size)}


def save_delta(ordinary: list[Image.Image], candidate: list[Image.Image], spec: CandidateSpec, path: Path) -> dict:
    scale = 8 if spec.cell_size == 16 else 2
    width = spec.cell_size * spec.frame_count
    canvas = Image.new("RGBA", (width, spec.cell_size * 3), TRANSPARENT)
    ordinary_strip = build_strip(ordinary, spec.cell_size)
    candidate_strip = build_strip(candidate, spec.cell_size)
    canvas.alpha_composite(ordinary_strip, (0, 0))
    canvas.alpha_composite(candidate_strip, (0, spec.cell_size))
    for index, (base, frame) in enumerate(zip(ordinary, candidate, strict=True)):
        for y in range(spec.cell_size):
            for x in range(spec.cell_size):
                if base.getpixel((x, y)) != frame.getpixel((x, y)):
                    canvas.putpixel((index * spec.cell_size + x, spec.cell_size * 2 + y), PURPLE[5])
    return save_upscaled(canvas, path, scale)


def imagegen_preview(spec: CandidateSpec) -> dict:
    source = Image.open(SOURCE_DIR / spec.imagegen_name).convert("RGB")
    source.thumbnail((900, 220), Image.Resampling.NEAREST)
    result = Image.new("RGBA", source.size, TRANSPARENT)
    for y in range(source.height):
        for x in range(source.width):
            red, green, blue = source.getpixel((x, y))
            if green >= 90 and green - red >= 30 and green - blue >= 30:
                continue
            result.putpixel((x, y), (red, green, blue, 255))
    path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_{spec.key.lower()}_imagegen_transparent_preview.png"
    save_png(result, path)
    return {"path": rel(path), "sha256": sha256(path), "size": list(result.size)}


def build_comparison(outputs: dict[str, dict], candidates: dict[str, list[Image.Image]]) -> Image.Image:
    width = 1500
    row_height = 260
    canvas = Image.new("RGBA", (width, 70 + row_height * len(SPECS)), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    draw.text((20, 18), "Elite drone operator - effect candidates (third human gate)", fill=REVIEW_TEXT, font=font)
    draw.text((20, 40), "ImageGen language reference | deterministic runtime-mask candidate | runtime_written=false", fill=(151, 159, 164, 255), font=font)
    for row, spec in enumerate(SPECS):
        top = 70 + row * row_height
        draw.rounded_rectangle((10, top + 5, width - 10, top + row_height - 5), radius=8, fill=REVIEW_PANEL)
        draw.text((25, top + 20), f"{spec.key}  {spec.design}  {spec.frame_count}f @ {spec.fps} FPS", fill=REVIEW_TEXT, font=font)
        frames = candidates[spec.key]
        scale = spec.preview_scale
        for index, frame in enumerate(frames):
            preview = composite_scaled(frame, scale).convert("RGBA")
            x = 25 + index * (spec.cell_size * scale + 8)
            y = top + 55
            if x + preview.width > width - 15:
                break
            canvas.alpha_composite(preview, (x, y))
        draw.text((25, top + row_height - 25), f"native: {outputs[spec.key]['native_strip']['sha256'][:16]}...", fill=(151, 159, 164, 255), font=font)
    return canvas


def main() -> None:
    ordinary, selection = validate_inputs()
    candidates = {}
    candidates.update(build_drone(ordinary["drone"]))
    candidates.update(build_marker(ordinary["target"]))
    candidates.update(build_explosion(ordinary["explosion"]))

    second_build = {}
    second_build.update(build_drone(ordinary["drone"]))
    second_build.update(build_marker(ordinary["target"]))
    second_build.update(build_explosion(ordinary["explosion"]))
    if any(
        left.tobytes() != right.tobytes()
        for key in candidates
        for left, right in zip(candidates[key], second_build[key], strict=True)
    ):
        raise AssertionError("in-memory deterministic rebuild drifted")

    prompt_sources = {}
    outputs = {}
    audits = {}
    for spec in SPECS:
        source_path = SOURCE_DIR / spec.imagegen_name
        prompt_sources[spec.key] = {
            "path": rel(source_path),
            "sha256": spec.imagegen_sha,
            "design": spec.design,
            "pixels_imported": False,
        }
        frames = candidates[spec.key]
        base = ordinary[spec.group]
        audits[spec.key] = audit_candidate(spec, base, frames)
        strip = build_strip(frames, spec.cell_size)
        native_path = SOURCE_DIR / f"combat_robot_drone_operator_elite_{spec.key.lower()}_candidate_native_strip.png"
        save_png(strip, native_path)
        upscaled_path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_{spec.key.lower()}_candidate_{spec.preview_scale}x.png"
        gif_path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_{spec.key.lower()}.gif"
        mirrored_path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_{spec.key.lower()}_mirrored.gif"
        delta_path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_{spec.key.lower()}_ordinary_delta.png"
        outputs[spec.key] = {
            "native_strip": {"path": rel(native_path), "sha256": sha256(native_path), "rgba_sha256": rgba_sha(strip), "size": list(strip.size)},
            "upscaled": save_upscaled(strip, upscaled_path, spec.preview_scale),
            "gif": save_gif(frames, gif_path, spec.fps, spec.preview_scale),
            "mirrored_gif": save_gif(frames, mirrored_path, spec.fps, spec.preview_scale, True),
            "ordinary_delta": save_delta(base, frames, spec, delta_path),
            "imagegen_preview": imagegen_preview(spec),
        }

    prompt_payload = {
        "version": 1,
        "asset": "combat_robot_drone_operator_elite_effect_imagegen_references",
        "sources": prompt_sources,
        "ordinary_runtime_sources": {key: {"path": rel(path), "sha256": EXPECTED_RUNTIME_SHA[key]} for key, path in {"drone": DRONE_PATH, "target": MARKER_PATH, "explosion": EXPLOSION_PATH}.items()},
        "imagegen_pixels_imported": False,
        "runtime_written": False,
    }
    save_json(prompt_payload, PROMPT_MANIFEST)

    comparison = build_comparison(outputs, candidates)
    save_png(comparison, COMPARISON)
    stability = {
        "asset": "combat_robot_drone_operator_elite_effect_candidates",
        "stage": "effect_candidates_pending_third_human_gate",
        "audits": audits,
        "deterministic_in_memory_rebuild": True,
        "gif_fixed_palette_exact_decode": True,
        "ordinary_alpha_masks_inherited": True,
        "approved_animation_selection": {"move": "M1", "deploy": "P1", "death": "K2"},
        "approved_selection": None,
        "runtime_written": False,
    }
    save_json(stability, STABILITY)
    report = {
        "asset": "combat_robot_drone_operator_elite_effect_candidates",
        "stage": "effect_candidates_pending_third_human_gate",
        "animation_selection_certificate": {"embedded_lock": True, "selection": selection},
        "ordinary_runtime_sources": {key: {"path": rel(path), "expected_sha256": EXPECTED_RUNTIME_SHA[key], "actual_sha256": sha256(path)} for key, path in {"drone": DRONE_PATH, "target": MARKER_PATH, "explosion": EXPLOSION_PATH}.items()},
        "candidate_outputs": outputs,
        "candidate_audits": audits,
        "comparison": {"path": rel(COMPARISON), "sha256": sha256(COMPARISON), "size": list(comparison.size)},
        "prompt_manifest": {"path": rel(PROMPT_MANIFEST), "sha256": sha256(PROMPT_MANIFEST)},
        "stability_report": {"path": rel(STABILITY), "sha256": sha256(STABILITY)},
        "script": {"path": rel(SCRIPT_PATH), "sha256": sha256(SCRIPT_PATH)},
        "imagegen_pixels_imported": False,
        "approved_selection": None,
        "runtime_written": False,
    }
    save_json(report, REPORT)
    manifest = {
        "version": 1,
        "asset": "combat_robot_drone_operator_elite_effect_candidates",
        "stage": "effect_candidates_pending_third_human_gate",
        "approved_anchor": "O3",
        "approved_animation_selection": {"move": "M1", "deploy": "P1", "death": "K2"},
        "animation_selection_certificate": {"embedded_lock": True, "selection": selection},
        "prompt_manifest": {"path": rel(PROMPT_MANIFEST), "sha256": sha256(PROMPT_MANIFEST)},
        "preview_report": {"path": rel(REPORT), "sha256": sha256(REPORT)},
        "stability_report": {"path": rel(STABILITY), "sha256": sha256(STABILITY)},
        "comparison": {"path": rel(COMPARISON), "sha256": sha256(COMPARISON)},
        "candidate_native_strips": {key: payload["native_strip"] for key, payload in outputs.items()},
        "approved_selection": None,
        "imagegen_pixels_imported": False,
        "runtime_written": False,
    }
    save_json(manifest, MANIFEST)

    for key, path in {"drone": DRONE_PATH, "target": MARKER_PATH, "explosion": EXPLOSION_PATH}.items():
        if sha256(path) != EXPECTED_RUNTIME_SHA[key]:
            raise AssertionError(f"runtime {key} changed while building previews")
    print(json.dumps({"ok": True, "stage": manifest["stage"], "gifs": {key: payload["gif"]["path"] for key, payload in outputs.items()}, "runtime_written": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
