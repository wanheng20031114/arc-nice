extends EnemyConfig
class_name CapooAK47Config

@export_group("AK 连发")
@export var windup_animation_name: StringName = &"windup"
@export var attack_animation_name: StringName = &"attack"
@export_range(0.0, 1024.0, 0.1, "or_greater") var attack_range: float = 170.0
@export_range(0.0, 30.0, 0.01, "or_greater") var attack_windup: float = 1.5
@export_range(1, 100, 1, "or_greater") var burst_count: int = 10
@export_range(0.01, 10.0, 0.01, "or_greater") var burst_fire_interval: float = 0.08
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 3.5
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 142.5
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 2.0
@export_range(0.0, 256.0, 0.5, "or_greater") var projectile_spawn_distance: float = 13.0
@export var attack_audio_stream: AudioStream
