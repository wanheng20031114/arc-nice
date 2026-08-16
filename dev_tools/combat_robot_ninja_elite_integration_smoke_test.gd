extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja_elite.tres"
)
const ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_ninja_elite.tscn"
)
const CODEX_ENTRY := preload(
	"res://resources/config/encyclopedia/enemies/combat_robot_ninja_elite.tres"
)
const FATE_COORDINATOR_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/fate/fate_coordinator.gd"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const ORDINARY_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot_ninja.tres"
)
const ELITE_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot_ninja_elite.tres"
)
const P1B_WAVE_PATHS := [
	"res://resources/config/campaigns/test_arena/p1b/singleplayer/wave_01.tres",
	"res://resources/config/campaigns/test_arena/p1b/multiplayer/wave_01.tres",
]
const P1B_EXPECTED_ENTRY_ORDER := [
	"SubResource(\"Resource_combat_robot_entry\")",
	"SubResource(\"Resource_combat_robot_gunner_entry\")",
	"SubResource(\"Resource_combat_robot_drone_operator_entry\")",
	"SubResource(\"Resource_combat_robot_shield_bearer_entry\")",
	"SubResource(\"Resource_combat_robot_ninja_entry\")",
]
const ZERO_DIRECT_REFERENCE_ROOTS := {
	"正式标准单人波次": "res://resources/config/campaigns/standard/singleplayer",
	"正式标准多人波次": "res://resources/config/campaigns/standard/multiplayer",
	"正式塔防波次": "res://resources/config/campaigns/tower_defense/formal",
	"旧正式波次": "res://resources/config/waves",
	"肉鸽战斗波次": "res://resources/config/campaigns/rogue_combat",
	"肉鸽遭遇配置": "res://resources/config/rogue_combat",
	"P1B单人": "res://resources/config/campaigns/test_arena/p1b/singleplayer",
	"P1B多人": "res://resources/config/campaigns/test_arena/p1b/multiplayer",
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_codex_and_fate()
	_test_protocol_and_no_new_attack_resources()
	_test_texture_counts()
	_test_p1b_contract()
	_test_zero_direct_references()
	for _cleanup_frame in range(3):
		await process_frame
	if failures.is_empty():
		print("COMBAT_ROBOT_NINJA_ELITE_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_codex_and_fate() -> void:
	_expect(
		CODEX_ENTRY.entry_id == &"combat_robot_ninja_elite"
		and CODEX_ENTRY.enemy_config == ELITE_CONFIG
		and CODEX_ENTRY.enemy_config.enemy_scene == ELITE_SCENE
		and CODEX_ENTRY.family_id == &"mechanical_life"
		and CODEX_ENTRY.rank == EnemyCodexEntryConfig.Rank.ELITE
		and CODEX_ENTRY.sort_order == 565
		and CODEX_ENTRY.traits
		== PackedStringArray(["精英", "高频反击", "紫能双刃"])
		and CODEX_ENTRY.description.contains("2倍")
		and CODEX_ENTRY.description.contains("0.5秒")
		and CODEX_ENTRY.description.contains("2秒")
		and CODEX_ENTRY.description.contains("不会刷新或排队"),
		"精英忍者图鉴必须保持排序565、机械生命精英与2×/0.5/2秒说明。"
	)
	var registry_text := FileAccess.get_file_as_string(
		"res://resources/config/encyclopedia/enemy_codex_registry.gd"
	)
	var catalog_text := FileAccess.get_file_as_string(
		"res://resources/config/encyclopedia/codex_catalog.gd"
	)
	_expect(
		registry_text.contains("const ENTRY_COUNT := 64")
		and registry_text.contains("&\"mechanical_life\": 11")
		and registry_text.contains("&\"artificial_creation\": 4")
		and registry_text.contains("EnemyCodexEntryConfig.Rank.NORMAL: 51")
		and registry_text.contains("EnemyCodexEntryConfig.Rank.ELITE: 12")
		and registry_text.contains("EnemyCodexEntryConfig.Rank.BOSS: 1")
		and registry_text.count(
			"resources/config/encyclopedia/enemies/combat_robot_ninja_elite.tres"
		) == 1
		and catalog_text.contains("CodexSection.ENEMY: 64"),
		"图鉴计数必须为64/51/12/1、机械生命11、人工造物4，且精英忍者只注册一次。"
	)

	var fate_coordinator := FATE_COORDINATOR_SCRIPT.new()
	_expect(
		fate_coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.size() == 10
		and str(fate_coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.get(
			ORDINARY_CONFIG_PATH, ""
		)) == ELITE_CONFIG_PATH,
		"命运系统必须把普通忍者映射到精英忍者，并保持十组替换。"
	)
	fate_coordinator.free()


func _test_protocol_and_no_new_attack_resources() -> void:
	_expect(NET_CONSTANTS.PROTOCOL_VERSION == 76, "协议v76必须隔离同局成员身份并保留v74旧局CH6、v73会话成员与精英忍者资源语义。")
	_expect(
		CombatAttackRegistry.PlayerHitWireId.COMBAT_ROBOT_GUNNER_ELITE_BULLET == 18
		and CombatAttackRegistry.encode_player_hit_source(
			&"combat_robot_ninja_elite"
		) == CombatAttackRegistry.PlayerHitWireId.INVALID
		and CombatAttackRegistry.decode_player_hit_source(19) == &"",
		"精英忍者不得新增攻击证书，稳定末尾必须保持ID18。"
	)
	for source_path in [
		"res://scene/combat/runtime/combat_runtime_base.gd",
		"res://scene/combat/runtime/wave_combat_runtime_base.gd",
		"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd",
		"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd",
	]:
		var source_text := FileAccess.get_file_as_string(source_path)
		_expect(
			not source_text.contains("combat_robot_ninja_elite"),
			"精英忍者不得新增投射物、对象池或独立预热：%s。" % source_path
		)


func _test_texture_counts() -> void:
	var all_enemy_pngs := _count_pngs_recursive("res://resources/texture/enemy")
	var artificial_pngs := _count_pngs_recursive(
		"res://resources/texture/enemy/artificial_creation"
	)
	var mechanical_pngs := _count_pngs_recursive(
		"res://resources/texture/enemy/mechanical_life"
	)
	_expect(
		all_enemy_pngs == 88 and artificial_pngs == 4 and mechanical_pngs == 21,
		"敌人纹理必须为88张、人工造物4张、机械生命21张；实际%d/%d/%d。"
		% [all_enemy_pngs, artificial_pngs, mechanical_pngs]
	)


func _test_p1b_contract() -> void:
	for wave_path in P1B_WAVE_PATHS:
		var wave_text := FileAccess.get_file_as_string(wave_path)
		_expect(
			not wave_text.is_empty()
			and wave_text.count("count = 200") == 5
			and wave_text.contains("spawn_order = 1")
			and wave_text.contains("spawn_interval = 3.0")
			and wave_text.contains("max_alive_enemies = 1000")
			and not wave_text.contains(ELITE_CONFIG_PATH),
			"P1B必须保持五种普通机器人各200台、总数1000且零精英忍者直引。"
		)
		var entries_line := ""
		for line in wave_text.split("\n"):
			if line.begins_with("enemy_entries = "):
				entries_line = line
				break
		var previous_index := -1
		for token in P1B_EXPECTED_ENTRY_ORDER:
			var current_index := entries_line.find(token)
			_expect(
				current_index > previous_index,
				"P1B必须维持持剑→持枪→操作员→举盾→忍者严格轮转。"
			)
			previous_index = current_index


func _test_zero_direct_references() -> void:
	for label: String in ZERO_DIRECT_REFERENCE_ROOTS:
		var references := _find_text_references(
			ZERO_DIRECT_REFERENCE_ROOTS[label], ELITE_CONFIG_PATH
		)
		_expect(
			references.is_empty(),
			"%s不得直接引用精英忍者战斗机器人：%s。" % [label, references]
		)


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
