#!/usr/bin/env python3
"""Build deterministic second-gate previews for the elite combat robot.

The eight ImageGen boards are design-language references only.  Runtime-scale
candidate pixels always start from the audited ordinary combat-robot sheet and
the approved native A1 anchor.  The script maps the ordinary functional accent
mask to an approved purple ramp and applies explicit gray A1 reinforcement
stamps; it never resizes or samples generated pixels into a native frame.

Every output is written below ``dev_assets``.  Nothing below ``resources`` is
created or modified by this review-only builder.
"""

from __future__ import annotations

import hashlib
import json
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Iterable, Sequence

from PIL import Image, ImageDraw, ImageFont

from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, normalize_source


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
APPROVED_ANCHOR_PATH = (
    SOURCE_DIR / "combat_robot_elite_anchor_a1_approved_native32.png"
)

FRAME_SIZE = 32
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
REGISTERED_BODY_CENTER_X = 16.0
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
BLADE_HIGHLIGHT = PALETTE[7]

PURPLE_RAMP: tuple[tuple[int, int, int, int], ...] = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)

ORDINARY_ACCENTS: frozenset[tuple[int, int, int, int]] = frozenset(
    {
        (102, 25, 20, 255),
        (190, 48, 31, 255),
        (239, 92, 34, 255),
        (255, 181, 71, 255),
        (255, 0, 0, 255),
        (236, 28, 36, 255),
        (185, 75, 80, 255),
    }
)

ALLOWED_PALETTE = frozenset((*PALETTE[:8], *PURPLE_RAMP, TRANSPARENT))


@dataclass(frozen=True)
class CandidateSpec:
    key: str
    animation: str
    source_file: str
    frame_count: int
    fps: int
    loop: bool
    label: str
    design: str


CANDIDATE_SPECS: tuple[CandidateSpec, ...] = (
    CandidateSpec(
        "move_m1",
        "move",
        "combat_robot_elite_move_m1_imagegen.png",
        8,
        14,
        True,
        "M1 刚性稳定肩盖",
        "A1灰色强化件逐帧刚性固定；保留普通版两段轻微紫色明暗。",
    ),
    CandidateSpec(
        "move_m2",
        "move",
        "combat_robot_elite_move_m2_imagegen.png",
        8,
        14,
        True,
        "M2 承重侧高光",
        "强化件轮廓固定；单像素肩部高光按步态半周期换侧。",
    ),
    CandidateSpec(
        "windup_w1",
        "windup",
        "combat_robot_elite_windup_w1_imagegen.png",
        4,
        10,
        False,
        "W1 整体递增充能",
        "眼槽整体递增，定向矩形剑格逐帧跟随普通版握点。",
    ),
    CandidateSpec(
        "windup_w2",
        "windup",
        "combat_robot_elite_windup_w2_imagegen.png",
        4,
        10,
        False,
        "W2 横向锁定扫描",
        "仅在既有六个眼槽像素内执行横向扫描，不新增剑功能点。",
    ),
    CandidateSpec(
        "dash_c1",
        "dash",
        "combat_robot_elite_dash_c1_imagegen.png",
        4,
        12,
        True,
        "C1 刚性持续高能",
        "上半身、强化件与紫色强度全部固定，冲刺时不产生频闪。",
    ),
    CandidateSpec(
        "dash_c2",
        "dash",
        "combat_robot_elite_dash_c2_imagegen.png",
        4,
        12,
        True,
        "C2 前向高光脉冲",
        "强化件轮廓固定，灰色高光偏向前侧，既有功能色轻微脉冲。",
    ),
    CandidateSpec(
        "death_d1",
        "death",
        "combat_robot_elite_death_d1_imagegen.png",
        8,
        12,
        False,
        "D1 完整重装外露",
        "八帧显式强化件点表；倒地时全部强化件保持可见并产生一次泄能闪光。",
    ),
    CandidateSpec(
        "death_d2",
        "death",
        "combat_robot_elite_death_d2_imagegen.png",
        8,
        12,
        False,
        "D2 遮挡式倒地断电",
        "八帧显式强化件点表；倒地后部件保持连接但逐步被机体遮挡。",
    ),
)


PointMap = dict[tuple[int, int], tuple[int, int, int, int]]


# Approved A1 native structure, excluding the ordinary functional accent pixels.
A1_BODY_STAMP: PointMap = {
    (9, 15): OUTLINE,
    (9, 16): OUTLINE,
    (10, 14): OUTLINE,
    (10, 15): DARK_STEEL,
    (11, 15): MID_STEEL,
    (21, 15): MID_STEEL,
    (22, 15): OUTLINE,
    (21, 16): DARK_STEEL,
    (22, 16): OUTLINE,
    (15, 9): OUTLINE,
    (16, 9): DARK_STEEL,
    (17, 9): MID_STEEL,
    (18, 9): DARK_STEEL,
    (19, 9): OUTLINE,
}

A1_MOVE_GUARD_STAMP: PointMap = {
    (22, 19): OUTLINE,
    (23, 19): DARK_STEEL,
    (24, 19): OUTLINE,
    (22, 22): OUTLINE,
    (23, 22): DARK_STEEL,
}


