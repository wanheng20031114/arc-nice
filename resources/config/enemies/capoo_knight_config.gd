extends EnemyConfig
class_name CapooKnightConfig

@export_group("Knight Slash")
@export var windup_animation_name: StringName = &"windup"
@export var attack_animation_name: StringName = &"attack"
@export_range(0.0, 256.0, 0.1, "or_greater") var attack_range: float = 48.0
@export_range(0.0, 30.0, 0.01, "or_greater") var attack_windup: float = 0.35
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 4.0
@export_range(0.0, 256.0, 0.5, "or_greater") var slash_outer_radius: float = 48.0
@export_range(0.0, 256.0, 0.5, "or_greater") var slash_inner_radius: float = 6.5
@export_range(1.0, 360.0, 1.0) var slash_angle_degrees: float = 60.0
@export_range(0.0, 5.0, 0.01, "or_greater") var slash_damage_delay: float = 0.08
@export_range(0.01, 5.0, 0.01, "or_greater") var slash_duration: float = 0.32
@export var slash_effect_scene: PackedScene
@export var attack_audio_stream: AudioStream
