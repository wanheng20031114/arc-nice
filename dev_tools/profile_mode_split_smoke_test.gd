extends SceneTree

const STANDARD_PROFILE_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
)
const TOWER_PROFILE_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/tower_defense_player_profile_panel.tscn"
)
const ROGUE_PROFILE_SCENE := preload(
	"res://scene/game_modes/rogue/ui/rogue_player_profile_panel.tscn"
)
const LEGACY_PROFILE_SCRIPT_UID := "uid://llltdqhomb4y"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var standard := (
		STANDARD_PROFILE_SCENE.instantiate() as StandardPlayerProfilePanel
	)
	var tower := (
		TOWER_PROFILE_SCENE.instantiate() as TowerDefensePlayerProfilePanel
	)
	var rogue := ROGUE_PROFILE_SCENE.instantiate() as RoguePlayerProfilePanel
	root.add_child(standard)
	root.add_child(tower)
	root.add_child(rogue)
	await process_frame

	_expect(
		standard != null and tower != null and rogue != null,
		"普通、塔防与肉鸽 Profile 必须能独立实例化。"
	)
	if standard != null and tower != null and rogue != null:
		_expect(
			standard.stats_view is PlayerStatsView
			and tower.stats_view is PlayerStatsView
			and rogue.stats_view is PlayerStatsView
			and standard.inventory_view is PlayerInventoryView
			and tower.inventory_view is PlayerInventoryView
			and rogue.inventory_view is PlayerInventoryView,
			"三个模式包装器必须原生组合共享属性与背包视图。"
		)
		_expect(
			standard.has_signal("opened")
			and standard.has_signal("closed")
			and tower.has_signal("opened")
			and tower.has_signal("closed")
			and rogue.has_signal("opened")
			and rogue.has_signal("closed")
			and standard.has_method("show_simple_crafting_result")
			and tower.has_method("show_simple_crafting_result")
			and rogue.has_method("show_simple_crafting_result"),
			"拆分后必须保留 Profile 的公开 façade 与开关信号。"
		)
		_expect(
			not standard.has_method("set_research_coordinator")
			and not rogue.has_method("set_research_coordinator")
			and not standard.has_signal("building_placement_requested")
			and not rogue.has_signal("building_placement_requested")
			and tower.has_method("set_research_coordinator")
			and tower.has_signal("building_placement_requested"),
			"研究与建筑放置入口只能属于塔防 Profile。"
		)
		standard.configure_multiplayer_requests(false)
		standard.configure_local_upgrade_authority(false)
		_expect(
			not standard.multiplayer_requests_enabled
			and not standard.local_upgrade_authority_enabled,
			"无标准多人消费者的模式必须能显式保留本地操作并禁止客户端升级。"
		)

	var standard_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/ui/standard_player_profile_panel.gd"
	)
	var tower_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/ui/tower_defense_player_profile_panel.gd"
	)
	var rogue_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/ui/rogue_player_profile_panel.gd"
	)
	var basic_source := FileAccess.get_file_as_string(
		"res://scene/ui/shared/profile/basic_player_profile_panel.gd"
	)
	var stats_source := FileAccess.get_file_as_string(
		"res://scene/ui/shared/profile/player_stats_view.gd"
	)
	var inventory_source := FileAccess.get_file_as_string(
		"res://scene/ui/shared/profile/player_inventory_view.gd"
	)
	var rogue_combat_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_game.gd"
	)
	for source in [
		standard_source,
		tower_source,
		rogue_source,
		basic_source,
		stats_source,
		inventory_source,
	]:
		_expect(
			not source.contains("get_tree().current_scene")
			and not source.contains("has_method(\"request_multiplayer"),
			"Profile 拆分后不得再猜测 current_scene 的多人能力。"
		)
	_expect(
		not rogue_source.contains("StandardPlayerProfilePanel")
		and not rogue_combat_source.contains("game_modes/standard")
		and not rogue_combat_source.contains("StandardPlayerProfilePanel"),
		"肉鸽 Profile 不得反向依赖普通模式。"
	)
	_expect(
		rogue_combat_source.contains(
			"player_profile_panel.configure_multiplayer_requests(\n"
			+ "\t\truntime_mode != RuntimeMode.SINGLEPLAYER\n"
			+ "\t)"
		)
		and rogue_combat_source.contains(
			"runtime_mode != RuntimeMode.CLIENT_VIEW"
		),
		"肉鸽 Host/Client 必须启用共享 Profile 多人请求，同时保持客户端升级权限边界。"
	)

	_expect(
		not FileAccess.file_exists(
			"res://scene/player/ui/player_profile_panel.tscn"
		)
		and not FileAccess.file_exists(
			"res://scene/player/ui/player_profile_panel.gd"
		),
		"旧 PlayerProfilePanel 类与路径不得保留兼容空壳。"
	)
	var legacy_uid := ResourceUID.text_to_id(LEGACY_PROFILE_SCRIPT_UID)
	_expect(
		ResourceUID.get_id_path(legacy_uid)
		== "res://scene/game_modes/standard/ui/standard_player_profile_panel.gd",
		"旧 Profile 脚本 UID 必须原子迁给 Standard 主包装器。"
	)

	standard.queue_free()
	tower.queue_free()
	rogue.queue_free()
	await process_frame
	if failures.is_empty():
		print("PROFILE_MODE_SPLIT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