WINDUP_GUARD_STAMPS: tuple[PointMap, ...] = (
    dict(A1_MOVE_GUARD_STAMP),
    {
        (23, 14): OUTLINE,
        (24, 15): DARK_STEEL,
        (25, 16): OUTLINE,
        (22, 16): OUTLINE,
        (23, 17): MID_STEEL,
        (24, 18): OUTLINE,
    },
    {
        (8, 14): OUTLINE,
        (9, 14): DARK_STEEL,
        (10, 14): OUTLINE,
        (8, 15): OUTLINE,
        (9, 15): MID_STEEL,
        (10, 15): OUTLINE,
    },
    {
        (8, 9): OUTLINE,
        (9, 10): DARK_STEEL,
        (10, 11): OUTLINE,
        (9, 8): OUTLINE,
        (10, 9): MID_STEEL,
        (11, 10): OUTLINE,
    },
)

DASH_GUARD_BALANCED: PointMap = {
    (23, 15): OUTLINE,
    (24, 15): DARK_STEEL,
    (23, 19): OUTLINE,
    (24, 19): DARK_STEEL,
}

DASH_GUARD_FORWARD: PointMap = {
    (23, 15): OUTLINE,
    (24, 15): MID_STEEL,
    (23, 19): OUTLINE,
    (24, 19): MID_STEEL,
}


@dataclass(frozen=True)
class DeathStamp:
    roof: tuple[tuple[tuple[int, int], tuple[int, int, int, int]], ...]
    rear_shoulder: tuple[tuple[tuple[int, int], tuple[int, int, int, int]], ...]
    front_shoulder: tuple[tuple[tuple[int, int], tuple[int, int, int, int]], ...]
    guard: tuple[tuple[tuple[int, int], tuple[int, int, int, int]], ...]

    def full_map(self) -> PointMap:
        return dict((*self.roof, *self.rear_shoulder, *self.front_shoulder, *self.guard))


def _pairs(points: PointMap) -> tuple[tuple[tuple[int, int], tuple[int, int, int, int]], ...]:
    return tuple(points.items())


def _shift_points(points: PointMap, offset_y: int) -> PointMap:
    return {(x, y + offset_y): color for (x, y), color in points.items()}


