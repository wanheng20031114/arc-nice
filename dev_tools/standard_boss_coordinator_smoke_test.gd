extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const EXPECTED_BOSS_ENTRY := preload(
	"res://resources/config/bosses/boss_01_linglan.tres"
)
const EXPECTED_ENEMY_CONFIG_PATH := (
	"res://resources/config/enemies/linglan_boss.tres"
)
const EXPECTED_INTRO_PATH := (
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn"
)
const EXPECTED_HUD_PATH := (
	"res://scene/boss/linglan/boss_health_hud.tscn"
)
const EXPECTED_SKILL2 := preload(
	"res://resources/config/bosses/linglan_skill2.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate.")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	await physics_frame

	var coordinator := game.get_node_or_null(
		"BossCoordinator"
	) as StandardBossCoordinator
	var runtime_port := game.get_node_or_null(
		"LinglanBossRuntimePort"
	) as StandardLinglanBossRuntimePort
	_expect(
		coordinator != null
		and coordinator.get_parent() == game
		and coordinator.runtime == game
		and coordinator.boss_container == game.boss_container
		and coordinator.runtime_port == runtime_port
		and coordinator.is_bound(),
		"Standard Boss coordinator must be statically mounted with explicit dependencies."
	)
	_expect(
		runtime_port != null
		and runtime_port.boss_coordinator == coordinator
		and runtime_port.combat_runtime == game,
		"Standard Linglan port must target the coordinator without a concrete root back-reference."
	)
	_expect(
		coordinator.configured_bosses.size() == 1
		and coordinator.get_first_boss_config() == EXPECTED_BOSS_ENTRY
		and game.bosses[0] == EXPECTED_BOSS_ENTRY,
		"Campaign, Boss coordinator and root façade must share one authored Boss table."
	)
	var original_flow_graph := game.flow_graph
	var fixture_boss := BossConfig.new()
	fixture_boss.step_id = &"fixture_boss_distinct_from_campaign"
	fixture_boss.boss_name = "Fixture Boss"
	fixture_boss.enemy_config = EXPECTED_BOSS_ENTRY.get_enemy_config()
	var fixture_flow_graph := FlowGraphConfig.new()
	fixture_flow_graph.start_step = fixture_boss
	var fixture_steps: Array[FlowStepConfig] = [fixture_boss]
	fixture_flow_graph.steps = fixture_steps
	game.flow_graph = fixture_flow_graph
	_expect(
		coordinator.configured_bosses.size() == 1
		and coordinator.get_first_boss_config() == fixture_boss
		and game.bosses.size() == 1
		and game.bosses[0] == EXPECTED_BOSS_ENTRY,
		"Runtime fixture flow_graph must override effective Boss lookup while preserving the raw Campaign façade."
	)
	game.flow_graph = original_flow_graph
	var appended_raw_boss := BossConfig.new()
	appended_raw_boss.step_id = &"raw_append_compatibility"
	game.bosses.append(appended_raw_boss)
	_expect(
		game.bosses.size() == 2
		and game.bosses[1] == appended_raw_boss
		and game.campaign_wave_coordinator.bosses[1] == appended_raw_boss,
		"Root bosses façade append must keep mutating the raw Campaign Boss array."
	)
	game.bosses.pop_back()
	_expect(
		coordinator.get_boss_enemy_config_path(EXPECTED_BOSS_ENTRY)
			== EXPECTED_ENEMY_CONFIG_PATH
		and coordinator.get_boss_intro_vfx_scene_path(EXPECTED_BOSS_ENTRY)
			== EXPECTED_INTRO_PATH
		and coordinator.get_boss_hud_scene_path(EXPECTED_BOSS_ENTRY)
			== EXPECTED_HUD_PATH
		and coordinator.get_boss_arena_center(EXPECTED_BOSS_ENTRY)
			== Vector2(128.0, 128.0)
		and coordinator.get_boss_arena_floor_rect(EXPECTED_BOSS_ENTRY)
			== Rect2i(Vector2i(-3, -1), Vector2i(22, 18)),
		"Authored Linglan spawn, arena and presentation paths must remain fixed."
	)
	_expect(
		game.get_node_or_null("BossContainer/LinglanBoss") == null
		and game.get_node_or_null("LinglanBossIntroVFX") == null
		and game.get_node_or_null("BossHealthHUD") == null,
		"Boss runtime art must remain lazy and retain its authored root NodePaths."
	)
	coordinator.active_boss_config = EXPECTED_BOSS_ENTRY
	game.random_generator.seed = 0xB055
	var first_airdrop_position := coordinator.call(
		"_get_random_arena_position"
	) as Vector2
	var second_airdrop_position := coordinator.call(
		"_get_random_arena_position"
	) as Vector2
	game.random_generator.seed = 0xB055
	var replay_first_position := coordinator.call(
		"_get_random_arena_position"
	) as Vector2
	var replay_second_position := coordinator.call(
		"_get_random_arena_position"
	) as Vector2
	_expect(
		first_airdrop_position == Vector2(25.0, 24.0)
		and second_airdrop_position == Vector2(121.0, 88.0)
		and replay_first_position == first_airdrop_position
		and replay_second_position == second_airdrop_position,
		"Fixed-seed Linglan airdrop sampling order or arena mapping changed."
	)
	var enemy_children_before := game.enemy_container.get_child_count()
	game.spawn_linglan_skill2_enemies(
		EXPECTED_SKILL2.spawn_enemy_config,
		EXPECTED_SKILL2.spawn_marker_names
	)
	await process_frame
	_expect(
		game.enemy_container.get_child_count() == enemy_children_before + 2,
		"Standard Boss skill2 façade must still spawn one add at Spawn4 and Spawn5."
	)
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	_expect(
		coordinator.apply_remote_state(
			CombatFlowState.State.BOSS_INTRO,
			EXPECTED_BOSS_ENTRY
		),
		"Remote Linglan intro must remain handled by the Boss coordinator."
	)
	var remote_intro := game.get_node_or_null(
		"LinglanBossIntroVFX"
	) as LinglanBossIntroVFX
	_expect(
		remote_intro != null
		and game.wave_state == CombatFlowState.State.BOSS_INTRO,
		"Remote intro must preserve the authored root VFX path and flow state."
	)
	if remote_intro != null:
		remote_intro.intro_finished.emit()
	await process_frame
	_expect(
		game.wave_state == CombatFlowState.State.BOSS_INTRO
		and game.get_node_or_null("BossContainer/LinglanBoss") == null,
		"Client intro completion must not activate or spawn an authoritative Boss."
	)

	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/boss/standard_boss_coordinator.gd"
	)
	var port_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/boss/standard_linglan_boss_runtime_port.gd"
	)
	_expect(
		not coordinator_source.contains("StandardGame")
		and not coordinator_source.contains("MultiplayerModeAdapter")
		and not coordinator_source.contains("MusicPlayer")
		and not coordinator_source.contains("get_tree().current_scene")
		and not port_source.contains("var game: StandardGame"),
		"Boss boundary must not restore concrete root, multiplayer, music or current-scene discovery."
	)

	_stop_audio_players(game)
	game.queue_free()
	for _cleanup_frame in range(5):
		await process_frame
		await physics_frame
	_finish()


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		var audio_player := child as AudioStreamPlayer
		if audio_player != null:
			audio_player.stop()
			audio_player.stream = null
		var audio_player_2d := child as AudioStreamPlayer2D
		if audio_player_2d != null:
			audio_player_2d.stop()
			audio_player_2d.stream = null
		_stop_audio_players(child)


func _finish() -> void:
	if failures.is_empty():
		print("STANDARD_BOSS_COORDINATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
