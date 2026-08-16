extends SceneTree

const MAIN_CONFIG: CombatRobotMainBattleEliteConfig = preload(
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
const AUDIO_STREAM_FIELDS := {
	&"move_stomp_audio_stream_a": ["combat_robot_main_battle_elite_stomp_a.wav", 0.25],
	&"move_stomp_audio_stream_b": ["combat_robot_main_battle_elite_stomp_b.wav", 0.25],
	&"hit_audio_stream_a": ["combat_robot_main_battle_elite_hit_a.wav", 0.16],
	&"hit_audio_stream_b": ["combat_robot_main_battle_elite_hit_b.wav", 0.18],
	&"attack_windup_audio_stream": ["combat_robot_main_battle_elite_normal_windup.wav", 0.35],
	&"attack_slash_audio_stream": ["combat_robot_main_battle_elite_normal_double_slash.wav", 0.78],
	&"skill1_charge_audio_stream": ["combat_robot_main_battle_elite_skill1_charge.wav", 0.56],
	&"skill1_dash_audio_stream": ["combat_robot_main_battle_elite_skill1_dash.wav", 0.75],
	&"skill1_circle_slash_audio_stream": ["combat_robot_main_battle_elite_skill1_circle_slash.wav", 0.78],
	&"skill2_takeoff_audio_stream": ["combat_robot_main_battle_elite_skill2_takeoff.wav", 0.46],
	&"skill2_drop_audio_stream": ["combat_robot_main_battle_elite_skill2_drop_bilateral_slash.wav", 0.76],
	&"death_audio_stream": ["combat_robot_main_battle_elite_death.wav", 1.20],
}
const AUDIO_NODE_SPECS := {
	&"MoveStompAudio": [&"move_stomp_audio_stream_a", -15.0, 180.0],
	&"HitAudio": [&"hit_audio_stream_a", -9.0, 180.0],
	&"DeathAudio": [&"death_audio_stream", -3.0, 220.0],
	&"AttackWindupAudio": [&"attack_windup_audio_stream", -11.0, 220.0],
	&"AttackSlashAudio": [&"attack_slash_audio_stream", -6.0, 220.0],
	&"Skill1ChargeAudio": [&"skill1_charge_audio_stream", -9.0, 220.0],
	&"Skill1DashAudio": [&"skill1_dash_audio_stream", -8.0, 220.0],
	&"Skill1CircleSlashAudio": [&"skill1_circle_slash_audio_stream", -5.0, 220.0],
	&"Skill2TakeoffAudio": [&"skill2_takeoff_audio_stream", -7.0, 220.0],
	&"Skill2DropAudio": [&"skill2_drop_audio_stream", -3.0, 220.0],
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_released_enemy_contract()
	_test_runtime_visual_release_contract()
	_test_dedicated_audio_release_contract()
	_test_selectable_p1e_entry_contract()
	_test_protocol_boundaries()
	_test_live_registry_and_texture_counts()
	_test_zero_direct_references()
	_finish()


func _test_released_enemy_contract() -> void:
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
		"主战机器人正式配置必须保持独立场景与800/80/40/35/28/2/10数值。"
	)
	for wave in P1E_WAVES:
		_expect(wave != null, "P1E单/多人波次都必须可加载。")
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
			"P1E流程必须整场只排入1台、终点无出口、单批生成且存活上限为1。"
		)