DEATH_FULL_STAMPS: tuple[DeathStamp, ...] = (
    DeathStamp(
        _pairs({point: color for point, color in A1_BODY_STAMP.items() if point[1] == 9}),
        _pairs({point: color for point, color in A1_BODY_STAMP.items() if point[0] <= 11 and point[1] >= 14}),
        _pairs({point: color for point, color in A1_BODY_STAMP.items() if point[0] >= 21}),
        _pairs(A1_MOVE_GUARD_STAMP),
    ),
    DeathStamp(
        _pairs(_shift_points({point: color for point, color in A1_BODY_STAMP.items() if point[1] == 9}, 1)),
        _pairs(_shift_points({point: color for point, color in A1_BODY_STAMP.items() if point[0] <= 11 and point[1] >= 14}, 1)),
        _pairs(_shift_points({point: color for point, color in A1_BODY_STAMP.items() if point[0] >= 21}, 1)),
        _pairs(_shift_points(A1_MOVE_GUARD_STAMP, 1)),
    ),
    DeathStamp(
        _pairs(_shift_points({point: color for point, color in A1_BODY_STAMP.items() if point[1] == 9}, 2)),
        _pairs(_shift_points({point: color for point, color in A1_BODY_STAMP.items() if point[0] <= 11 and point[1] >= 14}, 2)),
        _pairs(_shift_points({point: color for point, color in A1_BODY_STAMP.items() if point[0] >= 21}, 2)),
        _pairs(_shift_points(A1_MOVE_GUARD_STAMP, 2)),
    ),
    DeathStamp(
        _pairs({(15, 12): OUTLINE, (16, 12): DARK_STEEL, (17, 12): MID_STEEL, (18, 12): DARK_STEEL, (19, 12): OUTLINE}),
        _pairs({(12, 14): OUTLINE, (11, 15): OUTLINE, (12, 15): DARK_STEEL, (13, 15): MID_STEEL, (11, 16): OUTLINE}),
        _pairs({(21, 14): MID_STEEL, (22, 14): OUTLINE, (21, 15): DARK_STEEL, (22, 15): OUTLINE}),
        _pairs({(19, 24): OUTLINE, (20, 24): DARK_STEEL, (21, 24): OUTLINE, (19, 27): OUTLINE, (20, 27): DARK_STEEL}),
    ),
    DeathStamp(
        _pairs({(13, 15): OUTLINE, (14, 15): DARK_STEEL, (15, 15): MID_STEEL, (16, 15): DARK_STEEL, (17, 15): OUTLINE}),
        _pairs({(10, 17): OUTLINE, (9, 18): OUTLINE, (10, 18): DARK_STEEL, (11, 18): MID_STEEL, (9, 19): OUTLINE}),
        _pairs({(18, 18): MID_STEEL, (19, 18): OUTLINE, (18, 19): DARK_STEEL, (19, 19): OUTLINE}),
        _pairs({(17, 24): OUTLINE, (18, 24): DARK_STEEL, (19, 24): OUTLINE, (17, 27): OUTLINE, (18, 27): DARK_STEEL}),
    ),
    DeathStamp(
        _pairs({(14, 17): OUTLINE, (15, 17): DARK_STEEL, (16, 17): MID_STEEL, (17, 17): DARK_STEEL, (18, 17): OUTLINE}),
        _pairs({(11, 19): OUTLINE, (10, 20): OUTLINE, (11, 20): DARK_STEEL, (12, 20): MID_STEEL, (10, 21): OUTLINE}),
        _pairs({(19, 19): MID_STEEL, (20, 19): OUTLINE, (19, 20): DARK_STEEL, (20, 20): OUTLINE}),
        _pairs({(18, 24): OUTLINE, (19, 24): DARK_STEEL, (20, 24): OUTLINE, (18, 27): OUTLINE, (19, 27): DARK_STEEL}),
    ),
    DeathStamp(
        _pairs({(14, 19): OUTLINE, (15, 19): DARK_STEEL, (16, 19): MID_STEEL, (17, 19): DARK_STEEL, (18, 19): OUTLINE}),
        _pairs({(11, 21): OUTLINE, (10, 22): OUTLINE, (11, 22): DARK_STEEL, (12, 22): MID_STEEL, (10, 23): OUTLINE}),
        _pairs({(19, 21): MID_STEEL, (20, 21): OUTLINE, (19, 22): DARK_STEEL, (20, 22): OUTLINE}),
        _pairs({(19, 24): OUTLINE, (20, 24): DARK_STEEL, (21, 24): OUTLINE, (19, 27): OUTLINE, (20, 27): DARK_STEEL}),
    ),
    DeathStamp(
        _pairs({(13, 19): OUTLINE, (14, 19): DARK_STEEL, (15, 19): MID_STEEL, (16, 19): DARK_STEEL, (17, 19): OUTLINE}),
        _pairs({(10, 21): OUTLINE, (9, 22): OUTLINE, (10, 22): DARK_STEEL, (11, 22): MID_STEEL, (9, 23): OUTLINE}),
        _pairs({(18, 21): MID_STEEL, (19, 21): OUTLINE, (18, 22): DARK_STEEL, (19, 22): OUTLINE}),
        _pairs({(19, 24): OUTLINE, (20, 24): DARK_STEEL, (21, 24): OUTLINE, (19, 27): OUTLINE, (20, 27): DARK_STEEL}),
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


def _empty(size: tuple[int, int] = (FRAME_SIZE, FRAME_SIZE)) -> Image.Image:
    return Image.new("RGBA", size, TRANSPARENT)


def _ordinary_frames(animation: str, frame_count: int) -> list[Image.Image]:
    row_by_animation = {"move": 0, "windup": 1, "dash": 2, "death": 3}
    sheet = Image.open(ORDINARY_SHEET_PATH).convert("RGBA")
    if sheet.size != (256, 128):
        raise AssertionError(f"Unexpected ordinary sheet size: {sheet.size}")
    row = row_by_animation[animation]
    return [
        sheet.crop((index * 32, row * 32, index * 32 + 32, row * 32 + 32))
        for index in range(frame_count)
    ]


def _accent_points(frame: Image.Image) -> set[tuple[int, int]]:
    return {
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if frame.getpixel((x, y)) in ORDINARY_ACCENTS
    }


def _is_living_antenna(point: tuple[int, int]) -> bool:
    return point in {(13, 7), (13, 8)}


def _is_living_eye(point: tuple[int, int]) -> bool:
    x, y = point
    return x in (15, 16, 17) and y in (13, 14)


def _accent_color(
    candidate: str,
    frame_index: int,
    point: tuple[int, int],
) -> tuple[int, int, int, int]:
    if candidate == "move_m1":
        if _is_living_antenna(point) or _is_living_eye(point):
            return PURPLE_RAMP[1 if frame_index in (0, 1, 4, 5) else 2]
        return PURPLE_RAMP[4]
    if candidate == "move_m2":
        return PURPLE_RAMP[2] if (_is_living_antenna(point) or _is_living_eye(point)) else PURPLE_RAMP[4]
    if candidate == "windup_w1":
        eye_levels = (1, 2, 4, 5)
        antenna_levels = (0, 1, 3, 4)
        return PURPLE_RAMP[antenna_levels[frame_index] if _is_living_antenna(point) else eye_levels[frame_index]]
    if candidate == "windup_w2":
        if _is_living_antenna(point):
            return PURPLE_RAMP[(0, 1, 3, 5)[frame_index]]
        x, _y = point
        scan_levels = (
            {15: 1, 16: 1, 17: 1},
            {15: 4, 16: 1, 17: 1},
            {15: 2, 16: 5, 17: 2},
            {15: 2, 16: 4, 17: 5},
        )
        return PURPLE_RAMP[scan_levels[frame_index][x]]
    if candidate == "dash_c1":
        return PURPLE_RAMP[4] if (_is_living_antenna(point) or _is_living_eye(point)) else PURPLE_RAMP[5]
    if candidate == "dash_c2":
        if _is_living_antenna(point) or _is_living_eye(point):
            return PURPLE_RAMP[(4, 5, 4, 3)[frame_index]]
        return PURPLE_RAMP[(5, 4, 5, 4)[frame_index]]
    if candidate == "death_d1":
        return PURPLE_RAMP[(2, 2, 1, 5, 4, 3, 1, 0)[frame_index]]
    if candidate == "death_d2":
        return PURPLE_RAMP[(3, 2, 2, 1, 1, 0, 0, 0)[frame_index]]
    raise KeyError(candidate)


def _move_body_stamp(candidate: str, frame_index: int) -> PointMap:
    result = dict(A1_BODY_STAMP)
    if candidate == "move_m2":
        rear_high = frame_index in (0, 1, 6, 7)
        result[(11, 15)] = PLATE_GRAY if rear_high else DARK_STEEL
        result[(21, 15)] = DARK_STEEL if rear_high else PLATE_GRAY
    return result


def _dash_body_stamp(candidate: str) -> PointMap:
    result = dict(A1_BODY_STAMP)
    if candidate == "dash_c2":
        result[(11, 15)] = DARK_STEEL
        result[(21, 15)] = PLATE_GRAY
        result[(16, 9)] = DARK_STEEL
        result[(17, 9)] = DARK_STEEL
        result[(18, 9)] = MID_STEEL
    return result


def _death_stamp(candidate: str, frame_index: int) -> PointMap:
    stamp = DEATH_FULL_STAMPS[frame_index]
    if candidate == "death_d1" or frame_index <= 3:
        return stamp.full_map()

    # D2 keeps every remaining pixel attached, but later falling poses hide the
    # rear armor behind the chassis.  These are explicit, deterministic slices
    # rather than procedural morphology or a runtime visibility heuristic.
    visible_counts = {
        4: (4, 3, 4, 5),
        5: (3, 2, 4, 5),
        6: (2, 0, 3, 4),
        7: (2, 0, 2, 4),
    }[frame_index]
    groups = (stamp.roof, stamp.rear_shoulder, stamp.front_shoulder, stamp.guard)
    result: PointMap = {}
    for group, count in zip(groups, visible_counts):
        result.update(dict(group[:count]))
    return result


def _reinforcement_stamp(candidate: str, frame_index: int) -> PointMap:
    if candidate.startswith("move_"):
        return {**_move_body_stamp(candidate, frame_index), **A1_MOVE_GUARD_STAMP}
    if candidate.startswith("windup_"):
        return {**A1_BODY_STAMP, **WINDUP_GUARD_STAMPS[frame_index]}
    if candidate.startswith("dash_"):
        guard = DASH_GUARD_BALANCED if candidate == "dash_c1" else DASH_GUARD_FORWARD
        return {**_dash_body_stamp(candidate), **guard}
    if candidate.startswith("death_"):
        return _death_stamp(candidate, frame_index)
    raise KeyError(candidate)


def _compose_candidate(
    spec: CandidateSpec,
) -> tuple[list[Image.Image], list[set[tuple[int, int]]], list[set[tuple[int, int]]]]:
    ordinary = _ordinary_frames(spec.animation, spec.frame_count)
    frames: list[Image.Image] = []
    accent_masks: list[set[tuple[int, int]]] = []
    reinforcement_masks: list[set[tuple[int, int]]] = []
    for frame_index, source in enumerate(ordinary):
        frame = source.copy()
        accents = _accent_points(source)
        for point in accents:
            frame.putpixel(point, _accent_color(spec.key, frame_index, point))
        reinforcement = _reinforcement_stamp(spec.key, frame_index)
        for point, color in reinforcement.items():
            frame.putpixel(point, color)
        frames.append(frame)
        accent_masks.append(accents)
        reinforcement_masks.append(set(reinforcement))
    return frames, accent_masks, reinforcement_masks


def _components(frame: Image.Image) -> int:
    alpha = frame.getchannel("A")
    visible = alpha.load()
    visited: set[tuple[int, int]] = set()
    count = 0
    for start_y in range(frame.height):
        for start_x in range(frame.width):
            start = (start_x, start_y)
            if start in visited or visible[start_x, start_y] == 0:
                continue
            count += 1
            visited.add(start)
            pending: deque[tuple[int, int]] = deque([start])
            while pending:
                x, y = pending.popleft()
                for offset_y in (-1, 0, 1):
                    for offset_x in (-1, 0, 1):
                        if offset_x == 0 and offset_y == 0:
                            continue
                        neighbor = (x + offset_x, y + offset_y)
                        if (
                            neighbor in visited
                            or neighbor[0] < 0
                            or neighbor[1] < 0
                            or neighbor[0] >= frame.width
                            or neighbor[1] >= frame.height
                            or visible[neighbor[0], neighbor[1]] == 0
                        ):
                            continue
                        visited.add(neighbor)
                        pending.append(neighbor)
    return count


def _mask_hash(points: Iterable[tuple[int, int]]) -> str:
    payload = ";".join(f"{x},{y}" for x, y in sorted(points)).encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def _feature_color_hash(frame: Image.Image, points: Iterable[tuple[int, int]]) -> str:
    payload = bytearray()
    for x, y in sorted(points):
        payload.extend((x, y, *frame.getpixel((x, y))))
    return hashlib.sha256(payload).hexdigest()


def _frame_metrics(frame: Image.Image) -> dict[str, object]:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Candidate frame is empty")
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    points = [
        (x, y)
        for y in range(frame.height)
        for x in range(frame.width)
        if frame.getpixel((x, y))[3]
    ]
    return {
        "bbox": list(bbox),
        "visible_size": [width, height],
        "visible_pixels": len(points),
        "alpha_center_x": round(sum(x + 0.5 for x, _y in points) / len(points), 3),
        "baseline_bottom": bbox[3],
        "connected_components": _components(frame),
    }


def _audit_candidate(
    spec: CandidateSpec,
    frames: Sequence[Image.Image],
    accent_masks: Sequence[set[tuple[int, int]]],
    reinforcement_masks: Sequence[set[tuple[int, int]]],
) -> dict[str, object]:
    ordinary = _ordinary_frames(spec.animation, spec.frame_count)
    frame_reports: list[dict[str, object]] = []
    for frame_index, (base, frame, accents, reinforcement) in enumerate(
        zip(ordinary, frames, accent_masks, reinforcement_masks)
    ):
        metrics = _frame_metrics(frame)
        if metrics["visible_size"][0] > MAX_VISIBLE_SIZE or metrics["visible_size"][1] > MAX_VISIBLE_SIZE:
            raise AssertionError(f"{spec.key}[{frame_index}] exceeds 28x28: {metrics}")
        if metrics["baseline_bottom"] != BASELINE_Y:
            raise AssertionError(f"{spec.key}[{frame_index}] baseline drift: {metrics}")
        if metrics["connected_components"] != 1:
            raise AssertionError(f"{spec.key}[{frame_index}] has detached pixels: {metrics}")

        allowed_differences = accents | reinforcement
        changed: set[tuple[int, int]] = set()
        added_alpha: set[tuple[int, int]] = set()
        purple_points: set[tuple[int, int]] = set()
        for y in range(FRAME_SIZE):
            for x in range(FRAME_SIZE):
                point = (x, y)
                base_pixel = base.getpixel(point)
                pixel = frame.getpixel(point)
                if pixel != base_pixel:
                    changed.add(point)
                    if point not in allowed_differences:
                        raise AssertionError(
                            f"{spec.key}[{frame_index}] changes ordinary pixel outside whitelist: {point}"
                        )
                if base_pixel[3] == 0 and pixel[3] != 0:
                    added_alpha.add(point)
                if pixel in PURPLE_RAMP:
                    purple_points.add(point)
                if pixel not in ALLOWED_PALETTE:
                    raise AssertionError(
                        f"{spec.key}[{frame_index}] uses non-contract color {pixel} at {point}"
                    )
                if pixel[3] not in (0, 255):
                    raise AssertionError(f"{spec.key}[{frame_index}] alpha is not binary at {point}")
                if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
                    raise AssertionError(f"{spec.key}[{frame_index}] transparent RGB is nonzero at {point}")
        if not added_alpha <= reinforcement:
            raise AssertionError(f"{spec.key}[{frame_index}] adds alpha outside reinforcement mask")
        if purple_points != accents:
            raise AssertionError(
                f"{spec.key}[{frame_index}] purple mask differs from ordinary accent mask: "
                f"purple={sorted(purple_points)} ordinary={sorted(accents)}"
            )
        if any(pixel in ORDINARY_ACCENTS for pixel in frame.getdata()):
            raise AssertionError(f"{spec.key}[{frame_index}] retains red/orange pixels")
        frame_reports.append(
            {
                **metrics,
                "ordinary_accent_pixels": len(accents),
                "purple_pixels": len(purple_points),
                "reinforcement_whitelist_pixels": len(reinforcement),
                "changed_pixels": len(changed),
                "added_alpha_pixels": len(added_alpha),
                "ordinary_inheritance_outside_whitelist": True,
                "reinforcement_mask_sha256": _mask_hash(reinforcement),
                "reinforcement_color_sha256": _feature_color_hash(frame, reinforcement),
                "rgba_sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
            }
        )

    if spec.key == "move_m1":
        approved = Image.open(APPROVED_ANCHOR_PATH).convert("RGBA")
        if frames[0].tobytes() != approved.tobytes():
            raise AssertionError("move_m1[0] must equal the approved A1 native anchor")

    reinforcement_mask_hashes = [item["reinforcement_mask_sha256"] for item in frame_reports]
    reinforcement_color_hashes = [item["reinforcement_color_sha256"] for item in frame_reports]
    if spec.key in ("move_m1", "dash_c1"):
        if len(set(reinforcement_mask_hashes)) != 1 or len(set(reinforcement_color_hashes)) != 1:
            raise AssertionError(f"{spec.key} rigid reinforcement flickers")
    if spec.key in ("move_m2", "dash_c2") and len(set(reinforcement_mask_hashes)) != 1:
        raise AssertionError(f"{spec.key} reinforcement alpha mask flickers")

    return {
        "animation": spec.animation,
        "frame_count": spec.frame_count,
        "fps": spec.fps,
        "loop": spec.loop,
        "ordinary_pixels_imported_directly": True,
        "imagegen_pixels_imported": False,
        "allowed_difference_contract_enforced": True,
        "ordinary_accent_mask_preserved": True,
        "red_orange_remaining": 0,
        "reinforcement_masks_unique": len(set(reinforcement_mask_hashes)),
        "reinforcement_color_states": len(set(reinforcement_color_hashes)),
        "frames": frame_reports,
    }


def _strip(frames: Sequence[Image.Image]) -> Image.Image:
    result = _empty((FRAME_SIZE * len(frames), FRAME_SIZE))
    for index, frame in enumerate(frames):
        result.alpha_composite(frame, (index * FRAME_SIZE, 0))
    return result


def _on_background(image: Image.Image, color: tuple[int, int, int, int] = REVIEW_BACKGROUND) -> Image.Image:
    result = Image.new("RGBA", image.size, color)
    result.alpha_composite(image)
    return result


def _save_gif(frames: Sequence[Image.Image], path: Path, fps: int, mirrored: bool) -> None:
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


def _delta_strip(ordinary: Sequence[Image.Image], candidate: Sequence[Image.Image]) -> Image.Image:
    frames: list[Image.Image] = []
    for base, frame in zip(ordinary, candidate):
        delta = _empty()
        pixels = delta.load()
        for y in range(FRAME_SIZE):
            for x in range(FRAME_SIZE):
                before = base.getpixel((x, y))
                after = frame.getpixel((x, y))
                if before == after and before[3]:
                    pixels[x, y] = (112, 121, 128, 120)
                elif before[3] == 0 and after[3]:
                    pixels[x, y] = (238, 80, 205, 255)
                elif before[3] and after[3] == 0:
                    pixels[x, y] = (60, 210, 235, 255)
                elif before != after:
                    pixels[x, y] = (197, 138, 255, 255)
        frames.append(delta)
    return _strip(frames)


def _save_candidate_outputs(
    spec: CandidateSpec,
    frames: Sequence[Image.Image],
) -> dict[str, object]:
    strip = _strip(frames)
    ordinary = _ordinary_frames(spec.animation, spec.frame_count)
    native_path = SOURCE_DIR / f"combat_robot_elite_{spec.key}_candidate_native.png"
    board_path = PREVIEW_DIR / f"combat_robot_elite_{spec.key}_candidate_16x.png"
    gif_path = PREVIEW_DIR / f"combat_robot_elite_{spec.key}_candidate.gif"
    mirrored_gif_path = PREVIEW_DIR / f"combat_robot_elite_{spec.key}_candidate_mirrored.gif"
    delta_path = PREVIEW_DIR / f"combat_robot_elite_{spec.key}_ordinary_delta_8x.png"
    strip.save(native_path, optimize=True)
    _on_background(strip).resize(
        (strip.width * 16, strip.height * 16), Image.Resampling.NEAREST
    ).save(board_path, optimize=True)
    _save_gif(frames, gif_path, spec.fps, mirrored=False)
    _save_gif(frames, mirrored_gif_path, spec.fps, mirrored=True)
    _on_background(_delta_strip(ordinary, frames)).resize(
        (strip.width * 8, strip.height * 8), Image.Resampling.NEAREST
    ).save(delta_path, optimize=True)
    return {
        "native_strip": _relative(native_path),
        "native_size": list(strip.size),
        "integer_16x": _relative(board_path),
        "gif": _relative(gif_path),
        "mirrored_gif": _relative(mirrored_gif_path),
        "ordinary_delta_8x": _relative(delta_path),
        "native_sha256": _sha256(native_path),
        "integer_16x_sha256": _sha256(board_path),
        "gif_sha256": _sha256(gif_path),
        "mirrored_gif_sha256": _sha256(mirrored_gif_path),
        "ordinary_delta_sha256": _sha256(delta_path),
    }


def _normalize_imagegen_source(image: Image.Image) -> Image.Image:
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


def _checkerboard(size: tuple[int, int], cell: int = 16) -> Image.Image:
    result = Image.new("RGBA", size, REVIEW_PANEL)
    draw = ImageDraw.Draw(result)
    colors = ((37, 47, 62, 255), (55, 66, 82, 255))
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            draw.rectangle(
                (x, y, min(size[0], x + cell) - 1, min(size[1], y + cell) - 1),
                fill=colors[((x // cell) + (y // cell)) % 2],
            )
    return result


def _source_report(spec: CandidateSpec) -> tuple[dict[str, object], Image.Image]:
    source_path = SOURCE_DIR / spec.source_file
    transparent_path = source_path.with_name(source_path.name.replace("_imagegen.png", "_transparent.png"))
    display_path = PREVIEW_DIR / source_path.name.replace("_imagegen.png", "_imagegen_transparent_preview.png")
    transparent = _normalize_imagegen_source(Image.open(source_path))
    transparent.save(transparent_path, optimize=True)
    bbox = transparent.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{source_path.name} is empty after chroma-key removal")
    crop = transparent.crop(bbox)
    analysis = analyze_image(crop)
    subject = crop.copy()
    subject.thumbnail((900, 420), Image.Resampling.NEAREST)
    display = _checkerboard((960, 480), cell=20)
    display.alpha_composite(subject, ((960 - subject.width) // 2, (480 - subject.height) // 2))
    display.save(display_path, optimize=True)
    corner_alpha = [
        transparent.getpixel(point)[3]
        for point in ((0, 0), (transparent.width - 1, 0), (0, transparent.height - 1), (transparent.width - 1, transparent.height - 1))
    ]
    if any(corner_alpha):
        raise AssertionError(f"{source_path.name} chroma-key corners are not transparent")
    return (
        {
            "path": _relative(source_path),
            "sha256": _sha256(source_path),
            "source_size": list(transparent.size),
            "transparent": _relative(transparent_path),
            "transparent_sha256": _sha256(transparent_path),
            "transparent_preview": _relative(display_path),
            "transparent_preview_sha256": _sha256(display_path),
            "subject_bbox": list(bbox),
            "subject_crop_size": list(crop.size),
            "grid_analysis": analysis,
            "unsafe_for_direct_resize": (
                str(analysis["detection_mode"]) == "native_or_unknown"
                or float(analysis["confidence"]) < 0.65
            ),
            "transparent_corners": True,
            "source_pixels_imported": False,
            "role": "animation and reinforcement language reference only",
        },
        crop,
    )


def _font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _source_thumbnail(crop: Image.Image, size: tuple[int, int]) -> Image.Image:
    subject = crop.copy()
    subject.thumbnail((size[0] - 20, size[1] - 20), Image.Resampling.NEAREST)
    result = _checkerboard(size, cell=12)
    result.alpha_composite(subject, ((size[0] - subject.width) // 2, (size[1] - subject.height) // 2))
    return result


def _write_comparison(
    animations: dict[str, list[Image.Image]],
    source_crops: dict[str, Image.Image],
) -> Path:
    width = 2460
    header = 96
    row_height = 500
    canvas = Image.new("RGBA", (width, header + len(CANDIDATE_SPECS) * row_height), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title_font = _font(28)
    label_font = _font(20)
    small_font = _font(15)
    draw.text((24, 18), "精英战斗机器人 — 第二阶段动画候选", fill=REVIEW_TEXT, font=title_font)
    draw.text(
        (24, 58),
        "A1原生锚点 + 普通版逐帧继承；ImageGen仅作语言参考，未导入任何生成像素",
        fill=REVIEW_MUTED,
        font=small_font,
    )
    for row, spec in enumerate(CANDIDATE_SPECS):
        top = header + row * row_height
        draw.text((24, top + 8), f"{spec.label}  {spec.frame_count}f @{spec.fps} FPS", fill=REVIEW_TEXT, font=label_font)
        draw.text((24, top + 38), spec.design, fill=REVIEW_MUTED, font=small_font)
        strip = _on_background(_strip(animations[spec.key])).resize(
            (FRAME_SIZE * spec.frame_count * 8, FRAME_SIZE * 8),
            Image.Resampling.NEAREST,
        )
        canvas.alpha_composite(strip, (24, top + 74))
        delta = _on_background(
            _delta_strip(_ordinary_frames(spec.animation, spec.frame_count), animations[spec.key])
        ).resize(
            (FRAME_SIZE * spec.frame_count * 4, FRAME_SIZE * 4),
            Image.Resampling.NEAREST,
        )
        canvas.alpha_composite(delta, (24, top + 346))
        draw.text((2110, top + 8), "ImageGen语言参考", fill=REVIEW_MUTED, font=small_font)
        canvas.alpha_composite(_source_thumbnail(source_crops[spec.key], (320, 410)), (2110, top + 42))
        draw.text((24, top + 326), "ordinary delta（灰=未改；紫=改色；粉=新增强化件）", fill=REVIEW_MUTED, font=small_font)
    path = PREVIEW_DIR / "combat_robot_elite_animation_comparison.png"
    canvas.save(path, optimize=True)
    return path


def _write_stability_report(
    audits: dict[str, dict[str, object]],
) -> Path:
    report = {
        "asset": "combat_robot_elite_animation_stability",
        "approved_anchor": "A1",
        "runtime_written": False,
        "contracts": {
            "ordinary_inheritance": "Outside original accent pixels and explicit A1 reinforcement whitelists, every RGBA pixel equals the ordinary frame.",
            "accent_mask": "Purple coordinates equal the ordinary red/orange coordinate set exactly; no new functional-light area is introduced.",
            "rigid_candidates": ["move_m1", "dash_c1"],
            "alpha_stable_candidates": ["move_m1", "move_m2", "dash_c1", "dash_c2"],
            "death": "Eight explicit point tables; no morphology, rotation helper, or inferred runtime attachment.",
        },
        "candidates": {
            key: {
                "reinforcement_masks_unique": audit["reinforcement_masks_unique"],
                "reinforcement_color_states": audit["reinforcement_color_states"],
                "frame_rgba_sha256": [frame["rgba_sha256"] for frame in audit["frames"]],
                "reinforcement_mask_sha256": [frame["reinforcement_mask_sha256"] for frame in audit["frames"]],
                "reinforcement_color_sha256": [frame["reinforcement_color_sha256"] for frame in audit["frames"]],
                "connected_components": [frame["connected_components"] for frame in audit["frames"]],
                "visible_sizes": [frame["visible_size"] for frame in audit["frames"]],
            }
            for key, audit in audits.items()
        },
    }
    path = enemy_asset_report_path("combat_robot_elite_animation_stability_report.json")
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def _write_manifest(
    source_reports: dict[str, dict[str, object]],
    outputs: dict[str, dict[str, object]],
) -> Path:
    manifest = {
        "version": 1,
        "stage": "animation_candidates_pending_second_human_gate",
        "mode": "built-in image_gen references plus deterministic native reconstruction",
        "approved_anchor": {
            "selection": "A1",
            "path": _relative(APPROVED_ANCHOR_PATH),
            "sha256": _sha256(APPROVED_ANCHOR_PATH),
        },
        "approved_selection": None,
        "runtime_written": False,
        "imagegen_sources": {
            spec.key: {
                "path": source_reports[spec.key]["path"],
                "sha256": source_reports[spec.key]["sha256"],
                "transparent": source_reports[spec.key]["transparent"],
                "role": "language reference only",
                "pixels_imported": False,
            }
            for spec in CANDIDATE_SPECS
        },
        "candidate_contract": {
            spec.key: {
                "animation": spec.animation,
                "frames": spec.frame_count,
                "fps": spec.fps,
                "loop": spec.loop,
                "label": spec.label,
                "native_strip": outputs[spec.key]["native_strip"],
            }
            for spec in CANDIDATE_SPECS
        },
        "native_contract": {
            "frame_size": [32, 32],
            "visible_bbox_max": [28, 28],
            "registered_body_center_x": 16.0,
            "baseline_bottom": 28,
            "ordinary_motion_and_weapon_positions_inherited": True,
            "purple_mask_equals_ordinary_accent_mask": True,
            "fixed_palette": [list(color) for color in sorted(ALLOWED_PALETTE)],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "imagegen_pixels_imported": False,
            "death_explicit_frame_tables": 8,
        },
    }
    path = enemy_asset_report_path("combat_robot_elite_animation_manifest.json")
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def _ensure_review_only() -> None:
    runtime_root = (PROJECT_ROOT / "resources").resolve()
    for output_root in (SOURCE_DIR.resolve(), PREVIEW_DIR.resolve()):
        if output_root == runtime_root or runtime_root in output_root.parents:
            raise AssertionError("Elite preview output overlaps runtime resources")


def build() -> dict[str, object]:
    _ensure_review_only()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    if not ORDINARY_SHEET_PATH.is_file():
        raise FileNotFoundError(ORDINARY_SHEET_PATH)
    if not APPROVED_ANCHOR_PATH.is_file():
        raise FileNotFoundError(APPROVED_ANCHOR_PATH)
    for spec in CANDIDATE_SPECS:
        if not (SOURCE_DIR / spec.source_file).is_file():
            raise FileNotFoundError(SOURCE_DIR / spec.source_file)

    animations: dict[str, list[Image.Image]] = {}
    audits: dict[str, dict[str, object]] = {}
    outputs: dict[str, dict[str, object]] = {}
    source_reports: dict[str, dict[str, object]] = {}
    source_crops: dict[str, Image.Image] = {}

    for spec in CANDIDATE_SPECS:
        frames, accent_masks, reinforcement_masks = _compose_candidate(spec)
        animations[spec.key] = frames
        audits[spec.key] = _audit_candidate(spec, frames, accent_masks, reinforcement_masks)
        outputs[spec.key] = _save_candidate_outputs(spec, frames)
        source_report, source_crop = _source_report(spec)
        source_reports[spec.key] = source_report
        source_crops[spec.key] = source_crop

    comparison_path = _write_comparison(animations, source_crops)
    stability_path = _write_stability_report(audits)
    manifest_path = _write_manifest(source_reports, outputs)
    report: dict[str, object] = {
        "asset": "combat_robot_elite_animation_candidates",
        "stage": "second_human_gate",
        "approved_anchor": "A1",
        "approved_selection": None,
        "runtime_written": False,
        "construction": {
            "ordinary_sheet": _relative(ORDINARY_SHEET_PATH),
            "ordinary_sheet_sha256": _sha256(ORDINARY_SHEET_PATH),
            "approved_anchor": _relative(APPROVED_ANCHOR_PATH),
            "approved_anchor_sha256": _sha256(APPROVED_ANCHOR_PATH),
            "imagegen_pixels_imported": False,
            "native_frames_resized": False,
            "frame_size": [FRAME_SIZE, FRAME_SIZE],
            "maximum_visible_bbox": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "registered_body_center_x": REGISTERED_BODY_CENTER_X,
            "baseline_bottom": BASELINE_Y,
            "palette": [list(color) for color in sorted(ALLOWED_PALETTE)],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
        },
        "source_grid_analysis": source_reports,
        "animation_audit": audits,
        "outputs": outputs,
        "comparison": _relative(comparison_path),
        "comparison_sha256": _sha256(comparison_path),
        "stability_report": _relative(stability_path),
        "stability_report_sha256": _sha256(stability_path),
        "manifest": _relative(manifest_path),
        "manifest_sha256": _sha256(manifest_path),
    }
    report_path = enemy_asset_report_path("combat_robot_elite_animation_preview_report.json")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report["report"] = _relative(report_path)
    return report


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(build(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
