extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const FIXED_SEED := 0x71A4
const EXPECTED_FIXED_SEED_QUEUE_HASH := (
	"caffc615d4ef65f9d705aee80e7a84099c75346bf7df5e163b3c23f64aa3eabd"
)
const FIRST_ZONE_MUSIC := (
	"res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3"
)
const FOREST_COMBAT_MUSIC := "res://resources/audio/shenmu_forest_combat.ogg"
const FOREST_INTERMISSION_MUSIC := (
	"res://resources/audio/shenmu_forest_intermission.ogg"
)
const SWAMP_COMBAT_MUSIC := "res://resources/audio/shenmu_swamp_combat.ogg"
const SWAMP_INTERMISSION_MUSIC := (
	"res://resources/audio/shenmu_swamp_intermission.ogg"
)
const TOWN_COMBAT_MUSIC := "res://resources/audio/shenmu_town_combat.ogg"
const TOWN_INTERMISSION_MUSIC := (
	"res://resources/audio/shenmu_town_intermission.ogg"
)
const BOSS_MUSIC := "res://resources/audio/BGM_The_Truth_Never_Spoken.mp3"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_multiplayer_campaign_before_tree()
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
		"CampaignWaveCoordinator"
	) as StandardCampaignWaveCoordinator
	_expect(
		coordinator != null
		and coordinator.wave_hud == game.wave_hud
		and coordinator.countdown_audio == game.countdown_audio
		and coordinator.wave_start_audio == game.wave_start_audio,
		"StandardGame must bind explicit presentation dependencies to its static coordinator."
	)
	_expect(
		game.active_campaign != null
		and game.active_campaign.campaign_id == &"standard_singleplayer",
		"Single-player StandardGame must retain its authored Campaign."
	)
	_verify_campaign_contract(game, coordinator)
	_verify_fixed_seed_queue(game)
	_verify_flow_terminal_and_music(game, coordinator)

	_stop_audio_players(game)
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	_finish()


func _test_multiplayer_campaign_before_tree() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "Multiplayer StandardGame fixture must instantiate.")
	if game == null:
		return
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host", 2: "Client"}
	)
	_expect(
		game.call("_configure_active_campaign"),
		"Pre-tree multiplayer Campaign configuration must succeed."
	)
	var coordinator := game.get_node_or_null(
		"CampaignWaveCoordinator"
	) as StandardCampaignWaveCoordinator
	_expect(
		game.active_campaign != null
		and game.active_campaign.campaign_id == &"standard_multiplayer",
		"Pre-tree multiplayer configuration must retain the multiplayer Campaign."
	)
	_expect(
		coordinator != null
		and coordinator.flow_graph == game.flow_graph
		and coordinator.bosses.size() == 1,
		"Pre-tree Campaign configuration must initialize the typed Boss table."
	)
	game.free()


func _verify_campaign_contract(
	game: StandardGame,
	coordinator: StandardCampaignWaveCoordinator
) -> void:
	_expect(game.waves.size() == 12, "Standard Campaign must retain twelve waves.")
	_expect(
		coordinator != null
		and coordinator.bosses.size() == 1
		and game.bosses.size() == 1,
		"Coordinator and StandardGame façade must expose the same Boss table."
	)
	for wave_index in range(game.waves.size()):
		var wave := game.waves[wave_index]
		var wave_number := wave_index + 1
		_expect(
			wave.resource_path == (
				"res://resources/config/campaigns/standard/singleplayer/wave_%02d.tres"
				% wave_number
			),
			"Standard wave order/path changed at wave %02d." % wave_number
		)
		var expected_combat_music := FIRST_ZONE_MUSIC
		var expected_intermission_music := ""
		if wave_number >= 4 and wave_number <= 6:
			expected_combat_music = FOREST_COMBAT_MUSIC
			expected_intermission_music = FOREST_INTERMISSION_MUSIC
		elif wave_number >= 7 and wave_number <= 9:
			expected_combat_music = SWAMP_COMBAT_MUSIC
			expected_intermission_music = SWAMP_INTERMISSION_MUSIC
		elif wave_number >= 10:
			expected_combat_music = TOWN_COMBAT_MUSIC
			expected_intermission_music = TOWN_INTERMISSION_MUSIC
		_expect(
			_stream_path(wave.music) == expected_combat_music,
			"Standard combat BGM path changed at wave %02d." % wave_number
		)
		_expect(
			_stream_path(wave.post_wave_music) == expected_intermission_music,
			"Standard intermission BGM path changed at wave %02d." % wave_number
		)


