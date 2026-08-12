extends SceneTree

const MAIN_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const MAIN_SCENE: PackedScene = preload(
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const DEFAULT_DROP_TABLE: EnemyDropTable = preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const P1E_WAVES: Array[WaveConfig] = [
	preload("res://resources/config/campaigns/test_arena/p1e/singleplayer/wave_01.tres"),
	preload("res://resources/config/campaigns/test_arena/p1e/multiplayer/wave_01.tres"),
]
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")

const MAIN_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const MAIN_SCENE_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const MAIN_TEXTURE_DIRECTORY := "res://resources/texture/enemy/mechanical_life"
const MAIN_TEXTURE_PATH := (
	MAIN_TEXTURE_DIRECTORY + "/combat_robot_main_battle_elite.png"
)
const MAIN_ANIMATION_PATH := (
	"res://resources/animation/combat_robot_main_battle_elite.tres"
)
const STAGED_CODEX_PATH := (
	"res://resources/config/encyclopedia/enemies/combat_robot_main_battle_elite.tres"
)
const SELECTION_PATH := (
	"res://dev_assets/source_images/combat_robot_main_battle_elite/"
	+ "combat_robot_main_battle_elite_animation_selection.json"
)
const ELIGIBILITY_REPORT_PATH := (
	"res://dev_tools/output/asset_reports/"
	+ "combat_robot_main_battle_elite_animation_native_eligibility_report.json"
)
const EXPECTED_DIRECT_CONFIG_REFERENCES := [
	"res://resources/config/campaigns/test_arena/p1e/multiplayer/wave_01.tres",
	"res://resources/config/campaigns/test_arena/p1e/singleplayer/wave_01.tres",
	"res://resources/config/encyclopedia/enemies/combat_robot_main_battle_elite.tres",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_staged_enemy_contract()
	_test_runtime_visual_release_block()
	_test_known_but_unselectable_p1e_contract()
	_test_protocol_boundaries()
	_test_live_registry_and_texture_counts()
	_test_zero_direct_references()
	_finish()


func _test_staged_enemy_contract() -> void:
	_expect(
		MAIN_CONFIG.display_name == "主战机器人"
		and MAIN_CONFIG.enemy_scene == MAIN_SCENE
		and MAIN_CONFIG.category_tags == PackedStringArray(["mechanical_life"])
		and MAIN_CONFIG.max_health == 800
		and MAIN_CONFIG.attack_damage == 80
		and MAIN_CONFIG.physical_defense == 40
		and MAIN_CONFIG.magic_defense == 35
		and is_equal_approx(MAIN_CONFIG.move_speed, 28.0)
		and MAIN_CONFIG.home_damage == 2
		and MAIN_CONFIG.xirang_kill_reward == 10
		and MAIN_CONFIG.drop_table == DEFAULT_DROP_TABLE,
		"主战机器人暂存配置必须保持独立场景与800/80/40/35/28/2/10数值。"
	)
	for wave in P1E_WAVES:
		_expect(wave != null, "P1E暂存单/多人波次都必须可加载。")
		if wave == null:
			continue
		_expect(
			wave.enemy_entries.size() == 1
			and wave.enemy_entries[0].enemy_config == MAIN_CONFIG
			and wave.enemy_entries[0].count == 1
			and wave.get_total_enemy_count() == 1
			and wave.exits.is_empty()
			and wave.spawn_point_mask == 3
			and wave.spawn_point_order
			== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
			and wave.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
			and is_equal_approx(wave.spawn_interval, 5.0)
			and wave.spawn_count_per_tick == 1
			and wave.max_alive_enemies == 1,
			"P1E暂存流程必须整场只排入1台、终点无出口、单批生成且存活上限为1。"
		)


func _test_runtime_visual_release_block() -> void:
	var scene_text := FileAccess.get_file_as_string(MAIN_SCENE_PATH)
	var codex_text := FileAccess.get_file_as_string(STAGED_CODEX_PATH)
	_expect(
		scene_text.contains("metadata/runtime_visual_release_blocked = true")
		and scene_text.contains("visible = false")
		and scene_text.contains(MAIN_ANIMATION_PATH),
		"敌人场景必须显式保持运行视觉封锁且不得以空动画冒充发布。"
	)
	_expect(
		FileAccess.file_exists(STAGED_CODEX_PATH)
		and codex_text.contains("sort_order = 570")
		and codex_text.contains(MAIN_ANIMATION_PATH),
		"图鉴条目可保留为暂存记录，但必须继续依赖尚未发布的原生动画资源。"
	)
	_expect(
		not ResourceLoader.exists(MAIN_ANIMATION_PATH)
		and not FileAccess.file_exists(MAIN_TEXTURE_PATH),
		"运行SpriteFrames与图集必须在原生资格通过前保持未发布。"
	)
	var selection := _read_json_dictionary(SELECTION_PATH)
	var report := _read_json_dictionary(ELIGIBILITY_REPORT_PATH)
	_expect(
		bool(selection.get("human_approved", false))
		and not bool(selection.get("runtime_written", true))
		and str(selection.get("stage", ""))
		== "animation_approved_runtime_texture_blocked_grid_unproven",
		"用户批准的动作选择证书必须保留，并明确与运行资格分离。"
	)
	_expect(
		not bool(report.get("native_eligible", true))
		and not bool(report.get("runtime_written", true))
		and (report.get("runtime_paths", []) as Array).is_empty()
		and not bool(report.get("direct_native_all_sources", true))
		and not bool(report.get("exact_integer_display_all_sources", true)),
		"原生资格证书必须继续封锁所有运行路径。"
	)


func _test_known_but_unselectable_p1e_contract() -> void:
	var definition := GameModeCatalog.get_definition(
		GameModeCatalog.MODE_TEST_ARENA_P1E
	)
	_expect(
		GameModeCatalog.MODE_TEST_ARENA_P1E == 8
		and GameModeCatalog.is_valid_mode_id(8)
		and GameModeCatalog.resolve_wire_key_or_default(&"test_arena_p1e") == 8
		and definition != null
		and definition.wire_key == &"test_arena_p1e"
		and not GameModeCatalog.is_mode_selectable(8),
		"P1E必须保留v62 mode=8/wire键，但在运行素材发布前不可选择。"
	)
	var lobby_ids: Array[int] = []
	for lobby_definition in GameModeCatalog.get_lobby_definitions():
		lobby_ids.append(lobby_definition.mode_id)
	_expect(
		lobby_ids == [0, 1, 2, 5, 6, 7, 3, 4]
		and not lobby_ids.has(GameModeCatalog.MODE_TEST_ARENA_P1E),
		"P1E不得出现在正式大厅选项中。"
	)
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager != null:
		net_manager.disconnect_from_game()
		_expect(
			not net_manager.set_pending_game_mode(
				NetManagerStore.GameMode.TEST_ARENA_P1E
			)
			and net_manager.get_current_game_mode()
			== NetManagerStore.GameMode.STANDARD,
			"NetManager必须拒绝通过已知wire值绕过P1E发布门。"
		)


func _test_protocol_boundaries() -> void:
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 64
		and NET_CONSTANTS.CHANNEL_COUNT == 8
		and CombatAttackRegistry.PlayerHitWireId.COMBAT_ROBOT_GUNNER_ELITE_BULLET
		== 18
		and CombatAttackRegistry.encode_player_hit_source(
			&"combat_robot_main_battle_elite"
		) == CombatAttackRegistry.PlayerHitWireId.INVALID
		and CombatAttackRegistry.decode_player_hit_source(19) == &"",
		"协议v64必须保留P1E键和确认状态尾字段，同时保持8通道和攻击来源末尾ID18。"
	)


func _test_live_registry_and_texture_counts() -> void:
	_expect(
		EnemyCodexRegistry.ENTRY_COUNT == 63
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.NORMAL
		] == 51
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.ELITE
		] == 11
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.BOSS
		] == 1
		and EnemyCodexRegistry.EXPECTED_FAMILY_COUNTS[&"mechanical_life"] == 10
		and EnemyCodexRegistry.get_entry(&"combat_robot_main_battle_elite") == null
		and EnemyCodexRegistry.validate_contract(),
		"正式图鉴必须保持63/51/11/1、机械生命10，且不注册未发布P1E敌人。"
	)
	var all_enemy_pngs := _count_pngs_recursive("res://resources/texture/enemy")
	var mechanical_pngs := _count_pngs_recursive(
		"res://resources/texture/enemy/mechanical_life"
	)
	_expect(
		all_enemy_pngs == 87 and mechanical_pngs == 20,
		"正式敌人纹理必须保持87张、机械生命20张；实际%d/%d。"
		% [all_enemy_pngs, mechanical_pngs]
	)
	var mappings := FateCoordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH
	_expect(
		mappings.size() == 10
		and not mappings.has(MAIN_CONFIG_PATH)
		and MAIN_CONFIG_PATH not in mappings.values(),
		"Fate必须保持10项，未发布主战机器人不得加入替换映射。"
	)


