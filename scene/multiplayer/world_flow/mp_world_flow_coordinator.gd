extends Node
class_name MpWorldFlowCoordinator

const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS := 0.1

signal pickup_spawn_broadcast_requested(
	net_id: int,
	config_path: String,
	spawn_position: Vector2
)
signal pickup_remove_broadcast_requested(net_id: int)
signal merchant_active_broadcast_requested(active: bool)
signal wave_progress_broadcast_requested(
	progress: Dictionary,
	reliable: bool
)
signal flow_state_broadcast_requested(
	step_id: StringName,
	state: int,
	countdown_seconds: int
)
signal boss_started_broadcast_requested(
	net_id: int,
	boss_config_path: String,
	spawn_position: Vector2
)
signal defeat_broadcast_requested(failure_reason: String)
signal victory_broadcast_requested
signal terminal_flow_started

var _runtime: CombatRuntimeBase = null
var _mode_adapter: MultiplayerModeAdapter = null
var _enemy_coordinator: MpEnemyCoordinator = null
var _gameplay_gateway: MultiplayerGameplayGateway = null
var _pending_wave_progress: Dictionary = {}
var _wave_progress_flush_time_left := WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS
var _client_has_received_flow_state := false
var _last_applied_remote_enemy_count := -1


func bind_runtime(
	runtime_instance: CombatRuntimeBase,
	mode_adapter_instance: MultiplayerModeAdapter,
	enemy_coordinator_instance: MpEnemyCoordinator,
	gameplay_gateway_instance: MultiplayerGameplayGateway
) -> void:
	assert(runtime_instance != null, "MpWorldFlowCoordinator 缺少战斗运行时。")
	assert(mode_adapter_instance != null, "MpWorldFlowCoordinator 缺少模式适配器。")
	assert(enemy_coordinator_instance != null, "MpWorldFlowCoordinator 缺少敌人协调器。")
	assert(gameplay_gateway_instance != null, "MpWorldFlowCoordinator 缺少玩法网关。")
	if (
		_runtime == runtime_instance
		and _mode_adapter == mode_adapter_instance
		and _enemy_coordinator == enemy_coordinator_instance
		and _gameplay_gateway == gameplay_gateway_instance
	):
		return
	if _runtime != null:
		_disconnect_runtime_signals()
		reset_session_state()
	_runtime = runtime_instance
	_mode_adapter = mode_adapter_instance
	_enemy_coordinator = enemy_coordinator_instance
	_gameplay_gateway = gameplay_gateway_instance
	reset_session_state()
	_connect_runtime_signals()


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_disconnect_runtime_signals()
	reset_session_state()
	_runtime = null
	_mode_adapter = null
	_enemy_coordinator = null
	_gameplay_gateway = null


func is_bound() -> bool:
	return (
		_runtime != null
		and is_instance_valid(_runtime)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _enemy_coordinator != null
		and is_instance_valid(_enemy_coordinator)
		and _gameplay_gateway != null
		and is_instance_valid(_gameplay_gateway)
	)


func is_host_authority() -> bool:
	return (
		is_bound()
		and _runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	)


func is_client_view() -> bool:
	return (
		is_bound()
		and _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)


func supports_wave_progress() -> bool:
	return is_bound() and _mode_adapter.supports_multiplayer_wave_progress()


func request_authoritative_wave_start(requester_peer_id: int) -> bool:
	return (
		requester_peer_id > 0
		and is_host_authority()
		and supports_wave_progress()
		and _mode_adapter.request_authoritative_wave_start(requester_peer_id)
	)


func update_host(delta: float) -> bool:
	if not is_host_authority():
		return false
	_wave_progress_flush_time_left = maxf(
		_wave_progress_flush_time_left - maxf(delta, 0.0),
		0.0
	)
	if _wave_progress_flush_time_left > 0.0:
		return false
	_wave_progress_flush_time_left = WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS
	flush_pending_wave_progress()
	return true


func flush_pending_wave_progress() -> void:
	if not is_host_authority() or _pending_wave_progress.is_empty():
		return
	wave_progress_broadcast_requested.emit(
		_pending_wave_progress.duplicate(),
		false
	)
	_pending_wave_progress.clear()


func broadcast_wave_progress_keyframe() -> void:
	if not is_host_authority():
		return
	var snapshot := get_wave_progress_snapshot()
	if snapshot.is_empty():
		return
	wave_progress_broadcast_requested.emit(snapshot, true)


