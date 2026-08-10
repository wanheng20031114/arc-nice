#!/usr/bin/env python3
"""Build preview-only animation choices for the cardboard monster.

The six ImageGen sheets are structure-language references only.  Native pixels
are authored from the approved F2 anchor with fixed palette values and explicit
per-frame point/row tables.  This script refuses every output outside
``dev_assets`` and never writes runtime resources.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageSequence

from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import normalize_source


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "cardboard_monster"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"
ANCHOR = SOURCE_DIR / "cardboard_monster_anchor_approved_native32.png"
ANCHOR_MANIFEST = enemy_asset_report_path("cardboard_monster_anchor_manifest.json")
ANCHOR_REPORT = enemy_asset_report_path("cardboard_monster_anchor_report.json")
ANIMATION_MANIFEST = enemy_asset_report_path("cardboard_monster_animation_manifest.json")
REPORT_PATH = enemy_asset_report_path("cardboard_monster_animation_preview_report.json")
STABILITY_PATH = enemy_asset_report_path("cardboard_monster_animation_stability.json")

FRAME = 32
COUNT = 8
BACKGROUND = (14, 20, 29, 255)
TRANSPARENT = (0, 0, 0, 0)
OUTLINE = (116, 87, 61, 255)
DEEP_BROWN = (88, 64, 45, 255)
LIMB_BROWN = (123, 87, 55, 255)
KRAFT_DARK = (177, 145, 102, 255)
KRAFT_MID = (210, 181, 137, 255)
KRAFT_LIGHT = (232, 213, 177, 255)
FOLD_HIGHLIGHT = (245, 234, 208, 255)
PAPER_EDGE = (154, 117, 78, 255)
PAPER_STICK = (225, 202, 159, 255)
EYE_DARK = (79, 67, 59, 255)
PALETTE = frozenset((
    TRANSPARENT, OUTLINE, DEEP_BROWN, LIMB_BROWN, KRAFT_DARK, KRAFT_MID,
    KRAFT_LIGHT, FOLD_HIGHLIGHT, PAPER_EDGE, PAPER_STICK, EYE_DARK,
))

EXPECTED = {
    ANCHOR: "745cc7ec73e3d2268a91f6fb97db996821f32c49b3dc80eb1a4b122ebc298a3d",
    ANCHOR_MANIFEST: "d634689313146886a52f865dcb2b13fe1eb8b2102df8e9e98cedd5c2487ecff3",
    ANCHOR_REPORT: "687cd19cad87c0cc12fee5447181c719a777e8ef792e621a0462bd874459330f",
}

RAW_FILES = {
    "m1": SOURCE_DIR / "cardboard_monster_move_m1_imagegen.png",
    "m2": SOURCE_DIR / "cardboard_monster_move_m2_walk_refinement_imagegen.png",
    "a1": SOURCE_DIR / "cardboard_monster_attack_a1_imagegen.png",
    "a2": SOURCE_DIR / "cardboard_monster_attack_a2_imagegen.png",
    "d1": SOURCE_DIR / "cardboard_monster_death_d1_imagegen.png",
    "d2": SOURCE_DIR / "cardboard_monster_death_d2_imagegen.png",
}

# Filled only after the six one-call ImageGen originals have landed.  The
# script fails closed until every source is explicitly locked.
EXPECTED_RAW_SHA = {
    "m1": "e94130eb76da5019dbd24a111f5662d3560b6a153da5e8aa0d4ca1ad0923658c",
    "m2": "8c4568c809ee98fcac255ff907ea342e9134817af2adde620ecf3c703ba4c86a",
    "a1": "d70f399250981372bb7ed654d1e9520ed6f4a013fc59bd2cecb2dc3fd477a6fc",
    "a2": "766edecaa0308bbc16b1b91ccd5fdab23d44c33ea3d3194be683fe8976372e9a",
    "d1": "b496ba3dda91475a95286bfc25baee665462efac14a42d47f8eac3a1e490176b",
    "d2": "ec2ad08792bb93d5e95be70751abe468ad8764693af44531b1004d4a5c8dd535",
}

SPECS = {
    "m1": {"name": "move_m1", "title": "M1 守棒蹒跚", "author_fps": 10, "durations": [100] * 8},
    "m2": {"name": "move_m2", "title": "M2 纸脚碎步（八相步态优化）", "author_fps": 12, "durations": [80] * 8},
    "a1": {"name": "attack_a1", "title": "A1 短弧下挥", "author_fps": [9, 15], "durations": [110] * 3 + [70] * 5},
    "a2": {"name": "attack_a2", "title": "A2 短弧横扫", "author_fps": [9, 15], "durations": [110] * 3 + [70] * 5},
    "d1": {"name": "death_d1", "title": "D1 持棒侧倒", "author_fps": 10, "durations": [100] * 8},
    "d2": {"name": "death_d2", "title": "D2 连棒折叠", "author_fps": 8, "durations": [120] * 8},
}

SUPERSEDED_M2_LOCK = {
    "native_png_sha256": "b879d83c211ca7a3691334553d7e002a95d31da7377fd5a0fb557690edac013a",
    "native_rgba_sha256": "39373ad19a91b671dab852db6aa947f7dc5dc11349293f4b68a08aed2fa9d479",
    "reason": "双脚全程接地，读形更像同步蹲动而不是行走",
}
SELECTED_FIXED_LOCKS = {
    "attack_a2": {
        "native_png_sha256": "591f9d8c0d4578691b10251407d887961b72655c400e996369c9783e73d1bb08",
        "native_rgba_sha256": "902dc0a494cf00df383757872ff7d2ac1e9308623310b73820241cff2911fed8",
    },
    "death_d2": {
        "native_png_sha256": "b785d42a4ea07773c8931193baec43e10b50405bc8b29bb7ff3833e1540a822c",
        "native_rgba_sha256": "1caafb0e2db08c15e99fc87ab88c80b493a939b3af601d9a74266715804fb169",
    },
}
SECOND_GATE_DRAFT_SELECTION = {
    "move": {"candidate": "m2", "status": "refinement_ready_for_human_recheck"},
    "attack": {"candidate": "a2", "status": "human_selected"},
    "death": {"candidate": "d2", "status": "human_selected"},
}
APPROVED_ANIMATION_SELECTION = {"move": "m2", "attack": "a2", "death": "d2"}
APPROVAL_ENUMS = {
    "move": ("m1", "m2"),
    "attack": ("a1", "a2"),
    "death": ("d1", "d2"),
}
PENDING_SECOND_GATE_CERTIFICATE = {
    "builder_sha256": "02e66e08710af38a3c08b7c45e9bef0515127dd47d079e21a3a71dff84b4b766",
    "report_sha256": "8bdca8cea1f7b2ae7ea37081c7b7b6c3fc482795a3e907498888d2ac729ea922",
    "manifest_sha256": "e9b75d5606eba7142cee4474704422f5f3d1826b646d506dc90582d1e4cb7d6e",
    "stability_sha256": "40b40cf20d9ed39823268adedb3457c54c1c702e7c7dbc16ec90a5196f0924a3",
    "stage": "animation_candidates_pending_second_human_gate",
}
APPROVED_SELECTED_LOCKS = {
    "m2": {
        "native_png_sha256": "d3ceed3890ea35e7650ff4143fec139392c49c0c02bd389c1ae11713731840b5",
        "native_rgba_sha256": "57f6c81d3c2f0f02d4fca07037553d581648d91f6c4066ad0f8ef20b4637fe6f",
    },
    "a2": SELECTED_FIXED_LOCKS["attack_a2"],
    "d2": SELECTED_FIXED_LOCKS["death_d2"],
}

Point = tuple[int, int]
Color = tuple[int, int, int, int]


@dataclass(frozen=True)
class LimbPose:
    free_arm: frozenset[Point]
    weapon_arm: frozenset[Point]
    left_leg: frozenset[Point]
    right_leg: frozenset[Point]
    deep: frozenset[Point]


@dataclass(frozen=True)
class StickPose:
    edge: tuple[Point, ...]
    fill: tuple[Point, ...]
    highlights: tuple[Point, ...]
    endpoints: tuple[Point, Point]


def fs(*points: Point) -> frozenset[Point]:
    return frozenset(points)


IDLE_STICK = StickPose(
    edge=((23,20),(24,19),(25,18),(26,17),(27,16),(28,15),(29,14),(30,13)),
    fill=((23,19),(24,18),(25,17),(26,16),(27,15),(28,14),(29,13),(30,12)),
    highlights=((29,13),(29,12),(30,12)),
    endpoints=((23,20),(30,13)),
)
IDLE_LIMBS = LimbPose(
    free_arm=fs((8,19),(7,19),(7,20),(7,21),(8,21)),
    weapon_arm=fs((23,20),(24,20),(24,21)),
    left_leg=fs((12,24),(12,25),(11,26),(11,27),(10,27)),
    right_leg=fs((19,24),(19,25),(20,26),(20,27),(21,27)),
    deep=fs((7,21),(8,21),(24,20),(24,21),(10,27),(21,27)),
)

M1_LIMBS = (
    IDLE_LIMBS,
    LimbPose(fs((8,20),(7,20),(7,21),(7,22),(8,22)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(11,26),(10,27),(9,27)),fs((19,24),(19,25),(20,26),(21,27),(22,27)),fs((7,21),(7,22),(8,22),(24,20),(24,21),(9,27),(22,27))),
    LimbPose(fs((8,18),(7,18),(7,19),(7,20),(8,20)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(11,26),(10,27),(9,27)),fs((19,24),(19,25),(19,26),(20,27),(21,27)),fs((7,19),(7,20),(8,20),(24,20),(24,21),(9,27),(21,27))),
    LimbPose(fs((8,17),(7,17),(7,18),(8,18)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(12,26),(13,27),(14,27)),fs((19,24),(19,25),(20,26),(21,27),(22,27)),fs((7,17),(7,18),(8,18),(24,20),(24,21),(14,27),(22,27))),
    LimbPose(fs((8,18),(7,18),(7,19),(8,19)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(13,26),(14,27),(15,27)),fs((19,24),(19,25),(18,26),(18,27),(17,27)),fs((7,18),(7,19),(8,19),(24,20),(24,21),(15,27),(17,27))),
    LimbPose(fs((8,20),(7,20),(7,21),(7,22),(8,22)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(13,26),(14,27),(15,27)),fs((19,24),(19,25),(18,26),(17,27),(16,27)),fs((7,21),(7,22),(8,22),(24,20),(24,21),(15,27),(16,27))),
    LimbPose(fs((8,20),(7,20),(7,21),(7,22),(8,22)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(12,26),(11,27),(10,27)),fs((19,24),(19,25),(18,26),(17,27),(16,27)),fs((7,22),(8,22),(24,20),(24,21),(10,27),(16,27))),
    LimbPose(fs((8,19),(7,19),(7,20),(7,21),(8,21)),fs((23,20),(24,20),(24,21)),fs((12,24),(12,25),(11,26),(11,27),(10,27)),fs((19,24),(19,25),(18,26),(18,27),(17,27)),fs((7,21),(8,21),(24,20),(24,21),(10,27),(17,27))),
)

M2_GAIT_PHASES = ("contact", "down", "pass", "up", "opposite_contact", "down", "pass", "up")
M2_CORE_OFFSETS = (0, 1, 0, 0, 0, 1, 0, 0)
M2_LIMBS = (
    # F0 contact: the approved anchor pose, both feet planted.
    IDLE_LIMBS,
    # F1 down: the whole body, hand and diagonal stick move down exactly 1px.
    LimbPose(
        fs((8,20),(7,20),(7,21),(7,22),(8,22)),
        fs((23,21),(24,21),(24,22)),
        fs((12,25),(11,26),(10,27),(9,27)),
        fs((19,25),(20,26),(21,27),(22,27)),
        fs((7,22),(8,22),(24,21),(24,22),(9,27),(10,27),(21,27),(22,27)),
    ),
    # F2 pass: left foot swings above the floor; right foot supports.
    LimbPose(
        fs((8,19),(7,19),(7,20),(7,21),(8,21)),
        fs((23,20),(24,20),(24,21)),
        fs((12,24),(12,25),(13,25),(14,26),(15,26)),
        fs((19,24),(19,25),(19,26),(19,27),(20,27)),
        fs((7,21),(8,21),(24,20),(24,21),(14,26),(15,26),(19,27),(20,27)),
    ),
    # F3 up: left swing advances while the right support leg pushes back.
    LimbPose(
        fs((8,18),(7,18),(7,19),(7,20),(8,20)),
        fs((23,20),(24,20),(24,21)),
        fs((12,24),(13,25),(14,25),(15,26),(16,26)),
        fs((19,24),(19,25),(18,26),(18,27),(17,27)),
        fs((7,19),(7,20),(8,20),(24,20),(24,21),(15,26),(16,26),(17,27),(18,27)),
    ),
    # F4 opposite contact: the legs exchange support roles.
    LimbPose(
        fs((8,19),(7,19),(7,20),(7,21),(8,21)),
        fs((23,20),(24,20),(24,21)),
        fs((12,24),(13,25),(14,26),(15,27),(16,27)),
        fs((19,24),(18,25),(17,26),(17,27),(18,27)),
        fs((7,21),(8,21),(24,20),(24,21),(15,27),(16,27),(17,27),(18,27)),
    ),
    # F5 down: second and only other 1px body/stick drop.
    LimbPose(
        fs((8,20),(7,20),(7,21),(7,22),(8,22)),
        fs((23,21),(24,21),(24,22)),
        fs((12,25),(13,26),(14,27),(15,27)),
        fs((19,25),(18,26),(17,27),(18,27)),
        fs((7,22),(8,22),(24,21),(24,22),(14,27),(15,27),(17,27),(18,27)),
    ),
    # F6 pass: right foot swings above the floor; left foot supports.
    LimbPose(
        fs((8,19),(7,19),(7,20),(8,20)),
        fs((23,20),(24,20),(24,21)),
        fs((12,24),(12,25),(13,26),(13,27),(14,27)),
        fs((19,24),(19,25),(18,25),(18,26),(19,26)),
        fs((7,19),(7,20),(8,20),(24,20),(24,21),(13,27),(14,27),(18,26),(19,26)),
    ),
    # F7 up: right swing advances and lands into F0 without a jump.
    LimbPose(
        fs((8,18),(7,18),(7,19),(8,19)),
        fs((23,20),(24,20),(24,21)),
        fs((12,24),(12,25),(11,26),(11,27),(10,27)),
        fs((19,24),(20,25),(21,25),(21,26),(22,26)),
        fs((7,18),(7,19),(8,19),(24,20),(24,21),(10,27),(11,27),(21,26),(22,26)),
    ),
)

IDLE_STICK_DOWN_1 = StickPose(
    edge=((23,21),(24,20),(25,19),(26,18),(27,17),(28,16),(29,15),(30,14)),
    fill=((23,20),(24,19),(25,18),(26,17),(27,16),(28,15),(29,14),(30,13)),
    highlights=((29,14),(29,13),(30,13)), endpoints=((23,21),(30,14)),
)
M2_STICKS = (
    IDLE_STICK, IDLE_STICK_DOWN_1, IDLE_STICK, IDLE_STICK,
    IDLE_STICK, IDLE_STICK_DOWN_1, IDLE_STICK, IDLE_STICK,
)

STEEP_STICK = StickPose(
    edge=((23,20),(24,19),(24,18),(25,17),(25,16),(26,15),(26,14),(27,13),(27,12),(28,11)),
    fill=((24,20),(25,19),(25,18),(26,17),(26,16),(27,15),(27,14),(28,13),(28,12),(29,11)),
    highlights=((28,11),(29,11),(28,12)), endpoints=((23,20),(28,11)),
)
VERTICAL_STICK = StickPose(
    edge=((23,20),(23,19),(24,18),(24,17),(24,16),(25,15),(25,14),(25,13),(26,12),(26,11)),
    fill=((24,20),(24,19),(25,18),(25,17),(25,16),(26,15),(26,14),(26,13),(27,12),(27,11)),
    highlights=((26,11),(27,11),(27,12)), endpoints=((23,20),(26,11)),
)
MID_STICK = StickPose(
    edge=((23,20),(24,19),(25,19),(26,18),(27,18),(28,17),(29,17),(30,16),(31,16)),
    fill=((23,19),(24,18),(25,18),(26,17),(27,17),(28,16),(29,16),(30,15),(31,15)),
    highlights=((30,15),(31,15),(31,16)), endpoints=((23,20),(31,16)),
)
SHALLOW_STICK = StickPose(
    edge=((22,20),(23,20),(24,20),(25,19),(26,19),(27,19),(28,18),(29,18),(30,18),(31,17)),
    fill=((22,19),(23,19),(24,19),(25,18),(26,18),(27,18),(28,17),(29,17),(30,17),(31,16)),
    highlights=((30,17),(31,16),(31,17)), endpoints=((22,20),(31,17)),
)
HORIZONTAL_STICK = StickPose(
    edge=tuple((x,20) for x in range(22,32)),
    fill=tuple((x,19) for x in range(22,32)),
    highlights=((30,19),(31,19),(31,20)), endpoints=((22,20),(31,20)),
)
DOWN_STICK = StickPose(
    edge=((22,20),(23,20),(24,21),(25,21),(26,22),(27,22),(28,23),(29,23),(30,24),(31,24)),
    fill=((22,19),(23,19),(24,20),(25,20),(26,21),(27,21),(28,22),(29,22),(30,23),(31,23)),
    highlights=((30,23),(31,23),(31,24)), endpoints=((22,20),(31,24)),
)
RETURN_STICK = StickPose(
    edge=((23,20),(24,19),(25,18),(26,18),(27,17),(28,16),(29,15),(30,14)),
    fill=((23,19),(24,18),(25,17),(26,17),(27,16),(28,15),(29,14),(30,13)),
    highlights=((29,14),(30,13),(30,14)), endpoints=((23,20),(30,14)),
)

ATTACK_BASE_LIMBS = LimbPose(
    free_arm=fs((8,19),(7,19),(7,20),(7,21),(8,21)),
    weapon_arm=fs((23,20),(24,20),(24,21)),
    left_leg=IDLE_LIMBS.left_leg, right_leg=IDLE_LIMBS.right_leg,
    deep=IDLE_LIMBS.deep,
)
ATTACK_LIFT_LIMBS = LimbPose(
    free_arm=fs((8,19),(7,19),(7,20),(7,21),(8,21)),
    weapon_arm=fs((23,20),(24,20),(24,19)),
    left_leg=IDLE_LIMBS.left_leg, right_leg=IDLE_LIMBS.right_leg,
    deep=fs((7,21),(8,21),(24,20),(24,19),(10,27),(21,27)),
)
ATTACK_SWEEP_LIMBS = LimbPose(
    free_arm=fs((8,18),(7,18),(7,19),(6,19),(6,20)),
    weapon_arm=fs((23,20),(24,20),(25,20)),
    left_leg=IDLE_LIMBS.left_leg, right_leg=IDLE_LIMBS.right_leg,
    deep=fs((6,19),(6,20),(24,20),(25,20),(10,27),(21,27)),
)
ATTACK_DOWN_LIMBS = LimbPose(
    free_arm=fs((8,18),(7,18),(6,18),(6,19),(6,20)),
    weapon_arm=fs((23,20),(24,20),(24,21),(25,21)),
    left_leg=IDLE_LIMBS.left_leg, right_leg=IDLE_LIMBS.right_leg,
    deep=fs((6,19),(6,20),(24,20),(24,21),(25,21),(10,27),(21,27)),
)
ATTACK_RECOVER_LIMBS = LimbPose(
    free_arm=fs((8,19),(7,19),(7,20),(8,20)),
    weapon_arm=fs((23,20),(24,20),(24,21)),
    left_leg=IDLE_LIMBS.left_leg, right_leg=IDLE_LIMBS.right_leg,
    deep=fs((7,20),(8,20),(24,20),(24,21),(10,27),(21,27)),
)

A1_STICKS = (IDLE_STICK, STEEP_STICK, VERTICAL_STICK, STEEP_STICK, MID_STICK, SHALLOW_STICK, RETURN_STICK, IDLE_STICK)
A1_LIMBS = (ATTACK_BASE_LIMBS, ATTACK_LIFT_LIMBS, ATTACK_LIFT_LIMBS, ATTACK_BASE_LIMBS, ATTACK_SWEEP_LIMBS, ATTACK_DOWN_LIMBS, ATTACK_SWEEP_LIMBS, ATTACK_RECOVER_LIMBS)
A2_STICKS = (IDLE_STICK, STEEP_STICK, VERTICAL_STICK, VERTICAL_STICK, MID_STICK, HORIZONTAL_STICK, SHALLOW_STICK, IDLE_STICK)
A2_LIMBS = (ATTACK_BASE_LIMBS, ATTACK_LIFT_LIMBS, ATTACK_LIFT_LIMBS, ATTACK_BASE_LIMBS, ATTACK_SWEEP_LIMBS, ATTACK_SWEEP_LIMBS, ATTACK_SWEEP_LIMBS, ATTACK_RECOVER_LIMBS)

# Death body geometry is deliberately stored as explicit inclusive row runs.
D1_BODY_ROWS = (
    {y:(8,23) for y in range(12,25)},
    {13:(9,23), **{y:(8,24) for y in range(14,25)}},
    {14:(10,24), **{y:(9,25) for y in range(15,25)}},
    {15:(11,25), **{y:(10,26) for y in range(16,26)}},
    {17:(12,26), **{y:(9,27) for y in range(18,26)}},
    {19:(10,23), **{y:(8,24) for y in range(20,27)}},
    {21:(9,23), **{y:(7,24) for y in range(22,27)}},
    {23:(8,21), **{y:(6,22) for y in range(24,28)}},
)
D2_BODY_ROWS = (
    {y:(8,23) for y in range(12,25)},
    {y:(8,23) for y in range(13,25)},
    {y:(8,23) for y in range(14,26)},
    {y:(8,23) for y in range(15,26)},
    {y:(7,24) for y in range(17,27)},
    {y:(6,25) for y in range(19,27)},
    {y:(5,26) for y in range(21,28)},
    {y:(4,27) for y in range(23,28)},
)

D1_EYES = (
    fs((13,17),(13,18),(17,17),(17,18)), fs((14,18),(14,19),(18,18),(18,19)),
    fs((15,19),(15,20),(19,19),(19,20)), fs((16,20),(16,21),(20,20),(20,21)),
    fs((17,21),(18,22),(21,21),(22,22)), fs((16,23),(17,24),(20,23),(21,24)),
    fs((14,24),(15,25),(18,24),(19,25)), fs((11,25),(12,26),(15,25),(16,26)),
)
D2_EYES = (
    D1_EYES[0], fs((13,18),(13,19),(17,18),(17,19)), fs((13,19),(13,20),(17,19),(17,20)),
    fs((13,20),(13,21),(17,20),(17,21)), fs((13,22),(13,23),(18,22),(18,23)),
    fs((13,23),(13,24),(18,23),(18,24)), fs((12,24),(13,24),(18,24),(19,24)), fs(),
)

D1_LIMBS = (
    IDLE_LIMBS,
    LimbPose(fs((8,20),(7,20),(7,21),(8,21)),fs((24,21),(25,21),(25,22)),fs((12,24),(12,25),(11,26),(10,27)),fs((20,24),(20,25),(21,26),(22,27)),fs((7,21),(8,21),(25,21),(25,22),(10,27),(22,27))),
    LimbPose(fs((9,21),(8,21),(8,22),(9,22)),fs((25,22),(26,22),(26,23)),fs((13,24),(13,25),(12,26),(11,27)),fs((21,24),(21,25),(22,26),(23,27)),fs((8,22),(9,22),(26,22),(26,23),(11,27),(23,27))),
    LimbPose(fs((10,22),(9,22),(9,23),(10,23)),fs((26,23),(27,23),(27,24)),fs((14,25),(14,26),(13,27)),fs((22,25),(22,26),(23,27)),fs((9,23),(10,23),(27,23),(27,24),(13,27),(23,27))),
    LimbPose(fs((10,23),(9,23),(9,24),(10,24)),fs((26,24),(27,24),(27,25)),fs((14,25),(13,26),(12,27)),fs((22,25),(23,26),(24,27)),fs((9,24),(10,24),(27,24),(27,25),(12,27),(24,27))),
    LimbPose(fs((9,24),(8,24),(8,25),(9,25)),fs((25,25),(26,25),(26,26)),fs((13,26),(12,27)),fs((21,26),(22,27)),fs((8,25),(9,25),(26,25),(26,26),(12,27),(22,27))),
    LimbPose(fs((8,25),(7,25),(7,26),(8,26)),fs((24,26),(25,26),(25,27)),fs((12,26),(11,27)),fs((20,26),(21,27)),fs((7,26),(8,26),(25,26),(25,27),(11,27),(21,27))),
    LimbPose(fs((7,26),(6,26),(6,27),(7,27)),fs((22,26),(23,26),(23,27)),fs((11,27),(12,27)),fs((19,27),(20,27)),fs((6,27),(7,27),(23,26),(23,27),(11,27),(20,27))),
)

D1_STICKS = (
    IDLE_STICK,
    StickPose(((24,21),(25,20),(26,19),(27,18),(28,17),(29,16),(30,15),(31,14)),((24,20),(25,19),(26,18),(27,17),(28,16),(29,15),(30,14),(31,13)),((30,14),(31,13),(31,14)),((24,21),(31,14))),
    StickPose(((25,22),(26,21),(27,20),(28,19),(29,18),(30,17),(31,16)),((25,21),(26,20),(27,19),(28,18),(29,17),(30,16),(31,15)),((30,16),(31,15),(31,16)),((25,22),(31,16))),
    StickPose(tuple((x,23) for x in range(22,32)),tuple((x,22) for x in range(22,32)),((30,22),(31,22),(31,23)),((22,23),(31,23))),
    StickPose(tuple((x,24) for x in range(22,32)),tuple((x,23) for x in range(22,32)),((30,23),(31,23),(31,24)),((22,24),(31,24))),
    StickPose(tuple((x,25) for x in range(22,32)),tuple((x,24) for x in range(22,32)),((30,24),(31,24),(31,25)),((22,25),(31,25))),
    StickPose(tuple((x,27) for x in range(22,32)),tuple((x,26) for x in range(22,32)),((30,26),(31,26),(31,27)),((22,27),(31,27))),
    StickPose(tuple((x,26) for x in range(22,32)),tuple((x,25) for x in range(22,32)),((30,25),(31,25),(31,26)),((22,26),(31,26))),
)

D2_LIMBS = (
    IDLE_LIMBS,
    LimbPose(fs((8,20),(7,20),(7,21),(8,21)),fs((23,21),(24,21),(24,22)),fs((12,24),(12,25),(11,26),(10,27)),fs((19,24),(19,25),(20,26),(21,27)),fs((7,21),(8,21),(24,21),(24,22),(10,27),(21,27))),
    LimbPose(fs((8,21),(7,21),(7,22),(8,22)),fs((23,22),(24,22),(24,23)),fs((12,25),(12,26),(11,27)),fs((19,25),(19,26),(20,27)),fs((7,22),(8,22),(24,22),(24,23),(11,27),(20,27))),
    LimbPose(fs((8,22),(7,22),(7,23),(8,23)),fs((23,23),(24,23),(24,24)),fs((12,25),(11,26),(10,27)),fs((19,25),(20,26),(21,27)),fs((7,23),(8,23),(24,23),(24,24),(10,27),(21,27))),
    LimbPose(fs((7,24),(6,24),(6,25),(7,25)),fs((24,24),(25,24),(25,25)),fs((11,26),(10,27)),fs((20,26),(21,27)),fs((6,25),(7,25),(25,24),(25,25),(10,27),(21,27))),
    LimbPose(fs((6,25),(5,25),(5,26),(6,26)),fs((24,25),(25,25),(25,26)),fs((10,26),(9,27)),fs((20,26),(21,27)),fs((5,26),(6,26),(25,25),(25,26),(9,27),(21,27))),
    LimbPose(fs((5,26),(4,26),(4,27),(5,27)),fs((23,26),(24,26),(24,27)),fs((9,27),(10,27)),fs((20,27),(21,27)),fs((4,27),(5,27),(24,26),(24,27),(9,27),(21,27))),
    LimbPose(fs((5,26),(4,26),(4,27),(5,27)),fs((22,26),(23,26),(23,27)),fs((9,27),(10,27)),fs((20,27),(21,27)),fs((4,27),(5,27),(23,26),(23,27),(9,27),(21,27))),
)

D2_STICKS = (
    IDLE_STICK,
    StickPose(((23,21),(24,20),(25,19),(26,18),(27,17),(28,16),(29,15),(30,14)),((23,20),(24,19),(25,18),(26,17),(27,16),(28,15),(29,14),(30,13)),((29,14),(30,13),(30,14)),((23,21),(30,14))),
    StickPose(((23,22),(24,21),(25,20),(26,19),(27,18),(28,17),(29,16)),((23,21),(24,20),(25,19),(26,18),(27,17),(28,16),(29,15)),((28,16),(29,15),(29,16)),((23,22),(29,16))),
    StickPose(((23,23),(24,22),(25,21),(26,20),(27,19),(28,18)),((23,22),(24,21),(25,20),(26,19),(27,18),(28,17)),((27,18),(28,17),(28,18)),((23,23),(28,18))),
    StickPose(((24,24),(25,23),(26,22),(27,21),(28,20)),((24,23),(25,22),(26,21),(27,20),(28,19)),((27,20),(28,19),(28,20)),((24,24),(28,20))),
    StickPose(((24,25),(25,24),(26,23),(27,22)),((24,24),(25,23),(26,22),(27,21)),((26,22),(27,21),(27,22)),((24,25),(27,22))),
    StickPose(((23,26),(24,25),(25,24)),((23,25),(24,24),(25,23)),((25,23),(25,24)),((23,26),(25,24))),
    StickPose(((22,26),(23,25)),((22,25),(23,24)),((23,24),),((22,26),(23,25))),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def ensure_dev(path: Path) -> None:
    resolved = path.resolve()
    dev = (ROOT / "dev_assets").resolve()
    if resolved != dev and dev not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Refused non-dev output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def write_json(path: Path, payload: object) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def put_points(image: Image.Image, points: set[Point] | frozenset[Point] | tuple[Point, ...], color: Color) -> None:
    for point in points:
        if not (0 <= point[0] < FRAME and 0 <= point[1] < FRAME):
            raise AssertionError(f"Point outside frame: {point}")
        image.putpixel(point, color)


def body_mask(rows: dict[int, tuple[int, int]]) -> set[Point]:
    return {(x,y) for y,(left,right) in rows.items() for x in range(left,right+1)}


def paint_mask(image: Image.Image, mask: set[Point]) -> None:
    for x,y in mask:
        boundary = any((x+dx,y+dy) not in mask for dx,dy in ((-1,0),(1,0),(0,-1),(0,1)))
        image.putpixel((x,y), OUTLINE if boundary else KRAFT_MID)


def flat_core(offset_y: int = 0) -> tuple[Image.Image, set[Point]]:
    image = Image.new("RGBA", (FRAME,FRAME), TRANSPARENT)
    mask = {(x,y+offset_y) for y in range(12,25) for x in range(8,24)}
    paint_mask(image, mask)
    put_points(image, tuple((x,12+offset_y) for x in range(9,23)), FOLD_HIGHLIGHT)
    put_points(image, tuple((x,13+offset_y) for x in range(9,22)), KRAFT_LIGHT)
    put_points(image, tuple((22,y+offset_y) for y in range(14,24)), KRAFT_DARK)
    image.putpixel((9,14+offset_y), KRAFT_MID)
    put_points(image, fs((13,17+offset_y),(13,18+offset_y),(17,17+offset_y),(17,18+offset_y)), EYE_DARK)
    return image, mask


def paint_limb_pose(image: Image.Image, pose: LimbPose) -> None:
    put_points(image, pose.free_arm | pose.weapon_arm | pose.left_leg | pose.right_leg, LIMB_BROWN)
    put_points(image, pose.deep, DEEP_BROWN)


def paint_stick(image: Image.Image, stick: StickPose, weapon_arm: frozenset[Point]) -> None:
    put_points(image, stick.fill, PAPER_STICK)
    put_points(image, stick.edge, PAPER_EDGE)
    put_points(image, stick.highlights, FOLD_HIGHLIGHT)
    put_points(image, weapon_arm, DEEP_BROWN)


def living_frame(pose: LimbPose, stick: StickPose, offset_y: int = 0) -> Image.Image:
    image,_ = flat_core(offset_y)
    paint_limb_pose(image, pose)
    paint_stick(image, stick, pose.weapon_arm)
    return image


def death_frame(rows: dict[int, tuple[int,int]], eyes: frozenset[Point], limbs: LimbPose, stick: StickPose) -> Image.Image:
    image = Image.new("RGBA", (FRAME,FRAME), TRANSPARENT)
    mask = body_mask(rows)
    paint_mask(image, mask)
    top_y = min(rows)
    left,right = rows[top_y]
    put_points(image, tuple((x,top_y) for x in range(left+1,right)), FOLD_HIGHLIGHT)
    for y,(row_left,row_right) in rows.items():
        if row_right-1 > row_left:
            image.putpixel((row_right-1,y), KRAFT_DARK)
    put_points(image, eyes, EYE_DARK)
    paint_limb_pose(image, limbs)
    paint_stick(image, stick, limbs.weapon_arm)
    return image


def build_all() -> dict[str,list[Image.Image]]:
    m1 = [living_frame(M1_LIMBS[index], IDLE_STICK) for index in range(COUNT)]
    m2 = [living_frame(M2_LIMBS[index], M2_STICKS[index], M2_CORE_OFFSETS[index]) for index in range(COUNT)]
    a1 = [living_frame(A1_LIMBS[index], A1_STICKS[index]) for index in range(COUNT)]
    a2 = [living_frame(A2_LIMBS[index], A2_STICKS[index]) for index in range(COUNT)]
    d1 = [living_frame(IDLE_LIMBS, IDLE_STICK)] + [death_frame(D1_BODY_ROWS[index], D1_EYES[index], D1_LIMBS[index], D1_STICKS[index]) for index in range(1,COUNT)]
    d2 = [living_frame(IDLE_LIMBS, IDLE_STICK)] + [death_frame(D2_BODY_ROWS[index], D2_EYES[index], D2_LIMBS[index], D2_STICKS[index]) for index in range(1,COUNT)]
    return {"m1":m1,"m2":m2,"a1":a1,"a2":a2,"d1":d1,"d2":d2}


def opaque_points(image: Image.Image) -> set[Point]:
    return {(x,y) for y in range(FRAME) for x in range(FRAME) if image.getpixel((x,y))[3]}


def component_count(points: set[Point]) -> int:
    remaining = set(points)
    count = 0
    while remaining:
        count += 1
        start = remaining.pop()
        pending = deque((start,))
        while pending:
            x,y = pending.popleft()
            for dy in (-1,0,1):
                for dx in (-1,0,1):
                    if dx == 0 and dy == 0:
                        continue
                    point = (x+dx,y+dy)
                    if point in remaining:
                        remaining.remove(point)
                        pending.append(point)
    return count


def touches_mask_8(points: frozenset[Point], mask: set[Point]) -> bool:
    return any(
        (x + dx, y + dy) in mask
        for x, y in points
        for dx in (-1, 0, 1)
        for dy in (-1, 0, 1)
    )


def audit_m2_gait() -> None:
    expected_phases = ("contact", "down", "pass", "up", "opposite_contact", "down", "pass", "up")
    expected_offsets = (0, 1, 0, 0, 0, 1, 0, 0)
    if M2_GAIT_PHASES != expected_phases or M2_CORE_OFFSETS != expected_offsets:
        raise AssertionError("M2 gait phase/offset contract drifted")
    for index, (pose, offset, stick) in enumerate(zip(M2_LIMBS, M2_CORE_OFFSETS, M2_STICKS)):
        _, core = flat_core(offset)
        for label, leg in (("left", pose.left_leg), ("right", pose.right_leg)):
            if component_count(set(leg)) != 1:
                raise AssertionError(f"M2 F{index} {label} leg is not a single 8-connected chain")
            if not touches_mask_8(leg, core):
                raise AssertionError(f"M2 F{index} {label} leg detached from box")
        if not any(y == 27 for _, y in pose.left_leg | pose.right_leg):
            raise AssertionError(f"M2 F{index} has no planted support foot")
        expected_stick = IDLE_STICK_DOWN_1 if offset else IDLE_STICK
        if stick != expected_stick:
            raise AssertionError(f"M2 F{index} stick must follow body vertically and never drift in X")
    if max(y for _, y in M2_LIMBS[2].left_leg) != 26 or not any(y == 27 for _, y in M2_LIMBS[2].right_leg):
        raise AssertionError("M2 F2 must show a lifted left swing foot and planted right support foot")
    if max(y for _, y in M2_LIMBS[6].right_leg) != 26 or not any(y == 27 for _, y in M2_LIMBS[6].left_leg):
        raise AssertionError("M2 F6 must show a lifted right swing foot and planted left support foot")
    if max(y for _, y in M2_LIMBS[3].left_leg) != 26 or max(y for _, y in M2_LIMBS[7].right_leg) != 26:
        raise AssertionError("M2 up phases must keep the advancing swing foot visibly off the floor")


def audit_frame(image: Image.Image, key: str, index: int) -> dict[str,object]:
    if image.size != (FRAME,FRAME) or image.mode != "RGBA":
        raise AssertionError(f"{key}[{index}] geometry/mode drifted")
    colors = set(image.getdata())
    if not colors <= PALETTE:
        raise AssertionError(f"{key}[{index}] off-palette colors: {colors-PALETTE}")
    if any(pixel[3] not in (0,255) for pixel in image.getdata()):
        raise AssertionError(f"{key}[{index}] non-binary alpha")
    if any(pixel[:3] != (0,0,0) for pixel in image.getdata() if pixel[3] == 0):
        raise AssertionError(f"{key}[{index}] transparent RGB not zero")
    bbox = image.getbbox()
    if bbox is None:
        raise AssertionError(f"{key}[{index}] empty")
    width,height = bbox[2]-bbox[0],bbox[3]-bbox[1]
    limit = (24,23) if key.startswith("m") else (28,24)
    if width > limit[0] or height > limit[1] or bbox[3] != 28:
        raise AssertionError(f"{key}[{index}] bbox contract failed: {bbox} limit={limit}")
    points = opaque_points(image)
    components = component_count(points)
    if components != 1:
        raise AssertionError(f"{key}[{index}] disconnected components={components}")
    if key[0] in ("m", "a") and any(image.getpixel((x,y)) in (EYE_DARK,DEEP_BROWN,PAPER_EDGE) for y in range(20,24) for x in range(11,20)):
        raise AssertionError(f"{key}[{index}] mouth-like dark mark in central lower face")
    return {"bbox":list(bbox),"opaque":len(points),"components_8":components,"rgba_sha256":rgba_sha(image)}


def composite_16x(frame: Image.Image, mirrored: bool = False) -> Image.Image:
    native = ImageOps.mirror(frame) if mirrored else frame
    canvas = Image.new("RGBA", native.size, BACKGROUND)
    canvas.alpha_composite(native)
    return canvas.resize((FRAME*16,FRAME*16), Image.Resampling.NEAREST).convert("RGB")


def save_gif(frames: list[Image.Image], path: Path, durations: list[int], mirrored: bool) -> None:
    ensure_dev(path)
    rendered = [composite_16x(frame, mirrored) for frame in frames]
    quantized = [frame.quantize(colors=16, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE) for frame in rendered]
    quantized[0].save(path, save_all=True, append_images=quantized[1:], duration=durations, loop=0, optimize=False, disposal=2)
    with Image.open(path) as opened:
        decoded = [frame.convert("RGB") for frame in ImageSequence.Iterator(opened)]
        actual_durations = [frame.info.get("duration") for frame in ImageSequence.Iterator(opened)]
    if len(decoded) != COUNT or actual_durations != durations:
        raise AssertionError(f"GIF timing drift: {path.name} {actual_durations}")
    for index,(actual,expected) in enumerate(zip(decoded,rendered)):
        if actual.tobytes() != expected.tobytes():
            raise AssertionError(f"GIF palette drift: {path.name}[{index}]")


def strip(frames: list[Image.Image]) -> Image.Image:
    output = Image.new("RGBA", (FRAME*COUNT,FRAME), TRANSPARENT)
    for index,frame in enumerate(frames):
        output.alpha_composite(frame,(index*FRAME,0))
    return output


def delta_strip(frames: list[Image.Image], anchor: Image.Image) -> Image.Image:
    output = Image.new("RGBA", (FRAME*COUNT,FRAME), TRANSPARENT)
    for index,frame in enumerate(frames):
        for y in range(FRAME):
            for x in range(FRAME):
                current = frame.getpixel((x,y))
                if current != anchor.getpixel((x,y)):
                    output.putpixel((index*FRAME+x,y), current if current[3] else (232,86,76,255))
    return output


def font(size: int) -> ImageFont.ImageFont:
    for candidate in (Path("C:/Windows/Fonts/msyh.ttc"),Path("C:/Windows/Fonts/simhei.ttf")):
        if candidate.is_file():
            return ImageFont.truetype(str(candidate),size)
    return ImageFont.load_default()


def review_panel(key: str, frames: list[Image.Image], reference: Image.Image) -> Image.Image:
    panel = Image.new("RGBA",(1600,760),(23,33,46,255))
    draw = ImageDraw.Draw(panel)
    draw.text((30,22),f"{SPECS[key]['title']} · ImageGen仅作结构参考",font=font(30),fill=(238,238,232,255))
    ref = reference.copy()
    ref.thumbnail((510,510),Image.Resampling.LANCZOS)
    panel.alpha_composite(ref,((540-ref.width)//2+20,100))
    native = strip(frames).resize((1024,128),Image.Resampling.NEAREST)
    panel.alpha_composite(native,(550,160))
    draw.text((550,310),"确定性 native 8帧（仅显式像素表）",font=font(22),fill=(170,181,185,255))
    sample = composite_16x(frames[0]).resize((320,320),Image.Resampling.NEAREST).convert("RGBA")
    panel.alpha_composite(sample,(780,380))
    draw.text((550,700),"32×32 · 二值Alpha · 平面亮顶缘 · 单纸棒",font=font(20),fill=(170,181,185,255))
    return panel


def file_record(path: Path) -> dict[str,object]:
    record: dict[str,object] = {"path":rel(path),"sha256":sha256(path)}
    if path.suffix.lower() in (".png",".gif"):
        with Image.open(path) as image:
            record["size"] = list(image.size)
            record["mode"] = image.mode
            if path.suffix.lower() == ".gif":
                record["frames"] = getattr(image,"n_frames",1)
    return record


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build preview-only cardboard-monster animation candidates and certificates."
    )
    parser.add_argument(
        "--approve",
        nargs=3,
        metavar=("MOVE", "ATTACK", "DEATH"),
        help="Record the explicit second-gate choice; only 'm2 a2 d2' is approvable.",
    )
    args = parser.parse_args()
    if args.approve is not None:
        requested = dict(zip(("move", "attack", "death"), args.approve))
        for category, candidate in requested.items():
            if candidate not in APPROVAL_ENUMS[category]:
                parser.error(
                    f"invalid {category} candidate {candidate!r}; "
                    f"expected one of {APPROVAL_ENUMS[category]}"
                )
        if requested != APPROVED_ANIMATION_SELECTION:
            parser.error(
                "this frozen human gate only accepts the exact combination "
                "'--approve m2 a2 d2'"
            )
        args.approve = requested
    return args


def verify_selected_candidate_files() -> None:
    for key, lock in APPROVED_SELECTED_LOCKS.items():
        path = SOURCE_DIR / f"cardboard_monster_{SPECS[key]['name']}_candidate_native.png"
        if sha256(path) != lock["native_png_sha256"]:
            raise AssertionError(f"Approved {key} native PNG drifted before certification")
        with Image.open(path) as opened:
            decoded = opened.convert("RGBA")
        if rgba_sha(decoded) != lock["native_rgba_sha256"]:
            raise AssertionError(f"Approved {key} decoded RGBA drifted before certification")


def verify_pending_second_gate_certificate() -> None:
    locked_paths = {
        "report_sha256": REPORT_PATH,
        "manifest_sha256": ANIMATION_MANIFEST,
        "stability_sha256": STABILITY_PATH,
    }
    for lock_key, path in locked_paths.items():
        actual = sha256(path)
        expected = PENDING_SECOND_GATE_CERTIFICATE[lock_key]
        if actual != expected:
            raise AssertionError(
                f"Pending second-gate certificate drifted: {rel(path)} "
                f"expected={expected} actual={actual}"
            )
    pending_report = json.loads(REPORT_PATH.read_text(encoding="utf-8"))
    pending_manifest = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    pending_stability = json.loads(STABILITY_PATH.read_text(encoding="utf-8"))
    for payload, label in (
        (pending_report, "report"),
        (pending_manifest, "manifest"),
        (pending_stability, "stability"),
    ):
        if payload.get("stage") != PENDING_SECOND_GATE_CERTIFICATE["stage"]:
            raise AssertionError(f"Pending {label} stage drifted")
        if payload.get("runtime_written") is not False:
            raise AssertionError(f"Pending {label} unexpectedly claims runtime output")
        builder_sha = (
            payload.get("builder", {}).get("sha256")
            if label != "stability"
            else payload.get("builder_sha256")
        )
        if builder_sha != PENDING_SECOND_GATE_CERTIFICATE["builder_sha256"]:
            raise AssertionError(f"Pending {label} builder certificate drifted")
    if pending_report.get("approved_animation_selection") is not None:
        raise AssertionError("Pending report unexpectedly contains an approved selection")
    if pending_manifest.get("approved_animation_selection") is not None:
        raise AssertionError("Pending manifest unexpectedly contains an approved selection")


def validate_persisted_approval() -> bool:
    manifest = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    claims_approval = manifest.get("second_human_approved") is True
    if not claims_approval:
        if manifest.get("stage") == "second_human_gate_approved":
            raise AssertionError("Manifest stage claims approval without approval boolean")
        if manifest.get("approved_animation_selection") is not None:
            raise AssertionError("Unapproved manifest contains an animation selection")
        return False
    report = json.loads(REPORT_PATH.read_text(encoding="utf-8"))
    stability = json.loads(STABILITY_PATH.read_text(encoding="utf-8"))
    for payload, label in ((manifest, "manifest"), (report, "report"), (stability, "stability")):
        if payload.get("stage") != "second_human_gate_approved":
            raise AssertionError(f"Persisted approved {label} stage drifted")
        if payload.get("approved_animation_selection") != APPROVED_ANIMATION_SELECTION:
            raise AssertionError(f"Persisted approved {label} selection drifted")
        if payload.get("second_human_approved") is not True:
            raise AssertionError(f"Persisted approved {label} boolean drifted")
        if payload.get("final_human_approved") is not False:
            raise AssertionError(f"Persisted approved {label} unexpectedly claims final approval")
        if payload.get("runtime_written") is not False:
            raise AssertionError(f"Persisted approved {label} unexpectedly claims runtime output")
        if payload.get("approval_basis") != PENDING_SECOND_GATE_CERTIFICATE:
            raise AssertionError(f"Persisted approved {label} basis drifted")
        if payload.get("approved_selected_locks") != APPROVED_SELECTED_LOCKS:
            raise AssertionError(f"Persisted approved {label} selected locks drifted")
    verify_selected_candidate_files()
    return True


def resolve_second_gate_approval(requested: dict[str,str] | None) -> bool:
    persisted = validate_persisted_approval()
    if requested is None:
        return persisted
    if requested != APPROVED_ANIMATION_SELECTION:
        raise AssertionError("Approval selection reached builder without strict CLI validation")
    if not persisted:
        verify_pending_second_gate_certificate()
        verify_selected_candidate_files()
    return True


def verify_inputs() -> dict[str,object]:
    records: dict[str,object] = {}
    for path,expected in EXPECTED.items():
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Locked input drifted: {rel(path)} expected={expected} actual={actual}")
        records[rel(path)] = {"sha256":actual,"locked":True}
    manifest = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("approved_selection") != "f2" or manifest.get("first_human_approved") is not True:
        raise AssertionError("Approved F2 anchor certificate missing")
    if manifest.get("runtime_written") is not False:
        raise AssertionError("Anchor unexpectedly claims runtime output")
    for key,path in RAW_FILES.items():
        expected = EXPECTED_RAW_SHA[key]
        if expected == "PENDING":
            raise AssertionError(f"Raw SHA for {key} has not been frozen")
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"ImageGen raw drifted: {key} expected={expected} actual={actual}")
        records[rel(path)] = {"sha256":actual,"locked":True,"pixels_imported_into_native":False}
    return records


def build_reference(key: str) -> tuple[Image.Image,dict[str,object]]:
    with Image.open(RAW_FILES[key]) as opened:
        normalized = normalize_source(opened)
    cropped = crop_to_square(normalized,padding=12,align_to_grid=False)
    transparent_path = PREVIEW_DIR / f"cardboard_monster_{SPECS[key]['name']}_reference_transparent.png"
    save_png(cropped,transparent_path)
    analysis = analyze_image(cropped)
    analysis["unsafe_for_direct_resize"] = True
    analysis["imagegen_pixels_imported_into_native"] = False
    return cropped,{"transparent_reference":file_record(transparent_path),"grid_analysis":analysis}


def write_outputs(built: dict[str,list[Image.Image]], anchor: Image.Image) -> tuple[dict[str,object],list[Path]]:
    records: dict[str,object] = {}
    outputs: list[Path] = []
    for key,frames in built.items():
        spec = SPECS[key]
        native_path = SOURCE_DIR / f"cardboard_monster_{spec['name']}_candidate_native.png"
        zoom_path = PREVIEW_DIR / f"cardboard_monster_{spec['name']}_candidate_8x.png"
        delta_path = PREVIEW_DIR / f"cardboard_monster_{spec['name']}_ordinary_delta_8x.png"
        gif_path = PREVIEW_DIR / f"cardboard_monster_{spec['name']}_candidate.gif"
        mirror_path = PREVIEW_DIR / f"cardboard_monster_{spec['name']}_candidate_mirror.gif"
        panel_path = PREVIEW_DIR / f"cardboard_monster_{spec['name']}_review_panel.png"
        native = strip(frames)
        save_png(native,native_path)
        save_png(native.resize((native.width*8,native.height*8),Image.Resampling.NEAREST),zoom_path)
        delta = delta_strip(frames,anchor)
        save_png(delta.resize((delta.width*8,delta.height*8),Image.Resampling.NEAREST),delta_path)
        save_gif(frames,gif_path,list(spec["durations"]),False)
        save_gif(frames,mirror_path,list(spec["durations"]),True)
        reference,reference_record = build_reference(key)
        save_png(review_panel(key,frames,reference),panel_path)
        paths = [native_path,zoom_path,delta_path,gif_path,mirror_path,panel_path,Path(ROOT / reference_record["transparent_reference"]["path"])]
        outputs.extend(paths)
        records[key] = {
            "title":spec["title"],"author_fps":spec["author_fps"],"gif_durations_ms":spec["durations"],
            "native_rgba_sha256":rgba_sha(native),
            "frame_audit":[audit_frame(frame,key,index) for index,frame in enumerate(frames)],
            "outputs":[file_record(path) for path in paths[:-1]],
            **reference_record,
        }
        if key == "m2":
            records[key]["gait_contract"] = {
                "revision": "contact_down_pass_up_with_alternating_support",
                "phases": list(M2_GAIT_PHASES),
                "body_y_offsets": list(M2_CORE_OFFSETS),
                "left_swing_off_floor_frames": [2, 3],
                "right_swing_off_floor_frames": [6, 7],
                "support_floor_y": 27,
                "swing_floor_y": 26,
                "horizontal_body_or_stick_drift": 0,
            }
    return records,outputs


def snapshot(paths: list[Path]) -> dict[str,str]:
    return {rel(path):sha256(path) for path in sorted(set(paths),key=lambda p:rel(p))}


def audit_locked_draft_outputs(records: dict[str,object]) -> None:
    for key, lock in (("a2", SELECTED_FIXED_LOCKS["attack_a2"]), ("d2", SELECTED_FIXED_LOCKS["death_d2"])):
        record = records[key]
        if record["outputs"][0]["sha256"] != lock["native_png_sha256"]:
            raise AssertionError(f"{key} changed after the user's draft selection")
        if record["native_rgba_sha256"] != lock["native_rgba_sha256"]:
            raise AssertionError(f"{key} decoded RGBA changed after the user's draft selection")
    m2_record = records["m2"]
    if m2_record["outputs"][0]["sha256"] == SUPERSEDED_M2_LOCK["native_png_sha256"]:
        raise AssertionError("Refined M2 still matches the superseded non-walking candidate")
    if m2_record["native_rgba_sha256"] == SUPERSEDED_M2_LOCK["native_rgba_sha256"]:
        raise AssertionError("Refined M2 decoded RGBA still matches the superseded candidate")


def audit_approved_selected_outputs(records: dict[str,object]) -> None:
    for key, lock in APPROVED_SELECTED_LOCKS.items():
        record = records[key]
        if record["outputs"][0]["sha256"] != lock["native_png_sha256"]:
            raise AssertionError(f"Approved {key} native PNG changed during rebuild")
        if record["native_rgba_sha256"] != lock["native_rgba_sha256"]:
            raise AssertionError(f"Approved {key} decoded RGBA changed during rebuild")


def main() -> None:
    args = parse_args()
    second_human_approved = resolve_second_gate_approval(args.approve)
    stage = (
        "second_human_gate_approved"
        if second_human_approved
        else "animation_candidates_pending_second_human_gate"
    )
    approved_selection = (
        dict(APPROVED_ANIMATION_SELECTION) if second_human_approved else None
    )
    input_records = verify_inputs()
    audit_m2_gait()
    with Image.open(ANCHOR) as opened:
        anchor = opened.convert("RGBA")
    built_first = build_all()
    for key in SPECS:
        if rgba_sha(built_first[key][0]) != rgba_sha(anchor):
            raise AssertionError(f"{key} frame0 must be byte-identical to the approved refined F2 anchor")
    for key,frames in built_first.items():
        if len(frames) != COUNT:
            raise AssertionError(f"{key} frame count drifted")
        if len({rgba_sha(frame) for frame in frames}) != COUNT:
            raise AssertionError(f"{key} must contain eight unique authored frames")
        for index,frame in enumerate(frames):
            audit_frame(frame,key,index)
    records_first,outputs = write_outputs(built_first,anchor)
    audit_locked_draft_outputs(records_first)
    audit_approved_selected_outputs(records_first)
    first_snapshot = snapshot(outputs)
    built_second = build_all()
    records_second,outputs_second = write_outputs(built_second,anchor)
    audit_locked_draft_outputs(records_second)
    audit_approved_selected_outputs(records_second)
    second_snapshot = snapshot(outputs_second)
    drift = sorted(path for path in first_snapshot if first_snapshot[path] != second_snapshot.get(path))
    if drift or set(first_snapshot) != set(second_snapshot):
        raise AssertionError(f"Animation preview determinism drift: {drift}")
    if json.dumps(records_first,sort_keys=True,ensure_ascii=False) != json.dumps(records_second,sort_keys=True,ensure_ascii=False):
        raise AssertionError("Animation report records drifted across two builds")
    stability = {
        "asset":"cardboard_monster","stage":stage,
        "approved_animation_selection":approved_selection,
        "second_human_approved":second_human_approved,
        "final_human_approved":False,
        "approval_basis":PENDING_SECOND_GATE_CERTIFICATE,
        "approved_selected_locks":APPROVED_SELECTED_LOCKS,
        "passes":2,"drift_count":0,"drift_paths":[],"snapshot_1":first_snapshot,"snapshot_2":second_snapshot,
        "builder_sha256":sha256(SCRIPT),"runtime_written":False,
    }
    write_json(STABILITY_PATH,stability)
    report = {
        "asset":"cardboard_monster","stage":stage,
        "approved_anchor":"f2","anchor_revision":"flat_bright_top_edge_and_diagonal_paper_stick",
        "first_human_approved":True,"approved_animation_selection":approved_selection,
        "second_human_approved":second_human_approved,
        "final_human_approved":False,"runtime_written":False,"runtime_paths_written":[],
        "approval_basis":PENDING_SECOND_GATE_CERTIFICATE,
        "approved_selected_locks":APPROVED_SELECTED_LOCKS,
        "second_gate_draft_selection":SECOND_GATE_DRAFT_SELECTION,
        "selected_fixed_locks":SELECTED_FIXED_LOCKS,"superseded_m2_lock":SUPERSEDED_M2_LOCK,
        "imagegen_pixels_imported":False,"builder":{"path":rel(SCRIPT),"sha256":sha256(SCRIPT)},
        "inputs":input_records,"candidates":records_first,
        "stability":{"path":rel(STABILITY_PATH),"sha256":sha256(STABILITY_PATH),"passes":2,"drift_count":0},
        "contracts":{
            "frame_size":[32,32],"frame_count":8,"center_x":16,"baseline_bottom_exclusive":28,
            "flat_top_silhouette":True,"bright_top_lighting_band":True,"visible_top_plane":False,
            "stick_runtime_rotation":False,"stick_explicit_frame_tables":True,
            "windup_frames":3,"slash_frames":5,"slash_damage_frame_within_slash":1,
        },
    }
    write_json(REPORT_PATH,report)
    manifest = {
        "asset":"cardboard_monster","stage":stage,
        "approved_anchor":"f2","first_human_approved":True,
        "approved_animation_selection":approved_selection,
        "second_human_approved":second_human_approved,
        "final_human_approved":False,"runtime_written":False,
        "runtime_paths_written":[],"imagegen_pixels_imported":False,
        "approval_basis":PENDING_SECOND_GATE_CERTIFICATE,
        "approved_selected_locks":APPROVED_SELECTED_LOCKS,
        "second_gate_draft_selection":SECOND_GATE_DRAFT_SELECTION,
        "selected_fixed_locks":SELECTED_FIXED_LOCKS,"superseded_m2_lock":SUPERSEDED_M2_LOCK,
        "builder":{"path":rel(SCRIPT),"sha256":sha256(SCRIPT)},
        "report":{"path":rel(REPORT_PATH),"sha256":sha256(REPORT_PATH)},
        "stability":{"path":rel(STABILITY_PATH),"sha256":sha256(STABILITY_PATH)},
        "raw_sha256":EXPECTED_RAW_SHA,
        "candidate_native_locks":{key:{"path":records_first[key]["outputs"][0]["path"],"sha256":records_first[key]["outputs"][0]["sha256"],"rgba_sha256":records_first[key]["native_rgba_sha256"]} for key in SPECS},
    }
    write_json(ANIMATION_MANIFEST,manifest)
    print("CARDBOARD_MONSTER_ANIMATION_PREVIEWS_OK")
    print(f"report={rel(REPORT_PATH)} sha256={sha256(REPORT_PATH)}")
    print(f"manifest={rel(ANIMATION_MANIFEST)} sha256={sha256(ANIMATION_MANIFEST)}")
    print(f"stability={rel(STABILITY_PATH)} sha256={sha256(STABILITY_PATH)}")


if __name__ == "__main__":
    main()
