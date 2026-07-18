extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const TEST_PORT := 29279
const STANDARD_BOSS_RUNTIME_RESOURCE_PATHS: Array[String] = [
	"res://resources/config/enemies/linglan_boss.tres",
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn",
	"res://scene/boss/linglan/boss_health_hud.tscn",
]
const TOWER_DEFENSE_HIGH_FREQUENCY_RESOURCE_PATHS: Array[String] = [
	"res://resources/config/campaigns/tower_defense/singleplayer/wave_01.tres",
	"res://resources/config/enemies/yuanshi_insect_basic.tres",
	"res://resources/config/enemies/yuanshi_insect_shell.tres",
	"res://resources/config/enemies/capoo_ak47.tres",
	"res://scene/enemy/yuanshi_insect_basic.tscn",
	"res://scene/enemy/yuanshi_insect_shell.tscn",
	"res://scene/enemy/capoo_ak47.tscn",
	"res://scene/enemy/capoo_ak47_bullet.tscn",
	"res://scene/enemy/fire_sorcerer_fireball_volley.tscn",
	"res://scene/enemy/fire_sorcerer_elite_fireball_volley.tscn",
	"res://resources/animation/yuanshi_insect_basic.tres",
	"res://resources/animation/capoo_ak47.tres",
	"res://resources/audio/capoo_ak47_fire.wav",
	"res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3",
	"res://scene/bullet.tscn",
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn",
	"res://resources/audio/Cowboy_gunshot.wav",
	"res://resources/config/plant_defense/agave_cannon.tres",
	"res://scene/plant_defense/agave_cannon.tscn",
	"res://scene/plant_defense/agave_cannonball.tscn",
	"res://resources/config/plant_defense/bamboo_mortar.tres",
	"res://scene/plant_defense/bamboo_mortar.tscn",
	"res://scene/plant_defense/bamboo_mortar_shell.tscn",
	"res://resources/config/plant_defense/corn_machine_gun.tres",
	"res://scene/plant_defense/corn_machine_gun.tscn",
	"res://resources/config/plant_defense/oak_warehouse.tres",
	"res://scene/plant_defense/oak_warehouse.tscn",
	"res://resources/shader/plant_lifecycle.gdshader",
	"res://resources/shader/plant_lifecycle_material.tres",
	"res://resources/shader/plant_lifecycle_noise.tres",
	"res://scene/plant_defense/effects/plant_placement_particles.tscn",
	"res://scene/plant_defense/effects/plant_removal_smoke.tscn",
	"res://scene/enemy/yuanshi_insect_spawn_effect.tscn",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_loading_scene_contract()
	await _test_runtime_activation_gate()
	_test_mode_specific_mp_game_source()
	_test_host_ready_barrier()
	await _test_mp_game_preparation_barrier()
	await _test_singleplayer_coordinator_flow()
	await _cleanup_test_runtime()
	call_deferred("_finish")


func _cleanup_test_runtime() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	if coordinator != null:
		coordinator.set("_state", 0)
		coordinator.set_process(false)
		var overlay := coordinator.get_node_or_null("Overlay") as Control
		if overlay != null:
			overlay.hide()
	var runtime := current_scene
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame


func _test_loading_scene_contract() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	_expect(coordinator is CanvasLayer, "Loading coordinator must remain a persistent CanvasLayer.")
	if coordinator == null:
		return
	_expect(
		coordinator.get_node_or_null("Overlay/Layout/Stack/Content/RouteProgress") is ProgressBar,
		"Loading UI must expose its native progress bar."
	)
	_expect(
		coordinator.get_node_or_null("Overlay/Layout/Stack/Content/ActionRow/Back") is Button,
		"Loading errors must expose a native return action."
	)
	var manifest: Array[String] = []
	coordinator.call("_append_character_scene", manifest, &"weishidaier")
	_expect(
		manifest == ["res://scene/player/weishidaier/player_weishidaier.tscn"],
		"Loading manifest must include the selected player scene exactly once."
	)
	coordinator.call("_append_character_scene", manifest, &"weishidaier")
	_expect(manifest.size() == 1, "Loading manifest must deduplicate player scenes.")


func _test_runtime_activation_gate() -> void:
	var game := GAME_SCENE.instantiate() as GameRuntimeBase
	_expect(game != null, "Standard runtime must instantiate for activation-gate coverage.")
	if game == null:
		return
	game.configure_multiplayer(
		GameRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Loading Host"},
		{1: &"weishidaier"}
	)
	game.set("auto_start_waves", false)
	game.defer_runtime_activation()
	_expect(
		game.runtime_activation_deferred
		and not game.runtime_activated
		and game.process_mode == Node.PROCESS_MODE_DISABLED,
		"Deferred multiplayer runtime must freeze the complete gameplay subtree."
	)
	root.add_child(game)
	for _frame in range(240):
		if game.is_runtime_preparation_complete():
			break
		await process_frame
	_expect(
		game.is_runtime_preparation_complete()
		and game.process_mode == Node.PROCESS_MODE_DISABLED,
		"Runtime preparation must finish while gameplay processing remains frozen."
	)
	game.activate_runtime()
	_expect(
		not game.runtime_activation_deferred
		and game.runtime_activated
		and game.process_mode == Node.PROCESS_MODE_INHERIT,
		"Barrier completion must reactivate gameplay exactly once."
	)
	_expect_fire_sorcerer_projectile_pool(game, 48, 704)
	game.queue_free()
	await process_frame


func _test_mode_specific_mp_game_source() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(not source.is_empty(), "MpGame source must be readable.")
	_expect(
		not source.contains('preload("res://scene/game.tscn")')
		and not source.contains('preload("res://scene/game_tower_defense.tscn")'),
		"MpGame must not eagerly preload both gameplay modes."
	)
	_expect(
		not source.contains('preload("res://scene/boss/linglan')
		and not source.contains('preload("res://resources/config/bosses/linglan'),
		"Tower-defense multiplayer must not eagerly load Linglan scenes or configs."
	)
	_expect(
		not source.contains("const AGAVE_CANNONBALL_SCENE := preload")
		and not source.contains("const BULLET_SCENE := preload")
		and not source.contains("const TIYI_SNIPER_BULLET_SCENE := preload")
		and not source.contains("const TIYI_SNIPER_HIT_EFFECT_SCENE := preload")
		and not source.contains("const SKILL1_BOMB_SCENE := preload"),
		"MpGame must let the active mode and frozen character roster own projectile loading."
	)
	_expect(
		source.contains("FIRE_SORCERER_FIREBALL_VOLLEY_SCENE")
		and source.contains(
			"FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE"
		)
		and source.contains('&"fire_sorcerer_fireball_volley"')
		and source.contains(
			'&"fire_sorcerer_elite_fireball_volley"'
		)
		and source.contains(
			"fireball_target = game.get_player_for_peer(target_peer_id)"
		)
		and source.contains(
			"fireball_target = game.get_multiplayer_plant_node("
		)
		and source.contains("projectile as FireSorcererFireballVolley")
		and source.contains('projectile.has_method("simulate_compensated_motion")'),
		(
			"MpGame must instantiate, target, time-compensate, and lifetime-compensate "
			+ "Fire Sorcerer volleys."
		)
	)
	var player_source := FileAccess.get_file_as_string("res://scene/player/player.gd")
	_expect(
		not player_source.contains("const LINGLAN_SKILL2_ROCKET_SCENE := preload"),
		"Base Player must not pull a Linglan rocket scene into tower-defense loading."
	)
	_expect(
		source.contains("game.defer_runtime_activation()")
		and source.contains("net_manager.report_game_loaded()"),
		"MpGame must defer runtime activation before reporting local readiness."
	)
	for runtime_script_path in [
		"res://scene/game.gd",
		"res://scene/game_tower_defense.gd",
	]:
		var runtime_source := FileAccess.get_file_as_string(runtime_script_path)
		_expect(
			not runtime_source.contains("@export var singleplayer_campaign: WaveCampaignConfig = preload")
			and not runtime_source.contains("@export var multiplayer_campaign: WaveCampaignConfig = preload"),
			"Each runtime must load only the active player-count campaign."
		)


func _test_host_ready_barrier() -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "NetManager autoload must exist for loading-barrier coverage.")
	if net_manager == null:
		return
	net_manager.disconnect_from_game()
	net_manager.local_player_name = "LoadingSmokeHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var error := net_manager.host_create_lan_server(TEST_PORT)
	_expect(error == OK, "Loading-barrier smoke must create a local host.")
	if error != OK:
		return
	net_manager.host_start_game()
	var progress := net_manager.get_game_load_progress()
	var session_id := int(progress.get("session_id", 0))
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME
		and int(progress.get("ready", -1)) == 0
		and int(progress.get("total", -1)) == 1
		and session_id > 0,
		"Host start must freeze the expected roster before scene loading."
	)
	net_manager.mark_in_game()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME,
		"Manual mark_in_game must not bypass an incomplete ready roster."
	)
	net_manager.host_start_game()
	_expect(
		int(net_manager.get_game_load_progress().get("session_id", 0)) == session_id,
		"A duplicate start request must not replace an active loading session."
	)
	net_manager.report_game_loaded()
	var completed_progress := net_manager.get_game_load_progress()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and net_manager.host_game_ready
		and int(completed_progress.get("ready", -1)) == 1
		and int(completed_progress.get("total", -1)) == 1,
		"The final expected peer report must complete the loading barrier."
	)
	net_manager.disconnect_from_game()
	var reset_progress := net_manager.get_game_load_progress()
	_expect(
		int(reset_progress.get("ready", -1)) == 0
		and int(reset_progress.get("total", -1)) == 0
		and int(reset_progress.get("session_id", -1)) == 0,
		"Disconnect must clear the complete loading-session snapshot."
	)


