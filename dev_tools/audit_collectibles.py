#!/usr/bin/env python3
"""
Audit collectible resources and icon assets.

Checks every collectible config for a meaningful gameplay effect, valid
rarity, valid effect field combinations, unique effect signatures, and a
32x32 non-empty PNG icon with matching Godot import metadata.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
from math import floor
from pathlib import Path
from typing import Any

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = PROJECT_ROOT / "resources" / "config" / "collectibles"
REPORT_PATH = PROJECT_ROOT / "dev_tools" / "collectible_audit_report.md"
SOURCE_IMAGE_ROOT = PROJECT_ROOT / "dev_assets" / "source_images"
MIN_SOURCE_GRID_CONFIDENCE = 0.65
MAX_SOURCE_LOGICAL_SUBJECT_SIZE = 26

RARITY_LABELS = {
    0: "普通",
    1: "稀有",
    2: "史诗",
    3: "传说",
}

FIELD_DEFAULTS: dict[str, Any] = {
    "collectible_stacks_by_copy": False,
    "collectible_max_copies": 0,
    "bullet_pierce_chance": 0.0,
    "bullet_homing_chance": 0.0,
    "ammo_free_shot_chance": 0.0,
    "skill_charge_preserve_chance": 0.0,
    "damage_against_burning_multiplier": 1.0,
    "damage_against_bleeding_multiplier": 1.0,
    "collectible_attack_bonus": 0,
    "collectible_max_health_bonus": 0,
    "collectible_move_speed_bonus": 0.0,
    "collectible_attack_speed_bonus": 0.0,
    "collectible_dash_distance_bonus": 0.0,
    "collectible_dash_cooldown_reduction": 0.0,
    "collectible_physical_defense_bonus": 0,
    "collectible_magic_defense_bonus": 0,
    "collectible_physical_damage_bonus": 0,
    "collectible_magic_damage_bonus": 0,
    "collectible_skill_charge_bonus_per_second": 0.0,
    "base_upgrade_free_chance": 0.0,
    "incoming_ranged_front_damage_multiplier": 1.0,
    "incoming_ranged_back_damage_multiplier": 1.0,
    "incoming_ranged_dodge_chance": 0.0,
    "attack_speed_xirang_step": 0,
    "attack_speed_bonus_per_xirang_step": 0.0,
    "defense_xirang_step": 0,
    "defense_bonus_per_xirang_step": 0,
    "periodic_effect_id": "",
    "periodic_interval": 0.0,
    "periodic_radius": 0.0,
    "periodic_damage": 0,
    "periodic_attack_damage_multiplier": 0.0,
    "periodic_target_count": 1,
    "periodic_heal": 0,
    "periodic_slow_multiplier": 1.0,
    "periodic_slow_duration": 0.0,
    "skill_effect_id": "",
    "skill_effect_radius": 0.0,
    "skill_effect_duration": 0.0,
    "skill_move_speed_multiplier": 1.0,
    "collectible_design_id": "",
    "collectible_design_note": "",
    "conditional_effect_id": "",
    "conditional_health_ratio_threshold": 0.0,
    "conditional_xirang_threshold": 0,
    "conditional_attack_bonus": 0,
    "conditional_max_health_bonus": 0,
    "conditional_move_speed_bonus": 0.0,
    "conditional_physical_defense_bonus": 0,
    "conditional_magic_defense_bonus": 0,
    "conditional_physical_damage_bonus": 0,
    "conditional_magic_damage_bonus": 0,
    "conditional_skill_charge_bonus_per_second": 0.0,
    "conditional_bullet_pierce_chance": 0.0,
    "trigger_effect_id": "",
    "trigger_shot_interval": 0,
    "trigger_cooldown": 0.0,
    "trigger_damage": 0,
    "trigger_radius": 0.0,
    "trigger_heal": 0,
    "trigger_xirang": 0,
    "trigger_skill_charge": 0.0,
    "trigger_slow_multiplier": 1.0,
    "trigger_slow_duration": 0.0,
    "on_hit_effect_id": "",
    "on_hit_chance": 0.0,
    "on_hit_cooldown": 0.0,
    "on_hit_damage": 0,
    "on_hit_duration": 0.0,
    "on_hit_tick_interval": 0.5,
    "on_hit_radius": 0.0,
    "on_hit_heal": 0,
    "on_hit_xirang": 0,
    "on_hit_skill_charge": 0.0,
    "on_hit_slow_multiplier": 1.0,
    "on_hit_physical_defense_modifier": 0,
    "on_hit_damage_taken_multiplier": 1.0,
    "on_hit_execute_health_ratio": 0.0,
    "kill_effect_id": "",
    "kill_cooldown": 0.0,
    "kill_heal": 0,
    "kill_xirang": 0,
    "kill_skill_charge": 0.0,
    "kill_damage": 0,
    "kill_radius": 0.0,
    "kill_duration": 0.0,
    "kill_slow_multiplier": 1.0,
    "kill_move_speed_multiplier": 1.0,
}

DESIGN_METADATA_FIELDS = {"collectible_design_id", "collectible_design_note"}
STACKING_METADATA_FIELDS = {"collectible_stacks_by_copy", "collectible_max_copies"}
GAMEPLAY_EFFECT_FIELDS = tuple(
    field
    for field in FIELD_DEFAULTS.keys()
    if field not in STACKING_METADATA_FIELDS and field not in DESIGN_METADATA_FIELDS
)
SPECIAL_EFFECT_IDS = {"admin_doll"}
VALID_PERIODIC_EFFECTS = {"thunder", "frost", "heal", "archer", "sakura_rocket"}
VALID_SKILL_EFFECTS = {"moon_shield", "swift"}
VALID_CONDITIONAL_EFFECTS = {"health_below", "health_above", "xirang_at_least", "xirang_below", "skill_unlocked", "skill_locked"}
VALID_TRIGGER_EFFECTS = {
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
}
VALID_ON_HIT_EFFECTS = {"burn", "bleed", "chill", "shock", "mark", "crack", "leech", "siphon", "execute", "bloom", "xirang"}
VALID_KILL_EFFECTS = {"heal", "xirang", "charge", "thunder", "frost", "haste", "bloom", "burst"}
CONDITIONAL_BONUS_FIELDS = (
    "conditional_attack_bonus",
    "conditional_max_health_bonus",
    "conditional_move_speed_bonus",
    "conditional_physical_defense_bonus",
    "conditional_magic_defense_bonus",
    "conditional_physical_damage_bonus",
    "conditional_magic_damage_bonus",
    "conditional_skill_charge_bonus_per_second",
    "conditional_bullet_pierce_chance",
)
DESIGN_PROFILE_FIELDS = (
    "conditional_effect_id",
    "conditional_health_ratio_threshold",
    "conditional_xirang_threshold",
    *CONDITIONAL_BONUS_FIELDS,
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
    "bullet_pierce_chance",
    "bullet_homing_chance",
    "ammo_free_shot_chance",
    "skill_charge_preserve_chance",
    "damage_against_burning_multiplier",
    "damage_against_bleeding_multiplier",
    "base_upgrade_free_chance",
    "incoming_ranged_front_damage_multiplier",
    "incoming_ranged_back_damage_multiplier",
    "incoming_ranged_dodge_chance",
    "attack_speed_xirang_step",
    "attack_speed_bonus_per_xirang_step",
    "defense_xirang_step",
    "defense_bonus_per_xirang_step",
)
NEW_COLLECTIBLE_COUNT = 88
EXPECTED_TOTAL_COUNT = 112
STATIC_STAT_FIELDS = (
    "collectible_attack_bonus",
    "collectible_max_health_bonus",
    "collectible_move_speed_bonus",
    "collectible_attack_speed_bonus",
    "collectible_dash_distance_bonus",
    "collectible_dash_cooldown_reduction",
    "collectible_physical_defense_bonus",
    "collectible_magic_defense_bonus",
    "collectible_physical_damage_bonus",
    "collectible_magic_damage_bonus",
    "collectible_skill_charge_bonus_per_second",
)
RANGED_DEFENSE_FIELDS = (
    "incoming_ranged_front_damage_multiplier",
    "incoming_ranged_back_damage_multiplier",
    "incoming_ranged_dodge_chance",
)
STATUS_TARGET_DAMAGE_FIELDS = (
    "damage_against_burning_multiplier",
    "damage_against_bleeding_multiplier",
)
PROBABILITY_EFFECT_FIELDS = (
    "bullet_pierce_chance",
    "bullet_homing_chance",
    "ammo_free_shot_chance",
    "skill_charge_preserve_chance",
    "base_upgrade_free_chance",
    "incoming_ranged_dodge_chance",
)
XIRANG_DYNAMIC_FIELDS = (
    "attack_speed_xirang_step",
    "attack_speed_bonus_per_xirang_step",
    "defense_xirang_step",
    "defense_bonus_per_xirang_step",
)
MIN_ATTACK_SPEED_XIRANG_STEP = 500
MAX_ATTACK_SPEED_BONUS_PER_STEP = 2.0
MAX_ATTACK_SPEED_BONUS_PER_1000_XIRANG = 2.0
MAX_ATTACK_SPEED_BONUS_AT_3000_XIRANG = 8.0
ATTACK_SPEED_XIRANG_LIMIT_OVERRIDES = {
    "gold_wine_cup": {
        "max_bonus_per_step": 5.0,
        "max_bonus_per_1000": 5.0,
        "max_bonus_at_3000": 15.0,
    },
}
MIN_DEFENSE_XIRANG_STEP = 1500
MAX_DEFENSE_BONUS_PER_STEP = 1
MAX_DEFENSE_BONUS_PER_1000_XIRANG = 0.75
MAX_DEFENSE_BONUS_AT_5000_XIRANG = 3


@dataclass
class CollectibleAudit:
    path: Path
    data: dict[str, Any]
    icon_path: Path | None
    icon_bbox: tuple[int, int, int, int] | None
    icon_alpha_pixels: int
    effect_summary: str
    effect_signature: tuple[tuple[str, Any], ...]
    design_profile: tuple[tuple[str, Any], ...]
    issues: list[str]


def parse_value(raw_value: str) -> Any:
    value = raw_value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if value == "true":
        return True
    if value == "false":
        return False
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def parse_config(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if " = " not in line or line.startswith("["):
            continue
        key, raw_value = line.split(" = ", 1)
        data[key] = parse_value(raw_value)

    text = path.read_text(encoding="utf-8")
    icon_marker = '[ext_resource type="Texture2D"'
    icon_path = ""
    for line in text.splitlines():
        if line.startswith(icon_marker) and ' path="res://' in line:
            icon_path = line.split(' path="res://', 1)[1].split('"', 1)[0]
            break
    data["_icon_res_path"] = icon_path
    return data


def resolve_res_path(res_path: str) -> Path:
    if not res_path:
        return PROJECT_ROOT / "__missing__"
    if not res_path.startswith("res://"):
        return PROJECT_ROOT / res_path
    return PROJECT_ROOT / res_path.removeprefix("res://")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source_file:
        for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def audit_icon_build_manifest(icon_path: Path, issues: list[str]) -> None:
    if not SOURCE_IMAGE_ROOT.is_dir():
        return
    manifests = sorted(SOURCE_IMAGE_ROOT.rglob(f"{icon_path.stem}_v*_build.json"))
    if not manifests:
        return
    manifest_path = manifests[-1]
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - audit should report malformed provenance.
        issues.append(f"图标构建清单无法读取: {manifest_path.relative_to(PROJECT_ROOT)} ({exc})")
        return

    expected_output = icon_path.relative_to(PROJECT_ROOT).as_posix()
    manifest_output = str(manifest.get("output", "")).replace("\\", "/")
    if manifest_output != expected_output:
        issues.append(f"图标构建清单输出不匹配: {manifest_output or '空'}")

    input_value = str(manifest.get("input", "")).replace("\\", "/")
    input_path = PROJECT_ROOT / input_value
    if not input_value or not input_path.is_file():
        issues.append(f"图标构建清单源 Alpha 不存在: {input_value or '空'}")
    elif manifest.get("input_sha256") != _sha256(input_path):
        issues.append("图标构建清单源 Alpha 哈希不匹配")

    if manifest.get("output_sha256") != _sha256(icon_path):
        issues.append("图标构建清单最终 PNG 哈希不匹配")
    if manifest.get("detection_mode") not in {"exact_integer", "approximate"}:
        issues.append(f"图标源逻辑网格不可识别: {manifest.get('detection_mode', '空')}")
    try:
        source_confidence = float(manifest.get("confidence", 0.0))
    except (TypeError, ValueError):
        source_confidence = 0.0
    if source_confidence < MIN_SOURCE_GRID_CONFIDENCE:
        issues.append(f"图标源逻辑网格置信度不足: {manifest.get('confidence', 0.0)}")
    subject_grid_size = manifest.get("subject_grid_size", [])
    grid_dimensions: list[int] = []
    if isinstance(subject_grid_size, list) and len(subject_grid_size) == 2:
        try:
            grid_dimensions = [int(value) for value in subject_grid_size]
        except (TypeError, ValueError):
            grid_dimensions = []
    if not grid_dimensions or max(grid_dimensions) > MAX_SOURCE_LOGICAL_SUBJECT_SIZE:
        issues.append(f"图标源逻辑主体超出预算: {subject_grid_size}")


def non_default_effect_fields(data: dict[str, Any]) -> tuple[tuple[str, Any], ...]:
    result: list[tuple[str, Any]] = []
    for field, default in FIELD_DEFAULTS.items():
        if field in DESIGN_METADATA_FIELDS:
            continue
        value = data.get(field, default)
        if value != default:
            result.append((field, value))
    return tuple(result)


def design_profile(data: dict[str, Any]) -> tuple[tuple[str, Any], ...]:
    result: list[tuple[str, Any]] = []
    for field in DESIGN_PROFILE_FIELDS:
        default = FIELD_DEFAULTS[field]
        value = data.get(field, default)
        if value != default:
            result.append((field, value))
    return tuple(result)


def has_meaningful_effect(data: dict[str, Any]) -> bool:
    if data.get("collectible_effect_id") in SPECIAL_EFFECT_IDS:
        return True
    return any(data.get(field, FIELD_DEFAULTS[field]) != FIELD_DEFAULTS[field] for field in GAMEPLAY_EFFECT_FIELDS)


def summarize_effect(data: dict[str, Any]) -> str:
    if data.get("collectible_effect_id") == "admin_doll":
        return "庄方宜后续技能升级免费"

    parts: list[str] = []
    labels = [
        ("collectible_attack_bonus", "攻击"),
        ("collectible_max_health_bonus", "生命"),
        ("collectible_move_speed_bonus", "移速"),
        ("collectible_attack_speed_bonus", "攻速"),
        ("collectible_dash_distance_bonus", "冲刺距离"),
        ("collectible_dash_cooldown_reduction", "冲刺冷却减免"),
        ("collectible_physical_defense_bonus", "物防"),
        ("collectible_magic_defense_bonus", "法防"),
        ("collectible_physical_damage_bonus", "物伤"),
        ("collectible_magic_damage_bonus", "法伤"),
        ("collectible_skill_charge_bonus_per_second", "技力/s"),
        ("bullet_pierce_chance", "穿透率"),
        ("bullet_homing_chance", "追踪率"),
        ("ammo_free_shot_chance", "免耗弹率"),
        ("skill_charge_preserve_chance", "技能免耗率"),
        ("base_upgrade_free_chance", "免费升级率"),
        ("incoming_ranged_dodge_chance", "远程闪避率"),
    ]
    for field, label in labels:
        value = data.get(field, FIELD_DEFAULTS[field])
        if value != FIELD_DEFAULTS[field]:
            parts.append(f"{label}+{value}")

    def percentage_phrase(subject: str, multiplier: float) -> str:
        percentage = round(abs(multiplier - 1.0) * 100)
        direction = "提高" if multiplier > 1.0 else "降低"
        return f"{subject}{direction}{percentage}%"

    if data.get("incoming_ranged_front_damage_multiplier", 1.0) != 1.0:
        parts.append(percentage_phrase("受到的正面远程伤害", data["incoming_ranged_front_damage_multiplier"]))
    if data.get("incoming_ranged_back_damage_multiplier", 1.0) != 1.0:
        parts.append(percentage_phrase("受到的背面远程伤害", data["incoming_ranged_back_damage_multiplier"]))
    if data.get("damage_against_burning_multiplier", 1.0) != 1.0:
        parts.append(percentage_phrase("对燃烧敌人的伤害", data["damage_against_burning_multiplier"]))
    if data.get("damage_against_bleeding_multiplier", 1.0) != 1.0:
        parts.append(percentage_phrase("对流血敌人的伤害", data["damage_against_bleeding_multiplier"]))
    if data.get("attack_speed_xirang_step", 0):
        parts.append(f"每{data['attack_speed_xirang_step']}息壤攻速+{data.get('attack_speed_bonus_per_xirang_step', 0)}")
    if data.get("defense_xirang_step", 0):
        parts.append(f"每{data['defense_xirang_step']}息壤双防+{data.get('defense_bonus_per_xirang_step', 0)}")
    if data.get("periodic_effect_id", ""):
        parts.append(f"周期:{data['periodic_effect_id']}")
    if data.get("skill_effect_id", ""):
        parts.append(f"技能:{data['skill_effect_id']}")
    if data.get("conditional_effect_id", ""):
        parts.append(f"条件:{data['conditional_effect_id']}")
    if data.get("trigger_effect_id", ""):
        parts.append(f"触发:{data['trigger_effect_id']}")
    if data.get("on_hit_effect_id", ""):
        parts.append(f"命中:{data['on_hit_effect_id']}")
    if data.get("kill_effect_id", ""):
        parts.append(f"击杀:{data['kill_effect_id']}")

    return "；".join(parts) if parts else "无常规效果"


def _has_non_default(data: dict[str, Any], fields: tuple[str, ...]) -> bool:
    return any(data.get(field, FIELD_DEFAULTS[field]) != FIELD_DEFAULTS[field] for field in fields)


def primary_affix_categories(data: dict[str, Any]) -> list[str]:
    categories: list[str] = []
    if _has_non_default(data, STATIC_STAT_FIELDS):
        categories.append("基础数值")
    if data.get("bullet_pierce_chance", 0.0) != 0.0:
        categories.append("穿透")
    if data.get("bullet_homing_chance", 0.0) != 0.0:
        categories.append("追踪")
    if data.get("ammo_free_shot_chance", 0.0) != 0.0:
        categories.append("弹药免耗")
    if data.get("skill_charge_preserve_chance", 0.0) != 0.0:
        categories.append("技能免耗")
    if _has_non_default(data, STATUS_TARGET_DAMAGE_FIELDS):
        categories.append("状态增伤")
    if data.get("base_upgrade_free_chance", 0.0) != 0.0:
        categories.append("免费升级")
    if _has_non_default(data, RANGED_DEFENSE_FIELDS):
        categories.append("远程防御")
    if _has_non_default(data, XIRANG_DYNAMIC_FIELDS):
        categories.append("息壤动态")
    if str(data.get("periodic_effect_id", "")).strip():
        categories.append("周期")
    if str(data.get("skill_effect_id", "")).strip():
        categories.append("技能")
    if str(data.get("conditional_effect_id", "")).strip():
        categories.append("条件")
    if str(data.get("trigger_effect_id", "")).strip():
        categories.append("触发")
    if str(data.get("on_hit_effect_id", "")).strip():
        categories.append("命中")
    if str(data.get("kill_effect_id", "")).strip():
        categories.append("击杀")
    return categories


def audit_icon(data: dict[str, Any], issues: list[str]) -> tuple[Path | None, tuple[int, int, int, int] | None, int]:
    res_path = str(data.get("_icon_res_path", ""))
    if not res_path:
        issues.append("缺少图标资源路径")
        return None, None, 0

    icon_path = resolve_res_path("res://" + res_path if not res_path.startswith("res://") else res_path)
    if not icon_path.is_file():
        issues.append(f"图标文件不存在: {res_path}")
        return icon_path, None, 0
    if icon_path.suffix.lower() != ".png":
        issues.append(f"图标不是 PNG: {res_path}")

    import_path = Path(str(icon_path) + ".import")
    if not import_path.is_file():
        issues.append(f"缺少 Godot 导入文件: {import_path.relative_to(PROJECT_ROOT)}")

    try:
        image = Image.open(icon_path).convert("RGBA")
    except Exception as exc:  # noqa: BLE001 - audit should report corrupt images.
        issues.append(f"图标无法读取: {exc}")
        return icon_path, None, 0

    if image.size != (32, 32):
        issues.append(f"图标尺寸不是 32x32: {image.size[0]}x{image.size[1]}")

    audit_icon_build_manifest(icon_path, issues)

    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    alpha_pixels = sum(1 for value in alpha.getdata() if value > 0)
    if bbox is None:
        issues.append("图标为空透明图")
    else:
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        if width < 6 or height < 6:
            issues.append(f"图标主体过小: {width}x{height}")
        if width > 30 or height > 30:
            issues.append(f"图标主体过大: {width}x{height}")
        if alpha_pixels < 24:
            issues.append(f"图标非透明像素过少: {alpha_pixels}")
        if alpha_pixels > 760:
            issues.append(f"图标非透明像素过多: {alpha_pixels}")

    return icon_path, bbox, alpha_pixels


def _has_conditional_bonus(data: dict[str, Any]) -> bool:
    return any(data.get(field, FIELD_DEFAULTS[field]) != FIELD_DEFAULTS[field] for field in CONDITIONAL_BONUS_FIELDS)


def validate_xirang_scaling_balance(data: dict[str, Any], issues: list[str]) -> None:
    attack_limits = ATTACK_SPEED_XIRANG_LIMIT_OVERRIDES.get(str(data.get("collectible_effect_id", "")), {})
    max_attack_bonus_per_step = float(attack_limits.get("max_bonus_per_step", MAX_ATTACK_SPEED_BONUS_PER_STEP))
    max_attack_bonus_per_1000 = float(attack_limits.get("max_bonus_per_1000", MAX_ATTACK_SPEED_BONUS_PER_1000_XIRANG))
    max_attack_bonus_at_3000 = float(attack_limits.get("max_bonus_at_3000", MAX_ATTACK_SPEED_BONUS_AT_3000_XIRANG))
    attack_step = int(data.get("attack_speed_xirang_step", 0))
    attack_bonus = float(data.get("attack_speed_bonus_per_xirang_step", 0.0))
    if attack_step > 0:
        if attack_step < MIN_ATTACK_SPEED_XIRANG_STEP:
            issues.append(f"息壤攻速步长过低，至少应为 {MIN_ATTACK_SPEED_XIRANG_STEP}")
        if attack_bonus > max_attack_bonus_per_step:
            issues.append(f"息壤攻速单步收益过高，最多应为 {max_attack_bonus_per_step:g}")
        bonus_per_1000 = attack_bonus * 1000.0 / float(attack_step)
        if bonus_per_1000 > max_attack_bonus_per_1000:
            issues.append(
                "息壤攻速折算收益过高: 每1000息壤+%s，最多+%s"
                % (round(bonus_per_1000, 2), max_attack_bonus_per_1000)
            )
        bonus_at_3000 = floor(3000 / attack_step) * attack_bonus
        if bonus_at_3000 > max_attack_bonus_at_3000:
            issues.append(
                "息壤攻速3000息壤收益过高: +%s，最多+%s"
                % (round(bonus_at_3000, 2), max_attack_bonus_at_3000)
            )

    defense_step = int(data.get("defense_xirang_step", 0))
    defense_bonus = int(data.get("defense_bonus_per_xirang_step", 0))
    if defense_step > 0:
        if defense_step < MIN_DEFENSE_XIRANG_STEP:
            issues.append(f"息壤防御步长过低，至少应为 {MIN_DEFENSE_XIRANG_STEP}")
        if defense_bonus > MAX_DEFENSE_BONUS_PER_STEP:
            issues.append(f"息壤防御单步收益过高，最多应为 {MAX_DEFENSE_BONUS_PER_STEP}")
        bonus_per_1000 = float(defense_bonus) * 1000.0 / float(defense_step)
        if bonus_per_1000 > MAX_DEFENSE_BONUS_PER_1000_XIRANG:
            issues.append(
                "息壤防御折算收益过高: 每1000息壤+%s，最多+%s"
                % (round(bonus_per_1000, 2), MAX_DEFENSE_BONUS_PER_1000_XIRANG)
            )
        bonus_at_5000 = floor(5000 / defense_step) * defense_bonus
        if bonus_at_5000 > MAX_DEFENSE_BONUS_AT_5000_XIRANG:
            issues.append(
                "息壤防御5000息壤收益过高: +%s，最多+%s"
                % (bonus_at_5000, MAX_DEFENSE_BONUS_AT_5000_XIRANG)
            )


def validate_unique_design_fields(data: dict[str, Any], issues: list[str], is_original: bool) -> None:
    design_id = str(data.get("collectible_design_id", "")).strip()
    design_note = str(data.get("collectible_design_note", "")).strip()
    description = str(data.get("description", ""))
    if not description.strip():
        issues.append("缺少面向玩家的设计描述")
    if "独特设计" in description:
        issues.append("描述仍然使用外挂机制式的“独特设计”标签")
    if is_original:
        return

    if not design_id:
        issues.append("缺少 collectible_design_id")
    if not design_note:
        issues.append("缺少 collectible_design_note")

    categories = primary_affix_categories(data)
    if len(categories) != 1:
        summary = "、".join(categories) if categories else "无"
        issues.append(f"新收藏品必须且只能有一个主词条类别: {summary}")

    condition = str(data.get("conditional_effect_id", "")).strip()
    trigger = str(data.get("trigger_effect_id", "")).strip()
    on_hit = str(data.get("on_hit_effect_id", "")).strip()
    kill = str(data.get("kill_effect_id", "")).strip()

    if condition:
        if condition not in VALID_CONDITIONAL_EFFECTS:
            issues.append(f"未知条件机制: {condition}")
        if condition in {"health_below", "health_above"}:
            threshold = float(data.get("conditional_health_ratio_threshold", 0.0))
            if threshold <= 0.0 or threshold >= 1.0:
                issues.append("生命条件机制缺少 0-1 之间的生命比例阈值")
        if condition in {"xirang_at_least", "xirang_below"} and int(data.get("conditional_xirang_threshold", 0)) <= 0:
            issues.append("息壤条件机制缺少正数阈值")
        if not _has_conditional_bonus(data):
            issues.append("条件机制没有任何条件收益字段")

    if trigger:
        if trigger not in VALID_TRIGGER_EFFECTS:
            issues.append(f"未知触发机制: {trigger}")
        if trigger.startswith("shot_") and int(data.get("trigger_shot_interval", 0)) <= 0:
            issues.append("射击触发机制缺少正数 shot interval")
        if trigger.startswith("hurt_") and float(data.get("trigger_cooldown", 0.0)) <= 0.0:
            issues.append("受伤触发机制缺少正数 cooldown")
        if trigger.endswith("_heal") and int(data.get("trigger_heal", 0)) <= 0:
            issues.append("治疗触发机制缺少治疗量")
        if trigger.endswith("_xirang") and int(data.get("trigger_xirang", 0)) <= 0:
            issues.append("息壤触发机制缺少息壤量")
        if trigger.endswith("_charge") and float(data.get("trigger_skill_charge", 0.0)) <= 0.0:
            issues.append("充能触发机制缺少充能量")
        if trigger.endswith("_thunder"):
            if int(data.get("trigger_damage", 0)) <= 0:
                issues.append("落雷触发机制缺少伤害")
            if float(data.get("trigger_radius", 0.0)) <= 0.0:
                issues.append("落雷触发机制缺少半径")
        if trigger.endswith("_frost"):
            if int(data.get("trigger_damage", 0)) <= 0:
                issues.append("寒霜触发机制缺少伤害")
            if float(data.get("trigger_radius", 0.0)) <= 0.0:
                issues.append("寒霜触发机制缺少半径")
            if float(data.get("trigger_slow_multiplier", 1.0)) >= 1.0:
                issues.append("寒霜触发机制没有减速")
            if float(data.get("trigger_slow_duration", 0.0)) <= 0.0:
                issues.append("寒霜触发机制缺少减速持续时间")

    if on_hit:
        if on_hit not in VALID_ON_HIT_EFFECTS:
            issues.append(f"未知命中机制: {on_hit}")
        if float(data.get("on_hit_chance", 0.0)) <= 0.0:
            issues.append("命中机制缺少正数触发概率")
        if on_hit in {"burn", "bleed"}:
            if int(data.get("on_hit_damage", 0)) <= 0:
                issues.append("持续伤害命中机制缺少伤害")
            if float(data.get("on_hit_duration", 0.0)) <= 0.0:
                issues.append("持续伤害命中机制缺少持续时间")
        if on_hit == "chill":
            if float(data.get("on_hit_duration", 0.0)) <= 0.0:
                issues.append("寒冷命中机制缺少持续时间")
            if float(data.get("on_hit_slow_multiplier", 1.0)) >= 1.0:
                issues.append("寒冷命中机制没有减速")
        if on_hit == "shock":
            if int(data.get("on_hit_damage", 0)) <= 0:
                issues.append("电弧命中机制缺少伤害")
            if float(data.get("on_hit_radius", 0.0)) <= 0.0:
                issues.append("电弧命中机制缺少半径")
        if on_hit == "mark":
            if float(data.get("on_hit_duration", 0.0)) <= 0.0:
                issues.append("标记命中机制缺少持续时间")
            if float(data.get("on_hit_damage_taken_multiplier", 1.0)) <= 1.0:
                issues.append("标记命中机制没有提高承伤")
        if on_hit == "crack":
            if float(data.get("on_hit_duration", 0.0)) <= 0.0:
                issues.append("破甲命中机制缺少持续时间")
            if int(data.get("on_hit_physical_defense_modifier", 0)) >= 0:
                issues.append("破甲命中机制没有降低物防")
        if on_hit == "leech" and int(data.get("on_hit_heal", 0)) <= 0:
            issues.append("吸生命中机制缺少治疗量")
        if on_hit == "siphon" and float(data.get("on_hit_skill_charge", 0.0)) <= 0.0:
            issues.append("汲取命中机制缺少充能量")
        if on_hit == "execute" and float(data.get("on_hit_execute_health_ratio", 0.0)) <= 0.0:
            issues.append("处决命中机制缺少生命阈值")
        if on_hit == "bloom":
            if int(data.get("on_hit_heal", 0)) <= 0:
                issues.append("治疗花命中机制缺少治疗量")
            if float(data.get("on_hit_radius", 0.0)) <= 0.0:
                issues.append("治疗花命中机制缺少半径")
        if on_hit == "xirang" and int(data.get("on_hit_xirang", 0)) <= 0:
            issues.append("息壤命中机制缺少息壤量")

    if kill:
        if kill not in VALID_KILL_EFFECTS:
            issues.append(f"未知击杀机制: {kill}")
        if kill == "heal" and int(data.get("kill_heal", 0)) <= 0:
            issues.append("击杀治疗机制缺少治疗量")
        if kill == "xirang" and int(data.get("kill_xirang", 0)) <= 0:
            issues.append("击杀息壤机制缺少息壤量")
        if kill == "charge" and float(data.get("kill_skill_charge", 0.0)) <= 0.0:
            issues.append("击杀充能机制缺少充能量")
        if kill in {"thunder", "burst"}:
            if int(data.get("kill_damage", 0)) <= 0:
                issues.append("击杀伤害机制缺少伤害")
            if float(data.get("kill_radius", 0.0)) <= 0.0:
                issues.append("击杀伤害机制缺少半径")
        if kill == "frost":
            if int(data.get("kill_damage", 0)) <= 0:
                issues.append("击杀寒霜机制缺少伤害")
            if float(data.get("kill_radius", 0.0)) <= 0.0:
                issues.append("击杀寒霜机制缺少半径")
            if float(data.get("kill_slow_multiplier", 1.0)) >= 1.0:
                issues.append("击杀寒霜机制没有减速")
            if float(data.get("kill_duration", 0.0)) <= 0.0:
                issues.append("击杀寒霜机制缺少持续时间")
        if kill == "haste":
            if float(data.get("kill_duration", 0.0)) <= 0.0:
                issues.append("击杀加速机制缺少持续时间")
            if float(data.get("kill_move_speed_multiplier", 1.0)) <= 1.0:
                issues.append("击杀加速机制没有提高移速")
        if kill == "bloom":
            if int(data.get("kill_heal", 0)) <= 0:
                issues.append("击杀治疗花机制缺少治疗量")
            if float(data.get("kill_radius", 0.0)) <= 0.0:
                issues.append("击杀治疗花机制缺少半径")


def validate_logic_fields(data: dict[str, Any], issues: list[str], config_name: str) -> None:
    if data.get("pickup_type") != 5:
        issues.append("pickup_type 不是 COLLECTIBLE")
    if data.get("can_store_in_inventory") is not True:
        issues.append("不可放入背包")
    if not str(data.get("display_name", "")).strip():
        issues.append("缺少显示名称")
    if not str(data.get("description", "")).strip():
        issues.append("缺少描述")
    if not str(data.get("collectible_effect_id", "")).strip():
        issues.append("缺少 collectible_effect_id")

    max_copies = int(data.get("collectible_max_copies", 0))
    if max_copies < 0:
        issues.append("collectible_max_copies 不能为负数")
    if max_copies > 0 and data.get("collectible_stacks_by_copy") is not True:
        issues.append("设置 collectible_max_copies 时必须允许逐份叠加")
    for field in PROBABILITY_EFFECT_FIELDS:
        value = float(data.get(field, FIELD_DEFAULTS[field]))
        if value < 0.0 or value > 1.0:
            issues.append(f"{field} 必须位于 0-1 之间")
    for field in STATUS_TARGET_DAMAGE_FIELDS:
        if float(data.get(field, FIELD_DEFAULTS[field])) < 1.0:
            issues.append(f"{field} 不能低于 1.0")

    rarity = data.get("collectible_rarity")
    if rarity not in RARITY_LABELS:
        issues.append(f"稀有度无效: {rarity}")

    if not has_meaningful_effect(data):
        issues.append("没有可运行的收藏品效果")
    validate_unique_design_fields(data, issues, config_name in ORIGINAL_CONFIG_NAMES)

    periodic = data.get("periodic_effect_id", "")
    if periodic:
        if periodic not in VALID_PERIODIC_EFFECTS:
            issues.append(f"未知周期效果: {periodic}")
        if data.get("periodic_interval", 0.0) <= 0.0:
            issues.append("周期效果缺少正数 interval")
        if periodic != "sakura_rocket" and data.get("periodic_radius", 0.0) <= 0.0:
            issues.append("周期效果缺少正数 radius")
        if periodic == "thunder" and data.get("periodic_damage", 0) <= 0:
            issues.append("闪电周期效果缺少伤害")
        if periodic == "frost":
            if data.get("periodic_damage", 0) <= 0:
                issues.append("寒霜周期效果缺少伤害")
            if data.get("periodic_slow_multiplier", 1.0) >= 1.0:
                issues.append("寒霜周期效果没有减速")
            if data.get("periodic_slow_duration", 0.0) <= 0.0:
                issues.append("寒霜周期效果缺少减速持续时间")
        if periodic == "heal" and data.get("periodic_heal", 0) <= 0:
            issues.append("治疗周期效果缺少治疗量")
        if periodic == "archer":
            if data.get("periodic_attack_damage_multiplier", 0.0) <= 0.0:
                issues.append("弓箭周期效果缺少攻击倍率")
            if data.get("periodic_target_count", 0) <= 0:
                issues.append("弓箭周期效果缺少目标数量")
        if periodic == "sakura_rocket":
            if data.get("periodic_damage", 0) <= 0:
                issues.append("樱花导弹周期效果缺少伤害")
            if data.get("periodic_target_count", 0) <= 0:
                issues.append("樱花导弹周期效果缺少目标数量")

    skill = data.get("skill_effect_id", "")
    if skill:
        if skill not in VALID_SKILL_EFFECTS:
            issues.append(f"未知技能触发效果: {skill}")
        if data.get("skill_effect_duration", 0.0) <= 0.0:
            issues.append("技能触发效果缺少持续时间")
        if skill == "moon_shield" and data.get("skill_effect_radius", 0.0) <= 0.0:
            issues.append("月盾技能效果缺少半径")
        if skill == "swift" and data.get("skill_move_speed_multiplier", 1.0) <= 1.0:
            issues.append("迅捷技能效果没有移速提升")

    if bool(data.get("attack_speed_xirang_step", 0)) != bool(data.get("attack_speed_bonus_per_xirang_step", 0.0)):
        issues.append("息壤攻速字段不成对")
    if bool(data.get("defense_xirang_step", 0)) != bool(data.get("defense_bonus_per_xirang_step", 0)):
        issues.append("息壤防御字段不成对")
    validate_xirang_scaling_balance(data, issues)


def audit_collectibles() -> list[CollectibleAudit]:
    audits: list[CollectibleAudit] = []
    for path in sorted(CONFIG_DIR.glob("collectible_*.tres")):
        data = parse_config(path)
        issues: list[str] = []
        validate_logic_fields(data, issues, path.name)
        icon_path, icon_bbox, alpha_pixels = audit_icon(data, issues)
        audits.append(
            CollectibleAudit(
                path=path,
                data=data,
                icon_path=icon_path,
                icon_bbox=icon_bbox,
                icon_alpha_pixels=alpha_pixels,
                effect_summary=summarize_effect(data),
                effect_signature=non_default_effect_fields(data),
                design_profile=design_profile(data),
                issues=issues,
            )
        )

    new_audits = [audit for audit in audits if audit.path.name not in ORIGINAL_CONFIG_NAMES]

    signature_map: dict[tuple[tuple[str, Any], ...], list[CollectibleAudit]] = defaultdict(list)
    for audit in new_audits:
        signature_map[audit.effect_signature].append(audit)
    for duplicates in signature_map.values():
        if len(duplicates) <= 1:
            continue
        names = "、".join(str(audit.data.get("display_name", audit.path.name)) for audit in duplicates)
        for audit in duplicates:
            audit.issues.append(f"效果组合与其他收藏品完全重复: {names}")

    effect_ids = Counter(str(audit.data.get("collectible_effect_id", "")) for audit in audits)
    for audit in audits:
        effect_id = str(audit.data.get("collectible_effect_id", ""))
        if effect_ids[effect_id] > 1:
            audit.issues.append(f"collectible_effect_id 重复: {effect_id}")

    design_ids = Counter(str(audit.data.get("collectible_design_id", "")) for audit in new_audits)
    for audit in new_audits:
        design_id = str(audit.data.get("collectible_design_id", ""))
        if design_id and design_ids[design_id] > 1:
            audit.issues.append(f"collectible_design_id 重复: {design_id}")

    design_profile_map: dict[tuple[tuple[str, Any], ...], list[CollectibleAudit]] = defaultdict(list)
    for audit in new_audits:
        if not audit.design_profile:
            continue
        design_profile_map[audit.design_profile].append(audit)
    for duplicates in design_profile_map.values():
        if len(duplicates) <= 1:
            continue
        names = "、".join(str(audit.data.get("display_name", audit.path.name)) for audit in duplicates)
        for audit in duplicates:
            audit.issues.append(f"独特机制组合与其他收藏品重复: {names}")

    return audits


def write_report(audits: list[CollectibleAudit]) -> None:
    total_issues = sum(len(audit.issues) for audit in audits)
    rarity_counts = Counter(int(audit.data.get("collectible_rarity", -1)) for audit in audits)
    new_count = len([audit for audit in audits if audit.path.name not in ORIGINAL_CONFIG_NAMES])

    lines = [
        "# 收藏品逐项审计报告",
        "",
        f"- 配置总数: {len(audits)}",
        f"- 新增收藏品数: {new_count}",
        f"- 问题总数: {total_issues}",
        "- 稀有度分布: "
        + "，".join(f"{RARITY_LABELS.get(rarity, str(rarity))} {count}" for rarity, count in sorted(rarity_counts.items())),
        "",
        "| 文件 | 名称 | 稀有度 | 效果摘要 | 设计说明 | 图标主体 | 图标像素 | 问题 |",
        "| --- | --- | --- | --- | --- | --- | ---: | --- |",
    ]

    for audit in audits:
        bbox_text = "无"
        if audit.icon_bbox is not None:
            bbox_text = "%dx%d" % (
                audit.icon_bbox[2] - audit.icon_bbox[0],
                audit.icon_bbox[3] - audit.icon_bbox[1],
            )
        issues = "<br>".join(audit.issues) if audit.issues else "OK"
        rarity = RARITY_LABELS.get(int(audit.data.get("collectible_rarity", -1)), "?")
        rel_path = audit.path.relative_to(PROJECT_ROOT).as_posix()
        lines.append(
            "| %s | %s | %s | %s | %s | %s | %d | %s |"
            % (
                rel_path,
                str(audit.data.get("display_name", "")),
                rarity,
                audit.effect_summary,
                str(audit.data.get("collectible_design_note", "")),
                bbox_text,
                audit.icon_alpha_pixels,
                issues,
            )
        )

    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


ORIGINAL_CONFIG_NAMES = {
    "collectible_admin_doll.tres",
    "collectible_amethyst.tres",
    "collectible_apple.tres",
    "collectible_archer.tres",
    "collectible_charged_jade_pendant.tres",
    "collectible_emerald.tres",
    "collectible_frost_crystal.tres",
    "collectible_gold_wine_cup.tres",
    "collectible_gray_gem.tres",
    "collectible_life_crystal.tres",
    "collectible_life_ring.tres",
    "collectible_lucky_gem.tres",
    "collectible_magic_ring.tres",
    "collectible_medieval_shield.tres",
    "collectible_moon_amulet.tres",
    "collectible_nine_eleven.tres",
    "collectible_physical_ring.tres",
    "collectible_power_ring.tres",
    "collectible_ruby.tres",
    "collectible_speed_ring.tres",
    "collectible_swift_crystal.tres",
    "collectible_thunder_crystal.tres",
    "collectible_tianshi_stake.tres",
    "collectible_topaz.tres",
}


def main() -> None:
    audits = audit_collectibles()
    write_report(audits)

    errors: list[str] = []
    if len(audits) != EXPECTED_TOTAL_COUNT:
        errors.append(f"Expected {EXPECTED_TOTAL_COUNT} collectibles, found {len(audits)}")

    new_count = len([audit for audit in audits if audit.path.name not in ORIGINAL_CONFIG_NAMES])
    if new_count != NEW_COLLECTIBLE_COUNT:
        errors.append(f"Expected {NEW_COLLECTIBLE_COUNT} new collectibles, found {new_count}")

    for audit in audits:
        for issue in audit.issues:
            errors.append(f"{audit.path.name}: {issue}")

    summary = {
        "collectible_count": len(audits),
        "new_collectible_count": new_count,
        "issue_count": len(errors),
        "report": str(REPORT_PATH),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if errors:
        print("\n".join(errors))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
