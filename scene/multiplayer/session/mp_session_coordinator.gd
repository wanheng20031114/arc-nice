extends Node
class_name MpSessionCoordinator

signal rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
)
signal runtime_repair_plant_roster_requested(peer_id: int)
signal client_runtime_repair_available

const RUNTIME_STATE_REQUEST_RATE_PER_SECOND := 0.5
const RUNTIME_STATE_REQUEST_RATE_BURST := 2.0
const CLIENT_RUNTIME_REPAIR_LEASE_SECONDS := 2.0
const CLIENT_RUNTIME_REPAIR_COOLDOWN_SECONDS := 0.25
const MAX_CLIENT_RUNTIME_REPAIR_REQUEST_ID := 0x7FFFFFFF
const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08


class RuntimeWorldManifest:
	extends RefCounted

	var enemy_id_set: Dictionary[int, bool] = {}
	var pickup_id_set: Dictionary[int, bool] = {}
	var plant_id_set: Dictionary[int, bool] = {}
	var positive_plant_ids := PackedInt32Array()


var _runtime: CombatRuntimeBase = null
var _net_manager: NetManagerStore = null
var _world_flow_coordinator: MpWorldFlowCoordinator = null
var _enemy_coordinator: MpEnemyCoordinator = null
var _tower_world_coordinator: MpTowerWorldCoordinator = null
var _tower_economy_coordinator: MpTowerEconomyCoordinator = null
var _player_coordinator: MpPlayerCoordinator = null
var _transactions_coordinator: MpTransactionsCoordinator = null
var _merchant_transactions_coordinator: MpMerchantTransactionsCoordinator = null
var _tower_fate_coordinator: MpTowerFateCoordinator = null
var _network_diagnostics_coordinator: MpNetworkDiagnosticsCoordinator = null
var _tower_mode_adapter: TowerDefenseMultiplayerModeAdapter = null
## 首次进局同步是一局一次的启动屏障；后续异常修复使用下面独立的短租约，
## 不能再由这个 one-shot 标记永久挡住。
var _initial_runtime_state_requested := false
## 修复 request id 只标识客户端本地租约，不进入 wire。序列跨 session reset
## 保持单调，旧 deferred/timeout 回调不能误释放后来建立的新租约。
var _client_runtime_repair_request_sequence := 0
var _client_runtime_repair_in_flight_id := 0
var _client_runtime_repair_lease_time_left := 0.0
var _client_runtime_repair_cooldown_time_left := 0.0
var _client_runtime_repair_deferred := false
var _client_runtime_repair_availability_announced := false
var _runtime_state_request_rate_buckets: Dictionary = {}
var _net_time_origin: float = 0.0
var _has_host_time_offset := false
var _host_to_client_time_offset: float = 0.0


func bind_transport_dependencies(
	net_manager_instance: NetManagerStore
) -> void:
	assert(net_manager_instance != null, "MpSessionCoordinator 缺少 NetManagerStore。")
	if _net_manager != net_manager_instance:
		unbind_transport_dependencies()
		_net_manager = net_manager_instance
	reset_transport_state()


func unbind_transport_dependencies() -> void:
	_net_manager = null
	_reset_transport_values()


func update_transport(delta: float) -> void:
	_update_client_runtime_repair_lease(maxf(delta, 0.0))


func get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func get_net_time_origin() -> float:
	return _net_time_origin


func map_host_timestamp_to_client_time(
	host_timestamp: float,
	update_offset: bool = true
) -> float:
	var receive_time := get_net_time()
	var sampled_offset := receive_time - host_timestamp
	if not update_offset:
		if _has_host_time_offset:
			return host_timestamp + _host_to_client_time_offset
		return receive_time
	if not _has_host_time_offset:
		_host_to_client_time_offset = sampled_offset
		_has_host_time_offset = true
	else:
		_host_to_client_time_offset = lerpf(
			_host_to_client_time_offset,
			sampled_offset,
			HOST_TIME_OFFSET_SMOOTH_WEIGHT
		)
	return host_timestamp + _host_to_client_time_offset


func has_host_time_offset() -> bool:
	return _has_host_time_offset


