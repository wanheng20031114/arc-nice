extends Resource
class_name PlantDefenseConfig

const ATTACK_SPEED_UNITS_PER_SECOND: float = 100.0
const REQUIRED_FOOTPRINT_SIZE: Vector2i = Vector2i(2, 2)

@export_group("基础信息")
@export var plant_id: StringName = &""
@export var display_name: String = "植物"
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var plant_scene: PackedScene
@export var supports_multiplayer: bool = false

@export_group("基础数值")
@export_range(1, 9999, 1, "or_greater") var max_health: int = 100
@export_range(0, 999, 1, "or_greater") var physical_defense: int = 0
@export_range(0, 100, 1) var magic_defense: int = 0
@export_range(0, 9999, 1, "or_greater") var attack_damage: int = 0
@export_range(0.0, 99999.0, 1.0, "or_greater") var attack_speed: float = 0.0
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 0.0

@export_group("占格")
@export var footprint_size: Vector2i = REQUIRED_FOOTPRINT_SIZE


func get_attack_interval() -> float:
	if attack_speed <= 0.0:
		return 0.0
	return ATTACK_SPEED_UNITS_PER_SECOND / attack_speed


func is_valid() -> bool:
	return (
		plant_id != &""
		and not display_name.is_empty()
		and icon != null
		and plant_scene != null
		and max_health > 0
		and footprint_size.x > 0
		and footprint_size.y > 0
	)
