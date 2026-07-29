extends Resource
class_name LinglanSkillConfig

@export var skill_name: StringName = &"linglan_skill1"
@export_range(0.0, 60.0, 0.1, "or_greater") var start_delay: float = 5.0
@export_range(1, 128, 1, "or_greater") var ring_direction_count: int = 20
@export_range(1.0, 9999.0, 1.0, "or_greater") var attack_speed: float = 800.0
@export_range(0.0, 60.0, 0.1, "or_greater") var fixed_fire_duration: float = 2.0
@export_range(0.0, 60.0, 0.1, "or_greater") var rotating_fire_duration: float = 15.0
@export_range(-360.0, 360.0, 0.1) var rotation_speed_degrees_per_second: float = 6.0
@export_range(0.0, 2000.0, 1.0, "or_greater") var projectile_speed: float = 300.0
@export_range(0.0, 10.0, 0.1, "or_greater") var projectile_lifetime: float = 1.2
@export_range(0, 999, 1, "or_greater") var projectile_damage: int = 50
@export_range(0.0, 128.0, 0.5, "or_greater") var projectile_spawn_distance: float = 18.0
@export var projectile_scene: PackedScene
@export_range(0.0, 10.0, 0.1, "or_greater") var warning_lead_time: float = 1.0
@export_range(0.1, 8.0, 0.1, "or_greater") var warning_ray_width_scale: float = 1.0
@export var warning_ray_scene: PackedScene


func get_fire_interval() -> float:
	return maxf(100.0 / maxf(attack_speed, 1.0), 0.01)


func get_projectile_travel_distance() -> float:
	return projectile_speed * projectile_lifetime


func get_total_duration() -> float:
	return fixed_fire_duration + rotating_fire_duration