func get_host_to_client_time_offset() -> float:
	return _host_to_client_time_offset


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpSessionCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	_clear_world_manifest_dependencies()
	_runtime = runtime_instance
	reset_session_state()


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	_clear_world_manifest_dependencies()
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func bind_world_manifest_dependencies(
	world_flow_coordinator_instance: MpWorldFlowCoordinator,
	enemy_coordinator_instance: MpEnemyCoordinator,
	tower_world_coordinator_instance: MpTowerWorldCoordinator,
	tower_economy_coordinator_instance: MpTowerEconomyCoordinator
) -> void:
	assert(
		world_flow_coordinator_instance != null,
		"MpSessionCoordinator 缺少世界流程协调器。"
	)
	assert(
		enemy_coordinator_instance != null,
		"MpSessionCoordinator 缺少敌人协调器。"
	)
	assert(
		tower_world_coordinator_instance != null,
		"MpSessionCoordinator 缺少塔防世界协调器。"
	)
	assert(
		tower_economy_coordinator_instance != null,
		"MpSessionCoordinator 缺少塔防经济协调器。"
	)
	_world_flow_coordinator = world_flow_coordinator_instance
	_enemy_coordinator = enemy_coordinator_instance
	_tower_world_coordinator = tower_world_coordinator_instance
	_tower_economy_coordinator = tower_economy_coordinator_instance


func bind_runtime_repair_dependencies(
	player_coordinator_instance: MpPlayerCoordinator,
	transactions_coordinator_instance: MpTransactionsCoordinator,
	merchant_transactions_coordinator_instance: MpMerchantTransactionsCoordinator,
	tower_fate_coordinator_instance: MpTowerFateCoordinator,
	network_diagnostics_coordinator_instance: MpNetworkDiagnosticsCoordinator,
	tower_mode_adapter_instance: TowerDefenseMultiplayerModeAdapter = null
) -> void:
	assert(
		player_coordinator_instance != null,
		"MpSessionCoordinator 缺少玩家协调器。"
	)
	assert(
		transactions_coordinator_instance != null,
		"MpSessionCoordinator 缺少事务协调器。"
	)
	assert(
		merchant_transactions_coordinator_instance != null,
		"MpSessionCoordinator 缺少商人事务协调器。"
	)
	assert(
		tower_fate_coordinator_instance != null,
		"MpSessionCoordinator 缺少塔防命运协调器。"
	)
	assert(
		network_diagnostics_coordinator_instance != null,
		"MpSessionCoordinator 缺少网络诊断协调器。"
	)
	_player_coordinator = player_coordinator_instance
	_transactions_coordinator = transactions_coordinator_instance
	_merchant_transactions_coordinator = merchant_transactions_coordinator_instance
	_tower_fate_coordinator = tower_fate_coordinator_instance
	_network_diagnostics_coordinator = network_diagnostics_coordinator_instance
	_tower_mode_adapter = tower_mode_adapter_instance


func has_world_manifest_dependencies() -> bool:
	return (
		is_bound()
		and _world_flow_coordinator != null
		and is_instance_valid(_world_flow_coordinator)
		and _enemy_coordinator != null
		and is_instance_valid(_enemy_coordinator)
		and _tower_world_coordinator != null
		and is_instance_valid(_tower_world_coordinator)
		and _tower_economy_coordinator != null
		and is_instance_valid(_tower_economy_coordinator)
	)


func has_runtime_repair_dependencies() -> bool:
	return (
		has_world_manifest_dependencies()
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _player_coordinator != null
		and is_instance_valid(_player_coordinator)
		and _transactions_coordinator != null
		and is_instance_valid(_transactions_coordinator)
		and _merchant_transactions_coordinator != null
		and is_instance_valid(_merchant_transactions_coordinator)
		and _tower_fate_coordinator != null
		and is_instance_valid(_tower_fate_coordinator)
		and _network_diagnostics_coordinator != null
		and is_instance_valid(_network_diagnostics_coordinator)
	)


func try_begin_client_runtime_state_request(
	is_client: bool,
	host_game_ready: bool
) -> bool:
	if (
		not is_bound()
		or not is_client
		or not host_game_ready
		or _initial_runtime_state_requested
	):
		return false
	_initial_runtime_state_requested = true
	return true