func _test_singleplayer_coordinator_flow() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	if coordinator == null:
		return
	var load_errors: Array[String] = []
	var failure_callback := func(message: String) -> void:
		load_errors.append(message)
	coordinator.loading_failed.connect(failure_callback)
	coordinator.begin_singleplayer("res://scene/game.tscn")
	var deadline_msec := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline_msec:
		if not coordinator.is_loading():
			break
		await process_frame
	coordinator.loading_failed.disconnect(failure_callback)
	_expect(load_errors.is_empty(), "Single-player coordinator flow must not report a load error.")
	var runtime := current_scene as GameRuntimeBase
	_expect(
		runtime != null
		and runtime.scene_file_path == "res://scene/game.tscn"
		and runtime.is_runtime_preparation_complete()
		and runtime.runtime_activated
		and runtime.process_mode == Node.PROCESS_MODE_INHERIT,
		"Single-player loading must prepare, activate, and reveal the selected runtime."
	)
	for path in STANDARD_BOSS_RUNTIME_RESOURCE_PATHS:
		_expect(
			ResourceLoader.has_cached(path),
			"Standard loading must retain delayed Boss runtime resource: %s" % path
		)

	load_errors.clear()
	coordinator.loading_failed.connect(failure_callback)
	coordinator.begin_singleplayer("res://scene/game_tower_defense.tscn")
	deadline_msec = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline_msec:
		if not coordinator.is_loading():
			break
		await process_frame
	coordinator.loading_failed.disconnect(failure_callback)
	_expect(load_errors.is_empty(), "Tower-defense coordinator flow must not report a load error.")
	var tower_runtime := current_scene as GameRuntimeBase
	_expect(
		tower_runtime != null
		and tower_runtime.scene_file_path == "res://scene/game_tower_defense.tscn"
		and tower_runtime.supports_tower_defense()
		and tower_runtime.is_runtime_preparation_complete()
		and tower_runtime.runtime_activated
		and bool(tower_runtime.get("plant_lifecycle_shader_prewarmed")),
		"Tower-defense loading must finish staged preparation before activation."
	)
	_expect_fire_sorcerer_projectile_pool(tower_runtime, 48, 704)
	await physics_frame
	await physics_frame
	_expect_lifecycle_prewarm_pool_released(tower_runtime)
	for path in TOWER_DEFENSE_HIGH_FREQUENCY_RESOURCE_PATHS:
		_expect(
			ResourceLoader.has_cached(path),
			"Tower-defense preparation must cache first-use resource: %s" % path
		)
	for path in STANDARD_BOSS_RUNTIME_RESOURCE_PATHS:
		_expect(
			not ResourceLoader.has_cached(path),
			"Tower-defense loading must not retain standard Boss resource: %s" % path
		)


