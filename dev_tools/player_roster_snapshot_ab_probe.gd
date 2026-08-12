extends SceneTree

const STANDARD_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const SAMPLE_COUNT := 7
const COLLECTIONS_PER_SAMPLE := 3000


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := STANDARD_SCENE.instantiate() as StandardGame
	if game == null:
		push_error("PLAYER_ROSTER_SNAPSHOT_AB_PROBE_FAILED scene")
		quit(1)
		return
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
	var legacy_once := _legacy_collect(game.peer_players)
	var reused_once := game.collect_player_snapshot_states()
	if _state_hash(legacy_once) != _state_hash(reused_once):
		push_error("PLAYER_ROSTER_SNAPSHOT_AB_PROBE_FAILED state_hash")
		game.queue_free()
		quit(1)
		return
	var legacy_samples: Array[int] = []
	var reused_samples: Array[int] = []
	var checksum := 0
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			checksum += _measure_legacy(game.peer_players, legacy_samples)
			checksum += _measure_reused(game, reused_samples)
		else:
			checksum += _measure_reused(game, reused_samples)
			checksum += _measure_legacy(game.peer_players, legacy_samples)
	legacy_samples.sort()
	reused_samples.sort()
	var legacy_p50 := legacy_samples[legacy_samples.size() / 2]
	var reused_p50 := reused_samples[reused_samples.size() / 2]
	var improvement := (
		float(legacy_p50 - reused_p50) / float(maxi(legacy_p50, 1)) * 100.0
	)
	print(
		"PLAYER_ROSTER_SNAPSHOT_AB_PROBE_OK legacy_p50_usec=%d reused_p50_usec=%d improvement_percent=%.2f checksum=%d"
		% [legacy_p50, reused_p50, improvement, checksum]
	)
	game.queue_free()
	await process_frame
	quit(0)


func _measure_legacy(
	peer_players: Dictionary,
	samples: Array[int]
) -> int:
	var checksum := 0
	var states: Array[SnapshotManager.PlayerState] = []
	var started_at := Time.get_ticks_usec()
	for _index in range(COLLECTIONS_PER_SAMPLE):
		states = _legacy_collect(peer_players)
		checksum += states.size() + states[0].current_health
	samples.append(Time.get_ticks_usec() - started_at)
	checksum ^= _state_hash(states)
	return checksum


func _measure_reused(
	game: StandardGame,
	samples: Array[int]
) -> int:
	var checksum := 0
	var states: Array[SnapshotManager.PlayerState] = []
	var started_at := Time.get_ticks_usec()
	for _index in range(COLLECTIONS_PER_SAMPLE):
		states = game.collect_player_snapshot_states()
		checksum += states.size() + states[0].current_health
	samples.append(Time.get_ticks_usec() - started_at)
	checksum ^= _state_hash(states)
	return checksum


func _legacy_collect(
	peer_players: Dictionary
) -> Array[SnapshotManager.PlayerState]:
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
			player_instance.get_primary_cooldown_ratio(),
			0.0,
			1.0
		)
		state.effective_move_speed_multiplier = (
			player_instance.get_authoritative_effective_move_speed_ratio()
		)
		states.append(state)
	return states


func _state_hash(states: Array[SnapshotManager.PlayerState]) -> int:
	var values: Array = []
	for state in states:
		values.append([
			state.peer_id,
			state.sequence,
			state.character_id,
			state.position,
			state.velocity,
			state.facing,
			state.anim_state,
			state.current_health,
			state.max_health,
			state.health_revision,
			state.current_xirang,
			state.is_dead,
			state.invincibility_time_left,
			state.skill1_unlocked,
			state.skill1_charge,
			state.skill1_charge_duration,
			state.skill1_upgrade_level,
			state.form_mode,
			state.shot_pattern,
			state.ammo_capacity,
			state.current_ammo,
			state.is_reloading,
			state.reload_progress,
			state.primary_cooldown_ratio,
			state.effective_move_speed_multiplier,
		])
	return hash(values)
