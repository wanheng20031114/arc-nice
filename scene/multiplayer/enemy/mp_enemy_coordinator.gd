extends Node
class_name MpEnemyCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const _CombatTargetIndex := preload("res://scene/combat/targeting/combat_target_index.gd")

const GAME_RUNTIME_CLIENT_VIEW := 2
# v26 起使用上一发送状态作为 delta 基线；缺席后回归的 peer 会促使共享 cohort 发 full。
const SHARED_SNAPSHOT_COHORT_ID := -1
const ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
# 完整敌人记录为 24 bytes，46 条连同计数仍低于项目 1200-byte 预算。
const ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES := 46
const ENEMY_HIGH_PRESSURE_THRESHOLD := 200
const ENEMY_HIGH_PRESSURE_SNAPSHOT_HZ := 20
const CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_HZ := 15.0
const CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_PHASE_COUNT := 64
# 离屏代理保留完整逻辑快照，只按稳定 net-id 相位降低视觉插值频率。
const CLIENT_PROXY_VISUAL_BUDGET_INTERVAL_SECONDS := 0.2
const CLIENT_PROXY_VISUAL_BUDGET_MARGIN := 192.0
const ENEMY_SPAWN_BATCH_MAX_RECORDS := 16
const COMBAT_FEEDBACK_MAX_RECORDS_PER_PACKET := 40
const COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS := 0.05
const CLIENT_PENDING_ENEMY_ACTION_MAX_ENTRIES := 512
const CLIENT_PENDING_ENEMY_ACTION_MAX_AGE_SECONDS := 5.0
const CLIENT_TERMINAL_ENEMY_TOMBSTONE_MAX_ENTRIES := 512
const ENEMY_CONFIG_PATH_WIRE_MAX_LENGTH := 512
const ENEMY_ACTION_NAME_WIRE_MAX_LENGTH := 128
const LIGHTNING_SORCERER_CHAIN_MIN_POINTS := 2
const LIGHTNING_SORCERER_CHAIN_MAX_POINTS := 6

const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
const CLIENT_ENEMY_ACTION_KIND_GENERIC := 0
const CLIENT_ENEMY_ACTION_KIND_TARGET := 1

signal remote_enemy_spawned(enemy: Enemy)
signal remote_enemy_escape_requested(net_id: int)
signal lifecycle_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
)
signal lifecycle_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
)
signal damage_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
)
signal enemy_snapshot_send_requested(
	peer_id: int,
	host_timestamp: float,
	data: PackedByteArray,
	batch_id: int,
	chunk_index: int,
	chunk_count: int,
	snapshot_hz: int,
	entity_count: int
)


class HostSnapshotChunk:
	extends RefCounted

	var chunk_index := 0
	var data := PackedByteArray()
	var entity_count := 0


class HostSnapshotBatch:
	extends RefCounted

	var peer_ids: Array[int] = []
	var host_timestamp := 0.0
	var batch_id := 0
	var chunk_count := 0
	var snapshot_hz := _NetConstants.ENEMY_SNAPSHOT_HZ
	var chunks: Array[HostSnapshotChunk] = []

	func is_empty() -> bool:
		return peer_ids.is_empty() or chunks.is_empty() or batch_id <= 0


class SpawnBatch:
	extends RefCounted

	var net_ids := PackedInt32Array()
	var config_paths := PackedStringArray()
	var positions := PackedVector2Array()
	var spawn_times := PackedFloat64Array()

	func is_empty() -> bool:
		return net_ids.is_empty()


class DamageFeedbackBatch:
	extends RefCounted

	var net_ids := PackedInt32Array()
	var health_values := PackedInt32Array()
	var health_revisions := PackedInt32Array()
	var damage_values := PackedInt32Array()
	var directions := PackedVector2Array()
	var damage_types := PackedByteArray()
	var particle_flags := PackedByteArray()

	func is_empty() -> bool:
		return net_ids.is_empty()


var net_enemies: Dictionary[int, Enemy] = {}
var enemy_interpolators: Dictionary[int, NetInterpolator] = {}
var pending_enemy_damage_feedback: Dictionary = {}
var active_enemy_damage_feedback_context: Dictionary = {}
var pending_enemy_snapshot_batches: Dictionary = {}
# 未生成敌人的 CH7 动作共享一个有界 FIFO；同 net-id 只保留最新合法动作。
var pending_enemy_actions: Dictionary = {}
# 可靠终结可能越过旧 CH7 动作，墓碑阻止旧动作重新建立等待状态。
var client_terminal_enemy_ids: Dictionary = {}
# Host 仅保留 defeated→removed 的短生命周期配对标记，不形成会话级墓碑。
var host_terminal_enemy_ids: Dictionary = {}

var _runtime: CombatRuntimeBase = null
var _net_manager: NetManagerStore = null
var _gameplay_gateway: MultiplayerGameplayGateway = null
var _get_net_time_callable := Callable()
var _projectile_coordinator: MpProjectileCoordinator = null
var _damage_presentation_parent: Node2D = null
var _combat_feedback_flush_time_left: float = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
var _snapshot_manager := SnapshotManager.new()
var enemy_spawn_snapshot_times: Dictionary[int, float] = {}
var _stale_enemy_interpolator_ids: Array[int] = []
var _host_snapshot_batch_sequence := 0
var _host_snapshot_live_ids: Dictionary[int, bool] = {}
var _last_keyframe_time_by_peer: Dictionary[int, float] = {}
var _snapshot_cohort_peers: Dictionary[int, bool] = {}
# 会话级编码计数不会随单个 peer 离开而重置，仅在整场会话清理时归零。
var _snapshot_chunk_encode_count := 0
var _snapshot_batch_count := 0
var _snapshot_completed_batch_count := 0
var _snapshot_incomplete_batch_evict_count := 0
var _snapshot_stale_chunk_count := 0
var _last_completed_snapshot_batch_id := 0
var _latest_snapshot_batch_seen := 0
var _current_snapshot_hz := _NetConstants.ENEMY_SNAPSHOT_HZ
var _offscreen_interpolation_slots: Dictionary[int, int] = {}
var _offscreen_proxy_count := 0
var _proxy_visual_budget_time_left := 0.0
var _pending_enemy_action_previous_ids: Dictionary[int, int] = {}
var _pending_enemy_action_next_ids: Dictionary[int, int] = {}
var _pending_enemy_action_oldest_id := 0
var _pending_enemy_action_newest_id := 0
var _client_terminal_enemy_previous_ids: Dictionary[int, int] = {}
var _client_terminal_enemy_next_ids: Dictionary[int, int] = {}
var _client_terminal_enemy_oldest_id := 0
var _client_terminal_enemy_newest_id := 0
var _pending_host_spawns: Array[Dictionary] = []


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpEnemyCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	if _runtime != null:
		_clear_damage_dependencies()
		_clear_lifecycle_dependencies()
		reset_session_state()
	_runtime = runtime_instance


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_clear_damage_dependencies()
	_clear_lifecycle_dependencies()
	_runtime = null
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func bind_lifecycle_dependencies(
	net_manager_instance: NetManagerStore,
	gameplay_gateway_instance: MultiplayerGameplayGateway,
	get_net_time_callable: Callable
) -> void:
	assert(net_manager_instance != null, "MpEnemyCoordinator 缺少 NetManager。")
	assert(
		gameplay_gateway_instance != null,
		"MpEnemyCoordinator 缺少 MultiplayerGameplayGateway。"
	)
	assert(get_net_time_callable.is_valid(), "MpEnemyCoordinator 缺少网络时钟。")
	_disconnect_gameplay_gateway()
	_net_manager = net_manager_instance
	_gameplay_gateway = gameplay_gateway_instance
	_get_net_time_callable = get_net_time_callable
	_connect_gameplay_gateway()


func has_lifecycle_dependencies() -> bool:
	return (
		is_bound()
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _gameplay_gateway != null
		and is_instance_valid(_gameplay_gateway)
		and _get_net_time_callable.is_valid()
	)


func bind_damage_dependencies(
	projectile_coordinator_instance: MpProjectileCoordinator,
	presentation_parent_instance: Node2D
) -> void:
	assert(
		projectile_coordinator_instance != null,
		"MpEnemyCoordinator 缺少 MpProjectileCoordinator。"
	)
	assert(
		presentation_parent_instance != null,
		"MpEnemyCoordinator 缺少敌人伤害表现父节点。"
	)
	_projectile_coordinator = projectile_coordinator_instance
	_damage_presentation_parent = presentation_parent_instance


func has_damage_dependencies() -> bool:
	return (
		is_bound()
		and _projectile_coordinator != null
		and is_instance_valid(_projectile_coordinator)
		and _damage_presentation_parent != null
		and is_instance_valid(_damage_presentation_parent)
	)


func _connect_gameplay_gateway() -> void:
	if _gameplay_gateway == null or not is_instance_valid(_gameplay_gateway):
		return
	if not _gameplay_gateway.enemy_spawned.is_connected(
		_on_gameplay_enemy_spawned
	):
		_gameplay_gateway.enemy_spawned.connect(_on_gameplay_enemy_spawned)
	if not _gameplay_gateway.enemy_defeated.is_connected(
		_on_gameplay_enemy_defeated
	):
		_gameplay_gateway.enemy_defeated.connect(_on_gameplay_enemy_defeated)
	if not _gameplay_gateway.enemy_removed.is_connected(
		_on_gameplay_enemy_removed
	):
		_gameplay_gateway.enemy_removed.connect(_on_gameplay_enemy_removed)
	if not _gameplay_gateway.enemy_escaped.is_connected(
		_on_gameplay_enemy_escaped
	):
		_gameplay_gateway.enemy_escaped.connect(_on_gameplay_enemy_escaped)


