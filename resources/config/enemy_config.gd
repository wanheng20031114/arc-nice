extends Resource
class_name EnemyConfig

enum EnemyType {
	BASIC,
	SHELLED,
	FAST_SMALL,
	BOMBER,
	PURPLE_BOMBER,
	GREEN_SHELLED,
	FIRE_RANGED,
}

@export_group("基础信息")

@export var enemy_type: EnemyType = EnemyType.BASIC
@export var display_name : String = "基础敌人"

@export_group("基础数值")
# 最大生命值，敌人生成时可用它初始化当前生命值。
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
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


@export_group("远程攻击")
# 是否会在玩家进入射程且没有墙体遮挡时停下攻击。
@export var ranged_attack_enabled: bool = false
# 远程攻击使用的非循环动画。
@export var attack_animation_name: StringName = &"attack"
# 允许开始远程攻击的最大距离。
@export_range(0.0, 1024.0, 1.0, "or_greater") var attack_range: float = 0.0
# 每次攻击起手后需要等待的冷却时间。
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 1.0
# 攻击动画中生成弹丸的帧，从 0 开始。
@export_range(0, 100, 1, "or_greater") var attack_fire_frame: int = 0
# 远程攻击生成的弹丸场景。
@export var projectile_scene: PackedScene
# 单枚弹丸造成的伤害。
@export_range(0, 999, 1, "or_greater") var projectile_damage: int = 1
# 单枚弹丸的飞行速度。
@export_range(0.0, 2000.0, 1.0, "or_greater") var projectile_speed: float = 190.0
# 单枚弹丸的最大存活时间。
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 2.0
# 弹丸生成点距离敌人中心的距离。
@export_range(0.0, 256.0, 0.5, "or_greater") var projectile_spawn_distance: float = 11.0
# 成功发射弹丸时播放的空间音效。
@export var attack_audio_stream: AudioStream


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
	preload("res://resources/config/pickup_speed.tres"),
	preload("res://resources/config/pickup_rapid.tres"),
	preload("res://resources/config/pickup_spiral.tres"),
	preload("res://resources/config/pickup_tenpura.tres"),
	preload("res://resources/config/pickup_health.tres"),
]