func get_wave_progress_snapshot() -> Dictionary:
	if not is_bound() or not _mode_adapter.supports_multiplayer_wave_progress():
		return {}
	return _mode_adapter.get_wave_progress_snapshot().duplicate()


func get_flow_state_snapshot() -> Dictionary:
	if not is_bound():
		return {}
	return _mode_adapter.get_flow_state_snapshot().duplicate()


func has_received_flow_state() -> bool:
	return _client_has_received_flow_state


func update_client_enemy_count() -> bool:
	if not is_client_view():
		return false
	var remote_enemy_count := _enemy_coordinator.get_remote_enemy_count()
	if remote_enemy_count == _last_applied_remote_enemy_count:
		return false
	_last_applied_remote_enemy_count = remote_enemy_count
	_mode_adapter.apply_remote_enemy_count(remote_enemy_count)
	return true


func receive_merchant_active(active: bool) -> void:
	if not is_client_view():
		return
	_mode_adapter.apply_remote_merchant_active(active)


func receive_flow_state(
	step_id: StringName,
	state: int,
	countdown_seconds: int
) -> void:
	if not is_client_view():
		return
	_client_has_received_flow_state = true
	# A flow transition can reuse the same numerical count while replacing the
	# active HUD. Force one repaint on the following client frame.
	_last_applied_remote_enemy_count = -1
	_mode_adapter.apply_remote_flow_state(step_id, state, countdown_seconds)


func receive_boss_started(
	net_id: int,
	boss_config_path: String,
	spawn_position: Vector2,
	now: float
) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or boss_config_path.is_empty()
	):
		return
	var boss_config := load(boss_config_path) as BossConfig
	if boss_config == null:
		return
	_mode_adapter.apply_remote_boss_started(
		net_id,
		boss_config,
		spawn_position
	)
	var boss_enemy := _runtime.get_enemy_for_net_id(net_id)
	if boss_enemy != null and is_instance_valid(boss_enemy):
		_enemy_coordinator.register_client_enemy(net_id, boss_enemy, now)


func receive_defeat(failure_reason: String) -> void:
	if not is_client_view():
		return
	terminal_flow_started.emit()
	_mode_adapter.apply_remote_defeat_with_reason(failure_reason)


func receive_victory() -> void:
	if not is_client_view():
		return
	terminal_flow_started.emit()
	_mode_adapter.apply_remote_victory()


func receive_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	if not is_client_view() or not supports_wave_progress():
		return
	_mode_adapter.apply_remote_wave_progress(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


func build_live_pickup_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	if not is_host_authority():
		return records
	var sorted_ids: Array[int] = []
	for net_id_variant in _runtime.multiplayer_pickups.keys():
		sorted_ids.append(int(net_id_variant))
	sorted_ids.sort()
	for net_id in sorted_ids:
		var pickup_variant: Variant = _runtime.multiplayer_pickups.get(net_id)
		if pickup_variant == null or not is_instance_valid(pickup_variant):
			continue
		var pickup := pickup_variant as Pickup
		if (
			pickup == null
			or pickup.config == null
			or pickup.config.resource_path.is_empty()
		):
			continue
		records.append({
			"net_id": net_id,
			"config_path": pickup.config.resource_path,
			"position": pickup.global_position,
		})
	return records


func receive_pickup_removed(net_id: int) -> void:
	if not is_client_view() or net_id <= 0:
		return
	var pickup := _runtime.get_pickup_for_net_id(net_id)
	_runtime.multiplayer_pickups.erase(net_id)
	if pickup != null and is_instance_valid(pickup):
		pickup.queue_free()


func receive_pickup_spawned(
	net_id: int,
	config_path: String,
	spawn_position: Vector2
) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or config_path.is_empty()
		or _runtime.get_pickup_for_net_id(net_id) != null
		or _runtime.enemy_container == null
	):
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	if pickup == null:
		return
	pickup.config = pickup_config
	_runtime.enemy_container.add_child(pickup)
	pickup.global_position = spawn_position
	pickup.set_meta("net_id", net_id)
	pickup.collision_layer = 0
	pickup.collision_mask = 0
	_runtime.multiplayer_pickups[net_id] = pickup


func reset_session_state() -> void:
	_pending_wave_progress.clear()
	_wave_progress_flush_time_left = WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS
	_client_has_received_flow_state = false
	_last_applied_remote_enemy_count = -1


