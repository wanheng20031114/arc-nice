#!/usr/bin/env python3
"""Assemble the approved elite-gunner art for the third human review gate.

The selected M1 / S2 / D2 / B1 native strips are copied byte-for-pixel into
review candidates below ``dev_assets``.  This script never samples ImageGen
art, regenerates a pose, recolors a selected strip, or writes runtime assets.
"""

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Sequence

from PIL import Image, ImageDraw, ImageFont

import build_combat_robot_gunner_elite_animation_previews as stage2


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_gunner_elite"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
STAGE2_REPORT_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_preview_report.json")
)
ANIMATION_MANIFEST_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_manifest.json")
)
STABILITY_REPORT_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_animation_stability_report.json")
)
FINAL_MANIFEST_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_final_candidate_manifest.json")
)
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

FINAL_SHEET_PATH = SOURCE_DIR / "combat_robot_gunner_elite_final_candidate.png"
FINAL_BULLET_PATH = (
    SOURCE_DIR / "combat_robot_gunner_elite_bullet_final_candidate.png"
)
FINAL_REPORT_PATH = (
    enemy_asset_report_path("combat_robot_gunner_elite_final_preview_report.json")
)

FRAME_SIZE = 32
SHEET_SIZE = (256, 192)
BULLET_SIZE = (36, 8)
BULLET_CELL_SIZE = (12, 8)
MAX_VISIBLE_SIZE = 28
BASELINE_BOTTOM = 28
TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)

EXPECTED_STAGE2_REPORT_SHA256 = (
    "50b67ea4662c154b6bd816a05b81b77c6962c73643eca60104f130e403cf1606"
)
EXPECTED_STAGE2_MANIFEST_SHA256 = (
    "c24dcd597aa2365664e57739062f3e46cb5f691368880c073a3b1738f339780c"
)
EXPECTED_STABILITY_REPORT_SHA256 = (
    "dde449df16e3e17771202aa0821147855f7682ba2fbbe4bafb95f27bf0a0e4cd"
)
EXPECTED_ORDINARY_SHEET_SHA256 = (
    "a8b656423ffd456f31b51905cd2f988d37ba73b0982f3c4faf5a9dd7ea677201"
)
EXPECTED_ORDINARY_BULLET_SHA256 = (
    "36d70c62bb19878ce0ad284093c6738b1cdd8985f4c65166695b662c39477974"
)

APPROVED_SELECTION = {
    "move": "M1",
    "fire": "S2",
    "death": "D2",
    "bullet": "B1",
}


@dataclass(frozen=True)
class ApprovedInput:
    selection: str
    report_key: str
    filename: str
    size: tuple[int, int]
    expected_sha256: str
    frame_size: tuple[int, int]
    frame_count: int

    @property
    def path(self) -> Path:
        return PREVIEW_DIR / self.filename