func _test_mp_game_preparation_barrier() -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager == null:
		return
	net_manager.disconnect_from_game()
	net_manager.local_player_name = "MpPreparationHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var error := net_manager.host_create_lan_server(TEST_PORT + 1)
	_expect(error == OK, "MpGame preparation smoke must create a local host.")
	if error != OK:
		return
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"MpGame preparation smoke must select tower-defense mode."
	)
	net_manager.host_start_game()
	var mp_game := MP_GAME_SCENE.instantiate()
	root.add_child(mp_game)
	var deadline_msec := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline_msec:
		if net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME:
			break
		await process_frame
	var runtime := mp_game.get("game") as GameRuntimeBase
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and runtime != null
		and runtime.supports_tower_defense()
		and runtime.is_runtime_preparation_complete()
		and runtime.runtime_activated
		and runtime.process_mode == Node.PROCESS_MODE_INHERIT
		and bool(runtime.get("plant_lifecycle_shader_prewarmed")),
		"MpGame must finish preparation while disabled, report ready, then activate."
	)
	mp_game.queue_free()
	await process_frame
	net_manager.disconnect_from_game()


func _expect_lifecycle_prewarm_pool_released(runtime: GameRuntimeBase) -> void:
	var tower_runtime := runtime as GameTowerDefense
	if tower_runtime == null:
		return
	for scene_path in [
		"res://scene/plant_defense/effects/plant_placement_particles.tscn",
		"res://scene/plant_defense/effects/plant_removal_smoke.tscn",
	]:
		var metrics := tower_runtime.session_object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("pending_release", -1)) == 0,
			"Lifecycle VFX prewarm lease must return to its pool: %s" % scene_path
		)


func _expect_fire_sorcerer_projectile_pool(
	runtime: GameRuntimeBase,
	expected_prewarm_count: int,
	expected_retained_capacity: int
) -> void:
	if runtime == null:
		return
	var object_pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
	_expect(object_pool != null, "Runtime must expose its projectile object pool.")
	if object_pool == null:
		return
	for scene_path in [
		"res://scene/enemy/fire_sorcerer_fireball_volley.tscn",
		"res://scene/enemy/fire_sorcerer_elite_fireball_volley.tscn",
	]:
		var metrics := object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("created", -1)) == expected_prewarm_count
			and int(metrics.get("inactive", -1)) == expected_prewarm_count
			and int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("pending_release", -1)) == 0
			and int(metrics.get("overflow", -1)) == 0
			and int(metrics.get("dropped", -1)) == 0
			and int(metrics.get("retained_capacity", -1))
				== expected_retained_capacity,
			(
				"%s pool must prewarm %d leases with capacity %d."
				% [
					scene_path,
					expected_prewarm_count,
					expected_retained_capacity,
				]
			)
		)


func _finish() -> void:
	if failures.is_empty():
		print("GAME_LOADING_BARRIER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
