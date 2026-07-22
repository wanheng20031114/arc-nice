#!/usr/bin/env python3
"""Regenerate exact, implementation-facing collectible design notes.

The player-facing ``description`` stays short.  ``collectible_design_note`` is
the canonical place for exact values, activation/copy rules, compatibility,
and the calculation order needed to reproduce the runtime behavior.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

from update_collectible_descriptions import (
    THUNDER_LOCAL_TARGET_RADIUS,
    fmt_num,
    parse_config,
    percent,
)


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = PROJECT_ROOT / "resources" / "config" / "collectibles"


def _pct_points(value: float) -> str:
    return f"{fmt_num(value * 100.0)}个百分点"


def _increase_percent(multiplier: float) -> str:
    return percent(max(multiplier - 1.0, 0.0))


def _decrease_percent(multiplier: float) -> str:
    return percent(max(1.0 - multiplier, 0.0))


def _cooldown(value: Any) -> str:
    seconds = float(value or 0.0)
    return f"；触发冷却为{fmt_num(seconds)}秒" if seconds > 0.0 else ""


def _fixed_damage_formula(damage_type: str) -> str:
    if damage_type == "物理":
        defense_rule = "命中后先计算max(出手值-目标有效物理防御,1)"
    elif damage_type == "法术":
        defense_rule = (
            "命中后先将目标有效魔法防御钳制在0至100，再计算"
            "max(floor(出手值×(100-有效魔法防御)/100),1)"
        )
    else:
        raise ValueError(f"unknown damage type: {damage_type}")
    return (
        f"实际出手{damage_type}伤害为配置伤害加当前{damage_type}伤害加成，出手值至少为1点；"
        f"{defense_rule}，再乘目标承伤倍率并四舍五入，最终至少为1点"
    )


def _temporary_slow_rule() -> str:
    return (
        "每次寒霜触发分配独立的临时减速来源；与寒冷及其他仍生效减速来源的移速倍率彼此连乘；"
        "每个来源独立计时，到期仅移除自身，并从敌人基础移速与其余仍生效倍率重新计算"
    )


def _static_stat_rule(data: dict[str, Any]) -> list[str]:
    stats: list[str] = []
    labels = (
        ("collectible_attack_bonus", "攻击力"),
        ("collectible_max_health_bonus", "生命上限"),
        ("collectible_move_speed_bonus", "移动速度"),
        ("collectible_attack_speed_bonus", "攻击速度"),
        ("collectible_dash_distance_bonus", "冲刺距离"),
        ("collectible_physical_defense_bonus", "物理防御"),
        ("collectible_magic_defense_bonus", "魔法防御"),
        ("collectible_physical_damage_bonus", "物理伤害"),
        ("collectible_magic_damage_bonus", "法术伤害"),
    )
    for field, label in labels:
        value = data.get(field, 0)
        if float(value) != 0.0:
            stats.append(f"{label}+{fmt_num(value)}")

    skill_charge = float(data.get("collectible_skill_charge_bonus_per_second", 0.0))
    if skill_charge != 0.0:
        stats.append(f"技力充能+{fmt_num(skill_charge)}/秒")

    dash_cooldown = float(data.get("collectible_dash_cooldown_reduction", 0.0))
    if dash_cooldown != 0.0:
        stats.append(f"冲刺冷却减少{fmt_num(dash_cooldown)}秒")

    if not stats:
        return []

    rules = ["每个生效副本提供" + "、".join(stats)]
    if int(data.get("collectible_attack_bonus", 0)) != 0:
        rules.append(
            "最终攻击力=max(ceil((round(角色基础攻击力)+所有有效攻击力加成)×max(当前临时攻击倍率,0.1)),1)"
        )
    if int(data.get("collectible_max_health_bonus", 0)) != 0:
        rules.append(
            "最终生命上限=max(角色基础生命上限+所有有效生命上限加成,1)；刷新上限时当前生命只钳制到新上限，不额外治疗"
        )
    if float(data.get("collectible_move_speed_bonus", 0.0)) != 0.0:
        rules.append("移动速度加成与角色基础移动速度加算，结果不低于0")
    if float(data.get("collectible_attack_speed_bonus", 0.0)) != 0.0:
        rules.append(
            "攻击速度加成先与角色基础攻击速度加算，再乘角色当前射速倍率；实际射击间隔至少0.01秒"
        )
    if dash_cooldown != 0.0:
        rules.append(
            "每件收藏品的冲刺冷却减秒先钳制在0至0.5秒，再与不同效果加算；最终冲刺冷却不低于0秒"
        )
    if float(data.get("collectible_dash_distance_bonus", 0.0)) != 0.0:
        rules.append("冲刺距离与角色基础冲刺距离加算，结果不低于0")
    if int(data.get("collectible_magic_defense_bonus", 0)) != 0:
        rules.append("角色总魔法防御最终钳制在0至100之间")
    if int(data.get("collectible_physical_defense_bonus", 0)) != 0:
        rules.append("角色总物理防御为基础物理防御加所有有效加成，结果不低于0")
    if skill_charge != 0.0:
        rules.append(
            "实际技力充能速率为每秒1点基础充能加所有有效充能加成，达到当前技能所需技力后停止"
        )
    if (
        int(data.get("collectible_physical_damage_bonus", 0)) != 0
        or int(data.get("collectible_magic_damage_bonus", 0)) != 0
    ):
        rules.append("对应伤害类型在基础伤害上加算，结果至少为1点")
    return rules


def _ammunition_rules(data: dict[str, Any]) -> list[str]:
    rules: list[str] = []
    additive = int(data.get("collectible_ammo_capacity_additive_bonus", 0))
    ratio = float(data.get("collectible_ammo_capacity_bonus_ratio", 0.0))
    reload_reduction = float(data.get("collectible_reload_time_reduction", 0.0))
    if additive:
        rules.append(f"每个生效副本使弹匣容量加算值+{additive}")
        rules.append(
            "最终弹匣容量=floor((角色基础弹匣容量+所有有效加算值)×(1+持有的最高百分比增幅))，结果至少为1发"
        )
    if ratio:
        rules.append(f"弹匣容量百分比增幅为{percent(ratio)}")
        rules.append(
            "多个百分比弹匣效果同时存在时只取最高增幅；最终弹匣容量=floor((角色基础弹匣容量+所有有效加算值)×(1+最高百分比增幅))，结果至少为1发"
        )
    if additive or ratio:
        rules.append(
            "容量刷新时，若当前弹药不少于刷新前的有效容量，则视为原先满弹并将当前弹药改为新容量；"
            "否则保留当前弹药但向下钳制到新容量。换弹中的当前弹药为0，容量变化不会补弹或重置换弹进度；"
            "换弹完成时填满届时最新容量"
        )
    if reload_reduction:
        rules.append(f"换弹时间缩短比例为{percent(reload_reduction)}")
        rules.append(
            "多个换弹缩短效果同时存在时只取最高比例，再将该比例钳制在0%至95%；"
            "有效换弹时间=角色基础换弹时间×(1-钳制后比例)，结果至少为0.01秒；"
            "换弹中途增减该效果会按新的有效换弹时间继续推进同一归一化进度，不会重置已完成进度"
        )
    return rules


def _probability_rules(data: dict[str, Any]) -> list[str]:
    rules: list[str] = []
    pierce = float(data.get("bullet_pierce_chance", 0.0))
    if pierce:
        rules.append(
            f"每个生效副本使普通子弹穿透概率增加{_pct_points(pierce)}；"
            "所有穿透概率按百分点相加，最终钳制在0%至100%"
        )

    homing = float(data.get("bullet_homing_chance", 0.0))
    if homing:
        rules.append(
            f"每个生效副本使普通子弹追踪概率增加{_pct_points(homing)}；"
            "所有追踪概率按百分点相加，最终钳制在0%至100%"
        )
        rules.append(
            "追踪判定成功时，在角色周围256范围、射击方向左右各60度内，从最多64个候选中选最近敌人；"
            "子弹以每秒5.5弧度转向，目标死亡或命中该目标后停止追踪"
        )

    free_ammo = float(data.get("ammo_free_shot_chance", 0.0))
    if free_ammo:
        rules.append(
            f"每个生效副本使普通射击不消耗弹药的概率增加{_pct_points(free_ammo)}；"
            "该概率与角色自身免耗弹概率相加，最终钳制在0%至100%"
        )

    preserve = float(data.get("skill_charge_preserve_chance", 0.0))
    if preserve:
        rules.append(
            f"每个生效副本使技能发动时保留全部技力的概率增加{_pct_points(preserve)}；"
            "所有技能免耗概率按百分点相加，最终钳制在0%至100%"
        )
        rules.append(
            "每个Player实例各自为技能1维护0.1秒最短成功发动间隔；不同玩家之间不共用该计时；"
            "即使免耗判定成功并保留满技力，同一玩家也不能绕过该间隔"
        )

    free_upgrade = float(data.get("base_upgrade_free_chance", 0.0))
    if free_upgrade:
        rules.append(
            f"升级基础属性时，每个生效副本提供{_pct_points(free_upgrade)}不消耗息壤概率；"
            "所有基础升级免耗概率按百分点相加，最终钳制在0%至100%"
        )

    dodge = float(data.get("incoming_ranged_dodge_chance", 0.0))
    if dodge:
        rules.append(
            f"收到标记为远程的伤害时，每个生效副本额外提供{_pct_points(dodge)}闪避概率；"
            "所有收藏品远程闪避概率按百分点相加，最终钳制在0%至100%；"
            "角色普通闪避先独立判定，仅普通闪避失败后再判定这项收藏品远程闪避"
        )
    return rules


def _multiplier_rules(data: dict[str, Any]) -> list[str]:
    rules: list[str] = []
    burn = float(data.get("damage_against_burning_multiplier", 1.0))
    bleed = float(data.get("damage_against_bleeding_multiplier", 1.0))
    if burn != 1.0:
        rules.append(
            f"攻击带有燃烧状态的敌人时伤害乘以{fmt_num(burn)}；"
            "燃烧与流血目标增伤若同时满足则倍率连乘，之后四舍五入且伤害至少为1点"
        )
    if bleed != 1.0:
        rules.append(
            f"攻击带有流血状态的敌人时伤害乘以{fmt_num(bleed)}；"
            "燃烧与流血目标增伤若同时满足则倍率连乘，之后四舍五入且伤害至少为1点"
        )

    front = float(data.get("incoming_ranged_front_damage_multiplier", 1.0))
    back = float(data.get("incoming_ranged_back_damage_multiplier", 1.0))
    if front != 1.0:
        rules.append(f"远程伤害来源位于角色正面时，受击原始伤害乘以{fmt_num(front)}")
    if back != 1.0:
        rules.append(f"远程伤害来源位于角色背面时，受击原始伤害乘以{fmt_num(back)}")
    if front != 1.0 or back != 1.0:
        rules.append(
            "同一方向的多个收藏品倍率在属性刷新时彼此连乘；每次远程受击只按角色朝向与伤害来源方向的点积择一结算："
            "点积不小于0.35时使用正面总倍率，不大于-0.35时使用背面总倍率，中间侧向区间使用1；"
            "正面与背面倍率不会在同一次受击中连乘，所选倍率乘算后四舍五入且进入防御结算前至少为1点"
        )
    return rules


def _xirang_rules(data: dict[str, Any]) -> list[str]:
    rules: list[str] = []
    attack_step = int(data.get("attack_speed_xirang_step", 0))
    if attack_step:
        bonus = float(data.get("attack_speed_bonus_per_xirang_step", 0.0))
        rules.append(
            f"按floor(当前息壤/{attack_step})计算完整档数，每档攻击速度+{fmt_num(bonus)}；"
            "息壤数量变化时重新计算，并与其他攻击速度加成相加"
        )
    defense_step = int(data.get("defense_xirang_step", 0))
    if defense_step:
        bonus = int(data.get("defense_bonus_per_xirang_step", 0))
        rules.append(
            f"按floor(当前息壤/{defense_step})计算完整档数，每档物理防御和魔法防御各+{bonus}；"
            "息壤数量变化时重新计算，魔法防御最终钳制在0至100之间"
        )
    return rules


def _conditional_rule(data: dict[str, Any]) -> list[str]:
    effect_id = str(data.get("conditional_effect_id", ""))
    if not effect_id:
        return []
    if effect_id == "health_below":
        condition = f"当前生命/生命上限不高于{percent(float(data.get('conditional_health_ratio_threshold', 0.0)))}时"
    elif effect_id == "health_above":
        condition = f"当前生命/生命上限不低于{percent(float(data.get('conditional_health_ratio_threshold', 0.0)))}时"
    elif effect_id == "xirang_at_least":
        condition = f"当前息壤不少于{int(data.get('conditional_xirang_threshold', 0))}时"
    elif effect_id == "xirang_below":
        condition = f"当前息壤少于{int(data.get('conditional_xirang_threshold', 0))}时"
    elif effect_id == "skill_unlocked":
        condition = "技能已解锁时"
    elif effect_id == "skill_locked":
        condition = "技能未解锁时"
    else:
        raise ValueError(f"unknown conditional effect: {effect_id}")

    stats: list[str] = []
    labels = (
        ("conditional_attack_bonus", "攻击力"),
        ("conditional_max_health_bonus", "生命上限"),
        ("conditional_move_speed_bonus", "移动速度"),
        ("conditional_physical_defense_bonus", "物理防御"),
        ("conditional_magic_defense_bonus", "魔法防御"),
        ("conditional_physical_damage_bonus", "物理伤害"),
        ("conditional_magic_damage_bonus", "法术伤害"),
        ("conditional_skill_charge_bonus_per_second", "技力充能/秒"),
    )
    for field, label in labels:
        value = data.get(field, 0)
        if float(value) != 0.0:
            stats.append(f"{label}+{fmt_num(value)}")
    pierce = float(data.get("conditional_bullet_pierce_chance", 0.0))
    if pierce:
        stats.append(f"普通子弹穿透概率+{percent(pierce)}")
    return [f"{condition}，每个生效副本提供" + "、".join(stats) + "；条件变化时立即重新计算"]


def _periodic_rule(data: dict[str, Any]) -> list[str]:
    effect_id = str(data.get("periodic_effect_id", ""))
    if not effect_id:
        return []
    interval = fmt_num(data.get("periodic_interval", 0.0))
    radius = fmt_num(data.get("periodic_radius", 0.0))
    damage = int(data.get("periodic_damage", 0))
    if effect_id == "thunder":
        return [
            f"首次等待{interval}秒且之后每{interval}秒，优先从持有者周围"
            f"{fmt_num(THUNDER_LOCAL_TARGET_RADIUS)}范围内的存活敌人中随机选择1名；"
            "该范围内没有目标时，改从全部存活敌人中随机选择1名；"
            f"以其位置为中心对{radius}范围内敌人造成配置值{damage}点法术伤害；"
            + _fixed_damage_formula("法术")
            + "；没有存活敌人时本次不产生伤害但仍重新开始周期计时"
        ]
    if effect_id == "frost":
        slow = float(data.get("periodic_slow_multiplier", 1.0))
        duration = fmt_num(data.get("periodic_slow_duration", 0.0))
        return [
            f"首次等待{interval}秒且之后每{interval}秒，以持有者为中心影响{radius}范围敌人，"
            f"造成配置值{damage}点法术伤害，并使移速乘以{fmt_num(slow)}（降低{_decrease_percent(slow)}），持续{duration}秒；"
            + _fixed_damage_formula("法术")
            + "；"
            + _temporary_slow_rule()
        ]
    if effect_id == "heal":
        heal = int(data.get("periodic_heal", 0))
        return [
            f"首次等待{interval}秒且之后每{interval}秒，治疗持有者周围{radius}范围内所有存活友方{heal}点生命；"
            "治疗不超过各自生命上限"
        ]
    if effect_id == "archer":
        count = int(data.get("periodic_target_count", 1))
        multiplier = float(data.get("periodic_attack_damage_multiplier", 0.0))
        return [
            f"首次等待{interval}秒且之后每{interval}秒，选择持有者周围{radius}范围内最近的至多{count}名存活敌人并各发射1箭；"
            f"每箭先将当前攻击力×{fmt_num(multiplier)}四舍五入并至少取1，再加当前物理伤害加成，出手值至少为1点物理伤害；"
            "命中后减去目标有效物理防御并至少取1，再乘目标承伤倍率并四舍五入，最终至少为1点；"
            "没有有效目标时本次不发射但仍重新开始周期计时"
        ]
    if effect_id == "sakura_rocket":
        count = int(data.get("periodic_target_count", 1))
        search_radius = float(data.get("periodic_radius", 0.0))
        search_text = (
            "全部距离内"
            if search_radius <= 0.0
            else f"持有者周围{fmt_num(search_radius)}范围内"
        )
        return [
            f"首次等待{interval}秒且之后每{interval}秒，在{search_text}按距离查询至多{count}名存活敌人；"
            "搜索半径配置为0时表示不限制距离；无论查询上限是多少，实际只向查询结果第1名即最近目标发射1枚追踪樱花导弹；"
            f"爆炸半径47，配置值{damage}点法术伤害；"
            + _fixed_damage_formula("法术")
            + "；没有有效目标时本次不发射但仍重新开始周期计时"
        ]
    raise ValueError(f"unknown periodic effect: {effect_id}")


def _skill_rule(data: dict[str, Any]) -> list[str]:
    effect_id = str(data.get("skill_effect_id", ""))
    if not effect_id:
        return []
    duration = fmt_num(data.get("skill_effect_duration", 0.0))
    if effect_id == "moon_shield":
        radius = fmt_num(data.get("skill_effect_radius", 0.0))
        return [
            f"每次技能成功发动时，以持有者为中心生成半径{radius}、持续{duration}秒的月盾；"
            "进入月盾的友方获得50%伤害减免，离开或月盾结束时移除；多个减伤来源只取最高减伤比例；"
            "物理或法术防御先完成减伤并至少得到1点，之后再计算"
            "max(floor(防御后伤害×(1-最高减伤比例)),1)，因此奇数伤害向下取整且最终伤害至少为1点"
        ]
    if effect_id == "swift":
        multiplier = float(data.get("skill_move_speed_multiplier", 1.0))
        return [
            f"每次技能成功发动时，将收藏品迅捷倍率设为{fmt_num(multiplier)}（移动速度提高{_increase_percent(multiplier)}），持续{duration}秒；"
            "技能迅捷与击杀加速共用同一个收藏品迅捷倍率和剩余时间槽；任一效果后触发都会同时覆盖当前倍率与剩余时间；"
            "同次遍历触发多个迅捷效果时后处理者生效"
        ]
    raise ValueError(f"unknown skill effect: {effect_id}")


def _trigger_rule(data: dict[str, Any]) -> list[str]:
    effect_id = str(data.get("trigger_effect_id", ""))
    if not effect_id:
        return []
    if effect_id.startswith("shot_"):
        event = f"每完成{int(data.get('trigger_shot_interval', 1))}次普通攻击时"
    elif effect_id.startswith("hurt_"):
        event = "每次实际受到伤害且仍存活时"
    elif effect_id.startswith("skill_"):
        event = "每次技能成功发动时"
    else:
        raise ValueError(f"unknown trigger event: {effect_id}")

    if effect_id.endswith("_heal"):
        action = f"回复自身{int(data.get('trigger_heal', 0))}点生命，且不超过生命上限"
    elif effect_id.endswith("_xirang"):
        action = f"获得{int(data.get('trigger_xirang', 0))}息壤"
    elif effect_id.endswith("_charge"):
        action = f"补充{fmt_num(data.get('trigger_skill_charge', 0.0))}秒技力；仅技能已解锁、角色存活且技力未满时增加，并钳制到技能需求上限"
    elif effect_id.endswith("_thunder"):
        radius = fmt_num(data.get("trigger_radius", 0.0))
        damage = int(data.get("trigger_damage", 0))
        action = (
            f"优先从持有者周围{fmt_num(THUNDER_LOCAL_TARGET_RADIUS)}范围内的存活敌人中随机选择1名；"
            "该范围内没有目标时，改从全部存活敌人中随机选择1名；"
            f"对其位置{radius}范围内敌人造成配置值{damage}点法术伤害；"
            + _fixed_damage_formula("法术")
        )
    elif effect_id.endswith("_frost"):
        radius = fmt_num(data.get("trigger_radius", 0.0))
        damage = int(data.get("trigger_damage", 0))
        slow = float(data.get("trigger_slow_multiplier", 1.0))
        duration = fmt_num(data.get("trigger_slow_duration", 0.0))
        action = (
            f"以持有者为中心对{radius}范围内敌人造成配置值{damage}点法术伤害，"
            f"并使移速乘以{fmt_num(slow)}（降低{_decrease_percent(slow)}），持续{duration}秒；"
            + _fixed_damage_formula("法术")
            + "；"
            + _temporary_slow_rule()
        )
    else:
        raise ValueError(f"unknown trigger action: {effect_id}")
    cooldown = float(data.get("trigger_cooldown", 0.0))
    if cooldown > 0.0:
        no_effect_clause = ""
        if effect_id.endswith("_heal"):
            no_effect_clause = "；即使生命已满而没有获得治疗，冷却仍会消耗"
        elif effect_id.endswith("_charge"):
            no_effect_clause = "；即使技能未解锁、角色已死亡或技力已满而没有获得技力，冷却仍会消耗"
        elif effect_id.endswith("_thunder"):
            no_effect_clause = "；即使没有存活敌人可供落雷，冷却仍会消耗"
        return [event + f"若不在冷却中则先启动{fmt_num(cooldown)}秒冷却，再" + action + no_effect_clause]
    return [event + action]


def _on_hit_rule(data: dict[str, Any]) -> list[str]:
    effect_id = str(data.get("on_hit_effect_id", ""))
    if not effect_id:
        return []
    chance = percent(float(data.get("on_hit_chance", 0.0)))
    duration = fmt_num(data.get("on_hit_duration", 0.0))
    cooldown = float(data.get("on_hit_cooldown", 0.0))
    if cooldown > 0.0:
        prefix = (
            f"攻击命中基础伤害后仍存活的敌人时，先以{chance}概率判定；"
            f"判定成功且不在冷却时先启动{fmt_num(cooldown)}秒冷却，再"
        )
    else:
        prefix = f"攻击命中基础伤害后仍存活的敌人时，先以{chance}概率判定；判定成功时"
    if effect_id == "burn":
        damage = int(data.get("on_hit_damage", 0))
        tick = fmt_num(data.get("on_hit_tick_interval", 0.5))
        action = (
            f"施加持续{duration}秒的燃烧，每{tick}秒造成配置值{damage}点法术伤害；"
            + _fixed_damage_formula("法术")
            + "；跳伤值在施加状态时快照当时的法术伤害加成，之后加成变化不会修改该状态，直至再次施加；"
            "同一来源再次触发会替换状态并重置持续与跳伤计时；多个燃烧来源同时存在时仅跳伤值最高的一条推进并造成跳伤，"
            "其余燃烧的持续时间继续流逝但跳伤倒计时暂停"
        )
    elif effect_id == "bleed":
        damage = int(data.get("on_hit_damage", 0))
        tick = fmt_num(data.get("on_hit_tick_interval", 0.5))
        action = (
            f"施加持续{duration}秒的流血，每{tick}秒造成配置值{damage}点物理伤害；"
            + _fixed_damage_formula("物理")
            + "；跳伤值在施加状态时快照当时的物理伤害加成，之后加成变化不会修改该状态，直至再次施加；"
            "同一来源再次触发会替换状态并重置持续与跳伤计时；不同来源的流血各自独立跳伤"
        )
    elif effect_id == "chill":
        slow = float(data.get("on_hit_slow_multiplier", 1.0))
        damage = int(data.get("on_hit_damage", 0))
        tick = fmt_num(data.get("on_hit_tick_interval", 0.5))
        action = f"施加持续{duration}秒的寒冷，使移速乘以{fmt_num(slow)}（降低{_decrease_percent(slow)}）"
        if damage > 0:
            action += (
                f"，并每{tick}秒造成配置值{damage}点法术伤害；"
                + _fixed_damage_formula("法术")
                + "；跳伤值在施加状态时快照当时的法术伤害加成，之后加成变化不会修改该状态，直至再次施加"
            )
        action += "；同一来源再次触发会刷新该状态，不同来源的移速倍率彼此连乘"
    elif effect_id == "shock":
        radius = fmt_num(data.get("on_hit_radius", 0.0))
        damage = int(data.get("on_hit_damage", 0))
        action = f"对命中点{radius}范围内敌人造成配置值{damage}点法术伤害；" + _fixed_damage_formula("法术")
    elif effect_id == "mark":
        multiplier = float(data.get("on_hit_damage_taken_multiplier", 1.0))
        action = (
            f"标记目标{duration}秒，使其受到的伤害乘以{fmt_num(multiplier)}（提高{_increase_percent(multiplier)}）；"
            "同一来源再次触发会刷新该状态，不同来源的承伤倍率彼此连乘"
        )
    elif effect_id == "crack":
        modifier = int(data.get("on_hit_physical_defense_modifier", 0))
        action = (
            f"使目标物理防御{modifier:+d}，持续{duration}秒；"
            "同一来源再次触发会刷新该状态，不同来源的物理防御修饰相加，目标最终有效物理防御不低于0"
        )
    elif effect_id == "leech":
        action = f"回复自身{int(data.get('on_hit_heal', 0))}点生命，且不超过生命上限"
    elif effect_id == "siphon":
        action = f"补充{fmt_num(data.get('on_hit_skill_charge', 0.0))}秒技力；仅技能已解锁、角色存活且技力未满时增加，并钳制到技能需求上限"
    elif effect_id == "execute":
        threshold = percent(float(data.get("on_hit_execute_health_ratio", 0.0)))
        action = (
            f"仅在目标当前生命不高于其配置生命上限的{threshold}时，额外提交“目标当前生命+目标配置生命上限”的原始物理伤害；"
            "目标没有配置时，生命上限项改取判定时的当前生命；"
            "该额外伤害仍会先减去目标有效物理防御并至少取1，再乘目标承伤倍率、四舍五入并至少取1；"
            "因此极高物理防御下不保证击杀"
        )
    elif effect_id == "bloom":
        radius = fmt_num(data.get("on_hit_radius", 0.0))
        heal = int(data.get("on_hit_heal", 0))
        action = f"治疗命中点{radius}范围内所有存活友方{heal}点生命，且不超过各自生命上限"
    elif effect_id == "xirang":
        action = f"获得{int(data.get('on_hit_xirang', 0))}息壤"
    else:
        raise ValueError(f"unknown on-hit effect: {effect_id}")
    if cooldown > 0.0:
        if effect_id == "leech":
            action += "；即使生命已满而没有获得治疗，冷却仍会消耗"
        elif effect_id == "siphon":
            action += "；即使技能未解锁、角色已死亡或技力已满而没有获得技力，冷却仍会消耗"
        elif effect_id == "execute":
            action += "；即使目标未达到处决生命阈值，或达到阈值但减伤后仍未死亡，成功的概率判定仍会消耗冷却"
    action += (
        "；多个命中附加效果按背包槽及有效副本顺序依次处理；"
        "任一效果（包括处决）使目标死亡后立即停止后续命中附加效果，再按同一有效顺序处理击杀效果"
    )
    return [prefix + action]


def _kill_rule(data: dict[str, Any]) -> list[str]:
    effect_id = str(data.get("kill_effect_id", ""))
    if not effect_id:
        return []
    cooldown = float(data.get("kill_cooldown", 0.0))
    if cooldown > 0.0:
        prefix = f"玩家攻击命中并使敌人死亡时，若该效果不在冷却中则先启动{fmt_num(cooldown)}秒冷却，再"
    else:
        prefix = "玩家攻击命中并使敌人死亡时"
    if effect_id == "heal":
        action = f"回复自身{int(data.get('kill_heal', 0))}点生命，且不超过生命上限"
    elif effect_id == "xirang":
        action = f"获得{int(data.get('kill_xirang', 0))}息壤"
    elif effect_id == "charge":
        action = f"补充{fmt_num(data.get('kill_skill_charge', 0.0))}秒技力；仅技能已解锁、角色存活且技力未满时增加，并钳制到技能需求上限"
    elif effect_id == "thunder":
        radius = fmt_num(data.get("kill_radius", 0.0))
        damage = int(data.get("kill_damage", 0))
        action = f"以死亡位置为中心对{radius}范围内敌人造成配置值{damage}点法术伤害；" + _fixed_damage_formula("法术")
    elif effect_id == "frost":
        radius = fmt_num(data.get("kill_radius", 0.0))
        damage = int(data.get("kill_damage", 0))
        slow = float(data.get("kill_slow_multiplier", 1.0))
        duration = fmt_num(data.get("kill_duration", 0.0))
        action = (
            f"以死亡位置为中心对{radius}范围内敌人造成配置值{damage}点法术伤害，"
            f"并使移速乘以{fmt_num(slow)}（降低{_decrease_percent(slow)}），持续{duration}秒；"
            + _fixed_damage_formula("法术")
            + "；"
            + _temporary_slow_rule()
        )
    elif effect_id == "haste":
        multiplier = float(data.get("kill_move_speed_multiplier", 1.0))
        duration = fmt_num(data.get("kill_duration", 0.0))
        action = (
            f"将收藏品迅捷倍率设为{fmt_num(multiplier)}（移动速度提高{_increase_percent(multiplier)}），持续{duration}秒；"
            "击杀加速与技能迅捷共用同一个收藏品迅捷倍率和剩余时间槽；任一效果后触发都会同时覆盖当前倍率与剩余时间；"
            "同次遍历触发多个迅捷效果时后处理者生效"
        )
    elif effect_id == "bloom":
        radius = fmt_num(data.get("kill_radius", 0.0))
        heal = int(data.get("kill_heal", 0))
        action = f"治疗死亡位置{radius}范围内所有存活友方{heal}点生命，且不超过各自生命上限"
    elif effect_id == "burst":
        radius = fmt_num(data.get("kill_radius", 0.0))
        damage = int(data.get("kill_damage", 0))
        action = f"以死亡位置为中心对{radius}范围内敌人造成配置值{damage}点物理伤害；" + _fixed_damage_formula("物理")
    else:
        raise ValueError(f"unknown kill effect: {effect_id}")
    if cooldown > 0.0:
        if effect_id == "heal":
            action += "；即使生命已满而没有获得治疗，冷却仍会消耗"
        elif effect_id == "charge":
            action += "；即使技能未解锁、角色已死亡或技力已满而没有获得技力，冷却仍会消耗"
    return [prefix + action]


def _copy_rule(data: dict[str, Any]) -> str:
    if bool(data.get("collectible_stacks_by_copy", False)):
        maximum = int(data.get("collectible_max_copies", 0))
        if maximum > 0:
            return (
                f"副本规则：相同collectible_effect_id最多前{maximum}份参与效果计算；"
                f"第{maximum + 1}份及以后仍可放入背包并携带，但不再生效"
            )
        return "副本规则：效果层不设置生效份数上限，所有已携带副本均逐份参与效果计算"
    return (
        "副本规则：相同collectible_effect_id的重复副本仍可放入背包并携带，"
        "但仅1份参与效果计算，其余副本不生效"
    )


def _compatibility_rule(data: dict[str, Any]) -> str:
    projectile = bool(data.get("requires_projectile_primary_attack", False))
    ammunition = bool(data.get("requires_ammunition", False))
    if projectile and ammunition:
        return "角色兼容：候选池仅向普通攻击可生成投射物且具备弹药与换弹机制的角色提供此收藏品"
    if projectile:
        return "角色兼容：候选池仅向普通攻击可生成投射物的角色提供此收藏品"
    if ammunition:
        return "角色兼容：候选池仅向具备弹药与换弹机制的角色提供此收藏品"
    return ""


def _effect_rules(data: dict[str, Any]) -> list[str]:
    if str(data.get("collectible_effect_id", "")) == "admin_doll":
        return ["在庄方宜处升级已解锁技能的后续等级时，本次升级不消耗息壤"]

    rules: list[str] = []
    for builder in (
        _static_stat_rule,
        _ammunition_rules,
        _probability_rules,
        _multiplier_rules,
        _xirang_rules,
        _conditional_rule,
        _periodic_rule,
        _skill_rule,
        _trigger_rule,
        _on_hit_rule,
        _kill_rule,
    ):
        rules.extend(builder(data))
    if not rules:
        raise ValueError(f"{data.get('display_name', 'unknown')} has no rendered gameplay rule")
    return rules


def _note_title(data: dict[str, Any]) -> str:
    display_name = str(data.get("display_name", "")).strip()
    return f"{display_name}规则" if display_name else "收藏品规则"


def generate_design_note(data: dict[str, Any]) -> str:
    clauses = _effect_rules(data)
    clauses.append(_copy_rule(data))
    compatibility = _compatibility_rule(data)
    if compatibility:
        clauses.append(compatibility)
    return f"{_note_title(data)}：" + "。".join(clause.rstrip("。") for clause in clauses) + "。"


def replace_design_note(path: Path, design_note: str) -> None:
    text = path.read_text(encoding="utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    escaped = design_note.replace("\\", "\\\\").replace('"', '\\"')
    next_text, count = re.subn(
        r'^collectible_design_note = ".*"$',
        f'collectible_design_note = "{escaped}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise RuntimeError(f"{path} does not contain exactly one collectible_design_note line")
    if next_text != text:
        with path.open("w", encoding="utf-8", newline=newline) as file:
            file.write(next_text)


def collect_changes() -> list[tuple[Path, str, str]]:
    changes: list[tuple[Path, str, str]] = []
    for path in sorted(CONFIG_DIR.glob("collectible_*.tres")):
        data = parse_config(path)
        current = str(data.get("collectible_design_note", ""))
        generated = generate_design_note(data)
        if current != generated:
            changes.append((path, current, generated))
    return changes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if any design note is out of date")
    parser.add_argument("--print-changes", action="store_true", help="print planned or applied changes")
    args = parser.parse_args()

    changes = collect_changes()
    if args.print_changes:
        for path, current, generated in changes:
            print(path.relative_to(PROJECT_ROOT))
            print(f"  - {current}")
            print(f"  + {generated}")
    if args.check:
        if changes:
            print(f"{len(changes)} collectible design notes are out of date.")
            return 1
        print("All collectible design notes are complete and up to date.")
        return 0

    for path, _current, generated in changes:
        replace_design_note(path, generated)
    print(f"Updated {len(changes)} collectible design notes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
