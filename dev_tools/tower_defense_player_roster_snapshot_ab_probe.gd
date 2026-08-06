extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const SAMPLE_COUNT := 7
const COLLECTIONS_PER_SAMPLE := 300


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var mode := "current"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--probe-mode="):
			mode = argument.trim_prefix("--probe-mode=")
	if mode not in ["baseline", "current"]:
		push_error("TOWER_PLAYER_ROSTER_AB_FAILED invalid_mode=%s" % mode)
		quit(1)
		return
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{4: "Fourth", 2: "Second", 1: "Host", 3: "Third"},
		{1: &"weishidaier", 2: &"tango", 3: &"weishidaier", 4: &"tango"}
	)
	root.add_child(game)
	await process_frame
	await process_frame
	var parity := _verify_snapshot_parity(game)
	var current_hash := int(parity.get("trace_hash", 0))
	if not bool(parity.get("matches", false)):
		push_error(
			"TOWER_PLAYER_ROSTER_AB_FAILED trace baseline=%d current=%d"
			% [parity.get("baseline_hash", 0), current_hash]
		)
		quit(1)
		return
	var samples_usec: Array[int] = []
	var checksum := 0
	for _sample_index in range(SAMPLE_COUNT):
		var measurement := _measure_sample(game, mode)
		samples_usec.append(int(measurement.get("elapsed_usec", 0)))
		checksum += int(measurement.get("checksum", 0))
	samples_usec.sort()
	var p50_ms := (
		float(samples_usec[samples_usec.size() / 2])
		/ float(COLLECTIONS_PER_SAMPLE)
		/ 1000.0
	)
	var p95_index := mini(
		ceili(float(samples_usec.size()) * 0.95) - 1,
		samples_usec.size() - 1
	)
	var p95_ms := (
		float(samples_usec[p95_index])
		/ float(COLLECTIONS_PER_SAMPLE)
		/ 1000.0
	)
	print(
		"TOWER_PLAYER_ROSTER_AB_OK mode=%s p50_ms=%.6f p95_ms=%.6f trace_hash=%d checksum=%d"
		% [mode, p50_ms, p95_ms, current_hash, checksum]
	)
	game.peer_players.clear()
	game.queue_free()
	await process_frame
	await physics_frame
	await process_frame
	call_deferred("_finish")


func _finish() -> void:
	quit(0)


func _verify_snapshot_parity(game: TowerDefenseGame) -> Dictionary:
	var baseline_states := _legacy_collect(game.peer_players)
	var current_states := game.collect_player_snapshot_states()
	var baseline_hash := _state_hash(baseline_states)
	var current_hash := _state_hash(current_states)
	baseline_states.clear()
	current_states.clear()
	return {
		"matches": baseline_hash == current_hash,
		"baseline_hash": baseline_hash,
		"trace_hash": current_hash,
	}


func _measure_sample(game: TowerDefenseGame, mode: String) -> Dictionary:
	var checksum := 0
	var started_at := Time.get_ticks_usec()
	for _collection_index in range(COLLECTIONS_PER_SAMPLE):
		var states := (
			_legacy_collect(game.peer_players)
			if mode == "baseline"
			else game.collect_player_snapshot_states()
		)
		checksum += states.size() + states[0].current_health
		states.clear()
	return {
		"elapsed_usec": Time.get_ticks_usec() - started_at,
		"checksum": checksum,
	}


func _legacy_collect(peer_players: Dictionary) -> Array[SnapshotManager.PlayerState]:
	var states: Array[SnapshotManager.PlayerState] = []
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		var player_instance := peer_players[peer_id] as Player
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = peer_id
		state.character_id = player_instance.get_character_id()
		state.position = player_instance.global_position
		state.velocity = player_instance.velocity
		state.facing = player_instance.get_multiplayer_facing_id()
		state.anim_state = player_instance.get_multiplayer_anim_state()
		state.current_health = player_instance.current_health
		state.max_health = player_instance.max_health
		state.current_xirang = player_instance.current_xirang
		state.is_dead = player_instance.is_dead
		state.invincibility_time_left = player_instance.invincibility_time_left
		state.skill1_unlocked = player_instance.skill1_unlocked
		state.skill1_charge = player_instance.skill1_charge
		state.skill1_charge_duration = player_instance.skill1_charge_duration
		state.skill1_upgrade_level = player_instance.skill1_upgrade_level
		state.form_mode = player_instance.get_multiplayer_form_mode()
		state.shot_pattern = player_instance.get_multiplayer_shot_pattern()
		state.ammo_capacity = player_instance.get_multiplayer_ammo_capacity()
		state.current_ammo = player_instance.get_multiplayer_current_ammo()
		state.is_reloading = player_instance.get_multiplayer_is_reloading()
		state.reload_progress = player_instance.get_multiplayer_reload_progress()
		state.primary_cooldown_ratio = clampf(
			player_instance.get_primary_cooldown_ratio(), 0.0, 1.0
		)
		state.effective_move_speed_multiplier = (
			player_instance.get_authoritative_move_speed_multiplier()
		)
		states.append(state)
	return states


func _state_hash(states: Array[SnapshotManager.PlayerState]) -> int:
	var values: Array = []
	for state in states:
		values.append([
			state.peer_id, state.character_id, state.position, state.velocity,
			state.facing, state.anim_state, state.current_health, state.max_health,
			state.current_xirang, state.is_dead, state.invincibility_time_left,
			state.skill1_unlocked, state.skill1_charge, state.skill1_charge_duration,
			state.skill1_upgrade_level, state.form_mode, state.shot_pattern,
			state.ammo_capacity, state.current_ammo, state.is_reloading,
			state.reload_progress, state.primary_cooldown_ratio,
			state.effective_move_speed_multiplier,
		])
	return hash(values)