func _test_zero_direct_references() -> void:
	var references := _find_text_references("res://resources/config", MAIN_CONFIG_PATH)
	references.sort()
	_expect(
		references == EXPECTED_DIRECT_CONFIG_REFERENCES,
		(
			"主战机器人仅可由P1E暂存单/多人波次与暂存图鉴直引；"
			+ "正式敌人池必须保持零直引：%s。"
		)
		% [references]
	)


func _read_json_dictionary(path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(source)
	if parsed is Dictionary:
		return parsed as Dictionary
	failures.append("无法读取JSON证书：%s。" % path)
	return {}


func _count_pngs_recursive(directory_path: String) -> int:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开纹理目录：%s。" % directory_path)
		return 0
	var count := 0
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				count += _count_pngs_recursive(child_path)
			elif entry_name.get_extension().to_lower() == "png":
				count += 1
		entry_name = directory.get_next()
	directory.list_dir_end()
	return count


func _find_text_references(directory_path: String, needle: String) -> Array[String]:
	var matches: Array[String] = []
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开集成审计目录：%s。" % directory_path)
		return matches
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				matches.append_array(_find_text_references(child_path, needle))
			elif entry_name.get_extension() in ["tres", "tscn", "gd"]:
				var file := FileAccess.open(child_path, FileAccess.READ)
				if file != null and needle in file.get_as_text():
					matches.append(child_path)
		entry_name = directory.get_next()
	directory.list_dir_end()
	return matches


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_ELITE_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
