extends EnemyConfig
class_name CombatRobotNinjaConfig

@export_group("忍者战斗机器人受击加速")

@export var boost_animation_name: StringName = &"boost"
@export_range(1.0, 10.0, 0.05, "or_greater") var boost_speed_multiplier: float = 2.0
@export_range(0.01, 30.0, 0.01, "or_greater") var boost_duration: float = 0.5
@export_range(0.01, 60.0, 0.01, "or_greater") var boost_cooldown: float = 3.0
@export var boost_audio_stream: AudioStream
