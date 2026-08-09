#!/usr/bin/env python3
"""
Generate the 80-item collectible expansion.

The output is intentionally deterministic: every icon is a native 32x32
transparent pixel-art PNG and every config is a Godot PickupConfig resource.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw
from update_collectible_descriptions import (
    THUNDER_LOCAL_TARGET_RADIUS,
    generate_description as generate_player_description,
    parse_value,
)
from update_collectible_design_notes import generate_design_note


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TEXTURE_DIR = PROJECT_ROOT / "resources" / "texture" / "collectibles"
CONFIG_DIR = PROJECT_ROOT / "resources" / "config" / "collectibles"
AUDIT_PATH = PROJECT_ROOT / "dev_tools" / "collectible_expansion_audit.png"
DESIGN_MANIFEST_PATH = PROJECT_ROOT / "dev_tools" / "collectible_redesign_manifest.md"

COMMON = 0
RARE = 1
EPIC = 2
LEGENDARY = 3

RARITY_LABELS_TEXT = {
    COMMON: "普通",
    RARE: "稀有",
    EPIC: "史诗",
    LEGENDARY: "传说",
}

OUTLINE = (18, 13, 22, 255)
OUTLINE_SOFT = (52, 18, 58, 255)
WHITE = (255, 244, 205, 255)
BLACK_ALPHA = (0, 0, 0, 0)

PALETTES: dict[str, dict[str, tuple[int, int, int, int]]] = {
    "red": {"primary": (207, 42, 48, 255), "light": (255, 112, 96, 255), "dark": (110, 18, 34, 255), "metal": (211, 138, 53, 255), "accent": (255, 225, 88, 255)},
    "green": {"primary": (42, 185, 78, 255), "light": (125, 255, 116, 255), "dark": (20, 94, 52, 255), "metal": (202, 138, 54, 255), "accent": (97, 240, 214, 255)},
    "blue": {"primary": (48, 142, 220, 255), "light": (123, 228, 255, 255), "dark": (26, 61, 142, 255), "metal": (184, 194, 205, 255), "accent": (250, 245, 174, 255)},
    "cyan": {"primary": (45, 204, 218, 255), "light": (164, 255, 255, 255), "dark": (18, 101, 126, 255), "metal": (191, 204, 210, 255), "accent": (255, 240, 120, 255)},
    "purple": {"primary": (137, 59, 206, 255), "light": (225, 129, 255, 255), "dark": (66, 24, 112, 255), "metal": (214, 151, 62, 255), "accent": (107, 233, 255, 255)},
    "yellow": {"primary": (232, 174, 36, 255), "light": (255, 241, 107, 255), "dark": (136, 80, 19, 255), "metal": (178, 116, 42, 255), "accent": (255, 94, 55, 255)},
    "orange": {"primary": (226, 102, 32, 255), "light": (255, 186, 78, 255), "dark": (123, 48, 21, 255), "metal": (184, 121, 54, 255), "accent": (255, 238, 129, 255)},
    "silver": {"primary": (170, 181, 184, 255), "light": (238, 248, 247, 255), "dark": (78, 88, 94, 255), "metal": (208, 213, 214, 255), "accent": (93, 228, 250, 255)},
    "gold": {"primary": (226, 166, 31, 255), "light": (255, 235, 89, 255), "dark": (137, 76, 18, 255), "metal": (209, 143, 44, 255), "accent": (116, 232, 255, 255)},
    "brown": {"primary": (151, 88, 43, 255), "light": (231, 163, 88, 255), "dark": (78, 42, 24, 255), "metal": (185, 191, 183, 255), "accent": (236, 70, 54, 255)},
    "leaf": {"primary": (82, 158, 61, 255), "light": (164, 236, 82, 255), "dark": (43, 82, 39, 255), "metal": (157, 102, 48, 255), "accent": (255, 236, 154, 255)},
    "void": {"primary": (55, 45, 91, 255), "light": (151, 112, 255, 255), "dark": (17, 14, 36, 255), "metal": (226, 175, 56, 255), "accent": (96, 235, 255, 255)},
}

RARITY_SPARK = {
    COMMON: (218, 206, 174, 255),
    RARE: (102, 216, 255, 255),
    EPIC: (207, 139, 255, 255),
    LEGENDARY: (255, 220, 83, 255),
}

FIELD_ALIASES = {
    "stack": "collectible_stacks_by_copy",
    "attack": "collectible_attack_bonus",
    "health": "collectible_max_health_bonus",
    "move": "collectible_move_speed_bonus",
    "attack_speed": "collectible_attack_speed_bonus",
    "pdef": "collectible_physical_defense_bonus",
    "mdef": "collectible_magic_defense_bonus",
    "pdamage": "collectible_physical_damage_bonus",
    "mdamage": "collectible_magic_damage_bonus",
    "charge": "collectible_skill_charge_bonus_per_second",
    "pierce": "bullet_pierce_chance",
    "requires_projectile": "requires_projectile_primary_attack",
    "requires_ammo": "requires_ammunition",
    "ammo_add": "collectible_ammo_capacity_additive_bonus",
    "ammo_ratio": "collectible_ammo_capacity_bonus_ratio",
    "reload_reduction": "collectible_reload_time_reduction",
    "free": "base_upgrade_free_chance",
    "front": "incoming_ranged_front_damage_multiplier",
    "back": "incoming_ranged_back_damage_multiplier",
    "dodge": "incoming_ranged_dodge_chance",
    "atk_step": "attack_speed_xirang_step",
    "atk_step_bonus": "attack_speed_bonus_per_xirang_step",
    "def_step": "defense_xirang_step",
    "def_step_bonus": "defense_bonus_per_xirang_step",
    "periodic": "periodic_effect_id",
    "interval": "periodic_interval",
    "radius": "periodic_radius",
    "damage": "periodic_damage",
    "multiplier": "periodic_attack_damage_multiplier",
    "targets": "periodic_target_count",
    "heal": "periodic_heal",
    "slow": "periodic_slow_multiplier",
    "slow_duration": "periodic_slow_duration",
    "skill": "skill_effect_id",
    "skill_radius": "skill_effect_radius",
    "skill_duration": "skill_effect_duration",
    "skill_speed": "skill_move_speed_multiplier",
    "design_id": "collectible_design_id",
    "design_note": "collectible_design_note",
    "condition": "conditional_effect_id",
    "hp_threshold": "conditional_health_ratio_threshold",
    "xirang_threshold": "conditional_xirang_threshold",
    "c_attack": "conditional_attack_bonus",
    "c_health": "conditional_max_health_bonus",
    "c_move": "conditional_move_speed_bonus",
    "c_pdef": "conditional_physical_defense_bonus",
    "c_mdef": "conditional_magic_defense_bonus",
    "c_pdamage": "conditional_physical_damage_bonus",
    "c_mdamage": "conditional_magic_damage_bonus",
    "c_charge": "conditional_skill_charge_bonus_per_second",
    "c_pierce": "conditional_bullet_pierce_chance",
    "trigger": "trigger_effect_id",
    "shots": "trigger_shot_interval",
    "cooldown": "trigger_cooldown",
    "t_damage": "trigger_damage",
    "t_radius": "trigger_radius",
    "t_heal": "trigger_heal",
    "t_xirang": "trigger_xirang",
    "t_charge": "trigger_skill_charge",
    "t_slow": "trigger_slow_multiplier",
    "t_slow_duration": "trigger_slow_duration",
    "hit": "on_hit_effect_id",
    "hit_chance": "on_hit_chance",
    "hit_cd": "on_hit_cooldown",
    "hit_damage": "on_hit_damage",
    "hit_duration": "on_hit_duration",
    "hit_tick": "on_hit_tick_interval",
    "hit_radius": "on_hit_radius",
    "hit_heal": "on_hit_heal",
    "hit_xirang": "on_hit_xirang",
    "hit_charge": "on_hit_skill_charge",
    "hit_slow": "on_hit_slow_multiplier",
    "hit_pdef_mod": "on_hit_physical_defense_modifier",
    "hit_taken": "on_hit_damage_taken_multiplier",
    "hit_execute": "on_hit_execute_health_ratio",
    "kill": "kill_effect_id",
    "kill_cd": "kill_cooldown",
    "kill_heal": "kill_heal",
    "kill_xirang": "kill_xirang",
    "kill_charge": "kill_skill_charge",
    "kill_damage": "kill_damage",
    "kill_radius": "kill_radius",
    "kill_duration": "kill_duration",
    "kill_slow": "kill_slow_multiplier",
    "kill_speed": "kill_move_speed_multiplier",
}

CONFIG_FIELD_ORDER = [
    "collectible_design_id",
    "collectible_design_note",
    "collectible_stacks_by_copy",
    "collectible_max_copies",
    "requires_projectile_primary_attack",
    "requires_ammunition",
    "bullet_pierce_chance",
    "collectible_ammo_capacity_additive_bonus",
    "collectible_ammo_capacity_bonus_ratio",
    "collectible_reload_time_reduction",
    "collectible_attack_bonus",
    "collectible_max_health_bonus",
    "collectible_move_speed_bonus",
    "collectible_attack_speed_bonus",
    "collectible_physical_defense_bonus",
    "collectible_magic_defense_bonus",
    "collectible_physical_damage_bonus",
    "collectible_magic_damage_bonus",
    "collectible_skill_charge_bonus_per_second",
    "base_upgrade_free_chance",
    "incoming_ranged_front_damage_multiplier",
    "incoming_ranged_back_damage_multiplier",
    "incoming_ranged_dodge_chance",
    "attack_speed_xirang_step",
    "attack_speed_bonus_per_xirang_step",
    "defense_xirang_step",
    "defense_bonus_per_xirang_step",
    "periodic_effect_id",
    "periodic_interval",
    "periodic_radius",
    "periodic_damage",
    "periodic_attack_damage_multiplier",
    "periodic_target_count",
    "periodic_heal",
    "periodic_slow_multiplier",
    "periodic_slow_duration",
    "skill_effect_id",
    "skill_effect_radius",
    "skill_effect_duration",
    "skill_move_speed_multiplier",
    "conditional_effect_id",
    "conditional_health_ratio_threshold",
    "conditional_xirang_threshold",
    "conditional_attack_bonus",
    "conditional_max_health_bonus",
    "conditional_move_speed_bonus",
    "conditional_physical_defense_bonus",
    "conditional_magic_defense_bonus",
    "conditional_physical_damage_bonus",
    "conditional_magic_damage_bonus",
    "conditional_skill_charge_bonus_per_second",
    "conditional_bullet_pierce_chance",
    "trigger_effect_id",
    "trigger_shot_interval",
    "trigger_cooldown",
    "trigger_damage",
    "trigger_radius",
    "trigger_heal",
    "trigger_xirang",
    "trigger_skill_charge",
    "trigger_slow_multiplier",
    "trigger_slow_duration",
    "on_hit_effect_id",
    "on_hit_chance",
    "on_hit_cooldown",
    "on_hit_damage",
    "on_hit_duration",
    "on_hit_tick_interval",
    "on_hit_radius",
    "on_hit_heal",
    "on_hit_xirang",
    "on_hit_skill_charge",
    "on_hit_slow_multiplier",
    "on_hit_physical_defense_modifier",
    "on_hit_damage_taken_multiplier",
    "on_hit_execute_health_ratio",
    "kill_effect_id",
    "kill_cooldown",
    "kill_heal",
    "kill_xirang",
    "kill_skill_charge",
    "kill_damage",
    "kill_radius",
    "kill_duration",
    "kill_slow_multiplier",
    "kill_move_speed_multiplier",
]

EXISTING_RARITIES = {
    "collectible_apple.tres": EPIC,
    "collectible_ruby.tres": COMMON,
    "collectible_emerald.tres": COMMON,
    "collectible_topaz.tres": COMMON,
    "collectible_gray_gem.tres": COMMON,
    "collectible_amethyst.tres": RARE,
    "collectible_power_ring.tres": RARE,
    "collectible_life_ring.tres": RARE,
    "collectible_speed_ring.tres": RARE,
    "collectible_physical_ring.tres": RARE,
    "collectible_magic_ring.tres": RARE,
    "collectible_charged_jade_pendant.tres": RARE,
    "collectible_lucky_gem.tres": RARE,
    "collectible_medieval_shield.tres": RARE,
    "collectible_gold_wine_cup.tres": LEGENDARY,
    "collectible_tianshi_stake.tres": EPIC,
    "collectible_moon_amulet.tres": EPIC,
    "collectible_thunder_crystal.tres": EPIC,
    "collectible_frost_crystal.tres": EPIC,
    "collectible_life_crystal.tres": EPIC,
    "collectible_swift_crystal.tres": EPIC,
    "collectible_archer.tres": EPIC,
    "collectible_admin_doll.tres": LEGENDARY,
    "collectible_nine_eleven.tres": LEGENDARY,
}

EXISTING_BALANCE_OVERRIDES: dict[str, dict[str, Any]] = {
    "collectible_gold_wine_cup.tres": {
        "description": "身上每持有1000息壤，攻击速度+5。",
        "attack_speed_xirang_step": 1000,
        "attack_speed_bonus_per_xirang_step": 5.0,
    },
    "collectible_tianshi_stake.tres": {
        "description": "身上每持有2000息壤，物理防御和法术防御各+1。",
        "defense_xirang_step": 2000,
        "defense_bonus_per_xirang_step": 1,
    },
}

DESIGN_FIELD_KEYS = (
    "collectible_design_id",
    "collectible_design_note",
    "conditional_effect_id",
    "conditional_health_ratio_threshold",
    "conditional_xirang_threshold",
    "conditional_attack_bonus",
    "conditional_max_health_bonus",
    "conditional_move_speed_bonus",
    "conditional_physical_defense_bonus",
    "conditional_magic_defense_bonus",
    "conditional_physical_damage_bonus",
    "conditional_magic_damage_bonus",
    "conditional_skill_charge_bonus_per_second",
    "conditional_bullet_pierce_chance",
    "trigger_effect_id",
    "trigger_shot_interval",
    "trigger_cooldown",
    "trigger_damage",
    "trigger_radius",
    "trigger_heal",
    "trigger_xirang",
    "trigger_skill_charge",
    "trigger_slow_multiplier",
    "trigger_slow_duration",
    "on_hit_effect_id",
    "on_hit_chance",
    "on_hit_cooldown",
    "on_hit_damage",
    "on_hit_duration",
    "on_hit_tick_interval",
    "on_hit_radius",
    "on_hit_heal",
    "on_hit_xirang",
    "on_hit_skill_charge",
    "on_hit_slow_multiplier",
    "on_hit_physical_defense_modifier",
    "on_hit_damage_taken_multiplier",
    "on_hit_execute_health_ratio",
    "kill_effect_id",
    "kill_cooldown",
    "kill_heal",
    "kill_xirang",
    "kill_skill_charge",
    "kill_damage",
    "kill_radius",
    "kill_duration",
    "kill_slow_multiplier",
    "kill_move_speed_multiplier",
)

CONDITIONAL_BONUS_PROFILES = (
    ("conditional_attack_bonus", "攻击力", "flat"),
    ("conditional_max_health_bonus", "生命上限", "flat"),
    ("conditional_move_speed_bonus", "移动速度", "flat"),
    ("conditional_physical_defense_bonus", "物理防御", "flat"),
    ("conditional_magic_defense_bonus", "法术防御", "flat"),
    ("conditional_physical_damage_bonus", "造成物理伤害", "flat"),
    ("conditional_magic_damage_bonus", "造成法术伤害", "flat"),
    ("conditional_skill_charge_bonus_per_second", "每秒技能充能", "flat"),
    ("conditional_bullet_pierce_chance", "穿透弹概率", "percent"),
)

TRIGGER_EFFECTS = (
    "shot_heal",
    "shot_xirang",
    "shot_charge",
    "shot_thunder",
    "shot_frost",
    "hurt_heal",
    "hurt_xirang",
    "hurt_thunder",
    "hurt_frost",
    "skill_heal",
    "skill_xirang",
    "skill_charge",
    "skill_thunder",
    "skill_frost",
)


def _rarity_tier(rarity: int) -> int:
    return max(1, min(int(rarity), LEGENDARY) + 1)


def _slug_from_config_name(file_name: str) -> str:
    return file_name.removeprefix("collectible_").removesuffix(".tres")


def _condition_bonus_value(field_name: str, rarity: int, index: int) -> float | int:
    tier = _rarity_tier(rarity)
    lane = index % 4
    if field_name == "conditional_move_speed_bonus":
        return float(3 + tier * 3 + lane * 2)
    if field_name == "conditional_skill_charge_bonus_per_second":
        return round(0.12 + rarity * 0.12 + lane * 0.04, 2)
    if field_name == "conditional_bullet_pierce_chance":
        return round(0.04 + rarity * 0.03 + lane * 0.01, 2)
    if field_name == "conditional_max_health_bonus":
        return 4 + tier * 4 + lane * 2
    if field_name in {"conditional_physical_defense_bonus", "conditional_magic_defense_bonus"}:
        return 1 + rarity + (1 if lane >= 2 else 0)
    return 1 + tier + (lane % 2)


def _format_design_bonus(label: str, value: float | int, value_kind: str) -> str:
    if value_kind == "percent":
        return "%s+%s" % (label, pct(float(value)))
    return "%s+%s" % (label, num(value))


def _build_condition_design(slug: str, rarity: int, index: int) -> tuple[dict[str, Any], str]:
    fields: dict[str, Any] = {}
    condition_lane = index % 3
    if condition_lane == 0:
        threshold = round(0.28 + (index % 7) * 0.03, 2)
        fields["conditional_effect_id"] = "health_below"
        fields["conditional_health_ratio_threshold"] = threshold
        condition_text = "生命不高于%s时" % pct(threshold)
    elif condition_lane == 1:
        threshold = 180 + rarity * 220 + (index % 6) * 70
        fields["conditional_effect_id"] = "xirang_at_least"
        fields["conditional_xirang_threshold"] = threshold
        condition_text = "持有息壤不少于%s时" % num(threshold)
    else:
        fields["conditional_effect_id"] = "skill_unlocked"
        condition_text = "解锁庄方宜技能后"

    bonus_field, bonus_label, bonus_kind = CONDITIONAL_BONUS_PROFILES[
        (index + rarity) % len(CONDITIONAL_BONUS_PROFILES)
    ]
    if fields["conditional_effect_id"] == "skill_unlocked" and bonus_field == "conditional_skill_charge_bonus_per_second":
        bonus_field, bonus_label, bonus_kind = CONDITIONAL_BONUS_PROFILES[
            (index + rarity + 1) % len(CONDITIONAL_BONUS_PROFILES)
        ]
    bonus_value = _condition_bonus_value(bonus_field, rarity, index)
    fields[bonus_field] = bonus_value
    note = "%s，%s。" % (condition_text, _format_design_bonus(bonus_label, bonus_value, bonus_kind))
    fields["collectible_design_id"] = "%s_condition_%03d" % (slug, index + 1)
    fields["collectible_design_note"] = note
    return fields, note


def _build_trigger_design(slug: str, rarity: int, index: int) -> tuple[dict[str, Any], str]:
    fields: dict[str, Any] = {}
    trigger_id = TRIGGER_EFFECTS[(index * 5 + rarity) % len(TRIGGER_EFFECTS)]
    fields["trigger_effect_id"] = trigger_id

    tier = _rarity_tier(rarity)
    if trigger_id.startswith("shot_"):
        shot_interval = max(4, 16 - rarity * 3 + (index % 4))
        fields["trigger_shot_interval"] = shot_interval
        event_text = "每发射第%s颗子弹时" % num(shot_interval)
    elif trigger_id.startswith("hurt_"):
        cooldown = round(max(3.0, 12.0 - rarity * 2.0 + float(index % 3)), 1)
        fields["trigger_cooldown"] = cooldown
        event_text = "受伤后（冷却%s秒）" % num(cooldown)
    else:
        cooldown = round((index % 3) * 0.5, 1)
        if cooldown > 0.0:
            fields["trigger_cooldown"] = cooldown
        event_text = "使用庄方宜技能时"

    effect_text = ""
    if trigger_id.endswith("_heal"):
        heal = tier + 1 + (index % 3)
        fields["trigger_heal"] = heal
        effect_text = "回复%s点生命" % num(heal)
    elif trigger_id.endswith("_xirang"):
        xirang = tier * 2 + (index % 5)
        fields["trigger_xirang"] = xirang
        effect_text = "获得%s点息壤" % num(xirang)
    elif trigger_id.endswith("_charge"):
        charge = round(0.25 + rarity * 0.2 + (index % 4) * 0.08, 2)
        fields["trigger_skill_charge"] = charge
        effect_text = "补充%s秒技能充能" % num(charge)
    elif trigger_id.endswith("_thunder"):
        damage = 8 + tier * 6 + (index % 6) * 2
        radius = float(20 + tier * 8 + (index % 4) * 4)
        fields["trigger_damage"] = damage
        fields["trigger_radius"] = radius
        effect_text = (
            "优先在自身周围%s范围内随机选择敌人落雷，附近无目标时改选全场，"
            "半径%s内造成%s点法术伤害"
            % (num(THUNDER_LOCAL_TARGET_RADIUS), num(radius), num(damage))
        )
    elif trigger_id.endswith("_frost"):
        damage = 5 + tier * 4 + (index % 5)
        radius = float(24 + tier * 8 + (index % 4) * 4)
        slow = round(max(0.45, 0.84 - rarity * 0.07 - (index % 3) * 0.03), 2)
        slow_duration = round(0.8 + tier * 0.25 + (index % 3) * 0.2, 1)
        fields["trigger_damage"] = damage
        fields["trigger_radius"] = radius
        fields["trigger_slow_multiplier"] = slow
        fields["trigger_slow_duration"] = slow_duration
        effect_text = "释放半径%s的寒霜，造成%s点法术伤害并减速至%s，持续%s秒" % (
            num(radius),
            num(damage),
            pct(slow),
            num(slow_duration),
        )

    note = "%s，%s。" % (event_text, effect_text)
    fields["collectible_design_id"] = "%s_trigger_%03d" % (slug, index + 1)
    fields["collectible_design_note"] = note
    return fields, note


def build_unique_design(slug: str, rarity: int, index: int) -> dict[str, Any]:
    if index % 4 == 1:
        fields, _note = _build_condition_design(slug, rarity, index)
    else:
        fields, _note = _build_trigger_design(slug, rarity, index)
    return fields


def apply_unique_design(config: dict[str, Any], index: int) -> None:
    config["fields"].update(build_unique_design(config["slug"], config["rarity"], index))


def design(slug: str, role: str, description: str, **fields: Any) -> dict[str, Any]:
    resolved: dict[str, Any] = {}
    for key, value in fields.items():
        resolved[FIELD_ALIASES.get(key, key)] = value
    resolved["collectible_design_id"] = slug
    resolved["collectible_design_note"] = "%s：%s" % (role, description)
    return {
        "slug": slug,
        "role": role,
        "description": description,
        "fields": resolved,
    }


DESIGN_ROWS = [
    design("copper_sword", "基础攻击", "攻击力+1。", stack=True, attack=1),
    design("iron_dagger", "流血命中", "普通子弹有概率造成短时流血。", hit="bleed", hit_chance=0.18, hit_damage=1, hit_duration=2.0, hit_tick=0.5),
    design("chipped_ruby", "火星命中", "普通子弹有概率施加每秒5点伤害的燃烧，持续稍久。", hit="burn", hit_chance=0.14, hit_damage=5, hit_duration=2.2, hit_tick=1.0),
    design("moss_agate", "生命上限", "生命上限+8。", stack=True, health=8),
    design("pebble_shield", "物理防御", "物理防御+1。", stack=True, pdef=1),
    design("blue_quartz", "技能充能", "每秒技能充能+0.15。", stack=True, charge=0.15),
    design("quick_feather", "移动速度", "移动速度+6。", stack=True, move=6.0),
    design("warm_bread", "击杀回血", "击败敌人时回复2点生命。", kill="heal", kill_heal=2, kill_cd=0.5),
    design("campfire_coal", "灼烧命中", "普通子弹有概率造成每秒10点伤害的灼烧。", hit="burn", hit_chance=0.16, hit_damage=10, hit_duration=2.4, hit_tick=1.0),
    design("fox_coin", "免费升级", "升级基础属性时有5%概率不消耗息壤。", free=0.05),
    design("tiny_bell", "击杀充能", "击败敌人时补充0.2秒技能充能。", kill="charge", kill_charge=0.2, kill_cd=0.6),
    design("herbal_bundle", "命中治疗花", "普通子弹有概率在命中位置治疗附近友方。", hit="bloom", hit_chance=0.12, hit_radius=36.0, hit_heal=3, hit_cd=1.0),
    design("clay_totem", "低血护体", "生命不高于40%时，物理防御+2。", condition="health_below", hp_threshold=0.4, c_pdef=2),
    design("wooden_buckler", "远程闪避", "受到远程攻击时，额外有5%概率闪避。", dodge=0.05),
    design("candle_stub", "烛火命中", "普通子弹有概率附着每秒5点伤害的短火。", hit="burn", hit_chance=0.12, hit_damage=5, hit_duration=1.5, hit_tick=1.0),
    design("apprentice_scroll", "技能充能", "每秒技能充能+0.2。", stack=True, charge=0.2),
    design("tin_ring", "轻巧步伐", "移动速度+3。", stack=True, move=3.0),
    design("river_shell", "法术防御", "法术防御+1。", stack=True, mdef=1),
    design("salt_charm", "易伤标记", "普通子弹有概率标记敌人，使其短时承受更多伤害。", hit="mark", hit_chance=0.12, hit_duration=1.8, hit_taken=1.1),
    design("rusty_helm", "物理防御", "物理防御+2。", stack=True, pdef=2),
    design(
        "glass_marble",
        "穿透弹",
        "普通子弹有6%概率变为穿透弹。",
        pierce=0.06,
        requires_projectile=True,
    ),
    design("oil_lamp", "油火命中", "普通子弹有概率造成每秒15点伤害的油火灼烧。", hit="burn", hit_chance=0.14, hit_damage=15, hit_duration=2.6, hit_tick=1.0),
    design("goat_horn", "低血处决", "普通子弹有概率处决生命值3%以内的非Boss敌人。", hit="execute", hit_chance=0.14, hit_execute=0.03, hit_cd=0.8),
    design("pocket_anvil", "破甲命中", "普通子弹有概率短暂降低敌人物防。", hit="crack", hit_chance=0.13, hit_duration=2.0, hit_pdef_mod=-2),
    design("leaf_cloak", "击杀加速", "击败敌人后短暂加速。", kill="haste", kill_duration=1.0, kill_speed=1.16, kill_cd=0.8),
    design("bone_needle", "流血命中", "普通子弹有概率造成更久流血。", hit="bleed", hit_chance=0.16, hit_damage=1, hit_duration=2.2, hit_tick=0.5),
    design("blue_mushroom", "寒冷命中", "普通子弹有概率减速敌人。", hit="chill", hit_chance=0.12, hit_duration=1.5, hit_slow=0.78),
    design("red_mushroom", "命中吸血", "普通子弹有概率治疗自己。", hit="leech", hit_chance=0.1, hit_heal=2, hit_cd=0.8),
    design("topaz_chip", "移动速度", "移动速度+7。", stack=True, move=7.0),
    design("tarnished_medal", "击杀息壤", "击败敌人时获得3点息壤。", kill="xirang", kill_xirang=3, kill_cd=0.5),
    design("training_arrow", "易伤标记", "普通子弹有概率标记敌人。", hit="mark", hit_chance=0.12, hit_duration=1.6, hit_taken=1.1),
    design("wool_charm", "受伤回血", "受伤后回复4点生命，有冷却。", trigger="hurt_heal", cooldown=10.0, t_heal=4),
    design("rain_bead", "雨气缓速", "普通子弹有概率让敌人被雨气减速。", hit="chill", hit_chance=0.14, hit_duration=1.4, hit_slow=0.76),
    design("copper_gear", "息壤攻速", "每持有600息壤，攻击速度+1。", atk_step=600, atk_step_bonus=1.0),
    design("ember_leaf", "灰叶火种", "普通子弹有概率施加每秒10点伤害的短燃烧。", hit="burn", hit_chance=0.12, hit_damage=10, hit_duration=1.6, hit_tick=1.0),
    design("stone_tablet", "息壤防御", "每持有2500息壤，物理防御和法术防御各+1。", def_step=2500, def_step_bonus=1),
    design("steel_longsword", "基础攻击", "攻击力+4。", stack=True, attack=4),
    design("hunters_bow", "周期射箭", "每12秒向近处2名敌人射箭。", periodic="archer", interval=12.0, radius=280.0, multiplier=1.2, targets=2),
    design("sapphire_ring", "寒冷命中", "普通子弹有概率施加寒冷。", hit="chill", hit_chance=0.16, hit_duration=1.8, hit_slow=0.7),
    design("guardian_badge", "受伤反击", "受伤后小范围反击落雷。", trigger="hurt_thunder", cooldown=8.0, t_damage=16, t_radius=36.0),
    design("swift_boot", "移动速度", "移动速度+18。", stack=True, move=18.0),
    design("alchemist_vial", "免费升级", "升级基础属性时有8%概率不消耗息壤。", free=0.08),
    design(
        "prism_lens",
        "穿透弹",
        "普通子弹有15%概率变为穿透弹。",
        pierce=0.15,
        requires_projectile=True,
    ),
    design("thorn_shield", "荆棘反击", "受伤后释放一次小范围反击。", trigger="hurt_thunder", cooldown=7.0, t_damage=18, t_radius=42.0),
    design("frost_totem", "周期寒霜", "每13秒释放寒霜，伤害并减速范围内敌人。", periodic="frost", interval=13.0, radius=56.0, damage=8, slow=0.65, slow_duration=1.5),
    design("spark_bottle", "周期落雷", "每16秒引落闪电。", periodic="thunder", interval=16.0, radius=32.0, damage=32),
    design("moon_pin", "技能月盾", "使用技能时生成小月盾。", skill="moon_shield", skill_radius=48.0, skill_duration=4.0),
    design("wind_charm", "技能疾行", "使用技能后短暂提速。", skill="swift", skill_duration=3.0, skill_speed=1.2),
    design("gold_apple", "击杀回血", "击败敌人时回复7点生命。", kill="heal", kill_heal=7, kill_cd=0.8),
    design("ruby_crown", "攻势强化", "攻击力+4，攻击速度+10。", stack=True, attack=4, attack_speed=10.0),
    design("runed_book", "技能充能", "每秒技能充能+0.5。", stack=True, charge=0.5),
    design("crystal_compass", "命中息壤", "普通子弹有概率从目标身上定位息壤。", hit="xirang", hit_chance=0.14, hit_xirang=4, hit_cd=0.7),
    design("ironwood_seed", "生命上限", "生命上限+25。", stack=True, health=25),
    design("echo_drum", "息壤攻速", "每持有800息壤，攻击速度+1。", atk_step=800, atk_step_bonus=1.0),
    design("silver_mask", "背面减伤", "受到背面远程伤害变为75%。", back=0.75),
    design("battle_standard", "击杀加速", "击败敌人后短暂提速推进。", kill="haste", kill_duration=1.3, kill_speed=1.2, kill_cd=0.7),
    design("heavy_gauntlet", "物理伤害", "造成物理伤害+2。", stack=True, pdamage=2),
    design("jade_fish", "击杀充能", "击败敌人时补充0.35秒技能充能。", kill="charge", kill_charge=0.35, kill_cd=0.7),
    design("sun_brooch", "周期治疗", "每18秒治疗附近友方。", periodic="heal", interval=18.0, radius=56.0, heal=8),
    design("obsidian_key", "低血处决", "普通子弹有概率处决低生命非Boss敌人。", hit="execute", hit_chance=0.16, hit_execute=0.16, hit_cd=0.8),
    design("dragon_heart", "击杀爆裂", "击败敌人时在其位置引发火焰爆裂。", kill="burst", kill_damage=18, kill_radius=48.0, kill_cd=0.6),
    design("storm_core", "周期落雷", "每9秒引落强闪电。", periodic="thunder", interval=9.0, radius=48.0, damage=55),
    design("glacier_orb", "周期寒霜", "每10秒释放大范围寒霜。", periodic="frost", interval=10.0, radius=72.0, damage=16, slow=0.5, slow_duration=2.5),
    design("phoenix_feather", "周期治疗", "每15秒治疗附近友方。", periodic="heal", interval=15.0, radius=72.0, heal=14),
    design("mirror_shield", "受伤寒霜", "受伤后释放反射寒霜。", trigger="hurt_frost", cooldown=6.0, t_damage=18, t_radius=58.0, t_slow=0.58, t_slow_duration=1.8),
    design("eclipse_amulet", "技能月盾", "使用技能时生成较大的月盾。", skill="moon_shield", skill_radius=72.0, skill_duration=8.0),
    design("blink_crystal", "技能疾行", "使用技能后强力加速。", skill="swift", skill_duration=4.0, skill_speed=1.45),
    design("royal_goblet", "息壤攻速", "每持有1000息壤，攻击速度+2。", atk_step=1000, atk_step_bonus=2.0),
    design("titan_helm", "生命上限", "生命上限+35。", health=35),
    design("spellblade", "易伤标记", "普通子弹有概率施加更强易伤标记。", hit="mark", hit_chance=0.2, hit_duration=2.5, hit_taken=1.18),
    design("celestial_ring", "击杀充能", "击败敌人时补充0.55秒技能充能。", kill="charge", kill_charge=0.55, kill_cd=0.6),
    design("archer_sigil", "周期箭雨", "每7秒向最多4名敌人射箭。", periodic="archer", interval=7.0, radius=420.0, multiplier=2.0, targets=4),
    design("philosopher_stone", "免费升级", "升级基础属性时有25%概率不消耗息壤。", free=0.25),
    design("thunder_crown", "技能落雷", "使用技能时追加一道落雷。", trigger="skill_thunder", t_damage=32, t_radius=58.0),
    design("world_seed", "周期治疗", "每12秒治疗大范围友方。", periodic="heal", interval=12.0, radius=96.0, heal=20),
    design("void_crown", "虚空处决", "普通子弹有概率处决低生命非Boss敌人。", hit="execute", hit_chance=0.22, hit_execute=0.22, hit_cd=0.6),
    design("sun_moon_relic", "技能月盾", "使用技能时生成强月盾。", skill="moon_shield", skill_radius=96.0, skill_duration=10.0),
    design("kingslayer_blade", "弑王处决", "普通子弹有概率强力处决低生命非Boss敌人。", hit="execute", hit_chance=0.24, hit_execute=0.28, hit_cd=0.5),
    design("oracle_cube", "先知标记", "普通子弹有概率施加高额易伤标记。", hit="mark", hit_chance=0.24, hit_duration=3.0, hit_taken=1.22),
    design("thunder_god_idol", "周期神雷", "每6秒引落高伤害闪电。", periodic="thunder", interval=6.0, radius=72.0, damage=75),
]

DESIGN_SPECS = {row["slug"]: row for row in DESIGN_ROWS}


def get_design_spec(slug: str) -> dict[str, Any]:
    if slug not in DESIGN_SPECS:
        raise RuntimeError("Missing collectible redesign spec for %s" % slug)
    return DESIGN_SPECS[slug]


def item(slug: str, name: str, rarity: int, icon: str, palette: str, *, stack: bool = False, **fields: Any) -> dict[str, Any]:
    resolved: dict[str, Any] = {}
    for key, value in fields.items():
        resolved[FIELD_ALIASES.get(key, key)] = value
    if stack:
        resolved["collectible_stacks_by_copy"] = True
    return {
        "slug": slug,
        "name": name,
        "rarity": rarity,
        "icon": icon,
        "palette": palette,
        "fields": resolved,
    }


ITEMS = [
    item("copper_sword", "铜短剑", COMMON, "sword", "orange", stack=True, attack=1),
    item("iron_dagger", "铁匕首", COMMON, "dagger", "silver", stack=True, pdamage=1),
    item("chipped_ruby", "裂纹红玉", COMMON, "gem", "red", stack=True, attack=2),
    item("moss_agate", "苔纹玛瑙", COMMON, "gem", "green", stack=True, health=8),
    item("pebble_shield", "卵石小盾", COMMON, "shield", "silver", stack=True, pdef=1, dodge=0.04),
    item("blue_quartz", "蓝石英", COMMON, "crystal", "blue", stack=True, mdef=1, charge=0.1),
    item("quick_feather", "轻羽", COMMON, "feather", "cyan", stack=True, move=6.0),
    item("warm_bread", "烤面包", COMMON, "bread", "brown", stack=True, health=6),
    item("campfire_coal", "篝火余烬", RARE, "coal", "orange", stack=True, attack=1, mdamage=1),
    item("fox_coin", "狐纹铜币", COMMON, "coin", "gold", free=0.05),
    item("tiny_bell", "小铃铛", COMMON, "bell", "gold", stack=True, charge=0.15),
    item("herbal_bundle", "草药束", COMMON, "herb", "leaf", stack=True, health=7),
    item("clay_totem", "陶土小像", COMMON, "totem", "brown", stack=True, health=4, pdef=1),
    item("wooden_buckler", "木圆盾", COMMON, "shield", "brown", dodge=0.05),
    item("candle_stub", "蜡烛头", COMMON, "candle", "yellow", stack=True, mdamage=1),
    item("apprentice_scroll", "学徒卷轴", COMMON, "scroll", "brown", stack=True, charge=0.2),
    item("tin_ring", "锡戒指", COMMON, "ring", "silver", stack=True, attack=1, move=3.0),
    item("river_shell", "河贝壳", COMMON, "shell", "cyan", stack=True, health=4, mdef=1),
    item("salt_charm", "盐晶符", COMMON, "charm", "silver", stack=True, health=5, mdef=1),
    item("rusty_helm", "生锈头盔", COMMON, "helmet", "orange", stack=True, health=5, pdef=1),
    item("glass_marble", "玻璃弹珠", COMMON, "marble", "cyan", pierce=0.06),
    item("oil_lamp", "油灯", RARE, "lamp", "yellow", stack=True, mdamage=1, charge=0.1),
    item("goat_horn", "山羊角", COMMON, "horn", "brown", stack=True, attack=2, pdamage=1),
    item("pocket_anvil", "口袋铁砧", COMMON, "anvil", "silver", stack=True, pdamage=1, pdef=2),
    item("leaf_cloak", "叶片披风", COMMON, "cloak", "leaf", move=5.0, dodge=0.03),
    item("bone_needle", "骨针", COMMON, "needle", "silver", pierce=0.08),
    item("blue_mushroom", "蓝蘑菇", COMMON, "mushroom", "blue", stack=True, health=8, mdef=1),
    item("red_mushroom", "红蘑菇", COMMON, "mushroom", "red", stack=True, attack=2, health=4),
    item("topaz_chip", "黄玉碎片", COMMON, "gem", "yellow", stack=True, move=7.0),
    item("tarnished_medal", "旧勋章", COMMON, "medal", "brown", stack=True, attack=1, pdef=1),
    item("training_arrow", "练习箭", COMMON, "arrow", "brown", stack=True, attack=1, pdamage=1),
    item("wool_charm", "羊毛护符", COMMON, "charm", "silver", stack=True, health=10, mdef=1),
    item("rain_bead", "雨珠", COMMON, "marble", "blue", stack=True, health=3, charge=0.25),
    item("copper_gear", "铜齿轮", COMMON, "gear", "orange", atk_step=600, atk_step_bonus=1.0),
    item("ember_leaf", "余烬叶", COMMON, "leaf", "orange", stack=True, mdamage=1, health=4),
    item("stone_tablet", "石刻片", COMMON, "tablet", "silver", def_step=2500, def_step_bonus=1),
    item("steel_longsword", "钢长剑", RARE, "sword", "silver", stack=True, attack=4),
    item("hunters_bow", "猎人短弓", RARE, "bow", "brown", periodic="archer", interval=12.0, radius=280.0, multiplier=1.2, targets=2),
    item("sapphire_ring", "蓝宝石戒指", RARE, "ring", "blue", stack=True, mdef=2, mdamage=1),
    item("guardian_badge", "守卫徽章", RARE, "badge", "silver", stack=True, pdef=2, health=12),
    item("swift_boot", "疾行靴", RARE, "boots", "brown", stack=True, move=18.0),
    item("alchemist_vial", "炼金小瓶", RARE, "vial", "green", stack=True, charge=0.4, free=0.06),
    item("prism_lens", "棱镜镜片", RARE, "lens", "cyan", pierce=0.15),
    item("thorn_shield", "荆棘盾", RARE, "shield", "leaf", dodge=0.12),
    item("frost_totem", "寒霜图腾", RARE, "totem", "blue", periodic="frost", interval=13.0, radius=56.0, damage=8, slow=0.65, slow_duration=1.5),
    item("spark_bottle", "电火瓶", RARE, "bottle", "yellow", periodic="thunder", interval=16.0, radius=32.0, damage=32),
    item("moon_pin", "月纹胸针", RARE, "pin", "blue", skill="moon_shield", skill_radius=48.0, skill_duration=4.0),
    item("wind_charm", "风行符", RARE, "charm", "cyan", skill="swift", skill_duration=3.0, skill_speed=1.2),
    item("gold_apple", "金苹果", RARE, "apple", "gold", health=12, pierce=0.15),
    item("ruby_crown", "红玉小冠", RARE, "crown", "red", stack=True, attack=4, attack_speed=10.0),
    item("runed_book", "符文书", RARE, "book", "purple", stack=True, mdamage=2, charge=0.4),
    item("crystal_compass", "水晶罗盘", RARE, "compass", "cyan", free=0.1),
    item("ironwood_seed", "铁木种子", RARE, "seed", "leaf", stack=True, health=25),
    item("echo_drum", "回声小鼓", RARE, "drum", "brown", atk_step=800, atk_step_bonus=1.0),
    item("silver_mask", "银面具", RARE, "mask", "silver", back=0.75),
    item("battle_standard", "战旗", RARE, "standard", "red", stack=True, attack=3, pdamage=1),
    item("heavy_gauntlet", "重拳套", RARE, "gauntlet", "silver", stack=True, pdamage=2, pdef=1),
    item("jade_fish", "玉鱼", RARE, "fish", "green", stack=True, charge=0.6),
    item("sun_brooch", "日纹胸针", RARE, "brooch", "yellow", periodic="heal", interval=18.0, radius=56.0, heal=8),
    item("obsidian_key", "黑曜钥匙", RARE, "key", "void", mdef=2, dodge=0.08),
    item("dragon_heart", "龙心", EPIC, "heart", "red", attack=8, health=30),
    item("storm_core", "风暴核心", EPIC, "orb", "yellow", periodic="thunder", interval=9.0, radius=48.0, damage=55),
    item("glacier_orb", "冰川宝珠", EPIC, "orb", "cyan", periodic="frost", interval=10.0, radius=72.0, damage=16, slow=0.5, slow_duration=2.5),
    item("phoenix_feather", "凤凰羽", EPIC, "feather", "orange", move=10.0, periodic="heal", interval=15.0, radius=72.0, heal=14),
    item("mirror_shield", "镜面盾", EPIC, "shield", "silver", dodge=0.25, back=0.6),
    item("eclipse_amulet", "蚀月护符", EPIC, "amulet", "purple", mdef=2, skill="moon_shield", skill_radius=72.0, skill_duration=8.0),
    item("blink_crystal", "闪现水晶", EPIC, "crystal", "cyan", skill="swift", skill_duration=4.0, skill_speed=1.45),
    item("royal_goblet", "王家圣杯", EPIC, "goblet", "gold", atk_step=1000, atk_step_bonus=2.0),
    item("titan_helm", "泰坦头盔", EPIC, "helmet", "silver", pdef=4, health=35),
    item("spellblade", "咒刃", EPIC, "spellblade", "purple", attack=6, mdamage=3),
    item("celestial_ring", "星界戒指", EPIC, "ring", "purple", mdef=2, charge=1.0),
    item("archer_sigil", "神射徽记", EPIC, "sigil", "green", periodic="archer", interval=7.0, radius=420.0, multiplier=2.0, targets=4),
    item("philosopher_stone", "贤者石", EPIC, "stone", "red", health=15, free=0.25),
    item("thunder_crown", "雷冠", EPIC, "crown", "yellow", mdamage=4, periodic="thunder", interval=12.0, radius=64.0, damage=35),
    item("world_seed", "世界树种", LEGENDARY, "seed", "leaf", health=80, periodic="heal", interval=12.0, radius=96.0, heal=20),
    item("void_crown", "虚空王冠", LEGENDARY, "crown", "void", attack=12, mdamage=6, charge=1.0),
    item("sun_moon_relic", "日月遗物", LEGENDARY, "relic", "gold", mdef=4, skill="moon_shield", skill_radius=96.0, skill_duration=10.0),
    item("kingslayer_blade", "弑王刃", LEGENDARY, "blade", "red", attack=10, pdamage=8, pierce=0.25),
    item("oracle_cube", "先知方块", LEGENDARY, "cube", "cyan", charge=1.5, free=0.35),
    item("thunder_god_idol", "雷神像", LEGENDARY, "idol", "yellow", periodic="thunder", interval=6.0, radius=72.0, damage=75),
]


def rect(draw: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], fill: tuple[int, int, int, int], outline: tuple[int, int, int, int] = OUTLINE, width: int = 2) -> None:
    draw.rectangle(xy, fill=fill, outline=outline, width=width)


def poly(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], fill: tuple[int, int, int, int], outline: tuple[int, int, int, int] = OUTLINE) -> None:
    draw.polygon(points, fill=fill)
    draw.line(points + [points[0]], fill=outline, width=2, joint="curve")


def line(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], fill: tuple[int, int, int, int], width: int = 2) -> None:
    draw.line(points, fill=fill, width=width)


def sparkle(draw: ImageDraw.ImageDraw, x: int, y: int, color: tuple[int, int, int, int]) -> None:
    draw.point((x, y), fill=color)
    draw.point((x - 1, y), fill=color)
    draw.point((x + 1, y), fill=color)
    draw.point((x, y - 1), fill=color)
    draw.point((x, y + 1), fill=color)


def add_rarity_spark(draw: ImageDraw.ImageDraw, rarity: int) -> None:
    if rarity == COMMON:
        return
    color = RARITY_SPARK[rarity]
    sparkle(draw, 26, 5, color)
    if rarity >= EPIC:
        sparkle(draw, 5, 25, color)
    if rarity >= LEGENDARY:
        sparkle(draw, 27, 25, color)


def draw_gem(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(16, 3), (26, 12), (22, 28), (10, 28), (6, 12)], p["primary"])
    poly(draw, [(16, 5), (22, 12), (16, 15), (10, 12)], p["light"], p["dark"])
    line(draw, [(16, 6), (16, 27)], p["dark"], 1)
    line(draw, [(9, 13), (16, 27), (23, 13)], p["dark"], 1)
    sparkle(draw, 11, 10, WHITE)


def draw_crystal(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(15, 3), (22, 10), (20, 28), (12, 28), (10, 10)], p["primary"])
    poly(draw, [(6, 13), (12, 9), (13, 28), (5, 27)], p["dark"])
    poly(draw, [(21, 13), (27, 17), (25, 28), (19, 28)], p["light"])
    line(draw, [(15, 5), (16, 27)], p["light"], 1)
    sparkle(draw, 13, 8, WHITE)


def draw_ring(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((6, 9, 26, 28), outline=OUTLINE, width=4)
    draw.ellipse((8, 11, 24, 26), outline=p["metal"], width=3)
    rect(draw, (12, 4, 20, 12), p["primary"], OUTLINE, 2)
    rect(draw, (14, 6, 17, 9), p["light"], p["light"], 1)


def draw_sword(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]], heavy: bool = False) -> None:
    poly(draw, [(16, 2), (22, 7), (18, 22), (14, 22), (10, 7)], p["metal"])
    line(draw, [(16, 4), (16, 21)], p["light"], 1)
    rect(draw, (8, 21, 24, 24), p["accent"], OUTLINE, 2)
    rect(draw, (14, 23, 18, 30), p["primary"], OUTLINE, 2)
    if heavy:
        rect(draw, (12, 26, 20, 30), p["dark"], OUTLINE, 1)


def draw_dagger(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(18, 3), (23, 8), (14, 22), (10, 18)], p["metal"])
    line(draw, [(18, 6), (13, 19)], p["light"], 1)
    rect(draw, (8, 20, 18, 23), p["accent"], OUTLINE, 2)
    rect(draw, (6, 22, 12, 29), p["primary"], OUTLINE, 2)


def draw_shield(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(16, 3), (26, 8), (24, 22), (16, 29), (8, 22), (6, 8)], p["primary"])
    poly(draw, [(16, 6), (23, 10), (21, 21), (16, 26)], p["light"], p["dark"])
    line(draw, [(16, 5), (16, 27)], OUTLINE_SOFT, 1)
    rect(draw, (12, 12, 20, 18), p["accent"], OUTLINE, 1)


def draw_bread(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((5, 10, 27, 25), fill=p["primary"], outline=OUTLINE, width=2)
    rect(draw, (7, 17, 25, 25), p["primary"], OUTLINE, 2)
    line(draw, [(11, 13), (10, 18)], p["light"], 2)
    line(draw, [(17, 12), (16, 18)], p["light"], 2)


def draw_coal(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(9, 11), (17, 6), (25, 13), (22, 25), (11, 27), (5, 19)], p["dark"])
    rect(draw, (13, 12, 19, 18), p["primary"], OUTLINE_SOFT, 1)
    rect(draw, (16, 16, 22, 22), p["light"], OUTLINE_SOFT, 1)


def draw_coin(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((6, 6, 26, 26), fill=p["primary"], outline=OUTLINE, width=2)
    draw.ellipse((10, 10, 22, 22), outline=p["dark"], width=2)
    line(draw, [(16, 9), (16, 23)], p["light"], 2)
    line(draw, [(11, 16), (21, 16)], p["light"], 1)


def draw_bell(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (13, 5, 19, 9), p["accent"], OUTLINE, 1)
    poly(draw, [(10, 9), (22, 9), (25, 23), (7, 23)], p["primary"])
    rect(draw, (9, 23, 23, 26), p["dark"], OUTLINE, 1)
    rect(draw, (14, 26, 18, 29), p["accent"], OUTLINE, 1)
    sparkle(draw, 13, 12, WHITE)


def draw_herb(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    line(draw, [(16, 28), (16, 9)], p["metal"], 2)
    for points in [
        [(15, 19), (7, 13), (8, 22)],
        [(17, 17), (26, 10), (24, 21)],
        [(15, 12), (10, 5), (9, 14)],
        [(17, 11), (22, 4), (23, 14)],
    ]:
        poly(draw, points, p["primary"], p["dark"])
    sparkle(draw, 22, 9, p["light"])


def draw_feather(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    line(draw, [(9, 27), (23, 5)], OUTLINE, 3)
    line(draw, [(10, 26), (22, 6)], p["dark"], 1)
    poly(draw, [(13, 19), (7, 17), (12, 12), (20, 6)], p["primary"], p["dark"])
    poly(draw, [(14, 20), (21, 22), (23, 15), (20, 6)], p["light"], p["dark"])
    line(draw, [(12, 22), (17, 20)], p["accent"], 1)


def draw_totem(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (10, 4, 22, 28), p["primary"], OUTLINE, 2)
    rect(draw, (8, 13, 24, 18), p["dark"], OUTLINE, 1)
    rect(draw, (12, 8, 15, 11), p["accent"], OUTLINE, 1)
    rect(draw, (17, 8, 20, 11), p["accent"], OUTLINE, 1)
    line(draw, [(13, 23), (19, 23)], OUTLINE, 1)


def draw_candle(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(16, 3), (20, 9), (16, 13), (12, 9)], p["accent"])
    rect(draw, (11, 12, 21, 28), p["light"], OUTLINE, 2)
    rect(draw, (12, 23, 20, 28), p["primary"], OUTLINE, 1)
    line(draw, [(16, 12), (16, 16)], OUTLINE_SOFT, 1)


def draw_scroll(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (8, 7, 24, 25), (225, 198, 141, 255), OUTLINE, 2)
    rect(draw, (6, 5, 13, 10), p["primary"], OUTLINE, 1)
    rect(draw, (19, 22, 26, 27), p["primary"], OUTLINE, 1)
    line(draw, [(11, 13), (21, 13)], p["dark"], 1)
    line(draw, [(11, 17), (20, 17)], p["dark"], 1)


def draw_shell(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(16, 5), (25, 12), (24, 25), (8, 25), (7, 12)], p["primary"])
    for x in [10, 14, 18, 22]:
        line(draw, [(16, 6), (x, 24)], p["light"], 1)
    line(draw, [(8, 25), (24, 25)], OUTLINE, 2)


def draw_charm(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (11, 6, 21, 10), p["metal"], OUTLINE, 1)
    poly(draw, [(16, 9), (24, 16), (21, 27), (11, 27), (8, 16)], p["primary"])
    rect(draw, (13, 15, 19, 21), p["accent"], OUTLINE, 1)
    sparkle(draw, 12, 14, WHITE)


def draw_helmet(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((6, 5, 26, 23), fill=p["primary"], outline=OUTLINE, width=2)
    rect(draw, (7, 15, 25, 24), p["primary"], OUTLINE, 2)
    rect(draw, (11, 15, 21, 20), p["dark"], OUTLINE, 1)
    line(draw, [(16, 7), (16, 23)], p["light"], 1)


def draw_marble(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((7, 7, 25, 25), fill=p["primary"], outline=OUTLINE, width=2)
    draw.arc((10, 9, 24, 24), start=190, end=350, fill=p["light"], width=2)
    sparkle(draw, 12, 11, WHITE)


def draw_lamp(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (11, 10, 21, 24), p["primary"], OUTLINE, 2)
    rect(draw, (13, 6, 19, 11), p["metal"], OUTLINE, 1)
    rect(draw, (9, 23, 23, 27), p["dark"], OUTLINE, 1)
    rect(draw, (13, 13, 19, 21), p["accent"], OUTLINE_SOFT, 1)


def draw_horn(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(7, 23), (13, 10), (24, 6), (20, 15), (13, 22)], p["light"])
    line(draw, [(13, 11), (20, 15)], p["dark"], 1)
    rect(draw, (6, 22, 13, 27), p["metal"], OUTLINE, 1)


def draw_anvil(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (8, 12, 24, 20), p["primary"], OUTLINE, 2)
    poly(draw, [(19, 10), (28, 12), (24, 16), (19, 16)], p["primary"])
    rect(draw, (12, 20, 20, 25), p["dark"], OUTLINE, 1)
    rect(draw, (9, 25, 23, 28), p["primary"], OUTLINE, 1)


def draw_cloak(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(16, 5), (25, 27), (7, 27)], p["primary"])
    rect(draw, (13, 5, 19, 10), p["accent"], OUTLINE, 1)
    line(draw, [(16, 9), (14, 27)], p["dark"], 1)
    line(draw, [(16, 9), (19, 27)], p["light"], 1)


def draw_needle(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    line(draw, [(8, 25), (23, 7)], OUTLINE, 4)
    line(draw, [(9, 24), (22, 8)], p["primary"], 2)
    draw.ellipse((20, 4, 27, 11), outline=OUTLINE, width=2)
    draw.ellipse((22, 6, 25, 9), outline=p["light"], width=1)


def draw_mushroom(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.pieslice((5, 5, 27, 23), 180, 360, fill=p["primary"], outline=OUTLINE, width=2)
    rect(draw, (13, 17, 20, 28), (227, 205, 164, 255), OUTLINE, 2)
    rect(draw, (9, 13, 12, 16), p["light"], p["light"], 1)
    rect(draw, (19, 11, 22, 14), p["light"], p["light"], 1)


def draw_medal(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (11, 4, 15, 13), p["primary"], OUTLINE, 1)
    rect(draw, (17, 4, 21, 13), p["accent"], OUTLINE, 1)
    draw.ellipse((8, 11, 24, 27), fill=p["metal"], outline=OUTLINE, width=2)
    sparkle(draw, 14, 16, WHITE)


def draw_arrow(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    line(draw, [(7, 25), (23, 9)], OUTLINE, 4)
    line(draw, [(8, 24), (22, 10)], p["metal"], 2)
    poly(draw, [(22, 6), (27, 13), (20, 12)], p["primary"])
    line(draw, [(8, 24), (5, 20), (11, 22)], p["accent"], 1)


def draw_gear(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    for xy in [(14, 3, 18, 9), (14, 23, 18, 29), (3, 14, 9, 18), (23, 14, 29, 18)]:
        rect(draw, xy, p["metal"], OUTLINE, 1)
    draw.ellipse((7, 7, 25, 25), fill=p["primary"], outline=OUTLINE, width=2)
    draw.ellipse((12, 12, 20, 20), fill=BLACK_ALPHA, outline=OUTLINE, width=2)
    sparkle(draw, 11, 10, p["light"])


def draw_tablet(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (8, 5, 24, 28), p["primary"], OUTLINE, 2)
    line(draw, [(12, 11), (20, 11)], p["dark"], 1)
    line(draw, [(12, 16), (19, 16)], p["dark"], 1)
    line(draw, [(12, 21), (21, 21)], p["dark"], 1)
    sparkle(draw, 20, 8, p["light"])


def draw_bow(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.arc((7, 3, 27, 29), 75, 285, fill=OUTLINE, width=4)
    draw.arc((9, 5, 25, 27), 75, 285, fill=p["primary"], width=2)
    line(draw, [(22, 6), (22, 26)], p["light"], 1)
    line(draw, [(9, 17), (23, 14)], p["metal"], 2)


def draw_boots(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (8, 9, 15, 24), p["primary"], OUTLINE, 2)
    rect(draw, (17, 7, 24, 22), p["primary"], OUTLINE, 2)
    rect(draw, (7, 23, 17, 27), p["dark"], OUTLINE, 1)
    rect(draw, (16, 21, 27, 25), p["dark"], OUTLINE, 1)
    line(draw, [(10, 12), (14, 12)], p["light"], 1)


def draw_vial(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (13, 5, 19, 10), p["metal"], OUTLINE, 1)
    poly(draw, [(11, 10), (21, 10), (25, 26), (7, 26)], p["primary"])
    rect(draw, (9, 19, 23, 26), p["dark"], OUTLINE_SOFT, 1)
    sparkle(draw, 14, 13, WHITE)


def draw_lens(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((6, 6, 24, 24), fill=(110, 226, 244, 180), outline=OUTLINE, width=2)
    draw.ellipse((9, 9, 21, 21), outline=p["light"], width=2)
    line(draw, [(21, 21), (28, 28)], OUTLINE, 4)
    line(draw, [(22, 22), (27, 27)], p["metal"], 2)
    sparkle(draw, 12, 10, WHITE)


def draw_pin(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((8, 5, 24, 21), fill=p["primary"], outline=OUTLINE, width=2)
    poly(draw, [(16, 8), (21, 14), (16, 19), (11, 14)], p["accent"], p["dark"])
    line(draw, [(16, 21), (16, 29)], p["metal"], 2)


def draw_crown(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(6, 24), (8, 9), (14, 17), (16, 6), (20, 17), (26, 9), (26, 24)], p["metal"])
    rect(draw, (7, 21, 25, 27), p["primary"], OUTLINE, 2)
    rect(draw, (14, 18, 18, 22), p["accent"], OUTLINE, 1)
    sparkle(draw, 16, 8, WHITE)


def draw_book(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (8, 5, 24, 27), p["primary"], OUTLINE, 2)
    rect(draw, (11, 8, 21, 14), p["accent"], OUTLINE, 1)
    line(draw, [(12, 18), (21, 18)], p["light"], 1)
    line(draw, [(12, 22), (20, 22)], p["light"], 1)
    line(draw, [(8, 6), (8, 26)], p["dark"], 2)


def draw_compass(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((5, 5, 27, 27), fill=p["metal"], outline=OUTLINE, width=2)
    draw.ellipse((9, 9, 23, 23), fill=p["primary"], outline=p["dark"], width=1)
    poly(draw, [(16, 9), (19, 17), (16, 23), (13, 17)], p["accent"], OUTLINE_SOFT)
    sparkle(draw, 12, 10, WHITE)


def draw_seed(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((9, 8, 23, 28), fill=p["primary"], outline=OUTLINE, width=2)
    poly(draw, [(16, 9), (8, 5), (11, 14)], p["light"], p["dark"])
    poly(draw, [(16, 8), (25, 4), (22, 14)], p["light"], p["dark"])
    line(draw, [(16, 10), (16, 26)], p["dark"], 1)


def draw_drum(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (8, 10, 24, 24), p["primary"], OUTLINE, 2)
    draw.ellipse((8, 6, 24, 14), fill=p["light"], outline=OUTLINE, width=2)
    draw.ellipse((8, 20, 24, 28), fill=p["dark"], outline=OUTLINE, width=2)
    line(draw, [(9, 12), (23, 22)], p["accent"], 1)
    line(draw, [(23, 12), (9, 22)], p["accent"], 1)


def draw_mask(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(8, 7), (24, 7), (27, 16), (21, 27), (16, 23), (11, 27), (5, 16)], p["primary"])
    rect(draw, (10, 13, 14, 16), p["dark"], OUTLINE, 1)
    rect(draw, (18, 13, 22, 16), p["dark"], OUTLINE, 1)
    line(draw, [(13, 21), (19, 21)], p["accent"], 1)


def draw_standard(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    line(draw, [(10, 4), (10, 29)], p["metal"], 2)
    poly(draw, [(11, 6), (26, 9), (20, 15), (26, 21), (11, 19)], p["primary"])
    rect(draw, (7, 27, 14, 30), p["dark"], OUTLINE, 1)
    line(draw, [(14, 10), (23, 12)], p["accent"], 1)


def draw_gauntlet(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (10, 10, 23, 23), p["primary"], OUTLINE, 2)
    for x in [8, 11, 14, 17]:
        rect(draw, (x, 5, x + 5, 13), p["metal"], OUTLINE, 1)
    rect(draw, (13, 23, 23, 28), p["dark"], OUTLINE, 1)
    sparkle(draw, 18, 15, p["light"])


def draw_fish(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((7, 10, 24, 23), fill=p["primary"], outline=OUTLINE, width=2)
    poly(draw, [(23, 16), (29, 10), (29, 23)], p["dark"])
    rect(draw, (10, 13, 13, 16), p["light"], p["light"], 1)
    draw.point((20, 14), fill=OUTLINE)


def draw_brooch(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((7, 6, 25, 24), fill=p["metal"], outline=OUTLINE, width=2)
    poly(draw, [(16, 9), (20, 16), (16, 21), (12, 16)], p["accent"], p["dark"])
    line(draw, [(16, 24), (16, 29)], p["dark"], 2)


def draw_key(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((5, 6, 17, 18), outline=OUTLINE, width=3)
    draw.ellipse((8, 9, 14, 15), outline=p["light"], width=1)
    line(draw, [(15, 16), (27, 28)], OUTLINE, 4)
    line(draw, [(16, 17), (26, 27)], p["metal"], 2)
    rect(draw, (24, 24, 28, 27), p["primary"], OUTLINE, 1)


def draw_heart(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (10, 7, 15, 12), p["primary"], OUTLINE, 1)
    rect(draw, (18, 7, 23, 12), p["primary"], OUTLINE, 1)
    poly(draw, [(8, 11), (25, 11), (24, 20), (16, 28), (8, 20)], p["primary"])
    sparkle(draw, 12, 12, WHITE)


def draw_orb(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((6, 6, 26, 26), fill=p["primary"], outline=OUTLINE, width=2)
    draw.ellipse((10, 10, 22, 22), outline=p["light"], width=1)
    line(draw, [(8, 22), (24, 10)], p["accent"], 2)
    sparkle(draw, 12, 10, WHITE)


def draw_amulet(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (13, 3, 19, 8), p["metal"], OUTLINE, 1)
    draw.ellipse((7, 7, 25, 27), fill=p["primary"], outline=OUTLINE, width=2)
    poly(draw, [(16, 10), (22, 17), (16, 24), (10, 17)], p["accent"], p["dark"])
    sparkle(draw, 12, 11, WHITE)


def draw_goblet(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (9, 4, 23, 9), p["light"], OUTLINE, 2)
    poly(draw, [(9, 8), (23, 8), (20, 19), (12, 19)], p["primary"])
    rect(draw, (14, 19, 18, 26), p["metal"], OUTLINE, 1)
    rect(draw, (10, 26, 22, 29), p["dark"], OUTLINE, 1)
    sparkle(draw, 12, 9, WHITE)


def draw_sigils(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    draw.ellipse((6, 6, 26, 26), fill=p["primary"], outline=OUTLINE, width=2)
    line(draw, [(16, 8), (21, 21), (8, 13), (24, 13), (11, 21), (16, 8)], p["accent"], 2)
    draw.ellipse((13, 13, 19, 19), fill=p["light"], outline=OUTLINE, width=1)


def draw_cube(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    poly(draw, [(16, 4), (26, 10), (26, 22), (16, 28), (6, 22), (6, 10)], p["primary"])
    poly(draw, [(16, 4), (26, 10), (16, 16), (6, 10)], p["light"], OUTLINE_SOFT)
    poly(draw, [(16, 16), (26, 10), (26, 22), (16, 28)], p["dark"], OUTLINE_SOFT)
    line(draw, [(16, 16), (16, 28)], OUTLINE, 1)


def draw_relic(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (12, 3, 20, 9), p["metal"], OUTLINE, 1)
    draw.ellipse((6, 7, 26, 27), fill=p["primary"], outline=OUTLINE, width=2)
    poly(draw, [(16, 9), (23, 16), (16, 25), (9, 16)], p["accent"], OUTLINE_SOFT)
    line(draw, [(9, 16), (23, 16)], p["light"], 1)
    line(draw, [(16, 9), (16, 25)], p["light"], 1)


def draw_idol(draw: ImageDraw.ImageDraw, p: dict[str, tuple[int, int, int, int]]) -> None:
    rect(draw, (11, 5, 21, 14), p["primary"], OUTLINE, 2)
    rect(draw, (8, 14, 24, 26), p["metal"], OUTLINE, 2)
    rect(draw, (11, 26, 14, 30), p["dark"], OUTLINE, 1)
    rect(draw, (18, 26, 21, 30), p["dark"], OUTLINE, 1)
    rect(draw, (13, 9, 15, 11), p["accent"], p["accent"], 1)
    rect(draw, (18, 9, 20, 11), p["accent"], p["accent"], 1)


DRAWERS = {
    "gem": draw_gem,
    "crystal": draw_crystal,
    "ring": draw_ring,
    "sword": draw_sword,
    "dagger": draw_dagger,
    "shield": draw_shield,
    "feather": draw_feather,
    "bread": draw_bread,
    "coal": draw_coal,
    "coin": draw_coin,
    "bell": draw_bell,
    "herb": draw_herb,
    "totem": draw_totem,
    "candle": draw_candle,
    "scroll": draw_scroll,
    "shell": draw_shell,
    "charm": draw_charm,
    "helmet": draw_helmet,
    "marble": draw_marble,
    "lamp": draw_lamp,
    "horn": draw_horn,
    "anvil": draw_anvil,
    "cloak": draw_cloak,
    "needle": draw_needle,
    "mushroom": draw_mushroom,
    "medal": draw_medal,
    "arrow": draw_arrow,
    "leaf": draw_herb,
    "gear": draw_gear,
    "tablet": draw_tablet,
    "bow": draw_bow,
    "boots": draw_boots,
    "vial": draw_vial,
    "bottle": draw_vial,
    "lens": draw_lens,
    "pin": draw_pin,
    "apple": draw_heart,
    "crown": draw_crown,
    "book": draw_book,
    "compass": draw_compass,
    "seed": draw_seed,
    "drum": draw_drum,
    "mask": draw_mask,
    "standard": draw_standard,
    "gauntlet": draw_gauntlet,
    "fish": draw_fish,
    "brooch": draw_brooch,
    "key": draw_key,
    "heart": draw_heart,
    "orb": draw_orb,
    "amulet": draw_amulet,
    "goblet": draw_goblet,
    "spellblade": lambda draw, p: draw_sword(draw, p, True),
    "sigil": draw_sigils,
    "stone": draw_gem,
    "relic": draw_relic,
    "blade": lambda draw, p: draw_sword(draw, p, True),
    "cube": draw_cube,
    "idol": draw_idol,
    "badge": draw_medal,
}


def generate_icon(config: dict[str, Any]) -> Image.Image:
    image = Image.new("RGBA", (32, 32), BLACK_ALPHA)
    draw = ImageDraw.Draw(image)
    palette = PALETTES[config["palette"]]
    drawer = DRAWERS[config["icon"]]
    drawer(draw, palette)
    add_rarity_spark(draw, config["rarity"])
    return image


def pct(value: float) -> str:
    return "%d%%" % round(value * 100)


def num(value: float | int) -> str:
    if isinstance(value, int):
        return str(value)
    if float(value).is_integer():
        return str(int(value))
    return ("%.2f" % value).rstrip("0").rstrip(".")


def build_description(config: dict[str, Any]) -> str:
    canonical_data = dict(config["fields"])
    canonical_data["collectible_effect_id"] = config["slug"]
    canonical_data["description"] = str(config.get("design_description", ""))
    canonical_description = generate_player_description(canonical_data)
    if canonical_description:
        return canonical_description

    fields = config["fields"]
    stats: list[str] = []
    stat_labels = [
        ("collectible_attack_bonus", "攻击力"),
        ("collectible_max_health_bonus", "生命上限"),
        ("collectible_move_speed_bonus", "移动速度"),
        ("collectible_physical_defense_bonus", "物理防御"),
        ("collectible_magic_defense_bonus", "法术防御"),
        ("collectible_physical_damage_bonus", "造成物理伤害"),
        ("collectible_magic_damage_bonus", "造成法术伤害"),
        ("collectible_skill_charge_bonus_per_second", "每秒技力"),
    ]
    for key, label in stat_labels:
        value = fields.get(key, 0)
        if value:
            stats.append("%s+%s" % (label, num(value)))

    segments: list[str] = []
    if stats:
        suffix = "（可叠加）" if fields.get("collectible_stacks_by_copy", False) else ""
        segments.append("持有时，%s%s。" % ("，".join(stats), suffix))
    if fields.get("bullet_pierce_chance", 0.0):
        segments.append("发射子弹有%s概率变为穿透弹。" % pct(float(fields["bullet_pierce_chance"])))
    if fields.get("base_upgrade_free_chance", 0.0):
        segments.append("升级基础属性时，有%s概率不消耗息壤。" % pct(float(fields["base_upgrade_free_chance"])))
    if fields.get("incoming_ranged_dodge_chance", 0.0):
        segments.append("受到远程攻击时，额外有%s概率闪避该次伤害。" % pct(float(fields["incoming_ranged_dodge_chance"])))
    if fields.get("incoming_ranged_front_damage_multiplier", 1.0) != 1.0:
        segments.append("受到正面远程伤害变为%s。" % pct(float(fields["incoming_ranged_front_damage_multiplier"])))
    if fields.get("incoming_ranged_back_damage_multiplier", 1.0) != 1.0:
        segments.append("受到背面远程伤害变为%s。" % pct(float(fields["incoming_ranged_back_damage_multiplier"])))
    if fields.get("attack_speed_xirang_step", 0):
        segments.append(
            "身上每持有%s息壤，攻击速度+%s。"
            % (num(fields["attack_speed_xirang_step"]), num(fields["attack_speed_bonus_per_xirang_step"]))
        )
    if fields.get("defense_xirang_step", 0):
        segments.append(
            "身上每持有%s息壤，物理防御和法术防御各+%s。"
            % (num(fields["defense_xirang_step"]), num(fields["defense_bonus_per_xirang_step"]))
        )

    periodic = fields.get("periodic_effect_id", "")
    if periodic == "thunder":
        segments.append(
            "每%s秒优先在自身周围%s范围内随机选择敌人引落闪电"
            "，附近无目标时改选全场，对落点%s范围内敌人造成%s点法术伤害。"
            % (
                num(fields["periodic_interval"]),
                num(THUNDER_LOCAL_TARGET_RADIUS),
                num(fields["periodic_radius"]),
                num(fields["periodic_damage"]),
            )
        )
    elif periodic == "frost":
        segments.append(
            "每%s秒释放寒霜，%s范围内敌人受到%s点伤害并在%s秒内移速降至%s。"
            % (
                num(fields["periodic_interval"]),
                num(fields["periodic_radius"]),
                num(fields["periodic_damage"]),
                num(fields["periodic_slow_duration"]),
                pct(float(fields["periodic_slow_multiplier"])),
            )
        )
    elif periodic == "heal":
        segments.append(
            "每%s秒治疗%s范围内友方单位%s点生命。"
            % (num(fields["periodic_interval"]), num(fields["periodic_radius"]), num(fields["periodic_heal"]))
        )
    elif periodic == "archer":
        segments.append(
            "每%s秒向%s范围内最近的%s名敌人射箭，每支造成攻击力%s的物理伤害。"
            % (
                num(fields["periodic_interval"]),
                num(fields["periodic_radius"]),
                num(fields["periodic_target_count"]),
                pct(float(fields["periodic_attack_damage_multiplier"])),
            )
        )

    skill = fields.get("skill_effect_id", "")
    if skill == "moon_shield":
        segments.append(
            "使用技能时生成持续%s秒、半径%s的护盾，护盾内友方受到的伤害减半。"
            % (num(fields["skill_effect_duration"]), num(fields["skill_effect_radius"]))
        )
    elif skill == "swift":
        segments.append(
            "使用技能后移动速度提升至%s，持续%s秒。"
            % (pct(float(fields["skill_move_speed_multiplier"])), num(fields["skill_effect_duration"]))
        )

    if not segments:
        segments.append("持有时，提供一项稳定的小幅祝福。")
    return "".join(segments)


def godot_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return '"%s"' % value.replace('"', '\\"')
    if isinstance(value, float):
        return num(value) + (".0" if value.is_integer() else "")
    return str(value)


def render_config(config: dict[str, Any]) -> str:
    fields = dict(config["fields"])
    note_data = dict(fields)
    note_data["collectible_effect_id"] = config["slug"]
    note_data["display_name"] = config["name"]
    fields["collectible_design_note"] = generate_design_note(note_data)
    description_config = dict(config)
    description_config["fields"] = fields
    description = build_description(description_config)
    lines = [
        '[gd_resource type="Resource" script_class="PickupConfig" format=3]',
        "",
        '[ext_resource type="Texture2D" path="res://resources/texture/collectibles/%s.png" id="1_icon"]' % config["slug"],
        '[ext_resource type="Script" path="res://resources/config/pickup_config.gd" id="2_script"]',
        "",
        "[resource]",
        'script = ExtResource("2_script")',
        "pickup_type = 5",
        'display_name = "%s"' % config["name"],
        "drop_weight = 0.0",
        'description = "%s"' % description.replace('"', '\\"'),
        "can_store_in_inventory = true",
        'icon_texture = ExtResource("1_icon")',
        "icon_scale = Vector2(1, 1)",
        "duration = 0.0",
        'collectible_effect_id = "%s"' % config["slug"],
        "collectible_rarity = %d" % config["rarity"],
    ]
    for key in CONFIG_FIELD_ORDER:
        if key in fields and key != "collectible_rarity":
            lines.append("%s = %s" % (key, godot_value(fields[key])))
    lines.append('metadata/_custom_type_script = "uid://qucrregg4cq0"')
    return "\n".join(lines) + "\n"


def write_config(config: dict[str, Any]) -> None:
    path = CONFIG_DIR / ("collectible_%s.tres" % config["slug"])
    rendered = render_config(config)
    if not path.is_file() or path.read_text(encoding="utf-8") != rendered:
        path.write_text(rendered, encoding="utf-8")


def _read_godot_string_assignment(line_text: str) -> str:
    raw_value = line_text.split(" = ", 1)[1].strip()
    if raw_value.startswith('"') and raw_value.endswith('"'):
        raw_value = raw_value[1:-1]
    return raw_value.replace('\\"', '"')


def _parse_config_text(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    for line_text in text.splitlines():
        if " = " not in line_text or line_text.startswith("["):
            continue
        key, raw_value = line_text.split(" = ", 1)
        data[key] = parse_value(raw_value)
    return data


def _replace_string_assignment(text: str, key: str, value: str) -> str:
    newline = "\r\n" if "\r\n" in text else "\n"
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    replacement = '%s = "%s"' % (key, escaped)
    lines = text.splitlines()
    matches = [index for index, line_text in enumerate(lines) if line_text.startswith(key + " = ")]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one %s assignment" % key)
    lines[matches[0]] = replacement
    return newline.join(lines) + newline


def render_existing_config(file_name: str, rarity: int) -> str:
    path = CONFIG_DIR / file_name
    if not path.is_file():
        raise RuntimeError("Missing existing collectible config: %s" % path)
    text = path.read_text(encoding="utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines()
    updated: list[str] = []
    inserted = False
    override = EXISTING_BALANCE_OVERRIDES.get(file_name, {})
    override_fields = {key: value for key, value in override.items() if key != "description"}
    for line_text in lines:
        if " = " in line_text:
            key = line_text.split(" = ", 1)[0]
            if key == "collectible_rarity" or key in override_fields:
                continue
        if line_text.startswith("collectible_effect_id = "):
            updated.append(line_text)
            updated.append("collectible_rarity = %d" % rarity)
            for key in CONFIG_FIELD_ORDER:
                if key in override_fields:
                    updated.append("%s = %s" % (key, godot_value(override_fields[key])))
            inserted = True
            continue
        updated.append(line_text)
    if not inserted:
        raise RuntimeError("Could not insert rarity/design into %s" % path)

    canonical_text = newline.join(updated) + newline
    canonical_data = _parse_config_text(canonical_text)
    canonical_text = _replace_string_assignment(
        canonical_text,
        "description",
        generate_player_description(canonical_data),
    )
    canonical_data = _parse_config_text(canonical_text)
    canonical_text = _replace_string_assignment(
        canonical_text,
        "collectible_design_note",
        generate_design_note(canonical_data),
    )
    return canonical_text


def update_existing_config(file_name: str, rarity: int) -> None:
    path = CONFIG_DIR / file_name
    current = path.read_text(encoding="utf-8")
    rendered = render_existing_config(file_name, rarity)
    if current != rendered:
        path.write_text(rendered, encoding="utf-8")


def apply_curated_design(config: dict[str, Any]) -> None:
    spec = get_design_spec(config["slug"])
    config["fields"] = dict(spec["fields"])
    config["design_role"] = spec["role"]
    config["design_description"] = spec["description"]


def validate_design_specs() -> None:
    expected_slugs = {config["slug"] for config in ITEMS}
    actual_slugs = set(DESIGN_SPECS.keys())
    missing = sorted(expected_slugs - actual_slugs)
    extra = sorted(actual_slugs - expected_slugs)
    if missing:
        raise RuntimeError("Missing redesign specs: %s" % ", ".join(missing))
    if extra:
        raise RuntimeError("Unknown redesign specs: %s" % ", ".join(extra))


def render_audit_sheet(
    configs: list[dict[str, Any]],
    icons: dict[str, Image.Image] | None = None,
) -> Image.Image:
    cell = 64
    columns = 10
    rows = (len(configs) + columns - 1) // columns
    image = Image.new("RGBA", (columns * cell, rows * cell), (28, 28, 30, 255))
    checker_a = (62, 62, 66, 255)
    checker_b = (43, 43, 47, 255)
    for index, config in enumerate(configs):
        x0 = (index % columns) * cell
        y0 = (index // columns) * cell
        for y in range(0, 32, 8):
            for x in range(0, 32, 8):
                color = checker_a if ((x + y) // 8) % 2 == 0 else checker_b
                ImageDraw.Draw(image).rectangle((x0 + 16 + x, y0 + 5 + y, x0 + 23 + x, y0 + 12 + y), fill=color)
        if icons is None:
            icon = Image.open(TEXTURE_DIR / ("%s.png" % config["slug"])).convert("RGBA")
        else:
            icon = icons[config["slug"]]
        image.alpha_composite(icon.resize((32, 32), Image.Resampling.NEAREST), (x0 + 16, y0 + 5))
        draw = ImageDraw.Draw(image)
        draw.text((x0 + 2, y0 + 42), config["slug"][:12], fill=(210, 210, 210, 255))
    return image


def build_audit_sheet(configs: list[dict[str, Any]], icons: dict[str, Image.Image]) -> None:
    save_image_if_changed(AUDIT_PATH, render_audit_sheet(configs, icons))


def _read_existing_display_name(file_name: str) -> str:
    path = CONFIG_DIR / file_name
    if not path.is_file():
        return _slug_from_config_name(file_name)
    for line_text in path.read_text(encoding="utf-8").splitlines():
        if line_text.startswith("display_name = "):
            return _read_godot_string_assignment(line_text)
    return _slug_from_config_name(file_name)


def _mechanic_summary(fields: dict[str, Any]) -> str:
    parts: list[str] = []
    for key, label in [
        ("on_hit_effect_id", "命中"),
        ("kill_effect_id", "击杀"),
        ("periodic_effect_id", "周期"),
        ("skill_effect_id", "技能"),
        ("trigger_effect_id", "触发"),
        ("conditional_effect_id", "条件"),
    ]:
        value = fields.get(key, "")
        if value:
            parts.append("%s:%s" % (label, value))
    if fields.get("attack_speed_xirang_step", 0):
        parts.append("息壤攻速")
    if fields.get("defense_xirang_step", 0):
        parts.append("息壤防御")
    if fields.get("bullet_pierce_chance", 0.0):
        parts.append("穿透")
    if fields.get("base_upgrade_free_chance", 0.0):
        parts.append("免费升级")
    return "，".join(parts) if parts else "常驻属性"


def render_design_manifest(configs: list[dict[str, Any]]) -> str:
    name_by_slug = {config["slug"]: config["name"] for config in configs}
    rarity_by_slug = {config["slug"]: config["rarity"] for config in configs}
    for file_name, rarity in EXISTING_RARITIES.items():
        slug = _slug_from_config_name(file_name)
        name_by_slug[slug] = _read_existing_display_name(file_name)
        rarity_by_slug[slug] = rarity

    lines = [
        "# 收藏品重设计清单",
        "",
        "本清单只列出 80 个新增收藏品的单主词条重设计；git 仓库中原有的 24 个收藏品只补充稀有度，功能和描述保持旧版本。",
        "",
        "| 名称 | 稀有度 | 定位 | 设计说明 | 机制摘要 |",
        "| --- | --- | --- | --- | --- |",
    ]
    rows = sorted(
        DESIGN_ROWS,
        key=lambda row: (int(rarity_by_slug.get(row["slug"], 0)), str(row["slug"])),
    )
    for row in rows:
        slug = row["slug"]
        rarity = RARITY_LABELS_TEXT[int(rarity_by_slug.get(slug, 0))]
        lines.append(
            "| %s | %s | %s | %s | %s |"
            % (
                name_by_slug.get(slug, slug),
                rarity,
                row["role"],
                row["description"],
                _mechanic_summary(row["fields"]),
            )
        )
    return "\n".join(lines) + "\n"


def build_design_manifest(configs: list[dict[str, Any]]) -> None:
    rendered = render_design_manifest(configs)
    if not DESIGN_MANIFEST_PATH.is_file() or DESIGN_MANIFEST_PATH.read_text(encoding="utf-8") != rendered:
        DESIGN_MANIFEST_PATH.write_text(rendered, encoding="utf-8")


def save_image_if_changed(path: Path, image: Image.Image) -> None:
    if path.is_file():
        with Image.open(path) as current_source:
            current = current_source.convert("RGBA")
            if current.size == image.size and current.tobytes() == image.convert("RGBA").tobytes():
                return
    image.save(path)


def validate_outputs(configs: list[dict[str, Any]]) -> None:
    seen_slugs: set[str] = set()
    seen_design_ids: set[str] = set()
    for config in configs:
        slug = config["slug"]
        if slug in seen_slugs:
            raise RuntimeError("Duplicate slug: %s" % slug)
        seen_slugs.add(slug)
        design_id = str(config["fields"].get("collectible_design_id", ""))
        if not design_id:
            raise RuntimeError("Missing collectible design id: %s" % slug)
        if design_id in seen_design_ids:
            raise RuntimeError("Duplicate collectible design id: %s" % design_id)
        seen_design_ids.add(design_id)
        path = TEXTURE_DIR / ("%s.png" % slug)
        image = Image.open(path).convert("RGBA")
        if image.size != (32, 32):
            raise RuntimeError("%s is not 32x32" % path)
        if image.getchannel("A").getbbox() is None:
            raise RuntimeError("%s is empty" % path)
        config_path = CONFIG_DIR / ("collectible_%s.tres" % slug)
        if not config_path.is_file():
            raise RuntimeError("Missing config: %s" % config_path)


def validate_generated_in_memory(
    configs: list[dict[str, Any]],
    icons: dict[str, Image.Image],
    rendered_configs: dict[str, str],
) -> None:
    seen_slugs: set[str] = set()
    seen_design_ids: set[str] = set()
    for config in configs:
        slug = str(config["slug"])
        if slug in seen_slugs:
            raise RuntimeError("Duplicate slug: %s" % slug)
        seen_slugs.add(slug)

        data = _parse_config_text(rendered_configs[slug])
        design_id = str(data.get("collectible_design_id", ""))
        if not design_id:
            raise RuntimeError("Missing collectible design id: %s" % slug)
        if design_id in seen_design_ids:
            raise RuntimeError("Duplicate collectible design id: %s" % design_id)
        seen_design_ids.add(design_id)
        if str(data.get("description", "")) != generate_player_description(data):
            raise RuntimeError("Non-canonical description: %s" % slug)
        if str(data.get("collectible_design_note", "")) != generate_design_note(data):
            raise RuntimeError("Non-canonical collectible design note: %s" % slug)

        icon = icons[slug].convert("RGBA")
        if icon.size != (32, 32):
            raise RuntimeError("%s is not 32x32" % slug)
        if icon.getchannel("A").getbbox() is None:
            raise RuntimeError("%s is empty" % slug)

    for file_name, rarity in EXISTING_RARITIES.items():
        canonical_text = render_existing_config(file_name, rarity)
        data = _parse_config_text(canonical_text)
        if str(data.get("description", "")) != generate_player_description(data):
            raise RuntimeError("Non-canonical existing description: %s" % file_name)
        if str(data.get("collectible_design_note", "")) != generate_design_note(data):
            raise RuntimeError("Non-canonical existing design note: %s" % file_name)

    audit_sheet = render_audit_sheet(configs, icons)
    if audit_sheet.size != (640, 512):
        raise RuntimeError("Unexpected audit sheet size: %s" % (audit_sheet.size,))
    manifest = render_design_manifest(configs)
    if manifest.count("\n|") != len(configs) + 2:
        raise RuntimeError("Design manifest does not contain exactly %d rows" % len(configs))


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate or validate the 80-item collectible expansion")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="validate all generated data in memory without writing any files",
    )
    args = parser.parse_args()

    if len(ITEMS) != 80:
        raise RuntimeError("Expected exactly 80 new collectibles, got %d" % len(ITEMS))
    validate_design_specs()

    icons: dict[str, Image.Image] = {}
    rendered_configs: dict[str, str] = {}
    for config in ITEMS:
        apply_curated_design(config)
        slug = str(config["slug"])
        icons[slug] = generate_icon(config)
        rendered_configs[slug] = render_config(config)
    validate_generated_in_memory(ITEMS, icons, rendered_configs)

    if args.check_only:
        print("Validated %d collectibles entirely in memory; no files written." % len(ITEMS))
        return 0

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    for file_name, rarity in EXISTING_RARITIES.items():
        update_existing_config(file_name, rarity)

    for config in ITEMS:
        slug = str(config["slug"])
        save_image_if_changed(TEXTURE_DIR / ("%s.png" % slug), icons[slug])
        write_config(config)

    validate_outputs(ITEMS)
    build_audit_sheet(ITEMS, icons)
    build_design_manifest(ITEMS)
    print("Generated %d collectibles." % len(ITEMS))
    print("Audit sheet: %s" % AUDIT_PATH)
    print("Design manifest: %s" % DESIGN_MANIFEST_PATH)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
