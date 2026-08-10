#!/usr/bin/env python3
"""Build deterministic second-gate animation previews for the ninja robot.

The approved native-40 C anchor is the only runtime-scale pixel source. Six
ImageGen boards provide motion language only; their pixels are never sampled,
resized or copied into candidate frames. Living animations retain one immutable
robot core and use authored eight-phase line-leg cycles. Death candidates move
the chassis, legs and two rigid blades as separate native-pixel layers, then
bridge each hilt back to an actual transformed chassis pixel.

All outputs stay below ``dev_assets``. This script never writes runtime texture,
animation, scene or configuration files.
"""

from __future__ import annotations

import hashlib
import json
import sys
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from typing import Sequence

from PIL import Image, ImageDraw, ImageFont

import process_combat_robot_ninja_anchors as anchors
from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_ninja"
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"
APPROVED_ANCHOR_PATH = (
    SOURCE_DIR / "combat_robot_ninja_anchor_c_approved_native40.png"
)

FRAME_SIZE = 40
FRAME_COUNT = 8
BASELINE_Y = 32
REGISTERED_CENTER_X = 20.0
MAX_VISIBLE_SIZE = 28
LEG_TOP_Y = 26
LEG_BOTTOM_Y = 32
LEG_ROI = (0, LEG_TOP_Y, FRAME_SIZE, FRAME_SIZE)
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
DEEP_RED = PALETTE[8]
ACTIVE_RED = PALETTE[9]
HOT_ORANGE = PALETTE[10]


@dataclass(frozen=True)
class AnimationSpec:
    name: str
    source_file: str
    fps: int
    kind: str
    label: str


ANIMATION_SPECS: tuple[AnimationSpec, ...] = (
    AnimationSpec(
        "move_m1",
        "combat_robot_ninja_move_m1_imagegen.png",
        20,
        "living",
        "M1 长步 / long stride",
    ),
    AnimationSpec(
        "move_m2",
        "combat_robot_ninja_move_m2_imagegen.png",
        22,
        "living",
        "M2 碎步 / compact rapid step",
    ),
    AnimationSpec(
        "boost_s1",
        "combat_robot_ninja_boost_s1_imagegen.png",
        24,
        "living",
        "S1 后掠疾跑 / rear-swept sprint",
    ),
    AnimationSpec(
        "boost_s2",
        "combat_robot_ninja_boost_s2_imagegen.png",
        28,
        "living",
        "S2 护持碎步 / guarded rapid step",
    ),
    AnimationSpec(
        "death_d1",
        "combat_robot_ninja_death_d1_imagegen.png",
        12,
        "death",
        "D1 前折 / forward fold",
    ),
    AnimationSpec(
        "death_d2",
        "combat_robot_ninja_death_d2_imagegen.png",
        12,
        "death",
        "D2 后仰侧倒 / backward side fall",
    ),
)

# Approved by the user at the second animation review gate.  Keep this in the
# deterministic builder so a rerun cannot silently return the manifest to an
# undecided state while the afterimage shader is being revised.
APPROVED_ANIMATION_SELECTION = {
    "move": "move_m1",
    "boost": "boost_s1",
    "death": "death_d1",
}

GENERATED_IMAGE_IDS: dict[str, str] = {
    "move_m1": "exec-178f40c3-12bd-4c78-b0cd-d8d69c725d77",
    "move_m2": "exec-fde9913d-3827-4d9a-9b41-7217b6c2ad2b",
    "boost_s1": "exec-5d18989a-3ae7-4518-a6a0-bc5dbf7307cb",
    "boost_s2": "exec-d9abfd21-e3f6-457a-ac6e-7e0855a19a6a",
    "death_d1": "exec-6c59c8bd-e720-4cc9-866f-58b0c90b69a4",
    "death_d2": "exec-e4ea81b6-5cc1-4488-bbd6-728f1ea2be53",
}


LegPath = tuple[tuple[int, int], ...]
Foot = tuple[int, int, int]
LegDefinition = tuple[LegPath, Foot]
PoseDefinition = tuple[LegDefinition, LegDefinition]


M1_HALF_CYCLE: tuple[PoseDefinition, ...] = (
    (
        (((17, 26), (16, 28), (14, 30)), (12, 16, 31)),
        (((22, 26), (23, 28), (25, 30)), (24, 27, 31)),
    ),
    (
        (((17, 26), (15, 28), (14, 30)), (12, 15, 31)),
        (((22, 26), (23, 28), (24, 30)), (23, 26, 31)),
    ),
    (
        (((17, 26), (18, 28), (19, 29)), (18, 21, 30)),
        (((22, 26), (21, 28), (20, 30)), (18, 22, 31)),
    ),
    (
        (((17, 26), (19, 28), (22, 29)), (21, 24, 30)),
        (((22, 26), (21, 28), (19, 30)), (17, 21, 31)),
    ),
)

