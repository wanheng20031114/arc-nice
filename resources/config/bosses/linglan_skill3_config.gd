extends Resource
class_name LinglanSkill3Config

@export var skill_name: StringName = &"linglan_skill3"
@export var target_cell: Vector2i = Vector2i(0, 1)
@export_range(0.0, 1000.0, 1.0, "or_greater") var move_speed: float = 120.0
@export_range(0.0, 32.0, 0.1, "or_greater") var arrival_distance: float = 2.0
@export_range(0.05, 60.0, 0.05, "or_greater") var duration: float = 10.0
@export_range(0.05, 10.0, 0.05, "or_greater") var fire_interval: float = 0.25
@export_range(0.0, 360.0, 0.5) var direction_min_degrees: float = 0.0
@export_range(0.0, 360.0, 0.5) var direction_max_degrees: float = 90.0
@export_range(0.0, 2000.0, 1.0, "or_greater") var orb_speed: float = 70.0
@export_range(0, 999, 1, "or_greater") var orb_damage: int = 50
@export_range(1.0, 128.0, 0.5, "or_greater") var orb_base_radius: float = 5.0
@export_range(1.0, 32.0, 0.5, "or_greater") var orb_grow_scale: float = 7.0
@export_range(0.0, 10.0, 0.05, "or_greater") var orb_expanded_hold_duration: float = 0.7
@export_range(0.0, 10.0, 0.05, "or_greater") var orb_flash_lead_time: float = 2.0
@export_range(0.01, 30.0, 0.05, "or_greater") var orb_grow_delay_min: float = 2.2
@export_range(0.01, 30.0, 0.05, "or_greater") var orb_grow_delay_max: float = 2.9
@export var orb_scene: PackedScene


func get_shot_count() -> int:
	return maxi(floori(duration / maxf(fire_interval, 0.05)), 1)


func get_random_grow_delay(random_generator: RandomNumberGenerator) -> float:
	var minimum := minf(orb_grow_delay_min, orb_grow_delay_max)
	var maximum := maxf(orb_grow_delay_min, orb_grow_delay_max)
	if is_equal_approx(minimum, maximum):
		return minimum
	return random_generator.randf_range(minimum, maximum)