func _disconnect_gameplay_gateway() -> void:
	if _gameplay_gateway == null or not is_instance_valid(_gameplay_gateway):
		return
	if _gameplay_gateway.enemy_spawned.is_connected(_on_gameplay_enemy_spawned):
		_gameplay_gateway.enemy_spawned.disconnect(_on_gameplay_enemy_spawned)
	if _gameplay_gateway.enemy_defeated.is_connected(_on_gameplay_enemy_defeated):
		_gameplay_gateway.enemy_defeated.disconnect(_on_gameplay_enemy_defeated)
	if _gameplay_gateway.enemy_removed.is_connected(_on_gameplay_enemy_removed):
		_gameplay_gateway.enemy_removed.disconnect(_on_gameplay_enemy_removed)
	if _gameplay_gateway.enemy_escaped.is_connected(_on_gameplay_enemy_escaped):
		_gameplay_gateway.enemy_escaped.disconnect(_on_gameplay_enemy_escaped)


func _clear_lifecycle_dependencies() -> void:
	_disconnect_gameplay_gateway()
	_net_manager = null
	_gameplay_gateway = null
	_get_net_time_callable = Callable()


func _clear_damage_dependencies() -> void:
	_projectile_coordinator = null
	_damage_presentation_parent = null


func _is_host_lifecycle_bound() -> bool:
	return has_lifecycle_dependencies() and _net_manager.is_host()


func _get_network_time() -> float:
	if not _get_net_time_callable.is_valid():
		return -1.0
	var network_time := float(_get_net_time_callable.call())
	return network_time if is_finite(network_time) and network_time >= 0.0 else -1.0


func _on_gameplay_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if not _is_host_lifecycle_bound() or not is_inside_tree():
		return
	queue_host_spawn(
		net_id,
		enemy_config,
		spawn_position,
		_get_network_time()
	)


func _on_gameplay_enemy_defeated(
	net_id: int,
	defeat_position: Vector2
) -> void:
	broadcast_host_terminal(net_id, ENEMY_TERMINAL_DEFEATED, defeat_position)


func _on_gameplay_enemy_removed(net_id: int) -> void:
	broadcast_host_terminal(net_id, ENEMY_TERMINAL_REMOVED, Vector2.ZERO)


func _on_gameplay_enemy_escaped(net_id: int) -> void:
	broadcast_host_terminal(net_id, ENEMY_TERMINAL_ESCAPED, Vector2.ZERO)


func is_client_view() -> bool:
	return is_bound() and int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW


func get_snapshot_interval_frames() -> int:
	var enemy_count := _runtime.multiplayer_enemies_by_net_id.size() if is_bound() else 0
	var target_hz := (
		ENEMY_HIGH_PRESSURE_SNAPSHOT_HZ
		if enemy_count >= ENEMY_HIGH_PRESSURE_THRESHOLD
		else _NetConstants.ENEMY_SNAPSHOT_HZ
	)
	return maxi(roundi(float(_NetConstants.HOST_PHYSICS_HZ) / float(target_hz)), 1)


func sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	var ready_lookup: Dictionary[int, bool] = {}
	for peer_id in ready_peer_ids:
		if peer_id > 0:
			ready_lookup[peer_id] = true
	for peer_id_variant in _snapshot_cohort_peers.keys():
		var peer_id := int(peer_id_variant)
		if ready_lookup.has(peer_id):
			continue
		_snapshot_cohort_peers.erase(peer_id)
		_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_enemy_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func broadcast_host_enemy_snapshots(
	ready_peer_ids: Array[int],
	host_timestamp: float
) -> int:
	if not is_bound() or ready_peer_ids.is_empty():
		return 0
	var states: Array[SnapshotManager.EnemyState] = (
		_runtime.collect_enemy_snapshot_states()
	)
	var batch := build_host_snapshot_batch(
		states,
		ready_peer_ids,
		host_timestamp
	)
	if batch == null or batch.is_empty():
		return 0
	var send_count := 0
	for chunk in batch.chunks:
		for peer_id in batch.peer_ids:
			enemy_snapshot_send_requested.emit(
				peer_id,
				batch.host_timestamp,
				chunk.data,
				batch.batch_id,
				chunk.chunk_index,
				batch.chunk_count,
				batch.snapshot_hz,
				chunk.entity_count
			)
			send_count += 1
	return send_count


func build_host_snapshot_batch(
	states: Array[SnapshotManager.EnemyState],
	ready_peer_ids: Array[int],
	host_timestamp: float
) -> HostSnapshotBatch:
	if not is_bound() or ready_peer_ids.is_empty():
		return null
	if not SnapshotManager.are_enemy_snapshot_states_serializable(states):
		push_error("MpEnemyCoordinator: 敌人快照含越界战斗值，已拒绝整个发送批次。")
		return null
	var interval_frames := get_snapshot_interval_frames()
	var snapshot_hz := maxi(
		roundi(float(_NetConstants.HOST_PHYSICS_HZ) / float(interval_frames)),
		1
	)
	_host_snapshot_batch_sequence += 1
	var batch := HostSnapshotBatch.new()
	batch.peer_ids.assign(ready_peer_ids)
	batch.host_timestamp = host_timestamp
	batch.batch_id = _host_snapshot_batch_sequence
	batch.snapshot_hz = snapshot_hz
	batch.chunk_count = maxi(
		ceili(float(states.size()) / float(ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES)),
		1
	)
	_host_snapshot_live_ids.clear()
	for state in states:
		if state != null and state.net_id > 0:
			_host_snapshot_live_ids[state.net_id] = true
	var force_keyframe := _snapshot_cohort_requires_keyframe(
		ready_peer_ids,
		host_timestamp
	)
	_snapshot_batch_count += ready_peer_ids.size()
	for chunk_index in range(batch.chunk_count):
		var chunk_start := chunk_index * ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
		var chunk_end := mini(
			chunk_start + ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES,
			states.size()
		)
		var chunk := HostSnapshotChunk.new()
		chunk.chunk_index = chunk_index
		chunk.entity_count = chunk_end - chunk_start
		chunk.data = _snapshot_manager.encode_enemy_snapshot_range_for_cohort(
			SHARED_SNAPSHOT_COHORT_ID,
			states,
			chunk_start,
			chunk.entity_count,
			force_keyframe
		)
		_snapshot_chunk_encode_count += 1
		batch.chunks.append(chunk)
	_snapshot_manager.prune_enemy_send_cohort_baseline_to_ids(
		SHARED_SNAPSHOT_COHORT_ID,
		_host_snapshot_live_ids
	)
	_commit_snapshot_cohort_send(ready_peer_ids, host_timestamp, force_keyframe)
	return batch


func apply_authoritative_snapshot(
	snapshot_time: float,
	data: PackedByteArray,
	batch_id: int,
	chunk_index: int,
	chunk_count: int,
	snapshot_hz: int
) -> void:
	if not is_client_view():
		return
	var is_chunked_batch := batch_id > 0
	if is_chunked_batch and (chunk_count <= 0 or chunk_index < 0 or chunk_index >= chunk_count):
		return
	if is_chunked_batch and batch_id <= _last_completed_snapshot_batch_id:
		_snapshot_stale_chunk_count += 1
		return
	if is_chunked_batch and batch_id < _latest_snapshot_batch_seen:
		_snapshot_stale_chunk_count += 1
		return
	if is_chunked_batch:
		_latest_snapshot_batch_seen = maxi(_latest_snapshot_batch_seen, batch_id)
	_update_snapshot_hz(snapshot_hz)
	var batch: Dictionary = {}
	if is_chunked_batch:
		_prune_old_snapshot_batches(batch_id)
		batch = pending_enemy_snapshot_batches.get(batch_id, {}) as Dictionary
		if batch.is_empty():
			batch = {
				"chunk_count": chunk_count,
				"received": {},
				"seen": {},
				"snapshot_time": snapshot_time,
			}
			pending_enemy_snapshot_batches[batch_id] = batch
		elif int(batch.get("chunk_count", 0)) != chunk_count:
			pending_enemy_snapshot_batches.erase(batch_id)
			return
		var received := batch["received"] as Dictionary
		if received.has(chunk_index):
			return
	var states := _snapshot_manager.decode_enemy_snapshots_with_baseline(
		data,
		not is_chunked_batch
	)
	var snapshot_has_full_roster := _is_complete_snapshot_chunk(data, states.size())
	var seen_enemy_ids: Dictionary = {}
	if is_chunked_batch:
		seen_enemy_ids = batch["seen"] as Dictionary
	for state in states:
		var enemy_state := state as SnapshotManager.EnemyState
		if enemy_state == null or enemy_state.net_id <= 0:
			continue
		seen_enemy_ids[enemy_state.net_id] = true
		if enemy_state.is_dead:
			var dead_enemy := get_valid_client_enemy(enemy_state.net_id)
			if dead_enemy != null and is_instance_valid(dead_enemy):
				dead_enemy.global_position = enemy_state.position
				apply_network_health(
					dead_enemy,
					enemy_state.health,
					enemy_state.health_revision
				)
			remove_client_enemy(enemy_state.net_id, true)
			continue
		var interpolator := enemy_interpolators.get(
			enemy_state.net_id
		) as NetInterpolator
		if interpolator == null:
			interpolator = _create_interpolator()
			enemy_interpolators[enemy_state.net_id] = interpolator
		interpolator.push_snapshot(
			snapshot_time,
			enemy_state.position,
			enemy_state.velocity,
			0,
			enemy_state.locomotion_state,
			enemy_state.health,
			enemy_state.is_dead
		)
		var enemy_node := get_valid_client_enemy(enemy_state.net_id)
		if enemy_node != null and is_instance_valid(enemy_node):
			apply_network_health(
				enemy_node,
				enemy_state.health,
				enemy_state.health_revision
			)
			enemy_node.is_dead = enemy_state.is_dead
			enemy_node.apply_multiplayer_visual_status_mask(
				enemy_state.visual_status_mask
			)
	if not is_chunked_batch:
		if snapshot_has_full_roster:
			reconcile_roster(seen_enemy_ids, snapshot_time)
		return
	if not snapshot_has_full_roster:
		return
	var received := batch["received"] as Dictionary
	received[chunk_index] = true
	if received.size() != chunk_count:
		return
	_snapshot_manager.prune_enemy_receive_baseline_to_ids(seen_enemy_ids)
	_snapshot_completed_batch_count += 1
	_last_completed_snapshot_batch_id = batch_id
	_discard_snapshot_batches_through(batch_id)
	reconcile_roster(
		seen_enemy_ids,
		float(batch.get("snapshot_time", snapshot_time))
	)