M2_HALF_CYCLE: tuple[PoseDefinition, ...] = (
    (
        (((17, 26), (16, 28), (16, 30)), (14, 18, 31)),
        (((22, 26), (23, 28), (24, 30)), (22, 26, 31)),
    ),
    (
        (((17, 26), (16, 28), (17, 30)), (15, 18, 31)),
        (((22, 26), (22, 28), (23, 30)), (21, 25, 31)),
    ),
    (
        (((17, 26), (18, 28), (19, 29)), (18, 20, 30)),
        (((22, 26), (21, 28), (21, 30)), (19, 23, 31)),
    ),
    (
        (((17, 26), (18, 28), (20, 29)), (19, 22, 30)),
        (((22, 26), (21, 28), (20, 30)), (18, 22, 31)),
    ),
)

S1_HALF_CYCLE: tuple[PoseDefinition, ...] = (
    (
        (((17, 26), (15, 28), (12, 29)), (10, 14, 31)),
        (((22, 26), (24, 28), (27, 29)), (26, 29, 31)),
    ),
    (
        (((17, 26), (14, 28), (12, 30)), (10, 13, 31)),
        (((22, 26), (24, 27), (26, 29)), (25, 28, 30)),
    ),
    (
        (((17, 26), (18, 28), (20, 29)), (19, 22, 30)),
        (((22, 26), (21, 28), (19, 30)), (17, 21, 31)),
    ),
    (
        (((17, 26), (20, 28), (24, 29)), (23, 27, 30)),
        (((22, 26), (20, 28), (16, 30)), (14, 18, 31)),
    ),
)

S2_HALF_CYCLE: tuple[PoseDefinition, ...] = (
    (
        (((17, 26), (16, 28), (15, 30)), (13, 17, 31)),
        (((22, 26), (23, 28), (24, 30)), (23, 27, 31)),
    ),
    (
        (((17, 26), (16, 28), (17, 30)), (15, 18, 31)),
        (((22, 26), (23, 27), (24, 29)), (23, 26, 30)),
    ),
    (
        (((17, 26), (19, 28), (20, 29)), (19, 22, 30)),
        (((22, 26), (21, 28), (20, 30)), (18, 22, 31)),
    ),
    (
        (((17, 26), (19, 28), (22, 30)), (21, 25, 31)),
        (((22, 26), (20, 28), (18, 29)), (16, 20, 30)),
    ),
)

GAIT_HALF_CYCLES: dict[str, tuple[PoseDefinition, ...]] = {
    "move_m1": M1_HALF_CYCLE,
    "move_m2": M2_HALF_CYCLE,
    "boost_s1": S1_HALF_CYCLE,
    "boost_s2": S2_HALF_CYCLE,
}

DEATH_ANGLES: dict[str, tuple[int, ...]] = {
    "death_d1": (0, -8, -16, -24, -32, -45, -65, -90),
    "death_d2": (0, 8, 16, 24, 32, 45, 65, 90),
}

DEATH_BODY_CENTERS: dict[str, tuple[tuple[float, float], ...]] = {
    "death_d1": (
        (20.0, 17.0), (20.0, 18.0), (20.5, 18.5), (21.0, 19.5),
        (21.0, 20.5), (21.0, 22.0), (20.5, 23.5), (20.0, 25.0),
    ),
    "death_d2": (
        (20.0, 17.0), (20.0, 18.0), (19.5, 18.5), (19.0, 19.5),
        (18.5, 20.5), (18.5, 22.0), (18.5, 23.5), (19.0, 25.0),
    ),
}

# Each tuple is (hand, guard, tip). Frame zero is supplied by the approved C
# anchor. D1 settles one blade to either side; D2 gathers both blades forward.
DEATH_SWORD_LAYOUTS: dict[
    str,
    tuple[
        tuple[
            tuple[tuple[int, int], tuple[int, int], tuple[int, int]],
            tuple[tuple[int, int], tuple[int, int], tuple[int, int]],
        ],
        ...,
    ],
] = {
    "death_d1": (
        (((13, 24), (12, 24), (6, 22)), ((26, 21), (27, 21), (32, 19))),
        (((13, 24), (12, 24), (6, 23)), ((26, 22), (27, 22), (33, 21))),
        (((13, 25), (12, 25), (6, 25)), ((26, 23), (27, 23), (33, 23))),
        (((14, 26), (13, 26), (6, 27)), ((26, 25), (27, 25), (33, 26))),
        (((15, 28), (14, 28), (7, 29)), ((26, 27), (27, 27), (33, 28))),
        (((16, 29), (15, 29), (7, 31)), ((25, 28), (26, 28), (33, 30))),
        (((16, 29), (15, 29), (6, 31)), ((25, 29), (26, 29), (33, 31))),
        (((15, 29), (14, 29), (6, 31)), ((25, 29), (26, 29), (33, 31))),
    ),
    "death_d2": (
        (((13, 24), (12, 24), (6, 22)), ((26, 21), (27, 21), (32, 19))),
        (((13, 24), (12, 24), (6, 23)), ((26, 21), (27, 21), (33, 19))),
        (((14, 25), (13, 25), (7, 24)), ((26, 22), (27, 22), (33, 20))),
        (((15, 26), (14, 26), (8, 27)), ((25, 24), (26, 24), (32, 22))),
        (((16, 27), (15, 27), (9, 29)), ((24, 26), (25, 26), (31, 24))),
        (((17, 28), (16, 28), (10, 30)), ((23, 27), (24, 27), (31, 27))),
        (((18, 29), (17, 29), (11, 31)), ((23, 28), (24, 28), (32, 29))),
        (((22, 29), (23, 29), (33, 31)), ((21, 27), (22, 27), (32, 28))),
    ),
}


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


