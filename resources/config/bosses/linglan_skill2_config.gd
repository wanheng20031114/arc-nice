extends Resource
class_name LinglanSkill2Config

@export var skill_name: StringName = &"linglan_skill2"
@export var target_cell: Vector2i = Vector2i(15, 2)
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 120.0
@export_range(0.0, 32.0, 0.1, "or_greater") var arrival_distance: float = 2.0
@export_range(1, 99, 1, "or_greater") var attack_count: int = 10
@export_range(0.05, 60.0, 0.05, "or_greater") var attack_interval: float = 1.0
@export_range(0.0, 10.0, 0.05, "or_greater") var warning_lead_time: float = 0.35
@export_range(0.0, 2000.0, 1.0, "or_greater") var rocket_speed: float = 210.0
@export_range(0.0, 20.0, 0.05, "or_greater") var rocket_homing_turn_rate: float = 1.2
@export_range(0.01, 30.0, 0.05, "or_greater") var rocket_lifetime: float = 5.0
@export_range(0, 999, 1, "or_greater") var rocket_damage: int = 80
@export_range(0.0, 512.0, 0.5, "or_greater") var rocket_explosion_radius: float = 78.0
@export_range(0.0, 128.0, 0.5, "or_greater") var rocket_spawn_distance: float = 28.0
@export_range(0.0, 128.0, 0.5, "or_greater") var warning_arrow_start_distance: float = 18.0
@export_range(16.0, 512.0, 1.0, "or_greater") var warning_arrow_length: float = 56.0
@export var rocket_scene: PackedScene
@export var warning_arrow_scene: PackedScene
@export var spawn_enemy_config: EnemyConfig
@export var spawn_marker_names: Array[StringName] = [&"Spawn4", &"Spawn5"]


func get_total_duration() -> float:
	return maxf(attack_interval, 0.05) * float(maxi(attack_count, 1))
