@tool
extends FlowStepConfig
class_name BossConfig

@export_group("Boss内容")
@export var boss_name: String = "Boss"
@export var enemy_config: EnemyConfig
@export_file("*.tres") var enemy_config_path: String = ""
@export_file("*.tscn") var intro_vfx_scene_path: String = "res://scene/linglan_boss_intro_vfx.tscn"
@export_file("*.tscn") var boss_hud_scene_path: String = "res://scene/boss_health_hud.tscn"

@export_group("Boss音乐")
@export var music: AudioStream
@export_range(-40.0, 12.0, 0.5) var music_volume_db: float = -6.0
@export_range(0.0, 30.0, 0.05, "or_greater") var music_loop_offset: float = 0.0

@export_group("入场场地")
@export var arena_center: Vector2 = Vector2(128.0, 128.0)
@export var arena_floor_rect: Rect2i = Rect2i(Vector2i(-3, -1), Vector2i(22, 18))
@export var floor_source_id: int = 0
@export var floor_atlas_coords: Vector2i = Vector2i.ZERO
@export var clear_inner_overlay_cells: bool = true


func has_required_data() -> bool:
	return enemy_config != null or not enemy_config_path.is_empty()


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


func get_flow_display_name() -> String:
	if not display_name.strip_edges().is_empty():
		return display_name
	return get_display_name()