def _normalize(image: Image.Image) -> Image.Image:
    normalized = snap_palette(image.convert("RGBA"))
    pixels = normalized.load()
    for y in range(normalized.height):
        for x in range(normalized.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha < 128:
                pixels[x, y] = TRANSPARENT
            else:
                pixels[x, y] = (red, green, blue, 255)
    return normalized


def _clear_rect(image: Image.Image, rect: tuple[int, int, int, int]) -> Image.Image:
    result = image.copy()
    result.paste(TRANSPARENT, rect)
    return result


def _load_anchor() -> Image.Image:
    anchor = _normalize(Image.open(APPROVED_ANCHOR_PATH))
    if anchor.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"Approved ninja anchor must be 40x40, got {anchor.size}")
    bbox = anchor.getchannel("A").getbbox()
    if bbox != (6, 8, 33, 32):
        raise AssertionError(f"Approved C anchor registration changed: {bbox}")
    _audit_pixels(anchor, "approved anchor C")
    return anchor


def _extract_fixed_core(anchor: Image.Image) -> Image.Image:
    core = _empty()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            keep = (
                y <= 17
                or (18 <= y <= 23 and 13 <= x <= 26)
                or (y == 24 and 15 <= x <= 24)
                or (y == 25 and 16 <= x <= 23)
            )
            if not keep:
                continue
            pixel = anchor.getpixel((x, y))
            if pixel[3]:
                core.putpixel((x, y), pixel)
    core = _normalize(core)
    bbox = core.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Fixed ninja core is empty")
    torso = core.getchannel("A").crop((10, 18, 30, 26))
    torso_bbox = torso.getbbox()
    if torso_bbox is None:
        raise AssertionError("Fixed ninja torso is empty")
    center_x = 10 + (torso_bbox[0] + torso_bbox[2]) * 0.5
    if abs(center_x - REGISTERED_CENTER_X) > 0.5:
        raise AssertionError(f"Fixed core center x={center_x}, expected 20±0.5")
    return core


def _draw_leg(
    layer: Image.Image,
    points: LegPath,
    foot: Foot,
    front: bool,
) -> None:
    outline = OUTLINE if front else DEEP_SHADOW
    joint = MID_STEEL if front else JOINT_SHADOW
    fill = PLATE_GRAY if front else DARK_STEEL
    draw = ImageDraw.Draw(layer)
    draw.line(points, fill=outline, width=1)
    for point in points[1:-1]:
        draw.point(point, fill=joint)
    left, right, bottom_y = foot
    draw.rectangle((left, bottom_y - 1, right, bottom_y), fill=outline)
    if right - left >= 2:
        draw.line((left + 1, bottom_y - 1, right - 1, bottom_y - 1), fill=fill)


def _make_leg_layer(pose: PoseDefinition) -> Image.Image:
    layer = _empty()
    rear, front = pose
    _draw_leg(layer, rear[0], rear[1], front=False)
    _draw_leg(layer, front[0], front[1], front=True)
    return _normalize(layer)


def _mirror_leg_layer(layer: Image.Image) -> Image.Image:
    result = _empty()
    source = layer.load()
    destination = result.load()
    for y in range(LEG_TOP_Y, LEG_BOTTOM_Y):
        for x in range(FRAME_SIZE):
            pixel = source[x, y]
            if pixel[3]:
                destination[FRAME_SIZE - 1 - x, y] = pixel
    return _normalize(result)


def _build_gait(name: str) -> list[Image.Image]:
    authored = [_make_leg_layer(pose) for pose in GAIT_HALF_CYCLES[name]]
    frames = authored + [_mirror_leg_layer(layer) for layer in authored]
    if len(frames) != FRAME_COUNT:
        raise AssertionError(f"{name} gait produced {len(frames)} phases")
    return frames


def _build_weapon_upper(
    core: Image.Image,
    sword_specs: Sequence[anchors.SwordSpec],
) -> Image.Image:
    weapon_layer = _empty()
    for sword in sword_specs:
        anchors._draw_arm(weapon_layer, sword)
        anchors._draw_blade(weapon_layer, sword)
    weapon_layer.alpha_composite(core)
    return _normalize(weapon_layer)


def _build_living_upper(
    name: str,
    anchor: Image.Image,
    core: Image.Image,
) -> Image.Image:
    if name in ("move_m1", "move_m2"):
        return _normalize(_clear_rect(anchor, LEG_ROI))
    if name == "boost_s1":
        return _build_weapon_upper(core, anchors.SWORD_LAYOUTS["b"])
    if name == "boost_s2":
        compact_guard = (
            replace(anchors.SWORD_LAYOUTS["c"][0], tip=(6, 22)),
            anchors.SWORD_LAYOUTS["c"][1],
        )
        return _build_weapon_upper(core, compact_guard)
    raise KeyError(name)