func interpolate_remote_enemies(current_time: float) -> void:
	if not is_client_view():
		return
	_stale_enemy_interpolator_ids.clear()
	for net_id_variant in enemy_interpolators:
		var net_id := int(net_id_variant)
		var interpolator := enemy_interpolators.get(net_id) as NetInterpolator
		var enemy_node := net_enemies.get(net_id) as Enemy
		if (
			interpolator == null
			or enemy_node == null
			or not is_instance_valid(enemy_node)
		):
			_stale_enemy_interpolator_ids.append(net_id)
			continue
		if not _should_interpolate_proxy(net_id, enemy_node, current_time):
			continue
		var frame_state := interpolator.get_current_state(current_time)
		enemy_node.apply_multiplayer_proxy_motion(
			interpolator.get_interpolated_position(current_time),
			interpolator.get_interpolated_velocity(current_time),
			frame_state.anim_state
		)
	for stale_net_id in _stale_enemy_interpolator_ids:
		get_valid_client_enemy(stale_net_id)
		enemy_interpolators.erase(stale_net_id)
		_offscreen_interpolation_slots.erase(stale_net_id)


func update_proxy_visual_budget(delta: float) -> void:
	_proxy_visual_budget_time_left = maxf(
		_proxy_visual_budget_time_left - maxf(delta, 0.0),
		0.0
	)
	if _proxy_visual_budget_time_left > 0.0 or not is_bound():
		return
	_proxy_visual_budget_time_left = CLIENT_PROXY_VISUAL_BUDGET_INTERVAL_SECONDS
	var viewport := _runtime.get_viewport()
	var camera: Camera2D = null
	if viewport != null:
		camera = viewport.get_camera_2d()
	if camera == null:
		_offscreen_proxy_count = 0
		for enemy_variant in net_enemies.values():
			var enemy := enemy_variant as Enemy
			if enemy != null and is_instance_valid(enemy):
				enemy.set_multiplayer_proxy_visual_active(true)
		return
	var viewport_size := viewport.get_visible_rect().size
	var safe_zoom := Vector2(
		maxf(absf(camera.zoom.x), 0.001),
		maxf(absf(camera.zoom.y), 0.001)
	)
	var visible_world_size := Vector2(
		viewport_size.x / safe_zoom.x,
		viewport_size.y / safe_zoom.y
	)
	var margin_vector := Vector2.ONE * CLIENT_PROXY_VISUAL_BUDGET_MARGIN
	var active_rect := Rect2(
		camera.get_screen_center_position() - visible_world_size * 0.5 - margin_vector,
		visible_world_size + margin_vector * 2.0
	)
	var offscreen_count := 0
	for enemy_variant in net_enemies.values():
		var enemy := enemy_variant as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var visual_active := active_rect.has_point(enemy.global_position)
		enemy.set_multiplayer_proxy_visual_active(visual_active)
		if not visual_active:
			offscreen_count += 1
	_offscreen_proxy_count = offscreen_count


func build_live_spawn_batches(host_timestamp: float) -> Array[SpawnBatch]:
	var batches: Array[SpawnBatch] = []
	if not is_bound() or not is_finite(host_timestamp) or host_timestamp < 0.0:
		return batches
	var sorted_ids: Array[int] = []
	for net_id_variant in _runtime.multiplayer_enemies_by_net_id.keys():
		sorted_ids.append(int(net_id_variant))
	sorted_ids.sort()
	for chunk_start in range(0, sorted_ids.size(), ENEMY_SPAWN_BATCH_MAX_RECORDS):
		var batch := SpawnBatch.new()
		var chunk_end := mini(
			chunk_start + ENEMY_SPAWN_BATCH_MAX_RECORDS,
			sorted_ids.size()
		)
		for record_index in range(chunk_start, chunk_end):
			var net_id := sorted_ids[record_index]
			var enemy := _runtime.multiplayer_enemies_by_net_id.get(net_id) as Enemy
			if (
				net_id <= 0
				or not _NetConstants.is_valid_network_combat_value(net_id)
				or enemy == null
				or not is_instance_valid(enemy)
				or enemy.is_dead
				or enemy is LinglanBoss
				or enemy.config == null
				or enemy.config.resource_path.is_empty()
				or not enemy.global_position.is_finite()
			):
				continue
			batch.net_ids.append(net_id)
			batch.config_paths.append(enemy.config.resource_path)
			batch.positions.append(enemy.global_position)
			batch.spawn_times.append(host_timestamp)
		if not batch.is_empty():
			batches.append(batch)
	return batches


func send_live_spawn_roster_to_peer(peer_id: int) -> void:
	if not _is_host_lifecycle_bound() or peer_id <= 0:
		return
	var host_timestamp := _get_network_time()
	if host_timestamp < 0.0:
		return
	for batch in build_live_spawn_batches(host_timestamp):
		lifecycle_rpc_to_peer_requested.emit(
			peer_id,
			&"net_enemy_spawned_batch",
			[
				batch.net_ids,
				batch.config_paths,
				batch.positions,
				batch.spawn_times,
			]
		)


