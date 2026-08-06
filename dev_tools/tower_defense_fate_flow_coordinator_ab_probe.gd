extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const PROBE_SEED := 852741963
const TIME_SCALE := 4.0

var trace: Array[Dictionary] = []
var failures: Array[String] = []
var exit_code := 0
var exit_timer: Timer


func _init() -> void:
	Engine.time_scale = TIME_SCALE
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	if game == null:
		_fail("TowerDefenseGame scene failed to instantiate.")
		_finish()
		return
	game.auto_start_waves = false
	game.random_generator.seed = PROBE_SEED
	var runtime_fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if runtime_fate != null:
		runtime_fate.elite_enemy_config_loads_requested = true
		runtime_fate.random_generator.seed = PROBE_SEED + 1
	var runtime_boss := game.get_node_or_null(
		"BossCoordinator"
	) as TowerDefenseBossCoordinator
	if runtime_boss != null:
		runtime_boss.runtime_scene_loads_requested = true
	root.add_child(game)
	current_scene = game
	await process_frame
	game.fate_manager.random_generator.seed = PROBE_SEED + 2
	var next_step := game._get_start_flow_step()
	if next_step == null:
		_fail("Fate A/B probe could not resolve a campaign step.")
		await _cleanup_game(game)
		_finish()
		return
	var next_step_id := game._get_flow_step_id(next_step)
	game.current_wave_index = 3
	game.plant_terrain_decay_timer.start(9.0)
	game._enter_xiaocong_fate_interlude(next_step)
	await create_timer(1.2).timeout
	_trace_state(game, &"host_entered", next_step_id)
	if not game.fate_manager.active:
		_fail("Host fate entry did not activate the manager.")
	var active_snapshot := game.get_xiaocong_fate_state_snapshot()
	game.player.global_position = game.xiaocong_fate_interlude.global_position
	game.request_xiaocong_interaction(0)
	_trace_state(game, &"host_interacted", next_step_id)
	game.fate_manager.force_finish()
	await create_timer(3.0).timeout
	_trace_state(game, &"host_departed", next_step_id)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.fate_manager.state_revision = 0
	active_snapshot["revision"] = 1
	active_snapshot["active"] = true
	active_snapshot["stage"] = String(
		TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS
	)
	active_snapshot["interacted_peer_ids"] = []
	game.apply_remote_flow_state(
		next_step_id,
		int(CombatFlowState.State.FATE_INTERLUDE),
		0
	)
	game.apply_remote_xiaocong_fate_state(active_snapshot)
	await create_timer(1.2).timeout
	_trace_state(game, &"client_entered", next_step_id)
	var stale_snapshot := active_snapshot.duplicate(true)
	stale_snapshot["revision"] = 0
	stale_snapshot["elite_bias_day"] = 77
	var elite_bias_before := game.fate_coordinator.elite_bias_day
	game.apply_remote_xiaocong_fate_state(stale_snapshot)
	trace.append({
		"event": "client_stale_snapshot",
		"rejected": game.fate_coordinator.elite_bias_day == elite_bias_before,
	})
	var inactive_snapshot := active_snapshot.duplicate(true)
	inactive_snapshot["revision"] = 2
	inactive_snapshot["active"] = false
	inactive_snapshot["winning_option_id"] = ""
	game.apply_remote_xiaocong_fate_state(inactive_snapshot)
	game.apply_remote_flow_state(
		next_step_id,
		int(CombatFlowState.State.INTERMISSION),
		6
	)
	game.apply_remote_flow_state(
		next_step_id,
		int(CombatFlowState.State.INTERMISSION),
		5
	)
	await create_timer(3.0).timeout
	_trace_state(game, &"client_departed", next_step_id)

	await _cleanup_game(game)
	_finish()


func _trace_state(
	game: TowerDefenseGame,
	event: StringName,
	next_step_id: StringName
) -> void:
	trace.append({
		"event": String(event),
		"wave_state": int(game.wave_state),
		"next_step_id": String(next_step_id),
		"manager_active": game.fate_manager.active,
		"manager_stage": String(game.fate_manager.stage),
		"manager_revision": game.fate_manager.state_revision,
		"interlude_active": game.xiaocong_fate_interlude.is_active,
		"player_at_room_spawn": (
			game.player.global_position
			== game.xiaocong_fate_interlude.get_player_spawn_position(0)
		),
		"player_at_world_spawn": (
			game.player.global_position == game.player_spawn.global_position
		),
		"combat_locked": game.player.combat_actions_locked,
		"controls_locked": game.player.controls_locked,
		"production_enabled": (
			game.production_coordinator.authoritative_processing_enabled
		),
		"research_enabled": (
			game.research_coordinator.authoritative_processing_enabled
		),
		"terrain_timer_stopped": game.plant_terrain_decay_timer.is_stopped(),
		"eligible_peers": game.fate_manager.eligible_peer_ids.duplicate(),
		"interacted_peers": game.fate_manager.interacted_peer_ids.duplicate(),
		"available_options": _to_string_array(
			game.fate_manager.available_option_ids
		),
	})


func _to_string_array(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result


func _cleanup_game(game: TowerDefenseGame) -> void:
	_stop_audio_recursive(game)
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame


func _finish() -> void:
	var trace_json := JSON.stringify(trace)
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(trace_json.to_utf8_buffer())
	var trace_hash := hashing.finish().hex_encode()
	print("TOWER_FATE_FLOW_AB_TRACE=%s" % trace_json)
	print("TOWER_FATE_FLOW_AB_HASH=%s" % trace_hash)
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_FLOW_COORDINATOR_AB_PROBE_OK")
		_schedule_exit(0)
		return
	for failure in failures:
		push_error(failure)
	_schedule_exit(1)


func _fail(message: String) -> void:
	failures.append(message)


func _stop_audio_recursive(node: Node) -> void:
	var player_2d := node as AudioStreamPlayer2D
	if player_2d != null:
		player_2d.stop()
		player_2d.stream = null
	var player := node as AudioStreamPlayer
	if player != null:
		player.stop()
		player.stream = null
	for child in node.get_children():
		_stop_audio_recursive(child)


func _schedule_exit(code: int) -> void:
	exit_code = code
	exit_timer = Timer.new()
	exit_timer.one_shot = true
	exit_timer.wait_time = 0.1
	root.add_child(exit_timer)
	exit_timer.timeout.connect(_quit_after_async_release)
	exit_timer.start()


func _quit_after_async_release() -> void:
	Engine.time_scale = 1.0
	exit_timer.stop()
	exit_timer.queue_free()
	quit(exit_code)