def _compose_living_frames(
    name: str,
    anchor: Image.Image,
    core: Image.Image,
) -> tuple[list[Image.Image], Image.Image, list[Image.Image]]:
    upper = _build_living_upper(name, anchor, core)
    legs = _build_gait(name)
    frames: list[Image.Image] = []
    for leg_layer in legs:
        # Legs are the rear layer.  S1's lower swept blade deliberately enters
        # the leg ROI, so compositing the gait last would make the blade flicker.
        frame = leg_layer.copy()
        frame.alpha_composite(upper)
        frames.append(_normalize(frame))
    return frames, upper, legs


def _build_blade_masks(anchor: Image.Image) -> tuple[Image.Image, Image.Image]:
    left = _empty()
    right = _empty()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            pixel = anchor.getpixel((x, y))
            if pixel[3] == 0:
                continue
            if x < 14 and y >= 18:
                left.putpixel((x, y), (255, 255, 255, 255))
            elif x > 26 and y >= 17:
                right.putpixel((x, y), (255, 255, 255, 255))
    if left.getchannel("A").getbbox() is None or right.getchannel("A").getbbox() is None:
        raise AssertionError("Cannot isolate both approved C blades")
    return left, right


def _place_rotated_piece(
    piece: Image.Image,
    angle: int,
    center: tuple[float, float],
) -> Image.Image:
    bbox = piece.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Cannot rotate an empty death-rig piece")
    cropped = piece.crop(bbox)
    rotated = cropped.rotate(
        angle,
        resample=Image.Resampling.NEAREST,
        expand=True,
        fillcolor=TRANSPARENT,
    )
    rotated = _normalize(rotated)
    visible = rotated.getchannel("A").getbbox()
    if visible is None:
        raise AssertionError(f"Death rotation {angle} erased a rig piece")
    rotated = rotated.crop(visible)
    left = round(center[0] - rotated.width * 0.5)
    top = round(center[1] - rotated.height * 0.5)
    if (
        left < 0
        or top < 0
        or left + rotated.width > FRAME_SIZE
        or top + rotated.height > FRAME_SIZE
    ):
        raise AssertionError(
            f"Death rig piece {rotated.size} at {(left, top)} leaves 40x40 canvas"
        )
    result = _empty()
    result.alpha_composite(rotated, (left, top))
    return _normalize(result)


def _nearest_body_pixel(
    body: Image.Image,
    target: tuple[int, int],
) -> tuple[int, int]:
    points = [
        (x, y)
        for y in range(FRAME_SIZE)
        for x in range(FRAME_SIZE)
        if body.getpixel((x, y))[3]
    ]
    if not points:
        raise AssertionError("Death rig lost the transformed chassis")
    return min(
        points,
        key=lambda point: (
            (point[0] - target[0]) ** 2 + (point[1] - target[1]) ** 2,
            abs(point[1] - target[1]),
            abs(point[0] - target[0]),
        ),
    )


def _death_foot_targets(name: str, phase: int) -> tuple[tuple[int, int], tuple[int, int]]:
    d1 = (
        ((16, 30), (23, 30)),
        ((16, 30), (23, 30)),
        ((17, 30), (24, 30)),
        ((18, 30), (24, 30)),
        ((19, 30), (25, 30)),
        ((19, 30), (24, 30)),
        ((18, 30), (24, 30)),
        ((17, 30), (24, 30)),
    )
    if name == "death_d1":
        return d1[phase]
    left, right = d1[phase]
    return ((FRAME_SIZE - 1 - right[0], right[1]), (FRAME_SIZE - 1 - left[0], left[1]))


def _draw_death_supports(
    body: Image.Image,
    name: str,
    phase: int,
) -> Image.Image:
    layer = _empty()
    draw = ImageDraw.Draw(layer)
    feet = _death_foot_targets(name, phase)
    for index, ankle in enumerate(feet):
        target = (ankle[0], max(ankle[1] - 3, 24))
        hip = _nearest_body_pixel(body, target)
        knee = (
            round((hip[0] + ankle[0]) * 0.5),
            min(ankle[1] - 1, max(hip[1] + 1, target[1])),
        )
        line_color = OUTLINE if index else DEEP_SHADOW
        joint_color = MID_STEEL if index else JOINT_SHADOW
        draw.line((hip, knee, ankle), fill=line_color, width=1)
        draw.point(knee, fill=joint_color)
        foot_left = ankle[0] - (2 if index == 0 else 1)
        foot_right = ankle[0] + (1 if index == 0 else 2)
        draw.rectangle((foot_left, 30, foot_right, 31), fill=line_color)
        if foot_right - foot_left >= 2:
            draw.line((foot_left + 1, 30, foot_right - 1, 30), fill=joint_color)
    return _normalize(layer)


def _translate_to_baseline(frame: Image.Image) -> Image.Image:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Cannot ground an empty death frame")
    delta_y = BASELINE_Y - bbox[3]
    result = _empty()
    result.alpha_composite(frame, (0, delta_y))
    return _normalize(result)


def _draw_death_sword(
    frame: Image.Image,
    body: Image.Image,
    layout: tuple[tuple[int, int], tuple[int, int], tuple[int, int]],
    *,
    front: bool,
) -> int:
    hand, guard, tip = layout
    shoulder = _nearest_body_pixel(body, hand)
    edge_side = -1 if tip[0] >= guard[0] else 1
    sword = anchors.SwordSpec(
        arm=(shoulder, hand),
        hand=hand,
        guard=guard,
        tip=tip,
        edge_side=edge_side,
        front=front,
    )
    anchors._draw_arm(frame, sword)
    return len(anchors._draw_blade(frame, sword))


