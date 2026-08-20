extends SceneTree

const NORMAL_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const LARGE_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const LARGE_SCENE: PackedScene = preload(
	"res://scene/enemy/artificial_creation/cardboard_monster_large.tscn"
)
const LARGE_CODEX_ENTRY: EnemyCodexEntryConfig = preload(
	"res://resources/config/encyclopedia/enemies/cardboard_monster_large.tres"
)
const LARGE_SPRITE_FRAMES: SpriteFrames = preload(
	"res://resources/animation/cardboard_monster_large.tres"
)
const P1C_WAVES: Array[WaveConfig] = [
	preload(
		"res://resources/config/campaigns/test_arena/p1c/singleplayer/wave_01.tres"
	),
	preload(
		"res://resources/config/campaigns/test_arena/p1c/multiplayer/wave_01.tres"
	),
]
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const LARGE_REFERENCE_CONTRACT := preload(
	"res://dev_tools/cardboard_monster_large_reference_contract.gd"
)
const NORMAL_CONFIG_PATH := (
	"res://resources/config/enemies/cardboard_monster.tres"
)
const LARGE_CONFIG_PATH := (
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const LARGE_TEXTURE_PATH := (
	"res://resources/texture/enemy/artificial_creation/cardboard_monster_large.png"
)
const EXPECTED_LARGE_CONFIG_REFERENCES := [
	"res://resources/config/campaigns/test_arena/p1c/multiplayer/wave_01.tres",
	"res://resources/config/campaigns/test_arena/p1c/singleplayer/wave_01.tres",
	LARGE_REFERENCE_CONTRACT.FORMAL_WAVE_12_PATH,
	"res://resources/config/encyclopedia/enemies/cardboard_monster_large.tres",
	"res://resources/config/runtime_content_catalog.gd",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_codex_and_counts()
	_test_texture_counts()
	_test_fate_and_protocol_boundaries()
	_test_p1c_round_robin_contract()
	_test_formal_direct_reference_contract()
	_test_exact_direct_references()
	_finish()


func _test_codex_and_counts() -> void:
	_expect(
		LARGE_CODEX_ENTRY.entry_id == &"cardboard_monster_large"
		and LARGE_CODEX_ENTRY.enemy_config == LARGE_CONFIG
		and LARGE_CODEX_ENTRY.preview_frames == LARGE_SPRITE_FRAMES
		and LARGE_CODEX_ENTRY.family_id == &"artificial_creation"
		and LARGE_CODEX_ENTRY.family_label == "人工造物"
		and LARGE_CODEX_ENTRY.rank == EnemyCodexEntryConfig.Rank.NORMAL
		and LARGE_CODEX_ENTRY.sort_order == 516
		and LARGE_CODEX_ENTRY.traits
		== PackedStringArray(["人工造物", "大型纸箱", "纸剑重挥"]),
		"大纸箱怪图鉴必须保持516排序、普通人工造物与三项玩家可见特性。"
	)
	_expect(
		LARGE_CONFIG.display_name == "大纸箱怪"
		and LARGE_CONFIG.category_tags
		== PackedStringArray(["artificial_creation"])
		and LARGE_CONFIG.enemy_scene == LARGE_SCENE
		and LARGE_CONFIG.max_health == 15
		and LARGE_CONFIG.attack_damage == 40
		and is_equal_approx(LARGE_CONFIG.move_speed, 22.0),
		"大纸箱怪必须为15生命、40攻击、22移速且只属于人工造物。"
	)
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
		and EnemyCodexRegistry.EXPECTED_FAMILY_COUNTS[&"artificial_creation"] == 4
		and EnemyCodexRegistry.EXPECTED_FAMILY_COUNTS[&"mechanical_life"] == 11
		and EnemyCodexRegistry.validate_contract(),
		"图鉴计数必须为64/51/12/1，人工造物4、机械生命11。"
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
	var texture := Image.load_from_file(LARGE_TEXTURE_PATH)
	_expect(
		texture != null and texture.get_size() == Vector2i(384, 144),
		"大纸箱怪运行图集必须为384×144。"
	)


func _test_fate_and_protocol_boundaries() -> void:
	var mappings := FateCoordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH
	_expect(
		mappings.size() == 10
		and not mappings.has(NORMAL_CONFIG_PATH)
		and not mappings.has(LARGE_CONFIG_PATH),
		"命运精英映射必须保持10项，普通与大纸箱怪都不得拥有精英替换。"
	)
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 90
		and NET_CONSTANTS.CHANNEL_COUNT == 9
		and CombatAttackRegistry.PlayerHitWireId.COMBAT_ROBOT_GUNNER_ELITE_BULLET
		== 18
		and CombatAttackRegistry.encode_player_hit_source(
			&"cardboard_monster_large_slash"
		) == CombatAttackRegistry.PlayerHitWireId.INVALID
		and CombatAttackRegistry.decode_player_hit_source(19) == &"",
		"协议v90必须保留九条逻辑信道、内容摘要、同局成员身份、大纸箱怪及既有 wire 合同。"
	)
	_expect(
		GameModeCatalog.MODE_TEST_ARENA_P1C == 6
		and GameModeCatalog.MODE_TEST_ARENA_P1D == 7
		and GameModeCatalog.resolve_wire_key_or_default(&"test_arena_p1c") == 6,
		"P1C必须保持模式ID 6与wire key test_arena_p1c，P1D仍为ID 7。"
	)


func _test_p1c_round_robin_contract() -> void:
	for wave in P1C_WAVES:
		_expect(wave != null, "P1C单/多人波次都必须可加载。")
		if wave == null:
			continue
		_expect(
			wave.enemy_entries.size() == 2
			and wave.enemy_entries[0].enemy_config == NORMAL_CONFIG
			and wave.enemy_entries[0].count == 500
			and wave.enemy_entries[1].enemy_config == LARGE_CONFIG
			and wave.enemy_entries[1].count == 500
			and wave.get_total_enemy_count() == 1000,
			"P1C必须按普通纸箱怪500→大纸箱怪500的顺序组成1000只。"
		)
		_expect(
			wave.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
			and is_equal_approx(wave.spawn_interval, 3.0)
			and wave.spawn_count_per_tick == 1
			and wave.max_alive_enemies == 1000,
			"P1C必须每3秒严格轮转生成1只，存活上限1000。"
		)


func _test_formal_direct_reference_contract() -> void:
	failures.append_array(
		LARGE_REFERENCE_CONTRACT.validate_formal_wave_12_contract()
	)


func _test_exact_direct_references() -> void:
	var references := _find_text_references(
		"res://resources/config", LARGE_CONFIG_PATH
	)
	references.sort()
	_expect(
		references == EXPECTED_LARGE_CONFIG_REFERENCES,
		(
			"大纸箱怪仅可由P1C单/多人、正式塔防第12波、图鉴与运行时"
			+ "内容信任目录直接引用；"
			+ "其他正式/测试/性能/肉鸽资源必须保持零直引：%s。"
		)
		% [references]
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


func _finish() -> void:
	if failures.is_empty():
		print("CARDBOARD_MONSTER_LARGE_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
