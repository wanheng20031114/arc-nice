extends SceneTree

const WAVE_CAMPAIGN_CONFIG_SCRIPT := preload(
	"res://resources/config/waves/wave_campaign_config.gd"
)
const STANDARD_GAME_SCENE := preload("res://scene/game.tscn")
const TOWER_DEFENSE_GAME_SCENE := preload("res://scene/game_tower_defense.tscn")
const CAMPAIGN_DEFINITIONS := [
	{
		"path": "res://resources/config/campaigns/standard/singleplayer/campaign.tres",
		"directory": "res://resources/config/campaigns/standard/singleplayer/",
		"campaign_id": &"standard_singleplayer",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_path": "res://resources/config/bosses/boss_01_linglan.tres",
		"tower_defense": false,
	},
	{
		"path": "res://resources/config/campaigns/standard/multiplayer/campaign.tres",
		"directory": "res://resources/config/campaigns/standard/multiplayer/",
		"campaign_id": &"standard_multiplayer",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_path": "res://resources/config/bosses/boss_01_linglan.tres",
		"tower_defense": false,
	},
	{
		"path": "res://resources/config/campaigns/tower_defense/singleplayer/campaign.tres",
		"directory": "res://resources/config/campaigns/tower_defense/singleplayer/",
		"campaign_id": &"tower_defense_singleplayer",
		"spawn_point_mask": WaveConfig.ALL_SPAWN_POINT_MASK,
		"tower_defense": true,
	},
	{
		"path": "res://resources/config/campaigns/tower_defense/multiplayer/campaign.tres",
		"directory": "res://resources/config/campaigns/tower_defense/multiplayer/",
		"campaign_id": &"tower_defense_multiplayer",
		"spawn_point_mask": WaveConfig.ALL_SPAWN_POINT_MASK,
		"tower_defense": true,
	},
]

const TOWER_DEFENSE_STRESS_TOTAL_ENEMIES := 1200
const TOWER_DEFENSE_STRESS_MAX_ALIVE := 300
const TOWER_DEFENSE_STRESS_SPAWN_INTERVAL := 0.1
const TOWER_DEFENSE_STRESS_SPAWN_COUNT_PER_TICK := 4
const TOWER_DEFENSE_FOREST_COMBAT_BGM := "res://resources/audio/shenmu_forest_combat.ogg"
const TOWER_DEFENSE_FOREST_INTERMISSION_BGM := "res://resources/audio/shenmu_forest_intermission.ogg"
const STONE_GOLEM_CONFIG_PATH := "res://resources/config/enemies/stone_golem.tres"
const FIRST_WAVE_EXPECTED_COUNTS := {
	"res://resources/config/enemies/yuanshi_insect_basic.tres": 850,
	"res://resources/config/enemies/yuanshi_insect_shell.tres": 320,
	"res://resources/config/enemies/capoo_ak47.tres": 30,
}

var failures: Array[String] = []