def _rotate_and_ground(image: Image.Image, angle: int) -> Image.Image:
    if angle == 0:
        return image.copy()
    rotated = image.rotate(
        angle,
        resample=Image.Resampling.NEAREST,
        expand=False,
        center=(20, 26),
        fillcolor=TRANSPARENT,
    )
    bbox = rotated.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"Rotation {angle} produced an empty frame")
    grounded = _empty()
    grounded.alpha_composite(rotated, (0, BASELINE_Y - bbox[3]))
    return _normalize(grounded)


def _power_down(frame: Image.Image, phase: int) -> Image.Image:
    if phase < 5:
        return frame
    result = frame.copy()
    pixels = result.load()
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            pixel = pixels[x, y]
            if phase == 5 and pixel == ACTIVE_RED:
                pixels[x, y] = DEEP_RED
            elif phase == 6 and pixel in (ACTIVE_RED, HOT_ORANGE):
                pixels[x, y] = DEEP_RED
            elif phase >= 7 and pixel in (ACTIVE_RED, HOT_ORANGE, DEEP_RED):
                pixels[x, y] = DEEP_SHADOW
    return _normalize(result)


def _compose_death_frames(
    name: str,
    anchor: Image.Image,
) -> tuple[list[Image.Image], list[tuple[int, int]]]:
    core = _extract_fixed_core(anchor)
    approved_left, approved_right = _build_blade_masks(anchor)
    frames: list[Image.Image] = [anchor.copy()]
    blade_counts: list[tuple[int, int]] = [
        (
            sum(pixel[3] > 0 for pixel in approved_left.getdata()),
            sum(pixel[3] > 0 for pixel in approved_right.getdata()),
        )
    ]
    for phase in range(1, FRAME_COUNT):
        body = _place_rotated_piece(
            core,
            DEATH_ANGLES[name][phase],
            DEATH_BODY_CENTERS[name][phase],
        )
        frame = _draw_death_supports(body, name, phase)
        frame.alpha_composite(body)
        left_layout, right_layout = DEATH_SWORD_LAYOUTS[name][phase]
        left_count = _draw_death_sword(
            frame,
            body,
            left_layout,
            front=False,
        )
        right_count = _draw_death_sword(
            frame,
            body,
            right_layout,
            front=True,
        )
        frame = _translate_to_baseline(_power_down(_normalize(frame), phase))
        frames.append(frame)
        blade_counts.append((left_count, right_count))
    return frames, blade_counts


def _component_count(image: Image.Image, color: tuple[int, int, int, int] | None = None) -> int:
    visible = {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if (
            image.getpixel((x, y))[3] > 0
            and (color is None or image.getpixel((x, y)) == color)
        )
    }
    components = 0
    while visible:
        components += 1
        queue: deque[tuple[int, int]] = deque([visible.pop()])
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
                if point in visible:
                    visible.remove(point)
                    queue.append(point)
    return components


def _audit_pixels(image: Image.Image, label: str) -> None:
    allowed = set(PALETTE) | {TRANSPARENT}
    for pixel in image.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{label} contains non-binary alpha: {pixel}")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{label} contains dirty transparent RGB: {pixel}")
        if pixel not in allowed:
            raise AssertionError(f"{label} contains a color outside the robot palette: {pixel}")


def _frame_report(frame: Image.Image, label: str) -> dict[str, object]:
    if frame.size != (FRAME_SIZE, FRAME_SIZE):
        raise AssertionError(f"{label} is {frame.size}, expected 40x40")
    _audit_pixels(frame, label)
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{label} is empty")
    visible_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])
    if visible_size[0] > MAX_VISIBLE_SIZE or visible_size[1] > MAX_VISIBLE_SIZE:
        raise AssertionError(f"{label} bbox {bbox} exceeds 28x28")
    if bbox[3] != BASELINE_Y:
        raise AssertionError(f"{label} misses baseline y={BASELINE_Y}: {bbox}")
    return {
        "bbox": list(bbox),
        "visible_size": list(visible_size),
        "connected_components": _component_count(frame),
        "blade_highlight_pixels": sum(
            pixel == BLADE_HIGHLIGHT for pixel in frame.getdata()
        ),
        "rgba_sha256": hashlib.sha256(frame.tobytes()).hexdigest(),
    }


def _assert_core_preserved(frame: Image.Image, core: Image.Image, label: str) -> None:
    preserved = 0
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            source = core.getpixel((x, y))
            if source[3] == 0:
                continue
            if frame.getpixel((x, y)) != source:
                raise AssertionError(f"{label} changed fixed core at {(x, y)}")
            preserved += 1
    if preserved == 0:
        raise AssertionError(f"{label} preserved no core pixels")