func receive_enemy_spawn_packet(
	net_id: int,
	config_path: String,
	spawn_position: Vector2,
	host_spawn_timestamp: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	if not _is_valid_spawn_record(
		net_id,
		config_path,
		spawn_position,
		host_spawn_timestamp
	):
		return
	var mapped_spawn_time := _map_remote_timestamp(
		host_spawn_timestamp,
		local_net_time,
		has_host_time_offset,
		host_to_client_time_offset
	)
	if not is_finite(mapped_spawn_time):
		return
	receive_enemy_spawn(
		net_id,
		config_path,
		spawn_position,
		mapped_spawn_time,
		local_net_time
	)


func receive_enemy_spawn_batch(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	if not _is_valid_spawn_batch_payload(
		net_ids,
		config_paths,
		positions,
		spawn_times
	):
		return
	for record_index in range(net_ids.size()):
		receive_enemy_spawn_packet(
			net_ids[record_index],
			config_paths[record_index],
			positions[record_index],
			spawn_times[record_index],
			local_net_time,
			has_host_time_offset,
			host_to_client_time_offset
		)


func receive_enemy_spawn(
	net_id: int,
	config_path: String,
	spawn_position: Vector2,
	mapped_spawn_time: float,
	current_time: float
) -> void:
	if (
		not is_client_view()
		or not _is_valid_spawn_record(
			net_id,
			config_path,
			spawn_position,
			mapped_spawn_time
		)
		or not is_finite(current_time)
	):
		return
	var existing_enemy := get_valid_client_enemy(net_id)
	if (
		existing_enemy != null
		and not existing_enemy.is_dead
		and existing_enemy.config != null
		and existing_enemy.config.resource_path == config_path
	):
		clear_client_terminal_marker(net_id)
		consume_pending_enemy_action(net_id, current_time)
		return
	remove_client_enemy(net_id, false, true, true)
	var enemy_config := load(config_path) as EnemyConfig
	if enemy_config == null or enemy_config.enemy_scene == null:
		return
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy == null:
		return
	_runtime.enemy_container.add_child(enemy)
	enemy_spawn_snapshot_times[net_id] = mapped_spawn_time
	enemy.global_position = get_buffered_enemy_position(
		net_id,
		spawn_position,
		current_time
	)
	enemy.setup(
		enemy_config,
		_runtime.player,
		_runtime.grid_pathfinder,
		_runtime
	)
	remote_enemy_spawned.emit(enemy)
	enemy.configure_multiplayer_proxy()
	enemy.set_meta("net_id", net_id)
	_register_client_enemy(net_id, enemy)
	clear_client_terminal_marker(net_id)
	consume_pending_enemy_action(net_id, current_time)
	_runtime.play_remote_enemy_spawn_effect(spawn_position)


func register_client_enemy(
	net_id: int,
	enemy: Enemy,
	current_time: float
) -> void:
	if net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return
	_register_client_enemy(net_id, enemy)
	clear_client_terminal_marker(net_id)
	consume_pending_enemy_action(net_id, current_time)


func queue_host_spawn(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	spawn_time: float
) -> void:
	if (
		not is_bound()
		or enemy_config == null
		or not _is_valid_spawn_record(
			net_id,
			enemy_config.resource_path,
			spawn_position,
			spawn_time
		)
	):
		return
	_pending_host_spawns.append({
		"net_id": net_id,
		"config_path": enemy_config.resource_path,
		"position": spawn_position,
		"spawn_time": spawn_time,
	})


func drain_host_spawn_batches() -> Array[SpawnBatch]:
	var batches: Array[SpawnBatch] = []
	if _pending_host_spawns.is_empty():
		return batches
	var records := _pending_host_spawns.duplicate(true)
	_pending_host_spawns.clear()
	for chunk_start in range(0, records.size(), ENEMY_SPAWN_BATCH_MAX_RECORDS):
		var batch := SpawnBatch.new()
		var chunk_end := mini(
			chunk_start + ENEMY_SPAWN_BATCH_MAX_RECORDS,
			records.size()
		)
		for record_index in range(chunk_start, chunk_end):
			var record := records[record_index] as Dictionary
			batch.net_ids.append(int(record.get("net_id", 0)))
			batch.config_paths.append(String(record.get("config_path", "")))
			batch.positions.append(record.get("position", Vector2.ZERO) as Vector2)
			batch.spawn_times.append(float(record.get("spawn_time", 0.0)))
		if not batch.is_empty():
			batches.append(batch)
	return batches


func update_host() -> void:
	if not _is_host_lifecycle_bound():
		return
	for batch in drain_host_spawn_batches():
		lifecycle_rpc_broadcast_requested.emit(
			&"net_enemy_spawned_batch",
			[
				batch.net_ids,
				batch.config_paths,
				batch.positions,
				batch.spawn_times,
			]
		)


func build_host_terminal_event(
	net_id: int,
	reason: int,
	event_position: Vector2
) -> Dictionary:
	if (
		not _NetConstants.is_valid_network_combat_value(net_id)
		or net_id <= 0
		or not event_position.is_finite()
		or not _is_valid_terminal_reason(reason)
	):
		return {}
	if reason == ENEMY_TERMINAL_DEFEATED and host_terminal_enemy_ids.has(net_id):
		return {}
	if reason == ENEMY_TERMINAL_REMOVED and host_terminal_enemy_ids.erase(net_id):
		return {}
	var feedback := collect_terminal_feedback(net_id) if reason == ENEMY_TERMINAL_DEFEATED else {}
	for key in ["current_health", "health_revision", "damage"]:
		if not _NetConstants.is_valid_network_combat_value(int(feedback.get(key, 0))):
			push_error("MpEnemyCoordinator: 敌人终结事件超出网络 signed int32 契约。")
			return {}
	if (
		not (feedback.get("impact_direction", Vector2.ZERO) as Vector2).is_finite()
		or not _is_valid_damage_type(int(feedback.get(
			"damage_type",
			EnemyConfig.DamageType.PHYSICAL
		)))
	):
		return {}
	match reason:
		ENEMY_TERMINAL_DEFEATED:
			host_terminal_enemy_ids[net_id] = true
		ENEMY_TERMINAL_REMOVED:
			host_terminal_enemy_ids.erase(net_id)
		ENEMY_TERMINAL_ESCAPED:
			host_terminal_enemy_ids.erase(net_id)
	return {
		"net_id": net_id,
		"reason": reason,
		"event_position": event_position,
		"current_health": int(feedback.get("current_health", 0)),
		"health_revision": int(feedback.get("health_revision", 0)),
		"damage": int(feedback.get("damage", 0)),
		"impact_direction": feedback.get("impact_direction", Vector2.ZERO),
		"damage_type": int(feedback.get("damage_type", EnemyConfig.DamageType.PHYSICAL)),
		"show_hit_particles": bool(feedback.get("show_hit_particles", false)),
	}


func broadcast_host_terminal(
	net_id: int,
	reason: int,
	event_position: Vector2
) -> void:
	if not _is_host_lifecycle_bound() or not is_inside_tree():
		return
	var terminal := build_host_terminal_event(net_id, reason, event_position)
	if terminal.is_empty():
		return
	lifecycle_rpc_broadcast_requested.emit(
		&"net_enemy_terminal",
		[
			int(terminal.get("net_id", 0)),
			int(terminal.get("reason", ENEMY_TERMINAL_REMOVED)),
			terminal.get("event_position", Vector2.ZERO) as Vector2,
			int(terminal.get("current_health", 0)),
			int(terminal.get("health_revision", 0)),
			int(terminal.get("damage", 0)),
			terminal.get("impact_direction", Vector2.ZERO) as Vector2,
			int(terminal.get("damage_type", EnemyConfig.DamageType.PHYSICAL)),
			bool(terminal.get("show_hit_particles", false)),
		]
	)


func receive_enemy_terminal(
	net_id: int,
	reason: int,
	event_position: Vector2,
	current_health: int,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	show_hit_particles: bool
) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
		or not _is_valid_terminal_reason(reason)
		or not event_position.is_finite()
		or not impact_direction.is_finite()
		or not _is_valid_damage_type(damage_type)
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		return
	mark_client_terminal(net_id)
	match reason:
		ENEMY_TERMINAL_DEFEATED:
			var enemy := get_valid_client_enemy(net_id)
			if enemy != null and is_instance_valid(enemy):
				enemy.global_position = event_position
				apply_network_health(enemy, current_health, health_revision)
				if confirmed_damage > 0:
					enemy.show_damage_number(
						confirmed_damage,
						impact_direction,
						damage_type as EnemyConfig.DamageType
					)
					if impact_direction != Vector2.ZERO:
						enemy.play_multiplayer_damage_feedback(
							impact_direction,
							show_hit_particles
						)
			remove_client_enemy(net_id, true)
		ENEMY_TERMINAL_ESCAPED:
			remote_enemy_escape_requested.emit(net_id)
			remove_client_enemy(net_id, false)
		_:
			remove_client_enemy(net_id, false)


func receive_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
		or not defeat_position.is_finite()
	):
		return
	mark_client_terminal(net_id)
	var enemy := get_valid_client_enemy(net_id)
	if enemy != null and is_instance_valid(enemy):
		enemy.global_position = defeat_position
	remove_client_enemy(net_id, true)


func receive_enemy_removed(net_id: int) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
	):
		return
	mark_client_terminal(net_id)
	remove_client_enemy(net_id, true)


func receive_enemy_escaped(net_id: int) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
	):
		return
	mark_client_terminal(net_id)
	remote_enemy_escape_requested.emit(net_id)
	remove_client_enemy(net_id, false)


func broadcast_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void:
	if not _is_host_lifecycle_bound():
		return
	var host_action_time := _get_network_time()
	var record := {
		"kind": CLIENT_ENEMY_ACTION_KIND_GENERIC,
		"net_id": net_id,
		"action_name": action_name,
		"direction": direction,
		"action_position": action_position,
		"action_id": action_id,
		"action_time": host_action_time,
		"host_action_timestamp": host_action_time,
	}
	if not _is_valid_action_record(record):
		return
	lifecycle_rpc_broadcast_requested.emit(
		&"net_enemy_action",
		[
			net_id,
			String(action_name),
			direction,
			action_position,
			action_id,
			host_action_time,
		]
	)


func broadcast_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int
) -> void:
	if not _is_host_lifecycle_bound():
		return
	var host_action_time := _get_network_time()
	var record := {
		"kind": CLIENT_ENEMY_ACTION_KIND_TARGET,
		"net_id": net_id,
		"action_name": action_name,
		"target_peer_id": target_peer_id,
		"action_position": action_position,
		"action_id": action_id,
		"action_time": host_action_time,
		"host_action_timestamp": host_action_time,
	}
	if not _is_valid_action_record(record):
		return
	lifecycle_rpc_broadcast_requested.emit(
		&"net_enemy_target_action",
		[
			net_id,
			String(action_name),
			target_peer_id,
			action_position,
			action_id,
			host_action_time,
		]
	)


func broadcast_enemy_lightning_chain(points: PackedVector2Array) -> void:
	if not _is_host_lifecycle_bound() or not _is_valid_lightning_chain(points):
		return
	lifecycle_rpc_broadcast_requested.emit(
		&"net_enemy_lightning_chain",
		[points]
	)


