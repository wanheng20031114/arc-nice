extends SceneTree

const WAVE_CAMPAIGN_CONFIG_SCRIPT := preload(
	"res://resources/config/waves/wave_campaign_config.gd"
)
const WAVE_CONTENT_CONTRACT := preload(
	"res://dev_tools/wave_campaign_content_contract.gd"
)
const STANDARD_GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const TOWER_DEFENSE_GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const FORMAL_TOTALS: Array[int] = [
	3000, 3850, 3470, 2080, 2100, 2240, 2150, 2240, 3120, 3780, 3000, 4900,
]
const FORMAL_MAX_ALIVE: Array[int] = [
	200, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300,
]
const FORMAL_SPAWN_POINT_MASKS: Array[int] = [
	15, 15, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
]
const PERFORMANCE_TOTAL := 1200
const PERFORMANCE_MAX_ALIVE := 300
const STANDARD_SOURCE_WAVE_PATTERN := "res://resources/config/waves/wave_%02d.tres"
const STANDARD_AUDIO_TEST_FIXTURE := (
	"res://dev_tools/fixtures/waves/standard_wave_01_audio_stress_test.tres"
)

const CAMPAIGN_DEFINITIONS := [
	{
		"path": "res://resources/config/campaigns/standard/singleplayer/campaign.tres",
		"campaign_id": &"standard_singleplayer",
		"flow_path": "res://resources/config/campaigns/standard/singleplayer/flow.tres",
		"kind": &"standard",
		"boss_count": 1,
	},
	{
		"path": "res://resources/config/campaigns/standard/multiplayer/campaign.tres",
		"campaign_id": &"standard_multiplayer",
		"flow_path": "res://resources/config/campaigns/standard/multiplayer/flow.tres",
		"kind": &"standard",
		"boss_count": 1,
	},
	{
		"path": "res://resources/config/campaigns/tower_defense/singleplayer/campaign.tres",
		"campaign_id": &"tower_defense_singleplayer",
		"flow_path": "res://resources/config/campaigns/tower_defense/singleplayer/flow.tres",
		"kind": &"formal",
		"boss_count": 1,
	},
	{
		"path": "res://resources/config/campaigns/tower_defense/multiplayer/campaign.tres",
		"campaign_id": &"tower_defense_multiplayer",
		"flow_path": "res://resources/config/campaigns/tower_defense/multiplayer/flow.tres",
		"kind": &"formal",
		"boss_count": 1,
	},
	{
		"path": "res://resources/config/campaigns/tower_defense/performance/campaign.tres",
		"campaign_id": &"tower_defense_performance",
		"flow_path": "res://resources/config/campaigns/tower_defense/performance/flow.tres",
		"kind": &"performance",
		"boss_count": 0,
	},
]

var failures: Array[String] = []


