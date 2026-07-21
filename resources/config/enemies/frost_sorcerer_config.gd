extends EnemyConfig
class_name FrostSorcererConfig

@export_group("寒冰锥")
# 法杖蓄力期间播放的角色动画。
@export var windup_animation_name: StringName = &"windup"
# 寒冰锥完成生成时播放的挥杖动画。
@export var attack_animation_name: StringName = &"attack"
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 672.0
# 预览冰锥从零缩放到完整大小的持续时间。
@export_range(0.01, 30.0, 0.01, "or_greater") var summon_duration: float = 0.6
# 从真实冰锥完成生成后开始计算的攻击冷却。
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 3.0
# 大群敌人初次进入射程时使用确定性错峰，避免同帧集中施法。
@export_range(0.0, 2.0, 0.01, "or_greater") var initial_attack_stagger_window: float = 0.9
@export var ice_spike_scene: PackedScene
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 100.0
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 7.0