func _verify_fixed_seed_queue(game: StandardGame) -> void:
	var wave := game.waves[11]
	game.random_generator.seed = FIXED_SEED
	game.call("_build_wave_spawn_queue", wave)
	var first_trace := _get_pending_queue_trace(game)
	var first_hash := "\n".join(first_trace).sha256_text()
	game.random_generator.seed = FIXED_SEED
	game.call("_build_wave_spawn_queue", wave)
	var second_trace := _get_pending_queue_trace(game)
	_expect(
		first_trace == second_trace,
		"Fixed-seed Standard wave queue must remain deterministic."
	)
	_expect(
		first_hash == EXPECTED_FIXED_SEED_QUEUE_HASH,
		"Fixed-seed Standard wave queue hash changed: %s" % first_hash
	)
	game.call("_clear_pending_enemy_spawn_queue")


func _get_pending_queue_trace(game: StandardGame) -> PackedStringArray:
	var trace := PackedStringArray()
	for queue_index in range(game.pending_enemy_configs.size()):
		var config := game.pending_enemy_configs[queue_index] as EnemyConfig
		trace.append(
			"%s|%d"
			% [
				config.resource_path if config != null else "<null>",
				game.pending_enemy_xirang_kill_rewards[queue_index],
			]
		)
	return trace


func _verify_flow_terminal_and_music(
	game: StandardGame,
	coordinator: StandardCampaignWaveCoordinator
) -> void:
	var final_wave := game.waves[11]
	var boss_config := game.call("_get_first_boss_config") as BossConfig
	_expect(
		boss_config != null
		and boss_config.step_id == &"boss_01_linglan"
		and game.call("_get_default_next_flow_step", final_wave) == boss_config,
		"Standard wave 12 must still advance to the authored Linglan Boss."
	)
	_expect(
		boss_config != null
		and game.call("_get_default_next_flow_step", boss_config) == null,
		"The authored Standard Boss must remain the terminal flow step."
	)
	_expect(
		boss_config != null and _stream_path(boss_config.music) == BOSS_MUSIC,
		"Standard Boss BGM path changed."
	)

	game.current_wave_index = 3
	game.call("_present_wave_started", game.waves[3], false)
	_expect(
		game.music_player.stream == game.waves[3].music,
		"Wave presentation façade must still select the wave combat BGM."
	)
	game.call("_present_intermission_started", game.waves[3])
	_expect(
		game.music_player.stream == game.waves[3].post_wave_music,
		"Intermission presentation façade must still select the cleared-wave BGM."
	)
	_expect(
		game.call(
			"_apply_remote_mode_flow_state",
			CombatFlowState.State.BOSS_ACTIVE,
			boss_config
		),
		"Remote Standard Boss flow must remain handled by the mode coordinator."
	)
	_expect(
		game.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and game.music_player.stream == boss_config.music,
		"Remote Boss flow must preserve state and Boss BGM."
	)
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.apply_remote_victory()
	_expect(
		game.wave_state == CombatFlowState.State.VICTORY,
		"Standard remote terminal flow must still enter victory."
	)


func _stream_path(stream: AudioStream) -> String:
	return stream.resource_path if stream != null else ""


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
		print("STANDARD_CAMPAIGN_WAVE_COORDINATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