func get_state_metrics() -> Dictionary:
	return {
		"pending_wave_progress": _pending_wave_progress.size(),
		"wave_progress_flush_time_left": _wave_progress_flush_time_left,
		"client_has_received_flow_state": _client_has_received_flow_state,
		"last_applied_remote_enemy_count": _last_applied_remote_enemy_count,
	}


func _connect_runtime_signals() -> void:
	if not is_host_authority():
		return
	_connect_signal(
		_mode_adapter.merchant_active_changed,
		_on_host_merchant_active_changed
	)
	_connect_signal(
		_mode_adapter.flow_state_changed,
		_on_host_flow_state_changed
	)
	_connect_signal(_mode_adapter.boss_started, _on_host_boss_started)
	_connect_signal(_mode_adapter.defeat_started, _on_host_defeat_started)
	_connect_signal(_mode_adapter.victory_started, _on_host_victory_started)
	_connect_signal(
		_mode_adapter.wave_progress_changed,
		_on_host_wave_progress_changed
	)
	_connect_signal(_gameplay_gateway.pickup_spawned, _on_host_pickup_spawned)
	_connect_signal(_gameplay_gateway.pickup_removed, _on_host_pickup_removed)


func _disconnect_runtime_signals() -> void:
	if _mode_adapter != null and is_instance_valid(_mode_adapter):
		_disconnect_signal(
			_mode_adapter.merchant_active_changed,
			_on_host_merchant_active_changed
		)
		_disconnect_signal(
			_mode_adapter.flow_state_changed,
			_on_host_flow_state_changed
		)
		_disconnect_signal(_mode_adapter.boss_started, _on_host_boss_started)
		_disconnect_signal(_mode_adapter.defeat_started, _on_host_defeat_started)
		_disconnect_signal(_mode_adapter.victory_started, _on_host_victory_started)
		_disconnect_signal(
			_mode_adapter.wave_progress_changed,
			_on_host_wave_progress_changed
		)
	if _gameplay_gateway != null and is_instance_valid(_gameplay_gateway):
		_disconnect_signal(
			_gameplay_gateway.pickup_spawned,
			_on_host_pickup_spawned
		)
		_disconnect_signal(
			_gameplay_gateway.pickup_removed,
			_on_host_pickup_removed
		)


func _on_host_pickup_spawned(
	net_id: int,
	pickup_config: PickupConfig,
	spawn_position: Vector2
) -> void:
	if not is_host_authority() or pickup_config == null:
		return
	pickup_spawn_broadcast_requested.emit(
		net_id,
		pickup_config.resource_path,
		spawn_position
	)


func _on_host_pickup_removed(net_id: int) -> void:
	if not is_host_authority() or net_id <= 0:
		return
	pickup_remove_broadcast_requested.emit(net_id)


func _on_host_merchant_active_changed(active: bool) -> void:
	if not is_host_authority():
		return
	merchant_active_broadcast_requested.emit(active)


func _on_host_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	if not is_host_authority() or not supports_wave_progress():
		return
	_pending_wave_progress = {
		"wave_number": wave_number,
		"defeated": defeated,
		"escaped": escaped,
		"resolved": resolved,
		"total": total,
	}


func _on_host_flow_state_changed(
	step_id: StringName,
	state: int,
	countdown_seconds: int
) -> void:
	if not is_host_authority():
		return
	flush_pending_wave_progress()
	broadcast_wave_progress_keyframe()
	flow_state_broadcast_requested.emit(
		step_id,
		state,
		countdown_seconds
	)


func _on_host_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	if not is_host_authority() or boss_config == null:
		return
	boss_started_broadcast_requested.emit(
		net_id,
		boss_config.resource_path,
		spawn_position
	)


func _on_host_defeat_started() -> void:
	if not is_host_authority():
		return
	terminal_flow_started.emit()
	defeat_broadcast_requested.emit(
		_mode_adapter.get_multiplayer_defeat_reason()
	)


func _on_host_victory_started() -> void:
	if not is_host_authority():
		return
	terminal_flow_started.emit()
	victory_broadcast_requested.emit()


static func _connect_signal(source: Signal, target: Callable) -> void:
	if not source.is_connected(target):
		source.connect(target)


static func _disconnect_signal(source: Signal, target: Callable) -> void:
	if source.is_connected(target):
		source.disconnect(target)
