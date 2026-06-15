extends Resource
class_name YuanshiInsectConfig

enum Variant {
	BASIC,
	SHELLED,
	FAST_SMALL,
	BOMBER,
	PURPLE_BOMBER,
	GREEN_SHELLED,
	FIRE_RANGED,
}

@export_group("基础信息")

@export var variant: Variant = Variant.BASIC
@export var display_name : String = "基础原石虫"
# 特殊原石虫可指定专属场景；为空时沿用 Game 的通用原石虫场景。
@export var enemy_scene_override: PackedScene

@export_group("基础数值")
# 最大生命值，敌人生成时可用它初始化当前生命值。
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
# 常规攻击伤害，供身体接触、光环和远程弹丸等攻击方式统一读取。
@export_range(0, 999, 1, "or_greater") var attack_damage: int = 1
# 移动速度，单位通常为像素/秒。
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 60.0
# 圆形碰撞区域半径，可用于不同体型敌人的碰撞大小配置。
@export_range(1.0, 256.0, 0.5, "or_greater") var collision_radius: float = 8


@export_group("动画资源")
# 敌人本体使用的 SpriteFrames 资源。
# 建议在同一个资源中同时配置移动、待机、死亡等动画。
@export var enemy_frames: SpriteFrames
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
