extends EnemyConfig
class_name CombatRobotConfig

@export_group("战斗机器人冲刺")

@export var windup_animation_name: StringName = &"windup"
@export var dash_animation_name: StringName = &"dash"
@export var windup_warning_color: Color = Color(1.0, 0.28, 0.08, 1.0)
@export_range(0.0, 2048.0, 1.0, "or_greater") var dash_trigger_range: float = 140.0
@export_range(0.0, 30.0, 0.01, "or_greater") var dash_windup: float = 0.4
@export_range(0.0, 1000.0, 1.0, "or_greater") var dash_speed: float = 100.0
@export_range(0.01, 30.0, 0.01, "or_greater") var dash_duration: float = 1.4
@export_range(0.0, 60.0, 0.01, "or_greater") var dash_cooldown: float = 3.0