func receive_enemy_action_packet(
	net_id: int,
	action_name: String,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	var mapped_action_time := _resolve_remote_action_time(
		host_action_timestamp,
		local_net_time,
		has_host_time_offset,
		host_to_client_time_offset
	)
	if not is_finite(mapped_action_time):
		return
	receive_enemy_action(
		net_id,
		StringName(action_name),
		direction,
		action_position,
		action_id,
		mapped_action_time,
		local_net_time,
		host_action_timestamp
	)


func receive_enemy_target_action_packet(
	net_id: int,
	action_name: String,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	var mapped_action_time := _resolve_remote_action_time(
		host_action_timestamp,
		local_net_time,
		has_host_time_offset,
		host_to_client_time_offset
	)
	if not is_finite(mapped_action_time):
		return
	receive_enemy_target_action(
		net_id,
		StringName(action_name),
		target_peer_id,
		action_position,
		action_id,
		mapped_action_time,
		local_net_time,
		host_action_timestamp
	)


func receive_enemy_lightning_chain(points: PackedVector2Array) -> void:
	if not is_client_view() or not _is_valid_lightning_chain(points):
		return
	# Damage and target selection stay authoritative. Clients replay only VFX.
	_runtime.play_lightning_sorcerer_chain_vfx(points)


func _map_remote_timestamp(
	host_timestamp: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> float:
	if (
		not is_finite(host_timestamp)
		or host_timestamp < 0.0
		or not is_finite(local_net_time)
	):
		return NAN
	if not has_host_time_offset:
		return local_net_time
	if not is_finite(host_to_client_time_offset):
		return NAN
	return host_timestamp + host_to_client_time_offset


func _resolve_remote_action_time(
	host_action_timestamp: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> float:
	if not is_finite(host_action_timestamp) or not is_finite(local_net_time):
		return NAN
	# v49 keeps the optional -1 timestamp default for compatibility with the
	# original CH7 action façade. Such packets replay from their receive time.
	if host_action_timestamp < 0.0:
		return local_net_time
	return _map_remote_timestamp(
		host_action_timestamp,
		local_net_time,
		has_host_time_offset,
		host_to_client_time_offset
	)


func _is_valid_spawn_record(
	net_id: int,
	config_path: String,
	spawn_position: Vector2,
	host_spawn_timestamp: float
) -> bool:
	return (
		net_id > 0
		and _NetConstants.is_valid_network_combat_value(net_id)
		and not config_path.is_empty()
		and config_path.length() <= ENEMY_CONFIG_PATH_WIRE_MAX_LENGTH
		and config_path.begins_with("res://")
		and spawn_position.is_finite()
		and is_finite(host_spawn_timestamp)
		and host_spawn_timestamp >= 0.0
	)


func _is_valid_spawn_batch_payload(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array
) -> bool:
	var record_count := net_ids.size()
	if (
		record_count <= 0
		or record_count > ENEMY_SPAWN_BATCH_MAX_RECORDS
		or config_paths.size() != record_count
		or positions.size() != record_count
		or spawn_times.size() != record_count
	):
		return false
	for record_index in range(record_count):
		if not _is_valid_spawn_record(
			net_ids[record_index],
			config_paths[record_index],
			positions[record_index],
			spawn_times[record_index]
		):
			return false
	return true


func _is_valid_terminal_reason(reason: int) -> bool:
	return reason in [
		ENEMY_TERMINAL_DEFEATED,
		ENEMY_TERMINAL_ESCAPED,
		ENEMY_TERMINAL_REMOVED,
	]


func _is_valid_damage_type(damage_type: int) -> bool:
	return damage_type in [
		EnemyConfig.DamageType.PHYSICAL,
		EnemyConfig.DamageType.MAGIC,
	]


func _is_valid_lightning_chain(points: PackedVector2Array) -> bool:
	var point_count := points.size()
	if (
		point_count < LIGHTNING_SORCERER_CHAIN_MIN_POINTS
		or point_count > LIGHTNING_SORCERER_CHAIN_MAX_POINTS
	):
		return false
	for point in points:
		if not point.is_finite():
			return false
	return true


func receive_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	mapped_action_time: float,
	received_at: float,
	host_action_timestamp: float = -1.0
) -> void:
	_receive_action_record({
		"kind": CLIENT_ENEMY_ACTION_KIND_GENERIC,
		"net_id": net_id,
		"action_name": action_name,
		"direction": direction,
		"action_position": action_position,
		"action_id": action_id,
		"action_time": mapped_action_time,
		"host_action_timestamp": host_action_timestamp,
		"received_at": received_at,
	}, received_at)


func receive_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	mapped_action_time: float,
	received_at: float,
	host_action_timestamp: float = -1.0
) -> void:
	_receive_action_record({
		"kind": CLIENT_ENEMY_ACTION_KIND_TARGET,
		"net_id": net_id,
		"action_name": action_name,
		"target_peer_id": target_peer_id,
		"action_position": action_position,
		"action_id": action_id,
		"action_time": mapped_action_time,
		"host_action_timestamp": host_action_timestamp,
		"received_at": received_at,
	}, received_at)


func receive_enemy_hit_report(
	_sender_id: int,
	_projectile_id: int,
	_owner_peer_id: int,
	_enemy_net_id: int,
	_damage: int,
	_impact_direction: Vector2
) -> void:
	# Protocol-v25 compatibility shell. Client-selected target ids are never
	# collision evidence and therefore cannot settle authoritative damage.
	pass


func get_player_projectile_damage_type(
	projectile_type: StringName
) -> EnemyConfig.DamageType:
	if projectile_type == MpProjectileCoordinator.TIYI_SNIPER_PROJECTILE_TYPE:
		return EnemyConfig.DamageType.MAGIC
	return EnemyConfig.DamageType.PHYSICAL


func apply_tiyi_high_noon_damage(
	owner_player: PlayerTiyi,
	enemy_net_id: int,
	enemy: Enemy
) -> void:
	if (
		owner_player == null
		or not is_instance_valid(owner_player)
		or enemy_net_id <= 0
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
	):
		return
	var resolved_damage := owner_player.get_high_noon_damage_against_enemy(enemy)
	var impact_direction := -owner_player.global_position.direction_to(
		enemy.global_position
	)
	apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		resolved_damage,
		impact_direction,
		EnemyConfig.DamageType.MAGIC,
		false
	)


func apply_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.MAGIC,
	show_hit_particles: bool = true
) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	var enemy_net_id := int(enemy.get_meta("net_id", 0))
	if enemy_net_id <= 0:
		var request := DamageRequest.new(damage, damage_type)
		request.with_source(null, 0, &"collectible_effect")
		request.with_directions(impact_direction)
		request.with_flag(
			CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
			not show_hit_particles
		)
		return enemy.apply_combat_damage(request).accepted
	return apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType,
		show_hit_particles
	)


func apply_host_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	impact_direction: Vector2
) -> void:
	if not has_damage_dependencies():
		return
	var now := _get_network_time()
	var admission: MpProjectileCoordinator.EnemyHitAdmission = (
		_projectile_coordinator.prepare_enemy_hit(
			projectile_id,
			owner_peer_id,
			enemy_net_id,
			reported_damage,
			now
		)
	)
	if admission == null:
		return
	var projectile_type: StringName = admission.projectile_type
	var authoritative_damage: int = admission.authoritative_damage
	var enemy := get_host_enemy(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	var owner_player: Player = _runtime.get_player_for_peer(owner_peer_id)
	if (
		owner_player != null
		and is_instance_valid(owner_player)
		and (
			projectile_type == &"player_bullet"
			or projectile_type == MpProjectileCoordinator.TIYI_SNIPER_PROJECTILE_TYPE
			or projectile_type == MpProjectileCoordinator.TANGO_LASER_PROJECTILE_TYPE
			or projectile_type == &"skill1_bomb"
		)
	):
		authoritative_damage = owner_player.resolve_attack_damage_against_enemy(
			authoritative_damage,
			enemy
		)
	if not apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		authoritative_damage,
		impact_direction,
		get_player_projectile_damage_type(projectile_type)
	):
		return
	_projectile_coordinator.commit_enemy_hit(
		projectile_id,
		enemy_net_id,
		admission.consumes_first_confirmed_hit,
		now
	)
	if projectile_type == MpProjectileCoordinator.TIYI_SNIPER_PROJECTILE_TYPE:
		_broadcast_tiyi_sniper_hit_confirmation(
			projectile_id,
			enemy_net_id,
			enemy,
			impact_direction
		)
	if (
		(
			projectile_type == &"player_bullet"
			or projectile_type == MpProjectileCoordinator.TIYI_SNIPER_PROJECTILE_TYPE
			or projectile_type == MpProjectileCoordinator.TANGO_LASER_PROJECTILE_TYPE
		)
		and owner_player != null
		and is_instance_valid(owner_player)
	):
		owner_player.apply_collectible_attack_hit_effects(enemy, authoritative_damage)


func _broadcast_tiyi_sniper_hit_confirmation(
	projectile_id: int,
	enemy_net_id: int,
	enemy: Enemy,
	impact_direction: Vector2
) -> void:
	var projectile_record: Dictionary = _projectile_coordinator.get_projectile_record(
		projectile_id
	)
	var authoritative_hit_position := enemy.global_position
	var authoritative_direction := (
		_projectile_coordinator.get_valid_client_projectile_direction(-impact_direction)
	)
	var projectile_node := _projectile_coordinator.get_projectile(projectile_id) as Node2D
	if projectile_node != null:
		authoritative_hit_position = projectile_node.global_position
		var projectile_direction_variant: Variant = projectile_node.get("direction")
		if projectile_direction_variant is Vector2:
			var projectile_direction := (
				_projectile_coordinator.get_valid_client_projectile_direction(
					projectile_direction_variant as Vector2
				)
			)
			if projectile_direction != Vector2.ZERO:
				authoritative_direction = projectile_direction
	if authoritative_direction == Vector2.ZERO:
		authoritative_direction = Vector2.RIGHT
	damage_rpc_broadcast_requested.emit(
		&"net_tiyi_sniper_hit_confirmed",
		[
			projectile_id,
			enemy_net_id,
			authoritative_hit_position,
			authoritative_direction,
			bool(projectile_record.get("pierces_enemies", false)),
		]
	)


func receive_tiyi_sniper_hit_confirmation(
	sender_id: int,
	host_peer_id: int,
	projectile_id: int,
	enemy_net_id: int,
	hit_position: Vector2,
	direction: Vector2,
	continues_piercing: bool
) -> void:
	if (
		not has_damage_dependencies()
		or projectile_id <= 0
		or enemy_net_id <= 0
		or not _is_finite_vector2(hit_position)
		or (sender_id > 0 and sender_id != host_peer_id)
	):
		return
	_projectile_coordinator.apply_tiyi_sniper_hit_confirmation(
		projectile_id,
		enemy_net_id,
		hit_position,
		direction,
		continues_piercing,
		_damage_presentation_parent
	)


func apply_confirmed_enemy_damage(
	enemy_net_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool = true
) -> bool:
	if enemy_net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return false
	var request := DamageRequest.new(damage, int(damage_type))
	request.with_directions(impact_direction)
	request.with_flag(
		CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
		not show_hit_particles
	)
	set_active_damage_feedback_context(
		enemy_net_id,
		impact_direction,
		damage_type,
		show_hit_particles
	)
	var result := enemy.apply_combat_damage(request)
	clear_active_damage_feedback_context(enemy_net_id)
	if not result.accepted:
		return false
	if result.lethal:
		# 同步 defeated 信号已经把最终一击纳入可靠 terminal 事件。
		return true
	_queue_host_damage_feedback(
		enemy_net_id,
		result.health_after,
		enemy.health_revision,
		result.applied_damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)
	return true


func _queue_host_damage_feedback(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool
) -> void:
	if (
		not is_inside_tree()
		or _net_manager == null
		or not is_instance_valid(_net_manager)
		or not _net_manager.is_host()
		or enemy_net_id <= 0
	):
		return
	queue_damage_feedback(
		enemy_net_id,
		current_health,
		health_revision,
		confirmed_damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)


func update_damage_feedback(delta: float) -> void:
	if (
		_net_manager == null
		or not is_instance_valid(_net_manager)
		or not _net_manager.is_host()
	):
		return
	_combat_feedback_flush_time_left -= maxf(delta, 0.0)
	if _combat_feedback_flush_time_left > 0.0:
		return
	_combat_feedback_flush_time_left = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
	for batch in drain_damage_feedback_batches():
		damage_rpc_broadcast_requested.emit(
			&"net_enemy_damage_feedback_batch",
			[
				batch.net_ids,
				batch.health_values,
				batch.health_revisions,
				batch.damage_values,
				batch.directions,
				batch.damage_types,
				batch.particle_flags,
			]
		)


