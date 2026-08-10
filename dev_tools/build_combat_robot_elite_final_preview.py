#!/usr/bin/env python3
"""Assemble the approved elite combat-robot animations for final review.

This third-gate builder only copies pixels from the four approved native strips
created at the second review gate: M1 / W2 / C1 / D2.  It never regenerates a
pose, samples an ImageGen source, or writes below ``resources``.  The resulting
256x128 sheet remains a review candidate under ``dev_assets`` until the user
explicitly approves the final sheet.
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

import build_combat_robot_elite_animation_previews as stage2
from process_combat_robot_assets import detect_torso_bbox


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_elite"
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
ORDINARY_SHEET_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot.png"
)
STAGE2_REPORT_PATH = (
    enemy_asset_report_path("combat_robot_elite_animation_preview_report.json")
)
ANIMATION_MANIFEST_PATH = (
    enemy_asset_report_path("combat_robot_elite_animation_manifest.json")
)
FINAL_SHEET_PATH = SOURCE_DIR / "combat_robot_elite_final_candidate.png"

FRAME_SIZE = 32
SHEET_SIZE = (256, 128)
MAX_VISIBLE_SIZE = 28
BASELINE_BOTTOM = 28
REGISTERED_BODY_CENTER_X = 16.0
TRANSPARENT = (0, 0, 0, 0)

REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)
REVIEW_MUTED = (151, 159, 164, 255)


@dataclass(frozen=True)
class ApprovedStrip:
    key: str
    selection: str
    animation: str
    row: int
    frame_count: int
    fps: int
    loop: bool
    filename: str
    expected_sha256: str

    @property
    def path(self) -> Path:
        return SOURCE_DIR / self.filename


APPROVED_STRIPS: tuple[ApprovedStrip, ...] = (
    ApprovedStrip(
        "move_m1",
        "M1",
        "move",
        0,
        8,
        14,
        True,
        "combat_robot_elite_move_m1_candidate_native.png",
        "83cd6695b84b563069cc1922ae3e0fb219a0272100c6a3f12637a72a25e37ed1",
    ),
    ApprovedStrip(
        "windup_w2",
        "W2",
        "windup",
        1,
        4,
        10,
        False,
        "combat_robot_elite_windup_w2_candidate_native.png",
        "cdece91c77011c5bfd65b106f028921bd7519576911fab3b121bcb70ea59dc5b",
    ),
    ApprovedStrip(
        "dash_c1",
        "C1",
        "dash",
        2,
        4,
        12,
        True,
        "combat_robot_elite_dash_c1_candidate_native.png",
        "9fafec02ebd496f3733c08539571f141dff65c87f38e19d6242e5d5e1f1b699e",
    ),
    ApprovedStrip(
        "death_d2",
        "D2",
        "death",
        3,
        8,
        12,
        False,
        "combat_robot_elite_death_d2_candidate_native.png",
        "d2054e276becc0f98bbe33dabecc90d95350890455a13b0a4e25b73d242b4f65",
    ),
)

APPROVED_SELECTION = {
    "move": "M1",
    "windup": "W2",
    "dash": "C1",
    "death": "D2",
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _empty(size: tuple[int, int]) -> Image.Image:
    return Image.new("RGBA", size, TRANSPARENT)


def _frames_from_strip(strip: Image.Image, frame_count: int) -> list[Image.Image]:
    return [
        strip.crop((index * FRAME_SIZE, 0, (index + 1) * FRAME_SIZE, FRAME_SIZE))
        for index in range(frame_count)
    ]


def _ordinary_frames(spec: ApprovedStrip) -> list[Image.Image]:
    ordinary = Image.open(ORDINARY_SHEET_PATH).convert("RGBA")
    if ordinary.size != SHEET_SIZE:
        raise AssertionError(f"Unexpected ordinary sheet size: {ordinary.size}")
    return [
        ordinary.crop(
            (
                index * FRAME_SIZE,
                spec.row * FRAME_SIZE,
                (index + 1) * FRAME_SIZE,
                (spec.row + 1) * FRAME_SIZE,
            )
        )
        for index in range(spec.frame_count)
    ]


def _load_stage2_report() -> dict[str, object]:
    if not STAGE2_REPORT_PATH.is_file():
        raise FileNotFoundError(STAGE2_REPORT_PATH)
    report = json.loads(STAGE2_REPORT_PATH.read_text(encoding="utf-8"))
    if report.get("runtime_written") is not False:
        raise AssertionError("Second-stage report must remain review-only")
    if report.get("approved_anchor") != "A1":
        raise AssertionError("Third stage requires the approved A1 anchor")
    return report


def _load_approved_strips(
    stage2_report: dict[str, object],
) -> tuple[dict[str, Image.Image], dict[str, dict[str, object]]]:
    strips: dict[str, Image.Image] = {}
    reports: dict[str, dict[str, object]] = {}
    for spec in APPROVED_STRIPS:
        if not spec.path.is_file():
            raise FileNotFoundError(spec.path)
        expected_size = (spec.frame_count * FRAME_SIZE, FRAME_SIZE)
        strip = Image.open(spec.path).convert("RGBA")
        if strip.size != expected_size:
            raise AssertionError(
                f"{spec.key} native size {strip.size} != {expected_size}"
            )
        actual_sha = _sha256(spec.path)
        report_output = stage2_report["outputs"][spec.key]
        report_audit = stage2_report["animation_audit"][spec.key]
        if report_output["native_strip"] != _relative(spec.path):
            raise AssertionError(f"{spec.key} path differs from second-stage report")
        if report_output["native_sha256"] != actual_sha:
            raise AssertionError(f"{spec.key} SHA differs from second-stage report")
        if actual_sha != spec.expected_sha256:
            raise AssertionError(
                f"{spec.key} SHA changed: {actual_sha} != {spec.expected_sha256}"
            )
        expected_contract = (spec.frame_count, spec.fps, spec.loop)
        report_contract = (
            report_audit["frame_count"],
            report_audit["fps"],
            report_audit["loop"],
        )
        if report_contract != expected_contract:
            raise AssertionError(
                f"{spec.key} animation contract changed: {report_contract}"
            )
        strips[spec.animation] = strip
        reports[spec.animation] = {
            "selection": spec.selection,
            "candidate_key": spec.key,
            "path": _relative(spec.path),
            "size": list(strip.size),
            "sha256": actual_sha,
            "candidate_sha_matches_constant": True,
            "candidate_sha_matches_stage2_report": True,
            "frame_count": spec.frame_count,
            "fps": spec.fps,
            "loop": spec.loop,
        }
    return strips, reports


def _compose_final_sheet(strips: dict[str, Image.Image]) -> Image.Image:
    sheet = _empty(SHEET_SIZE)
    for spec in APPROVED_STRIPS:
        sheet.alpha_composite(strips[spec.animation], (0, spec.row * FRAME_SIZE))
    return sheet


def _frame_metrics(frame: Image.Image) -> dict[str, object]:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Approved frame is empty")
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    return {
        "bbox": list(bbox),
        "visible_size": [width, height],
        "baseline_bottom": bbox[3],
        "visible_pixels": sum(pixel[3] != 0 for pixel in frame.getdata()),
        "rgba_sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
    }


def _audit_frame(
    spec: ApprovedStrip,
    frame_index: int,
    frame: Image.Image,
    ordinary: Image.Image,
) -> dict[str, object]:
    metrics = _frame_metrics(frame)
    if metrics["visible_size"][0] > MAX_VISIBLE_SIZE or metrics["visible_size"][1] > MAX_VISIBLE_SIZE:
        raise AssertionError(
            f"{spec.animation}[{frame_index}] exceeds 28x28: {metrics}"
        )
    if metrics["baseline_bottom"] != BASELINE_BOTTOM:
        raise AssertionError(
            f"{spec.animation}[{frame_index}] baseline drift: {metrics}"
        )

    accent_points = stage2._accent_points(ordinary)
    reinforcement = set(stage2._reinforcement_stamp(spec.key, frame_index))
    allowed_differences = accent_points | reinforcement
    purple_points: set[tuple[int, int]] = set()
    changed_points: set[tuple[int, int]] = set()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            point = (x, y)
            ordinary_pixel = ordinary.getpixel(point)
            pixel = frame.getpixel(point)
            if pixel != ordinary_pixel:
                changed_points.add(point)
                if point not in allowed_differences:
                    raise AssertionError(
                        f"{spec.animation}[{frame_index}] changes ordinary pixel outside whitelist: {point}"
                    )
            if pixel in stage2.PURPLE_RAMP:
                purple_points.add(point)
            if pixel in stage2.ORDINARY_ACCENTS:
                raise AssertionError(
                    f"{spec.animation}[{frame_index}] retains red/orange at {point}"
                )
            if pixel not in stage2.ALLOWED_PALETTE:
                raise AssertionError(
                    f"{spec.animation}[{frame_index}] uses non-contract color {pixel}"
                )
            if pixel[3] not in (0, 255):
                raise AssertionError(
                    f"{spec.animation}[{frame_index}] alpha is not binary at {point}"
                )
            if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
                raise AssertionError(
                    f"{spec.animation}[{frame_index}] transparent RGB is nonzero at {point}"
                )
    if purple_points != accent_points:
        raise AssertionError(
            f"{spec.animation}[{frame_index}] purple mask differs from ordinary accent mask"
        )

    torso_center_x: float | None = None
    if spec.animation != "death":
        torso_bbox = detect_torso_bbox(frame)
        torso_center_x = (torso_bbox[0] + torso_bbox[2]) * 0.5
        if abs(torso_center_x - REGISTERED_BODY_CENTER_X) > 1.5:
            raise AssertionError(
                f"{spec.animation}[{frame_index}] torso center {torso_center_x} drifted from x=16"
            )

    return {
        **metrics,
        "registered_frame_origin": [REGISTERED_BODY_CENTER_X, BASELINE_BOTTOM],
        "living_torso_center_x": torso_center_x,
        "ordinary_accent_pixels": len(accent_points),
        "purple_pixels": len(purple_points),
        "reinforcement_whitelist_pixels": len(reinforcement),
        "changed_pixels": len(changed_points),
        "ordinary_inheritance_outside_whitelist": True,
        "red_orange_remaining": 0,
        "binary_alpha": True,
        "transparent_rgb_zero": True,
    }


def _audit_final_sheet(
    sheet: Image.Image,
    strips: dict[str, Image.Image],
) -> dict[str, object]:
    if sheet.size != SHEET_SIZE:
        raise AssertionError(f"Final sheet size {sheet.size} != {SHEET_SIZE}")
    for red, green, blue, alpha in sheet.getdata():
        if alpha not in (0, 255):
            raise AssertionError("Final sheet alpha must be binary")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError("Final sheet transparent RGB must be zero")

    animation_reports: dict[str, dict[str, object]] = {}
    for spec in APPROVED_STRIPS:
        source_frames = _frames_from_strip(strips[spec.animation], spec.frame_count)
        ordinary_frames = _ordinary_frames(spec)
        final_frames: list[Image.Image] = []
        frame_reports: list[dict[str, object]] = []
        for frame_index in range(spec.frame_count):
            final_frame = sheet.crop(
                (
                    frame_index * FRAME_SIZE,
                    spec.row * FRAME_SIZE,
                    (frame_index + 1) * FRAME_SIZE,
                    (spec.row + 1) * FRAME_SIZE,
                )
            )
            if final_frame.tobytes() != source_frames[frame_index].tobytes():
                raise AssertionError(
                    f"{spec.animation}[{frame_index}] differs from approved native strip"
                )
            final_frames.append(final_frame)
            frame_reports.append(
                _audit_frame(
                    spec,
                    frame_index,
                    final_frame,
                    ordinary_frames[frame_index],
                )
            )

        # The unused right half of four-frame rows must remain exactly RGBA zero.
        unused_cells_transparent = True
        if spec.frame_count == 4:
            unused = sheet.crop(
                (
                    spec.frame_count * FRAME_SIZE,
                    spec.row * FRAME_SIZE,
                    SHEET_SIZE[0],
                    (spec.row + 1) * FRAME_SIZE,
                )
            )
            unused_cells_transparent = all(pixel == TRANSPARENT for pixel in unused.getdata())
            if not unused_cells_transparent:
                raise AssertionError(f"{spec.animation} unused atlas cells are not transparent")

        animation_reports[spec.animation] = {
            "selection": spec.selection,
            "candidate_key": spec.key,
            "row": spec.row,
            "frame_count": spec.frame_count,
            "fps": spec.fps,
            "loop": spec.loop,
            "source_strip_sha256": spec.expected_sha256,
            "final_frames_equal_approved_strip": True,
            "unused_right_cells_transparent": unused_cells_transparent,
            "frames": frame_reports,
        }
    return {
        "sheet_size": list(sheet.size),
        "frame_size": [FRAME_SIZE, FRAME_SIZE],
        "grid": [8, 4],
        "registered_frame_origin": [REGISTERED_BODY_CENTER_X, BASELINE_BOTTOM],
        "binary_alpha": True,
        "transparent_rgb_zero": True,
        "red_orange_remaining": 0,
        "animations": animation_reports,
    }


def _on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, REVIEW_BACKGROUND)
    result.alpha_composite(image)
    return result


def _save_gif(
    frames: Sequence[Image.Image],
    path: Path,
    fps: int,
    mirrored: bool,
) -> None:
    rendered: list[Image.Image] = []
    for frame in frames:
        pose = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if mirrored else frame
        rendered.append(
            _on_background(pose)
            .resize((FRAME_SIZE * 16, FRAME_SIZE * 16), Image.Resampling.NEAREST)
            .convert("P", palette=Image.Palette.ADAPTIVE, colors=64)
        )
    rendered[0].save(
        path,
        save_all=True,
        append_images=rendered[1:],
        duration=max(1, round(1000 / fps)),
        loop=0,
        disposal=2,
        optimize=False,
    )


def _save_state_transition_gif(
    strips: dict[str, Image.Image],
    path: Path,
) -> None:
    """Preview the real M1 -> W2 -> C1 -> M1 state boundary at native rates."""

    phases = (
        ("move", 4, 14),
        ("windup", 4, 10),
        ("dash", 4, 12),
        ("move", 4, 14),
    )
    rendered: list[Image.Image] = []
    durations: list[int] = []
    for animation, frame_count, fps in phases:
        for frame in _frames_from_strip(strips[animation], frame_count):
            rendered.append(
                _on_background(frame)
                .resize((FRAME_SIZE * 16, FRAME_SIZE * 16), Image.Resampling.NEAREST)
                .convert("P", palette=Image.Palette.ADAPTIVE, colors=64)
            )
            durations.append(max(1, round(1000 / fps)))
    rendered[0].save(
        path,
        save_all=True,
        append_images=rendered[1:],
        duration=durations,
        loop=0,
        disposal=2,
        optimize=False,
    )


def _delta_frames(
    ordinary: Sequence[Image.Image],
    elite: Sequence[Image.Image],
) -> list[Image.Image]:
    result: list[Image.Image] = []
    for base, candidate in zip(ordinary, elite):
        frame = _empty((FRAME_SIZE, FRAME_SIZE))
        pixels = frame.load()
        for y in range(FRAME_SIZE):
            for x in range(FRAME_SIZE):
                before = base.getpixel((x, y))
                after = candidate.getpixel((x, y))
                if before == after and before[3]:
                    pixels[x, y] = (112, 121, 128, 120)
                elif before[3] == 0 and after[3]:
                    pixels[x, y] = (238, 80, 205, 255)
                elif before[3] and after[3] == 0:
                    pixels[x, y] = (60, 210, 235, 255)
                elif before != after:
                    pixels[x, y] = (197, 138, 255, 255)
        result.append(frame)
    return result


def _strip(frames: Sequence[Image.Image]) -> Image.Image:
    result = _empty((len(frames) * FRAME_SIZE, FRAME_SIZE))
    for index, frame in enumerate(frames):
        result.alpha_composite(frame, (index * FRAME_SIZE, 0))
    return result


def _font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _write_comparison(
    sheet: Image.Image,
    strips: dict[str, Image.Image],
) -> Path:
    width = 2240
    header_height = 650
    section_height = 860
    canvas = Image.new(
        "RGBA",
        (width, header_height + len(APPROVED_STRIPS) * section_height),
        REVIEW_BACKGROUND,
    )
    draw = ImageDraw.Draw(canvas)
    title_font = _font(30)
    label_font = _font(20)
    small_font = _font(15)
    draw.text((24, 18), "精英战斗机器人 — 第三阶段最终候选", fill=REVIEW_TEXT, font=title_font)
    draw.text(
        (24, 60),
        "已选 M1 / W2 / C1 / D2；仍待最终人工批准，runtime_written=false",
        fill=REVIEW_MUTED,
        font=small_font,
    )
    final_preview = _on_background(sheet).resize((1024, 512), Image.Resampling.NEAREST)
    canvas.alpha_composite(final_preview, (24, 106))
    draw.text((1080, 106), "256×128最终候选（4倍）", fill=REVIEW_TEXT, font=label_font)
    draw.text((1080, 144), "row0 move M1 — 8帧 @14FPS", fill=REVIEW_MUTED, font=small_font)
    draw.text((1080, 174), "row1 windup W2 — 4帧 @10FPS，右4格透明", fill=REVIEW_MUTED, font=small_font)
    draw.text((1080, 204), "row2 dash C1 — 4帧 @12FPS，右4格透明", fill=REVIEW_MUTED, font=small_font)
    draw.text((1080, 234), "row3 death D2 — 8帧 @12FPS", fill=REVIEW_MUTED, font=small_font)

    for section, spec in enumerate(APPROVED_STRIPS):
        top = header_height + section * section_height
        elite_frames = _frames_from_strip(strips[spec.animation], spec.frame_count)
        ordinary_frames = _ordinary_frames(spec)
        delta_frames = _delta_frames(ordinary_frames, elite_frames)
        draw.text(
            (24, top + 8),
            f"{spec.animation.upper()} / {spec.selection} — 普通版、精英版、差分",
            fill=REVIEW_TEXT,
            font=label_font,
        )
        for row, (label, frames) in enumerate(
            (("ORDINARY", ordinary_frames), ("ELITE", elite_frames), ("DELTA", delta_frames))
        ):
            y = top + 62 + row * 266
            draw.text((24, y), label, fill=REVIEW_MUTED, font=small_font)
            rendered = _on_background(_strip(frames)).resize(
                (FRAME_SIZE * spec.frame_count * 8, FRAME_SIZE * 8),
                Image.Resampling.NEAREST,
            )
            canvas.alpha_composite(rendered, (144, y))
    path = PREVIEW_DIR / "combat_robot_elite_final_comparison.png"
    canvas.save(path, optimize=True)
    return path


def _save_outputs(
    sheet: Image.Image,
    strips: dict[str, Image.Image],
) -> dict[str, object]:
    sheet.save(FINAL_SHEET_PATH, optimize=True)
    sheet_16x_path = PREVIEW_DIR / "combat_robot_elite_final_candidate_16x.png"
    _on_background(sheet).resize(
        (sheet.width * 16, sheet.height * 16), Image.Resampling.NEAREST
    ).save(sheet_16x_path, optimize=True)

    gifs: dict[str, dict[str, object]] = {}
    for spec in APPROVED_STRIPS:
        frames = _frames_from_strip(strips[spec.animation], spec.frame_count)
        right_path = PREVIEW_DIR / f"combat_robot_elite_final_{spec.animation}_right.gif"
        left_path = PREVIEW_DIR / f"combat_robot_elite_final_{spec.animation}_left_mirrored.gif"
        _save_gif(frames, right_path, spec.fps, mirrored=False)
        _save_gif(frames, left_path, spec.fps, mirrored=True)
        gifs[spec.animation] = {
            "right_facing": _relative(right_path),
            "right_facing_sha256": _sha256(right_path),
            "left_facing_mirrored": _relative(left_path),
            "left_facing_mirrored_sha256": _sha256(left_path),
            "frame_count": spec.frame_count,
            "fps": spec.fps,
            "runtime_loop": spec.loop,
        }

    state_transition_path = (
        PREVIEW_DIR / "combat_robot_elite_final_state_transition.gif"
    )
    _save_state_transition_gif(strips, state_transition_path)

    comparison_path = _write_comparison(sheet, strips)
    return {
        "final_candidate": _relative(FINAL_SHEET_PATH),
        "final_candidate_size": list(sheet.size),
        "final_candidate_sha256": _sha256(FINAL_SHEET_PATH),
        "integer_16x": _relative(sheet_16x_path),
        "integer_16x_sha256": _sha256(sheet_16x_path),
        "comparison": _relative(comparison_path),
        "comparison_sha256": _sha256(comparison_path),
        "state_transition": _relative(state_transition_path),
        "state_transition_sha256": _sha256(state_transition_path),
        "gifs": gifs,
    }


def _update_manifest(outputs: dict[str, object]) -> dict[str, object]:
    if not ANIMATION_MANIFEST_PATH.is_file():
        raise FileNotFoundError(ANIMATION_MANIFEST_PATH)
    manifest = json.loads(ANIMATION_MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("runtime_written") is not False:
        raise AssertionError("Animation manifest must remain review-only")
    manifest["stage"] = "final_candidate_pending_third_human_gate"
    manifest["approved_selection"] = dict(APPROVED_SELECTION)
    manifest["final_human_approved"] = False
    manifest["runtime_written"] = False
    manifest["third_stage"] = {
        "status": "awaiting_final_user_approval",
        "final_human_approved": False,
        "final_candidate": outputs["final_candidate"],
        "final_candidate_size": outputs["final_candidate_size"],
        "final_candidate_sha256": outputs["final_candidate_sha256"],
        "integer_16x": outputs["integer_16x"],
        "comparison": outputs["comparison"],
        "state_transition": outputs["state_transition"],
        "runtime_written": False,
    }
    ANIMATION_MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return manifest


def _ensure_review_only() -> None:
    runtime_root = (PROJECT_ROOT / "resources").resolve()
    for output_root in (SOURCE_DIR.resolve(), PREVIEW_DIR.resolve()):
        if output_root == runtime_root or runtime_root in output_root.parents:
            raise AssertionError("Final preview output overlaps runtime resources")


def build() -> dict[str, object]:
    _ensure_review_only()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    if not ORDINARY_SHEET_PATH.is_file():
        raise FileNotFoundError(ORDINARY_SHEET_PATH)

    stage2_report = _load_stage2_report()
    strips, input_reports = _load_approved_strips(stage2_report)
    sheet = _compose_final_sheet(strips)
    audit = _audit_final_sheet(sheet, strips)
    outputs = _save_outputs(sheet, strips)
    manifest = _update_manifest(outputs)

    report: dict[str, object] = {
        "asset": "combat_robot_elite_final_candidate",
        "stage": "third_human_gate",
        "status": "awaiting_final_user_approval",
        "approved_selection": dict(APPROVED_SELECTION),
        "final_human_approved": False,
        "runtime_written": False,
        "construction": {
            "pixel_sources": "approved native M1/W2/C1/D2 strips only",
            "imagegen_pixels_imported": False,
            "frames_regenerated": False,
            "runtime_resources_written": False,
            "ordinary_sheet": _relative(ORDINARY_SHEET_PATH),
            "ordinary_sheet_sha256": _sha256(ORDINARY_SHEET_PATH),
            "stage2_report": _relative(STAGE2_REPORT_PATH),
            "stage2_report_sha256": _sha256(STAGE2_REPORT_PATH),
        },
        "approved_inputs": input_reports,
        "sheet_audit": audit,
        "outputs": outputs,
        "manifest": {
            "path": _relative(ANIMATION_MANIFEST_PATH),
            "sha256": _sha256(ANIMATION_MANIFEST_PATH),
            "stage": manifest["stage"],
            "approved_selection": manifest["approved_selection"],
            "final_human_approved": manifest["final_human_approved"],
            "runtime_written": manifest["runtime_written"],
            "third_stage_status": manifest["third_stage"]["status"],
        },
        "determinism_contract": {
            "all_inputs_sha256_pinned": True,
            "no_timestamps_or_randomness": True,
            "output_sha256": outputs["final_candidate_sha256"],
        },
    }
    report_path = enemy_asset_report_path("combat_robot_elite_final_preview_report.json")
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report["report"] = _relative(report_path)
    return report


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(build(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
