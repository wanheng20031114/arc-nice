extends EnemyConfig
class_name FireRangedEnemyConfig

@export_group("火焰远程攻击")
# 火焰虫使用的非循环攻击动画。
@export var attack_animation_name: StringName = &"attack"
# 允许开始攻击的最大距离。
@export_range(0.0, 1024.0, 1.0, "or_greater") var attack_range: float = 144.0
# 每次攻击起手后需要等待的冷却时间。
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 1.35
# 攻击动画中生成弹丸的帧，从 0 开始。
@export_range(0, 100, 1, "or_greater") var attack_fire_frame: int = 2
# 火焰弹场景。
@export var projectile_scene: PackedScene
# 单枚火焰弹造成的伤害。
@export_range(0, 999, 1, "or_greater") var projectile_damage: int = 1
# 火焰弹飞行速度。
@export_range(0.0, 2000.0, 1.0, "or_greater") var projectile_speed: float = 190.0
# 火焰弹最大存活时间。
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 2.0
# 火焰弹生成点距离敌人中心的距离。
@export_range(0.0, 256.0, 0.5, "or_greater") var projectile_spawn_distance: float = 11.0
# 成功发射火焰弹时播放的空间音效。
@export var attack_audio_stream: AudioStream
