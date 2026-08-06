extends Node
class_name MpSessionCoordinator

const RUNTIME_STATE_REQUEST_RATE_PER_SECOND := 0.5
const RUNTIME_STATE_REQUEST_RATE_BURST := 2.0


class RuntimeWorldManifest:
	extends RefCounted

	var enemy_id_set: Dictionary[int, bool] = {}
	var pickup_id_set: Dictionary[int, bool] = {}
	var plant_id_set: Dictionary[int, bool] = {}
	var positive_plant_ids := PackedInt32Array()


var _runtime: CombatRuntimeBase = null
var _runtime_state_requested := false
var _runtime_state_request_rate_buckets: Dictionary = {}


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpSessionCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	_runtime = runtime_instance
	reset_session_state()


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func try_begin_client_runtime_state_request(
	is_client: bool,
	host_game_ready: bool
) -> bool:
	if (
		not is_bound()
		or not is_client
		or not host_game_ready
		or _runtime_state_requested
	):
		return false
	_runtime_state_requested = true
	return true


func admit_authoritative_runtime_state_request(
	is_host: bool,
	sender_id: int,
	now_seconds: float
) -> bool:
	if not is_host or not is_bound() or sender_id <= 0:
		return false
	if not _consume_runtime_state_request_token(sender_id, now_seconds):
		return false
	return _runtime.get_player_for_peer(sender_id) != null


func parse_runtime_world_manifest(
	live_enemy_ids: PackedInt32Array,
	live_pickup_ids: PackedInt32Array,
	live_plant_ids: PackedInt32Array
) -> RuntimeWorldManifest:
	var manifest := RuntimeWorldManifest.new()
	for net_id in live_enemy_ids:
		if net_id > 0:
			manifest.enemy_id_set[net_id] = true
	for net_id in live_pickup_ids:
		if net_id > 0:
			manifest.pickup_id_set[net_id] = true
	for net_id in live_plant_ids:
		if net_id <= 0:
			continue
		manifest.plant_id_set[net_id] = true
		# The old repair path cleared one removal marker per wire entry. Preserve
		# both ordering and duplicates even though membership itself is deduplicated.
		manifest.positive_plant_ids.append(net_id)
	return manifest


func clear_peer(peer_id: int) -> void:
	_runtime_state_request_rate_buckets.erase(peer_id)


func reset_session_state() -> void:
	_runtime_state_requested = false
	_runtime_state_request_rate_buckets.clear()


func has_requested_runtime_state() -> bool:
	return _runtime_state_requested


func _consume_runtime_state_request_token(
	peer_id: int,
	now_seconds: float
) -> bool:
	if peer_id <= 0:
		return false
	var bucket: Dictionary
	if _runtime_state_request_rate_buckets.has(peer_id):
		bucket = _runtime_state_request_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": RUNTIME_STATE_REQUEST_RATE_BURST,
			"last_time": now_seconds,
		}
		_runtime_state_request_rate_buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", RUNTIME_STATE_REQUEST_RATE_BURST))
	var last_time := float(bucket.get("last_time", now_seconds))
	tokens = minf(
		RUNTIME_STATE_REQUEST_RATE_BURST,
		tokens
		+ maxf(now_seconds - last_time, 0.0)
		* RUNTIME_STATE_REQUEST_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now_seconds
	return accepted
