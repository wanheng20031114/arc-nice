extends SceneTree

const ARENA_SCENE := preload(
	"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1c.tscn"
)
const SINGLEPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p1c/singleplayer/campaign.tres"
)
const MULTIPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p1c/multiplayer/campaign.tres"
)
const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const LARGE_CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const LARGE_CARDBOARD_CONFIG_PATH := (
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const ZERO_DIRECT_REFERENCE_ROOTS := {
	"正式标准单人": "res://resources/config/campaigns/standard/singleplayer",
	"正式标准多人": "res://resources/config/campaigns/standard/multiplayer",
	"正式塔防": "res://resources/config/campaigns/tower_defense/formal",
	"塔防性能": "res://resources/config/campaigns/tower_defense/performance",
	"旧正式波次": "res://resources/config/waves",
	"肉鸽战斗": "res://resources/config/campaigns/rogue_combat",
	"肉鸽遭遇": "res://resources/config/rogue_combat",
	"P1A单人": "res://resources/config/campaigns/test_arena/singleplayer",
	"P1A多人": "res://resources/config/campaigns/test_arena/multiplayer",
	"P1B": "res://resources/config/campaigns/test_arena/p1b",
	"P1D": "res://resources/config/campaigns/test_arena/p1d",
	"P2": "res://resources/config/campaigns/test_arena/p2",
	"P3": "res://resources/config/rogue_route",
}
const EXPECTED_ENEMY_COUNT := 1000

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var arena := ARENA_SCENE.instantiate() as TestGrassArena
	_expect(arena != null, "P1C 必须复用 TestGrassArena 运行时。")
	if arena == null:
		_finish()
		return
	arena.auto_start_waves = false
	var fate := arena.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate != null:
		fate.elite_enemy_config_loads_requested = true
	root.add_child(arena)
	current_scene = arena
	await process_frame
	await process_frame

	_test_scene_and_catalog_contract(arena)
	_test_campaign_contract(SINGLEPLAYER_CAMPAIGN, "单人")
	_test_campaign_contract(MULTIPLAYER_CAMPAIGN, "多人")
	_test_multiplayer_probe_entry_contract()
	_test_zero_direct_references()

	current_scene = null
	arena.queue_free()
	await process_frame
	await process_frame
	_finish()


func _test_scene_and_catalog_contract(arena: TestGrassArena) -> void:
	var definition := GameModeCatalog.get_definition(
		GameModeCatalog.MODE_TEST_ARENA_P1C
	)
	_expect(
		definition != null
		and definition.mode_id == 6
		and definition.wire_key == &"test_arena_p1c"
		and definition.lobby_order == 4
		and definition.lobby_icon_path
		== "res://resources/texture/ui/multiplayer/mode_test_p1.png",
		"P1C 必须以 wire=6 接入，并复用 P1A 大厅图标。"
	)
	_expect(
		arena.mode_definition == definition
		and arena.singleplayer_campaign == SINGLEPLAYER_CAMPAIGN
		and arena.multiplayer_campaign == MULTIPLAYER_CAMPAIGN,
		"P1C 场景必须由目录定义绑定独立单人/多人 Campaign。"
	)
	_expect(
		arena.test_scene_label == "P1C"
		and arena.test_entry_announcement_text == "测试场景 P1C"
		and not arena.day_phase_announcements_enabled
		and arena.sandbox_free_building_enabled,
		"P1C 必须保留 P1A 地图的测试场表现与自由建造合同。"
	)
	_expect(
		is_zero_approx(arena.progression_config.enemy_count_per_extra_player_ratio)
		and arena.progression_config.get_scaled_enemy_count(EXPECTED_ENEMY_COUNT, 8)
		== EXPECTED_ENEMY_COUNT,
		"P1C 的1000只大小纸箱怪不得随多人房间人数缩放。"
	)


func _test_campaign_contract(
	campaign: WaveCampaignConfig,
	mode_label: String
) -> void:
	_expect(campaign.validate_campaign().is_empty(), "P1C %s Campaign 必须通过校验。" % mode_label)
	var waves := campaign.get_waves()
	_expect(waves.size() == 1, "P1C %s Campaign 必须只有一个波次。" % mode_label)
	if waves.size() != 1:
		return
	var wave := waves[0] as WaveConfig
	_expect(
		wave != null
		and wave.enemy_entries.size() == 2
		and wave.enemy_entries[0].enemy_config == CARDBOARD_CONFIG
		and wave.enemy_entries[0].count == 500
		and wave.enemy_entries[1].enemy_config == LARGE_CARDBOARD_CONFIG
		and wave.enemy_entries[1].count == 500
		and wave.get_total_enemy_count() == EXPECTED_ENEMY_COUNT,
		"P1C %s波次必须按普通500→大型500登记1000只纸箱怪。" % mode_label
	)
	_expect(
		is_equal_approx(wave.spawn_interval, 3.0)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == EXPECTED_ENEMY_COUNT,
		"P1C %s必须每3秒生成1只，场上上限1000。" % mode_label
	)
	_expect(
		wave.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
		and wave.spawn_point_mask == 3
		and wave.get_enabled_spawn_point_names() == [&"Spawn1", &"Spawn2"],
		"P1C %s必须保持条目轮询并只使用右侧两个出生门。" % mode_label
	)


func _test_zero_direct_references() -> void:
	for label: String in ZERO_DIRECT_REFERENCE_ROOTS:
		var references := _find_text_references(
			ZERO_DIRECT_REFERENCE_ROOTS[label],
			LARGE_CARDBOARD_CONFIG_PATH
		)
		_expect(
			references.is_empty(),
			"%s不得直接引用大纸箱怪：%s。" % [label, references]
		)


func _test_multiplayer_probe_entry_contract() -> void:
	var runner_source := FileAccess.get_file_as_string(
		"res://dev_tools/run_multiplayer_lan_probe.ps1"
	)
	_expect(
		'"test_arena_p1c"' in runner_source,
		"多人 LAN 探针入口必须允许 test_arena_p1c。"
	)


func _find_text_references(directory_path: String, needle: String) -> Array[String]:
	var matches: Array[String] = []
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开零直引审计目录：%s。" % directory_path)
		return matches
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				matches.append_array(_find_text_references(child_path, needle))
			elif entry_name.get_extension() in ["tres", "tscn", "gd"]:
				var source := FileAccess.get_file_as_string(child_path)
				if needle in source:
					matches.append(child_path)
		entry_name = directory.get_next()
	directory.list_dir_end()
	return matches


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TEST_GRASS_ARENA_P1C_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
