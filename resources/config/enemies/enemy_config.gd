extends Resource
class_name EnemyConfig

enum DamageType {
	PHYSICAL,
	MAGIC,
}

@export_group("基础信息")

@export var display_name: String = "敌人"
# 当前敌人的完整场景，包含碰撞体积、接触伤害体积和本体动画。
@export var enemy_scene: PackedScene

@export_group("基础数值")
# 最大生命值，敌人生成时可用它初始化当前生命值。
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
# 常规攻击伤害，供身体接触、光环和远程弹丸等攻击方式统一读取。
@export_range(0, 999, 1, "or_greater") var attack_damage: int = 1
# 物理防御直接抵消物理伤害，最终伤害最低为 1。
@export_range(0, 999, 1, "or_greater") var physical_defense: int = 0
# 魔法防御按百分比降低魔法伤害，最终伤害最低为 1。
@export_range(0, 100, 1) var magic_defense: int = 0
# 移动速度，单位通常为像素/秒。
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 60.0


@export_group("动画名称")
# 敌人正常移动时默认播放的动画名。
@export var move_animation_name: StringName = &"move"
# 敌人死亡时默认播放的动画名。
@export var death_animation_name: StringName = &"death"
# 爆炸特效默认播放的动画名。
@export var explosion_animation_name: StringName = &"explode"


@export_group("死亡效果")
# 是否在死亡时触发自爆。
@export var explode_on_death: bool = false
# 自爆伤害，只有 explode_on_death 为 true 时才有意义。
@export_range(0, 999, 1, "or_greater") var explosion_damage: int = 0
# 自爆半径，只有 explode_on_death 为 true 时才有意义。
@export_range(0.0, 512.0, 1.0, "or_greater") var explosion_radius: float = 0
# 爆炸动画相对原始帧的显示缩放，用于让视觉范围贴合实际伤害半径。
@export_range(0.1, 10.0, 0.01, "or_greater") var explosion_animation_scale: float = 1.0


@export_group("掉落")
# 敌人死亡时必定掉落的息壤晶体总值；0 表示不掉落。
@export_range(0, 999, 1, "or_greater") var xirang_drop_amount: int = 1
# 敌人死亡后尝试掉落道具的概率。
@export_range(0.0, 1.0, 0.01) var pickup_drop_chance: float = 0.3
# 当前敌人允许掉落的道具配置列表；为空时表示该敌人不会掉落道具。
@export var pickup_drop_configs: Array[PickupConfig] = [
	preload("res://resources/config/pickups/pickup_speed.tres"),
	preload("res://resources/config/pickups/pickup_rapid.tres"),
	preload("res://resources/config/pickups/pickup_spiral.tres"),
	preload("res://resources/config/pickups/pickup_tenpura.tres"),
	preload("res://resources/config/pickups/pickup_health.tres"),
]
