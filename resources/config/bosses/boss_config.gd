extends Resource
class_name BossConfig

@export_group("Boss内容")
@export var boss_name: String = "Boss"
@export var enemy_config: EnemyConfig
@export_file("*.tres") var enemy_config_path: String = ""

@export_group("流程入口")
@export_range(1, 999, 1, "or_greater") var starts_after_wave_number: int = 1

@export_group("入场场地")
@export var arena_center: Vector2 = Vector2(128.0, 128.0)
@export var arena_floor_rect: Rect2i = Rect2i(Vector2i(-3, -1), Vector2i(22, 18))
@export var floor_source_id: int = 0
@export var floor_atlas_coords: Vector2i = Vector2i.ZERO
@export var clear_inner_overlay_cells: bool = true


func has_required_data() -> bool:
	return (enemy_config != null or not enemy_config_path.is_empty()) and starts_after_wave_number > 0


func get_display_name() -> String:
	if not boss_name.is_empty():
		return boss_name
	if enemy_config != null and not enemy_config.display_name.is_empty():
		return enemy_config.display_name
	return "Boss"


func get_enemy_config() -> EnemyConfig:
	if enemy_config != null:
		return enemy_config
	if enemy_config_path.is_empty():
		return null
	enemy_config = load(enemy_config_path) as EnemyConfig
	return enemy_config
