#!/usr/bin/env python3
"""Build preview-only M/A/D animation candidates for the large cardboard monster.

The six ImageGen sheets are structural references only.  Every native 48px
frame is authored from the approved L1 anchor, a fixed palette, and explicit
per-frame masks.  The builder refuses outputs outside dev-only paths.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageSequence

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets/source_images/cardboard_monster_large"
PREVIEW_DIR = ROOT / "dev_assets/generated_previews"
ANCHOR = SOURCE_DIR / "cardboard_monster_large_anchor_approved_native48.png"
ANCHOR_REPORT = enemy_asset_report_path("cardboard_monster_large_anchor_report.json")
ANCHOR_MANIFEST = enemy_asset_report_path("cardboard_monster_large_anchor_manifest.json")
ANCHOR_STABILITY = enemy_asset_report_path("cardboard_monster_large_anchor_stability.json")
REPORT_PATH = enemy_asset_report_path("cardboard_monster_large_animation_preview_report.json")
MANIFEST_PATH = enemy_asset_report_path("cardboard_monster_large_animation_manifest.json")
STABILITY_PATH = enemy_asset_report_path("cardboard_monster_large_animation_stability.json")

FRAME = 48
COUNT = 8
CENTER_X = 24
BASELINE_BOTTOM = 36
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
PAPER_SWORD = (225, 202, 159, 255)
EYE_DARK = (79, 67, 59, 255)
PALETTE = frozenset((TRANSPARENT, OUTLINE, DEEP_BROWN, LIMB_BROWN, KRAFT_DARK,
                     KRAFT_MID, KRAFT_LIGHT, FOLD_HIGHLIGHT, PAPER_EDGE,
                     PAPER_SWORD, EYE_DARK))

EXPECTED = {
    ANCHOR: "9e4422e1090ea35e97824b694a11335ef600e26d9b6a6a8a135af52e7e255529",
    ANCHOR_REPORT: "abb43ace23a6eb53a6e1918b3e4237bb6fa5b9249ed49cabe19099ff254da953",
    ANCHOR_MANIFEST: "d6bf52039ca8fc7e0bc04f110190a261958fe7fa1b05b85de8d5245f577658f5",
    ANCHOR_STABILITY: "0ef7cf3550c0231ea6262e47c3030dc62a8a984c1b428517a436be7099eb1705",
}
ANCHOR_RGBA_SHA256 = "10591c058dfd3461973c1399e082af43fdbc1a29697cb282cbba3dcaf6cc9c3a"

RAW_FILES = {
    "m1": SOURCE_DIR / "cardboard_monster_large_move_m1_imagegen.png",
    "m2": SOURCE_DIR / "cardboard_monster_large_move_m2_imagegen.png",
    "a1": SOURCE_DIR / "cardboard_monster_large_attack_a1_imagegen.png",
    "a2": SOURCE_DIR / "cardboard_monster_large_attack_a2_imagegen.png",
    "d1": SOURCE_DIR / "cardboard_monster_large_death_d1_imagegen.png",
    "d2": SOURCE_DIR / "cardboard_monster_large_death_d2_imagegen.png",
}
EXPECTED_RAW_SHA = {
    "m1": "4520db29c3c143226acd056f32e6220f8bcc8c9e826af980b06ac6e673ab0e5e",
    "m2": "f3b9a4e9dd163a9df927cadbc7302fe05f34b4666c2f750f37bd240c31dcb0ec",
    "a1": "b747f55f2102f720a30434ea2cf812ec5a19081e4b94433ca87be9a0a14c0b0e",
    "a2": "0a660ce590bd45659c7d345d9e9164bf349772b55df5809564bd12a02b916946",
    "d1": "9d7643f685f85bc9dabf63385764fc55c86a07478279a76d2e2fa43e8c232566",
    "d2": "7f408de8a0be3e044d4075b8de1d0eaed913ffb355175530dec02a70c720a3d1",
}

SPECS = {
    "m1": {"name": "move_m1", "title": "M1 重步换脚", "kind": "move", "author_fps": 9, "durations": [110] * 8},
    "m2": {"name": "move_m2", "title": "M2 慢速蹒跚", "kind": "move", "author_fps": 8, "durations": [120] * 8},
    "a1": {"name": "attack_a1", "title": "A1 前景斜下重挥", "kind": "attack", "author_fps": [9, 15], "durations": [110] * 3 + [70] * 5},
    "a2": {"name": "attack_a2", "title": "A2 前景短横扫", "kind": "attack", "author_fps": [9, 15], "durations": [110] * 3 + [70] * 5},
    "d1": {"name": "death_d1", "title": "D1 连剑侧倒", "kind": "death", "author_fps": 9, "durations": [110] * 8},
    "d2": {"name": "death_d2", "title": "D2 连剑压扁折叠", "kind": "death", "author_fps": 8, "durations": [120] * 8},
}

APPROVAL_ENUMS = {
    "move": ("m1", "m2"),
    "attack": ("a1", "a2"),
    "death": ("d1", "d2"),
}
APPROVED_ANIMATION_SELECTION = {
    "move": "m1",
    "attack": "a1",
    "death": "d2",
}
# This is the immutable, independently audited second-gate candidate certificate
# that existed immediately before approval support was added.  Approval is only
# allowed when these exact pending files are still present.
PENDING_SECOND_GATE_CERTIFICATE = {
    "stage": "animation_candidates_pending_second_human_gate",
    "builder_sha256": "5fc6e5ffe244f6a620a1cb61282d075f7381d59f3ca0194e6cb1013c66437928",
    "report_sha256": "20dfd050b8d992578d9e1c99a249a26a03a5ee96a90225a32a6f24e0a897455b",
    "manifest_sha256": "913b3365ea05b33ecc96cc6a5271ca6fc9ace1337df204b03240d31f624fa6c8",
    "stability_sha256": "22400538aff3b2ce73838f331b81d3b22fb8224b402bcf065e9f3572a6ebb40e",
    "approved_anchor": "l1",
    "anchor_rgba_sha256": ANCHOR_RGBA_SHA256,
    "coordinate_table_sha256": "912ada2e394c171f5dc487ecfd6719f0c9fcd845a06d7795a6970c7d6a862690",
}
ALL_CANDIDATE_NATIVE_LOCKS = {
    "m1": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_move_m1_candidate_native.png",
        "sha256": "1509a178104e40422ca4b53b00d89a97bee2fbfbf01138a304ce9e835042f03d",
        "rgba_sha256": "f765ca2aa317d789cb90c2251ace81f3f9d36ef1fffa91ef068760445b7ebbdc",
    },
    "m2": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_move_m2_candidate_native.png",
        "sha256": "39368066bdafcd57ad693d5c9190e0690f418443f6ab2a248eb24a0fec57db89",
        "rgba_sha256": "6744a237dc95333db3c4dd905064dee9bc833964528223ac8008a5b13d8676e7",
    },
    "a1": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_attack_a1_candidate_native.png",
        "sha256": "b2d2514bd632eb19fd260855dd4dec3278ed977e56fa8bcfa5892f486690fd88",
        "rgba_sha256": "ca101c63d033bc28aa81c927ef63390ed8ebc7dd6d9fdf95f3c0293c5352ef7e",
    },
    "a2": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_attack_a2_candidate_native.png",
        "sha256": "4e8d5a1513ed8f70313cb7c6b77ec3989c0618113ae3bc4546d73d81f68a11ae",
        "rgba_sha256": "c213ad6d0268f7253b1884b8a5ef6068750900a96edfeebdbd905be965a9d055",
    },
    "d1": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_death_d1_candidate_native.png",
        "sha256": "e00e162b4b3e50d70e071306ca5213dabff582626a6e7347244bea91c42cbbbf",
        "rgba_sha256": "0ffd92998e5c3c1d9c72ededdd26e7c3f6fed81e017b94e55adf6eee261d2d40",
    },
    "d2": {
        "path": "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_death_d2_candidate_native.png",
        "sha256": "de4e3c39746b8743a21b99cd091102ab75fffc8188f9ecc029c896e1a728e4f1",
        "rgba_sha256": "1973382d0e5ad008d1ec2975e0faf1f53c084978a4fff2c7c3cd358f8b6bb8e9",
    },
}
APPROVED_SELECTED_LOCKS = {
    category: dict(ALL_CANDIDATE_NATIVE_LOCKS[candidate])
    for category, candidate in APPROVED_ANIMATION_SELECTION.items()
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
class SwordPose:
    mask: frozenset[Point]
    core: frozenset[Point]
    endpoints: tuple[Point, Point]


@dataclass
class BuiltFrame:
    image: Image.Image
    body: set[Point]
    limbs: LimbPose
    sword: SwordPose
    eyes: set[Point]


def fs(*points: Point) -> frozenset[Point]:
    return frozenset(points)


def rows(rowspec: dict[int, tuple[int, int]]) -> frozenset[Point]:
    return frozenset((x, y) for y, (left, right) in rowspec.items() for x in range(left, right + 1))


def sword(rowspec: dict[int, tuple[int, int]], core: tuple[Point, ...], endpoints: tuple[Point, Point]) -> SwordPose:
    return SwordPose(rows(rowspec), fs(*core), endpoints)


IDLE_SWORD_BASE_MASK = rows(
    {14:(45,45),15:(44,45),16:(43,45),17:(42,44),18:(41,43),19:(40,42),
     20:(39,41),21:(38,40),22:(37,39),23:(34,38),24:(34,37),25:(34,37)}
)
IDLE_SWORD_GUARD_MASK = fs(
    (33,22),(34,22),
    (33,23),(34,23),(35,23),
    (34,24),(35,24),(36,24),
    (35,25),(36,25),(37,25),
    (36,26),(37,26),(38,26),
)
IDLE_SWORD = SwordPose(
    IDLE_SWORD_BASE_MASK | IDLE_SWORD_GUARD_MASK,
    fs((45,15),(44,16),(43,17),(42,18),(41,19),(40,20),(39,21),(38,22),
       (37,23),(36,24),(34,23),(36,25),(37,26)),
    ((35,24),(45,14)),
)


def shift_sword(source: SwordPose, dx: int, dy: int) -> SwordPose:
    return SwordPose(
        frozenset((x + dx, y + dy) for x, y in source.mask),
        frozenset((x + dx, y + dy) for x, y in source.core),
        tuple((x + dx, y + dy) for x, y in source.endpoints),
    )


IDLE_SWORD_DOWN = shift_sword(IDLE_SWORD, 0, 1)
IDLE_SWORD_UP = shift_sword(IDLE_SWORD, 0, -1)

STEEP_SWORD = sword(
    {9:(40,40),10:(39,40),11:(39,41),12:(38,40),13:(38,40),14:(37,39),
     15:(37,39),16:(36,38),17:(36,38),18:(35,37),19:(35,37),20:(34,36),
     21:(34,36),22:(32,38),23:(32,38),24:(33,37),25:(34,37)},
    ((40,10),(40,11),(39,12),(39,13),(38,14),(38,15),(37,16),(37,17),
     (36,18),(36,19),(35,20),(35,21),(34,22),(33,23),(36,23)), ((35,24),(40,9)))
VERTICAL_SWORD = sword(
    {9:(35,35),10:(34,36),11:(34,36),12:(34,36),13:(34,36),14:(34,36),
     15:(34,36),16:(34,36),17:(34,36),18:(34,36),19:(34,36),20:(34,36),
     21:(34,36),22:(31,39),23:(31,39),24:(31,39),25:(34,36)},
    tuple((35,y) for y in range(10,22)) + ((32,23),(33,23),(37,23),(38,23)), ((35,24),(35,9)))
MID_SWORD = sword(
    {16:(47,47),17:(46,47),18:(44,47),19:(42,46),20:(40,44),21:(38,42),
     22:(32,40),23:(32,38),24:(32,37),25:(33,36),26:(34,36)},
    ((47,17),(46,18),(44,19),(43,19),(42,20),(41,20),(40,21),(39,21),
     (38,22),(37,22),(34,23),(35,24),(35,25)), ((33,24),(47,17)))
HORIZONTAL_SWORD = sword(
    {20:(32,34),21:(32,34),22:(32,35),23:(33,45),24:(33,47),25:(33,45),
     26:(32,35),27:(32,34),28:(32,34)},
    tuple((x,24) for x in range(34,47)) + ((33,21),(33,22),(33,26),(33,27)), ((33,24),(47,24)))
DOWN_SWORD = sword(
    {22:(32,36),23:(32,37),24:(33,38),25:(34,40),26:(36,42),27:(38,44),
     28:(40,46),29:(42,47),30:(44,47),31:(47,47),32:(47,47)},
    ((33,23),(34,24),(36,25),(37,26),(39,27),(40,28),(42,29),(44,30),(47,31)), ((34,23),(47,31)))
RETURN_SWORD = sword(
    {15:(46,46),16:(45,46),17:(43,46),18:(42,44),19:(40,43),20:(38,41),
     21:(36,39),22:(33,38),23:(33,37),24:(33,37),25:(34,36),26:(35,37)},
    ((46,16),(45,17),(44,18),(42,19),(41,20),(39,21),(38,22),(36,23),(35,24),(36,25)), ((34,24),(46,16)))

BASE_LIMBS = LimbPose(
    fs((13,24),(12,24),(11,25),(10,25),(10,26),(11,26)),
    fs((34,24),(35,24),(35,25),(36,25)),
    fs((19,31),(19,32),(18,33),(18,34),(17,35),(18,35)),
    fs((28,31),(28,32),(29,33),(29,34),(30,35),(31,35)),
    fs((10,26),(11,26),(35,24),(35,25),(17,35),(18,35),(30,35),(31,35)))

M1_CORE_OFFSETS = (0, 1, 0, -1, 0, 1, 0, -1)
M1_SWORDS = (IDLE_SWORD, IDLE_SWORD_DOWN, IDLE_SWORD, IDLE_SWORD_UP,
             IDLE_SWORD, IDLE_SWORD_DOWN, IDLE_SWORD, IDLE_SWORD_UP)
M1_PHASES = ("contact", "down", "left_pass", "left_up", "opposite_contact", "down", "right_pass", "right_up")
M1_LIMBS = (
    BASE_LIMBS,
    LimbPose(fs((13,25),(12,25),(11,26),(10,26),(10,27)),fs((34,25),(35,25),(35,26),(36,26)),fs((19,32),(18,33),(17,34),(15,35),(16,35)),fs((28,32),(29,33),(30,34),(31,35),(32,35)),fs((10,27),(35,25),(35,26),(15,35),(16,35),(31,35),(32,35))),
    LimbPose(fs((13,23),(12,23),(11,24),(10,24),(10,25)),fs((34,24),(35,24),(35,25),(36,25)),fs((19,31),(20,32),(21,33),(22,34),(23,34)),fs((28,31),(28,32),(29,33),(30,34),(30,35),(31,35)),fs((10,25),(35,24),(35,25),(22,34),(23,34),(30,35),(31,35))),
    LimbPose(fs((13,21),(12,21),(11,22),(10,22),(10,23)),fs((34,23),(35,23),(35,24),(36,24)),fs((19,30),(20,31),(21,32),(22,33),(23,34)),fs((28,30),(28,31),(29,32),(30,33),(30,34),(31,35)),fs((10,23),(35,23),(35,24),(22,33),(23,34),(30,34),(31,35))),
    LimbPose(fs((13,24),(12,24),(11,25),(10,25)),fs((34,24),(35,24),(35,25),(36,25)),fs((19,31),(20,32),(22,33),(23,34),(24,35)),fs((28,31),(27,32),(26,33),(25,34),(25,35)),fs((10,25),(35,24),(35,25),(23,34),(24,35),(25,34),(25,35))),
    LimbPose(fs((13,25),(12,25),(11,26),(10,26),(10,27)),fs((34,25),(35,25),(35,26),(36,26)),fs((19,32),(20,33),(22,34),(23,35),(24,35)),fs((28,32),(27,33),(26,34),(25,35),(26,35)),fs((10,27),(35,25),(35,26),(23,35),(24,35),(25,35),(26,35))),
    LimbPose(fs((13,23),(12,23),(11,24),(10,24)),fs((34,24),(35,24),(35,25),(36,25)),fs((19,31),(19,32),(18,33),(17,34),(17,35),(18,35)),fs((28,31),(27,32),(26,33),(25,34),(24,34)),fs((10,24),(35,24),(35,25),(17,35),(18,35),(24,34),(25,34))),
    LimbPose(fs((13,21),(12,21),(11,22),(10,22)),fs((34,23),(35,23),(35,24),(36,24)),fs((19,30),(19,31),(18,32),(17,33),(17,34),(16,35)),fs((28,30),(27,31),(26,32),(25,33),(24,34)),fs((10,22),(35,23),(35,24),(17,34),(16,35),(25,33),(24,34))),
)

M2_CORE_OFFSETS = (0, 0, 1, 1, 0, 0, 1, 1)
M2_SWORDS = (IDLE_SWORD, IDLE_SWORD, IDLE_SWORD_DOWN, IDLE_SWORD_DOWN,
             IDLE_SWORD, IDLE_SWORD, IDLE_SWORD_DOWN, IDLE_SWORD_DOWN)
M2_PHASES = ("contact", "weight_right", "left_lift", "left_land", "opposite_contact", "weight_left", "right_lift", "right_land")
M2_LIMBS = (
    BASE_LIMBS,
    LimbPose(fs((13,23),(12,23),(11,24),(10,24),(10,25)),fs((34,24),(35,24),(35,25),(36,25)),fs((19,31),(19,32),(18,33),(17,34),(16,35),(17,35)),fs((28,31),(28,32),(29,33),(30,34),(31,35),(32,35)),fs((10,25),(35,24),(35,25),(16,35),(17,35),(31,35),(32,35))),
    LimbPose(fs((13,25),(12,25),(11,26),(10,26),(10,27)),fs((34,25),(35,25),(35,26),(36,26)),fs((19,32),(20,33),(21,34),(22,34)),fs((28,32),(29,33),(30,34),(31,35),(32,35)),fs((10,27),(35,25),(35,26),(21,34),(22,34),(31,35),(32,35))),
    LimbPose(fs((13,26),(12,26),(11,27),(10,27)),fs((34,25),(35,25),(35,26),(36,26)),fs((19,32),(20,33),(21,34),(22,35),(23,35)),fs((28,32),(29,33),(30,34),(31,35),(32,35)),fs((10,27),(35,25),(35,26),(22,35),(23,35),(31,35),(32,35))),
    LimbPose(fs((13,24),(12,24),(11,25),(10,25)),fs((34,24),(35,24),(35,25),(36,25)),fs((19,31),(20,32),(21,33),(22,34),(23,35)),fs((28,31),(27,32),(26,33),(25,34),(24,35)),fs((10,25),(35,24),(35,25),(23,35),(24,35))),
    LimbPose(fs((13,23),(12,23),(11,24),(10,24)),fs((34,24),(35,24),(35,25),(36,25)),fs((19,31),(20,32),(21,33),(22,34),(23,35),(24,35)),fs((28,31),(27,32),(26,33),(25,34),(24,35)),fs((10,24),(35,24),(35,25),(23,35),(24,35))),
    LimbPose(fs((13,25),(12,25),(11,26),(10,26),(10,27)),fs((34,25),(35,25),(35,26),(36,26)),fs((19,32),(18,33),(17,34),(16,35),(17,35)),fs((28,32),(27,33),(26,34),(25,34)),fs((10,27),(35,25),(35,26),(16,35),(17,35),(25,34),(26,34))),
    LimbPose(fs((13,26),(12,26),(11,27),(10,27)),fs((34,25),(35,25),(35,26),(36,26)),fs((19,32),(18,33),(17,34),(16,35),(17,35)),fs((28,32),(27,33),(26,34),(25,35),(24,35)),fs((10,27),(35,25),(35,26),(16,35),(17,35),(24,35),(25,35))),
)

ATTACK_BASE = BASE_LIMBS
ATTACK_LIFT = LimbPose(fs((13,24),(12,24),(11,25),(10,25),(10,26)),fs((34,23),(35,23),(35,24),(36,24)),BASE_LIMBS.left_leg,BASE_LIMBS.right_leg,fs((10,26),(35,23),(35,24),(17,35),(18,35),(30,35),(31,35)))
ATTACK_RECOIL = LimbPose(fs((12,23),(11,23),(10,24),(9,24),(9,25)),fs((33,24),(34,24),(34,25),(35,25)),fs((18,31),(18,32),(17,33),(17,34),(16,35),(17,35)),fs((27,31),(27,32),(28,33),(29,34),(30,35)),fs((9,25),(34,24),(34,25),(16,35),(17,35),(30,35)))
ATTACK_DOWN = LimbPose(fs((12,22),(11,22),(10,23),(9,23),(9,24)),fs((33,23),(34,23),(34,24),(35,24)),ATTACK_RECOIL.left_leg,ATTACK_RECOIL.right_leg,fs((9,24),(34,23),(34,24),(16,35),(17,35),(30,35)))
ATTACK_RECOVER = LimbPose(fs((13,23),(12,23),(11,24),(10,24),(10,25)),fs((34,24),(35,24),(35,25),(36,25)),BASE_LIMBS.left_leg,BASE_LIMBS.right_leg,fs((10,25),(35,24),(35,25),(17,35),(18,35),(30,35),(31,35)))
A1_CORE_X = (0,0,0,-1,-1,-1,-1,0)
A1_LIMBS = (ATTACK_BASE,ATTACK_LIFT,ATTACK_LIFT,ATTACK_RECOIL,ATTACK_RECOIL,ATTACK_DOWN,ATTACK_RECOIL,ATTACK_RECOVER)
A1_SWORDS = (IDLE_SWORD,STEEP_SWORD,VERTICAL_SWORD,STEEP_SWORD,MID_SWORD,DOWN_SWORD,RETURN_SWORD,IDLE_SWORD)
A2_CORE_X = (0,0,0,-1,-1,-1,-1,0)
A2_LIMBS = (ATTACK_BASE,ATTACK_LIFT,ATTACK_LIFT,ATTACK_RECOIL,ATTACK_RECOIL,ATTACK_RECOIL,ATTACK_RECOIL,ATTACK_RECOVER)
A2_SWORDS = (IDLE_SWORD,STEEP_SWORD,VERTICAL_SWORD,VERTICAL_SWORD,MID_SWORD,HORIZONTAL_SWORD,RETURN_SWORD,IDLE_SWORD)

D1_BODIES = (
    rows({y:(13,34) for y in range(13,32)}),
    rows({y:(14,35) for y in range(14,33)}),
    rows({16:(18,34),17:(17,35),**{y:(15,36) for y in range(18,34)}}),
    rows({18:(21,35),19:(19,37),20:(18,38),**{y:(16,38) for y in range(21,35)}}),
    rows({21:(22,37),22:(19,39),23:(17,40),**{y:(14,40) for y in range(24,36)}}),
    rows({24:(18,36),25:(15,39),26:(12,40),**{y:(10,41) for y in range(27,36)}}),
    rows({26:(16,36),27:(13,39),28:(10,41),**{y:(8,42) for y in range(29,36)}}),
    rows({28:(13,36),29:(10,39),30:(8,41),**{y:(7,42) for y in range(31,36)}}),
)
D2_BODIES = (
    D1_BODIES[0],
    rows({y:(13,34) for y in range(14,33)}),
    rows({y:(12,35) for y in range(16,34)}),
    rows({y:(11,36) for y in range(18,35)}),
    rows({21:(12,35),22:(10,37),**{y:(9,38) for y in range(23,36)}}),
    rows({24:(11,36),25:(8,39),**{y:(7,40) for y in range(26,36)}}),
    rows({27:(10,37),28:(7,40),**{y:(5,42) for y in range(29,36)}}),
    rows({29:(11,36),30:(7,40),**{y:(4,43) for y in range(31,36)}}),
)

D1_EYES = (
    fs((20,21),(20,22),(27,21),(27,22)), fs((21,22),(21,23),(28,22),(28,23)),
    fs((22,24),(22,25),(29,24),(29,25)), fs((23,26),(23,27),(30,26),(30,27)),
    fs((22,28),(22,29),(30,28),(30,29)), fs((19,29),(19,30),(28,29),(28,30)),
    fs((17,30),(17,31),(27,30),(27,31)), fs((15,31),(15,32),(25,31),(25,32)),
)
D2_EYES = (
    D1_EYES[0], fs((20,22),(20,23),(27,22),(27,23)), fs((20,24),(20,25),(27,24),(27,25)),
    fs((20,26),(20,27),(27,26),(27,27)), fs((19,28),(19,29),(28,28),(28,29)),
    fs((18,30),(18,31),(29,30),(29,31)), fs((16,32),(16,33),(31,32),(31,33)), fs(),
)

D1_LIMBS = (
    BASE_LIMBS,
    LimbPose(fs((14,25),(13,25),(12,26),(11,26)),fs((35,25),(36,25),(36,26),(37,26)),fs((20,32),(19,33),(18,34),(17,35)),fs((29,32),(30,33),(31,34),(32,35)),fs((11,26),(36,25),(36,26),(17,35),(32,35))),
    LimbPose(fs((15,26),(14,26),(13,27),(12,27)),fs((36,26),(37,26),(37,27),(38,27)),fs((21,33),(20,34),(19,35)),fs((30,33),(31,34),(32,35)),fs((12,27),(37,26),(37,27),(19,35),(32,35))),
    LimbPose(fs((16,27),(15,27),(14,28),(13,28)),fs((38,27),(39,27),(39,28)),fs((21,34),(20,35)),fs((31,34),(32,35)),fs((13,28),(39,27),(39,28),(20,35),(32,35))),
    LimbPose(fs((14,29),(13,29),(12,30),(11,30)),fs((40,29),(41,29),(41,30)),fs((18,34),(17,35)),fs((33,34),(34,35)),fs((11,30),(41,29),(41,30),(17,35),(34,35))),
    LimbPose(fs((10,30),(9,30),(8,31),(8,32)),fs((41,30),(42,30),(42,31)),fs((15,34),(14,35)),fs((34,34),(35,35)),fs((8,32),(42,30),(42,31),(14,35),(35,35))),
    LimbPose(fs((8,31),(7,31),(6,32),(6,33)),fs((42,30),(43,30),(43,31)),fs((13,34),(12,35)),fs((35,34),(36,35)),fs((6,33),(43,30),(43,31),(12,35),(36,35))),
    LimbPose(fs((7,32),(6,32),(5,33),(5,34)),fs((42,31),(43,31),(43,32)),fs((12,34),(11,35)),fs((36,34),(37,35)),fs((5,34),(43,31),(43,32),(11,35),(37,35))),
)

D1_SWORDS = (
    IDLE_SWORD, shift_sword(IDLE_SWORD,1,1), shift_sword(IDLE_SWORD,1,2),
    sword({16:(47,47),17:(46,47),18:(45,47),19:(44,46),20:(43,45),21:(42,44),22:(41,43),23:(40,42),24:(39,41),25:(37,41),26:(36,41),27:(36,40),28:(37,40)},((47,17),(46,18),(45,19),(44,20),(43,21),(42,22),(41,23),(40,24),(39,25),(38,26),(37,27)),((37,27),(47,16))),
    sword({16:(47,47),17:(46,47),18:(45,47),19:(44,46),20:(44,46),21:(43,45),22:(43,45),23:(42,44),24:(42,44),25:(41,43),26:(41,43),27:(39,44),28:(39,44),29:(39,43),30:(40,43)},((47,17),(46,18),(45,19),(45,20),(44,21),(44,22),(43,23),(43,24),(42,25),(42,26),(41,27),(40,28)),((40,29),(47,16))),
    sword({16:(46,47),17:(46,47),18:(45,47),19:(45,47),20:(44,46),21:(44,46),22:(43,45),23:(43,45),24:(42,44),25:(42,44),26:(41,43),27:(40,44),28:(40,44),29:(40,44),30:(40,44),31:(41,43)},((47,16),(46,17),(46,18),(45,19),(45,20),(44,21),(44,22),(43,23),(43,24),(42,25),(42,26),(41,27),(41,28),(41,29)),((41,30),(47,16))),
    sword({14:(47,47),15:(46,47),16:(46,47),17:(46,47),18:(45,47),19:(45,47),20:(45,47),21:(44,46),22:(44,46),23:(44,46),24:(43,45),25:(43,45),26:(43,45),27:(42,44),28:(41,45),29:(41,45),30:(41,45),31:(41,45),32:(42,44)},((47,15),(46,16),(46,17),(46,18),(45,19),(45,20),(45,21),(44,22),(44,23),(44,24),(43,25),(43,26),(43,27),(42,28),(42,29)),((42,30),(47,15))),
    sword({15:(47,47),16:(46,47),17:(46,47),18:(46,47),19:(45,47),20:(45,47),21:(45,47),22:(44,46),23:(44,46),24:(44,46),25:(43,45),26:(43,45),27:(43,45),28:(42,44),29:(41,45),30:(41,45),31:(41,45),32:(41,45),33:(42,44)},((47,16),(46,17),(46,18),(46,19),(45,20),(45,21),(45,22),(44,23),(44,24),(44,25),(43,26),(43,27),(43,28),(42,29),(42,30)),((42,31),(47,16))),
)

D2_LIMBS = (
    BASE_LIMBS,
    LimbPose(fs((13,25),(12,25),(11,26),(10,26)),fs((34,25),(35,25),(35,26)),fs((19,32),(18,33),(17,34),(16,35)),fs((28,32),(29,33),(30,34),(31,35)),fs((10,26),(35,25),(35,26),(16,35),(31,35))),
    LimbPose(fs((12,27),(11,27),(10,28),(9,28)),fs((35,26),(36,26),(36,27)),fs((18,33),(17,34),(16,35)),fs((29,33),(30,34),(31,35)),fs((9,28),(36,26),(36,27),(16,35),(31,35))),
    LimbPose(fs((11,29),(10,29),(9,30),(8,30)),fs((36,28),(37,28),(37,29)),fs((17,34),(16,35)),fs((30,34),(31,35)),fs((8,30),(37,28),(37,29),(16,35),(31,35))),
    LimbPose(fs((9,31),(8,31),(7,32),(7,33)),fs((38,30),(39,30),(39,31)),fs((15,34),(14,35)),fs((32,34),(33,35)),fs((7,33),(39,30),(39,31),(14,35),(33,35))),
    LimbPose(fs((7,32),(6,32),(5,33),(5,34)),fs((40,32),(41,32),(41,33)),fs((13,34),(12,35)),fs((34,34),(35,35)),fs((5,34),(41,32),(41,33),(12,35),(35,35))),
    LimbPose(fs((5,33),(4,33),(4,34),(5,34)),fs((42,33),(43,33),(43,34)),fs((11,35),(12,35)),fs((36,35),(37,35)),fs((4,34),(43,33),(43,34),(11,35),(37,35))),
    LimbPose(fs((5,34),(4,34),(4,35),(5,35)),fs((43,34),(44,34),(44,35)),fs((10,35),(11,35)),fs((37,35),(38,35)),fs((4,35),(44,34),(44,35),(10,35),(38,35))),
)

D2_SWORDS = (
    IDLE_SWORD, IDLE_SWORD_DOWN,
    sword({16:(46,46),17:(45,46),18:(44,46),19:(43,45),20:(42,44),21:(41,43),22:(40,42),23:(39,41),24:(38,40),25:(35,40),26:(35,39),27:(35,39)},((46,17),(45,18),(44,19),(43,20),(42,21),(41,22),(40,23),(39,24),(38,25),(37,26)),((36,26),(46,16))),
    sword({19:(46,46),20:(45,46),21:(44,46),22:(43,45),23:(42,44),24:(41,43),25:(40,42),26:(39,41),27:(36,41),28:(36,40),29:(36,40)},((46,20),(45,21),(44,22),(43,23),(42,24),(41,25),(40,26),(39,27),(38,28)),((37,28),(46,19))),
    sword({23:(47,47),24:(46,47),25:(45,47),26:(44,46),27:(43,45),28:(42,44),29:(40,44),30:(38,43),31:(38,42)},((47,24),(46,25),(45,26),(44,27),(43,28),(42,29),(41,30)),((39,30),(47,23))),
    sword({27:(47,47),28:(46,47),29:(45,47),30:(44,46),31:(42,46),32:(40,45),33:(40,44)},((47,28),(46,29),(45,30),(44,31),(43,32)),((41,32),(47,27))),
    sword({29:(47,47),30:(46,47),31:(45,47),32:(44,47),33:(42,47),34:(42,46)},((47,30),(46,31),(45,32),(44,33)),((43,33),(47,29))),
    sword({32:(47,47),33:(46,47),34:(43,47),35:(43,46)},((47,33),(46,34),(45,34)),((44,34),(47,32))),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT.resolve()).as_posix()


def ensure_dev(path: Path) -> None:
    resolved = path.resolve()
    if not (
        resolved.is_relative_to(SOURCE_DIR.resolve())
        or resolved.is_relative_to(PREVIEW_DIR.resolve())
        or is_enemy_asset_report_path(path)
    ):
        raise AssertionError(f"Refused non-preview output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def write_json(path: Path, payload: object) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def put_points(image: Image.Image, points: set[Point] | frozenset[Point] | tuple[Point, ...], color: Color) -> None:
    for x, y in points:
        if not (0 <= x < FRAME and 0 <= y < FRAME):
            raise AssertionError(f"Point outside 48px frame: {(x, y)}")
        image.putpixel((x, y), color)


def paint_body(image: Image.Image, mask: set[Point]) -> None:
    for x, y in mask:
        boundary = any((x + dx, y + dy) not in mask for dx, dy in ((-1,0),(1,0),(0,-1),(0,1)))
        image.putpixel((x, y), OUTLINE if boundary else KRAFT_MID)


def flat_core(offset_x: int = 0, offset_y: int = 0) -> tuple[Image.Image, set[Point], set[Point]]:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = {(x + offset_x, y + offset_y) for y in range(13, 32) for x in range(13, 35)}
    paint_body(image, body)
    put_points(image, tuple((x + offset_x, 13 + offset_y) for x in range(14, 34)), FOLD_HIGHLIGHT)
    put_points(image, tuple((x + offset_x, 14 + offset_y) for x in range(14, 34)), KRAFT_LIGHT)
    put_points(image, tuple((33 + offset_x, y + offset_y) for y in range(16, 31)), KRAFT_DARK)
    image.putpixel((14 + offset_x, 16 + offset_y), KRAFT_LIGHT)
    eyes = {(20 + offset_x, 21 + offset_y), (20 + offset_x, 22 + offset_y),
            (27 + offset_x, 21 + offset_y), (27 + offset_x, 22 + offset_y)}
    put_points(image, eyes, EYE_DARK)
    return image, body, eyes


def paint_limbs(image: Image.Image, pose: LimbPose) -> None:
    put_points(image, pose.free_arm | pose.weapon_arm | pose.left_leg | pose.right_leg, LIMB_BROWN)
    put_points(image, pose.deep, DEEP_BROWN)


def paint_sword(image: Image.Image, pose: SwordPose, limbs: LimbPose) -> None:
    put_points(image, pose.mask, PAPER_EDGE)
    put_points(image, pose.core, PAPER_SWORD)
    put_points(image, limbs.deep & limbs.weapon_arm, DEEP_BROWN)


def living_frame(limbs: LimbPose, blade: SwordPose, offset_x: int = 0, offset_y: int = 0) -> BuiltFrame:
    image, body, eyes = flat_core(offset_x, offset_y)
    paint_limbs(image, limbs)
    paint_sword(image, blade, limbs)
    return BuiltFrame(image, body, limbs, blade, eyes)


def death_frame(body_mask: frozenset[Point], eyes: frozenset[Point], limbs: LimbPose, blade: SwordPose) -> BuiltFrame:
    image = Image.new("RGBA", (FRAME, FRAME), TRANSPARENT)
    body = set(body_mask)
    paint_body(image, body)
    top_y = min(y for _, y in body)
    top_x = sorted(x for x, y in body if y == top_y)
    if len(top_x) > 2:
        put_points(image, tuple((x, top_y) for x in top_x[1:-1]), FOLD_HIGHLIGHT)
    for y in sorted({y for _, y in body}):
        row_x = sorted(x for x, py in body if py == y)
        if len(row_x) > 3:
            image.putpixel((row_x[-2], y), KRAFT_DARK)
    put_points(image, eyes, EYE_DARK)
    paint_limbs(image, limbs)
    paint_sword(image, blade, limbs)
    return BuiltFrame(image, body, limbs, blade, set(eyes))


def build_all() -> dict[str, list[BuiltFrame]]:
    m1 = [living_frame(M1_LIMBS[i], M1_SWORDS[i], 0, M1_CORE_OFFSETS[i]) for i in range(COUNT)]
    m2 = [living_frame(M2_LIMBS[i], M2_SWORDS[i], 0, M2_CORE_OFFSETS[i]) for i in range(COUNT)]
    a1 = [living_frame(A1_LIMBS[i], A1_SWORDS[i], A1_CORE_X[i], 0) for i in range(COUNT)]
    a2 = [living_frame(A2_LIMBS[i], A2_SWORDS[i], A2_CORE_X[i], 0) for i in range(COUNT)]
    anchor_frame = living_frame(BASE_LIMBS, IDLE_SWORD)
    d1 = [anchor_frame] + [death_frame(D1_BODIES[i], D1_EYES[i], D1_LIMBS[i], D1_SWORDS[i]) for i in range(1, COUNT)]
    d2 = [living_frame(BASE_LIMBS, IDLE_SWORD)] + [death_frame(D2_BODIES[i], D2_EYES[i], D2_LIMBS[i], D2_SWORDS[i]) for i in range(1, COUNT)]
    return {"m1": m1, "m2": m2, "a1": a1, "a2": a2, "d1": d1, "d2": d2}


def opaque_points(image: Image.Image) -> set[Point]:
    return {(x, y) for y in range(FRAME) for x in range(FRAME) if image.getpixel((x, y))[3] == 255}


def components(points: set[Point], diagonal: bool = True) -> list[set[Point]]:
    remaining = set(points)
    result: list[set[Point]] = []
    offsets = [(-1,0),(1,0),(0,-1),(0,1)]
    if diagonal:
        offsets += [(-1,-1),(1,-1),(-1,1),(1,1)]
    while remaining:
        start = remaining.pop()
        part = {start}
        queue = deque([start])
        while queue:
            x, y = queue.popleft()
            for dx, dy in offsets:
                nxt = (x + dx, y + dy)
                if nxt in remaining:
                    remaining.remove(nxt)
                    part.add(nxt)
                    queue.append(nxt)
        result.append(part)
    return result


def touches8(first: set[Point] | frozenset[Point], second: set[Point] | frozenset[Point]) -> bool:
    if set(first) & set(second):
        return True
    return any((x + dx, y + dy) in second for x, y in first for dx in (-1,0,1) for dy in (-1,0,1) if dx or dy)


def audit_frame(frame: BuiltFrame, key: str, index: int) -> dict[str, object]:
    image = frame.image
    for pixel in image.getdata():
        if pixel not in PALETTE:
            raise AssertionError(f"{key}[{index}] palette drift: {pixel}")
        if pixel[3] not in (0, 255) or (pixel[3] == 0 and pixel[:3] != (0,0,0)):
            raise AssertionError(f"{key}[{index}] alpha/transparent RGB drift")
    opaque = opaque_points(image)
    if len(components(opaque)) != 1:
        raise AssertionError(f"{key}[{index}] character is not one 8-connected component")
    bbox = image.getchannel("A").getbbox()
    if bbox is None or bbox[3] != BASELINE_BOTTOM:
        raise AssertionError(f"{key}[{index}] baseline drift: {bbox}")
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    limit = (36, 27) if SPECS[key]["kind"] == "move" else (44, 32)
    if width > limit[0] or height > limit[1]:
        raise AssertionError(f"{key}[{index}] bbox exceeds {limit}: {bbox}")
    limbs = frame.limbs
    for name, mask in (("free_arm",limbs.free_arm),("weapon_arm",limbs.weapon_arm),
                       ("left_leg",limbs.left_leg),("right_leg",limbs.right_leg)):
        if not set(mask) <= opaque or not touches8(mask, frame.body):
            raise AssertionError(f"{key}[{index}] detached/missing {name}")
    if not set(frame.sword.mask) <= opaque or len(components(set(frame.sword.mask))) != 1 or not touches8(frame.sword.mask, limbs.weapon_arm):
        raise AssertionError(f"{key}[{index}] paper sword is detached or fragmented")
    if max(x for x, _ in frame.sword.mask) <= max(x for x, _ in frame.body):
        raise AssertionError(f"{key}[{index}] paper sword is not in front of right-facing body")
    sword_length = math.dist(*frame.sword.endpoints)
    if key != "d2" and not (14.0 <= sword_length <= 16.0):
        raise AssertionError(f"{key}[{index}] paper sword length drift: {sword_length}")
    if frame.eyes:
        if len(frame.eyes) != 4 or len(components(set(frame.eyes), diagonal=False)) != 2:
            raise AssertionError(f"{key}[{index}] eye-hole contract drift")
    return {
        "index": index, "bbox": list(bbox), "visible_size": [width, height],
        "opaque_pixels": len(opaque), "components_8": 1,
        "baseline_bottom_exclusive": BASELINE_BOTTOM, "sword_pixels": len(frame.sword.mask),
        "sword_endpoint_distance": round(sword_length, 4), "sword_connected_to_hand": True,
        "sword_in_front_for_right_facing": True, "rgba_sha256": rgba_sha(image),
    }


def audit_all(frames: dict[str, list[BuiltFrame]], anchor: Image.Image) -> dict[str, list[dict[str, object]]]:
    result: dict[str, list[dict[str, object]]] = {}
    anchor_bytes = anchor.convert("RGBA").tobytes()
    for key, sequence in frames.items():
        if len(sequence) != COUNT:
            raise AssertionError(f"{key}: frame count drift")
        if sequence[0].image.tobytes() != anchor_bytes:
            raise AssertionError(f"{key}: frame0 is not the approved L1 anchor")
        hashes = [rgba_sha(frame.image) for frame in sequence]
        if len(set(hashes)) != COUNT:
            raise AssertionError(f"{key}: all eight frames must be unique")
        result[key] = [audit_frame(frame, key, index) for index, frame in enumerate(sequence)]
    for key, limbs in (("m1",M1_LIMBS),("m2",M2_LIMBS)):
        if not any(y == 35 for _, y in limbs[2].right_leg) or max(y for _, y in limbs[2].left_leg) != 34:
            raise AssertionError(f"{key}: left pass phase is not visibly airborne")
        if not any(y == 35 for _, y in limbs[6].left_leg) or max(y for _, y in limbs[6].right_leg) != 34:
            raise AssertionError(f"{key}: right pass phase is not visibly airborne")
    for key in ("a1", "a2"):
        start, end = frames[key][4].sword.endpoints
        angle = math.degrees(math.atan2(end[1] - start[1], end[0] - start[0]))
        if abs(angle) > 30.0:
            raise AssertionError(f"{key}: global F4 damage pose misses the 60-degree fan: {angle}")
    d2_counts = [len(frame.sword.mask) for frame in frames["d2"]]
    if any(later > earlier for earlier, later in zip(d2_counts, d2_counts[1:])):
        raise AssertionError(f"d2: visible paper sword must become monotonically occluded: {d2_counts}")
    for index, frame in enumerate(frames["d1"]):
        if not (set(frame.sword.mask) - frame.body):
            raise AssertionError(f"d1[{index}]: paper sword must remain externally visible")
    return result


def normalize_reference(raw: Image.Image) -> Image.Image:
    rgba = raw.convert("RGBA")
    result = Image.new("RGBA", rgba.size, TRANSPARENT)
    source = rgba.load()
    target = result.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source[x, y]
            if alpha <= 8 or (green >= max(red, blue) + 34 and green >= 115):
                continue
            if green > max(red, blue) + 8:
                green = max(red, blue)
            target[x, y] = (red, green, blue, 255)
    return result


def nearest(image: Image.Image, scale: int) -> Image.Image:
    return image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)


def on_bg(image: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", image.size, BACKGROUND)
    canvas.alpha_composite(image)
    return canvas


def make_strip(sequence: list[BuiltFrame]) -> Image.Image:
    strip = Image.new("RGBA", (FRAME * COUNT, FRAME), TRANSPARENT)
    for index, frame in enumerate(sequence):
        strip.alpha_composite(frame.image, (index * FRAME, 0))
    return strip


def exact_palette(frames: list[Image.Image]) -> tuple[list[tuple[int,int,int]], dict[tuple[int,int,int],int]]:
    colors: list[tuple[int,int,int]] = []
    for frame in frames:
        for color in frame.convert("RGB").getdata():
            if color not in colors:
                colors.append(color)
    if len(colors) > 256:
        raise AssertionError("Exact GIF palette overflow")
    return colors, {color:index for index,color in enumerate(colors)}


def palettize(image: Image.Image, colors: list[tuple[int,int,int]], indices: dict[tuple[int,int,int],int]) -> Image.Image:
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    result.putpalette(palette)
    result.putdata([indices[color] for color in rgb.getdata()])
    return result


def save_animation_gif(sequence: list[BuiltFrame], path: Path, durations: list[int], mirrored: bool) -> dict[str, object]:
    ensure_dev(path)
    expected_native = [ImageOps.mirror(frame.image) if mirrored else frame.image for frame in sequence]
    expected = [nearest(on_bg(frame), 10).convert("RGB") for frame in expected_native]
    colors, indices = exact_palette(expected)
    encoded = [palettize(frame, colors, indices) for frame in expected]
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded[0].save(path, save_all=True, append_images=encoded[1:], duration=durations, loop=0, disposal=2, optimize=False)
    decoded = [frame.convert("RGB").copy() for frame in ImageSequence.Iterator(Image.open(path))]
    if len(decoded) != COUNT or any(a.tobytes() != b.tobytes() for a,b in zip(decoded, expected, strict=True)):
        raise AssertionError(f"GIF decode mismatch: {path}")
    return {"path":rel(path),"sha256":sha256(path),"frames":COUNT,"duration_ms":durations,"mirrored":mirrored,"exact_decode":True}


def delta_strip(sequence: list[BuiltFrame], anchor: Image.Image) -> Image.Image:
    result = Image.new("RGBA", (FRAME * COUNT, FRAME), BACKGROUND)
    for index, frame in enumerate(sequence):
        for y in range(FRAME):
            for x in range(FRAME):
                before = anchor.getpixel((x,y))
                after = frame.image.getpixel((x,y))
                if before == after:
                    color = (62,72,82,255) if after[3] else BACKGROUND
                elif before[3] == 0 and after[3]:
                    color = (65,224,129,255)
                elif before[3] and after[3] == 0:
                    color = (237,92,151,255)
                else:
                    color = (255,198,78,255)
                result.putpixel((index * FRAME + x, y), color)
    return result


def font(size: int) -> ImageFont.ImageFont:
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/simhei.ttf")):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def fit(image: Image.Image, size: tuple[int,int]) -> Image.Image:
    result = image.copy()
    result.thumbnail(size, Image.Resampling.NEAREST)
    return result


def paste_center(canvas: Image.Image, image: Image.Image, box: tuple[int,int,int,int]) -> None:
    left,top,right,bottom = box
    canvas.alpha_composite(image, (left + (right-left-image.width)//2, top + (bottom-top-image.height)//2))


def review_panel(key: str, reference: Image.Image, strip: Image.Image, delta: Image.Image) -> Image.Image:
    spec = SPECS[key]
    canvas = Image.new("RGBA", (1920, 1020), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    draw.text((28,18), f"大纸箱怪第二门 — {spec['title']}", fill=(235,236,232,255), font=font(32))
    draw.text((28,62), "ImageGen仅作动作结构参考；下方48px动画来自显式逐帧点表。", fill=(164,174,177,255), font=font(18))
    canvas.alpha_composite(Image.new("RGBA",(520,500),(23,33,46,255)),(24,112))
    paste_center(canvas, fit(reference,(480,460)), (44,132,524,592))
    draw.text((44,88), "ImageGen 4×2结构稿（仅参考）", fill=(235,236,232,255), font=font(16))
    preview = nearest(on_bg(strip), 3)
    paste_center(canvas, preview, (570,130,1890,420))
    draw.text((570,96), "native48 ×3（8帧）", fill=(235,236,232,255), font=font(16))
    delta_preview = nearest(delta, 3)
    paste_center(canvas, delta_preview, (570,500,1890,790))
    draw.text((570,466), "相对批准L1锚点：新增绿 / 删除粉 / 换色黄", fill=(235,236,232,255), font=font(16))
    notes = "M1/M2：支撑脚与摆动脚交替" if spec["kind"] == "move" else ("A1/A2：F0–F2前摇，F3–F7挥击；总F4结算" if spec["kind"] == "attack" else "D1/D2：纸剑全程与持剑手连接")
    draw.text((44,650), notes, fill=(235,236,232,255), font=font(19))
    draw.text((44,700), "中心 x=24｜脚底 y=36｜纸剑始终位于当前朝向前方", fill=(164,174,177,255), font=font(18))
    draw.text((44,750), "正/反向GIF分别输出；镜像为整帧精确水平翻转。", fill=(164,174,177,255), font=font(18))
    return canvas


def file_record(path: Path) -> dict[str, object]:
    with Image.open(path) as image:
        return {"path":rel(path),"sha256":sha256(path),"size":list(image.size),"mode":image.mode}


def coordinate_record(frame: BuiltFrame) -> dict[str, object]:
    return {
        "body": sorted([list(p) for p in frame.body]),
        "free_arm": sorted([list(p) for p in frame.limbs.free_arm]),
        "weapon_arm": sorted([list(p) for p in frame.limbs.weapon_arm]),
        "left_leg": sorted([list(p) for p in frame.limbs.left_leg]),
        "right_leg": sorted([list(p) for p in frame.limbs.right_leg]),
        "sword": sorted([list(p) for p in frame.sword.mask]),
        "sword_core": sorted([list(p) for p in frame.sword.core]),
        "sword_endpoints": [list(p) for p in frame.sword.endpoints],
        "eyes": sorted([list(p) for p in frame.eyes]),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build preview-only large-cardboard animation candidates and certificates."
    )
    parser.add_argument(
        "--approve",
        nargs=3,
        metavar=("MOVE", "ATTACK", "DEATH"),
        help=(
            "Record the explicit second-gate choice; this frozen gate only "
            "accepts '--approve m1 a1 d2'."
        ),
    )
    args = parser.parse_args()
    if args.approve is None:
        return args
    requested = dict(zip(("move", "attack", "death"), args.approve, strict=True))
    for category, candidate in requested.items():
        if candidate not in APPROVAL_ENUMS[category]:
            parser.error(
                f"invalid {category} candidate {candidate!r}; "
                f"expected one of {APPROVAL_ENUMS[category]}"
            )
    if requested != APPROVED_ANIMATION_SELECTION:
        parser.error(
            "this frozen human gate only accepts the exact combination "
            "'--approve m1 a1 d2'"
        )
    args.approve = requested
    return args


def verify_candidate_native_locks() -> None:
    for key, lock in ALL_CANDIDATE_NATIVE_LOCKS.items():
        path = ROOT / lock["path"]
        if not path.is_file() or sha256(path) != lock["sha256"]:
            raise AssertionError(f"Frozen {key} candidate PNG drifted before approval")
        with Image.open(path) as opened:
            decoded = opened.convert("RGBA")
        if rgba_sha(decoded) != lock["rgba_sha256"]:
            raise AssertionError(f"Frozen {key} candidate RGBA drifted before approval")


def verify_pending_second_gate_certificate() -> None:
    locked_paths = {
        "report_sha256": REPORT_PATH,
        "manifest_sha256": MANIFEST_PATH,
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
    payloads = (
        (json.loads(REPORT_PATH.read_text(encoding="utf-8")), "report"),
        (json.loads(MANIFEST_PATH.read_text(encoding="utf-8")), "manifest"),
        (json.loads(STABILITY_PATH.read_text(encoding="utf-8")), "stability"),
    )
    for payload, label in payloads:
        if payload.get("stage") != PENDING_SECOND_GATE_CERTIFICATE["stage"]:
            raise AssertionError(f"Pending {label} stage drifted")
        if payload.get("approved_anchor") != PENDING_SECOND_GATE_CERTIFICATE["approved_anchor"]:
            raise AssertionError(f"Pending {label} anchor selection drifted")
        if payload.get("approved_animation_selection") is not None:
            raise AssertionError(f"Pending {label} unexpectedly contains a selection")
        if payload.get("second_human_approved") is not False:
            raise AssertionError(f"Pending {label} approval boolean drifted")
        if payload.get("runtime_written") is not False:
            raise AssertionError(f"Pending {label} unexpectedly claims runtime output")
        builder_sha = (
            payload.get("builder", {}).get("sha256")
            if label != "stability"
            else payload.get("builder_sha256")
        )
        if builder_sha != PENDING_SECOND_GATE_CERTIFICATE["builder_sha256"]:
            raise AssertionError(f"Pending {label} builder lock drifted")
    report = payloads[0][0]
    if report.get("anchor_rgba_sha256") != PENDING_SECOND_GATE_CERTIFICATE["anchor_rgba_sha256"]:
        raise AssertionError("Pending report anchor RGBA lock drifted")
    if report.get("coordinate_table_sha256") != PENDING_SECOND_GATE_CERTIFICATE["coordinate_table_sha256"]:
        raise AssertionError("Pending report coordinate-table lock drifted")
    verify_candidate_native_locks()


def validate_persisted_approval() -> bool:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    claims_approval = manifest.get("second_human_approved") is True
    if not claims_approval:
        if manifest.get("stage") == "second_human_gate_approved":
            raise AssertionError("Manifest stage claims approval without approval boolean")
        if manifest.get("approved_animation_selection") is not None:
            raise AssertionError("Unapproved manifest contains an animation selection")
        return False
    payloads = (
        (manifest, "manifest"),
        (json.loads(REPORT_PATH.read_text(encoding="utf-8")), "report"),
        (json.loads(STABILITY_PATH.read_text(encoding="utf-8")), "stability"),
    )
    for payload, label in payloads:
        if payload.get("stage") != "second_human_gate_approved":
            raise AssertionError(f"Persisted approved {label} stage drifted")
        if payload.get("approved_anchor") != "l1":
            raise AssertionError(f"Persisted approved {label} anchor drifted")
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
        if payload.get("all_candidate_native_locks") != ALL_CANDIDATE_NATIVE_LOCKS:
            raise AssertionError(f"Persisted approved {label} candidate locks drifted")
        if payload.get("approved_selected_locks") != APPROVED_SELECTED_LOCKS:
            raise AssertionError(f"Persisted approved {label} selected locks drifted")
    verify_candidate_native_locks()
    return True


def resolve_second_gate_approval(requested: dict[str, str] | None) -> bool:
    persisted = validate_persisted_approval()
    if requested is None:
        if not persisted:
            raise AssertionError(
                "Pending second gate is frozen; rerun with exact "
                "'--approve m1 a1 d2' instead of rebuilding it without approval"
            )
        return True
    if requested != APPROVED_ANIMATION_SELECTION:
        raise AssertionError("Approval selection bypassed strict CLI validation")
    if not persisted:
        verify_pending_second_gate_certificate()
    return True


def audit_rebuilt_candidate_locks(records: dict[str, object]) -> None:
    if set(records) != set(ALL_CANDIDATE_NATIVE_LOCKS):
        raise AssertionError("Rebuilt candidate set does not match the frozen gate")
    for key, lock in ALL_CANDIDATE_NATIVE_LOCKS.items():
        native = records[key]["native_strip"]
        if native.get("path") != lock["path"]:
            raise AssertionError(f"{key}: rebuilt native path drifted")
        if native.get("sha256") != lock["sha256"]:
            raise AssertionError(f"{key}: rebuilt native PNG drifted")
        if native.get("rgba_sha256") != lock["rgba_sha256"]:
            raise AssertionError(f"{key}: rebuilt native RGBA drifted")


def build_once(second_human_approved: bool) -> tuple[dict[str, object], dict[str,str]]:
    if not second_human_approved:
        raise AssertionError("This builder cannot rewrite the frozen pending gate")
    for path, expected in EXPECTED.items():
        if not path.is_file() or sha256(path) != expected:
            raise AssertionError(f"Approved L1 input lock drift: {path}")
    anchor_manifest = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    if anchor_manifest.get("stage") != "first_human_gate_approved" or anchor_manifest.get("approved_selection") != "l1" or anchor_manifest.get("first_human_approved") is not True or anchor_manifest.get("runtime_written") is not False:
        raise AssertionError("L1 first-gate approval certificate is not valid")
    anchor = Image.open(ANCHOR).convert("RGBA")
    if rgba_sha(anchor) != ANCHOR_RGBA_SHA256:
        raise AssertionError("Approved L1 decoded RGBA drift")
    frames = build_all()
    metrics = audit_all(frames, anchor)
    output_paths: list[Path] = []
    records: dict[str, object] = {}
    coordinates: dict[str, object] = {}

    for key, spec in SPECS.items():
        raw_path = RAW_FILES[key]
        if not raw_path.is_file() or sha256(raw_path) != EXPECTED_RAW_SHA[key]:
            raise AssertionError(f"{key}: ImageGen raw SHA drift")
        raw = Image.open(raw_path).convert("RGBA")
        transparent = normalize_reference(raw)
        if transparent.getchannel("A").getbbox() is None:
            raise AssertionError(f"{key}: normalized reference is empty")
        crop = crop_to_square(transparent, padding=36, align_to_grid=False)
        transparent_path = SOURCE_DIR / f"cardboard_monster_large_{spec['name']}_transparent_reference.png"
        crop_path = SOURCE_DIR / f"cardboard_monster_large_{spec['name']}_crop_tool.png"
        strip_path = SOURCE_DIR / f"cardboard_monster_large_{spec['name']}_candidate_native.png"
        preview_path = PREVIEW_DIR / f"cardboard_monster_large_{spec['name']}_candidate_4x.png"
        forward_path = PREVIEW_DIR / f"cardboard_monster_large_{spec['name']}_candidate_forward.gif"
        mirror_path = PREVIEW_DIR / f"cardboard_monster_large_{spec['name']}_candidate_mirror.gif"
        delta_path = PREVIEW_DIR / f"cardboard_monster_large_{spec['name']}_anchor_delta.png"
        panel_path = PREVIEW_DIR / f"cardboard_monster_large_{spec['name']}_review_panel.png"
        strip = make_strip(frames[key])
        delta = delta_strip(frames[key], anchor)
        save_png(transparent, transparent_path)
        save_png(crop, crop_path)
        save_png(strip, strip_path)
        save_png(nearest(on_bg(strip), 4), preview_path)
        forward = save_animation_gif(frames[key], forward_path, spec["durations"], False)
        mirror = save_animation_gif(frames[key], mirror_path, spec["durations"], True)
        save_png(nearest(delta, 5), delta_path)
        save_png(review_panel(key, crop, strip, delta), panel_path)
        output_paths.extend([transparent_path,crop_path,strip_path,preview_path,forward_path,mirror_path,delta_path,panel_path])
        coordinates[key] = [coordinate_record(frame) for frame in frames[key]]
        records[key] = {
            "title":spec["title"],"kind":spec["kind"],"author_fps":spec["author_fps"],
            "imagegen_source":{**file_record(raw_path),"analysis":analyze_image(raw)},
            "transparent_reference":file_record(transparent_path),
            "pixel_crop_tool_reference":{**file_record(crop_path),"analysis":analyze_image(crop),"unsafe_for_direct_resize":True,"pixels_imported_into_native":False},
            "native_strip":{**file_record(strip_path),"rgba_sha256":rgba_sha(strip)},
            "integer_preview":file_record(preview_path),"forward_gif":forward,"mirror_gif":mirror,
            "anchor_delta":file_record(delta_path),"review_panel":file_record(panel_path),
            "frames":metrics[key],
        }
    audit_rebuilt_candidate_locks(records)
    coordinate_payload = json.dumps(coordinates, sort_keys=True, separators=(",",":")).encode("utf-8")
    report = {
        "asset":"cardboard_monster_large_animation_candidates","stage":"second_human_gate_approved",
        "approved_anchor":"l1","first_human_approved":True,
        "approved_animation_selection":APPROVED_ANIMATION_SELECTION,
        "second_human_approved":True,"final_human_approved":False,"preview_only":True,
        "runtime_written":False,"runtime_paths_written":[],"imagegen_pixels_imported":False,
        "builder":{"path":rel(SCRIPT),"sha256":sha256(SCRIPT)},
        "approval_basis":PENDING_SECOND_GATE_CERTIFICATE,
        "all_candidate_native_locks":ALL_CANDIDATE_NATIVE_LOCKS,
        "approved_selected_locks":APPROVED_SELECTED_LOCKS,
        "anchor_locks":{rel(path):expected for path,expected in EXPECTED.items()},
        "anchor_rgba_sha256":ANCHOR_RGBA_SHA256,"raw_sha256":EXPECTED_RAW_SHA,
        "palette":[list(c) for c in sorted(PALETTE)],
        "coordinate_table_sha256":hashlib.sha256(coordinate_payload).hexdigest(),
        "coordinate_certificate":coordinates,
        "contract":{
            "frame_size":[48,48],"frames_per_candidate":8,"registered_center_x":CENTER_X,
            "baseline_bottom_exclusive":BASELINE_BOTTOM,"max_move_visible_size":[36,27],
            "max_attack_or_death_visible_size":[44,32],"paper_sword_length_living":[14,16],
            "paper_sword_in_current_facing_foreground":True,"paper_sword_runtime_rotation":False,
            "windup_frames":[0,1,2],"slash_frames":[3,4,5,6,7],
            "slash_damage_frame_global_index":4,"slash_damage_frame_within_slash":1,
            "binary_alpha":True,"transparent_rgb_zero":True,"all_frames_single_component":True,
            "imagegen_structural_reference_only":True,"no_imagegen_pixels_in_native":True,
        },
        "move_phases":{"m1":M1_PHASES,"m2":M2_PHASES},
        "move_core_y_offsets":{"m1":M1_CORE_OFFSETS,"m2":M2_CORE_OFFSETS},
        "candidates":records,
        "stability_proof_path":rel(STABILITY_PATH),
    }
    write_json(REPORT_PATH, report)
    manifest = {
        "asset":"cardboard_monster_large","stage":report["stage"],"approved_anchor":"l1",
        "first_human_approved":True,"approved_animation_selection":APPROVED_ANIMATION_SELECTION,
        "second_human_approved":True,
        "final_human_approved":False,"preview_only":True,"runtime_written":False,"runtime_paths_written":[],
        "imagegen_pixels_imported":False,"builder":report["builder"],"raw_sha256":EXPECTED_RAW_SHA,
        "approval_basis":PENDING_SECOND_GATE_CERTIFICATE,
        "all_candidate_native_locks":ALL_CANDIDATE_NATIVE_LOCKS,
        "approved_selected_locks":APPROVED_SELECTED_LOCKS,
        "coordinate_table_sha256":report["coordinate_table_sha256"],
        "report":{"path":rel(REPORT_PATH),"sha256":sha256(REPORT_PATH)},
        "stability_proof_path":rel(STABILITY_PATH),
    }
    write_json(MANIFEST_PATH, manifest)
    output_paths.extend([REPORT_PATH,MANIFEST_PATH])
    return report, {rel(path):sha256(path) for path in sorted(output_paths)}


def build(second_human_approved: bool) -> dict[str, object]:
    first_report, first_snapshot = build_once(second_human_approved)
    second_report, second_snapshot = build_once(second_human_approved)
    if first_report != second_report or first_snapshot != second_snapshot:
        changed = sorted(key for key in set(first_snapshot)|set(second_snapshot) if first_snapshot.get(key)!=second_snapshot.get(key))
        raise AssertionError(f"Two-pass animation build drifted: {changed}")
    stability = {
        "asset":"cardboard_monster_large_animation_candidates","stage":"second_human_gate_approved",
        "builder_sha256":sha256(SCRIPT),"passes":2,"drift_count":0,
        "snapshot_scope_count":len(first_snapshot),
        "snapshot_exclusions":{rel(STABILITY_PATH):"self-referential certificate written after the two-pass snapshot; final SHA is externally locked by the build result"},
        "first_snapshot":first_snapshot,"second_snapshot":second_snapshot,
        "report_sha256":first_snapshot[rel(REPORT_PATH)],"manifest_sha256":first_snapshot[rel(MANIFEST_PATH)],
        "approved_anchor":"l1","first_human_approved":True,
        "approved_animation_selection":APPROVED_ANIMATION_SELECTION,
        "second_human_approved":True,"final_human_approved":False,
        "approval_basis":PENDING_SECOND_GATE_CERTIFICATE,
        "all_candidate_native_locks":ALL_CANDIDATE_NATIVE_LOCKS,
        "approved_selected_locks":APPROVED_SELECTED_LOCKS,
        "preview_only":True,"runtime_written":False,"runtime_paths_written":[],
    }
    write_json(STABILITY_PATH, stability)
    result = {"marker":"CARDBOARD_MONSTER_LARGE_ANIMATION_PREVIEWS_OK",
              "report":rel(REPORT_PATH),"report_sha256":stability["report_sha256"],
              "manifest":rel(MANIFEST_PATH),"manifest_sha256":stability["manifest_sha256"],
              "stability":{"path":rel(STABILITY_PATH),"sha256":sha256(STABILITY_PATH),"passes":2,"drift_count":0}}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result


if __name__ == "__main__":
    arguments = parse_args()
    build(resolve_second_gate_approval(arguments.approve))