def _audit_living(
    spec: AnimationSpec,
    frames: Sequence[Image.Image],
    upper: Image.Image,
    legs: Sequence[Image.Image],
    core: Image.Image,
) -> dict[str, object]:
    reports = [
        _frame_report(frame, f"{spec.name}[{index}]")
        for index, frame in enumerate(frames)
    ]
    if len(frames) != FRAME_COUNT:
        raise AssertionError(f"{spec.name} must contain eight frames")
    upper_hash = hashlib.sha256(upper.tobytes()).hexdigest()
    for index, frame in enumerate(frames):
        for y in range(FRAME_SIZE):
            for x in range(FRAME_SIZE):
                upper_pixel = upper.getpixel((x, y))
                if upper_pixel[3] and frame.getpixel((x, y)) != upper_pixel:
                    raise AssertionError(
                        f"{spec.name}[{index}] upper body or blades flicker at {(x, y)}"
                    )
        _assert_core_preserved(frame, core, f"{spec.name}[{index}]")
        if reports[index]["connected_components"] != 1:
            raise AssertionError(f"{spec.name}[{index}] has detached parts")
    leg_hashes = [hashlib.sha256(layer.tobytes()).hexdigest() for layer in legs]
    if len(set(leg_hashes)) != FRAME_COUNT:
        raise AssertionError(f"{spec.name} does not contain eight unique leg phases")
    if spec.name.startswith("boost_"):
        for index, report in enumerate(reports):
            left, _top, right, _bottom = report["bbox"]
            if left < 6 or right > 34:
                raise AssertionError(
                    f"{spec.name}[{index}] lacks six-pixel horizontal trail margin: "
                    f"{report['bbox']}"
                )
    return {
        "kind": spec.kind,
        "fps": spec.fps,
        "frame_count": FRAME_COUNT,
        "loop": True,
        "fixed_upper_sha256": upper_hash,
        "fixed_core_pixels": sum(pixel[3] > 0 for pixel in core.getdata()),
        "unique_leg_phases": len(set(leg_hashes)),
        "phase_contract": "0-3 authored contact/load/pass/push; 4-7 exact mirrored counterparts",
        "frames": reports,
    }


def _audit_death(
    spec: AnimationSpec,
    frames: Sequence[Image.Image],
    blade_counts: Sequence[tuple[int, int]],
    anchor: Image.Image,
) -> dict[str, object]:
    reports = [
        _frame_report(frame, f"{spec.name}[{index}]")
        for index, frame in enumerate(frames)
    ]
    if frames[0].tobytes() != anchor.tobytes():
        raise AssertionError(f"{spec.name}[0] must equal approved anchor C")
    if len({frame.tobytes() for frame in frames}) != FRAME_COUNT:
        raise AssertionError(f"{spec.name} does not contain eight unique frames")
    for index, (report, counts) in enumerate(zip(reports, blade_counts)):
        if report["connected_components"] != 1:
            raise AssertionError(f"{spec.name}[{index}] detaches a blade or limb")
        if counts[0] < 8 or counts[1] < 8:
            raise AssertionError(
                f"{spec.name}[{index}] loses a blade mask: left/right={counts}"
            )
        if report["blade_highlight_pixels"] < 8:
            raise AssertionError(f"{spec.name}[{index}] loses blade highlights")
    return {
        "kind": spec.kind,
        "fps": spec.fps,
        "frame_count": FRAME_COUNT,
        "loop": False,
        "angles_degrees": list(DEATH_ANGLES[spec.name]),
        "death_frame_zero_equals_anchor": True,
        "death_rig": "separate native chassis, support legs and two rigid blade layers with body-to-hilt arm bridges",
        "both_blade_masks_survive": True,
        "blade_mask_pixel_counts": [list(counts) for counts in blade_counts],
        "frames": reports,
    }