func _init() -> void:
	_test_campaign_resources()
	_test_standard_content_closure()
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
	var formal_wave_paths: PackedStringArray = []
	for definition in CAMPAIGN_DEFINITIONS:
		var campaign := load(String(definition["path"])) as WaveCampaignConfig
		_expect(campaign != null, "Campaign must load: %s" % definition["path"])
		if campaign == null:
			continue
		_expect(
			campaign.campaign_id == definition["campaign_id"],
			"Campaign id mismatch: %s" % campaign.resource_path
		)
		_expect(
			campaign.validate_campaign().is_empty(),
			"Campaign must validate: %s" % campaign.resource_path
		)
		var graph := campaign.flow_graph
		_expect(graph != null, "Campaign must provide a flow graph.")
		if graph == null:
			continue
		_expect(
			graph.resource_path == definition["flow_path"],
			"Campaign uses the wrong flow resource: %s" % graph.resource_path
		)
		var waves := campaign.get_waves()
		_expect(waves.size() == 12, "Campaign must contain 12 waves.")
		var campaign_bosses := campaign.get_bosses()
		_expect(
			campaign_bosses.size() == int(definition["boss_count"]),
			"Campaign boss count mismatch: %s" % campaign.resource_path
		)
		for campaign_boss in campaign_bosses:
			var boss_enemy_config := campaign_boss.get_enemy_config()
			_expect(
				boss_enemy_config != null and boss_enemy_config.is_boss,
				"Every BossConfig must resolve an EnemyConfig marked as Boss: %s"
				% campaign_boss.resource_path
			)
		if int(definition["boss_count"]) == 1 and campaign_bosses.size() == 1:
			var linglan_boss := campaign_bosses[0]
			var linglan_enemy_config := linglan_boss.get_enemy_config()
			_expect(
				linglan_boss.step_id == &"boss_01_linglan"
				and linglan_enemy_config != null
				and linglan_enemy_config.resource_path
				== "res://resources/config/enemies/linglan_boss.tres",
				"Campaign Boss step must resolve the authored Linglan enemy config."
			)
		if waves.size() != 12:
			continue
		_expect(graph.start_step == waves[0], "Flow must start from wave 1.")
		match StringName(definition["kind"]):
			&"formal":
				_verify_formal_waves(waves)
				var paths := PackedStringArray()
				for wave in waves:
					paths.append(wave.resource_path)
				if formal_wave_paths.is_empty():
					formal_wave_paths = paths
				else:
					_expect(
						paths == formal_wave_paths,
						"Singleplayer and multiplayer must share the formal wave baseline."
					)
			&"performance":
				_verify_performance_waves(waves)
			&"standard":
				_verify_standard_waves(waves)


func _verify_formal_waves(waves: Array[WaveConfig]) -> void:
	_expect(
		is_equal_approx(waves[0].spawn_interval, 0.25),
		"Formal first wave must spawn one enemy batch every 0.25 seconds."
	)
	for wave_index in waves.size():
		var wave := waves[wave_index]
		var expected_path := (
			"res://resources/config/campaigns/tower_defense/formal/wave_%02d.tres"
			% (wave_index + 1)
		)
		_expect(wave.resource_path == expected_path, "Formal wave path mismatch.")
		_expect(
			wave.get_total_enemy_count() == FORMAL_TOTALS[wave_index],
			"Formal wave %d enemy total mismatch." % (wave_index + 1)
		)
		_expect(
			wave.max_alive_enemies == FORMAL_MAX_ALIVE[wave_index],
			"Formal wave %d max-alive mismatch." % (wave_index + 1)
		)
		_expect(
			wave.spawn_point_mask == FORMAL_SPAWN_POINT_MASKS[wave_index],
			"Formal wave %d spawn-point mask mismatch." % (wave_index + 1)
		)
		_expect(
			wave.post_clear_rest_duration == 0.0,
			"Formal waves must not carry a second rest-duration source."
		)
		_expect(
			not wave.wave_name.contains("压力测试")
			and not wave.display_name.contains("压力测试"),
			"Formal campaign must not expose pressure-test labels."
		)
		_verify_linear_exit(wave, wave_index, &"boss_01_linglan")


func _verify_performance_waves(waves: Array[WaveConfig]) -> void:
	for wave_index in waves.size():
		var wave := waves[wave_index]
		_expect(
			wave.resource_path == (
				"res://resources/config/campaigns/tower_defense/performance/waves/wave_%02d.tres"
				% (wave_index + 1)
			),
			"Performance wave must live only in the performance campaign."
		)
		_expect(
			wave.get_total_enemy_count() == PERFORMANCE_TOTAL,
			"Every performance wave must retain exactly 1200 enemies."
		)
		_expect(
			wave.max_alive_enemies == PERFORMANCE_MAX_ALIVE,
			"Performance waves must retain the 300-enemy ceiling."
		)
		_verify_linear_exit(wave, wave_index, &"")
	_expect(
		waves[0].wave_name == "第1波 虫潮压力测试",
		"The pressure-test label must remain explicit in the performance campaign."
	)