func _test_runtime_visual_release_contract() -> void:
	var scene_text := FileAccess.get_file_as_string(MAIN_SCENE_PATH)
	var codex_text := FileAccess.get_file_as_string(STAGED_CODEX_PATH)
	var enemy := MAIN_SCENE.instantiate() as CombatRobotMainBattleElite
	if enemy != null:
		root.add_child(enemy)
	_expect(
		not scene_text.contains("metadata/runtime_visual_release_blocked")
		and scene_text.contains(
			"metadata/runtime_visual_strategy = \"high_resolution_source_preserved_linear_display\""
		)
		and scene_text.contains("texture_filter = 2")
		and scene_text.contains("scale = Vector2(0.125, 0.125)")
		and scene_text.contains(MAIN_ANIMATION_PATH),
		"敌人场景必须绑定高分辨率保真SpriteFrames、统一0.125缩放和线性过滤。"
	)
	_expect(
		FileAccess.file_exists(STAGED_CODEX_PATH)
		and codex_text.contains("sort_order = 570")
		and codex_text.contains(MAIN_ANIMATION_PATH)
		and codex_text.contains("preview_scale = Vector2(0.125, 0.125)"),
		"正式图鉴条目必须绑定同一SpriteFrames与0.125预览缩放。"
	)
	_expect(
		ResourceLoader.exists(MAIN_ANIMATION_PATH)
		and FileAccess.file_exists(MAIN_TEXTURE_PATH)
		and enemy != null
		and enemy.has_released_runtime_visuals()
		and (enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D).visible
		and (enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D).texture_filter
		== CanvasItem.TEXTURE_FILTER_LINEAR,
		"53帧高分辨率运行图集必须可加载、可见并通过精确动画合同。"
	)
	if enemy != null:
		enemy.free()
	var selection := _read_json_dictionary(SELECTION_PATH)
	var report := _read_json_dictionary(ELIGIBILITY_REPORT_PATH)
	_expect(
		bool(selection.get("human_approved", false))
		and bool(selection.get("runtime_written", false))
		and str(selection.get("stage", ""))
		== "high_resolution_runtime_released_native64_ineligible"
		and str((selection.get("runtime_release", {}) as Dictionary).get(
			"strategy", ""
		)) == "high_resolution_source_preserved_linear_display",
		"用户批准证书必须记录高分辨率保真运行发布，同时保持native64门独立。"
	)
	_expect(
		not bool(report.get("native_eligible", true))
		and bool(report.get("runtime_written", false))
		and (report.get("runtime_paths", []) as Array).size() == 2
		and not bool(report.get("direct_native_all_sources", true))
		and not bool(report.get("exact_integer_display_all_sources", true))
		and str((report.get("runtime_release", {}) as Dictionary).get(
			"strategy", ""
		)) == "high_resolution_source_preserved_linear_display",
		"原生64资格必须继续为false，但经授权的高分辨率保真运行路径必须发布。"
	)


func _test_dedicated_audio_release_contract() -> void:
	var seen_paths: Dictionary = {}
	for field_name: StringName in AUDIO_STREAM_FIELDS:
		var spec := AUDIO_STREAM_FIELDS[field_name] as Array
		var stream := MAIN_CONFIG.get(field_name) as AudioStream
		var expected_suffix := "resources/audio/%s" % str(spec[0])
		_expect(
			stream != null
			and stream.resource_path.ends_with(expected_suffix)
			and not seen_paths.has(stream.resource_path)
			and absf(stream.get_length() - float(spec[1])) <= 0.002,
			"专属音频字段%s必须绑定唯一且时长正确的正式WAV。" % field_name
		)
		if stream != null:
			seen_paths[stream.resource_path] = true
	_expect(
		seen_paths.size() == 12,
		"主战机器人必须精确绑定12条获批独立音效。"
	)

	var scene_text := FileAccess.get_file_as_string(MAIN_SCENE_PATH)
	var enemy := MAIN_SCENE.instantiate() as CombatRobotMainBattleElite
	if enemy != null:
		enemy.config = MAIN_CONFIG
		root.add_child(enemy)
	for node_name: StringName in AUDIO_NODE_SPECS:
		var spec := AUDIO_NODE_SPECS[node_name] as Array
		var player := (
			enemy.get_node_or_null(NodePath(String(node_name))) as AudioStreamPlayer2D
			if enemy != null
			else null
		)
		var configured_stream := MAIN_CONFIG.get(spec[0]) as AudioStream
		_expect(
			scene_text.contains("[node name=\"%s\"" % node_name)
			and player != null
			and player.stream == configured_stream
			and player.bus == &"SFX"
			and is_equal_approx(player.volume_db, float(spec[1]))
			and is_equal_approx(player.max_distance, float(spec[2]))
			and player.max_polyphony == 1,
			"音频节点%s必须静态存在并保持获批混音/空间合同。" % node_name
		)
	if enemy != null:
		enemy.free()


