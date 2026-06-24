extends EnemyConfig
class_name CapooSniperConfig

@export_group("狙击锁定")
@export var aim_animation_name: StringName = &"windup"
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 720.0
@export_range(0.1, 30.0, 0.01, "or_greater") var lock_duration: float = 3.0
@export_range(0.01, 60.0, 0.01, "or_greater") var attack_interval: float = 4.5
@export var lock_reticle_scene: PackedScene
@export var attack_audio_stream: AudioStream
