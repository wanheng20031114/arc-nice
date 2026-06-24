extends EnemyConfig
class_name CapooMageConfig

@export_group("法师火球")
@export var windup_animation_name: StringName = &"windup"
@export var attack_animation_name: StringName = &"attack"
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 640.0
@export_range(0.0, 30.0, 0.01, "or_greater") var attack_windup: float = 1.0
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 4.0
@export var projectile_scene: PackedScene
@export_range(0.0, 2000.0, 0.1, "or_greater") var projectile_speed: float = 155.0
@export_range(0.01, 30.0, 0.01, "or_greater") var projectile_lifetime: float = 4.0
@export_range(0.0, 256.0, 0.5, "or_greater") var projectile_spawn_distance: float = 18.0
@export_range(1.0, 64.0, 0.5, "or_greater") var fireball_radius: float = 10.5
@export_range(0.0, 8.0, 0.05, "or_greater") var fireball_homing_turn_rate: float = 0.65
@export var attack_audio_stream: AudioStream