func _verify_standard_waves(waves: Array[WaveConfig]) -> void:
	for wave in waves:
		_expect(
			wave.spawn_point_mask == WaveConfig.STANDARD_SPAWN_POINT_MASK,
			"Standard campaigns must retain their five-point spawn contract."
		)
		_expect(
			not WAVE_CONTENT_CONTRACT.has_test_label(wave),
			"Formal Standard waves must not expose test labels: %s" % wave.resource_path
		)


func _test_standard_content_closure() -> void:
	var singleplayer := load(
		"res://resources/config/campaigns/standard/singleplayer/campaign.tres"
	) as WaveCampaignConfig
	var multiplayer := load(
		"res://resources/config/campaigns/standard/multiplayer/campaign.tres"
	) as WaveCampaignConfig
	_expect(singleplayer != null and multiplayer != null, "Standard campaigns must load.")
	if singleplayer == null or multiplayer == null:
		return
	var singleplayer_waves := singleplayer.get_waves()
	var multiplayer_waves := multiplayer.get_waves()
	_expect(
		singleplayer_waves.size() == 12 and multiplayer_waves.size() == 12,
		"Standard content closure requires two complete 12-wave snapshots."
	)
	if singleplayer_waves.size() != 12 or multiplayer_waves.size() != 12:
		return

	# 标准单人与多人共享同一套正式源，快照不得各自漂移。
	for wave_index in range(12):
		var source_wave := load(
			STANDARD_SOURCE_WAVE_PATTERN % (wave_index + 1)
		) as WaveConfig
		_expect(source_wave != null, "Standard source wave must load.")
		if source_wave == null:
			continue
		var expected_signature := WAVE_CONTENT_CONTRACT.get_wave_signature(source_wave)
		_expect(
			WAVE_CONTENT_CONTRACT.get_wave_signature(singleplayer_waves[wave_index])
			== expected_signature,
			"Singleplayer wave snapshot drifted from source: %02d" % (wave_index + 1)
		)
		_expect(
			WAVE_CONTENT_CONTRACT.get_wave_signature(multiplayer_waves[wave_index])
			== expected_signature,
			"Multiplayer wave snapshot drifted from source: %02d" % (wave_index + 1)
		)

	var first_wave := singleplayer_waves[0]
	_expect(
		first_wave.enemy_entries.size() == 1
		and first_wave.enemy_entries[0] != null
		and first_wave.enemy_entries[0].enemy_config != null
		and first_wave.enemy_entries[0].enemy_config.resource_path
		== "res://resources/config/enemies/slime.tres"
		and first_wave.enemy_entries[0].count == 1
		and first_wave.max_alive_enemies == 1,
		"The formal Standard opening wave must be the authored one-slime wave."
	)

	var audio_test_fixture := load(STANDARD_AUDIO_TEST_FIXTURE) as WaveConfig
	_expect(audio_test_fixture != null, "The retired audio-stress content must remain a fixture.")
	if audio_test_fixture != null:
		_expect(
			audio_test_fixture.wave_name.contains("测试")
			and audio_test_fixture.step_id == &"wave_01_audio_stress_test"
			and audio_test_fixture.get_total_enemy_count() == 50,
			"The audio-stress fixture must remain explicit and isolated."
		)


func _verify_linear_exit(
	wave: WaveConfig,
	wave_index: int,
	final_target_step_id: StringName
) -> void:
	_expect(
		wave.step_id == StringName("wave_%02d" % (wave_index + 1)),
		"Wave step id mismatch: %s" % wave.resource_path
	)
	if wave_index < 11:
		_expect(
			wave.exits.size() == 1
			and wave.exits[0].get_target_step_id()
			== StringName("wave_%02d" % (wave_index + 2)),
			"Wave must advance linearly: %s" % wave.resource_path
		)
	elif final_target_step_id == &"":
		_expect(wave.exits.is_empty(), "Wave 12 must terminate the campaign.")
	else:
		_expect(
			wave.exits.size() == 1
			and wave.exits[0].get_target_step_id() == final_target_step_id,
			"Wave 12 must advance to %s: %s"
			% [final_target_step_id, wave.resource_path]
		)


