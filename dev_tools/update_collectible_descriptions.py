#!/usr/bin/env python3
"""Regenerate collectible descriptions from their gameplay fields."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = PROJECT_ROOT / "resources" / "config" / "collectibles"
THUNDER_LOCAL_TARGET_RADIUS = 256.0


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
    return data


def fmt_num(value: Any) -> str:
    if isinstance(value, float):
        if abs(value - round(value)) < 0.000001:
            return str(int(round(value)))
        return f"{value:.2f}".rstrip("0").rstrip(".")
    return str(value)


def percent(value: float) -> str:
    return f"{fmt_num(value * 100.0)}%"


def signed_num(value: Any) -> str:
    numeric_value = float(value)
    sign = "+" if numeric_value > 0.0 else ""
    return sign + fmt_num(value)


def cooldown_text(cooldown: float) -> str:
    return f"，冷却{fmt_num(cooldown)}秒" if cooldown > 0.0 else ""


def stat_parts(data: dict[str, Any], prefix: str = "") -> list[str]:
    parts: list[str] = []
    labels = (
        ("attack_bonus", "攻击力"),
        ("max_health_bonus", "生命上限"),
        ("move_speed_bonus", "移动速度"),
        ("attack_speed_bonus", "攻击速度"),
        ("physical_defense_bonus", "物理防御"),
        ("magic_defense_bonus", "法术防御"),
        ("physical_damage_bonus", "物理伤害"),
        ("magic_damage_bonus", "法术伤害"),
    )
    for field, label in labels:
        value = data.get(prefix + field, 0)
        if value:
            parts.append(f"{label}{signed_num(value)}")
    charge_bonus = float(data.get(prefix + "skill_charge_bonus_per_second", 0.0))
    if charge_bonus:
        parts.append(f"技力充能{signed_num(charge_bonus)}/秒")
    pierce_chance = float(data.get(prefix + "bullet_pierce_chance", 0.0))
    if pierce_chance:
        parts.append(f"普通子弹穿透概率+{percent(pierce_chance)}")
    return parts


def describe_condition(data: dict[str, Any]) -> str:
    effect_id = str(data.get("conditional_effect_id", ""))
    if not effect_id:
        return ""
    bonuses = stat_parts(data, "conditional_")
    if not bonuses:
        return ""
    if effect_id == "health_below":
        condition = f"生命不高于{percent(float(data.get('conditional_health_ratio_threshold', 0.0)))}时"
    elif effect_id == "health_above":
        condition = f"生命不低于{percent(float(data.get('conditional_health_ratio_threshold', 0.0)))}时"
    elif effect_id == "xirang_at_least":
        condition = f"持有息壤不少于{fmt_num(data.get('conditional_xirang_threshold', 0))}时"
    elif effect_id == "xirang_below":
        condition = f"持有息壤少于{fmt_num(data.get('conditional_xirang_threshold', 0))}时"
    elif effect_id == "skill_unlocked":
        condition = "技能已解锁时"
    elif effect_id == "skill_locked":
        condition = "技能未解锁时"
    else:
        condition = "条件满足时"
    return f"{condition}，{'、'.join(bonuses)}"


def describe_periodic(data: dict[str, Any]) -> str:
    effect_id = str(data.get("periodic_effect_id", ""))
    if not effect_id:
        return ""
    interval = fmt_num(data.get("periodic_interval", 0.0))
    radius = fmt_num(data.get("periodic_radius", 0.0))
    if effect_id == "thunder":
        return (
            f"每{interval}秒优先随机雷击自身周围{fmt_num(THUNDER_LOCAL_TARGET_RADIUS)}范围内1名敌人"
            "，附近无目标时改选全场，"
            f"对击中点{radius}范围敌人造成{fmt_num(data.get('periodic_damage', 0))}法术伤害"
        )
    if effect_id == "frost":
        return (
            f"每{interval}秒释放{radius}范围寒霜，造成{fmt_num(data.get('periodic_damage', 0))}法术伤害，"
            f"并减速{percent(1.0 - float(data.get('periodic_slow_multiplier', 1.0)))}，"
            f"持续{fmt_num(data.get('periodic_slow_duration', 0.0))}秒"
        )
    if effect_id == "heal":
        return f"每{interval}秒治疗{radius}范围友方{fmt_num(data.get('periodic_heal', 0))}生命"
    if effect_id == "archer":
        return (
            f"每{interval}秒向{radius}范围内最近{fmt_num(data.get('periodic_target_count', 1))}名敌人射箭，"
            f"每支造成攻击力{percent(float(data.get('periodic_attack_damage_multiplier', 0.0)))}的物理伤害"
        )
    if effect_id == "sakura_rocket":
        return (
            f"每{interval}秒向最近{fmt_num(data.get('periodic_target_count', 1))}名敌人发射追踪樱花导弹，"
            f"爆炸半径47，造成{fmt_num(data.get('periodic_damage', 0))}法术伤害"
        )
    return ""


def describe_skill(data: dict[str, Any]) -> str:
    effect_id = str(data.get("skill_effect_id", ""))
    if not effect_id:
        return ""
    if effect_id == "moon_shield":
        return (
            f"使用技能时生成半径{fmt_num(data.get('skill_effect_radius', 0.0))}的月盾，"
            f"持续{fmt_num(data.get('skill_effect_duration', 0.0))}秒，月盾内友方受到伤害减半"
        )
    if effect_id == "swift":
        speed_bonus = percent(float(data.get("skill_move_speed_multiplier", 1.0)) - 1.0)
        return f"使用技能后移动速度+{speed_bonus}，持续{fmt_num(data.get('skill_effect_duration', 0.0))}秒"
    return ""


def trigger_event_text(effect_id: str, data: dict[str, Any]) -> str:
    if effect_id.startswith("shot_"):
        return f"每{fmt_num(data.get('trigger_shot_interval', 1))}次射击"
    if effect_id.startswith("hurt_"):
        return "受伤时"
    if effect_id.startswith("skill_"):
        return "使用技能时"
    return "触发时"


def describe_trigger(data: dict[str, Any]) -> str:
    effect_id = str(data.get("trigger_effect_id", ""))
    if not effect_id:
        return ""
    event_text = trigger_event_text(effect_id, data)
    if effect_id.endswith("_heal"):
        effect_text = f"回复{fmt_num(data.get('trigger_heal', 0))}生命"
    elif effect_id.endswith("_xirang"):
        effect_text = f"获得{fmt_num(data.get('trigger_xirang', 0))}息壤"
    elif effect_id.endswith("_charge"):
        effect_text = f"补充{fmt_num(data.get('trigger_skill_charge', 0.0))}秒技力"
    elif effect_id.endswith("_thunder"):
        effect_text = (
            f"优先随机雷击自身周围{fmt_num(THUNDER_LOCAL_TARGET_RADIUS)}范围内1名敌人"
            "，附近无目标时改选全场，"
            f"对击中点{fmt_num(data.get('trigger_radius', 0.0))}"
            f"范围敌人造成{fmt_num(data.get('trigger_damage', 0))}法术伤害"
        )
    elif effect_id.endswith("_frost"):
        effect_text = (
            f"释放{fmt_num(data.get('trigger_radius', 0.0))}范围寒霜，"
            f"造成{fmt_num(data.get('trigger_damage', 0))}法术伤害，"
            f"并减速{percent(1.0 - float(data.get('trigger_slow_multiplier', 1.0)))}, "
            f"持续{fmt_num(data.get('trigger_slow_duration', 0.0))}秒"
        ).replace(", ", "，")
    else:
        return ""
    return f"{event_text}{effect_text}{cooldown_text(float(data.get('trigger_cooldown', 0.0)))}"


def describe_on_hit(data: dict[str, Any]) -> str:
    effect_id = str(data.get("on_hit_effect_id", ""))
    if not effect_id:
        return ""
    chance = percent(float(data.get("on_hit_chance", 0.0)))
    cooldown = cooldown_text(float(data.get("on_hit_cooldown", 0.0)))
    duration = fmt_num(data.get("on_hit_duration", 0.0))
    tick_interval = fmt_num(1.0 if effect_id == "burn" else data.get("on_hit_tick_interval", 0.5))
    damage = fmt_num(data.get("on_hit_damage", 0))
    if effect_id == "burn":
        return f"攻击命中时，{chance}概率使敌人燃烧{duration}秒，每{tick_interval}秒受{damage}法术伤害{cooldown}"
    if effect_id == "bleed":
        return f"攻击命中时，{chance}概率使敌人流血{duration}秒，每{tick_interval}秒受{damage}物理伤害{cooldown}"
    if effect_id == "chill":
        slow = percent(1.0 - float(data.get("on_hit_slow_multiplier", 1.0)))
        if float(data.get("on_hit_damage", 0)) == 0.0:
            return f"攻击命中时，{chance}概率使敌人寒冷{duration}秒，移速-{slow}{cooldown}"
        return (
            f"攻击命中时，{chance}概率使敌人寒冷{duration}秒，"
            f"每{tick_interval}秒受{damage}法术伤害，移速-{slow}{cooldown}"
        )
    if effect_id == "shock":
        return (
            f"攻击命中时，{chance}概率对命中点{fmt_num(data.get('on_hit_radius', 0.0))}"
            f"范围敌人造成{damage}法术伤害{cooldown}"
        )
    if effect_id == "mark":
        extra_damage = float(data.get("on_hit_damage_taken_multiplier", 1.0)) - 1.0
        return (
            f"攻击命中时，{chance}概率标记敌人{duration}秒，"
            f"使其额外受到{percent(extra_damage)}伤害{cooldown}"
        )
    if effect_id == "crack":
        return (
            f"攻击命中时，{chance}概率使敌人物理防御"
            f"{signed_num(data.get('on_hit_physical_defense_modifier', 0))}，持续{duration}秒{cooldown}"
        )
    if effect_id == "leech":
        return f"攻击命中时，{chance}概率回复自身{fmt_num(data.get('on_hit_heal', 0))}生命{cooldown}"
    if effect_id == "siphon":
        return f"攻击命中时，{chance}概率补充{fmt_num(data.get('on_hit_skill_charge', 0.0))}秒技力{cooldown}"
    if effect_id == "execute":
        return (
            f"攻击命中时，{chance}概率处决生命不高于"
            f"{percent(float(data.get('on_hit_execute_health_ratio', 0.0)))}的非Boss敌人{cooldown}"
        )
    if effect_id == "bloom":
        return (
            f"攻击命中时，{chance}概率治疗命中点{fmt_num(data.get('on_hit_radius', 0.0))}"
            f"范围友方{fmt_num(data.get('on_hit_heal', 0))}生命{cooldown}"
        )
    if effect_id == "xirang":
        return f"攻击命中时，{chance}概率获得{fmt_num(data.get('on_hit_xirang', 0))}息壤{cooldown}"
    return ""


def describe_kill(data: dict[str, Any]) -> str:
    effect_id = str(data.get("kill_effect_id", ""))
    if not effect_id:
        return ""
    cooldown = cooldown_text(float(data.get("kill_cooldown", 0.0)))
    if effect_id == "heal":
        return f"击败敌人时回复{fmt_num(data.get('kill_heal', 0))}生命{cooldown}"
    if effect_id == "xirang":
        return f"击败敌人时获得{fmt_num(data.get('kill_xirang', 0))}息壤{cooldown}"
    if effect_id == "charge":
        return f"击败敌人时补充{fmt_num(data.get('kill_skill_charge', 0.0))}秒技力{cooldown}"
    if effect_id == "thunder":
        return (
            f"击败敌人时对其位置{fmt_num(data.get('kill_radius', 0.0))}范围敌人"
            f"造成{fmt_num(data.get('kill_damage', 0))}法术伤害{cooldown}"
        )
    if effect_id == "frost":
        return (
            f"击败敌人时对其位置{fmt_num(data.get('kill_radius', 0.0))}范围敌人"
            f"造成{fmt_num(data.get('kill_damage', 0))}法术伤害，并减速"
            f"{percent(1.0 - float(data.get('kill_slow_multiplier', 1.0)))}, "
            f"持续{fmt_num(data.get('kill_duration', 0.0))}秒{cooldown}"
        ).replace(", ", "，")
    if effect_id == "haste":
        return (
            f"击败敌人后移动速度+{percent(float(data.get('kill_move_speed_multiplier', 1.0)) - 1.0)}，"
            f"持续{fmt_num(data.get('kill_duration', 0.0))}秒{cooldown}"
        )
    if effect_id == "bloom":
        return (
            f"击败敌人时治疗其位置{fmt_num(data.get('kill_radius', 0.0))}范围友方"
            f"{fmt_num(data.get('kill_heal', 0))}生命{cooldown}"
        )
    if effect_id == "burst":
        return (
            f"击败敌人时对其位置{fmt_num(data.get('kill_radius', 0.0))}范围敌人"
            f"造成{fmt_num(data.get('kill_damage', 0))}物理伤害{cooldown}"
        )
    return ""


def generate_description(data: dict[str, Any]) -> str:
    if data.get("collectible_effect_id") == "admin_doll":
        return "庄方宜为你升级技能时不消耗息壤。"
    if data.get("collectible_effect_id") == "basketball":
        return "会在某个特殊节点发挥作用。"
    if data.get("collectible_effect_id") == "flying_envelope":
        return "一封不愿安分停留的信，似乎正寻找着某位收件人。"

    parts: list[str] = []
    ammo_additive = int(data.get("collectible_ammo_capacity_additive_bonus", 0))
    if ammo_additive:
        parts.append(f"弹匣容量+{ammo_additive}")

    ammo_ratio = float(data.get("collectible_ammo_capacity_bonus_ratio", 0.0))
    if ammo_ratio:
        parts.append(f"弹匣容量提高{percent(ammo_ratio)}")

    reload_reduction = float(data.get("collectible_reload_time_reduction", 0.0))
    if reload_reduction:
        parts.append(f"换弹时间缩短{percent(reload_reduction)}")

    dash_distance = float(data.get("collectible_dash_distance_bonus", 0.0))
    if dash_distance:
        parts.append(f"冲刺距离{signed_num(dash_distance)}")

    dash_cooldown_reduction = float(data.get("collectible_dash_cooldown_reduction", 0.0))
    if dash_cooldown_reduction:
        parts.append(f"冲刺冷却减少{fmt_num(dash_cooldown_reduction)}秒")

    parts.extend(stat_parts(data, "collectible_"))

    pierce_chance = float(data.get("bullet_pierce_chance", 0.0))
    if pierce_chance:
        parts.append(f"普通子弹有{percent(pierce_chance)}概率穿透敌人")

    homing_chance = float(data.get("bullet_homing_chance", 0.0))
    if homing_chance:
        parts.append(f"普通子弹有{percent(homing_chance)}概率获得中等偏强的追踪能力")

    ammo_free_chance = float(data.get("ammo_free_shot_chance", 0.0))
    if ammo_free_chance:
        parts.append(f"普通射击有{percent(ammo_free_chance)}概率不消耗弹药")

    skill_preserve_chance = float(data.get("skill_charge_preserve_chance", 0.0))
    if skill_preserve_chance:
        parts.append(f"使用技能时有{percent(skill_preserve_chance)}概率不消耗技力")

    free_chance = float(data.get("base_upgrade_free_chance", 0.0))
    if free_chance:
        parts.append(f"升级基础属性时，{percent(free_chance)}概率不消耗息壤")

    front_multiplier = float(data.get("incoming_ranged_front_damage_multiplier", 1.0))
    if front_multiplier != 1.0:
        if front_multiplier > 1.0:
            parts.append(f"受到的正面远程伤害提高{percent(front_multiplier - 1.0)}")
        else:
            parts.append(f"受到的正面远程伤害降低{percent(1.0 - front_multiplier)}")

    back_multiplier = float(data.get("incoming_ranged_back_damage_multiplier", 1.0))
    if back_multiplier != 1.0:
        if back_multiplier > 1.0:
            parts.append(f"受到的背面远程伤害提高{percent(back_multiplier - 1.0)}")
        else:
            parts.append(f"受到的背面远程伤害降低{percent(1.0 - back_multiplier)}")

    ranged_dodge = float(data.get("incoming_ranged_dodge_chance", 0.0))
    if ranged_dodge:
        parts.append(f"受到远程攻击时，额外{percent(ranged_dodge)}概率闪避")

    attack_speed_step = int(data.get("attack_speed_xirang_step", 0))
    if attack_speed_step:
        parts.append(
            f"每持有{fmt_num(attack_speed_step)}息壤，攻击速度+"
            f"{fmt_num(data.get('attack_speed_bonus_per_xirang_step', 0.0))}"
        )

    defense_step = int(data.get("defense_xirang_step", 0))
    if defense_step:
        parts.append(
            f"每持有{fmt_num(defense_step)}息壤，物理防御和法术防御各+"
            f"{fmt_num(data.get('defense_bonus_per_xirang_step', 0))}"
        )

    for describe in (
        describe_condition,
        describe_periodic,
        describe_skill,
        describe_trigger,
        describe_on_hit,
        describe_kill,
    ):
        text = describe(data)
        if text:
            parts.append(text)

    if not parts:
        return str(data.get("description", ""))

    description = "；".join(parts)
    if bool(data.get("collectible_stacks_by_copy", False)):
        description += "（可叠加）"
    return description + "。"


def replace_description(path: Path, description: str) -> None:
    text = path.read_text(encoding="utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    escaped = description.replace("\\", "\\\\").replace('"', '\\"')
    next_text, count = re.subn(
        r'^description = ".*"$',
        f'description = "{escaped}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise RuntimeError(f"{path} does not contain exactly one description line")
    if next_text != text:
        with path.open("w", encoding="utf-8", newline=newline) as file:
            file.write(next_text)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if any description is out of date")
    parser.add_argument("--print-changes", action="store_true", help="print planned or applied changes")
    args = parser.parse_args()

    changed: list[tuple[Path, str, str]] = []
    for path in sorted(CONFIG_DIR.glob("collectible_*.tres")):
        data = parse_config(path)
        current = str(data.get("description", ""))
        generated = generate_description(data)
        if current != generated:
            changed.append((path, current, generated))

    if args.print_changes:
        for path, current, generated in changed:
            print(path.relative_to(PROJECT_ROOT))
            print(f"  - {current}")
            print(f"  + {generated}")

    if args.check:
        if changed:
            print(f"{len(changed)} collectible descriptions are out of date.")
            return 1
        print("All collectible descriptions are up to date.")
        return 0

    for path, _current, generated in changed:
        replace_description(path, generated)
    print(f"Updated {len(changed)} collectible descriptions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
