@tool
extends FlowStepConfig
class_name BossConfig

const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)

@export_group("Boss内容")
@export var boss_name: String = "Boss"
@export var enemy_config: EnemyConfig
@export_file("*.tres") var enemy_config_path: String = ""
@export_file("*.tscn") var intro_vfx_scene_path: String = ""
@export_file("*.tscn") var boss_hud_scene_path: String = ""

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
	var has_direct_config := enemy_config != null
	var has_config_path := not enemy_config_path.is_empty()
	return has_direct_config != has_config_path


func get_display_name() -> String:
	if not boss_name.is_empty():
		return boss_name
	if enemy_config != null and not enemy_config.display_name.is_empty():
		return enemy_config.display_name
	return "Boss"


func get_enemy_config() -> EnemyConfig:
	if not has_required_data():
		return null
	if enemy_config != null:
		return enemy_config
	# 路径解析不回写 exported 字段，避免读操作制造第二内容源。
	return load(enemy_config_path) as EnemyConfig


func get_flow_display_name() -> String:
	if not display_name.strip_edges().is_empty():
		return display_name
	return get_display_name()


## Boss 叶子与波次共用内容闭包，不允许直接资源与路径双源竞争。
func append_validation_errors(
	context: ContentValidationContextResource,
	path: String
) -> void:
	var visit_state := context.begin_resource(self, path)
	if visit_state != ContentValidationContextResource.VisitState.ENTERED:
		return

	if boss_name.strip_edges().is_empty():
		context.add_error(path, "缺少 boss_name。")
	if not is_finite(post_clear_rest_duration) or post_clear_rest_duration < 0.0:
		context.add_error(path, "post_clear_rest_duration 必须是非负有限数。")

	var has_direct_config := enemy_config != null
	var has_config_path := not enemy_config_path.is_empty()
	var resolved_enemy_config: EnemyConfig = null
	if has_direct_config and has_config_path:
		context.add_error(path, "enemy_config 与 enemy_config_path 只能配置一个。")
		resolved_enemy_config = enemy_config
	elif has_direct_config:
		resolved_enemy_config = enemy_config
	elif has_config_path:
		var enemy_path := ContentValidationContextResource.child_path(
			path,
			"enemy_config_path"
		)
		if not ResourceLoader.exists(enemy_config_path):
			context.add_error(enemy_path, "指向的资源不存在。")
		else:
			resolved_enemy_config = load(enemy_config_path) as EnemyConfig
			if resolved_enemy_config == null:
				context.add_error(enemy_path, "必须指向 EnemyConfig。")
	else:
		context.add_error(path, "缺少 enemy_config 或 enemy_config_path。")

	if resolved_enemy_config != null:
		var resolved_enemy_path := ContentValidationContextResource.child_path(
			path,
			"enemy_config" if has_direct_config else "enemy_config_path"
		)
		if not resolved_enemy_config.is_boss:
			context.add_error(resolved_enemy_path, "Boss 敌人必须设置 is_boss。")
		resolved_enemy_config.append_validation_errors(context, resolved_enemy_path)

	_append_scene_path_errors(
		context,
		ContentValidationContextResource.child_path(path, "intro_vfx_scene_path"),
		intro_vfx_scene_path
	)
	_append_scene_path_errors(
		context,
		ContentValidationContextResource.child_path(path, "boss_hud_scene_path"),
		boss_hud_scene_path
	)
	if (
		not is_finite(music_volume_db)
		or music_volume_db < -40.0
		or music_volume_db > 12.0
	):
		context.add_error(path, "music_volume_db 必须是 -40 到 12 之间的有限数。")
	if not is_finite(music_loop_offset) or music_loop_offset < 0.0:
		context.add_error(path, "music_loop_offset 必须是非负有限数。")
	if not arena_center.is_finite():
		context.add_error(path, "arena_center 必须是有限坐标。")
	if arena_floor_rect.size.x <= 0 or arena_floor_rect.size.y <= 0:
		context.add_error(path, "arena_floor_rect 必须具有正尺寸。")
	if floor_source_id < 0:
		context.add_error(path, "floor_source_id 不能为负数。")
	if floor_atlas_coords.x < 0 or floor_atlas_coords.y < 0:
		context.add_error(path, "floor_atlas_coords 不能包含负坐标。")
	context.complete_resource(self)


func _append_scene_path_errors(
	context: ContentValidationContextResource,
	path: String,
	scene_path: String
) -> void:
	# 空路径使用现有 Linglan 运行时默认场景；显式覆盖则必须可实例化。
	if scene_path.is_empty():
		return
	if not ResourceLoader.exists(scene_path):
		context.add_error(path, "指向的场景不存在。")
		return
	var scene := load(scene_path) as PackedScene
	if scene == null:
		context.add_error(path, "必须指向 PackedScene。")
	elif not scene.can_instantiate():
		context.add_error(path, "指向的 PackedScene 无法实例化。")