## PeerLedger 等运行时异常走可重入修复租约。活动租约和冷却期内的多次故障
## 只合并成一笔 deferred 债务；调用者不得为每个 reject 各发一份全量状态。
func try_begin_client_runtime_repair_request(
	is_client: bool,
	host_game_ready: bool
) -> int:
	if not is_bound() or not is_client or not host_game_ready:
		return 0
	if (
		_client_runtime_repair_in_flight_id > 0
		or _client_runtime_repair_cooldown_time_left > 0.0
	):
		if not _client_runtime_repair_deferred:
			_client_runtime_repair_deferred = true
			_client_runtime_repair_availability_announced = false
		return 0
	if (
		_client_runtime_repair_request_sequence
		>= MAX_CLIENT_RUNTIME_REPAIR_REQUEST_ID
	):
		push_error("MpSessionCoordinator: 客户端运行时修复 request id 已耗尽。")
		return 0
	_client_runtime_repair_request_sequence += 1
	_client_runtime_repair_in_flight_id = (
		_client_runtime_repair_request_sequence
	)
	_client_runtime_repair_lease_time_left = CLIENT_RUNTIME_REPAIR_LEASE_SECONDS
	_client_runtime_repair_cooldown_time_left = 0.0
	_client_runtime_repair_deferred = false
	_client_runtime_repair_availability_announced = false
	return _client_runtime_repair_in_flight_id


## completion 只释放完全匹配的本地租约。当前协议没有跨信道“全部应用”证明，
## 正式流程主要依靠有界超时释放；该入口供未来明确完成证据及测试使用。
func complete_client_runtime_repair_request(request_id: int) -> bool:
	return _release_client_runtime_repair_lease(request_id)


## 本地发送边界失败并不表示 repair 债务消失；释放匹配租约后保留一笔
## deferred，待冷却结束重新通知 MpGame。它与远端“完成”语义严格分离。
func fail_client_runtime_repair_request(request_id: int) -> bool:
	if not _release_client_runtime_repair_lease(request_id):
		return false
	_client_runtime_repair_deferred = true
	_client_runtime_repair_availability_announced = false
	return true


## timeout 回调必须携带创建时的 request id；旧回调命中新租约时严格无效。
func expire_client_runtime_repair_request(request_id: int) -> bool:
	return _release_client_runtime_repair_lease(request_id)


func get_client_runtime_repair_in_flight_id() -> int:
	return _client_runtime_repair_in_flight_id


func has_deferred_client_runtime_repair() -> bool:
	return _client_runtime_repair_deferred


func _release_client_runtime_repair_lease(request_id: int) -> bool:
	if (
		request_id <= 0
		or request_id != _client_runtime_repair_in_flight_id
	):
		return false
	_client_runtime_repair_in_flight_id = 0
	_client_runtime_repair_lease_time_left = 0.0
	_client_runtime_repair_cooldown_time_left = (
		CLIENT_RUNTIME_REPAIR_COOLDOWN_SECONDS
	)
	return true


func _update_client_runtime_repair_lease(delta: float) -> void:
	if _client_runtime_repair_in_flight_id > 0:
		_client_runtime_repair_lease_time_left = maxf(
			_client_runtime_repair_lease_time_left - delta,
			0.0
		)
		if _client_runtime_repair_lease_time_left <= 0.0:
			var expired_request_id := _client_runtime_repair_in_flight_id
			expire_client_runtime_repair_request(expired_request_id)
		return
	if _client_runtime_repair_cooldown_time_left > 0.0:
		_client_runtime_repair_cooldown_time_left = maxf(
			_client_runtime_repair_cooldown_time_left - delta,
			0.0
		)
		if _client_runtime_repair_cooldown_time_left > 0.0:
			return
	if (
		_client_runtime_repair_deferred
		and not _client_runtime_repair_availability_announced
	):
		# 先落标记再发信号，避免同步回调重入 update 时重复通知。若此刻尚未
		# ready，MpGame 仍保留 repair 债务，并在下一次 IN_GAME 主动重试。
		_client_runtime_repair_availability_announced = true
		client_runtime_repair_available.emit()


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