func _test_campaign_validation() -> void:
	var missing_graph := WAVE_CAMPAIGN_CONFIG_SCRIPT.new() as WaveCampaignConfig
	missing_graph.campaign_id = &"missing_graph"
	_expect(
		_has_error_containing(missing_graph.validate_campaign(), "FlowGraphConfig"),
		"Campaign validation must reject a missing flow graph."
	)
	var invalid_wave := WaveConfig.new()
	invalid_wave.step_id = &"invalid_wave"
	invalid_wave.spawn_point_mask = 0
	var invalid_graph := FlowGraphConfig.new()
	invalid_graph.start_step = invalid_wave
	invalid_graph.steps = [invalid_wave]
	var invalid_campaign := WAVE_CAMPAIGN_CONFIG_SCRIPT.new() as WaveCampaignConfig
	invalid_campaign.campaign_id = &"invalid_mask"
	invalid_campaign.flow_graph = invalid_graph
	_expect(
		_has_error_containing(invalid_campaign.validate_campaign(), "没有启用出生点"),
		"Campaign validation must reject an empty spawn-point mask."
	)


func _test_runtime_campaign_selection() -> void:
	var cases := [
		[STANDARD_GAME_SCENE, CombatRuntimeBase.RuntimeMode.SINGLEPLAYER, &"standard_singleplayer"],
		[STANDARD_GAME_SCENE, CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY, &"standard_multiplayer"],
		[TOWER_DEFENSE_GAME_SCENE, CombatRuntimeBase.RuntimeMode.SINGLEPLAYER, &"tower_defense_singleplayer"],
		[TOWER_DEFENSE_GAME_SCENE, CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY, &"tower_defense_multiplayer"],
	]
	for test_case in cases:
		var game := (test_case[0] as PackedScene).instantiate() as CombatRuntimeBase
		_expect(game != null, "Runtime campaign probe must instantiate.")
		if game == null:
			continue
		game.runtime_mode = int(test_case[1])
		var tower_game := game as TowerDefenseGame
		var tower_campaign_coordinator: TowerDefenseCampaignCoordinator = null
		if tower_game != null:
			tower_campaign_coordinator = tower_game.get_node_or_null(
				"CampaignCoordinator"
			) as TowerDefenseCampaignCoordinator
			_expect(
				tower_campaign_coordinator != null,
				"Tower-defense runtime probe must expose its authored CampaignCoordinator."
			)
			if tower_campaign_coordinator == null:
				game.free()
				continue
			tower_game.campaign_coordinator = tower_campaign_coordinator
		_expect(
			bool(game.call("_configure_active_campaign")),
			"Runtime must configure Campaign %s." % String(test_case[2])
		)
		var campaign: WaveCampaignConfig = null
		if tower_campaign_coordinator != null:
			campaign = tower_campaign_coordinator.active_campaign
		else:
			campaign = game.get("active_campaign") as WaveCampaignConfig
		_expect(
			campaign != null and campaign.campaign_id == test_case[2],
			"Runtime selected the wrong campaign."
		)
		game.free()


func _test_boss_mode_separation() -> void:
	var standard_boss := load(
		"res://resources/config/bosses/boss_01_linglan.tres"
	) as BossConfig
	_expect(standard_boss != null, "Standard Linglan BossConfig must continue to load.")
	var game := TOWER_DEFENSE_GAME_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Tower-defense boss integration probe must instantiate.")
	if game != null:
		_expect(game.linglan_boss_enabled, "Tower-defense Linglan must be enabled by the authored scene.")
		game.free()


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