APPROVED_INPUTS: tuple[ApprovedInput, ...] = (
    ApprovedInput(
        "M1",
        "M1",
        "combat_robot_gunner_elite_m1_candidate_strip.png",
        (256, 32),
        "06558e8d935137f742d7fbb00e10f15d28c8674c90469e85287f0b6289544354",
        (32, 32),
        8,
    ),
    ApprovedInput(
        "S2",
        "S2",
        "combat_robot_gunner_elite_s2_candidate_strip.png",
        (256, 128),
        "c12f781660c2a98746b731278acf176dcdda2efd2af9c828c09cf43093969dff",
        (32, 32),
        32,
    ),
    ApprovedInput(
        "D2",
        "D2",
        "combat_robot_gunner_elite_d2_candidate_strip.png",
        (256, 32),
        "27b795298fc3f1e443751c347e537e9e774850841e3eb851ddde0c20304fddff",
        (32, 32),
        8,
    ),
    ApprovedInput(
        "B1",
        "B1",
        "combat_robot_gunner_elite_b1_candidate_strip.png",
        (36, 8),
        "600016b26f904bdde24485474100ed91757c3a8bc479be6e8337e25d6a7fb830",
        (12, 8),
        3,
    ),
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
        raise AssertionError(f"Third-gate builder refused non-dev output: {path}")


def _save_png(image: Image.Image, path: Path) -> None:
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def _save_json(payload: dict, path: Path) -> None:
    _assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _frames_from_grid(
    image: Image.Image,
    frame_size: tuple[int, int],
    frame_count: int,
) -> list[Image.Image]:
    columns = image.width // frame_size[0]
    return [
        image.crop(
            (
                (index % columns) * frame_size[0],
                (index // columns) * frame_size[1],
                ((index % columns) + 1) * frame_size[0],
                ((index // columns) + 1) * frame_size[1],
            )
        )
        for index in range(frame_count)
    ]


def _validate_storage(image: Image.Image, label: str) -> None:
    for index, (red, green, blue, alpha) in enumerate(image.getdata()):
        if alpha not in (0, 255):
            raise AssertionError(f"{label} alpha is not binary at pixel {index}")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label} transparent RGB is nonzero at pixel {index}")


def _validate_stage2_report() -> dict:
    certificates = (
        (STAGE2_REPORT_PATH, EXPECTED_STAGE2_REPORT_SHA256),
        (ANIMATION_MANIFEST_PATH, EXPECTED_STAGE2_MANIFEST_SHA256),
        (STABILITY_REPORT_PATH, EXPECTED_STABILITY_REPORT_SHA256),
    )
    for path, expected_sha in certificates:
        if not path.is_file():
            raise FileNotFoundError(path)
        actual_sha = _sha256(path)
        if actual_sha != expected_sha:
            raise AssertionError(
                f"Second-stage certificate SHA changed: {actual_sha} != "
                f"{expected_sha} ({path})"
            )
    report = _load_json(STAGE2_REPORT_PATH)
    manifest = _load_json(ANIMATION_MANIFEST_PATH)
    stability = _load_json(STABILITY_REPORT_PATH)
    if report.get("stage") != "animation_candidates_pending_second_human_gate":
        raise AssertionError("Second-stage report no longer describes the second gate")
    if report.get("approved_anchor", {}).get("selection") != "G1":
        raise AssertionError("Third stage requires the approved G1 anchor")
    if report.get("approved_selection") is not None:
        raise AssertionError("Second-stage report must remain an unbiased candidate report")
    if report.get("runtime_written") is not False:
        raise AssertionError("Second-stage report unexpectedly wrote runtime assets")
    if manifest.get("stage") != "animation_candidates_pending_second_human_gate":
        raise AssertionError("Second-stage manifest stage changed")
    if manifest.get("approved_selection") is not None:
        raise AssertionError("Second-stage manifest must remain selection-neutral")
    if manifest.get("runtime_written") is not False:
        raise AssertionError("Second-stage manifest unexpectedly wrote runtime assets")
    if stability.get("stage") != "animation_candidates_pending_second_human_gate":
        raise AssertionError("Second-stage stability report stage changed")
    if stability.get("approved_selection") is not None:
        raise AssertionError("Second-stage stability report must remain selection-neutral")
    if stability.get("runtime_written") is not False:
        raise AssertionError("Second-stage stability report unexpectedly wrote runtime assets")
    if report.get("fire_timing_contract", {}).get("schedule_sha256") != (
        "133bb0a453b48c745235a469c398d452fc7b1ad273a64b85cebde40b8e73cb7a"
    ):
        raise AssertionError("Second-stage fire timing contract changed")
    return report


def _validate_runtime_sources() -> dict:
    expected = (
        (ORDINARY_SHEET_PATH, EXPECTED_ORDINARY_SHEET_SHA256, SHEET_SIZE),
        (ORDINARY_BULLET_PATH, EXPECTED_ORDINARY_BULLET_SHA256, BULLET_SIZE),
    )
    report: dict[str, dict] = {}
    for path, expected_sha, expected_size in expected:
        if not path.is_file():
            raise FileNotFoundError(path)
        actual_sha = _sha256(path)
        image = Image.open(path).convert("RGBA")
        if actual_sha != expected_sha:
            raise AssertionError(f"Runtime reference changed: {path}")
        if image.size != expected_size:
            raise AssertionError(f"Runtime reference size changed: {path}")
        _validate_storage(image, path.name)
        report[path.name] = {
            "path": _relative(path),
            "size": list(image.size),
            "sha256": actual_sha,
            "sha256_locked": True,
        }
    return report


def _load_approved_inputs(stage2_report: dict) -> tuple[dict[str, Image.Image], dict]:
    images: dict[str, Image.Image] = {}
    reports: dict[str, dict] = {}
    for spec in APPROVED_INPUTS:
        if not spec.path.is_file():
            raise FileNotFoundError(spec.path)
        actual_sha = _sha256(spec.path)
        if actual_sha != spec.expected_sha256:
            raise AssertionError(
                f"{spec.selection} native SHA changed: {actual_sha} != "
                f"{spec.expected_sha256}"
            )
        image = Image.open(spec.path).convert("RGBA")
        if image.size != spec.size:
            raise AssertionError(
                f"{spec.selection} native size {image.size} != {spec.size}"
            )
        _validate_storage(image, spec.selection)
        candidate_report = stage2_report["candidates"][spec.report_key]
        if candidate_report["strip"] != _relative(spec.path):
            raise AssertionError(f"{spec.selection} path differs from stage-two report")
        frames = _frames_from_grid(image, spec.frame_size, spec.frame_count)
        frame_hashes = [_rgba_sha256(frame) for frame in frames]
        if frame_hashes != candidate_report["frame_rgba_sha256"]:
            raise AssertionError(
                f"{spec.selection} frame pixels differ from stage-two report"
            )
        images[spec.selection] = image
        reports[spec.selection] = {
            "path": _relative(spec.path),
            "size": list(image.size),
            "sha256": actual_sha,
            "rgba_sha256": _rgba_sha256(image),
            "frame_count": spec.frame_count,
            "frame_rgba_sha256": frame_hashes,
            "byte_sha_matches_constant": True,
            "frames_match_stage2_report": True,
        }
    return images, reports


def _compose_final_candidates(images: dict[str, Image.Image]) -> tuple[Image.Image, Image.Image]:
    sheet = Image.new("RGBA", SHEET_SIZE, TRANSPARENT)
    sheet.alpha_composite(images["M1"], (0, 0))
    sheet.alpha_composite(images["S2"], (0, FRAME_SIZE))
    sheet.alpha_composite(images["D2"], (0, FRAME_SIZE * 5))
    return sheet, images["B1"].copy()


def _frame_metrics(frame: Image.Image) -> dict:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Selected frame is empty")
    return {
        "bbox": list(bbox),
        "visible_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        "baseline_bottom": bbox[3],
        "visible_pixels": sum(alpha != 0 for alpha in frame.getchannel("A").getdata()),
        "rgba_sha256": _rgba_sha256(frame),
    }


def _audit_robot_frames(sheet: Image.Image, ordinary_sheet: Image.Image) -> dict:
    frames = _frames_from_grid(sheet, (FRAME_SIZE, FRAME_SIZE), 48)
    ordinary_frames = _frames_from_grid(
        ordinary_sheet, (FRAME_SIZE, FRAME_SIZE), 48
    )
    reports: list[dict] = []
    for index, (frame, ordinary) in enumerate(zip(frames, ordinary_frames)):
        metrics = _frame_metrics(frame)
        width, height = metrics["visible_size"]
        if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
            raise AssertionError(f"Robot frame {index} exceeds 28x28: {metrics}")
        if metrics["baseline_bottom"] > BASELINE_BOTTOM:
            raise AssertionError(f"Robot frame {index} crosses y=28: {metrics}")
        for pixel in frame.getdata():
            if pixel in stage2.ORDINARY_ACCENTS:
                raise AssertionError(f"Robot frame {index} retains red/orange pixels")
        added_points = {
            (x, y)
            for y in range(FRAME_SIZE)
            for x in range(FRAME_SIZE)
            if ordinary.getpixel((x, y))[3] == 0 and frame.getpixel((x, y))[3] == 255
        }
        added_y7 = sorted(point for point in added_points if point[1] == 7)
        if added_y7:
            raise AssertionError(f"Robot frame {index} reintroduced floating y=7 pixels")
        if index < 40:
            alive_top_additions = {
                point for point in added_points if point[1] <= 8
            }
            expected_top_additions = {(10, 8), (21, 8)}
            if alive_top_additions != expected_top_additions:
                raise AssertionError(
                    f"Living frame {index} crown geometry changed: {alive_top_additions}"
                )
        reports.append({**metrics, "authored_added_y7_pixels": 0})
    return {
        "frame_count": len(frames),
        "frame_size": [FRAME_SIZE, FRAME_SIZE],
        "max_visible_size": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
        "baseline_limit": BASELINE_BOTTOM,
        "red_orange_remaining": 0,
        "living_crown_extension_points": [[10, 8], [21, 8]],
        "living_crown_matches_approved_flat_lip": True,
        "authored_added_y7_pixels": 0,
        "frames": reports,
    }


def _audit_bullet(bullet: Image.Image) -> dict:
    frames = _frames_from_grid(bullet, BULLET_CELL_SIZE, 3)
    masks: list[bytes] = []
    reports: list[dict] = []
    expected_bright_cores = (
        [(4, 4), (5, 4)],
        [(6, 4), (7, 4)],
        [(8, 4), (9, 4)],
    )
    for index, frame in enumerate(frames):
        bbox = frame.getchannel("A").getbbox()
        if bbox is None or (bbox[2] - bbox[0], bbox[3] - bbox[1]) != (9, 3):
            raise AssertionError(f"B1 bullet frame {index} is not strict 9x3: {bbox}")
        alpha = frame.getchannel("A").tobytes()
        visible_pixels = sum(value != 0 for value in alpha)
        if visible_pixels != 23:
            raise AssertionError(
                f"B1 bullet frame {index} changed its 23-pixel capsule mask"
            )
        masks.append(alpha)
        bright_core = sorted(
            (x, y)
            for y in range(frame.height)
            for x in range(frame.width)
            if frame.getpixel((x, y)) == stage2.PURPLE_RAMP[5]
        )
        if bright_core != expected_bright_cores[index]:
            raise AssertionError(
                f"B1 bullet frame {index} bright core changed: {bright_core}"
            )
        reports.append(
            {
                "frame": index,
                "bbox": list(bbox),
                "visible_pixels": visible_pixels,
                "alpha_mask_sha256": hashlib.sha256(alpha).hexdigest(),
                "rgba_sha256": _rgba_sha256(frame),
                "bright_core_points": [list(point) for point in bright_core],
            }
        )
    if len(set(masks)) != 1:
        raise AssertionError("B1 bullet alpha mask flickers")
    return {
        "frame_count": 3,
        "cell_size": list(BULLET_CELL_SIZE),
        "visible_bbox": [9, 3],
        "visible_pixels": 23,
        "alpha_mask_stable": True,
        "bright_core_advances_two_pixels_per_frame": True,
        "frames": reports,
    }


def _audit_exact_copy(
    sheet: Image.Image,
    bullet: Image.Image,
    inputs: dict[str, Image.Image],
) -> dict:
    checks = {
        "move_m1": sheet.crop((0, 0, 256, 32)).tobytes() == inputs["M1"].tobytes(),
        "fire_s2": sheet.crop((0, 32, 256, 160)).tobytes() == inputs["S2"].tobytes(),
        "death_d2": sheet.crop((0, 160, 256, 192)).tobytes() == inputs["D2"].tobytes(),
        "bullet_b1": bullet.tobytes() == inputs["B1"].tobytes(),
    }
    if not all(checks.values()):
        raise AssertionError(f"Final candidate differs from approved native inputs: {checks}")
    return {
        **checks,
        "all_selected_pixels_copied_exactly": True,
        "resampling_used": False,
        "recoloring_used": False,
        "imagegen_pixels_imported": False,
    }


def _on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    result.alpha_composite(image)
    return result


def _mirror(frames: Sequence[Image.Image]) -> list[Image.Image]:
    return [frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) for frame in frames]


def _save_gif(
    frames: Sequence[Image.Image],
    path: Path,
    fps: int,
    scale: int,
) -> dict:
    _assert_dev_output(path)
    expected_rgb = [
        _on_background(frame)
        .resize((frame.width * scale, frame.height * scale), Image.Resampling.NEAREST)
        .convert("RGB")
        for frame in frames
    ]
    colors = {pixel for frame in expected_rgb for pixel in frame.getdata()}
    if len(colors) > 256:
        raise AssertionError(f"Exact GIF palette exceeds 256 colors: {len(colors)}")
    background = REVIEW_BACKGROUND[:3]
    ordered_colors = [background] + sorted(colors - {background})
    color_to_index = {color: index for index, color in enumerate(ordered_colors)}
    palette = [channel for color in ordered_colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    prepared: list[Image.Image] = []
    for frame in expected_rgb:
        indexed = Image.new("P", frame.size)
        indexed.putpalette(palette)
        indexed.putdata([color_to_index[pixel] for pixel in frame.getdata()])
        prepared.append(indexed)

    # GIF stores time in centiseconds.  Distribute 10ms ticks across the loop
    # instead of silently rounding every 14/12 FPS frame down to 70/80ms.
    durations_ms: list[int] = []
    previous_centiseconds = 0
    for frame_index in range(len(frames)):
        cumulative_centiseconds = round((frame_index + 1) * 100 / fps)
        frame_centiseconds = cumulative_centiseconds - previous_centiseconds
        if frame_centiseconds <= 0:
            raise AssertionError("GIF timing requires at least one centisecond per frame")
        durations_ms.append(frame_centiseconds * 10)
        previous_centiseconds = cumulative_centiseconds
    prepared[0].save(
        path,
        save_all=True,
        append_images=prepared[1:],
        duration=durations_ms,
        loop=0,
        disposal=2,
        optimize=False,
    )

    decoded = Image.open(path)
    if decoded.n_frames != len(expected_rgb):
        raise AssertionError(
            f"GIF frame count changed: {decoded.n_frames} != {len(expected_rgb)} ({path})"
        )
    decoded_durations: list[int] = []
    for frame_index, expected in enumerate(expected_rgb):
        decoded.seek(frame_index)
        actual = decoded.convert("RGB")
        if actual.tobytes() != expected.tobytes():
            raise AssertionError(
                f"GIF palette changed native pixels in frame {frame_index}: {path}"
            )
        decoded_durations.append(int(decoded.info.get("duration", 0)))
    if decoded_durations != durations_ms:
        raise AssertionError(
            f"GIF encoded timing changed: {decoded_durations} != {durations_ms}"
        )
    total_duration_ms = sum(decoded_durations)
    return {
        "path": _relative(path),
        "sha256": _sha256(path),
        "frame_count": len(frames),
        "fps_contract": fps,
        "encoded_durations_ms": decoded_durations,
        "encoded_total_duration_ms": total_duration_ms,
        "effective_fps": round(len(frames) * 1000 / total_duration_ms, 6),
        "exact_fixed_palette": True,
        "palette_color_count": len(ordered_colors),
        "dithering_used": False,
        "decoded_frames_match_native_nearest_neighbor": True,
    }


def _delta(base: Image.Image, elite: Image.Image) -> Image.Image:
    if base.size != elite.size:
        raise AssertionError("Delta sources must have matching dimensions")
    result = Image.new("RGBA", base.size, TRANSPARENT)
    pixels = result.load()
    for y in range(base.height):
        for x in range(base.width):
            before = base.getpixel((x, y))
            after = elite.getpixel((x, y))
            if before == after and before[3]:
                pixels[x, y] = (112, 121, 128, 120)
            elif before[3] == 0 and after[3]:
                pixels[x, y] = (238, 80, 205, 255)
            elif before[3] and after[3] == 0:
                pixels[x, y] = (60, 210, 235, 255)
            elif before != after:
                pixels[x, y] = (197, 138, 255, 255)
    return result


def _review_font(size: int) -> ImageFont.ImageFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _strip(frames: Sequence[Image.Image]) -> Image.Image:
    result = Image.new("RGBA", (len(frames) * frames[0].width, frames[0].height), TRANSPARENT)
    for index, frame in enumerate(frames):
        result.alpha_composite(frame, (index * frame.width, 0))
    return result


def _write_comparison(
    sheet: Image.Image,
    bullet: Image.Image,
    ordinary_sheet: Image.Image,
    ordinary_bullet: Image.Image,
    sheet_delta: Image.Image,
    bullet_delta: Image.Image,
) -> Path:
    width = 2320
    height = 3300
    canvas = Image.new("RGBA", (width, height), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title = _review_font(30)
    label = _review_font(20)
    small = _review_font(15)
    draw.text((24, 18), "精英持枪战斗机器人 — 第三阶段最终候选", fill=REVIEW_TEXT, font=title)
    draw.text(
        (24, 62),
        "已选 M1 / S2 / D2 / B1；逐像素复制第二阶段 Native，仍待最终人工确认",
        fill=REVIEW_MUTED,
        font=small,
    )
    final_preview = _on_background(sheet).resize((1024, 768), Image.Resampling.NEAREST)
    canvas.alpha_composite(final_preview, (24, 100))
    draw.text((1080, 110), "256×192机体候选（4倍）", fill=REVIEW_TEXT, font=label)
    draw.text((1080, 150), "row0：move M1，8帧 @14 FPS", fill=REVIEW_MUTED, font=small)
    draw.text((1080, 182), "row1–4：fire S2，4上身相×8腿相", fill=REVIEW_MUTED, font=small)
    draw.text((1080, 214), "运行预览：上身25 FPS、腿部7 FPS", fill=REVIEW_MUTED, font=small)
    draw.text((1080, 246), "row5：death D2，8帧 @12 FPS", fill=REVIEW_MUTED, font=small)
    bullet_preview = _on_background(bullet).resize((36 * 24, 8 * 24), Image.Resampling.NEAREST)
    canvas.alpha_composite(bullet_preview, (1080, 310))
    draw.text((1080, 520), "B1紫弹：3帧 @25 FPS；9×3稳定轮廓", fill=REVIEW_MUTED, font=small)

    sections = (
        ("MOVE / M1", 0, 1, 8),
        ("FIRE / S2（上身四相，固定腿相0）", 1, 4, 4),
        ("DEATH / D2", 5, 1, 8),
    )
    y = 920
    for heading, start_row, row_count, count in sections:
        draw.text((24, y), heading, fill=REVIEW_TEXT, font=label)
        if heading.startswith("FIRE"):
            indices = [phase * 8 for phase in range(4)]
            ordinary_frames = _frames_from_grid(
                ordinary_sheet.crop((0, 32, 256, 160)), (32, 32), 32
            )
            elite_frames = _frames_from_grid(sheet.crop((0, 32, 256, 160)), (32, 32), 32)
            bases = [ordinary_frames[index] for index in indices]
            elites = [elite_frames[index] for index in indices]
        else:
            top = start_row * FRAME_SIZE
            bases = _frames_from_grid(
                ordinary_sheet.crop((0, top, 256, top + row_count * 32)),
                (32, 32),
                count,
            )
            elites = _frames_from_grid(
                sheet.crop((0, top, 256, top + row_count * 32)),
                (32, 32),
                count,
            )
        deltas = [_delta(base, elite) for base, elite in zip(bases, elites)]
        for row_index, (row_label, frames) in enumerate(
            (("普通", bases), ("精英", elites), ("差分", deltas))
        ):
            row_y = y + 44 + row_index * 190
            draw.text((24, row_y + 10), row_label, fill=REVIEW_MUTED, font=small)
            preview = _on_background(_strip(frames)).resize(
                (len(frames) * 32 * 5, 32 * 5), Image.Resampling.NEAREST
            )
            canvas.alpha_composite(preview, (120, row_y))
        y += 620

    draw.text((24, y), "BULLET / B1", fill=REVIEW_TEXT, font=label)
    for row_index, (row_label, image) in enumerate(
        (("普通", ordinary_bullet), ("精英", bullet), ("差分", bullet_delta))
    ):
        row_y = y + 44 + row_index * 135
        draw.text((24, row_y + 8), row_label, fill=REVIEW_MUTED, font=small)
        preview = _on_background(image).resize((36 * 14, 8 * 14), Image.Resampling.NEAREST)
        canvas.alpha_composite(preview, (120, row_y))

    path = PREVIEW_DIR / "combat_robot_gunner_elite_final_comparison.png"
    _save_png(canvas, path)
    return path


def _save_outputs(
    sheet: Image.Image,
    bullet: Image.Image,
    ordinary_sheet: Image.Image,
    ordinary_bullet: Image.Image,
) -> dict:
    _save_png(sheet, FINAL_SHEET_PATH)
    _save_png(bullet, FINAL_BULLET_PATH)

    sheet_8x = PREVIEW_DIR / "combat_robot_gunner_elite_final_candidate_8x.png"
    sheet_16x = PREVIEW_DIR / "combat_robot_gunner_elite_final_candidate_16x.png"
    bullet_16x = PREVIEW_DIR / "combat_robot_gunner_elite_bullet_final_candidate_16x.png"
    bullet_24x = PREVIEW_DIR / "combat_robot_gunner_elite_bullet_final_candidate_24x.png"
    _save_png(
        _on_background(sheet).resize((2048, 1536), Image.Resampling.NEAREST),
        sheet_8x,
    )
    _save_png(
        _on_background(sheet).resize((4096, 3072), Image.Resampling.NEAREST),
        sheet_16x,
    )
    _save_png(
        _on_background(bullet).resize((576, 128), Image.Resampling.NEAREST),
        bullet_16x,
    )
    _save_png(
        _on_background(bullet).resize((864, 192), Image.Resampling.NEAREST),
        bullet_24x,
    )
    integer_expected = {
        sheet_8x: _on_background(sheet).resize((2048, 1536), Image.Resampling.NEAREST),
        sheet_16x: _on_background(sheet).resize((4096, 3072), Image.Resampling.NEAREST),
        bullet_16x: _on_background(bullet).resize((576, 128), Image.Resampling.NEAREST),
        bullet_24x: _on_background(bullet).resize((864, 192), Image.Resampling.NEAREST),
    }
    for path, expected in integer_expected.items():
        written = Image.open(path).convert("RGBA")
        if written.tobytes() != expected.tobytes():
            raise AssertionError(f"Integer nearest-neighbor preview changed pixels: {path}")

    sheet_delta = _delta(ordinary_sheet, sheet)
    bullet_delta = _delta(ordinary_bullet, bullet)
    sheet_delta_path = PREVIEW_DIR / "combat_robot_gunner_elite_final_ordinary_delta.png"
    bullet_delta_path = PREVIEW_DIR / "combat_robot_gunner_elite_bullet_final_ordinary_delta.png"
    _save_png(sheet_delta, sheet_delta_path)
    _save_png(bullet_delta, bullet_delta_path)

    move_frames = _frames_from_grid(sheet.crop((0, 0, 256, 32)), (32, 32), 8)
    fire_matrix = _frames_from_grid(sheet.crop((0, 32, 256, 160)), (32, 32), 32)
    fire_timeline, fire_schedule = stage2._build_fire_runtime_timeline(fire_matrix)
    death_frames = _frames_from_grid(sheet.crop((0, 160, 256, 192)), (32, 32), 8)
    bullet_frames = _frames_from_grid(bullet, (12, 8), 3)
    schedule_sha = hashlib.sha256(
        json.dumps(fire_schedule, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()
    if schedule_sha != "133bb0a453b48c745235a469c398d452fc7b1ad273a64b85cebde40b8e73cb7a":
        raise AssertionError("Final fire runtime schedule drifted")

    gifs: dict[str, dict] = {}
    gif_specs = (
        ("move_right", move_frames, 14, 12),
        ("move_left_mirrored", _mirror(move_frames), 14, 12),
        ("fire_right_runtime_timing", fire_timeline, 25, 12),
        ("fire_left_runtime_timing_mirrored", _mirror(fire_timeline), 25, 12),
        ("death_right", death_frames, 12, 12),
        ("death_left_mirrored", _mirror(death_frames), 12, 12),
        ("bullet_right", bullet_frames, 25, 24),
        ("bullet_left_mirrored", _mirror(bullet_frames), 25, 24),
    )
    for key, frames, fps, scale in gif_specs:
        path = PREVIEW_DIR / f"combat_robot_gunner_elite_final_{key}.gif"
        gifs[key] = _save_gif(frames, path, fps, scale)

    comparison_path = _write_comparison(
        sheet,
        bullet,
        ordinary_sheet,
        ordinary_bullet,
        sheet_delta,
        bullet_delta,
    )
    return {
        "final_sheet": _relative(FINAL_SHEET_PATH),
        "final_sheet_size": list(sheet.size),
        "final_sheet_sha256": _sha256(FINAL_SHEET_PATH),
        "final_sheet_rgba_sha256": _rgba_sha256(sheet),
        "final_bullet": _relative(FINAL_BULLET_PATH),
        "final_bullet_size": list(bullet.size),
        "final_bullet_sha256": _sha256(FINAL_BULLET_PATH),
        "final_bullet_rgba_sha256": _rgba_sha256(bullet),
        "integer_sheet_8x": _relative(sheet_8x),
        "integer_sheet_8x_sha256": _sha256(sheet_8x),
        "integer_sheet_16x": _relative(sheet_16x),
        "integer_sheet_16x_sha256": _sha256(sheet_16x),
        "integer_bullet_16x": _relative(bullet_16x),
        "integer_bullet_16x_sha256": _sha256(bullet_16x),
        "integer_bullet_24x": _relative(bullet_24x),
        "integer_bullet_24x_sha256": _sha256(bullet_24x),
        "integer_preview_audit": {
            "nearest_neighbor_only": True,
            "sheet_8x_exact": True,
            "sheet_16x_exact": True,
            "bullet_16x_exact": True,
            "bullet_24x_exact": True,
        },
        "ordinary_delta": _relative(sheet_delta_path),
        "ordinary_delta_sha256": _sha256(sheet_delta_path),
        "bullet_ordinary_delta": _relative(bullet_delta_path),
        "bullet_ordinary_delta_sha256": _sha256(bullet_delta_path),
        "comparison": _relative(comparison_path),
        "comparison_sha256": _sha256(comparison_path),
        "gifs": gifs,
        "fire_timing": {
            "upper_fps": 25,
            "leg_fps": 7,
            "preview_fps": 25,
            "loop_seconds": 8,
            "gif_frames": 200,
            "schedule_sha256": schedule_sha,
            "formula": {
                "upper_phase": "floor(t * 25) % 4",
                "leg_phase": "floor(t * 7) % 8",
                "matrix_index": "upper_phase * 8 + leg_phase",
            },
        },
        "bullet_timing": {"fps": 25, "frames": 3, "loop": True},
    }


def _write_final_manifest(outputs: dict, input_reports: dict) -> dict:
    manifest = {
        "version": 1,
        "asset": "combat_robot_gunner_elite_final_candidate",
        "stage": "final_candidate_pending_third_human_gate",
        "status": "awaiting_final_user_approval",
        "approved_anchor": "G1",
        "approved_selection": dict(APPROVED_SELECTION),
        "final_human_approved": False,
        "runtime_written": False,
        "preview_only": True,
        "imagegen_pixels_imported": False,
        "second_stage_certificates": {
            "report": {
                "path": _relative(STAGE2_REPORT_PATH),
                "sha256": EXPECTED_STAGE2_REPORT_SHA256,
            },
            "manifest": {
                "path": _relative(ANIMATION_MANIFEST_PATH),
                "sha256": EXPECTED_STAGE2_MANIFEST_SHA256,
                "approved_selection": None,
            },
            "stability_report": {
                "path": _relative(STABILITY_REPORT_PATH),
                "sha256": EXPECTED_STABILITY_REPORT_SHA256,
                "approved_selection": None,
            },
        },
        "third_stage": {
        "status": "awaiting_final_user_approval",
        "selection": dict(APPROVED_SELECTION),
        "selected_native_inputs": input_reports,
        "final_sheet": outputs["final_sheet"],
        "final_sheet_size": outputs["final_sheet_size"],
        "final_sheet_sha256": outputs["final_sheet_sha256"],
        "final_bullet": outputs["final_bullet"],
        "final_bullet_size": outputs["final_bullet_size"],
        "final_bullet_sha256": outputs["final_bullet_sha256"],
        "integer_sheet_8x": outputs["integer_sheet_8x"],
        "integer_sheet_8x_sha256": outputs["integer_sheet_8x_sha256"],
        "integer_sheet_16x": outputs["integer_sheet_16x"],
        "integer_sheet_16x_sha256": outputs["integer_sheet_16x_sha256"],
        "integer_bullet_16x": outputs["integer_bullet_16x"],
        "integer_bullet_16x_sha256": outputs["integer_bullet_16x_sha256"],
        "integer_bullet_24x": outputs["integer_bullet_24x"],
        "integer_bullet_24x_sha256": outputs["integer_bullet_24x_sha256"],
        "integer_preview_audit": outputs["integer_preview_audit"],
        "comparison": outputs["comparison"],
        "fire_timing": outputs["fire_timing"],
        "bullet_timing": outputs["bullet_timing"],
        "final_human_approved": False,
        "runtime_written": False,
        },
    }
    _save_json(manifest, FINAL_MANIFEST_PATH)
    return manifest


def build() -> dict:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    stage2_report = _validate_stage2_report()
    runtime_sources = _validate_runtime_sources()
    inputs, input_reports = _load_approved_inputs(stage2_report)
    sheet, bullet = _compose_final_candidates(inputs)
    _validate_storage(sheet, "final robot sheet")
    _validate_storage(bullet, "final bullet sheet")
    exact_copy = _audit_exact_copy(sheet, bullet, inputs)
    ordinary_sheet = Image.open(ORDINARY_SHEET_PATH).convert("RGBA")
    ordinary_bullet = Image.open(ORDINARY_BULLET_PATH).convert("RGBA")
    robot_audit = _audit_robot_frames(sheet, ordinary_sheet)
    bullet_audit = _audit_bullet(bullet)
    outputs = _save_outputs(sheet, bullet, ordinary_sheet, ordinary_bullet)

    # Re-open the PNGs so compressed-file output is also proven pixel-identical.
    written_sheet = Image.open(FINAL_SHEET_PATH).convert("RGBA")
    written_bullet = Image.open(FINAL_BULLET_PATH).convert("RGBA")
    if written_sheet.tobytes() != sheet.tobytes():
        raise AssertionError("Written final sheet changed selected pixels")
    if written_bullet.tobytes() != bullet.tobytes():
        raise AssertionError("Written final bullet changed selected pixels")

    manifest = _write_final_manifest(outputs, input_reports)
    report = {
        "asset": "combat_robot_gunner_elite_final_candidate",
        "stage": "third_human_gate",
        "status": "awaiting_final_user_approval",
        "approved_anchor": "G1",
        "approved_selection": dict(APPROVED_SELECTION),
        "final_human_approved": False,
        "runtime_written": False,
        "preview_only": True,
        "construction": {
            "pixel_sources": "locked second-stage M1/S2/D2/B1 native strips only",
            "selected_pixels_copied_exactly": True,
            "imagegen_pixels_imported": False,
            "resampling_used": False,
            "recoloring_used": False,
            "frames_regenerated": False,
            "runtime_resources_written": False,
        },
        "input_locks": {
            "stage2_report": {
                "path": _relative(STAGE2_REPORT_PATH),
                "sha256": _sha256(STAGE2_REPORT_PATH),
                "expected_sha256": EXPECTED_STAGE2_REPORT_SHA256,
                "sha256_locked": True,
            },
            "stage2_manifest": {
                "path": _relative(ANIMATION_MANIFEST_PATH),
                "sha256": _sha256(ANIMATION_MANIFEST_PATH),
                "expected_sha256": EXPECTED_STAGE2_MANIFEST_SHA256,
                "approved_selection": None,
                "sha256_locked": True,
            },
            "stage2_stability_report": {
                "path": _relative(STABILITY_REPORT_PATH),
                "sha256": _sha256(STABILITY_REPORT_PATH),
                "expected_sha256": EXPECTED_STABILITY_REPORT_SHA256,
                "approved_selection": None,
                "sha256_locked": True,
            },
            "runtime_sources": runtime_sources,
            "selected_native_strips": input_reports,
        },
        "exact_copy_audit": exact_copy,
        "robot_audit": robot_audit,
        "bullet_audit": bullet_audit,
        "outputs": outputs,
        "manifest": {
            "path": _relative(FINAL_MANIFEST_PATH),
            "sha256": _sha256(FINAL_MANIFEST_PATH),
            "stage": manifest["stage"],
            "approved_selection": manifest["approved_selection"],
            "final_human_approved": manifest["final_human_approved"],
            "runtime_written": manifest["runtime_written"],
        },
        "determinism_contract": {
            "all_pixel_inputs_sha256_pinned": True,
            "no_timestamps_or_randomness": True,
            "final_sheet_sha256": outputs["final_sheet_sha256"],
            "final_bullet_sha256": outputs["final_bullet_sha256"],
        },
    }
    _save_json(report, FINAL_REPORT_PATH)
    report["report"] = _relative(FINAL_REPORT_PATH)
    return report


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(build(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