func handle_authoritative_runtime_state_request(
	sender_id: int,
	include_flow_state: bool,
	now_seconds: float
) -> bool:
	if not admit_authoritative_runtime_state_request(
		_net_manager != null and _net_manager.is_host(),
		sender_id,
		now_seconds
	):
		return false
	return send_authoritative_runtime_state_to_peer(
		sender_id,
		include_flow_state
	)


func send_authoritative_runtime_state_to_peer(
	peer_id: int,
	include_flow_state: bool
) -> bool:
	if (
		not has_runtime_repair_dependencies()
		or not _net_manager.is_host()
		or peer_id <= 0
		or not _net_manager.is_peer_send_ready(peer_id)
	):
		return false
	_network_diagnostics_coordinator.record_state_repair()
	var has_tower_mode := (
		_tower_mode_adapter != null
		and is_instance_valid(_tower_mode_adapter)
	)
	_tower_world_coordinator.request_terrain_snapshot_for_peer(peer_id)
	runtime_repair_plant_roster_requested.emit(peer_id)
	for inventory_arguments in (
		_transactions_coordinator.build_runtime_repair_inventory_rpc_arguments()
	):
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_inventory_snapshot",
			inventory_arguments
		)
	for progression_repair in (
		_transactions_coordinator.build_runtime_repair_progression_rpc_requests()
	):
		rpc_to_peer_requested.emit(
			peer_id,
			StringName(progression_repair["method"]),
			progression_repair["arguments"] as Array
		)
	_merchant_transactions_coordinator.send_offer_state_if_present(peer_id)
	_enemy_coordinator.send_live_spawn_roster_to_peer(peer_id)
	_world_flow_coordinator.send_live_pickup_roster_to_peer(peer_id)
	if has_tower_mode:
		_tower_world_coordinator.request_base_health_snapshot_for_peer(peer_id)
	var progress_snapshot := _world_flow_coordinator.get_wave_progress_snapshot()
	if not progress_snapshot.is_empty():
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_tower_defense_wave_progress_keyframe",
			[
				int(progress_snapshot.get("wave_number", 1)),
				int(progress_snapshot.get("defeated", 0)),
				int(progress_snapshot.get("escaped", 0)),
				int(progress_snapshot.get("resolved", 0)),
				int(progress_snapshot.get("total", 0)),
			]
		)
	if has_tower_mode:
		_tower_fate_coordinator.send_fate_state_to_peer(peer_id)
		if _tower_mode_adapter.is_fate_interlude_active():
			_player_coordinator.send_authoritative_positions_to_peer(peer_id)
		_tower_world_coordinator.request_test_arena_manual_night_for_peer(
			peer_id
		)
	if include_flow_state:
		var flow_snapshot := _world_flow_coordinator.get_flow_state_snapshot()
		if not flow_snapshot.is_empty():
			rpc_to_peer_requested.emit(
				peer_id,
				&"net_flow_state_changed",
				[
					String(flow_snapshot.get("step_id", &"")),
					int(
						flow_snapshot.get(
							"state",
							CombatFlowState.State.PRE_WAVE
						)
					),
					int(flow_snapshot.get("countdown_seconds", 0)),
				]
			)
	_player_coordinator.send_active_tango_electric_surges_to_peer(peer_id)
	_player_coordinator.send_active_tiyi_high_noon_to_peer(peer_id)
	_send_runtime_world_manifest_to_peer(peer_id)
	return true


func _send_runtime_world_manifest_to_peer(peer_id: int) -> bool:
	if not has_world_manifest_dependencies() or peer_id <= 0:
		return false
	var live_enemy_ids := PackedInt32Array()
	var live_pickup_ids := PackedInt32Array()
	var live_plant_ids := PackedInt32Array()
	var sorted_enemy_ids: Array[int] = []
	for net_id in _runtime.get_network_enemy_ids():
		sorted_enemy_ids.append(net_id)
	sorted_enemy_ids.sort()
	for net_id in sorted_enemy_ids:
		var enemy := _runtime.get_network_enemy(net_id)
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			live_enemy_ids.append(net_id)
	var sorted_pickup_ids: Array[int] = []
	for net_id in _runtime.get_network_pickup_ids():
		sorted_pickup_ids.append(net_id)
	sorted_pickup_ids.sort()
	for net_id in sorted_pickup_ids:
		var pickup := _runtime.get_network_pickup(net_id)
		if pickup != null and is_instance_valid(pickup):
			live_pickup_ids.append(net_id)
	if _tower_world_coordinator.is_bound():
		live_plant_ids = _tower_world_coordinator.build_live_plant_ids()
	rpc_to_peer_requested.emit(
		peer_id,
		&"net_runtime_world_manifest",
		[live_enemy_ids, live_pickup_ids, live_plant_ids]
	)
	return true