func _init() -> void:
	_test_campaign_resources()
	_test_campaign_validation()
	_test_runtime_campaign_selection()
	_test_boss_mode_separation()
	if failures.is_empty():
		print("WAVE_CAMPAIGN_CONFIG_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_campaign_resources() -> void:
	var seen_campaigns: Array[Resource] = []
	var seen_flow_graphs: Array[FlowGraphConfig] = []
	var seen_wave_instances: Array[WaveConfig] = []
	var seen_wave_paths: Dictionary = {}

	for definition in CAMPAIGN_DEFINITIONS:
		var campaign := load(String(definition["path"])) as Resource
		_expect(campaign != null, "Campaign must load: %s" % String(definition["path"]))
		if campaign == null:
			continue
		_expect(campaign.get("campaign_id") == definition["campaign_id"], "Campaign id mismatch: %s" % campaign.resource_path)
		_expect(not seen_campaigns.has(campaign), "Campaign resources must not share instances.")
		seen_campaigns.append(campaign)

		var validation_errors: PackedStringArray = campaign.call("validate_campaign")
		_expect(validation_errors.is_empty(), "Campaign must validate: %s" % str(validation_errors))
		var flow_graph := campaign.get("flow_graph") as FlowGraphConfig
		_expect(flow_graph != null, "Campaign must provide a flow graph: %s" % campaign.resource_path)
		if flow_graph == null:
			continue
		_expect(not seen_flow_graphs.has(flow_graph), "Campaign flow graphs must not share instances.")
		seen_flow_graphs.append(flow_graph)
		_expect(
			flow_graph.resource_path == String(definition["directory"]) + "flow.tres",
			"Campaign flow graph must stay in its own directory: %s" % flow_graph.resource_path
		)

		var waves: Array = campaign.call("get_waves")
		_expect(waves.size() == 12, "Campaign must contain 12 waves: %s" % campaign.resource_path)
		var is_tower_defense := bool(definition["tower_defense"])
		var bosses: Array = campaign.call("get_bosses")
		var expected_boss_count := 0 if is_tower_defense else 1
		_expect(
			bosses.size() == expected_boss_count,
			"Campaign boss count mismatch: %s" % campaign.resource_path
		)
		if not is_tower_defense and bosses.size() == 1:
			var boss_config := bosses[0] as BossConfig
			_expect(boss_config != null, "Campaign boss step must be a BossConfig.")
			if boss_config != null:
				_expect(
					boss_config.resource_path == String(definition["boss_path"]),
					"Campaign selected the wrong mode-specific boss layout: %s"
					% boss_config.resource_path
				)
		if not waves.is_empty():
			_expect(flow_graph.start_step == waves[0], "Campaign flow must start from its first wave.")
		for wave_index in range(waves.size()):
			var wave_config := waves[wave_index] as WaveConfig
			var source_wave := load(
				"res://resources/config/waves/wave_%02d.tres" % (wave_index + 1)
			) as WaveConfig
			_expect(
				source_wave != null
				and source_wave.spawn_point_mask == WaveConfig.STANDARD_SPAWN_POINT_MASK,
				"Canonical source waves must keep an explicit standard spawn mask."
			)
			_expect(wave_config != null, "Campaign contains a null wave.")
			if wave_config == null:
				continue
			var expected_path := "%swave_%02d.tres" % [
				String(definition["directory"]),
				wave_index + 1,
			]
			_expect(wave_config.resource_path == expected_path, "Wave path mismatch: %s" % wave_config.resource_path)
			_expect(not seen_wave_paths.has(wave_config.resource_path), "Wave paths must be unique across campaigns.")
			seen_wave_paths[wave_config.resource_path] = true
			_expect(not seen_wave_instances.has(wave_config), "Wave instances must not be shared across campaigns.")
			seen_wave_instances.append(wave_config)
			_expect(
				wave_config.spawn_point_mask == int(definition["spawn_point_mask"]),
				"Wave spawn mask mismatch: %s" % wave_config.resource_path
			)
			_expect(
				wave_config.step_id == StringName("wave_%02d" % (wave_index + 1)),
				"Wave step id mismatch: %s" % wave_config.resource_path
			)
			if is_tower_defense:
				_verify_tower_defense_stress_wave(wave_config, wave_index)
			elif (
				definition["campaign_id"] == &"standard_singleplayer"
				and wave_index == 0
			):
				_verify_standard_singleplayer_stone_golem_test_wave(
					wave_config,
					source_wave
				)
			else:
				_expect(
					_wave_content_matches_source(wave_config, source_wave),
					"Campaign wave content differs from its source snapshot: %s"
					% wave_config.resource_path
				)
			var spawn_names := wave_config.get_enabled_spawn_point_names()
			var expected_spawn_count := 6 if int(definition["spawn_point_mask"]) == 63 else 5
			_expect(spawn_names.size() == expected_spawn_count, "Enabled spawn-point list mismatch.")
			_expect(
				spawn_names.has(&"Spawn6") == (expected_spawn_count == 6),
				"Spawn6 availability must match the campaign mode."
			)

	_expect(seen_campaigns.size() == 4, "Exactly four independent Campaign resources are required.")
	_expect(seen_flow_graphs.size() == 4, "Exactly four independent flow graphs are required.")
	_expect(seen_wave_instances.size() == 48, "Exactly 48 independent WaveConfig instances are required.")
	_expect(seen_wave_paths.size() == 48, "Exactly 48 independent WaveConfig paths are required.")


func _test_campaign_validation() -> void:
	var missing_graph := WAVE_CAMPAIGN_CONFIG_SCRIPT.new() as Resource
	missing_graph.set("campaign_id", &"missing_graph")
	_expect(
		_has_error_containing(missing_graph.call("validate_campaign"), "FlowGraphConfig"),
		"Campaign validation must reject a missing flow graph."
	)
	var invalid_wave := WaveConfig.new()
	invalid_wave.step_id = &"invalid_wave"
	invalid_wave.spawn_point_mask = 0
	var invalid_graph := FlowGraphConfig.new()
	invalid_graph.start_step = invalid_wave
	invalid_graph.steps = [invalid_wave]
	var invalid_campaign := WAVE_CAMPAIGN_CONFIG_SCRIPT.new() as Resource
	invalid_campaign.set("campaign_id", &"invalid_mask")
	invalid_campaign.set("flow_graph", invalid_graph)
	_expect(
		_has_error_containing(invalid_campaign.call("validate_campaign"), "没有启用出生点"),
		"Campaign validation must reject an empty spawn-point mask."
	)


func _test_runtime_campaign_selection() -> void:
	var cases := [
		{
			"scene": STANDARD_GAME_SCENE,
			"runtime_mode": GameRuntimeBase.RuntimeMode.SINGLEPLAYER,
			"campaign_id": &"standard_singleplayer",
			"tower_defense": false,
		},
		{
			"scene": STANDARD_GAME_SCENE,
			"runtime_mode": GameRuntimeBase.RuntimeMode.HOST_AUTHORITY,
			"campaign_id": &"standard_multiplayer",
			"tower_defense": false,
		},
		{
			"scene": TOWER_DEFENSE_GAME_SCENE,
			"runtime_mode": GameRuntimeBase.RuntimeMode.SINGLEPLAYER,
			"campaign_id": &"tower_defense_singleplayer",
			"tower_defense": true,
		},
		{
			"scene": TOWER_DEFENSE_GAME_SCENE,
			"runtime_mode": GameRuntimeBase.RuntimeMode.HOST_AUTHORITY,
			"campaign_id": &"tower_defense_multiplayer",
			"tower_defense": true,
		},
	]
	for test_case in cases:
		var game := (test_case["scene"] as PackedScene).instantiate() as GameRuntimeBase
		_expect(game != null, "Runtime campaign probe scene must instantiate.")
		if game == null:
			continue
		game.runtime_mode = int(test_case["runtime_mode"])
		_expect(
			bool(game.call("_configure_active_campaign")),
			"Runtime must configure Campaign %s." % String(test_case["campaign_id"])
		)
		var active_campaign := game.get("active_campaign") as Resource
		_expect(
			active_campaign != null
			and active_campaign.get("campaign_id") == test_case["campaign_id"],
			"Runtime selected the wrong Campaign for %s." % String(test_case["campaign_id"])
		)
		if bool(test_case["tower_defense"]):
			_expect(
				(game as GameTowerDefense).bosses.is_empty(),
				"Tower-defense runtime must not expose a Boss step."
			)
		game.free()


func _test_boss_mode_separation() -> void:
	var standard_boss := load(
		"res://resources/config/bosses/boss_01_linglan.tres"
	) as BossConfig
	_expect(standard_boss != null, "Standard-mode Linglan BossConfig must continue to load.")
	if standard_boss == null:
		return
	_expect(
		standard_boss.arena_floor_rect == Rect2i(-3, -1, 22, 18),
		"Standard mode must retain its original small-map boss arena."
	)

	var game := TOWER_DEFENSE_GAME_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense Boss exclusion probe must instantiate.")
	if game == null:
		return
	_expect(not game.linglan_boss_enabled, "Tower-defense Linglan must stay disabled by default.")
	game.free()


func _verify_tower_defense_stress_wave(
	wave_config: WaveConfig,
	wave_index: int
) -> void:
	_expect(
		wave_config.get_total_enemy_count() == TOWER_DEFENSE_STRESS_TOTAL_ENEMIES,
		"Every tower-defense pressure wave must contain exactly 1200 enemies: %s"
		% wave_config.resource_path
	)
	_expect(
		wave_config.max_alive_enemies == TOWER_DEFENSE_STRESS_MAX_ALIVE,
		"Tower-defense maximum simultaneous enemies must be 300."
	)
	_expect(
		is_equal_approx(wave_config.spawn_interval, TOWER_DEFENSE_STRESS_SPAWN_INTERVAL)
		and wave_config.spawn_count_per_tick == TOWER_DEFENSE_STRESS_SPAWN_COUNT_PER_TICK,
		"Tower-defense pressure waves must spawn four enemies every 0.1 seconds."
	)
	if wave_index < 8:
		_expect(
			_resource_path(wave_config.music) == TOWER_DEFENSE_FOREST_COMBAT_BGM,
			"Tower-defense waves 1-8 must use the forest combat BGM: %s"
			% wave_config.resource_path
		)
		_expect(
			_resource_path(wave_config.post_wave_music)
			== TOWER_DEFENSE_FOREST_INTERMISSION_BGM,
			"Tower-defense rests through wave 8 must use the forest pre-combat BGM: %s"
			% wave_config.resource_path
		)
	if wave_index < 11:
		_expect(
			wave_config.exits.size() == 1
			and wave_config.exits[0].get_target_step_id()
			== StringName("wave_%02d" % (wave_index + 2)),
			"Tower-defense wave must advance to the next wave."
		)
	else:
		_expect(
			wave_config.exits.is_empty(),
			"Tower-defense wave 12 must finish the campaign without Linglan."
		)

	if wave_index != 0:
		return
	_expect(
		wave_config.enemy_entries.size() == FIRST_WAVE_EXPECTED_COUNTS.size(),
		"Tower-defense first wave must contain exactly three enemy types."
	)
	var actual_counts := {}
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config != null:
			actual_counts[entry.enemy_config.resource_path] = entry.count
	_expect(
		actual_counts == FIRST_WAVE_EXPECTED_COUNTS,
		"First pressure wave must be 850 basic, 320 shell, and 30 AK Capoo."
	)


func _verify_standard_singleplayer_stone_golem_test_wave(
	wave_config: WaveConfig,
	source_wave: WaveConfig
) -> void:
	_expect(
		wave_config.enemy_entries.size() == 1
		and wave_config.get_total_enemy_count() == 1,
		"Standard singleplayer wave 1 must contain exactly one enemy."
	)
	if wave_config.enemy_entries.size() == 1:
		var entry := wave_config.enemy_entries[0]
		_expect(
			entry != null
			and entry.count == 1
			and _resource_path(entry.enemy_config) == STONE_GOLEM_CONFIG_PATH,
			"Standard singleplayer wave 1 must contain only one stone golem."
		)
	_expect(
		wave_config.max_alive_enemies == 1,
		"Standard singleplayer stone-golem test wave must cap alive enemies at one."
	)
	_expect(
		wave_config.wave_name == "第1波 石头人测试"
		and wave_config.display_name == "第1波 石头人测试",
		"Standard singleplayer stone-golem test wave must use its explicit test label."
	)
	_expect(
		source_wave != null
		and wave_config.step_id == source_wave.step_id
		and is_equal_approx(wave_config.spawn_interval, source_wave.spawn_interval)
		and wave_config.spawn_count_per_tick == source_wave.spawn_count_per_tick
		and is_equal_approx(
			wave_config.post_clear_rest_duration,
			source_wave.post_clear_rest_duration
		)
		and _resource_path(wave_config.music) == _resource_path(source_wave.music)
		and _resource_path(wave_config.post_wave_music)
		== _resource_path(source_wave.post_wave_music)
		and wave_config.exits.size() == source_wave.exits.size(),
		"Standard singleplayer stone-golem test wave must preserve its flow and audio."
	)
	if source_wave != null and wave_config.exits.size() == source_wave.exits.size():
		for exit_index in range(wave_config.exits.size()):
			var campaign_exit := wave_config.exits[exit_index]
			var source_exit := source_wave.exits[exit_index]
			_expect(
				campaign_exit != null
				and source_exit != null
				and campaign_exit.exit_name == source_exit.exit_name
				and campaign_exit.get_target_step_id()
				== source_exit.get_target_step_id(),
				"Standard singleplayer stone-golem test wave must preserve its exit."
			)


func _wave_content_matches_source(wave_config: WaveConfig, source_wave: WaveConfig) -> bool:
	if wave_config == null or source_wave == null:
		return false
	if (
		wave_config.wave_name != source_wave.wave_name
		or wave_config.step_id != source_wave.step_id
		or wave_config.display_name != source_wave.display_name
		or not is_equal_approx(wave_config.spawn_interval, source_wave.spawn_interval)
		or wave_config.spawn_count_per_tick != source_wave.spawn_count_per_tick
		or wave_config.max_alive_enemies != source_wave.max_alive_enemies
		or not is_equal_approx(
			wave_config.post_clear_rest_duration,
			source_wave.post_clear_rest_duration
		)
		or _resource_path(wave_config.music) != _resource_path(source_wave.music)
		or _resource_path(wave_config.post_wave_music) != _resource_path(source_wave.post_wave_music)
		or wave_config.enemy_entries.size() != source_wave.enemy_entries.size()
		or wave_config.exits.size() != source_wave.exits.size()
	):
		return false
	for entry_index in range(wave_config.enemy_entries.size()):
		var campaign_entry := wave_config.enemy_entries[entry_index]
		var source_entry := source_wave.enemy_entries[entry_index]
		if campaign_entry == null or source_entry == null:
			return campaign_entry == source_entry
		if (
			campaign_entry.count != source_entry.count
			or _resource_path(campaign_entry.enemy_config) != _resource_path(source_entry.enemy_config)
		):
			return false
	for exit_index in range(wave_config.exits.size()):
		var campaign_exit := wave_config.exits[exit_index]
		var source_exit := source_wave.exits[exit_index]
		if campaign_exit == null or source_exit == null:
			return campaign_exit == source_exit
		if (
			campaign_exit.exit_name != source_exit.exit_name
			or campaign_exit.get_target_step_id() != source_exit.get_target_step_id()
		):
			return false
	return true


func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
