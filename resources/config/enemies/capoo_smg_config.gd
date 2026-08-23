extends EnemyConfig
class_name CapooSMGConfig

@export_group("冲锋枪")
@export var attack_animation_name: StringName = &"attack"
@export_range(0.01, 10.0, 0.01, "or_greater") var fire_interval: float = 0.1
@export_range(0.0, 256.0, 0.5, "or_greater") var attack_range: float = 48.0
@export_range(0.0, 90.0, 0.5) var spread_angle_degrees: float = 20.0
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 190.0
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 0.18
@export_range(0.0, 256.0, 0.5, "or_greater") var projectile_spawn_distance: float = 13.0
@export var attack_audio_stream: AudioStream