func get_connected_client_peer_ids(
	embedded_runtime: bool,
	embedded_participant_peer_ids: Dictionary[int, bool],
	suspended_embedded_participant_peer_ids: Dictionary[int, bool]
) -> Array[int]:
	var result: Array[int] = []
	if _net_manager == null:
		return result
	var host_peer_id := _net_manager.get_host_peer_id()
	for peer_id_variant in _net_manager.connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_peer_id:
			continue
		if embedded_runtime and not embedded_participant_peer_ids.has(peer_id):
			continue
		if (
			embedded_runtime
			and suspended_embedded_participant_peer_ids.has(peer_id)
		):
			continue
		if (
			embedded_runtime
			and (
				_runtime == null
				or _runtime.get_player_for_peer(peer_id) == null
			)
		):
			continue
		if not _net_manager.is_peer_send_ready(peer_id):
			continue
		result.append(peer_id)
	return result


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


func apply_runtime_world_manifest(
	live_enemy_ids: PackedInt32Array,
	live_pickup_ids: PackedInt32Array,
	live_plant_ids: PackedInt32Array
) -> bool:
	if (
		not has_world_manifest_dependencies()
		or _net_manager == null
		or _net_manager.is_host()
	):
		return false
	var manifest := parse_runtime_world_manifest(
		live_enemy_ids,
		live_pickup_ids,
		live_plant_ids
	)
	_enemy_coordinator.remove_enemies_missing_from_manifest(
		manifest.enemy_id_set
	)
	for net_id in _runtime.get_network_pickup_ids():
		if not manifest.pickup_id_set.has(net_id):
			_world_flow_coordinator.receive_pickup_removed(net_id)
	if _tower_world_coordinator.is_bound():
		for plant_net_id in manifest.positive_plant_ids:
			_tower_economy_coordinator.notify_plant_available(plant_net_id)
		var removed_plant_ids := (
			_tower_world_coordinator.find_live_plant_ids_missing_from_manifest(
				manifest.plant_id_set
			)
		)
		for plant_net_id in removed_plant_ids:
			_tower_economy_coordinator.notify_plant_removed(plant_net_id)
		_tower_world_coordinator.reconcile_runtime_manifest(
			manifest.plant_id_set,
			manifest.positive_plant_ids,
			removed_plant_ids
		)
		_tower_economy_coordinator.try_apply_pending_warehouse_snapshots_atomically()
		# CH5 manifests have no total order with CH6 warehouse/production state or
		# CH7 health batches. Unknown payloads remain bounded until their CH5 spawn,
		# explicit removal, or FIFO eviction establishes their lifecycle.
	return true


func clear_peer(peer_id: int) -> void:
	_runtime_state_request_rate_buckets.erase(peer_id)


func reset_session_state() -> void:
	_initial_runtime_state_requested = false
	_client_runtime_repair_in_flight_id = 0
	_client_runtime_repair_lease_time_left = 0.0
	_client_runtime_repair_cooldown_time_left = 0.0
	_client_runtime_repair_deferred = false
	_client_runtime_repair_availability_announced = false
	_runtime_state_request_rate_buckets.clear()
	reset_transport_state()


func reset_transport_state() -> void:
	_reset_transport_values()


func has_requested_runtime_state() -> bool:
	return _initial_runtime_state_requested


func _clear_world_manifest_dependencies() -> void:
	_world_flow_coordinator = null
	_enemy_coordinator = null
	_tower_world_coordinator = null
	_tower_economy_coordinator = null
	_player_coordinator = null
	_transactions_coordinator = null
	_merchant_transactions_coordinator = null
	_tower_fate_coordinator = null
	_network_diagnostics_coordinator = null
	_tower_mode_adapter = null


func _reset_transport_values() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	_has_host_time_offset = false
	_host_to_client_time_offset = 0.0


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
