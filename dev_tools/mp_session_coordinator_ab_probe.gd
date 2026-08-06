extends SceneTree

const ROUND_COUNT := 3
const EVENTS_PER_ROUND := 2048
const FIXED_SEED := 0x6D505345


class ProbeRuntime:
	extends CombatRuntimeBase

	var players: Dictionary[int, Player] = {}

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class LegacySessionLogic:
	extends RefCounted

	const RATE := 0.5
	const BURST := 2.0

	var runtime: ProbeRuntime
	var requested := false
	var buckets: Dictionary = {}

	func try_begin(is_client: bool, host_ready: bool) -> bool:
		if runtime == null or not is_client or not host_ready or requested:
			return false
		requested = true
		return true

	func admit(is_host: bool, peer_id: int, now: float) -> bool:
		if not is_host or runtime == null or peer_id <= 0:
			return false
		if not _consume(peer_id, now):
			return false
		return runtime.get_player_for_peer(peer_id) != null

	func parse(enemies: PackedInt32Array, pickups: PackedInt32Array, plants: PackedInt32Array) -> Dictionary:
		var enemy_set: Dictionary[int, bool] = {}
		var pickup_set: Dictionary[int, bool] = {}
		var plant_set: Dictionary[int, bool] = {}
		var positive_plants := PackedInt32Array()
		for net_id in enemies:
			if net_id > 0:
				enemy_set[net_id] = true
		for net_id in pickups:
			if net_id > 0:
				pickup_set[net_id] = true
		for net_id in plants:
			if net_id > 0:
				plant_set[net_id] = true
				positive_plants.append(net_id)
		return {
			"enemy": enemy_set,
			"pickup": pickup_set,
			"plant": plant_set,
			"positive_plants": positive_plants,
		}

	func clear_peer(peer_id: int) -> void:
		buckets.erase(peer_id)

	func reset() -> void:
		requested = false
		buckets.clear()

	func _consume(peer_id: int, now: float) -> bool:
		var bucket: Dictionary
		if buckets.has(peer_id):
			bucket = buckets[peer_id] as Dictionary
		else:
			bucket = {"tokens": BURST, "last_time": now}
			buckets[peer_id] = bucket
		var tokens := float(bucket.get("tokens", BURST))
		var last_time := float(bucket.get("last_time", now))
		tokens = minf(BURST, tokens + maxf(now - last_time, 0.0) * RATE)
		var accepted := tokens >= 1.0
		if accepted:
			tokens -= 1.0
		bucket["tokens"] = tokens
		bucket["last_time"] = now
		return accepted


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var combined_hash := 17
	for round_index in range(ROUND_COUNT):
		var legacy_hash := _run_trace(true, FIXED_SEED + round_index)
		var extracted_hash := _run_trace(false, FIXED_SEED + round_index)
		_expect(
			legacy_hash == extracted_hash,
			"第 %d 轮会话轨迹不一致：legacy=%d extracted=%d。"
			% [round_index + 1, legacy_hash, extracted_hash]
		)
		combined_hash = _combine_hash(combined_hash, extracted_hash)
	if failures.is_empty():
		print(
			"MP_SESSION_COORDINATOR_AB_PROBE_OK rounds=%d trajectory_hash=%d"
			% [ROUND_COUNT, combined_hash]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_trace(use_legacy: bool, seed: int) -> int:
	var runtime := ProbeRuntime.new()
	var players: Array[Player] = []
	for peer_id in range(1, 5):
		var player := Player.new()
		players.append(player)
		runtime.players[peer_id] = player
	var legacy := LegacySessionLogic.new()
	legacy.runtime = runtime
	var extracted := MpSessionCoordinator.new()
	extracted.bind_runtime(runtime)
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var trace_hash := 23
	var now := 100.0
	for _event_index in range(EVENTS_PER_ROUND):
		match random.randi_range(0, 3):
			0:
				var enemies := _random_ids(random)
				var pickups := _random_ids(random)
				var plants := _random_ids(random)
				trace_hash = _combine_hash(
					trace_hash,
					_manifest_hash(
						legacy.parse(enemies, pickups, plants)
						if use_legacy
						else _extract_manifest(extracted, enemies, pickups, plants)
					)
				)
			1:
				now += random.randf_range(-0.25, 1.0)
				var peer_id := random.randi_range(-1, 6)
				var is_host := random.randi_range(0, 4) != 0
				var accepted := (
					legacy.admit(is_host, peer_id, now)
					if use_legacy
					else extracted.admit_authoritative_runtime_state_request(
						is_host, peer_id, now
					)
				)
				trace_hash = _combine_hash(trace_hash, 1 if accepted else 0)
			2:
				var is_client := random.randi_range(0, 3) != 0
				var host_ready := random.randi_range(0, 2) != 0
				var began := (
					legacy.try_begin(is_client, host_ready)
					if use_legacy
					else extracted.try_begin_client_runtime_state_request(
						is_client, host_ready
					)
				)
				trace_hash = _combine_hash(trace_hash, 1 if began else 0)
			_:
				var peer_id := random.randi_range(1, 6)
				if random.randi_range(0, 3) == 0:
					if use_legacy:
						legacy.reset()
					else:
						extracted.reset_session_state()
				else:
					if use_legacy:
						legacy.clear_peer(peer_id)
					else:
						extracted.clear_peer(peer_id)
				trace_hash = _combine_hash(trace_hash, peer_id)
	for player in players:
		player.free()
	runtime.free()
	extracted.free()
	return trace_hash


func _random_ids(random: RandomNumberGenerator) -> PackedInt32Array:
	var result := PackedInt32Array()
	for _index in range(random.randi_range(0, 7)):
		result.append(random.randi_range(-2, 8))
	return result


func _extract_manifest(
	coordinator: MpSessionCoordinator,
	enemies: PackedInt32Array,
	pickups: PackedInt32Array,
	plants: PackedInt32Array
) -> Dictionary:
	var manifest := coordinator.parse_runtime_world_manifest(
		enemies, pickups, plants
	)
	return {
		"enemy": manifest.enemy_id_set,
		"pickup": manifest.pickup_id_set,
		"plant": manifest.plant_id_set,
		"positive_plants": manifest.positive_plant_ids,
	}


func _manifest_hash(manifest: Dictionary) -> int:
	var result := 31
	for key in [&"enemy", &"pickup", &"plant"]:
		var ids: Array = (manifest.get(key, {}) as Dictionary).keys()
		ids.sort()
		result = _combine_hash(result, ids.size())
		for net_id_variant in ids:
			result = _combine_hash(result, int(net_id_variant))
	var positive_plants := (
		manifest.get("positive_plants", PackedInt32Array()) as PackedInt32Array
	)
	result = _combine_hash(result, positive_plants.size())
	for net_id in positive_plants:
		result = _combine_hash(result, net_id)
	return result


func _combine_hash(current: int, value: int) -> int:
	return int((current * 65599 + value) & 0x7fffffff)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
