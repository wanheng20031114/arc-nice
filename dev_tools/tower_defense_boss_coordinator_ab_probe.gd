extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const BOSS_CONFIG := preload(
	"res://resources/config/bosses/boss_01_linglan.tres"
)
const SLIME_CONFIG := preload(
	"res://resources/config/enemies/slime.tres"
)
const FIXED_SEED := 0x5EEDB055

var failures: Array[String] = []
var flow_events: Array[String] = []
var boss_events: Array[String] = []
var exit_code := 0
var exit_timer: Timer


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var trace: Dictionary = {}
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	if game == null:
		_finish_with_failure("无法实例化 TowerDefenseGame A/B fixture。")
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.random_generator.seed = FIXED_SEED
	game.multiplayer_mode_adapter.flow_state_changed.connect(_on_flow_state_changed)
	game.multiplayer_mode_adapter.boss_started.connect(_on_boss_started)

	game.call("_begin_linglan_boss_intro", BOSS_CONFIG)
	var boss := game.linglan_boss as LinglanBoss
	trace["intro"] = {
		"state": int(game.wave_state),
		"total": game.current_wave_total,
		"spawned": game.current_wave_spawned,
		"defeated": game.current_wave_defeated,
		"escaped": game.current_wave_escaped,
		"resolved": game.current_wave_resolved,
		"boss_started": game.linglan_boss_started,
		"boss_position": _vector_key(boss.global_position if boss != null else Vector2.INF),
		"boss_active": boss != null and boss.is_active,
	}
	if boss == null:
		failures.append("Boss intro 未创建 LinglanBoss。")
	else:
		game.call("_on_linglan_boss_intro_finished")
		boss.set_process(false)
		boss.set_physics_process(false)
		if game.linglan_boss_intro_vfx != null:
			game.linglan_boss_intro_vfx.stop_intro()

	var skill4_target := game.get_linglan_skill4_target_global_position(
		Vector2i(-3, -1), Vector2i(18, 16)
	)
	var skill4_bounds := game.get_linglan_skill4_laser_bounds(-3, 18, -1, 16, 5)
	trace["active"] = {
		"state": int(game.wave_state),
		"active_enemy_count": game.active_wave_enemy_ids.size(),
		"boss_active": boss != null and boss.is_active,
		"skill2_target": _vector_key(
			game.get_linglan_skill2_target_global_position(Vector2i(7, 8))
		),
		"skill3_target": _vector_key(
			game.get_linglan_skill3_target_global_position(Vector2i(9, 10))
		),
		"skill4_target": _vector_key(skill4_target),
		"skill4_orb": _vector_key(
			game.get_linglan_skill4_orb_spawn_global_position(6, 2)
		),
		"skill4_bounds": _bounds_key(skill4_bounds),
	}

	game.spawn_linglan_skill2_enemies(
		SLIME_CONFIG, [&"Spawn1", &"Spawn2"] as Array[StringName]
	)
	game.spawn_linglan_random_slime(Vector2(321.0, 234.0))
	var adds: Array[String] = []
	for child in game.enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null:
			continue
		enemy.set_process(false)
		enemy.set_physics_process(false)
		adds.append(
			"%s@%s" % [
				enemy.config.resource_path if enemy.config != null else "",
				_vector_key(enemy.global_position),
			]
		)
	adds.sort()
	trace["adds"] = {
		"items": adds,
		"active_enemy_count": game.active_wave_enemy_ids.size(),
		"hud_enemy_count": game.hud_alive_enemy_ids.size(),
		"next_net_id": game.next_multiplayer_enemy_net_id,
	}

	await create_timer(0.80).timeout
	trace["network"] = {
		"flow_events": flow_events.duplicate(),
		"boss_events": boss_events.duplicate(),
	}
	if boss != null:
		game.call("_on_linglan_boss_defeated", boss)
		await create_timer(1.35).timeout
	trace["result"] = {
		"state": int(game.wave_state),
		"defeated": game.current_wave_defeated,
		"resolved": game.current_wave_resolved,
		"active_enemy_count": game.active_wave_enemy_ids.size(),
		"hud_enemy_count": game.hud_alive_enemy_ids.size(),
	}

	_stop_audio_recursive(game)
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(10):
		await process_frame
		await physics_frame
	var trace_json := JSON.stringify(trace)
	print("TOWER_BOSS_AB_TRACE=", trace_json)
	print("TOWER_BOSS_AB_HASH=", trace_json.sha256_text())
	if failures.is_empty():
		print("TOWER_DEFENSE_BOSS_COORDINATOR_AB_PROBE_OK")
		_schedule_exit(0)
		return
	for failure in failures:
		push_error(failure)
	_schedule_exit(1)


func _on_flow_state_changed(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	flow_events.append("%s:%d:%d" % [String(step_id), state, seconds])


func _on_boss_started(
	net_id: int,
	_boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	boss_events.append("%d@%s" % [net_id, _vector_key(spawn_position)])


func _bounds_key(bounds: Dictionary) -> Dictionary:
	return {
		"start_min": _vector_key(bounds.get("start_min", Vector2.INF)),
		"start_max": _vector_key(bounds.get("start_max", Vector2.INF)),
		"final_min": _vector_key(bounds.get("final_min", Vector2.INF)),
		"final_max": _vector_key(bounds.get("final_max", Vector2.INF)),
	}


func _vector_key(value: Vector2) -> String:
	return "%.3f,%.3f" % [value.x, value.y]


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


func _finish_with_failure(message: String) -> void:
	push_error(message)
	_schedule_exit(1)


func _schedule_exit(code: int) -> void:
	exit_code = code
	exit_timer = Timer.new()
	exit_timer.one_shot = true
	exit_timer.wait_time = 0.1
	root.add_child(exit_timer)
	exit_timer.timeout.connect(_quit_after_async_release)
	exit_timer.start()


func _quit_after_async_release() -> void:
	exit_timer.stop()
	exit_timer.queue_free()
	quit(exit_code)
