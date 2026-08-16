extends SceneTree

const ARENA_DIRECTORY := (
	"res://scene/game_modes/tower_defense/test_arenas"
)
const P1A_SCENE_PATH := ARENA_DIRECTORY + "/test_grass_arena.tscn"
const P1A_SOURCE_PATH := ARENA_DIRECTORY + "/test_grass_arena.gd"
const P1B_SCENE_PATH := ARENA_DIRECTORY + "/test_grass_arena_p1b.tscn"
const P1C_SCENE_PATH := ARENA_DIRECTORY + "/test_grass_arena_p1c.tscn"
const P2_SCENE_PATH := ARENA_DIRECTORY + "/test_grass_arena_p2.tscn"
const CAMPAIGN_ROOT := "res://resources/config/campaigns/test_arena"
const DEFINITION_ROOT := "res://scene/game_modes/definitions"
const MULTIPLAYER_ENTRY_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/"
	+ "tower_defense_multiplayer_session.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_scene_text_contracts()
	_test_campaign_resource_contracts()
	if failures.is_empty():
		print("TEST_GRASS_ARENA_RESOURCE_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_scene_text_contracts() -> void:
	var p1a_scene := _read_text(P1A_SCENE_PATH)
	var p1a_source := _read_text(P1A_SOURCE_PATH)
	_test_scene_definition_binding(
		p1a_scene,
		DEFINITION_ROOT + "/test_arena_p1.tres",
		"P1A"
	)
	_expect(
		p1a_scene.contains(
			'path="res://scene/game_modes/tower_defense/tower_defense_game.tscn"'
		)
		and p1a_scene.contains('test_scene_label = "P1A"')
		and p1a_scene.contains(
			'test_entry_announcement_text = "测试场景 P1A"'
		)
		and p1a_scene.contains("day_phase_announcements_enabled = false")
		and p1a_scene.contains("sandbox_free_building_enabled = true"),
		"P1A 场景必须继承正式塔防并保留独立测试表现配置。"
	)
	var spawn1_section := _get_node_section(
		p1a_scene,
		"Spawn1",
		"EnemySpawnPoints"
	)
	var spawn2_section := _get_node_section(
		p1a_scene,
		"Spawn2",
		"EnemySpawnPoints"
	)
	var zhuangfangyi_section := _get_node_section(
		p1a_scene,
		"ZhuangfangyiMerchant",
		"."
	)
	var luoxi_section := _get_node_section(
		p1a_scene,
		"LuoxiMerchant",
		"."
	)
	_expect(
		_node_property_equals(
			spawn1_section,
			"position",
			"Vector2(248, 120)"
		)
		and _node_property_equals(
			spawn2_section,
			"position",
			"Vector2(248, 136)"
		)
		and _node_property_equals(
			zhuangfangyi_section,
			"position",
			"Vector2(96, 224)"
		)
		and _node_property_equals(
			luoxi_section,
			"position",
			"Vector2(154, 224)"
		),
		"P1A 两个红门与两位商人的作者位置必须稳定。"
	)
	_expect(
		p1a_source.contains("const GRASS_RECT := Rect2i(0, 0, 16, 16)")
		and p1a_source.contains("const TEST_BASE_HEALTH := 1000")
		and p1a_source.contains(
			"progression_config.initial_preparation_seconds = 3.0"
		)
		and p1a_source.contains(
			"progression_config.enemy_count_per_extra_player_ratio = 0.0"
		),
		"P1A 资源契约必须保持 16×16、1000 核心生命和固定三秒准备。"
	)

	_test_inherited_scene_text(
		P1B_SCENE_PATH,
		"test_arena_p1b.tres",
		"P1B",
		"测试场景 P1B"
	)
	_test_inherited_scene_text(
		P1C_SCENE_PATH,
		"test_arena_p1c.tres",
		"P1C",
		"测试场景 P1C"
	)
	var p2_scene := _read_text(P2_SCENE_PATH)
	_test_scene_definition_binding(
		p2_scene,
		DEFINITION_ROOT + "/test_arena_p2.tres",
		"P2"
	)
	_expect(
		p2_scene.contains('path="%s"' % P1A_SCENE_PATH)
		and p2_scene.contains('path="%s/test_grass_arena_p2.gd"' % ARENA_DIRECTORY)
		and p2_scene.contains("waves_per_day = 1")
		and p2_scene.contains("night_start_wave_in_day = 1")
		and p2_scene.contains('test_entry_announcement_text = ""'),
		"P2 必须继承 P1A，并保留单波日结与禁用 P1A 报幕的资源配置。"
	)


func _test_inherited_scene_text(
	path: String,
	definition_file_name: String,
	label: String,
	announcement: String
) -> void:
	var source := _read_text(path)
	_test_scene_definition_binding(
		source,
		DEFINITION_ROOT + "/" + definition_file_name,
		label
	)
	_expect(
		source.contains('path="%s"' % P1A_SCENE_PATH)
		and source.contains('test_scene_label = "%s"' % label)
		and source.contains(
			'test_entry_announcement_text = "%s"' % announcement
		),
		"%s 必须只覆写自己的模式定义与测试标签。" % label
	)


func _test_scene_definition_binding(
	scene_source: String,
	definition_path: String,
	label: String
) -> void:
	var definition_resource_id := _get_ext_resource_id(
		scene_source,
		definition_path
	)
	var root_section := _get_root_node_section(scene_source)
	_expect(
		not definition_resource_id.is_empty()
		and _node_property_equals(
			root_section,
			"mode_definition",
			'ExtResource("%s")' % definition_resource_id
		),
		(
			"%s 根节点 mode_definition 必须通过同场景 ExtResource 精确绑定 %s。"
			% [label, definition_path]
		)
	)


func _get_ext_resource_id(scene_source: String, resource_path: String) -> String:
	for raw_line in scene_source.split("\n"):
		var line := String(raw_line).strip_edges()
		if (
			line.begins_with("[ext_resource ")
			and line.contains('path="%s"' % resource_path)
		):
			var id_prefix := ' id="'
			var id_start := line.find(id_prefix)
			if id_start < 0:
				return ""
			id_start += id_prefix.length()
			var id_end := line.find('"', id_start)
			return line.substr(id_start, id_end - id_start) if id_end > id_start else ""
	return ""


func _get_root_node_section(scene_source: String) -> String:
	var section_lines := PackedStringArray()
	var collecting := false
	for raw_line in scene_source.split("\n"):
		var line := String(raw_line).strip_edges()
		if line.begins_with("[node "):
			if collecting:
				break
			collecting = true
		if collecting:
			section_lines.append(line)
	return "\n".join(section_lines)


func _get_node_section(
	scene_source: String,
	node_name: String,
	parent_path: String
) -> String:
	var section_lines := PackedStringArray()
	var collecting := false
	for raw_line in scene_source.split("\n"):
		var line := String(raw_line).strip_edges()
		if line.begins_with("[node "):
			if collecting:
				break
			collecting = (
				line.contains('name="%s"' % node_name)
				and line.contains('parent="%s"' % parent_path)
			)
		if collecting:
			section_lines.append(line)
	return "\n".join(section_lines)


func _node_property_equals(
	node_section: String,
	property_name: String,
	expected_value: String
) -> bool:
	var expected_line := "%s = %s" % [property_name, expected_value]
	for raw_line in node_section.split("\n"):
		var line := String(raw_line).strip_edges()
		if line.begins_with(property_name + " ="):
			return line == expected_line
	return false


func _test_campaign_resource_contracts() -> void:
	_test_campaign_pair(
		DEFINITION_ROOT + "/test_arena_p1.tres",
		P1A_SCENE_PATH,
		CAMPAIGN_ROOT,
		&"test_grass_arena_singleplayer",
		&"test_grass_arena_multiplayer",
		[
			"res://resources/config/enemies/slime.tres",
			"res://resources/config/enemies/slime_golden.tres",
			"res://resources/config/enemies/slime_fire.tres",
			"res://resources/config/enemies/slime_frost.tres",
			"res://resources/config/enemies/slime_green.tres",
		],
		[200, 200, 200, 200, 200],
		WaveConfig.SpawnOrder.SHUFFLED,
		3.0,
		1000,
		3,
		"P1A"
	)
	_test_campaign_pair(
		DEFINITION_ROOT + "/test_arena_p1b.tres",
		P1B_SCENE_PATH,
		CAMPAIGN_ROOT + "/p1b",
		&"test_grass_arena_p1b_singleplayer",
		&"test_grass_arena_p1b_multiplayer",
		[
			"res://resources/config/enemies/combat_robot.tres",
			"res://resources/config/enemies/combat_robot_gunner.tres",
			"res://resources/config/enemies/combat_robot_drone_operator.tres",
			"res://resources/config/enemies/combat_robot_shield_bearer.tres",
			"res://resources/config/enemies/combat_robot_ninja.tres",
		],
		[200, 200, 200, 200, 200],
		WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN,
		3.0,
		1000,
		3,
		"P1B"
	)
	_test_campaign_pair(
		DEFINITION_ROOT + "/test_arena_p1c.tres",
		P1C_SCENE_PATH,
		CAMPAIGN_ROOT + "/p1c",
		&"test_grass_arena_p1c_singleplayer",
		&"test_grass_arena_p1c_multiplayer",
		[
			"res://resources/config/enemies/cardboard_monster.tres",
			"res://resources/config/enemies/cardboard_monster_large.tres",
		],
		[500, 500],
		WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN,
		3.0,
		1000,
		3,
		"P1C"
	)
	_test_campaign_pair(
		DEFINITION_ROOT + "/test_arena_p2.tres",
		P2_SCENE_PATH,
		CAMPAIGN_ROOT + "/p2",
		&"test_grass_arena_p2_singleplayer",
		&"test_grass_arena_p2_multiplayer",
		["res://resources/config/enemies/slime.tres"],
		[1],
		WaveConfig.SpawnOrder.SHUFFLED,
		0.25,
		1,
		1,
		"P2"
	)


func _test_campaign_pair(
	definition_path: String,
	expected_runtime_scene_path: String,
	root_path: String,
	singleplayer_id: StringName,
	multiplayer_id: StringName,
	expected_enemy_paths: Array,
	expected_counts: Array,
	expected_order: WaveConfig.SpawnOrder,
	expected_interval: float,
	expected_max_alive: int,
	expected_spawn_mask: int,
	label: String
) -> void:
	var definition := load(definition_path) as GameModeDefinition
	_expect(definition != null, "%s GameModeDefinition 无法加载。" % label)
	if definition == null:
		return
	_expect(
		definition.validate_definition().is_empty(),
		"%s GameModeDefinition 校验失败。" % label
	)
	_expect(
		definition.singleplayer_entry_scene_path == expected_runtime_scene_path
		and definition.multiplayer_entry_scene_path
		== MULTIPLAYER_ENTRY_SCENE_PATH
		and definition.multiplayer_runtime_scene_path == expected_runtime_scene_path
		and ResourceLoader.exists(definition.singleplayer_entry_scene_path)
		and ResourceLoader.exists(definition.multiplayer_entry_scene_path)
		and ResourceLoader.exists(definition.multiplayer_runtime_scene_path),
		(
			"%s 必须精确映射单人草地入口、共享多人入口与多人草地运行场景。"
			% label
		)
	)
	var expected_singleplayer_campaign_path := (
		root_path + "/singleplayer/campaign.tres"
	)
	var expected_multiplayer_campaign_path := (
		root_path + "/multiplayer/campaign.tres"
	)
	_expect(
		definition.singleplayer_campaign_path
		== expected_singleplayer_campaign_path
		and definition.multiplayer_campaign_path
		== expected_multiplayer_campaign_path,
		"%s GameModeDefinition 的单/多人 Campaign 路径映射漂移。" % label
	)
	_test_campaign(
		definition.singleplayer_campaign_path,
		singleplayer_id,
		expected_enemy_paths,
		expected_counts,
		expected_order,
		expected_interval,
		expected_max_alive,
		expected_spawn_mask,
		label + " 单人"
	)
	_test_campaign(
		definition.multiplayer_campaign_path,
		multiplayer_id,
		expected_enemy_paths,
		expected_counts,
		expected_order,
		expected_interval,
		expected_max_alive,
		expected_spawn_mask,
		label + " 多人"
	)


func _test_campaign(
	path: String,
	expected_id: StringName,
	expected_enemy_paths: Array,
	expected_counts: Array,
	expected_order: WaveConfig.SpawnOrder,
	expected_interval: float,
	expected_max_alive: int,
	expected_spawn_mask: int,
	label: String
) -> void:
	var campaign := load(path) as WaveCampaignConfig
	_expect(campaign != null, "%s Campaign 无法加载。" % label)
	if campaign == null:
		return
	_expect(campaign.campaign_id == expected_id, "%s Campaign ID 漂移。" % label)
	_expect(campaign.validate_campaign().is_empty(), "%s Campaign 校验失败。" % label)
	var waves := campaign.get_waves()
	_expect(waves.size() == 1, "%s 必须只有一个波次。" % label)
	if waves.size() != 1:
		return
	var wave := waves[0] as WaveConfig
	_expect(wave != null, "%s 唯一流程节点必须是 WaveConfig。" % label)
	if wave == null:
		return
	_expect(
		wave.enemy_entries.size() == expected_enemy_paths.size(),
		"%s 敌人条目数量漂移。" % label
	)
	if wave.enemy_entries.size() == expected_enemy_paths.size():
		for index in expected_enemy_paths.size():
			var entry := wave.enemy_entries[index]
			_expect(
				entry.enemy_config != null
				and entry.enemy_config.resource_path == expected_enemy_paths[index]
				and entry.count == expected_counts[index],
				"%s 第 %d 个敌人配置或数量漂移。" % [label, index + 1]
			)
	_expect(
		wave.spawn_order == expected_order
		and is_equal_approx(wave.spawn_interval, expected_interval)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == expected_max_alive
		and wave.spawn_point_mask == expected_spawn_mask,
		"%s 生成顺序、节奏、上限或出生门漂移。" % label
	)
	var expected_total := 0
	for count in expected_counts:
		expected_total += int(count)
	_expect(
		wave.get_total_enemy_count() == expected_total,
		"%s 敌人总数漂移。" % label
	)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("无法读取草地资源契约：%s" % path)
		return ""
	return file.get_as_text()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