func apply_damage_feedback_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	health_revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	particle_flags: PackedByteArray
) -> void:
	var record_count := mini(
		net_ids.size(),
		mini(
			health_values.size(),
			mini(
				health_revisions.size(),
				mini(
					damage_values.size(),
					mini(directions.size(), mini(damage_types.size(), particle_flags.size()))
				)
			)
		)
	)
	for record_index in range(record_count):
		if (
			net_ids[record_index] <= 0
			or not _NetConstants.is_valid_network_combat_value(health_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(health_revisions[record_index])
			or not _NetConstants.is_valid_network_combat_value(damage_values[record_index])
		):
			continue
		var enemy := get_valid_client_enemy(net_ids[record_index])
		if enemy == null or not is_instance_valid(enemy):
			continue
		apply_network_health(
			enemy,
			health_values[record_index],
			health_revisions[record_index]
		)
		enemy.show_damage_number(
			damage_values[record_index],
			directions[record_index],
			int(damage_types[record_index]) as EnemyConfig.DamageType
		)
		if directions[record_index] != Vector2.ZERO:
			enemy.play_multiplayer_damage_feedback(
				directions[record_index],
				particle_flags[record_index] != 0
			)


func apply_damage_event(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	show_hit_particles: bool
) -> void:
	if (
		enemy_net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		return
	var enemy := get_valid_client_enemy(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	apply_network_health(enemy, current_health, health_revision)
	enemy.show_damage_number(
		confirmed_damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType
	)
	if impact_direction != Vector2.ZERO:
		enemy.play_multiplayer_damage_feedback(impact_direction, show_hit_particles)
	if is_dead:
		remove_client_enemy(enemy_net_id, true)


func set_active_damage_feedback_context(
	enemy_net_id: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool
) -> void:
	active_enemy_damage_feedback_context[enemy_net_id] = {
		"impact_direction": impact_direction,
		"damage_type": int(damage_type),
		"show_hit_particles": show_hit_particles,
	}


func clear_active_damage_feedback_context(enemy_net_id: int) -> void:
	active_enemy_damage_feedback_context.erase(enemy_net_id)


func queue_damage_feedback(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool
) -> void:
	if enemy_net_id <= 0:
		return
	if (
		not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		push_error("MpEnemyCoordinator: 敌人战斗反馈含越界 int32 值。")
		return
	var feedback := pending_enemy_damage_feedback.get(enemy_net_id, {}) as Dictionary
	if feedback.is_empty():
		feedback = {
			"current_health": current_health,
			"health_revision": health_revision,
			"damage": 0,
			"impact_direction": impact_direction,
			"damage_type": int(damage_type),
			"show_hit_particles": show_hit_particles,
		}
	feedback["current_health"] = current_health
	feedback["health_revision"] = health_revision
	var combined_damage := int(feedback.get("damage", 0)) + confirmed_damage
	if not _NetConstants.is_valid_network_combat_value(combined_damage):
		push_error("MpEnemyCoordinator: 敌人战斗反馈聚合值超过 signed int32。")
		return
	feedback["damage"] = combined_damage
	feedback["impact_direction"] = impact_direction
	feedback["damage_type"] = int(damage_type)
	feedback["show_hit_particles"] = (
		bool(feedback.get("show_hit_particles", false)) or show_hit_particles
	)
	pending_enemy_damage_feedback[enemy_net_id] = feedback


func drain_damage_feedback_batches() -> Array[DamageFeedbackBatch]:
	var batches: Array[DamageFeedbackBatch] = []
	if pending_enemy_damage_feedback.is_empty():
		return batches
	var enemy_ids: Array[int] = []
	for enemy_id_variant in pending_enemy_damage_feedback.keys():
		enemy_ids.append(int(enemy_id_variant))
	enemy_ids.sort()
	for chunk_start in range(0, enemy_ids.size(), COMBAT_FEEDBACK_MAX_RECORDS_PER_PACKET):
		var batch := DamageFeedbackBatch.new()
		var chunk_end := mini(
			chunk_start + COMBAT_FEEDBACK_MAX_RECORDS_PER_PACKET,
			enemy_ids.size()
		)
		for record_index in range(chunk_start, chunk_end):
			var enemy_id := enemy_ids[record_index]
			var feedback := pending_enemy_damage_feedback.get(enemy_id, {}) as Dictionary
			var current_health := int(feedback.get("current_health", 0))
			var health_revision := int(feedback.get("health_revision", 0))
			var confirmed_damage := int(feedback.get("damage", 0))
			if (
				not _NetConstants.is_valid_network_combat_value(enemy_id)
				or not _NetConstants.is_valid_network_combat_value(current_health)
				or not _NetConstants.is_valid_network_combat_value(health_revision)
				or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
			):
				continue
			batch.net_ids.append(enemy_id)
			batch.health_values.append(current_health)
			batch.health_revisions.append(health_revision)
			batch.damage_values.append(confirmed_damage)
			batch.directions.append(feedback.get("impact_direction", Vector2.ZERO) as Vector2)
			batch.damage_types.append(int(feedback.get("damage_type", 0)))
			batch.particle_flags.append(
				1 if bool(feedback.get("show_hit_particles", false)) else 0
			)
		if not batch.is_empty():
			batches.append(batch)
	pending_enemy_damage_feedback.clear()
	return batches


func collect_terminal_feedback(enemy_net_id: int) -> Dictionary:
	var pending_feedback := pending_enemy_damage_feedback.get(enemy_net_id, {}) as Dictionary
	pending_enemy_damage_feedback.erase(enemy_net_id)
	var active_context := active_enemy_damage_feedback_context.get(enemy_net_id, {}) as Dictionary
	var enemy: Enemy = null
	if is_bound():
		enemy = _runtime.multiplayer_enemies_by_net_id.get(enemy_net_id) as Enemy
	var current_health := int(pending_feedback.get("current_health", 0))
	var health_revision := int(pending_feedback.get("health_revision", 0))
	var confirmed_damage := maxi(int(pending_feedback.get("damage", 0)), 0)
	var impact_direction := pending_feedback.get("impact_direction", Vector2.ZERO) as Vector2
	var damage_type := int(
		pending_feedback.get("damage_type", EnemyConfig.DamageType.PHYSICAL)
	)
	var show_hit_particles := bool(pending_feedback.get("show_hit_particles", false))
	if enemy != null and is_instance_valid(enemy):
		current_health = maxi(enemy.current_health, 0)
		health_revision = enemy.health_revision
		var lethal_result := enemy.last_damage_result
		if lethal_result != null and lethal_result.accepted and lethal_result.lethal:
			confirmed_damage += lethal_result.applied_damage
			if lethal_result.request != null:
				impact_direction = lethal_result.request.get_safe_impact_direction()
				damage_type = lethal_result.request.damage_type
				show_hit_particles = not lethal_result.request.has_flag(
					CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES
				)
	if not active_context.is_empty():
		impact_direction = active_context.get("impact_direction", impact_direction) as Vector2
		damage_type = int(active_context.get("damage_type", damage_type))
		show_hit_particles = (
			show_hit_particles
			or bool(active_context.get("show_hit_particles", false))
		)
	return {
		"current_health": current_health,
		"health_revision": health_revision,
		"damage": confirmed_damage,
		"impact_direction": impact_direction,
		"damage_type": damage_type,
		"show_hit_particles": show_hit_particles,
	}


func get_host_enemy(enemy_net_id: int) -> Enemy:
	return _runtime.get_enemy_for_net_id(enemy_net_id) if is_bound() else null


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func get_client_enemy(enemy_net_id: int) -> Enemy:
	return get_valid_client_enemy(enemy_net_id)


func get_valid_client_enemy(enemy_net_id: int) -> Enemy:
	var enemy_variant: Variant = net_enemies.get(enemy_net_id)
	if enemy_variant == null:
		return null
	if not is_instance_valid(enemy_variant):
		net_enemies.erase(enemy_net_id)
		enemy_spawn_snapshot_times.erase(enemy_net_id)
		enemy_interpolators.erase(enemy_net_id)
		_offscreen_interpolation_slots.erase(enemy_net_id)
		return null
	return enemy_variant as Enemy


func get_remote_enemy_count() -> int:
	return net_enemies.size()


func get_remote_enemy_ids() -> Array[int]:
	var result: Array[int] = []
	for net_id in net_enemies:
		result.append(int(net_id))
	return result


func get_all_client_combat_targets() -> Array[Enemy]:
	var result: Array[Enemy] = []
	for enemy_variant in net_enemies.values():
		var enemy := enemy_variant as Enemy
		if _CombatTargetIndex.is_enemy_queryable(enemy):
			result.append(enemy)
	return result


func find_nearest_client_combat_target(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary
) -> Enemy:
	var radius_squared := radius * radius
	var nearest: Enemy = null
	var nearest_distance_squared := INF
	var nearest_instance_id := 0
	for enemy_variant in net_enemies.values():
		var enemy := enemy_variant as Enemy
		if not _CombatTargetIndex.is_enemy_queryable(enemy):
			continue
		var instance_id := enemy.get_instance_id()
		if excluded_instance_ids.has(instance_id):
			continue
		var distance_squared := center.distance_squared_to(enemy.global_position)
		if distance_squared > radius_squared:
			continue
		if (
			nearest == null
			or distance_squared < nearest_distance_squared
			or (
				distance_squared == nearest_distance_squared
				and instance_id < nearest_instance_id
			)
		):
			nearest = enemy
			nearest_distance_squared = distance_squared
			nearest_instance_id = instance_id
	return nearest


func query_client_combat_targets_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int,
	sorted: bool
) -> void:
	result.clear()
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	for enemy_variant in net_enemies.values():
		var enemy := enemy_variant as Enemy
		if not _CombatTargetIndex.is_enemy_queryable(enemy):
			continue
		if safe_radius > 0.0 and center.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		result.append(enemy)
	if sorted:
		result.sort_custom(
			func(a: Enemy, b: Enemy) -> bool:
				var a_distance := center.distance_squared_to(a.global_position)
				var b_distance := center.distance_squared_to(b.global_position)
				if a_distance != b_distance:
					return a_distance < b_distance
				return a.get_instance_id() < b.get_instance_id()
		)
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)


func remove_enemies_missing_from_manifest(live_enemy_ids: Dictionary) -> void:
	for net_id in get_remote_enemy_ids():
		if not live_enemy_ids.has(net_id):
			remove_client_enemy(net_id, false)


func invalidate_remote_enemy_count() -> void:
	# Count presentation caching belongs to the root adapter. This hook exists so
	# flow changes can explicitly retain the same coordinator boundary.
	pass


func apply_network_health(
	enemy_node: Enemy,
	current_health: int,
	health_revision: int
) -> bool:
	if enemy_node == null or health_revision <= enemy_node.health_revision:
		return false
	enemy_node.apply_multiplayer_health_snapshot(maxi(current_health, 0))
	enemy_node.health_revision = health_revision
	return true


func get_buffered_enemy_position(
	net_id: int,
	fallback_position: Vector2,
	current_time: float
) -> Vector2:
	var interpolator := enemy_interpolators.get(net_id) as NetInterpolator
	if interpolator == null or interpolator.get_buffer_size() <= 0:
		return fallback_position
	return interpolator.get_interpolated_position(current_time)


func reconcile_roster(seen_enemy_ids: Dictionary, snapshot_time: float) -> void:
	var stale_ids: Array[int] = []
	for net_id in net_enemies:
		if seen_enemy_ids.has(net_id):
			continue
		if float(enemy_spawn_snapshot_times.get(net_id, -INF)) > snapshot_time:
			continue
		stale_ids.append(net_id)
	for net_id in stale_ids:
		remove_client_enemy(net_id, false)


func remove_client_enemy(
	net_id: int,
	play_death_sequence: bool,
	preserve_interpolator: bool = false,
	preserve_pending_action: bool = false
) -> void:
	var enemy := net_enemies.get(net_id) as Enemy
	if enemy != null and is_instance_valid(enemy):
		if play_death_sequence:
			enemy.play_multiplayer_death_sequence()
		else:
			enemy.queue_free()
	net_enemies.erase(net_id)
	if not preserve_pending_action:
		erase_pending_enemy_action(net_id)
	enemy_spawn_snapshot_times.erase(net_id)
	if is_bound():
		_runtime.multiplayer_enemies_by_net_id.erase(net_id)
		_runtime.unregister_combat_target(net_id)
		if enemy != null and is_instance_valid(enemy):
			_runtime.multiplayer_enemy_ids_by_instance.erase(enemy.get_instance_id())
	if not preserve_interpolator:
		enemy_interpolators.erase(net_id)
	_offscreen_interpolation_slots.erase(net_id)


func consume_pending_enemy_action(net_id: int, current_time: float) -> bool:
	var pending := take_pending_enemy_action(net_id)
	if pending.is_empty() or _is_pending_enemy_action_expired(pending, current_time):
		return false
	var enemy := get_valid_client_enemy(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return false
	_deliver_action_record(pending, enemy, current_time)
	return true


func take_pending_enemy_action(net_id: int) -> Dictionary:
	var pending := pending_enemy_actions.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return {}
	erase_pending_enemy_action(net_id)
	return pending


func erase_pending_enemy_action(net_id: int) -> bool:
	if not pending_enemy_actions.has(net_id):
		return false
	var previous_id := int(_pending_enemy_action_previous_ids.get(net_id, 0))
	var next_id := int(_pending_enemy_action_next_ids.get(net_id, 0))
	if previous_id > 0:
		_pending_enemy_action_next_ids[previous_id] = next_id
	else:
		_pending_enemy_action_oldest_id = next_id
	if next_id > 0:
		_pending_enemy_action_previous_ids[next_id] = previous_id
	else:
		_pending_enemy_action_newest_id = previous_id
	_pending_enemy_action_previous_ids.erase(net_id)
	_pending_enemy_action_next_ids.erase(net_id)
	pending_enemy_actions.erase(net_id)
	return true


func clear_pending_enemy_actions() -> void:
	pending_enemy_actions.clear()
	_pending_enemy_action_previous_ids.clear()
	_pending_enemy_action_next_ids.clear()
	_pending_enemy_action_oldest_id = 0
	_pending_enemy_action_newest_id = 0


func mark_client_terminal(net_id: int) -> void:
	if net_id <= 0:
		return
	erase_pending_enemy_action(net_id)
	clear_client_terminal_marker(net_id)
	while client_terminal_enemy_ids.size() >= CLIENT_TERMINAL_ENEMY_TOMBSTONE_MAX_ENTRIES:
		clear_client_terminal_marker(_client_terminal_enemy_oldest_id)
	var previous_id := _client_terminal_enemy_newest_id
	client_terminal_enemy_ids[net_id] = true
	_client_terminal_enemy_previous_ids[net_id] = previous_id
	_client_terminal_enemy_next_ids[net_id] = 0
	if previous_id > 0:
		_client_terminal_enemy_next_ids[previous_id] = net_id
	else:
		_client_terminal_enemy_oldest_id = net_id
	_client_terminal_enemy_newest_id = net_id


func clear_client_terminal_marker(net_id: int) -> bool:
	if not client_terminal_enemy_ids.has(net_id):
		return false
	var previous_id := int(_client_terminal_enemy_previous_ids.get(net_id, 0))
	var next_id := int(_client_terminal_enemy_next_ids.get(net_id, 0))
	if previous_id > 0:
		_client_terminal_enemy_next_ids[previous_id] = next_id
	else:
		_client_terminal_enemy_oldest_id = next_id
	if next_id > 0:
		_client_terminal_enemy_previous_ids[next_id] = previous_id
	else:
		_client_terminal_enemy_newest_id = previous_id
	_client_terminal_enemy_previous_ids.erase(net_id)
	_client_terminal_enemy_next_ids.erase(net_id)
	client_terminal_enemy_ids.erase(net_id)
	return true


func clear_client_terminal_markers() -> void:
	client_terminal_enemy_ids.clear()
	_client_terminal_enemy_previous_ids.clear()
	_client_terminal_enemy_next_ids.clear()
	_client_terminal_enemy_oldest_id = 0
	_client_terminal_enemy_newest_id = 0


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_snapshot_manager.clear_peer_delta_cache(peer_id)
	_snapshot_cohort_peers.erase(peer_id)
	_last_keyframe_time_by_peer.erase(peer_id)
	var pending_target_action_ids: Array[int] = []
	for net_id_variant in pending_enemy_actions.keys():
		var net_id := int(net_id_variant)
		var record := pending_enemy_actions.get(net_id, {}) as Dictionary
		if (
			int(record.get("kind", -1)) == CLIENT_ENEMY_ACTION_KIND_TARGET
			and int(record.get("target_peer_id", 0)) == peer_id
		):
			pending_target_action_ids.append(net_id)
	for net_id in pending_target_action_ids:
		erase_pending_enemy_action(net_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_enemy_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func reset_session_state() -> void:
	_snapshot_manager.reset_delta_cache()
	net_enemies.clear()
	enemy_interpolators.clear()
	enemy_spawn_snapshot_times.clear()
	_host_snapshot_live_ids.clear()
	_last_keyframe_time_by_peer.clear()
	_snapshot_cohort_peers.clear()
	pending_enemy_snapshot_batches.clear()
	pending_enemy_damage_feedback.clear()
	active_enemy_damage_feedback_context.clear()
	clear_pending_enemy_actions()
	clear_client_terminal_markers()
	host_terminal_enemy_ids.clear()
	_pending_host_spawns.clear()
	_offscreen_interpolation_slots.clear()
	_host_snapshot_batch_sequence = 0
	_snapshot_chunk_encode_count = 0
	_snapshot_batch_count = 0
	_snapshot_completed_batch_count = 0
	_snapshot_incomplete_batch_evict_count = 0
	_snapshot_stale_chunk_count = 0
	_last_completed_snapshot_batch_id = 0
	_latest_snapshot_batch_seen = 0
	_current_snapshot_hz = _NetConstants.ENEMY_SNAPSHOT_HZ
	_offscreen_proxy_count = 0
	_proxy_visual_budget_time_left = 0.0


func get_snapshot_metrics() -> Dictionary:
	return {
		"enemy_snapshot_batch_count": _snapshot_batch_count,
		"enemy_snapshot_chunk_encode_count": _snapshot_chunk_encode_count,
		"enemy_snapshot_completed_batch_count": _snapshot_completed_batch_count,
		"enemy_snapshot_incomplete_batch_evict_count": _snapshot_incomplete_batch_evict_count,
		"enemy_snapshot_stale_chunk_count": _snapshot_stale_chunk_count,
		"enemy_snapshot_cohort_size": _snapshot_cohort_peers.size(),
		"current_enemy_snapshot_hz": _current_snapshot_hz,
		"offscreen_enemy_proxy_count": _offscreen_proxy_count,
	}


func _snapshot_cohort_requires_keyframe(
	ready_peer_ids: Array[int],
	snapshot_time: float
) -> bool:
	if ready_peer_ids.is_empty():
		return false
	if _snapshot_cohort_peers.size() != ready_peer_ids.size():
		return true
	for peer_id in ready_peer_ids:
		if (
			not _snapshot_cohort_peers.has(peer_id)
			or not _last_keyframe_time_by_peer.has(peer_id)
		):
			return true
		if (
			snapshot_time
			- float(_last_keyframe_time_by_peer.get(peer_id, -INF))
			>= ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS
		):
			return true
	return false


func _commit_snapshot_cohort_send(
	ready_peer_ids: Array[int],
	snapshot_time: float,
	was_keyframe: bool
) -> void:
	_snapshot_cohort_peers.clear()
	for peer_id in ready_peer_ids:
		if peer_id <= 0:
			continue
		_snapshot_cohort_peers[peer_id] = true
		if was_keyframe:
			_last_keyframe_time_by_peer[peer_id] = snapshot_time


func _update_snapshot_hz(snapshot_hz: int) -> void:
	var resolved_hz := clampi(snapshot_hz, 1, _NetConstants.HOST_PHYSICS_HZ)
	if resolved_hz == _current_snapshot_hz:
		return
	_current_snapshot_hz = resolved_hz
	for interpolator_variant in enemy_interpolators.values():
		var interpolator := interpolator_variant as NetInterpolator
		if interpolator != null:
			interpolator.set_snapshot_interval(1.0 / float(resolved_hz))


func _prune_old_snapshot_batches(current_batch_id: int) -> void:
	for pending_batch_id_variant in pending_enemy_snapshot_batches.keys():
		var pending_batch_id := int(pending_batch_id_variant)
		if pending_batch_id < current_batch_id - 2:
			_snapshot_incomplete_batch_evict_count += 1
			pending_enemy_snapshot_batches.erase(pending_batch_id)


func _discard_snapshot_batches_through(completed_batch_id: int) -> void:
	for pending_batch_id_variant in pending_enemy_snapshot_batches.keys():
		var pending_batch_id := int(pending_batch_id_variant)
		if pending_batch_id <= completed_batch_id:
			if pending_batch_id < completed_batch_id:
				_snapshot_incomplete_batch_evict_count += 1
			pending_enemy_snapshot_batches.erase(pending_batch_id)


func _is_complete_snapshot_chunk(data: PackedByteArray, decoded_count: int) -> bool:
	if data.size() < 2:
		return false
	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	return decoded_count == stream.get_u16()


func _create_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(maxi(_current_snapshot_hz, 1)),
		_NetConstants.ENEMY_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.ENEMY_MAX_EXTRAPOLATION_SECONDS
	)


func _should_interpolate_proxy(
	net_id: int,
	enemy: Enemy,
	current_time: float
) -> bool:
	if enemy == null or enemy.multiplayer_proxy_visual_active:
		return true
	var interval := 1.0 / CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_HZ
	var phase_index := (net_id * 37) % CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_PHASE_COUNT
	var phase_offset := (
		float(phase_index)
		/ float(CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_PHASE_COUNT)
		* interval
	)
	var current_slot := floori((current_time + phase_offset) / interval)
	var previous_slot := int(_offscreen_interpolation_slots.get(net_id, current_slot - 1))
	if previous_slot == current_slot:
		return false
	_offscreen_interpolation_slots[net_id] = current_slot
	return true


func _register_client_enemy(net_id: int, enemy: Enemy) -> void:
	net_enemies[net_id] = enemy
	if is_bound():
		_runtime.multiplayer_enemies_by_net_id[net_id] = enemy
		_runtime.multiplayer_enemy_ids_by_instance[enemy.get_instance_id()] = net_id
		_runtime.register_combat_target(net_id, enemy)
	var callback := _on_client_enemy_tree_exited.bind(net_id, enemy)
	if not enemy.tree_exited.is_connected(callback):
		enemy.tree_exited.connect(callback)


func _on_client_enemy_tree_exited(net_id: int, exiting_enemy: Enemy) -> void:
	var indexed_enemy := net_enemies.get(net_id) as Enemy
	if indexed_enemy == null:
		return
	if is_instance_valid(indexed_enemy) and indexed_enemy != exiting_enemy:
		return
	net_enemies.erase(net_id)
	erase_pending_enemy_action(net_id)
	enemy_spawn_snapshot_times.erase(net_id)
	enemy_interpolators.erase(net_id)
	_offscreen_interpolation_slots.erase(net_id)
	if is_bound():
		_runtime.multiplayer_enemies_by_net_id.erase(net_id)
		_runtime.multiplayer_enemy_ids_by_instance.erase(exiting_enemy.get_instance_id())
		_runtime.unregister_combat_target(net_id)


func _receive_action_record(record: Dictionary, current_time: float) -> void:
	if not is_client_view() or not _is_valid_action_record(record):
		return
	var net_id := int(record.get("net_id", 0))
	var enemy := get_valid_client_enemy(net_id)
	if enemy == null or not is_instance_valid(enemy):
		if not client_terminal_enemy_ids.has(net_id):
			_cache_pending_enemy_action(record)
		return
	_deliver_action_record(record, enemy, current_time)


func _is_valid_action_record(record: Dictionary) -> bool:
	var kind := int(record.get("kind", -1))
	var net_id := int(record.get("net_id", 0))
	var action_id := int(record.get("action_id", 0))
	var action_name := StringName(record.get("action_name", &""))
	if (
		net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
		or action_id <= 0
		or not _NetConstants.is_valid_network_combat_value(action_id)
		or action_name.is_empty()
		or String(action_name).length() > ENEMY_ACTION_NAME_WIRE_MAX_LENGTH
		or not (record.get("action_position", Vector2.ZERO) as Vector2).is_finite()
		or not is_finite(float(record.get("action_time", -1.0)))
		or (
			record.has("received_at")
			and not is_finite(float(record.get("received_at", -1.0)))
		)
		or (
			record.has("host_action_timestamp")
			and not is_finite(float(record.get("host_action_timestamp", -1.0)))
		)
	):
		return false
	match kind:
		CLIENT_ENEMY_ACTION_KIND_GENERIC:
			return (record.get("direction", Vector2.ZERO) as Vector2).is_finite()
		CLIENT_ENEMY_ACTION_KIND_TARGET:
			var target_peer_id := int(record.get("target_peer_id", 0))
			return (
				target_peer_id > 0
				and _NetConstants.is_valid_network_combat_value(target_peer_id)
			)
		_:
			return false


func _deliver_action_record(
	record: Dictionary,
	enemy: Enemy,
	current_time: float
) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var net_id := int(record.get("net_id", 0))
	var action_position := record.get("action_position", Vector2.ZERO) as Vector2
	var action_sample := _push_action_interpolator_sample(
		net_id,
		action_position,
		float(record.get("action_time", current_time))
	)
	if bool(action_sample.get("apply_direct_position", false)):
		enemy.global_position = action_position
	var action_elapsed := maxf(
		current_time - float(record.get("action_time", current_time)),
		current_time - float(record.get("received_at", current_time))
	)
	action_elapsed = maxf(action_elapsed, 0.0)
	var action_name := StringName(record.get("action_name", &""))
	var action_id := int(record.get("action_id", 0))
	match int(record.get("kind", -1)):
		CLIENT_ENEMY_ACTION_KIND_GENERIC:
			var direction := record.get("direction", Vector2.ZERO) as Vector2
			if enemy.has_method("play_multiplayer_enemy_action_with_context"):
				enemy.call(
					"play_multiplayer_enemy_action_with_context",
					action_name,
					direction,
					action_position,
					action_id,
					action_elapsed
				)
			elif enemy.has_method("play_multiplayer_enemy_action"):
				enemy.call(
					"play_multiplayer_enemy_action",
					action_name,
					direction,
					action_id
				)
		CLIENT_ENEMY_ACTION_KIND_TARGET:
			var target := _runtime.get_player_for_peer(
				int(record.get("target_peer_id", 0))
			)
			if enemy.has_method("play_multiplayer_enemy_target_action_with_context"):
				enemy.call(
					"play_multiplayer_enemy_target_action_with_context",
					action_name,
					target,
					action_position,
					action_id,
					action_elapsed
				)
			elif enemy.has_method("play_multiplayer_enemy_target_action"):
				enemy.call(
					"play_multiplayer_enemy_target_action",
					action_name,
					target,
					action_id
				)


func _cache_pending_enemy_action(record: Dictionary) -> bool:
	var net_id := int(record.get("net_id", 0))
	if net_id <= 0 or client_terminal_enemy_ids.has(net_id):
		return false
	var action_id := int(record.get("action_id", 0))
	if pending_enemy_actions.has(net_id):
		var current := pending_enemy_actions[net_id] as Dictionary
		var current_action_id := int(current.get("action_id", 0))
		if action_id < current_action_id:
			return false
		if (
			action_id == current_action_id
			and float(current.get("host_action_timestamp", -1.0)) >= 0.0
			and float(record.get("host_action_timestamp", -1.0)) >= 0.0
			and float(record.get("host_action_timestamp", -1.0))
			< float(current.get("host_action_timestamp", -1.0))
		):
			return false
		erase_pending_enemy_action(net_id)
	while pending_enemy_actions.size() >= CLIENT_PENDING_ENEMY_ACTION_MAX_ENTRIES:
		erase_pending_enemy_action(_pending_enemy_action_oldest_id)
	var previous_id := _pending_enemy_action_newest_id
	pending_enemy_actions[net_id] = record.duplicate(true)
	_pending_enemy_action_previous_ids[net_id] = previous_id
	_pending_enemy_action_next_ids[net_id] = 0
	if previous_id > 0:
		_pending_enemy_action_next_ids[previous_id] = net_id
	else:
		_pending_enemy_action_oldest_id = net_id
	_pending_enemy_action_newest_id = net_id
	return true


func _is_pending_enemy_action_expired(
	record: Dictionary,
	current_time: float
) -> bool:
	var received_at := float(record.get("received_at", -INF))
	return (
		not is_finite(received_at)
		or current_time - received_at > CLIENT_PENDING_ENEMY_ACTION_MAX_AGE_SECONDS
	)


func _push_action_interpolator_sample(
	net_id: int,
	action_position: Vector2,
	action_time: float
) -> Dictionary:
	if net_id <= 0:
		return {}
	var interpolator := enemy_interpolators.get(net_id) as NetInterpolator
	var had_samples := interpolator != null and interpolator.get_buffer_size() > 0
	var inherited_state := NetInterpolator.FrameSnapshot.new()
	if interpolator != null:
		if had_samples:
			inherited_state = interpolator.get_latest_state()
		if interpolator.get_latest_timestamp() > 0.0 and action_time < interpolator.get_latest_timestamp():
			return {"sample_inserted": false, "apply_direct_position": false}
	else:
		interpolator = _create_interpolator()
		enemy_interpolators[net_id] = interpolator
	interpolator.push_snapshot(
		action_time,
		action_position,
		Vector2.ZERO,
		inherited_state.facing,
		inherited_state.anim_state,
		inherited_state.health,
		inherited_state.is_dead
	)
	return {"sample_inserted": true, "apply_direct_position": not had_samples}