func _test_selectable_p1e_entry_contract() -> void:
	var definition := GameModeCatalog.get_definition(
		GameModeCatalog.MODE_TEST_ARENA_P1E
	)
	_expect(
		GameModeCatalog.MODE_TEST_ARENA_P1E == 8
		and GameModeCatalog.is_valid_mode_id(8)
		and GameModeCatalog.resolve_wire_key_or_default(&"test_arena_p1e") == 8
		and definition != null
		and definition.wire_key == &"test_arena_p1e"
		and GameModeCatalog.is_mode_selectable(8),
		"P1E必须保留v62 mode=8/wire键，并开放已搭建的测试入口。"
	)
	var lobby_ids: Array[int] = []
	for lobby_definition in GameModeCatalog.get_lobby_definitions():
		lobby_ids.append(lobby_definition.mode_id)
	_expect(
		lobby_ids == [0, 1, 2, 5, 6, 7, 8, 3, 4]
		and lobby_ids.has(GameModeCatalog.MODE_TEST_ARENA_P1E),
		"P1E必须出现在多人大厅选项中。"
	)
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager != null:
		net_manager.disconnect_from_game()
		_expect(
			net_manager.set_pending_game_mode(
				NetManagerStore.GameMode.TEST_ARENA_P1E
			)
			and net_manager.get_current_game_mode()
			== NetManagerStore.GameMode.TEST_ARENA_P1E,
			"NetManager必须允许通过稳定wire值选择P1E。"
		)


func _test_protocol_boundaries() -> void:
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 76
		and NET_CONSTANTS.CHANNEL_COUNT == 8
		and CombatAttackRegistry.PlayerHitWireId.COMBAT_ROBOT_GUNNER_ELITE_BULLET
		== 18
		and CombatAttackRegistry.encode_player_hit_source(
			&"combat_robot_main_battle_elite"
		) == CombatAttackRegistry.PlayerHitWireId.INVALID
		and CombatAttackRegistry.decode_player_hit_source(19) == &"",
		"协议v76必须隔离同局成员身份并保留v74旧局CH6、v73会话成员、P1E和攻击来源合同。"
	)


func _test_live_registry_and_texture_counts() -> void:
	_expect(
		EnemyCodexRegistry.ENTRY_COUNT == 64
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.NORMAL
		] == 51
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.ELITE
		] == 12
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.BOSS
		] == 1
		and EnemyCodexRegistry.EXPECTED_FAMILY_COUNTS[&"mechanical_life"] == 11
		and EnemyCodexRegistry.get_entry(&"combat_robot_main_battle_elite") != null
		and EnemyCodexRegistry.get_entry(
			&"combat_robot_main_battle_elite"
		).enemy_config == MAIN_CONFIG
		and EnemyCodexRegistry.validate_contract(),
		"正式图鉴必须保持64/51/12/1、机械生命11，并唯一注册主战机器人。"
	)
	var all_enemy_pngs := _count_pngs_recursive("res://resources/texture/enemy")
	var mechanical_pngs := _count_pngs_recursive(
		"res://resources/texture/enemy/mechanical_life"
	)
	_expect(
		all_enemy_pngs == 88 and mechanical_pngs == 21,
		"正式敌人纹理必须保持88张、机械生命21张；实际%d/%d。"
		% [all_enemy_pngs, mechanical_pngs]
	)
	var mappings := FateCoordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH
	_expect(
		mappings.size() == 10
		and not mappings.has(MAIN_CONFIG_PATH)
		and MAIN_CONFIG_PATH not in mappings.values(),
		"Fate必须保持10项，主战机器人不得加入无普通基型的替换映射。"
	)


func _test_zero_direct_references() -> void:
	var references := _find_text_references("res://resources/config", MAIN_CONFIG_PATH)
	references.sort()
	_expect(
		references == EXPECTED_DIRECT_CONFIG_REFERENCES,
		(
			"主战机器人仅可由P1E单/多人波次与正式图鉴直引；"
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
