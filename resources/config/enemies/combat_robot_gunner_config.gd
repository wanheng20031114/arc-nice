extends EnemyConfig
class_name CombatRobotGunnerConfig

@export_group("持枪战斗机器人连射")

@export var fire_animation_name: StringName = &"fire"
@export var fire_walk_animation_name: StringName = &"fire_walk"
@export_range(0.0, 1024.0, 0.1, "or_greater") var attack_range: float = 84.0
@export_range(0.0, 1024.0, 0.1, "or_greater") var stop_distance: float = 24.0
@export_range(1, 100, 1, "or_greater") var burst_count: int = 12
@export_range(0.01, 10.0, 0.01, "or_greater") var burst_fire_interval: float = 0.08
@export_range(0.0, 45.0, 0.1) var spread_angle_degrees: float = 5.0
@export_range(0.0, 1.0, 0.01) var burst_move_speed_multiplier: float = 0.5
@export_range(0.0, 60.0, 0.01, "or_greater") var attack_cooldown: float = 2.5
@export var projectile_type: StringName = &"combat_robot_gunner_bullet"
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 80.0
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 1.5
@export var attack_audio_stream: AudioStream
