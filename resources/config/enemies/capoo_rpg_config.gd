extends EnemyConfig
class_name CapooRPGConfig

@export_group("RPG")
@export var windup_animation_name: StringName = &"windup"
@export var attack_animation_name: StringName = &"attack"
@export_range(0.0, 1024.0, 0.1, "or_greater") var attack_range: float = 320.0
@export_range(0.0, 30.0, 0.01, "or_greater") var attack_windup: float = 0.5
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 6.0
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 210.0
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 3.0
@export_range(0.0, 256.0, 0.5, "or_greater") var projectile_spawn_distance: float = 18.0
@export var attack_audio_stream: AudioStream