def _strip(frames: Sequence[Image.Image]) -> Image.Image:
    result = _empty((FRAME_SIZE * len(frames), FRAME_SIZE))
    for index, frame in enumerate(frames):
        result.alpha_composite(frame, (index * FRAME_SIZE, 0))
    return result


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
        pose = (
            frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            if mirrored
            else frame
        )
        rendered.append(
            _on_background(pose)
            .resize((FRAME_SIZE * 12, FRAME_SIZE * 12), Image.Resampling.NEAREST)
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


def _save_animation_outputs(
    spec: AnimationSpec,
    frames: Sequence[Image.Image],
) -> dict[str, object]:
    strip = _strip(frames)
    native_path = SOURCE_DIR / f"combat_robot_ninja_{spec.name}_candidate_native.png"
    board_path = PREVIEW_DIR / f"combat_robot_ninja_{spec.name}_candidate_16x.png"
    gif_path = PREVIEW_DIR / f"combat_robot_ninja_{spec.name}_candidate.gif"
    mirrored_gif_path = PREVIEW_DIR / (
        f"combat_robot_ninja_{spec.name}_candidate_mirrored.gif"
    )
    strip.save(native_path, optimize=True)
    _on_background(strip).resize(
        (strip.width * 16, strip.height * 16),
        Image.Resampling.NEAREST,
    ).save(board_path, optimize=True)
    _save_gif(frames, gif_path, spec.fps, mirrored=False)
    _save_gif(frames, mirrored_gif_path, spec.fps, mirrored=True)
    return {
        "native_sheet": _relative(native_path),
        "native_sheet_size": list(strip.size),
        "integer_16x_board": _relative(board_path),
        "gif": _relative(gif_path),
        "mirrored_gif": _relative(mirrored_gif_path),
        "native_sha256": _sha256(native_path),
        "board_sha256": _sha256(board_path),
        "gif_sha256": _sha256(gif_path),
        "mirrored_gif_sha256": _sha256(mirrored_gif_path),
    }


def _save_phase_transition_previews(
    animations: dict[str, list[Image.Image]],
) -> dict[str, dict[str, object]]:
    outputs: dict[str, dict[str, object]] = {}
    for move_name in ("move_m1", "move_m2"):
        for boost_name in ("boost_s1", "boost_s2"):
            # Both living animations share the same eight phase semantics.
            # Switch only at phase 4, then switch back at the next phase 4.
            sequence = [
                *animations[move_name][0:4],
                *animations[boost_name][4:8],
                *animations[boost_name][0:4],
                *animations[move_name][4:8],
            ]
            key = f"{move_name.removeprefix('move_')}_{boost_name.removeprefix('boost_')}"
            path = PREVIEW_DIR / f"combat_robot_ninja_transition_{key}.gif"
            _save_gif(sequence, path, fps=24, mirrored=False)
            outputs[key] = {
                "gif": _relative(path),
                "frames": len(sequence),
                "switch_phases": [4, 12],
                "sha256": _sha256(path),
            }
    return outputs


def _green_key(image: Image.Image) -> Image.Image:
    source = image.convert("RGB")
    result = Image.new("RGBA", source.size, TRANSPARENT)
    source_pixels = source.load()
    result_pixels = result.load()
    for y in range(source.height):
        for x in range(source.width):
            red, green, blue = source_pixels[x, y]
            is_green = (
                green >= 96
                and green - red >= 38
                and green - blue >= 38
                and green >= max(red, blue) * 1.35
            )
            if not is_green:
                result_pixels[x, y] = (red, green, blue, 255)
    return result


def _source_report(spec: AnimationSpec) -> dict[str, object]:
    source_path = SOURCE_DIR / spec.source_file
    if not source_path.is_file():
        raise FileNotFoundError(source_path)
    transparent_path = source_path.with_name(
        source_path.name.replace("_imagegen.png", "_transparent.png")
    )
    if transparent_path.is_file():
        transparent = Image.open(transparent_path).convert("RGBA")
        transparency_source = _relative(transparent_path)
        transparency_sha256 = _sha256(transparent_path)
    else:
        transparent = _green_key(Image.open(source_path))
        transparency_source = "in-memory green key"
        transparency_sha256 = None
    bbox = transparent.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError(f"{source_path.name} has no foreground after keying")
    cropped = transparent.crop(bbox)
    analysis = analyze_image(cropped)
    return {
        "path": _relative(source_path),
        "sha256": _sha256(source_path),
        "source_size": list(transparent.size),
        "subject_bbox": list(bbox),
        "subject_crop_size": list(cropped.size),
        "transparency_source": transparency_source,
        "transparency_sha256": transparency_sha256,
        "grid_cell_width": float(analysis["grid_cell_width"]),
        "grid_cell_height": float(analysis["grid_cell_height"]),
        "confidence": float(analysis["confidence"]),
        "detection_mode": str(analysis["detection_mode"]),
        "unsafe_for_direct_resize": (
            str(analysis["detection_mode"]) == "native_or_unknown"
            or float(analysis["confidence"]) < 0.65
        ),
        "source_pixels_imported": False,
        "use": "motion language only",
    }


def _font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    for path in (
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/consola.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if path.is_file():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _source_thumbnail(path: Path, size: int) -> Image.Image:
    image = Image.open(path).convert("RGB")
    image.thumbnail((size, size), Image.Resampling.LANCZOS)
    result = Image.new("RGBA", (size, size), REVIEW_PANEL)
    result.paste(
        image.convert("RGBA"),
        ((size - image.width) // 2, (size - image.height) // 2),
    )
    return result


def _write_comparison(
    animations: dict[str, list[Image.Image]],
) -> Path:
    canvas = Image.new("RGBA", (3220, 2690), REVIEW_BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    title_font = _font(28)
    label_font = _font(20)
    small_font = _font(15)
    draw.text(
        (24, 16),
        "Ninja robot — deterministic second-gate animation candidates",
        fill=REVIEW_TEXT,
        font=title_font,
    )
    draw.text(
        (24, 54),
        "Approved native40 C core; ImageGen boards are motion-language references only",
        fill=REVIEW_MUTED,
        font=small_font,
    )
    strip_scale = 8
    row_height = 430
    for index, spec in enumerate(ANIMATION_SPECS):
        top = 92 + index * row_height
        draw.text(
            (24, top),
            f"{spec.label} — 8f @{spec.fps} FPS",
            fill=REVIEW_TEXT,
            font=label_font,
        )
        strip = _on_background(_strip(animations[spec.name])).resize(
            (FRAME_SIZE * FRAME_COUNT * strip_scale, FRAME_SIZE * strip_scale),
            Image.Resampling.NEAREST,
        )
        canvas.alpha_composite(strip, (24, top + 34))
        draw.text(
            (2640, top),
            "ImageGen motion reference",
            fill=REVIEW_MUTED,
            font=small_font,
        )
        canvas.alpha_composite(
            _source_thumbnail(SOURCE_DIR / spec.source_file, 300),
            (2640, top + 34),
        )
    output_path = PREVIEW_DIR / "combat_robot_ninja_animation_comparison.png"
    canvas.save(output_path, optimize=True)
    return output_path


def _write_manifest(
    source_reports: dict[str, dict[str, object]],
    outputs: dict[str, dict[str, object]],
) -> Path:
    manifest = {
        "version": 1,
        "stage": "animations_approved_awaiting_afterimage",
        "mode": "built-in image_gen plus deterministic native reconstruction",
        "approved_anchor": {
            "selection": "C",
            "path": _relative(APPROVED_ANCHOR_PATH),
            "sha256": _sha256(APPROVED_ANCHOR_PATH),
            "identity_and_pixel_source": True,
        },
        "approved_animation_selection": APPROVED_ANIMATION_SELECTION,
        "imagegen_sources": {
            spec.name: {
                "path": source_reports[spec.name]["path"],
                "sha256": source_reports[spec.name]["sha256"],
                "generated_image": GENERATED_IMAGE_IDS[spec.name],
                "role": "motion language only",
            }
            for spec in ANIMATION_SPECS
        },
        "animation_contract": {
            spec.name: {
                "frames": FRAME_COUNT,
                "fps": spec.fps,
                "loop": spec.kind == "living",
                "label": spec.label,
                "native_sheet": outputs[spec.name]["native_sheet"],
            }
            for spec in ANIMATION_SPECS
        },
        "native_contract": {
            "frame_size": [FRAME_SIZE, FRAME_SIZE],
            "visible_bbox_max": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "body_center_x": REGISTERED_CENTER_X,
            "baseline_y": BASELINE_Y,
            "fixed_palette": [list(color) for color in PALETTE],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "living_core_byte_stable": True,
            "living_leg_phases": 8,
            "move_boost_phase_indices_shared": True,
            "death_blades_never_detach": True,
            "death_rig": "separate native chassis, support legs and two rigid blade layers with body-to-hilt arm bridges",
            "imagegen_pixels_imported": False,
            "runtime_written": False,
        },
    }
    path = enemy_asset_report_path("combat_robot_ninja_animation_manifest.json")
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return path


def _ensure_review_only() -> None:
    runtime_root = (PROJECT_ROOT / "resources").resolve()
    for output_root in (SOURCE_DIR.resolve(), PREVIEW_DIR.resolve()):
        if output_root == runtime_root or runtime_root in output_root.parents:
            raise AssertionError("Ninja animation preview output overlaps runtime resources")


def build() -> dict[str, object]:
    _ensure_review_only()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    if not APPROVED_ANCHOR_PATH.is_file():
        raise FileNotFoundError(APPROVED_ANCHOR_PATH)
    for spec in ANIMATION_SPECS:
        if not (SOURCE_DIR / spec.source_file).is_file():
            raise FileNotFoundError(SOURCE_DIR / spec.source_file)

    anchor = _load_anchor()
    core = _extract_fixed_core(anchor)
    animations: dict[str, list[Image.Image]] = {}
    audits: dict[str, dict[str, object]] = {}
    outputs: dict[str, dict[str, object]] = {}

    for spec in ANIMATION_SPECS:
        if spec.kind == "living":
            frames, upper, legs = _compose_living_frames(spec.name, anchor, core)
            audit = _audit_living(spec, frames, upper, legs, core)
        else:
            frames, blade_counts = _compose_death_frames(spec.name, anchor)
            audit = _audit_death(spec, frames, blade_counts, anchor)
        animations[spec.name] = frames
        audits[spec.name] = audit
        outputs[spec.name] = _save_animation_outputs(spec, frames)

    transition_outputs = _save_phase_transition_previews(animations)

    source_reports = {
        spec.name: _source_report(spec) for spec in ANIMATION_SPECS
    }
    comparison_path = _write_comparison(animations)
    manifest_path = _write_manifest(source_reports, outputs)
    report: dict[str, object] = {
        "asset": "combat_robot_ninja_animation_candidates",
        "stage": "animations_approved_awaiting_afterimage",
        "runtime_written": False,
        "approved_animation_selection": APPROVED_ANIMATION_SELECTION,
        "construction": {
            "approved_anchor": _relative(APPROVED_ANCHOR_PATH),
            "approved_anchor_sha256": _sha256(APPROVED_ANCHOR_PATH),
            "imagegen_source_pixels_imported": False,
            "native_anchor_resized": False,
            "fixed_core_sha256": hashlib.sha256(core.tobytes()).hexdigest(),
            "fixed_core_pixels": sum(pixel[3] > 0 for pixel in core.getdata()),
            "palette": [list(color) for color in PALETTE],
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "frame_size": [FRAME_SIZE, FRAME_SIZE],
            "maximum_visible_bbox": [MAX_VISIBLE_SIZE, MAX_VISIBLE_SIZE],
            "registered_center_x": REGISTERED_CENTER_X,
            "baseline_y": BASELINE_Y,
        },
        "source_grid_analysis": source_reports,
        "animation_audit": audits,
        "outputs": outputs,
        "phase_transition_previews": transition_outputs,
        "comparison": _relative(comparison_path),
        "manifest": _relative(manifest_path),
    }
    report_path = enemy_asset_report_path("combat_robot_ninja_animation_preview_report.json")
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
