extends Resource
class_name LinglanSkill4Config

@export var skill_name: StringName = &"linglan_skill4"
@export var target_cell_a: Vector2i = Vector2i(6, 2)
@export var target_cell_b: Vector2i = Vector2i(7, 2)
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 120.0
@export_range(0.0, 32.0, 0.1, "or_greater") var arrival_distance: float = 2.0
@export var laser_start_left_cell_x: int = -3
@export var laser_start_right_cell_x: int = 18
@export var laser_start_top_cell_y: int = -1
@export var laser_start_bottom_cell_y: int = 16
@export_range(0, 32, 1, "or_greater") var laser_inward_cell_distance: int = 5
@export_range(0.0, 10.0, 0.05, "or_greater") var laser_warning_duration: float = 1.6
@export_range(0.01, 30.0, 0.05, "or_greater") var laser_shrink_duration: float = 3.0
@export_range(0.0, 10.0, 0.05, "or_greater") var orb_start_delay: float = 0.5
@export_range(1.0, 64.0, 0.5, "or_greater") var laser_core_width: float = 6.0
@export_range(0, 999, 1, "or_greater") var laser_damage: int = 50
@export_range(-99, 99, 1) var orb_candidate_min_y: int = 0
@export_range(-99, 99, 1) var orb_candidate_max_y: int = 15
@export_range(1, 99, 1, "or_greater") var orb_count_per_side: int = 12
@export_range(0.05, 30.0, 0.05, "or_greater") var orb_spawn_interval: float = 2.0
@export_range(0.05, 60.0, 0.05, "or_greater") var orb_spawn_duration: float = 14.0
@export_range(0.0, 2000.0, 1.0, "or_greater") var orb_speed: float = 40.0
@export_range(0.01, 30.0, 0.05, "or_greater") var orb_lifetime: float = 12.0
@export_range(0, 999, 1, "or_greater") var orb_damage: int = 50
@export_range(1.0, 128.0, 0.5, "or_greater") var orb_radius: float = 8.0
@export_range(1.0, 128.0, 0.5, "or_greater") var orb_damage_radius: float = 6.0
@export var laser_field_scene: PackedScene
@export var orb_scene: PackedScene


func get_orb_start_time() -> float:
	return maxf(orb_start_delay, 0.0)


func get_total_duration() -> float:
	return get_orb_start_time() + maxf(orb_spawn_duration, 0.0)


func get_orb_wave_count() -> int:
	return maxi(floori(maxf(orb_spawn_duration, 0.0) / maxf(orb_spawn_interval, 0.05)), 1)


func get_random_orb_rows(random_generator: RandomNumberGenerator) -> Array[int]:
	var minimum := mini(orb_candidate_min_y, orb_candidate_max_y)
	var maximum := maxi(orb_candidate_min_y, orb_candidate_max_y)
	var rows: Array[int] = []
	for row in range(minimum, maximum + 1):
		rows.append(row)
	for index in range(rows.size() - 1, 0, -1):
		var swap_index := random_generator.randi_range(0, index)
		var current := rows[index]
		rows[index] = rows[swap_index]
		rows[swap_index] = current
	return rows.slice(0, mini(maxi(orb_count_per_side, 1), rows.size()))
