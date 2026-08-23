extends Node
class_name MpEnemyCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const _CombatTargetIndex := preload("res://scene/combat/targeting/combat_target_index.gd")
const _CombatTargetDescriptor := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)
const _CombatRelationService := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const RuntimeContentCatalogScript := preload(
	"res://resources/config/runtime_content_catalog.gd"
)

const GAME_RUNTIME_CLIENT_VIEW := 2
# v26 起使用上一发送状态作为 delta 基线；缺席后回归的 peer 会促使共享 cohort 发 full。
const SHARED_SNAPSHOT_COHORT_ID := -1
const ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
# v94 full 敌人记录为 29 bytes，41 条连同计数为 1191 bytes，低于项目
# 1200-byte 单包预算。
const ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES := (
	SnapshotManager.ENEMY_SNAPSHOT_MAX_RECORDS_PER_PACKET
)
const ENEMY_SNAPSHOT_MAX_PACKET_BYTES := 1191
# 压力验收包含 1000 个客户端代理；保留一倍余量，同时给不可信 chunk_count
# 和未完成批次一个明确的内存上界。
const ENEMY_SNAPSHOT_MAX_ENTITIES_PER_BATCH := 2048
const ENEMY_SNAPSHOT_MAX_CHUNKS := 50
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
const DAMAGE_PRESENTATION_FLAGS_MASK := (
	CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
	| CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
)
const CLIENT_PENDING_ENEMY_ACTION_MAX_ENTRIES := 512
const CLIENT_PENDING_ENEMY_ACTION_MAX_AGE_SECONDS := 5.0
const CLIENT_PENDING_ENEMY_FACTION_MAX_ENTRIES := 512
const CLIENT_PENDING_TARGET_PRESENTATION_MAX_ENTRIES := 512
const TARGET_PRESENTATION_BATCH_MAX_RECORDS := 16
const CLIENT_TERMINAL_ENEMY_TOMBSTONE_MAX_ENTRIES := 512
const ENEMY_CONFIG_PATH_WIRE_MAX_LENGTH := 512
const ENEMY_ACTION_NAME_WIRE_MAX_LENGTH := 128
const TARGET_PRESENTATION_START_ACTION_NAMES := {
	&"sniper_lock_start": true,
	&"sniper_plant_lock_start": true,
	&"lightning_windup": true,
	&"lightning_windup_retry": true,
	&"lightning_plant_windup": true,
	&"lightning_plant_windup_retry": true,
}
const LIGHTNING_SORCERER_CHAIN_MIN_POINTS := 2
const LIGHTNING_SORCERER_CHAIN_MAX_POINTS := 6
const ENEMY_SPAWN_TOKEN_EPSILON := 0.000001

const ENEMY_TERMINAL_DEFEATED := CombatTypes.EnemyTerminalReason.DEFEATED
const ENEMY_TERMINAL_ESCAPED := CombatTypes.EnemyTerminalReason.ESCAPED
const ENEMY_TERMINAL_REMOVED := CombatTypes.EnemyTerminalReason.REMOVED
const CLIENT_ENEMY_ACTION_KIND_GENERIC := 0
const CLIENT_ENEMY_ACTION_KIND_TARGET := 1
const TARGET_ACTION_RESOLUTION_READY := 0
const TARGET_ACTION_RESOLUTION_WAITING := 1
const TARGET_ACTION_RESOLUTION_STALE := 2

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
	var faction_ids := PackedByteArray()
	var faction_revisions := PackedInt32Array()

	func is_empty() -> bool:
		return net_ids.is_empty()


class FactionChangeBatch:
	extends RefCounted

	var net_ids := PackedInt32Array()
	var faction_ids := PackedByteArray()
	var faction_revisions := PackedInt32Array()

	func is_empty() -> bool:
		return net_ids.is_empty()


class TargetPresentationBatch:
	extends RefCounted

	var net_ids := PackedInt32Array()
	var state_revisions := PackedInt32Array()
	var phases := PackedByteArray()
	var target_kinds := PackedByteArray()
	var target_ids := PackedInt32Array()
	var target_revisions := PackedInt32Array()
	var target_fallback_positions := PackedVector2Array()
	var host_start_times := PackedFloat64Array()
	var host_end_times := PackedFloat64Array()
	var action_positions := PackedVector2Array()

	func is_empty() -> bool:
		return net_ids.is_empty()


class PreparedClientSpawn:
	extends RefCounted

	var net_id := 0
	var config_path := ""
	var spawn_position := Vector2.ZERO
	var mapped_spawn_time := 0.0
	var incarnation_token := 0.0
	var current_time := 0.0
	var faction_id := _CombatRelationService.HOSTILE_WAVE
	var faction_revision := 0
	var enemy_config: EnemyConfig = null
	var enemy: Enemy = null
	var previous_enemy: Enemy = null
	var committed_enemy: Enemy = null
	var reuses_existing := false
	var publishes_spawn := false
	var publishes_incarnation_token := false
	var had_previous_spawn_snapshot_time := false
	var previous_spawn_snapshot_time := 0.0
	var had_previous_incarnation_token := false
	var previous_incarnation_token := 0.0

	func release() -> void:
		if enemy == null or not is_instance_valid(enemy):
			enemy = null
			return
		# 准备态候选尚未对外公开；立即释放可确保失败事务不会把暂存子节点
		# 留到下一帧。
		enemy.free()
		enemy = null


class TargetActionResolution:
	extends RefCounted

	var state := TARGET_ACTION_RESOLUTION_WAITING
	var target: Node2D = null


class DamageFeedbackBatch:
	extends RefCounted

	var net_ids := PackedInt32Array()
	var health_values := PackedInt32Array()
	var health_revisions := PackedInt32Array()
	var damage_values := PackedInt32Array()
	var directions := PackedVector2Array()
	var damage_types := PackedByteArray()
	var presentation_flags := PackedByteArray()

	func is_empty() -> bool:
		return net_ids.is_empty()


var enemy_interpolators: Dictionary[int, NetInterpolator] = {}
var pending_enemy_damage_feedback: Dictionary = {}
var active_enemy_damage_feedback_context: Dictionary = {}
var pending_enemy_snapshot_batches: Dictionary = {}
# 未生成敌人的 CH7 动作共享一个有界 FIFO；同 net-id 只保留最新合法动作。
var pending_enemy_actions: Dictionary = {}
# 可靠阵营变更可能先于出生名册到达；按 net-id 仅保留最高 revision。
var pending_enemy_faction_changes: Dictionary = {}
# CH5 持续目标表现独立于 CH7 边沿；目标/来源乱序时按 source net-id 暂存。
var pending_enemy_target_presentation_states: Dictionary = {}
# 有界 FIFO 只承担近期终态的表现去重；raw 水位独立保留到同 ID
# 的严格更新 spawn，否则大波次淘汰表现墓碑后，旧 CH3 会污染新世代。
var client_terminal_enemy_ids: Dictionary = {}
var client_terminal_enemy_incarnation_tokens: Dictionary[int, float] = {}
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
# 映射后的本地时间只用于拒绝旧快照/动作；Host 原始时间令牌独立承担
# net-id 重用时的 incarnation CAS，避免时钟偏移估计变化制造假重生。
var enemy_spawn_snapshot_times: Dictionary[int, float] = {}
var enemy_spawn_incarnation_tokens: Dictionary[int, float] = {}
var _stale_enemy_interpolator_ids: Array[int] = []
var _host_snapshot_batch_sequence := 0
var _host_enemy_spawn_times: Dictionary[int, float] = {}
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
var _pending_enemy_faction_order: Array[int] = []
var _client_enemy_action_revisions: Dictionary[int, int] = {}
var _pending_target_presentation_order: Array[int] = []
var _client_target_presentation_revisions: Dictionary[int, int] = {}
var _client_target_presentation_phases: Dictionary[int, int] = {}
var _client_target_presentation_terminal_revisions: Dictionary[int, int] = {}
var _client_terminal_enemy_previous_ids: Dictionary[int, int] = {}
var _client_terminal_enemy_next_ids: Dictionary[int, int] = {}
var _client_terminal_enemy_oldest_id := 0
var _client_terminal_enemy_newest_id := 0
var _pending_host_spawns: Array[Dictionary] = []
var _pending_host_faction_changes: Dictionary[int, Dictionary] = {}
var _host_faction_enemy_by_net_id: Dictionary[int, Enemy] = {}
var _host_target_presentation_states: Dictionary[int, Dictionary] = {}
var _pending_host_target_presentation_states: Dictionary[int, Dictionary] = {}


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
	reset_session_state()
	_runtime = null


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
	_host_target_presentation_states.erase(net_id)
	_pending_host_target_presentation_states.erase(net_id)
	# 新 incarnation 可以从 revision 0 重新开始；旧 defeated 配对标记不能吞掉
	# 它的首个终结事件。运行时保证同 net-id 的 removed 先于再次 spawned。
	host_terminal_enemy_ids.erase(net_id)
	var enemy := _runtime.get_network_enemy(net_id)
	var has_live_enemy := enemy != null and is_instance_valid(enemy)
	if has_live_enemy:
		_connect_host_enemy_faction_signal(net_id, enemy)
	queue_host_spawn(
		net_id,
		enemy_config,
		spawn_position,
		_get_network_time(),
		enemy.get_combat_faction_id() if has_live_enemy else -1,
		enemy.get_faction_revision() if has_live_enemy else -1
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
	var enemy_count := _runtime.get_network_enemy_count() if is_bound() else 0
	return get_snapshot_interval_frames_for_enemy_count(enemy_count)


func get_snapshot_interval_frames_for_enemy_count(enemy_count: int) -> int:
	var target_hz := (
		ENEMY_HIGH_PRESSURE_SNAPSHOT_HZ
		if maxi(enemy_count, 0) >= ENEMY_HIGH_PRESSURE_THRESHOLD
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
	snapshot_hz: int,
	raw_host_timestamp: float = -1.0
) -> void:
	if not is_client_view() or not is_finite(snapshot_time):
		return
	# 负值是仅供旧直调测试/旧协议使用的“无 raw 时间”标记；网络入口会更早
	# 拒绝非法时间。这里仍拒绝 +INF，避免其被误当成兼容缺省值。
	if raw_host_timestamp >= 0.0 and not is_finite(raw_host_timestamp):
		return
	var has_raw_host_timestamp := (
		is_finite(raw_host_timestamp) and raw_host_timestamp >= 0.0
	)
	var is_chunked_batch := batch_id > 0
	if data.size() < 2 or data.size() > ENEMY_SNAPSHOT_MAX_PACKET_BYTES:
		return
	if (
		is_chunked_batch
		and (
			chunk_count <= 0
			or chunk_count > ENEMY_SNAPSHOT_MAX_CHUNKS
			or chunk_index < 0
			or chunk_index >= chunk_count
		)
	):
		return
	if is_chunked_batch and batch_id <= _last_completed_snapshot_batch_id:
		_snapshot_stale_chunk_count += 1
		return
	if is_chunked_batch and batch_id < _latest_snapshot_batch_seen:
		_snapshot_stale_chunk_count += 1
		return
	# 正式解码会推进共享 baseline。必须先只读扫描 wire ID/结构，再完成
	# batch 元数据与跨 chunk 重复检查，才能保证无效 chunk 零提交。
	var packet_enemy_ids: Array[int] = []
	if not _snapshot_manager.try_collect_decodable_enemy_snapshot_ids(
		data,
		packet_enemy_ids
	):
		if is_chunked_batch and pending_enemy_snapshot_batches.has(batch_id):
			pending_enemy_snapshot_batches.erase(batch_id)
			_prune_snapshot_receive_state_to_active_candidates()
		return
	if (
		is_chunked_batch
		and (
			(chunk_count > 1 and packet_enemy_ids.is_empty())
			or (
				chunk_index < chunk_count - 1
				and packet_enemy_ids.size()
				!= ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
			)
			or packet_enemy_ids.size() > ENEMY_SNAPSHOT_MAX_ENTITIES_PER_BATCH
		)
	):
		if pending_enemy_snapshot_batches.has(batch_id):
			pending_enemy_snapshot_batches.erase(batch_id)
			_prune_snapshot_receive_state_to_active_candidates()
		return
	var batch: Dictionary = {}
	var seen_enemy_ids: Dictionary = {}
	if is_chunked_batch:
		batch = pending_enemy_snapshot_batches.get(batch_id, {}) as Dictionary
		if not batch.is_empty() and (
			int(batch.get("chunk_count", 0)) != chunk_count
			or bool(batch.get("has_raw_host_timestamp", false))
			!= has_raw_host_timestamp
			or (
				has_raw_host_timestamp
				and absf(
					float(batch.get("raw_host_timestamp", -1.0))
					- raw_host_timestamp
				) > ENEMY_SPAWN_TOKEN_EPSILON
			)
		):
			pending_enemy_snapshot_batches.erase(batch_id)
			_prune_snapshot_receive_state_to_active_candidates()
			return
		if not batch.is_empty():
			var received := batch["received"] as Dictionary
			if received.has(chunk_index):
				return
			seen_enemy_ids = batch["seen"] as Dictionary
			var invalid_cross_chunk_ids := (
				seen_enemy_ids.size() + packet_enemy_ids.size()
				> ENEMY_SNAPSHOT_MAX_ENTITIES_PER_BATCH
			)
			if not invalid_cross_chunk_ids:
				for net_id in packet_enemy_ids:
					if seen_enemy_ids.has(net_id):
						invalid_cross_chunk_ids = true
						break
			if invalid_cross_chunk_ids:
				pending_enemy_snapshot_batches.erase(batch_id)
				_prune_snapshot_receive_state_to_active_candidates()
				return
	var states := _snapshot_manager.decode_enemy_snapshots_with_baseline(
		data,
		false
	)
	var snapshot_has_full_roster := _is_complete_snapshot_chunk(data, states.size())
	if (
		not snapshot_has_full_roster
		or states.size() != packet_enemy_ids.size()
	):
		if is_chunked_batch:
			pending_enemy_snapshot_batches.erase(batch_id)
			_prune_snapshot_receive_state_to_active_candidates()
		return
	for net_id in packet_enemy_ids:
		seen_enemy_ids[net_id] = true
	if is_chunked_batch:
		# 只有 wire 结构和正式语义解码都成功的 chunk 才能建立/推进 batch
		# 水位；高 batch-id 的非法 faction/health 不能淘汰较老合法批次。
		if batch.is_empty():
			batch = {
				"chunk_count": chunk_count,
				"received": {},
				"seen": seen_enemy_ids,
				"snapshot_time": snapshot_time,
				"has_raw_host_timestamp": has_raw_host_timestamp,
				"raw_host_timestamp": raw_host_timestamp,
			}
			pending_enemy_snapshot_batches[batch_id] = batch
		_latest_snapshot_batch_seen = maxi(_latest_snapshot_batch_seen, batch_id)
		_prune_old_snapshot_batches(batch_id)
	_update_snapshot_hz(snapshot_hz)
	for state in states:
		var enemy_state := state as SnapshotManager.EnemyState
		if enemy_state == null or enemy_state.net_id <= 0:
			continue
		if (
			_is_client_terminal_blocked(enemy_state.net_id)
			or _is_snapshot_older_than_enemy_incarnation(
				enemy_state.net_id,
				snapshot_time,
				raw_host_timestamp
			)
		):
			# 可靠终态墓碑禁止快照独自复活实体；新 spawn 会事务性清墓碑。
			# raw Host 时间优先承担 incarnation CAS，mapped 时间仅兼容旧直调。
			_snapshot_manager.erase_enemy_receive_baseline(enemy_state.net_id)
			continue
		if enemy_state.is_dead:
			var dead_enemy := get_valid_client_enemy(enemy_state.net_id)
			if dead_enemy != null and is_instance_valid(dead_enemy):
				dead_enemy.global_position = enemy_state.position
				_apply_client_enemy_faction_change(
					dead_enemy,
					enemy_state.faction_id,
					enemy_state.faction_revision
				)
				apply_network_health(
					dead_enemy,
					enemy_state.health,
					enemy_state.health_revision
				)
			mark_client_terminal(enemy_state.net_id, raw_host_timestamp)
			remove_client_enemy(
				enemy_state.net_id,
				true,
				false,
				false,
				true
			)
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
			_apply_client_enemy_faction_change(
				enemy_node,
				enemy_state.faction_id,
				enemy_state.faction_revision
			)
			apply_network_health(
				enemy_node,
					enemy_state.health,
					enemy_state.health_revision
				)
			enemy_node.apply_multiplayer_visual_status_mask(
				enemy_state.visual_status_mask
			)
		else:
			_cache_pending_enemy_faction_change(
				enemy_state.net_id,
				enemy_state.faction_id,
				enemy_state.faction_revision
			)
	if not is_chunked_batch:
		if snapshot_has_full_roster:
			_prune_snapshot_receive_baseline_for_roster(
				seen_enemy_ids,
				snapshot_time,
				raw_host_timestamp
			)
			reconcile_roster(
				seen_enemy_ids,
				snapshot_time,
				raw_host_timestamp
			)
		return
	if not snapshot_has_full_roster:
		return
	var received := batch["received"] as Dictionary
	received[chunk_index] = true
	if received.size() != chunk_count:
		return
	var batch_snapshot_time := float(batch.get("snapshot_time", snapshot_time))
	var batch_raw_host_timestamp := float(
		batch.get("raw_host_timestamp", raw_host_timestamp)
	)
	_prune_snapshot_receive_baseline_for_roster(
		seen_enemy_ids,
		batch_snapshot_time,
		batch_raw_host_timestamp
	)
	_snapshot_completed_batch_count += 1
	_last_completed_snapshot_batch_id = batch_id
	_discard_snapshot_batches_through(batch_id)
	reconcile_roster(
		seen_enemy_ids,
		batch_snapshot_time,
		batch_raw_host_timestamp
	)


func interpolate_remote_enemies(current_time: float) -> void:
	if not is_client_view():
		return
	if not pending_enemy_target_presentation_states.is_empty():
		_replay_ready_pending_target_presentation_states(current_time)
	if not pending_enemy_actions.is_empty():
		_replay_ready_pending_enemy_actions(current_time, _runtime)
	_stale_enemy_interpolator_ids.clear()
	for net_id_variant in enemy_interpolators:
		var net_id := int(net_id_variant)
		var interpolator := enemy_interpolators.get(net_id) as NetInterpolator
		var enemy_node := get_valid_client_enemy(net_id)
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
		for enemy in _runtime.get_network_enemies():
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
	for enemy in _runtime.get_network_enemies():
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
	for net_id in _runtime.get_network_enemy_ids():
		sorted_ids.append(net_id)
	sorted_ids.sort()
	for chunk_start in range(0, sorted_ids.size(), ENEMY_SPAWN_BATCH_MAX_RECORDS):
		var batch := SpawnBatch.new()
		var chunk_end := mini(
			chunk_start + ENEMY_SPAWN_BATCH_MAX_RECORDS,
			sorted_ids.size()
		)
		for record_index in range(chunk_start, chunk_end):
			var net_id := sorted_ids[record_index]
			var enemy := _runtime.get_network_enemy(net_id)
			if (
				net_id <= 0
				or not _NetConstants.is_valid_network_combat_value(net_id)
				or enemy == null
				or not is_instance_valid(enemy)
				or enemy.is_dead
				or enemy is LinglanBoss
				or enemy.config == null
				or not RuntimeContentCatalogScript.is_registered_enemy_config(
					enemy.config
				)
				or not enemy.global_position.is_finite()
			):
				continue
			_connect_host_enemy_faction_signal(net_id, enemy)
			batch.net_ids.append(net_id)
			batch.config_paths.append(enemy.config.resource_path)
			batch.positions.append(enemy.global_position)
			var incarnation_time := float(
				_host_enemy_spawn_times.get(net_id, -1.0)
			)
			if not is_finite(incarnation_time) or incarnation_time < 0.0:
				incarnation_time = host_timestamp
				_host_enemy_spawn_times[net_id] = incarnation_time
			batch.spawn_times.append(incarnation_time)
			batch.faction_ids.append(enemy.get_combat_faction_id())
			batch.faction_revisions.append(enemy.get_faction_revision())
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
				batch.faction_ids,
				batch.faction_revisions,
			]
		)
	# 同一可靠信道上先生成 roster、后持续表现状态；客户端解析 ACTIVE 时
	# source 已存在，NONE 也会显式清掉断线前遗留的锁定/预警视觉。
	_expire_host_target_presentation_states(host_timestamp)
	for batch in _build_target_presentation_batches(
		_host_target_presentation_states
	):
		_emit_target_presentation_batch_to_peer(peer_id, batch)


func receive_enemy_spawn_packet(
	net_id: int,
	config_path: String,
	spawn_position: Vector2,
	host_spawn_timestamp: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float,
	faction_id: int = -1,
	faction_revision: int = -1,
	strict_v94: bool = false
) -> void:
	if (
		not _is_valid_spawn_record(
			net_id,
			config_path,
			spawn_position,
			host_spawn_timestamp
		)
		or (
			strict_v94
			and not _is_valid_faction_state(faction_id, faction_revision)
		)
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
		local_net_time,
		faction_id,
		faction_revision,
		host_spawn_timestamp
	)


func receive_enemy_spawn_batch(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float,
	faction_ids: PackedByteArray = PackedByteArray(),
	faction_revisions: PackedInt32Array = PackedInt32Array(),
	strict_v94: bool = false
) -> void:
	if (
		not is_client_view()
		or not is_finite(local_net_time)
		or (
			strict_v94
			and (
				faction_ids.is_empty()
				or faction_revisions.is_empty()
			)
		)
		or not _is_valid_spawn_batch_payload(
			net_ids,
			config_paths,
			positions,
			spawn_times,
			faction_ids,
			faction_revisions
		)
	):
		return
	var prepared_spawns: Array[PreparedClientSpawn] = []
	for record_index in range(net_ids.size()):
		var mapped_spawn_time := _map_remote_timestamp(
			spawn_times[record_index],
			local_net_time,
			has_host_time_offset,
			host_to_client_time_offset
		)
		if not is_finite(mapped_spawn_time):
			_release_prepared_client_spawns(prepared_spawns)
			return
		var prepared := _prepare_client_spawn(
			net_ids[record_index],
			config_paths[record_index],
			positions[record_index],
			mapped_spawn_time,
			local_net_time,
			(
				int(faction_ids[record_index])
				if not faction_ids.is_empty()
				else -1
			),
			(
				faction_revisions[record_index]
				if not faction_revisions.is_empty()
				else -1
			),
			spawn_times[record_index]
		)
		if prepared == null:
			_release_prepared_client_spawns(prepared_spawns)
			return
		prepared_spawns.append(prepared)
	_commit_prepared_client_spawns(prepared_spawns)


func receive_enemy_spawn(
	net_id: int,
	config_path: String,
	spawn_position: Vector2,
	mapped_spawn_time: float,
	current_time: float,
	faction_id: int = -1,
	faction_revision: int = -1,
	incarnation_token: float = NAN
) -> void:
	var resolved_incarnation_token := (
		incarnation_token if is_finite(incarnation_token) else mapped_spawn_time
	)
	var prepared := _prepare_client_spawn(
		net_id,
		config_path,
		spawn_position,
		mapped_spawn_time,
		current_time,
		faction_id,
		faction_revision,
		resolved_incarnation_token
	)
	if prepared == null:
		return
	_commit_prepared_client_spawns([prepared])


func receive_enemy_faction_changed_batch(
	net_ids: PackedInt32Array,
	faction_ids: PackedByteArray,
	faction_revisions: PackedInt32Array
) -> void:
	if (
		not is_client_view()
		or not _is_valid_faction_change_batch_payload(
			net_ids,
			faction_ids,
			faction_revisions
		)
	):
		return
	for record_index in range(net_ids.size()):
		var net_id := net_ids[record_index]
		var faction_id := int(faction_ids[record_index])
		var faction_revision := faction_revisions[record_index]
		if _is_client_terminal_blocked(net_id):
			continue
		var enemy := get_valid_client_enemy(net_id)
		if enemy == null or not is_instance_valid(enemy):
			_cache_pending_enemy_faction_change(
				net_id,
				faction_id,
				faction_revision
			)
			continue
		_apply_client_enemy_faction_change(
			enemy,
			faction_id,
			faction_revision
		)


func receive_enemy_target_presentation_state_batch_packet(
	net_ids: PackedInt32Array,
	state_revisions: PackedInt32Array,
	phases: PackedByteArray,
	target_kinds: PackedByteArray,
	target_ids: PackedInt32Array,
	target_revisions: PackedInt32Array,
	target_fallback_positions: PackedVector2Array,
	host_start_times: PackedFloat64Array,
	host_end_times: PackedFloat64Array,
	action_positions: PackedVector2Array,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	if (
		not is_client_view()
		or not is_finite(local_net_time)
		or not _is_valid_target_presentation_batch_payload(
			net_ids,
			state_revisions,
			phases,
			target_kinds,
			target_ids,
			target_revisions,
			target_fallback_positions,
			host_start_times,
			host_end_times,
			action_positions
		)
	):
		return
	var records: Array[Dictionary] = []
	for record_index in range(net_ids.size()):
		var host_start_time := host_start_times[record_index]
		var host_end_time := host_end_times[record_index]
		var mapped_start_time := local_net_time
		var mapped_end_time := local_net_time + (host_end_time - host_start_time)
		if has_host_time_offset:
			mapped_start_time = _map_remote_timestamp(
				host_start_time,
				local_net_time,
				true,
				host_to_client_time_offset
			)
			mapped_end_time = _map_remote_timestamp(
				host_end_time,
				local_net_time,
				true,
				host_to_client_time_offset
			)
		if (
			not is_finite(mapped_start_time)
			or not is_finite(mapped_end_time)
			or mapped_end_time < mapped_start_time
		):
			return
		records.append({
			"net_id": net_ids[record_index],
			"state_revision": state_revisions[record_index],
			"phase": int(phases[record_index]),
			"target_kind": int(target_kinds[record_index]),
			"target_id": target_ids[record_index],
			"target_revision": target_revisions[record_index],
			"target_fallback_position": target_fallback_positions[record_index],
			"start_time": mapped_start_time,
			"end_time": mapped_end_time,
			"host_reference_timestamp": host_start_time,
			"action_position": action_positions[record_index],
		})
	receive_enemy_target_presentation_states(records, local_net_time)


func receive_enemy_target_presentation_states(
	records: Array[Dictionary],
	current_time: float
) -> void:
	if not is_client_view() or not is_finite(current_time):
		return
	for record in records:
		if not _is_valid_target_presentation_record(record):
			return
	for record in records:
		_receive_target_presentation_record(record, current_time)


func _receive_target_presentation_record(
	record: Dictionary,
	current_time: float
) -> void:
	var net_id := int(record.get("net_id", 0))
	var state_revision := int(record.get("state_revision", 0))
	var phase := int(record.get("phase", Enemy.TargetPresentationPhase.NONE))
	if (
		_is_client_terminal_blocked(net_id)
		or _is_record_older_than_enemy_incarnation(
			record,
			net_id,
			"host_reference_timestamp"
		)
		or (
			enemy_spawn_snapshot_times.has(net_id)
			and float(record.get("start_time", -INF))
			< float(enemy_spawn_snapshot_times.get(net_id, -INF))
		)
		or not _accept_client_target_presentation_revision(
			net_id,
			state_revision,
			phase
		)
	):
		return
	_commit_client_target_presentation_watermarks(record)
	_erase_pending_target_presentation_state(net_id)
	var apply_state := _apply_client_target_presentation_record(
		record,
		current_time
	)
	if apply_state == TARGET_ACTION_RESOLUTION_WAITING:
		_cache_pending_target_presentation_state(record)


func _accept_client_target_presentation_revision(
	net_id: int,
	state_revision: int,
	phase: int
) -> bool:
	var action_revision := int(_client_enemy_action_revisions.get(net_id, 0))
	# CH7 的 fire/cancel 边沿可能先于 CH5 可靠持续态到达。旧 ACTIVE 一旦
	# 落后于动作水位就必须拒绝，否则已结束的锁定会被重新打开。
	if state_revision < action_revision:
		return false
	var current_revision := int(
		_client_target_presentation_revisions.get(net_id, 0)
	)
	if state_revision > current_revision:
		# state_revision == action_revision 时仍允许：这正是同一 start 边沿的
		# 可靠修复；只有严格落后于 CH7 水位才代表过期状态。
		return true
	return (
		state_revision == current_revision
		and phase == Enemy.TargetPresentationPhase.NONE
		and int(_client_target_presentation_phases.get(
			net_id,
			Enemy.TargetPresentationPhase.NONE
		)) != Enemy.TargetPresentationPhase.NONE
	)


func _apply_client_target_presentation_record(
	record: Dictionary,
	current_time: float
) -> int:
	var net_id := int(record.get("net_id", 0))
	var state_revision := int(record.get("state_revision", 0))
	var phase := int(record.get("phase", Enemy.TargetPresentationPhase.NONE))
	var effective_record := record
	if (
		phase != Enemy.TargetPresentationPhase.NONE
		and current_time >= float(record.get("end_time", -INF))
	):
		effective_record = _make_target_presentation_clear_record(record)
		phase = Enemy.TargetPresentationPhase.NONE
		_commit_client_target_presentation_watermarks(effective_record)
	var source_enemy := get_valid_client_enemy(net_id)
	if source_enemy == null or not is_instance_valid(source_enemy):
		if effective_record != record:
			record.clear()
			record.merge(effective_record, true)
		return TARGET_ACTION_RESOLUTION_WAITING
	var target: Node2D = null
	if phase != Enemy.TargetPresentationPhase.NONE:
		var resolution := _resolve_target_action(effective_record, _runtime)
		if resolution.state == TARGET_ACTION_RESOLUTION_WAITING:
			return TARGET_ACTION_RESOLUTION_WAITING
		if resolution.state == TARGET_ACTION_RESOLUTION_STALE:
			effective_record = _make_target_presentation_clear_record(
				effective_record
			)
			phase = Enemy.TargetPresentationPhase.NONE
			_commit_client_target_presentation_watermarks(effective_record)
		else:
			target = resolution.target
	var start_time := float(effective_record.get("start_time", current_time))
	var end_time := float(effective_record.get("end_time", current_time))
	var elapsed_seconds := maxf(current_time - start_time, 0.0)
	var remaining_seconds := maxf(end_time - current_time, 0.0)
	source_enemy.apply_multiplayer_target_presentation_state(
		phase,
		target,
		effective_record.get("action_position", Vector2.ZERO) as Vector2,
		state_revision,
		elapsed_seconds,
		remaining_seconds
	)
	return TARGET_ACTION_RESOLUTION_READY


func _make_target_presentation_clear_record(record: Dictionary) -> Dictionary:
	var clear_record := record.duplicate(true)
	var end_time := float(record.get("end_time", 0.0))
	clear_record["phase"] = Enemy.TargetPresentationPhase.NONE
	clear_record["target_kind"] = _CombatTargetDescriptor.Kind.NONE
	clear_record["target_id"] = 0
	clear_record["target_revision"] = 0
	clear_record["target_fallback_position"] = Vector2.ZERO
	clear_record["start_time"] = end_time
	clear_record["end_time"] = end_time
	return clear_record


func _cache_pending_target_presentation_state(record: Dictionary) -> bool:
	var net_id := int(record.get("net_id", 0))
	if (
		net_id <= 0
		or _is_client_terminal_blocked(net_id)
		or _is_record_older_than_enemy_incarnation(
			record,
			net_id,
			"host_reference_timestamp"
		)
		or (
			enemy_spawn_snapshot_times.has(net_id)
			and float(record.get("start_time", -INF))
			< float(enemy_spawn_snapshot_times.get(net_id, -INF))
		)
	):
		return false
	if pending_enemy_target_presentation_states.has(net_id):
		_erase_pending_target_presentation_state(net_id)
	while (
		pending_enemy_target_presentation_states.size()
		>= CLIENT_PENDING_TARGET_PRESENTATION_MAX_ENTRIES
		and not _pending_target_presentation_order.is_empty()
	):
		var evicted_id: int = _pending_target_presentation_order.pop_front()
		pending_enemy_target_presentation_states.erase(evicted_id)
	pending_enemy_target_presentation_states[net_id] = record.duplicate(true)
	_pending_target_presentation_order.append(net_id)
	return true


func _erase_pending_target_presentation_state(net_id: int) -> bool:
	if not pending_enemy_target_presentation_states.erase(net_id):
		return false
	_pending_target_presentation_order.erase(net_id)
	return true


func _replay_ready_pending_target_presentation_states(
	current_time: float
) -> int:
	if not is_finite(current_time):
		return 0
	var ordered_ids: Array[int] = _pending_target_presentation_order.duplicate()
	var replayed_count := 0
	for net_id in ordered_ids:
		var record := pending_enemy_target_presentation_states.get(
			net_id,
			{}
		) as Dictionary
		if record.is_empty():
			continue
		if _is_record_older_than_enemy_incarnation(
			record,
			net_id,
			"host_reference_timestamp"
		):
			_erase_pending_target_presentation_state(net_id)
			continue
		if int(record.get("state_revision", 0)) < int(
			_client_enemy_action_revisions.get(net_id, 0)
		):
			# 等待目标期间 CH7 可能已交付更新的 fire/cancel。此时旧 ACTIVE
			# 不得绕过接收 CAS，在目标晚生成后重新打开已结束的表现。
			_erase_pending_target_presentation_state(net_id)
			continue
		_seed_client_target_presentation_watermarks(record)
		var apply_state := _apply_client_target_presentation_record(
			record,
			current_time
		)
		if apply_state == TARGET_ACTION_RESOLUTION_WAITING:
			continue
		_erase_pending_target_presentation_state(net_id)
		replayed_count += 1
	return replayed_count


func _consume_pending_target_presentation_state(
	net_id: int,
	current_time: float
) -> bool:
	var record := pending_enemy_target_presentation_states.get(net_id, {}) as Dictionary
	if record.is_empty():
		return false
	if _is_record_older_than_enemy_incarnation(
		record,
		net_id,
		"host_reference_timestamp"
	):
		_erase_pending_target_presentation_state(net_id)
		return false
	if int(record.get("state_revision", 0)) < int(
		_client_enemy_action_revisions.get(net_id, 0)
	):
		_erase_pending_target_presentation_state(net_id)
		return false
	_seed_client_target_presentation_watermarks(record)
	var apply_state := _apply_client_target_presentation_record(
		record,
		current_time
	)
	if apply_state == TARGET_ACTION_RESOLUTION_WAITING:
		return false
	_erase_pending_target_presentation_state(net_id)
	return true


func _seed_client_target_presentation_watermarks(record: Dictionary) -> void:
	_commit_client_target_presentation_watermarks(record)


func _commit_client_target_presentation_watermarks(record: Dictionary) -> void:
	var net_id := int(record.get("net_id", 0))
	var state_revision := int(record.get("state_revision", 0))
	if net_id <= 0 or state_revision <= 0:
		return
	var phase := int(record.get(
		"phase",
		Enemy.TargetPresentationPhase.NONE
	))
	_client_target_presentation_revisions[net_id] = state_revision
	_client_target_presentation_phases[net_id] = phase
	if phase != Enemy.TargetPresentationPhase.NONE:
		return
	_client_target_presentation_terminal_revisions[net_id] = maxi(
		int(_client_target_presentation_terminal_revisions.get(net_id, 0)),
		state_revision
	)
	var pending := pending_enemy_actions.get(net_id, {}) as Dictionary
	if _is_action_blocked_by_target_presentation_terminal(pending):
		erase_pending_enemy_action(net_id)


func _is_action_blocked_by_target_presentation_terminal(
	record: Dictionary
) -> bool:
	if record.is_empty():
		return false
	var net_id := int(record.get("net_id", 0))
	var action_id := int(record.get("action_id", 0))
	if net_id <= 0 or action_id <= 0:
		return false
	var terminal_revision := int(
		_client_target_presentation_terminal_revisions.get(net_id, 0)
	)
	if action_id < terminal_revision:
		return true
	if action_id > terminal_revision:
		return false
	var action_name := StringName(record.get("action_name", &""))
	return TARGET_PRESENTATION_START_ACTION_NAMES.has(action_name)


func _prepare_client_spawn(
	net_id: int,
	config_path: String,
	spawn_position: Vector2,
	mapped_spawn_time: float,
	current_time: float,
	faction_id: int = -1,
	faction_revision: int = -1,
	incarnation_token: float = NAN
) -> PreparedClientSpawn:
	if (
		not is_client_view()
		or not _is_valid_spawn_record(
			net_id,
			config_path,
			spawn_position,
			mapped_spawn_time
		)
		or not is_finite(current_time)
		or not is_finite(incarnation_token)
		or incarnation_token < 0.0
		or _runtime.enemy_container == null
		or not is_instance_valid(_runtime.enemy_container)
		or _runtime.enemy_container.is_queued_for_deletion()
	):
		return null
	if _is_spawn_blocked_by_terminal_incarnation(net_id, incarnation_token):
		return null
	# 调用方路径只用于精确查表；资源加载器永远不接收网络字符串。
	var runtime: CombatRuntimeBase = _runtime
	var enemy_container: Node = runtime.enemy_container
	var enemy_config := (
		RuntimeContentCatalogScript.load_enemy_config_from_path(config_path)
	)
	if enemy_config == null:
		return null
	var resolved_faction_id := faction_id
	var resolved_faction_revision := faction_revision
	if resolved_faction_id < 0 and resolved_faction_revision < 0:
		resolved_faction_id = enemy_config.default_combat_faction_id
		resolved_faction_revision = 0
	if not _is_valid_faction_state(
		resolved_faction_id,
		resolved_faction_revision
	):
		return null
	var prepared := PreparedClientSpawn.new()
	prepared.net_id = net_id
	prepared.config_path = config_path
	prepared.spawn_position = spawn_position
	prepared.mapped_spawn_time = mapped_spawn_time
	prepared.incarnation_token = incarnation_token
	prepared.current_time = current_time
	prepared.faction_id = resolved_faction_id
	prepared.faction_revision = resolved_faction_revision
	prepared.enemy_config = enemy_config
	prepared.previous_enemy = runtime.get_network_enemy(net_id)
	var has_known_incarnation := enemy_spawn_incarnation_tokens.has(net_id)
	var known_incarnation_token := float(
		enemy_spawn_incarnation_tokens.get(net_id, -INF)
	)
	if (
		has_known_incarnation
		and incarnation_token
		< known_incarnation_token - ENEMY_SPAWN_TOKEN_EPSILON
	):
		return null
	var matches_known_incarnation := (
		not has_known_incarnation
		or absf(incarnation_token - known_incarnation_token)
		<= ENEMY_SPAWN_TOKEN_EPSILON
	)
	if _can_reuse_existing_client_enemy(
		prepared.previous_enemy,
		config_path,
		enemy_container,
		matches_known_incarnation
	):
		# 幂等记录在这里短路，不实例化场景、不触发入树回调，也不分配导航相位。
		prepared.reuses_existing = true
		prepared.committed_enemy = prepared.previous_enemy
		return prepared
	if enemy_config.enemy_scene == null:
		return null
	var instance := enemy_config.enemy_scene.instantiate()
	var enemy := instance as Enemy
	if enemy == null:
		if instance != null and is_instance_valid(instance):
			instance.free()
		return null
	prepared.enemy = enemy
	return prepared


func _can_reuse_existing_client_enemy(
	enemy: Enemy,
	config_path: String,
	enemy_container: Node,
	matches_known_incarnation: bool
) -> bool:
	return (
		matches_known_incarnation
		and enemy != null
		and is_instance_valid(enemy)
		and not enemy.is_queued_for_deletion()
		and enemy.get_parent() == enemy_container
		and not enemy.is_dead
		and enemy.config != null
		and enemy.config.resource_path == config_path
	)


func _apply_spawn_faction_state(
	enemy: Enemy,
	faction_id: int,
	faction_revision: int,
	is_unregistered_candidate: bool
) -> bool:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or not _is_valid_faction_state(faction_id, faction_revision)
	):
		return false
	if is_unregistered_candidate:
		# 候选尚未进入 runtime 注册表与 CombatTargetIndex；在公开前直接写入
		# 权威初值，避免把“revision 0 的非默认阵营”误判成一次陈旧变更。
		enemy.combat_faction_id = faction_id
		enemy.faction_revision = faction_revision
		return true
	var current_revision := enemy.get_faction_revision()
	if faction_revision < current_revision:
		return true
	if faction_revision == current_revision:
		return enemy.get_combat_faction_id() == faction_id
	return enemy.apply_network_combat_faction(faction_id, faction_revision)


func _can_accept_spawn_faction_state(
	enemy: Enemy,
	faction_id: int,
	faction_revision: int
) -> bool:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or not _is_valid_faction_state(faction_id, faction_revision)
	):
		return false
	if faction_revision != enemy.get_faction_revision():
		return true
	return enemy.get_combat_faction_id() == faction_id


func _apply_client_enemy_faction_change(
	enemy: Enemy,
	faction_id: int,
	faction_revision: int
) -> bool:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or not _is_valid_faction_state(faction_id, faction_revision)
	):
		return false
	var current_revision := enemy.get_faction_revision()
	if faction_revision <= current_revision:
		return (
			faction_revision == current_revision
			and enemy.get_combat_faction_id() == faction_id
		)
	return enemy.apply_network_combat_faction(faction_id, faction_revision)


func _cache_pending_enemy_faction_change(
	net_id: int,
	faction_id: int,
	faction_revision: int
) -> bool:
	if (
		net_id <= 0
		or _is_client_terminal_blocked(net_id)
		or not _is_valid_faction_state(faction_id, faction_revision)
	):
		return false
	var current := pending_enemy_faction_changes.get(net_id, {}) as Dictionary
	if not current.is_empty():
		var current_revision := int(current.get("faction_revision", -1))
		if faction_revision <= current_revision:
			return false
	else:
		while (
			pending_enemy_faction_changes.size()
			>= CLIENT_PENDING_ENEMY_FACTION_MAX_ENTRIES
			and not _pending_enemy_faction_order.is_empty()
		):
			var evicted_id: int = _pending_enemy_faction_order.pop_front()
			pending_enemy_faction_changes.erase(evicted_id)
		_pending_enemy_faction_order.append(net_id)
	pending_enemy_faction_changes[net_id] = {
		"faction_id": faction_id,
		"faction_revision": faction_revision,
	}
	return true


func _consume_pending_enemy_faction_change(
	net_id: int,
	enemy: Enemy
) -> bool:
	var pending := pending_enemy_faction_changes.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return false
	_erase_pending_enemy_faction_change(net_id)
	return _apply_client_enemy_faction_change(
		enemy,
		int(pending.get("faction_id", -1)),
		int(pending.get("faction_revision", -1))
	)


func _erase_pending_enemy_faction_change(net_id: int) -> bool:
	if not pending_enemy_faction_changes.erase(net_id):
		return false
	_pending_enemy_faction_order.erase(net_id)
	return true


func clear_pending_enemy_faction_changes() -> void:
	pending_enemy_faction_changes.clear()
	_pending_enemy_faction_order.clear()


func _commit_prepared_client_spawns(
	prepared_spawns: Array[PreparedClientSpawn]
) -> void:
	if prepared_spawns.is_empty() or not is_client_view():
		_release_prepared_client_spawns(prepared_spawns)
		return
	var runtime: CombatRuntimeBase = _runtime
	var enemy_container: Node = runtime.enemy_container
	if (
		enemy_container == null
		or not is_instance_valid(enemy_container)
		or enemy_container.is_queued_for_deletion()
	):
		_release_prepared_client_spawns(prepared_spawns)
		return

	# 第一阶段：所有可信候选完成入树与配置，但尚不发布生成信号，也不改注册表。
	for prepared in prepared_spawns:
		if not _stage_prepared_client_spawn(
			prepared,
			runtime,
			enemy_container
		):
			_release_prepared_client_spawns(prepared_spawns)
			return

	# 第二阶段：在首个公开回调前完成整批注册表替换；强类型注册失败时恢复全部旧映射。
	if not _swap_prepared_client_spawn_registry(
		prepared_spawns,
		runtime,
		enemy_container
	):
		_release_prepared_client_spawns(prepared_spawns)
		return
	# 复用记录在整批注册事务成功前只做只读校验，避免后续记录失败时
	# 提前改变既有敌人的阵营。此处无公开回调，预检后的 CAS 必然可提交。
	for prepared in prepared_spawns:
		if not prepared.reuses_existing:
			continue
		var faction_applied := _apply_spawn_faction_state(
			prepared.committed_enemy,
			prepared.faction_id,
			prepared.faction_revision,
			false
		)
		assert(faction_applied, "MpEnemyCoordinator 生成事务阵营预检与提交不一致。")
		if not faction_applied:
			_clear_committed_client_spawn_batch(runtime, prepared_spawns)
			return
	for prepared in prepared_spawns:
		clear_client_terminal_marker(prepared.net_id)
		clear_client_terminal_incarnation_token(prepared.net_id)
		if prepared.publishes_spawn:
			_client_enemy_action_revisions.erase(prepared.net_id)
			_client_target_presentation_revisions.erase(prepared.net_id)
			_client_target_presentation_phases.erase(prepared.net_id)
			_client_target_presentation_terminal_revisions.erase(prepared.net_id)
		_consume_pending_enemy_faction_change(
			prepared.net_id,
			prepared.committed_enemy
		)

	# 第三阶段：全部记录均可查询后才发布回调与表现；冻结的运行时保证回调解绑安全。
	_publish_prepared_client_spawns(
		prepared_spawns,
		runtime,
		enemy_container
	)


func _stage_prepared_client_spawn(
	prepared: PreparedClientSpawn,
	runtime: CombatRuntimeBase,
	enemy_container: Node
) -> bool:
	if (
		prepared == null
		or prepared.enemy_config == null
		or runtime == null
		or not is_instance_valid(runtime)
		or enemy_container == null
		or not is_instance_valid(enemy_container)
		or enemy_container.is_queued_for_deletion()
	):
		return false
	if prepared.reuses_existing:
		var existing_enemy := prepared.committed_enemy
		var existing_is_valid := (
			existing_enemy != null
			and is_instance_valid(existing_enemy)
			and not existing_enemy.is_queued_for_deletion()
			and existing_enemy.get_parent() == enemy_container
			and runtime.get_network_enemy(prepared.net_id) == existing_enemy
			and _runtime == runtime
		)
		return (
			existing_is_valid
			and _can_accept_spawn_faction_state(
				existing_enemy,
				prepared.faction_id,
				prepared.faction_revision
			)
		)
	if (
		prepared.enemy == null
		or not is_instance_valid(prepared.enemy)
		or prepared.enemy.is_queued_for_deletion()
	):
		return false
	var enemy := prepared.enemy
	enemy_container.add_child(enemy)
	if (
		not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or enemy.get_parent() != enemy_container
	):
		return false
	enemy.global_position = get_buffered_enemy_position(
		prepared.net_id,
		prepared.spawn_position,
		prepared.current_time
	)
	enemy.setup(
		prepared.enemy_config,
		runtime.player,
		runtime.grid_pathfinder,
		runtime
	)
	if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
		return false
	if not _apply_spawn_faction_state(
		enemy,
		prepared.faction_id,
		prepared.faction_revision,
		true
	):
		return false
	enemy.configure_multiplayer_proxy()
	return (
		is_instance_valid(enemy)
		and not enemy.is_queued_for_deletion()
		and enemy.get_parent() == enemy_container
		and _runtime == runtime
	)


func _swap_prepared_client_spawn_registry(
	prepared_spawns: Array[PreparedClientSpawn],
	runtime: CombatRuntimeBase,
	enemy_container: Node
) -> bool:
	var swapped_spawns: Array[PreparedClientSpawn] = []
	for prepared in prepared_spawns:
		if prepared.reuses_existing:
			continue
		if not _register_client_enemy_on_runtime(
			runtime,
			prepared.net_id,
			prepared.enemy,
			enemy_container
		):
			_rollback_prepared_client_spawn_registry(swapped_spawns, runtime)
			return false
		prepared.committed_enemy = prepared.enemy
		prepared.publishes_spawn = true
		swapped_spawns.append(prepared)

	# 移交候选所有权前必须验证整批结构视图完整。
	if not _is_prepared_client_spawn_registry_intact(
		runtime,
		enemy_container,
		prepared_spawns
	):
		_rollback_prepared_client_spawn_registry(swapped_spawns, runtime)
		return false
	for prepared in prepared_spawns:
		if prepared.publishes_spawn:
			prepared.enemy = null
			_snapshot_manager.erase_enemy_receive_baseline(prepared.net_id)
			_capture_prepared_spawn_time_rollback(prepared)
			enemy_spawn_snapshot_times[prepared.net_id] = (
				prepared.mapped_spawn_time
			)
			enemy_spawn_incarnation_tokens[prepared.net_id] = (
				prepared.incarnation_token
			)
			prepared.publishes_incarnation_token = true
			_offscreen_interpolation_slots.erase(prepared.net_id)
			var previous_enemy := prepared.previous_enemy
			if previous_enemy != null and is_instance_valid(previous_enemy):
				previous_enemy.queue_free()
		else:
			if not enemy_spawn_incarnation_tokens.has(prepared.net_id):
				_capture_prepared_spawn_time_rollback(prepared)
				enemy_spawn_snapshot_times[prepared.net_id] = (
					prepared.mapped_spawn_time
				)
				enemy_spawn_incarnation_tokens[prepared.net_id] = (
					prepared.incarnation_token
				)
				prepared.publishes_incarnation_token = true
			prepared.release()
	return true


func _capture_prepared_spawn_time_rollback(prepared: PreparedClientSpawn) -> void:
	prepared.had_previous_spawn_snapshot_time = (
		enemy_spawn_snapshot_times.has(prepared.net_id)
	)
	prepared.previous_spawn_snapshot_time = float(
		enemy_spawn_snapshot_times.get(prepared.net_id, 0.0)
	)
	prepared.had_previous_incarnation_token = (
		enemy_spawn_incarnation_tokens.has(prepared.net_id)
	)
	prepared.previous_incarnation_token = float(
		enemy_spawn_incarnation_tokens.get(prepared.net_id, 0.0)
	)


func _rollback_prepared_client_spawn_registry(
	swapped_spawns: Array[PreparedClientSpawn],
	runtime: CombatRuntimeBase
) -> void:
	for spawn_index in range(swapped_spawns.size() - 1, -1, -1):
		var prepared := swapped_spawns[spawn_index]
		var candidate := prepared.enemy
		if (
			candidate != null
			and is_instance_valid(candidate)
			and runtime.get_network_enemy(prepared.net_id) == candidate
		):
			runtime.unregister_network_enemy(prepared.net_id, candidate)
		var previous_enemy := prepared.previous_enemy
		if previous_enemy != null and is_instance_valid(previous_enemy):
			var restored: bool = runtime.register_network_enemy(
				prepared.net_id,
				previous_enemy
			)
			assert(
				restored
				and runtime.get_network_enemy(prepared.net_id) == previous_enemy,
				"MpEnemyCoordinator 无法恢复敌人生成事务的旧注册。"
			)
		prepared.committed_enemy = null
		prepared.publishes_spawn = false


func _take_live_pending_enemy_action(
	net_id: int,
	current_time: float
) -> Dictionary:
	var pending := pending_enemy_actions.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return {}
	if _is_pending_enemy_action_expired(pending, current_time):
		erase_pending_enemy_action(net_id)
		return {}
	if _is_record_older_than_enemy_incarnation(
		pending,
		net_id,
		"host_action_timestamp"
	):
		erase_pending_enemy_action(net_id)
		return {}
	if (
		enemy_spawn_snapshot_times.has(net_id)
		and float(pending.get("action_time", -INF))
		< float(enemy_spawn_snapshot_times.get(net_id, -INF))
	):
		erase_pending_enemy_action(net_id)
		return {}
	return pending


func _is_record_older_than_enemy_incarnation(
	record: Dictionary,
	net_id: int,
	host_timestamp_key: String
) -> bool:
	if net_id <= 0 or not enemy_spawn_incarnation_tokens.has(net_id):
		return false
	var host_timestamp := float(record.get(host_timestamp_key, -1.0))
	if not is_finite(host_timestamp) or host_timestamp < 0.0:
		# 本地与旧协议兼容记录没有 raw Host 时间，只能继续使用既有的
		# mapped-time/faction revision CAS。
		return false
	var incarnation_token := float(
		enemy_spawn_incarnation_tokens.get(net_id, -INF)
	)
	return (
		is_finite(incarnation_token)
		and host_timestamp + ENEMY_SPAWN_TOKEN_EPSILON < incarnation_token
	)


func _publish_prepared_client_spawns(
	prepared_spawns: Array[PreparedClientSpawn],
	runtime: CombatRuntimeBase,
	enemy_container: Node
) -> void:
	for prepared in prepared_spawns:
		if not _is_prepared_client_spawn_registry_intact(
			runtime,
			enemy_container,
			prepared_spawns
		):
			_clear_committed_client_spawn_batch(runtime, prepared_spawns)
			return
		var enemy := prepared.committed_enemy
		if prepared.publishes_spawn:
			remote_enemy_spawned.emit(enemy)
			if not _is_prepared_client_spawn_registry_intact(
				runtime,
				enemy_container,
				prepared_spawns
			):
				_clear_committed_client_spawn_batch(runtime, prepared_spawns)
				return
		_consume_pending_target_presentation_state(
			prepared.net_id,
			prepared.current_time
		)
		# 等到本条即将交付时才从 FIFO 取动作；较早回调若中止，后续记录保持原样。
		var pending_action := _take_live_pending_enemy_action(
			prepared.net_id,
			prepared.current_time
		)
		if not pending_action.is_empty():
			var delivery_state := _deliver_action_record(
				pending_action,
				enemy,
				prepared.current_time,
				runtime
			)
			if delivery_state != TARGET_ACTION_RESOLUTION_WAITING:
				erase_pending_enemy_action(prepared.net_id)
			if not _is_prepared_client_spawn_registry_intact(
				runtime,
				enemy_container,
				prepared_spawns
			):
				_clear_committed_client_spawn_batch(runtime, prepared_spawns)
				return
		if prepared.publishes_spawn:
			runtime.play_remote_enemy_spawn_effect(prepared.spawn_position)
	if _is_prepared_client_spawn_registry_intact(
		runtime,
		enemy_container,
		prepared_spawns
	):
		_replay_ready_pending_target_presentation_states(
			prepared_spawns[0].current_time
		)
		_replay_ready_pending_enemy_actions(
			prepared_spawns[0].current_time,
			runtime
		)


func _is_prepared_client_spawn_registry_intact(
	runtime: CombatRuntimeBase,
	enemy_container: Node,
	prepared_spawns: Array[PreparedClientSpawn]
) -> bool:
	if (
		runtime == null
		or not is_instance_valid(runtime)
		or enemy_container == null
		or not is_instance_valid(enemy_container)
		or enemy_container.is_queued_for_deletion()
	):
		return false
	for prepared in prepared_spawns:
		var enemy := prepared.committed_enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_queued_for_deletion()
			or enemy.get_parent() != enemy_container
			or runtime.get_network_enemy(prepared.net_id) != enemy
		):
			return false
	return true


func _clear_committed_client_spawn_batch(
	runtime: CombatRuntimeBase,
	prepared_spawns: Array[PreparedClientSpawn]
) -> void:
	if runtime == null or not is_instance_valid(runtime):
		return
	for prepared in prepared_spawns:
		if prepared.publishes_incarnation_token:
			if prepared.had_previous_spawn_snapshot_time:
				enemy_spawn_snapshot_times[prepared.net_id] = (
					prepared.previous_spawn_snapshot_time
				)
			else:
				enemy_spawn_snapshot_times.erase(prepared.net_id)
			if prepared.had_previous_incarnation_token:
				enemy_spawn_incarnation_tokens[prepared.net_id] = (
					prepared.previous_incarnation_token
				)
			else:
				enemy_spawn_incarnation_tokens.erase(prepared.net_id)
		if not prepared.publishes_spawn:
			continue
		_erase_pending_target_presentation_state(prepared.net_id)
		_erase_pending_actions_targeting_enemy(prepared.net_id)
		_client_target_presentation_revisions.erase(prepared.net_id)
		_client_target_presentation_phases.erase(prepared.net_id)
		_client_target_presentation_terminal_revisions.erase(prepared.net_id)
		var enemy := prepared.committed_enemy
		if (
			enemy != null
			and is_instance_valid(enemy)
			and runtime.get_network_enemy(prepared.net_id) == enemy
		):
			runtime.unregister_network_enemy(prepared.net_id, enemy)
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
		enemy_interpolators.erase(prepared.net_id)
		_offscreen_interpolation_slots.erase(prepared.net_id)


static func _release_prepared_client_spawns(
	prepared_spawns: Array[PreparedClientSpawn]
) -> void:
	for prepared in prepared_spawns:
		if prepared != null:
			prepared.release()


func register_client_enemy(
	net_id: int,
	enemy: Enemy,
	current_time: float
) -> bool:
	if net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return false
	if not _register_client_enemy(net_id, enemy):
		return false
	clear_client_terminal_marker(net_id)
	clear_client_terminal_incarnation_token(net_id)
	_consume_pending_target_presentation_state(net_id, current_time)
	consume_pending_enemy_action(net_id, current_time)
	return true


func queue_host_spawn(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	spawn_time: float,
	faction_id: int = -1,
	faction_revision: int = -1
) -> void:
	var resolved_faction_id := faction_id
	var resolved_faction_revision := faction_revision
	if (
		resolved_faction_id < 0
		and resolved_faction_revision < 0
		and enemy_config != null
	):
		resolved_faction_id = enemy_config.default_combat_faction_id
		resolved_faction_revision = 0
	if (
		not is_bound()
		or enemy_config == null
		or not _is_valid_spawn_record(
			net_id,
			enemy_config.resource_path,
			spawn_position,
			spawn_time
		)
		or not _is_valid_faction_state(
			resolved_faction_id,
			resolved_faction_revision
		)
	):
		return
	_snapshot_manager.erase_enemy_send_baseline(net_id)
	_host_enemy_spawn_times[net_id] = spawn_time
	_pending_host_spawns.append({
		"net_id": net_id,
		"config_path": enemy_config.resource_path,
		"position": spawn_position,
		"spawn_time": spawn_time,
		"faction_id": resolved_faction_id,
		"faction_revision": resolved_faction_revision,
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
			batch.faction_ids.append(int(record.get(
				"faction_id",
				_CombatRelationService.HOSTILE_WAVE
			)))
			batch.faction_revisions.append(int(record.get(
				"faction_revision",
				0
			)))
		if not batch.is_empty():
			batches.append(batch)
	return batches


func _erase_pending_host_spawn(net_id: int) -> void:
	for record_index in range(_pending_host_spawns.size() - 1, -1, -1):
		var record := _pending_host_spawns[record_index] as Dictionary
		if int(record.get("net_id", 0)) == net_id:
			_pending_host_spawns.remove_at(record_index)


func drain_host_faction_change_batches() -> Array[FactionChangeBatch]:
	var batches: Array[FactionChangeBatch] = []
	if _pending_host_faction_changes.is_empty():
		return batches
	var sorted_ids: Array[int] = []
	for net_id_variant in _pending_host_faction_changes.keys():
		sorted_ids.append(int(net_id_variant))
	sorted_ids.sort()
	for chunk_start in range(0, sorted_ids.size(), ENEMY_SPAWN_BATCH_MAX_RECORDS):
		var batch := FactionChangeBatch.new()
		var chunk_end := mini(
			chunk_start + ENEMY_SPAWN_BATCH_MAX_RECORDS,
			sorted_ids.size()
		)
		for record_index in range(chunk_start, chunk_end):
			var net_id := sorted_ids[record_index]
			var record := _pending_host_faction_changes.get(net_id, {}) as Dictionary
			if record.is_empty():
				continue
			batch.net_ids.append(net_id)
			batch.faction_ids.append(int(record.get("faction_id", 0)))
			batch.faction_revisions.append(int(record.get("faction_revision", 0)))
		if not batch.is_empty():
			batches.append(batch)
	_pending_host_faction_changes.clear()
	return batches


func set_host_enemy_target_presentation_state(
	net_id: int,
	phase: int,
	target_descriptor: CombatTargetDescriptor,
	duration_seconds: float,
	action_position: Vector2,
	state_revision: int
) -> bool:
	if (
		not _is_host_lifecycle_bound()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
		or _runtime.get_network_enemy(net_id) == null
		or not _is_valid_target_presentation_phase(phase)
		or not _is_valid_target_presentation_descriptor(
			phase,
			target_descriptor
		)
		or state_revision <= 0
		or not _NetConstants.is_valid_network_combat_value(state_revision)
		or not is_finite(duration_seconds)
		or duration_seconds < 0.0
		or (
			phase != Enemy.TargetPresentationPhase.NONE
			and duration_seconds <= 0.0
		)
		or not action_position.is_finite()
	):
		return false
	var current := _host_target_presentation_states.get(net_id, {}) as Dictionary
	if (
		not current.is_empty()
		and state_revision <= int(current.get("state_revision", 0))
	):
		return false
	var host_start_time := _get_network_time()
	if host_start_time < 0.0 or not is_finite(host_start_time):
		return false
	var host_end_time := host_start_time
	if phase != Enemy.TargetPresentationPhase.NONE:
		host_end_time += duration_seconds
	if not is_finite(host_end_time):
		return false
	var record := {
		"net_id": net_id,
		"state_revision": state_revision,
		"phase": phase,
		"target_kind": target_descriptor.kind,
		"target_id": target_descriptor.id,
		"target_revision": target_descriptor.revision,
		"target_fallback_position": target_descriptor.fallback_position,
		"start_time": host_start_time,
		"end_time": host_end_time,
		"action_position": action_position,
	}
	_host_target_presentation_states[net_id] = record
	_pending_host_target_presentation_states[net_id] = record
	return true


func _expire_host_target_presentation_states(host_time: float) -> void:
	if not is_finite(host_time) or host_time < 0.0:
		return
	for net_id_variant in _host_target_presentation_states.keys():
		var net_id := int(net_id_variant)
		var record := _host_target_presentation_states.get(net_id, {}) as Dictionary
		if (
			record.is_empty()
			or int(record.get("phase", Enemy.TargetPresentationPhase.NONE))
			== Enemy.TargetPresentationPhase.NONE
			or float(record.get("end_time", INF)) > host_time
		):
			continue
		var clear_record := record.duplicate(true)
		var authoritative_end := float(record.get("end_time", host_time))
		clear_record["phase"] = Enemy.TargetPresentationPhase.NONE
		clear_record["target_kind"] = _CombatTargetDescriptor.Kind.NONE
		clear_record["target_id"] = 0
		clear_record["target_revision"] = 0
		clear_record["target_fallback_position"] = Vector2.ZERO
		clear_record["start_time"] = authoritative_end
		clear_record["end_time"] = authoritative_end
		_host_target_presentation_states[net_id] = clear_record
		_pending_host_target_presentation_states[net_id] = clear_record


func _clear_host_target_presentation_states_for_target(
	target_kind: int,
	target_id: int,
	host_time: float
) -> int:
	if (
		target_id <= 0
		or target_kind not in [
			_CombatTargetDescriptor.Kind.PLAYER,
			_CombatTargetDescriptor.Kind.ENEMY,
		]
		or not is_finite(host_time)
		or host_time < 0.0
	):
		return 0
	var cleared_count := 0
	for source_net_id_variant in _host_target_presentation_states.keys():
		var source_net_id := int(source_net_id_variant)
		var record := _host_target_presentation_states.get(
			source_net_id,
			{}
		) as Dictionary
		if (
			record.is_empty()
			or int(record.get("phase", Enemy.TargetPresentationPhase.NONE))
			== Enemy.TargetPresentationPhase.NONE
			or int(record.get("target_kind", -1)) != target_kind
			or int(record.get("target_id", 0)) != target_id
		):
			continue
		var clear_record := record.duplicate(true)
		clear_record["phase"] = Enemy.TargetPresentationPhase.NONE
		clear_record["target_kind"] = _CombatTargetDescriptor.Kind.NONE
		clear_record["target_id"] = 0
		clear_record["target_revision"] = 0
		clear_record["target_fallback_position"] = Vector2.ZERO
		clear_record["start_time"] = host_time
		clear_record["end_time"] = host_time
		_host_target_presentation_states[source_net_id] = clear_record
		_pending_host_target_presentation_states[source_net_id] = clear_record
		cleared_count += 1
	return cleared_count


func _build_target_presentation_batches(
	records: Dictionary
) -> Array[TargetPresentationBatch]:
	var batches: Array[TargetPresentationBatch] = []
	if records.is_empty():
		return batches
	var sorted_ids: Array[int] = []
	for net_id_variant in records.keys():
		sorted_ids.append(int(net_id_variant))
	sorted_ids.sort()
	for chunk_start in range(
		0,
		sorted_ids.size(),
		TARGET_PRESENTATION_BATCH_MAX_RECORDS
	):
		var batch := TargetPresentationBatch.new()
		var chunk_end := mini(
			chunk_start + TARGET_PRESENTATION_BATCH_MAX_RECORDS,
			sorted_ids.size()
		)
		for record_index in range(chunk_start, chunk_end):
			var net_id := sorted_ids[record_index]
			var record := records.get(net_id, {}) as Dictionary
			if not _is_valid_target_presentation_record(record):
				continue
			batch.net_ids.append(net_id)
			batch.state_revisions.append(int(record.get("state_revision", 0)))
			batch.phases.append(int(record.get("phase", 0)))
			batch.target_kinds.append(int(record.get("target_kind", 0)))
			batch.target_ids.append(int(record.get("target_id", 0)))
			batch.target_revisions.append(int(record.get("target_revision", 0)))
			batch.target_fallback_positions.append(
				record.get("target_fallback_position", Vector2.ZERO) as Vector2
			)
			batch.host_start_times.append(float(record.get("start_time", 0.0)))
			batch.host_end_times.append(float(record.get("end_time", 0.0)))
			batch.action_positions.append(
				record.get("action_position", Vector2.ZERO) as Vector2
			)
		if not batch.is_empty():
			batches.append(batch)
	return batches


func drain_host_target_presentation_batches() -> Array[TargetPresentationBatch]:
	var records := _pending_host_target_presentation_states.duplicate(true)
	_pending_host_target_presentation_states.clear()
	return _build_target_presentation_batches(records)


func _emit_target_presentation_batch_to_peer(
	peer_id: int,
	batch: TargetPresentationBatch
) -> void:
	lifecycle_rpc_to_peer_requested.emit(
		peer_id,
		&"net_enemy_target_presentation_state_batch",
		[
			batch.net_ids,
			batch.state_revisions,
			batch.phases,
			batch.target_kinds,
			batch.target_ids,
			batch.target_revisions,
			batch.target_fallback_positions,
			batch.host_start_times,
			batch.host_end_times,
			batch.action_positions,
		]
	)


func _emit_target_presentation_batch_broadcast(
	batch: TargetPresentationBatch
) -> void:
	lifecycle_rpc_broadcast_requested.emit(
		&"net_enemy_target_presentation_state_batch",
		[
			batch.net_ids,
			batch.state_revisions,
			batch.phases,
			batch.target_kinds,
			batch.target_ids,
			batch.target_revisions,
			batch.target_fallback_positions,
			batch.host_start_times,
			batch.host_end_times,
			batch.action_positions,
		]
	)


func update_host() -> void:
	if not _is_host_lifecycle_bound():
		return
	_expire_host_target_presentation_states(_get_network_time())
	for batch in drain_host_spawn_batches():
		lifecycle_rpc_broadcast_requested.emit(
			&"net_enemy_spawned_batch",
			[
				batch.net_ids,
				batch.config_paths,
				batch.positions,
				batch.spawn_times,
				batch.faction_ids,
				batch.faction_revisions,
			]
		)
	for batch in drain_host_faction_change_batches():
		lifecycle_rpc_broadcast_requested.emit(
			&"net_enemy_faction_changed_batch",
			[
				batch.net_ids,
				batch.faction_ids,
				batch.faction_revisions,
			]
		)
	for batch in drain_host_target_presentation_batches():
		_emit_target_presentation_batch_broadcast(batch)


func queue_host_faction_change(
	net_id: int,
	faction_id: int,
	faction_revision: int
) -> bool:
	if (
		not _is_host_lifecycle_bound()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
		or not _is_valid_faction_state(faction_id, faction_revision)
	):
		return false
	var current := _pending_host_faction_changes.get(net_id, {}) as Dictionary
	if (
		not current.is_empty()
		and int(current.get("faction_revision", -1)) >= faction_revision
	):
		return false
	_pending_host_faction_changes[net_id] = {
		"faction_id": faction_id,
		"faction_revision": faction_revision,
	}
	return true


func _connect_host_enemy_faction_signal(net_id: int, enemy: Enemy) -> void:
	if (
		net_id <= 0
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
	):
		return
	var previous_variant: Variant = _host_faction_enemy_by_net_id.get(net_id)
	var previous: Enemy = null
	if is_instance_valid(previous_variant):
		previous = previous_variant as Enemy
	if previous == enemy:
		return
	_disconnect_host_enemy_faction_signal(net_id)
	var callback := Callable(
		self,
		"_on_host_enemy_combat_faction_changed"
	).bind(net_id)
	if not enemy.combat_faction_changed.is_connected(callback):
		enemy.combat_faction_changed.connect(callback)
	_host_faction_enemy_by_net_id[net_id] = enemy


func _disconnect_host_enemy_faction_signal(net_id: int) -> void:
	var enemy_variant: Variant = _host_faction_enemy_by_net_id.get(net_id)
	_host_faction_enemy_by_net_id.erase(net_id)
	if not is_instance_valid(enemy_variant):
		return
	var enemy := enemy_variant as Enemy
	if enemy == null:
		return
	var callback := Callable(
		self,
		"_on_host_enemy_combat_faction_changed"
	).bind(net_id)
	if enemy.combat_faction_changed.is_connected(callback):
		enemy.combat_faction_changed.disconnect(callback)


func _disconnect_all_host_enemy_faction_signals() -> void:
	var net_ids: Array[int] = []
	for net_id_variant in _host_faction_enemy_by_net_id.keys():
		net_ids.append(int(net_id_variant))
	for net_id in net_ids:
		_disconnect_host_enemy_faction_signal(net_id)


func _on_host_enemy_combat_faction_changed(
	enemy: Enemy,
	_previous_faction_id: int,
	current_faction_id: int,
	faction_revision: int,
	net_id: int
) -> void:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or _host_faction_enemy_by_net_id.get(net_id) != enemy
		or not is_bound()
		or _runtime.get_network_enemy(net_id) != enemy
		or enemy.get_combat_faction_id() != current_faction_id
		or enemy.get_faction_revision() != faction_revision
	):
		return
	queue_host_faction_change(net_id, current_faction_id, faction_revision)


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
	_clear_host_target_presentation_states_for_target(
		_CombatTargetDescriptor.Kind.ENEMY,
		net_id,
		_get_network_time()
	)
	_erase_pending_host_spawn(net_id)
	_snapshot_manager.erase_enemy_send_baseline(net_id)
	_host_enemy_spawn_times.erase(net_id)
	_disconnect_host_enemy_faction_signal(net_id)
	_pending_host_faction_changes.erase(net_id)
	_host_target_presentation_states.erase(net_id)
	_pending_host_target_presentation_states.erase(net_id)
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
		or not _is_valid_damage_presentation_flags(
			int(feedback.get("presentation_flags", 0))
		)
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
		"presentation_flags": int(feedback.get("presentation_flags", 0)),
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
	# 目标终结产生的 NONE 与 terminal 同属可靠 CH5；先广播清理态，避免
	# terminal 后 repair/跨信道晚包短暂重建对已死亡目标的锁定表现。
	for batch in drain_host_target_presentation_batches():
		_emit_target_presentation_batch_broadcast(batch)
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
			int(terminal.get("presentation_flags", 0)),
			_get_network_time(),
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
	presentation_flags: int
) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
		or not _is_valid_terminal_reason(reason)
		or not event_position.is_finite()
		or not impact_direction.is_finite()
		or not _is_valid_damage_type(damage_type)
		or not _is_valid_damage_presentation_flags(presentation_flags)
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
					var safe_presentation_flags := _normalize_damage_presentation_flags(
						presentation_flags,
						impact_direction
					)
					if safe_presentation_flags != 0:
						enemy.play_multiplayer_damage_feedback(
							impact_direction,
							safe_presentation_flags
						)
			remove_client_enemy(net_id, true, false, false, true)
		ENEMY_TERMINAL_ESCAPED:
			remote_enemy_escape_requested.emit(net_id)
			remove_client_enemy(net_id, false, false, false, true)
		_:
			remove_client_enemy(net_id, false, false, false, true)


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
	remove_client_enemy(net_id, true, false, false, true)


func receive_enemy_removed(net_id: int) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
	):
		return
	mark_client_terminal(net_id)
	remove_client_enemy(net_id, true, false, false, true)


func receive_enemy_escaped(net_id: int) -> void:
	if (
		not is_client_view()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(net_id)
	):
		return
	mark_client_terminal(net_id)
	remote_enemy_escape_requested.emit(net_id)
	remove_client_enemy(net_id, false, false, false, true)


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
	target_descriptor: CombatTargetDescriptor,
	action_position: Vector2,
	assignment_revision: int
) -> void:
	if (
		not _is_host_lifecycle_bound()
		or not _is_valid_network_target_descriptor(target_descriptor)
	):
		return
	var host_action_time := _get_network_time()
	var record := {
		"kind": CLIENT_ENEMY_ACTION_KIND_TARGET,
		"net_id": net_id,
		"action_name": action_name,
		"target_kind": (
			target_descriptor.kind
			if target_descriptor != null
			else _CombatTargetDescriptor.Kind.NONE
		),
		"target_id": target_descriptor.id if target_descriptor != null else 0,
		"target_revision": (
			target_descriptor.revision if target_descriptor != null else 0
		),
		"target_fallback_position": (
			target_descriptor.fallback_position
			if target_descriptor != null
			else Vector2.ZERO
		),
		"action_position": action_position,
		"action_id": assignment_revision,
		"assignment_revision": assignment_revision,
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
			target_descriptor.kind,
			target_descriptor.id,
			target_descriptor.revision,
			target_descriptor.fallback_position,
			action_position,
			assignment_revision,
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
	target_kind: int,
	target_id: int,
	target_revision: int,
	target_fallback_position: Vector2,
	action_position: Vector2,
	assignment_revision: int,
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
	var target_descriptor := _CombatTargetDescriptor.create(
		target_kind,
		target_id,
		target_revision,
		target_fallback_position
	)
	if target_descriptor == null:
		return
	receive_enemy_target_action(
		net_id,
		StringName(action_name),
		target_descriptor,
		action_position,
		assignment_revision,
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
	# v51 keeps the optional -1 timestamp default for compatibility with the
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
		and config_path.length() <= ENEMY_CONFIG_PATH_WIRE_MAX_LENGTH
		and not RuntimeContentCatalogScript.get_enemy_id_for_path(
			config_path
		).is_empty()
		and spawn_position.is_finite()
		and is_finite(host_spawn_timestamp)
		and host_spawn_timestamp >= 0.0
	)


func _is_valid_spawn_batch_payload(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array,
	faction_ids: PackedByteArray = PackedByteArray(),
	faction_revisions: PackedInt32Array = PackedInt32Array()
) -> bool:
	var record_count := net_ids.size()
	var has_faction_roster := not faction_ids.is_empty()
	if (
		record_count <= 0
		or record_count > ENEMY_SPAWN_BATCH_MAX_RECORDS
		or config_paths.size() != record_count
		or positions.size() != record_count
		or spawn_times.size() != record_count
		or has_faction_roster != (not faction_revisions.is_empty())
		or (has_faction_roster and faction_ids.size() != record_count)
		or (has_faction_roster and faction_revisions.size() != record_count)
	):
		return false
	var seen_net_ids: Dictionary[int, bool] = {}
	for record_index in range(record_count):
		var net_id := net_ids[record_index]
		if seen_net_ids.has(net_id):
			return false
		seen_net_ids[net_id] = true
		if not _is_valid_spawn_record(
			net_id,
			config_paths[record_index],
			positions[record_index],
			spawn_times[record_index]
		):
			return false
		if (
			has_faction_roster
			and not _is_valid_faction_state(
				int(faction_ids[record_index]),
				faction_revisions[record_index]
			)
		):
			return false
	return true


func _is_valid_faction_change_batch_payload(
	net_ids: PackedInt32Array,
	faction_ids: PackedByteArray,
	faction_revisions: PackedInt32Array
) -> bool:
	var record_count := net_ids.size()
	if (
		record_count <= 0
		or record_count > ENEMY_SPAWN_BATCH_MAX_RECORDS
		or faction_ids.size() != record_count
		or faction_revisions.size() != record_count
	):
		return false
	var seen_net_ids: Dictionary[int, bool] = {}
	for record_index in range(record_count):
		var net_id := net_ids[record_index]
		if (
			net_id <= 0
			or seen_net_ids.has(net_id)
			or not _NetConstants.is_valid_network_combat_value(net_id)
			or not _is_valid_faction_state(
				int(faction_ids[record_index]),
				faction_revisions[record_index]
			)
		):
			return false
		seen_net_ids[net_id] = true
	return true


func _is_valid_faction_state(faction_id: int, faction_revision: int) -> bool:
	return (
		_CombatRelationService.is_valid_faction_id(faction_id)
		and faction_revision >= 0
		and _NetConstants.is_valid_network_combat_value(faction_revision)
	)


func _is_valid_target_presentation_phase(phase: int) -> bool:
	return phase in [
		Enemy.TargetPresentationPhase.NONE,
		Enemy.TargetPresentationPhase.SNIPER_LOCK,
		Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
	]


func _is_valid_target_presentation_descriptor(
	phase: int,
	descriptor: CombatTargetDescriptor
) -> bool:
	if descriptor == null or not descriptor.is_valid():
		return false
	if phase == Enemy.TargetPresentationPhase.NONE:
		return descriptor.kind == _CombatTargetDescriptor.Kind.NONE
	return _is_valid_network_target_descriptor(descriptor)


func _is_valid_target_presentation_record(record: Dictionary) -> bool:
	var net_id := int(record.get("net_id", 0))
	var state_revision := int(record.get("state_revision", 0))
	var phase := int(record.get("phase", -1))
	var start_time := float(record.get("start_time", -1.0))
	var end_time := float(record.get("end_time", -1.0))
	var descriptor := _target_descriptor_from_action_record(record)
	return (
		net_id > 0
		and _NetConstants.is_valid_network_combat_value(net_id)
		and state_revision > 0
		and _NetConstants.is_valid_network_combat_value(state_revision)
		and _is_valid_target_presentation_phase(phase)
		and _is_valid_target_presentation_descriptor(phase, descriptor)
		and is_finite(start_time)
		and start_time >= 0.0
		and is_finite(end_time)
		and end_time >= start_time
		and (
			(phase == Enemy.TargetPresentationPhase.NONE and end_time == start_time)
			or (
				phase != Enemy.TargetPresentationPhase.NONE
				and end_time > start_time
			)
		)
		and (record.get("action_position", Vector2.INF) as Vector2).is_finite()
	)


func _is_valid_target_presentation_batch_payload(
	net_ids: PackedInt32Array,
	state_revisions: PackedInt32Array,
	phases: PackedByteArray,
	target_kinds: PackedByteArray,
	target_ids: PackedInt32Array,
	target_revisions: PackedInt32Array,
	target_fallback_positions: PackedVector2Array,
	host_start_times: PackedFloat64Array,
	host_end_times: PackedFloat64Array,
	action_positions: PackedVector2Array
) -> bool:
	var record_count := net_ids.size()
	if (
		record_count <= 0
		or record_count > TARGET_PRESENTATION_BATCH_MAX_RECORDS
		or state_revisions.size() != record_count
		or phases.size() != record_count
		or target_kinds.size() != record_count
		or target_ids.size() != record_count
		or target_revisions.size() != record_count
		or target_fallback_positions.size() != record_count
		or host_start_times.size() != record_count
		or host_end_times.size() != record_count
		or action_positions.size() != record_count
	):
		return false
	var seen_ids: Dictionary[int, bool] = {}
	for record_index in range(record_count):
		var net_id := net_ids[record_index]
		if seen_ids.has(net_id):
			return false
		seen_ids[net_id] = true
		if not _is_valid_target_presentation_record({
			"net_id": net_id,
			"state_revision": state_revisions[record_index],
			"phase": int(phases[record_index]),
			"target_kind": int(target_kinds[record_index]),
			"target_id": target_ids[record_index],
			"target_revision": target_revisions[record_index],
			"target_fallback_position": target_fallback_positions[record_index],
			"start_time": host_start_times[record_index],
			"end_time": host_end_times[record_index],
			"action_position": action_positions[record_index],
		}):
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
	target_descriptor_or_peer_id: Variant,
	action_position: Vector2,
	assignment_revision: int,
	mapped_action_time: float,
	received_at: float,
	host_action_timestamp: float = -1.0
) -> void:
	var target_descriptor: CombatTargetDescriptor = null
	if target_descriptor_or_peer_id is CombatTargetDescriptor:
		target_descriptor = (
			target_descriptor_or_peer_id as CombatTargetDescriptor
		)
	elif target_descriptor_or_peer_id is int:
		# v93/local callers passed only a player peer ID. Normalize that legacy
		# boundary immediately; all validation, pending and replay paths below use
		# the v94 descriptor record.
		target_descriptor = _CombatTargetDescriptor.create_player(
			int(target_descriptor_or_peer_id),
			0,
			action_position
		)
	if target_descriptor == null:
		return
	_receive_action_record({
		"kind": CLIENT_ENEMY_ACTION_KIND_TARGET,
		"net_id": net_id,
		"action_name": action_name,
		"target_kind": (
			target_descriptor.kind
			if target_descriptor != null
			else _CombatTargetDescriptor.Kind.NONE
		),
		"target_id": target_descriptor.id if target_descriptor != null else 0,
		"target_revision": (
			target_descriptor.revision if target_descriptor != null else 0
		),
		"target_fallback_position": (
			target_descriptor.fallback_position
			if target_descriptor != null
			else Vector2.ZERO
		),
		"action_position": action_position,
		"action_id": assignment_revision,
		"assignment_revision": assignment_revision,
		"action_time": mapped_action_time,
		"host_action_timestamp": host_action_timestamp,
		"received_at": received_at,
	}, received_at)


## Protocol-v93/local test compatibility. The legacy peer-only entry is kept at
## the boundary, while every internal record uses the generic descriptor shape.
func receive_enemy_player_target_action_legacy(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	assignment_revision: int,
	mapped_action_time: float,
	received_at: float,
	host_action_timestamp: float = -1.0
) -> void:
	var descriptor := _CombatTargetDescriptor.create_player(
		target_peer_id,
		0,
		action_position
	)
	if descriptor == null:
		return
	receive_enemy_target_action(
		net_id,
		action_name,
		descriptor,
		action_position,
		assignment_revision,
		mapped_action_time,
		received_at,
		host_action_timestamp
	)


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
	var source_snapshot := owner_player.create_damage_source_snapshot(
		enemy_net_id,
		&"tiyi_high_noon"
	)
	apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		resolved_damage,
		impact_direction,
		EnemyConfig.DamageType.MAGIC,
		false,
		source_snapshot
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
	var source_snapshot := (
		_projectile_coordinator.get_projectile_damage_source_snapshot(
			projectile_id
		)
	)
	if source_snapshot == null:
		return
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
		get_player_projectile_damage_type(projectile_type),
		true,
		source_snapshot
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
	show_hit_particles: bool = true,
	source_snapshot: DamageSourceSnapshot = null
) -> bool:
	if enemy_net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return false
	var request := DamageRequest.new(damage, int(damage_type))
	if source_snapshot != null:
		request.with_source_snapshot(source_snapshot)
	request.with_directions(impact_direction)
	request.with_flag(
		CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
		not show_hit_particles
	)
	var active_presentation_flags := _get_damage_presentation_flags(
		request,
		impact_direction,
		damage
	)
	set_active_damage_feedback_context(
		enemy_net_id,
		impact_direction,
		damage_type,
		active_presentation_flags
	)
	var result := enemy.apply_combat_damage(request)
	clear_active_damage_feedback_context(enemy_net_id)
	if not result.accepted:
		return false
	if result.lethal:
		# 同步 defeated 信号已经把最终一击纳入可靠 terminal 事件。
		return true
	var network_damage := _clamp_damage_feedback_for_network(
		result.resolved_damage
	)
	var presentation_flags := _get_damage_presentation_flags(
		request,
		impact_direction,
		network_damage
	)
	_queue_host_damage_feedback(
		enemy_net_id,
		result.health_after,
		enemy.health_revision,
		network_damage,
		impact_direction,
		damage_type,
		presentation_flags
	)
	return true


func _queue_host_damage_feedback(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	presentation_flags: int
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
		presentation_flags
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
				batch.presentation_flags,
			]
		)


func apply_damage_feedback_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	health_revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	presentation_flags: PackedByteArray
) -> void:
	var record_count := mini(
		net_ids.size(),
		mini(
			health_values.size(),
			mini(
				health_revisions.size(),
				mini(
					damage_values.size(),
					mini(directions.size(), mini(damage_types.size(), presentation_flags.size()))
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
			or not _is_valid_damage_presentation_flags(presentation_flags[record_index])
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
		var safe_presentation_flags := _normalize_damage_presentation_flags(
			presentation_flags[record_index],
			directions[record_index]
		)
		if safe_presentation_flags != 0:
			enemy.play_multiplayer_damage_feedback(
				directions[record_index],
				safe_presentation_flags
			)


func apply_damage_event(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	presentation_flags: int
) -> void:
	if (
		enemy_net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
		or not _is_valid_damage_presentation_flags(presentation_flags)
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
	var safe_presentation_flags := _normalize_damage_presentation_flags(
		presentation_flags,
		impact_direction
	)
	if safe_presentation_flags != 0:
		enemy.play_multiplayer_damage_feedback(impact_direction, safe_presentation_flags)
	if is_dead:
		remove_client_enemy(enemy_net_id, true)


func set_active_damage_feedback_context(
	enemy_net_id: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	presentation_flags: int
) -> void:
	active_enemy_damage_feedback_context[enemy_net_id] = {
		"impact_direction": impact_direction,
		"damage_type": int(damage_type),
		"presentation_flags": presentation_flags,
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
	presentation_flags: int
) -> void:
	if enemy_net_id <= 0:
		return
	if (
		not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
		or not _is_valid_damage_presentation_flags(presentation_flags)
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
			"presentation_flags": 0,
		}
	feedback["current_health"] = current_health
	feedback["health_revision"] = health_revision
	var combined_damage := _merge_network_damage_feedback_amounts(
		int(feedback.get("damage", 0)),
		confirmed_damage
	)
	feedback["damage"] = combined_damage
	var previous_flags := int(feedback.get("presentation_flags", 0))
	feedback["impact_direction"] = _merge_damage_feedback_direction(
		feedback.get("impact_direction", Vector2.ZERO) as Vector2,
		previous_flags,
		impact_direction,
		presentation_flags
	)
	feedback["damage_type"] = int(damage_type)
	feedback["presentation_flags"] = previous_flags | presentation_flags
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
			batch.presentation_flags.append(int(feedback.get("presentation_flags", 0)))
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
		enemy = _runtime.get_network_enemy(enemy_net_id)
	var current_health := int(pending_feedback.get("current_health", 0))
	var health_revision := int(pending_feedback.get("health_revision", 0))
	var confirmed_damage := _clamp_damage_feedback_for_network(
		int(pending_feedback.get("damage", 0))
	)
	var impact_direction := pending_feedback.get("impact_direction", Vector2.ZERO) as Vector2
	var damage_type := int(
		pending_feedback.get("damage_type", EnemyConfig.DamageType.PHYSICAL)
	)
	var presentation_flags := int(pending_feedback.get("presentation_flags", 0))
	if enemy != null and is_instance_valid(enemy):
		current_health = maxi(enemy.current_health, 0)
		health_revision = enemy.health_revision
		var lethal_result := enemy.last_damage_result
		if lethal_result != null and lethal_result.accepted and lethal_result.lethal:
			confirmed_damage = _merge_network_damage_feedback_amounts(
				confirmed_damage,
				lethal_result.resolved_damage
			)
			if lethal_result.request != null:
				var lethal_impact_direction := (
					lethal_result.request.get_safe_impact_direction()
				)
				damage_type = lethal_result.request.damage_type
				var lethal_presentation_flags := _get_damage_presentation_flags(
					lethal_result.request,
					lethal_impact_direction,
					lethal_result.resolved_damage
				)
				impact_direction = _merge_damage_feedback_direction(
					impact_direction,
					presentation_flags,
					lethal_impact_direction,
					lethal_presentation_flags
				)
				presentation_flags |= lethal_presentation_flags
	if not active_context.is_empty():
		var active_presentation_flags := int(active_context.get("presentation_flags", 0))
		impact_direction = _merge_damage_feedback_direction(
			impact_direction,
			presentation_flags,
			active_context.get("impact_direction", impact_direction) as Vector2,
			active_presentation_flags
		)
		damage_type = int(active_context.get("damage_type", damage_type))
		presentation_flags |= active_presentation_flags
	return {
		"current_health": current_health,
		"health_revision": health_revision,
		"damage": confirmed_damage,
		"impact_direction": impact_direction,
		"damage_type": damage_type,
		"presentation_flags": presentation_flags,
	}


func _get_damage_presentation_flags(
	request: DamageRequest,
	impact_direction: Vector2,
	display_damage: int
) -> int:
	if request == null or display_damage <= 0:
		return 0
	var presentation_flags := 0
	if (
		impact_direction != Vector2.ZERO
		and not request.has_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	):
		presentation_flags |= CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
	if (
		not request.has_flag(CombatTypes.DamageFlag.PERIODIC)
		and not request.has_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	):
		presentation_flags |= CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	return presentation_flags


func _clamp_damage_feedback_for_network(damage: int) -> int:
	return clampi(
		damage,
		_NetConstants.NETWORK_COMBAT_VALUE_MIN,
		_NetConstants.NETWORK_COMBAT_VALUE_MAX
	)


func _merge_network_damage_feedback_amounts(
	current_damage: int,
	incoming_damage: int
) -> int:
	# 展示值可以超过目标生命，但 wire 仍必须保持无符号语义的 signed-int32 范围。
	var safe_current := _clamp_damage_feedback_for_network(current_damage)
	var safe_incoming := _clamp_damage_feedback_for_network(incoming_damage)
	return mini(
		safe_current + safe_incoming,
		_NetConstants.NETWORK_COMBAT_VALUE_MAX
	)


func _is_valid_damage_presentation_flags(presentation_flags: int) -> bool:
	return (
		presentation_flags >= 0
		and (presentation_flags & ~DAMAGE_PRESENTATION_FLAGS_MASK) == 0
	)


func _normalize_damage_presentation_flags(
	presentation_flags: int,
	impact_direction: Vector2
) -> int:
	var normalized := presentation_flags & DAMAGE_PRESENTATION_FLAGS_MASK
	if impact_direction == Vector2.ZERO:
		normalized &= ~CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
	return normalized


func _merge_damage_feedback_direction(
	current_direction: Vector2,
	current_flags: int,
	incoming_direction: Vector2,
	incoming_flags: int
) -> Vector2:
	if (
		(incoming_flags & CombatTypes.DamageFeedbackFlag.HIT_PARTICLES) != 0
		and incoming_direction != Vector2.ZERO
	):
		return incoming_direction
	if (
		(current_flags & CombatTypes.DamageFeedbackFlag.HIT_PARTICLES) != 0
		and current_direction != Vector2.ZERO
	):
		return current_direction
	return incoming_direction


func get_host_enemy(enemy_net_id: int) -> Enemy:
	return _runtime.get_enemy_for_net_id(enemy_net_id) if is_bound() else null


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func get_client_enemy(enemy_net_id: int) -> Enemy:
	return get_valid_client_enemy(enemy_net_id)


func get_valid_client_enemy(enemy_net_id: int) -> Enemy:
	if not is_bound():
		return null
	var enemy := _runtime.get_network_enemy(enemy_net_id)
	if enemy == null:
		enemy_spawn_snapshot_times.erase(enemy_net_id)
		enemy_spawn_incarnation_tokens.erase(enemy_net_id)
		enemy_interpolators.erase(enemy_net_id)
		_offscreen_interpolation_slots.erase(enemy_net_id)
		return null
	return enemy


func get_remote_enemy_count() -> int:
	return _runtime.get_network_enemy_count() if is_bound() else 0


func get_remote_enemy_ids() -> Array[int]:
	var result: Array[int] = []
	if is_bound():
		result.assign(_runtime.get_network_enemy_ids())
	return result


func get_all_client_combat_targets() -> Array[Enemy]:
	var result: Array[Enemy] = []
	if not is_bound():
		return result
	for enemy in _runtime.get_network_enemies():
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
	if not is_bound():
		return null
	for enemy in _runtime.get_network_enemies():
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
	if not is_bound():
		return
	for enemy in _runtime.get_network_enemies():
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
			mark_client_terminal(net_id)
			remove_client_enemy(net_id, false, false, false, true)


func apply_network_health(
	enemy_node: Enemy,
	current_health: int,
	health_revision: int
) -> bool:
	return (
		enemy_node != null
		and enemy_node.try_apply_multiplayer_health_snapshot(
			maxi(current_health, 0),
			health_revision
		)
	)


func get_buffered_enemy_position(
	net_id: int,
	fallback_position: Vector2,
	current_time: float
) -> Vector2:
	var interpolator := enemy_interpolators.get(net_id) as NetInterpolator
	if interpolator == null or interpolator.get_buffer_size() <= 0:
		return fallback_position
	return interpolator.get_interpolated_position(current_time)


func reconcile_roster(
	seen_enemy_ids: Dictionary,
	snapshot_time: float,
	raw_host_timestamp: float = -1.0
) -> void:
	var stale_ids: Array[int] = []
	for net_id in get_remote_enemy_ids():
		if seen_enemy_ids.has(net_id):
			continue
		if _is_snapshot_older_than_enemy_incarnation(
			net_id,
			snapshot_time,
			raw_host_timestamp
		):
			continue
		stale_ids.append(net_id)
	for net_id in stale_ids:
		# Full roster absence is an authoritative terminal fact for the current
		# incarnation. Keep a tombstone so delayed CH7 actions cannot repopulate
		# pending state; a later authoritative spawn clears it transactionally.
		mark_client_terminal(net_id, raw_host_timestamp)
		remove_client_enemy(net_id, false, false, false, true)


func _is_snapshot_older_than_enemy_incarnation(
	net_id: int,
	snapshot_time: float,
	raw_host_timestamp: float
) -> bool:
	if net_id <= 0:
		return false
	if (
		is_finite(raw_host_timestamp)
		and raw_host_timestamp >= 0.0
		and enemy_spawn_incarnation_tokens.has(net_id)
	):
		var incarnation_token := float(
			enemy_spawn_incarnation_tokens.get(net_id, -INF)
		)
		return (
			is_finite(incarnation_token)
			and raw_host_timestamp + ENEMY_SPAWN_TOKEN_EPSILON
			< incarnation_token
		)
	# 旧直调/旧协议没有 raw Host 时间；保留原 mapped-time CAS，但不能在
	# raw 时间存在时叠加它，否则 offset 漂移会把正确的新快照误判为旧。
	return (
		enemy_spawn_snapshot_times.has(net_id)
		and snapshot_time
		< float(enemy_spawn_snapshot_times.get(net_id, -INF))
	)


func _prune_snapshot_receive_baseline_for_roster(
	seen_enemy_ids: Dictionary,
	snapshot_time: float,
	raw_host_timestamp: float
) -> void:
	var live_baseline_ids := seen_enemy_ids.duplicate()
	# 旧 full roster 缺少 spawn 后的新 incarnation 时，实体和其新 baseline
	# 必须一起保留；否则虽然代理未被误删，下一条 delta 仍会因基线丢失中断。
	for net_id in get_remote_enemy_ids():
		if _is_snapshot_older_than_enemy_incarnation(
			net_id,
			snapshot_time,
			raw_host_timestamp
		):
			live_baseline_ids[net_id] = true
	_snapshot_manager.prune_enemy_receive_baseline_to_ids(live_baseline_ids)


func remove_client_enemy(
	net_id: int,
	play_death_sequence: bool,
	preserve_interpolator: bool = false,
	preserve_pending_action: bool = false,
	preserve_terminal_marker: bool = false
) -> void:
	var enemy := get_valid_client_enemy(net_id)
	if enemy != null and is_instance_valid(enemy):
		if play_death_sequence:
			enemy.play_multiplayer_death_sequence()
		else:
			enemy.queue_free()
	if not preserve_pending_action:
		erase_pending_enemy_action(net_id)
	_erase_pending_enemy_faction_change(net_id)
	_erase_pending_target_presentation_state(net_id)
	_erase_pending_actions_targeting_enemy(net_id)
	_client_enemy_action_revisions.erase(net_id)
	_client_target_presentation_revisions.erase(net_id)
	_client_target_presentation_phases.erase(net_id)
	_client_target_presentation_terminal_revisions.erase(net_id)
	if not preserve_terminal_marker:
		clear_client_terminal_marker(net_id)
		clear_client_terminal_incarnation_token(net_id)
	enemy_spawn_snapshot_times.erase(net_id)
	enemy_spawn_incarnation_tokens.erase(net_id)
	if is_bound():
		_runtime.unregister_network_enemy(net_id, enemy)
	if not preserve_interpolator:
		enemy_interpolators.erase(net_id)
	_offscreen_interpolation_slots.erase(net_id)


func _replay_ready_pending_enemy_actions(
	current_time: float,
	runtime: CombatRuntimeBase
) -> int:
	if (
		not is_finite(current_time)
		or runtime == null
		or not is_instance_valid(runtime)
	):
		return 0
	var ordered_ids: Array[int] = []
	var cursor := _pending_enemy_action_oldest_id
	while cursor > 0 and ordered_ids.size() < pending_enemy_actions.size():
		ordered_ids.append(cursor)
		cursor = int(_pending_enemy_action_next_ids.get(cursor, 0))
	var replayed_count := 0
	for net_id in ordered_ids:
		var pending := pending_enemy_actions.get(net_id, {}) as Dictionary
		if pending.is_empty():
			continue
		if _is_pending_enemy_action_expired(pending, current_time):
			erase_pending_enemy_action(net_id)
			continue
		var enemy := get_valid_client_enemy(net_id)
		if enemy == null or not is_instance_valid(enemy):
			continue
		var delivery_state := _deliver_action_record(
			pending,
			enemy,
			current_time,
			runtime
		)
		if delivery_state == TARGET_ACTION_RESOLUTION_WAITING:
			continue
		erase_pending_enemy_action(net_id)
		replayed_count += 1
	return replayed_count


func consume_pending_enemy_action(net_id: int, current_time: float) -> bool:
	var pending := pending_enemy_actions.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return false
	if _is_pending_enemy_action_expired(pending, current_time):
		erase_pending_enemy_action(net_id)
		return false
	var enemy := get_valid_client_enemy(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return false
	var delivery_state := _deliver_action_record(
		pending,
		enemy,
		current_time,
		_runtime
	)
	if delivery_state == TARGET_ACTION_RESOLUTION_WAITING:
		return false
	erase_pending_enemy_action(net_id)
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


func mark_client_terminal(net_id: int, raw_terminal_token: float = NAN) -> void:
	if net_id <= 0:
		return
	var retained_token := float(
		client_terminal_enemy_incarnation_tokens.get(net_id, -INF)
	)
	var incarnation_token := float(
		enemy_spawn_incarnation_tokens.get(net_id, -INF)
	)
	if is_finite(incarnation_token) and incarnation_token >= 0.0:
		retained_token = maxf(retained_token, incarnation_token)
	if is_finite(raw_terminal_token) and raw_terminal_token >= 0.0:
		retained_token = maxf(retained_token, raw_terminal_token)
	if is_finite(retained_token) and retained_token >= 0.0:
		client_terminal_enemy_incarnation_tokens[net_id] = retained_token
	erase_pending_enemy_action(net_id)
	_erase_pending_enemy_faction_change(net_id)
	_erase_pending_target_presentation_state(net_id)
	_erase_pending_actions_targeting_enemy(net_id)
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


func clear_client_terminal_incarnation_token(net_id: int) -> bool:
	return client_terminal_enemy_incarnation_tokens.erase(net_id)


func _is_client_terminal_blocked(net_id: int) -> bool:
	return (
		net_id > 0
		and (
			client_terminal_enemy_ids.has(net_id)
			or client_terminal_enemy_incarnation_tokens.has(net_id)
		)
	)


func _is_spawn_blocked_by_terminal_incarnation(
	net_id: int,
	incarnation_token: float
) -> bool:
	if (
		net_id <= 0
		or not is_finite(incarnation_token)
		or not client_terminal_enemy_incarnation_tokens.has(net_id)
	):
		return false
	var terminal_token := float(
		client_terminal_enemy_incarnation_tokens.get(net_id, -INF)
	)
	return (
		is_finite(terminal_token)
		and terminal_token >= 0.0
		and incarnation_token
		<= terminal_token + ENEMY_SPAWN_TOKEN_EPSILON
	)


func clear_client_terminal_markers() -> void:
	client_terminal_enemy_ids.clear()
	client_terminal_enemy_incarnation_tokens.clear()
	_client_terminal_enemy_previous_ids.clear()
	_client_terminal_enemy_next_ids.clear()
	_client_terminal_enemy_oldest_id = 0
	_client_terminal_enemy_newest_id = 0


func _erase_pending_actions_targeting_enemy(target_net_id: int) -> void:
	var stale_source_ids: Array[int] = []
	for source_net_id_variant in pending_enemy_actions.keys():
		var source_net_id := int(source_net_id_variant)
		var record := pending_enemy_actions.get(source_net_id, {}) as Dictionary
		if (
			int(record.get("kind", -1)) == CLIENT_ENEMY_ACTION_KIND_TARGET
			and int(record.get("target_kind", -1))
			== _CombatTargetDescriptor.Kind.ENEMY
			and int(record.get("target_id", 0)) == target_net_id
		):
			stale_source_ids.append(source_net_id)
	for source_net_id in stale_source_ids:
		erase_pending_enemy_action(source_net_id)
	_clear_pending_target_presentation_states_for_target(
		_CombatTargetDescriptor.Kind.ENEMY,
		target_net_id
	)


func _clear_pending_target_presentation_states_for_target(
	target_kind: int,
	target_id: int
) -> void:
	var source_ids: Array[int] = []
	for source_net_id_variant in pending_enemy_target_presentation_states.keys():
		var source_net_id := int(source_net_id_variant)
		var record := pending_enemy_target_presentation_states.get(
			source_net_id,
			{}
		) as Dictionary
		if (
			int(record.get("phase", Enemy.TargetPresentationPhase.NONE))
			!= Enemy.TargetPresentationPhase.NONE
			and int(record.get("target_kind", -1)) == target_kind
			and int(record.get("target_id", 0)) == target_id
		):
			source_ids.append(source_net_id)
	for source_net_id in source_ids:
		var record := pending_enemy_target_presentation_states.get(
			source_net_id,
			{}
		) as Dictionary
		var clear_record := _make_target_presentation_clear_record(record)
		_commit_client_target_presentation_watermarks(clear_record)
		var source_enemy := get_valid_client_enemy(source_net_id)
		if source_enemy == null or not is_instance_valid(source_enemy):
			pending_enemy_target_presentation_states[source_net_id] = clear_record
			continue
		source_enemy.apply_multiplayer_target_presentation_state(
			Enemy.TargetPresentationPhase.NONE,
			null,
			clear_record.get("action_position", Vector2.ZERO) as Vector2,
			int(clear_record.get("state_revision", 0)),
			0.0,
			0.0
		)
		_erase_pending_target_presentation_state(source_net_id)


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if _is_host_lifecycle_bound():
		_clear_host_target_presentation_states_for_target(
			_CombatTargetDescriptor.Kind.PLAYER,
			peer_id,
			_get_network_time()
		)
		if is_inside_tree():
			for batch in drain_host_target_presentation_batches():
				_emit_target_presentation_batch_broadcast(batch)
	_snapshot_manager.clear_peer_delta_cache(peer_id)
	_snapshot_cohort_peers.erase(peer_id)
	_last_keyframe_time_by_peer.erase(peer_id)
	var pending_target_action_ids: Array[int] = []
	for net_id_variant in pending_enemy_actions.keys():
		var net_id := int(net_id_variant)
		var record := pending_enemy_actions.get(net_id, {}) as Dictionary
		if (
			int(record.get("kind", -1)) == CLIENT_ENEMY_ACTION_KIND_TARGET
			and int(record.get("target_kind", -1))
			== _CombatTargetDescriptor.Kind.PLAYER
			and int(record.get("target_id", 0)) == peer_id
		):
			pending_target_action_ids.append(net_id)
	for net_id in pending_target_action_ids:
		erase_pending_enemy_action(net_id)
	_clear_pending_target_presentation_states_for_target(
		_CombatTargetDescriptor.Kind.PLAYER,
		peer_id
	)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_enemy_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func reset_session_state() -> void:
	_disconnect_all_host_enemy_faction_signals()
	_snapshot_manager.reset_delta_cache()
	if is_bound():
		if is_client_view():
			for net_id in get_remote_enemy_ids():
				remove_client_enemy(net_id, false)
		_runtime.clear_network_enemy_registry()
	enemy_interpolators.clear()
	enemy_spawn_snapshot_times.clear()
	enemy_spawn_incarnation_tokens.clear()
	_host_enemy_spawn_times.clear()
	_host_snapshot_live_ids.clear()
	_last_keyframe_time_by_peer.clear()
	_snapshot_cohort_peers.clear()
	pending_enemy_snapshot_batches.clear()
	pending_enemy_damage_feedback.clear()
	active_enemy_damage_feedback_context.clear()
	clear_pending_enemy_actions()
	clear_pending_enemy_faction_changes()
	pending_enemy_target_presentation_states.clear()
	_pending_target_presentation_order.clear()
	_client_enemy_action_revisions.clear()
	_client_target_presentation_revisions.clear()
	_client_target_presentation_phases.clear()
	_client_target_presentation_terminal_revisions.clear()
	clear_client_terminal_markers()
	host_terminal_enemy_ids.clear()
	_pending_host_spawns.clear()
	_pending_host_faction_changes.clear()
	_host_target_presentation_states.clear()
	_pending_host_target_presentation_states.clear()
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
	var evicted_any := false
	for pending_batch_id_variant in pending_enemy_snapshot_batches.keys():
		var pending_batch_id := int(pending_batch_id_variant)
		if pending_batch_id < current_batch_id - 2:
			_snapshot_incomplete_batch_evict_count += 1
			pending_enemy_snapshot_batches.erase(pending_batch_id)
			evicted_any = true
	if evicted_any:
		_prune_snapshot_receive_state_to_active_candidates()


func _prune_snapshot_receive_state_to_active_candidates() -> void:
	var live_ids: Dictionary = {}
	for net_id in get_remote_enemy_ids():
		if net_id > 0:
			live_ids[net_id] = true
	for pending_batch_variant in pending_enemy_snapshot_batches.values():
		var pending_batch := pending_batch_variant as Dictionary
		if pending_batch == null:
			continue
		var seen := pending_batch.get("seen", {}) as Dictionary
		for net_id_variant in seen.keys():
			var net_id := int(net_id_variant)
			if net_id > 0:
				live_ids[net_id] = true
	_snapshot_manager.prune_enemy_receive_baseline_to_ids(live_ids)
	var stale_interpolator_ids: Array[int] = []
	for net_id_variant in enemy_interpolators.keys():
		var net_id := int(net_id_variant)
		if not live_ids.has(net_id):
			stale_interpolator_ids.append(net_id)
	for net_id in stale_interpolator_ids:
		enemy_interpolators.erase(net_id)
		_offscreen_interpolation_slots.erase(net_id)


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
	var declared_count := stream.get_u16()
	if declared_count == 0:
		return decoded_count == 0 and data.size() == 2
	return decoded_count == declared_count


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


func _register_client_enemy(net_id: int, enemy: Enemy) -> bool:
	if not is_bound():
		return false
	return _register_client_enemy_on_runtime(_runtime, net_id, enemy, null)


func _register_client_enemy_on_runtime(
	runtime: CombatRuntimeBase,
	net_id: int,
	enemy: Enemy,
	expected_parent: Node
) -> bool:
	if (
		runtime == null
		or not is_instance_valid(runtime)
		or net_id <= 0
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_queued_for_deletion()
		or (
			expected_parent != null
			and (
				not is_instance_valid(expected_parent)
				or expected_parent.is_queued_for_deletion()
				or enemy.get_parent() != expected_parent
			)
		)
	):
		return false
	var registered: bool = runtime.register_network_enemy(net_id, enemy)
	var indexed_enemy: Enemy = runtime.get_network_enemy(net_id)
	if (
		not registered
		or indexed_enemy != enemy
		or not is_instance_valid(indexed_enemy)
		or indexed_enemy.is_queued_for_deletion()
		or (
			expected_parent != null
			and (
				not is_instance_valid(expected_parent)
				or expected_parent.is_queued_for_deletion()
				or indexed_enemy.get_parent() != expected_parent
			)
		)
	):
		if indexed_enemy == enemy:
			runtime.unregister_network_enemy(net_id, enemy)
		return false
	var callback := _on_client_enemy_tree_exited.bind(net_id, enemy)
	if not enemy.tree_exited.is_connected(callback):
		enemy.tree_exited.connect(callback)
	return true


func _on_client_enemy_tree_exited(net_id: int, exiting_enemy: Enemy) -> void:
	var indexed_enemy := (
		_runtime.get_network_enemy(net_id) if is_bound() else null
	)
	if is_instance_valid(indexed_enemy) and indexed_enemy != exiting_enemy:
		return
	erase_pending_enemy_action(net_id)
	_erase_pending_enemy_faction_change(net_id)
	_erase_pending_target_presentation_state(net_id)
	_erase_pending_actions_targeting_enemy(net_id)
	_client_enemy_action_revisions.erase(net_id)
	_client_target_presentation_revisions.erase(net_id)
	_client_target_presentation_phases.erase(net_id)
	_client_target_presentation_terminal_revisions.erase(net_id)
	enemy_spawn_snapshot_times.erase(net_id)
	enemy_spawn_incarnation_tokens.erase(net_id)
	enemy_interpolators.erase(net_id)
	_offscreen_interpolation_slots.erase(net_id)
	if is_bound():
		_runtime.unregister_network_enemy(net_id, exiting_enemy)


func _receive_action_record(record: Dictionary, current_time: float) -> void:
	if not is_client_view() or not _is_valid_action_record(record):
		return
	var net_id := int(record.get("net_id", 0))
	var action_id := int(record.get("action_id", 0))
	if (
		_is_client_terminal_blocked(net_id)
		or _is_record_older_than_enemy_incarnation(
			record,
			net_id,
			"host_action_timestamp"
		)
		or action_id <= int(_client_enemy_action_revisions.get(net_id, 0))
		or _is_action_blocked_by_target_presentation_terminal(record)
		or (
			enemy_spawn_snapshot_times.has(net_id)
			and float(record.get("action_time", current_time))
			< float(enemy_spawn_snapshot_times.get(net_id, -INF))
		)
	):
		return
	var enemy := get_valid_client_enemy(net_id)
	if enemy == null or not is_instance_valid(enemy):
		_cache_pending_enemy_action(record)
		return
	var delivery_state := _deliver_action_record(
		record,
		enemy,
		current_time,
		_runtime
	)
	if delivery_state == TARGET_ACTION_RESOLUTION_WAITING:
		_cache_pending_enemy_action(record)


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
			return (
				int(record.get("assignment_revision", -1)) == action_id
				and _is_valid_network_target_descriptor(
					_target_descriptor_from_action_record(record)
				)
			)
		_:
			return false


func _target_descriptor_from_action_record(
	record: Dictionary
) -> CombatTargetDescriptor:
	return _CombatTargetDescriptor.create(
		int(record.get("target_kind", _CombatTargetDescriptor.Kind.NONE)),
		int(record.get("target_id", 0)),
		int(record.get("target_revision", -1)),
		record.get("target_fallback_position", Vector2.INF) as Vector2
	)


func _is_valid_network_target_descriptor(
	descriptor: CombatTargetDescriptor
) -> bool:
	return (
		descriptor != null
		and descriptor.is_valid()
		and descriptor.kind in [
			_CombatTargetDescriptor.Kind.PLAYER,
			_CombatTargetDescriptor.Kind.PLANT,
			_CombatTargetDescriptor.Kind.ENEMY,
		]
		and _NetConstants.is_valid_network_combat_value(descriptor.id)
		and _NetConstants.is_valid_network_combat_value(descriptor.revision)
	)


func _deliver_action_record(
	record: Dictionary,
	enemy: Enemy,
	current_time: float,
	runtime: CombatRuntimeBase
) -> int:
	if (
		enemy == null
		or not is_instance_valid(enemy)
		or runtime == null
		or not is_instance_valid(runtime)
	):
		return TARGET_ACTION_RESOLUTION_WAITING
	var net_id := int(record.get("net_id", 0))
	var action_id := int(record.get("action_id", 0))
	if _is_record_older_than_enemy_incarnation(
		record,
		net_id,
		"host_action_timestamp"
	):
		return TARGET_ACTION_RESOLUTION_STALE
	if action_id <= int(_client_enemy_action_revisions.get(net_id, 0)):
		return TARGET_ACTION_RESOLUTION_STALE
	if _is_action_blocked_by_target_presentation_terminal(record):
		return TARGET_ACTION_RESOLUTION_STALE
	var target: Node2D = null
	if int(record.get("kind", -1)) == CLIENT_ENEMY_ACTION_KIND_TARGET:
		var target_resolution := _resolve_target_action(record, runtime)
		if target_resolution.state != TARGET_ACTION_RESOLUTION_READY:
			if target_resolution.state == TARGET_ACTION_RESOLUTION_STALE:
				_client_enemy_action_revisions[net_id] = action_id
			return target_resolution.state
		target = target_resolution.target
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
	_client_enemy_action_revisions[net_id] = action_id
	return TARGET_ACTION_RESOLUTION_READY


func _resolve_target_action(
	record: Dictionary,
	runtime: CombatRuntimeBase
) -> TargetActionResolution:
	var resolution := TargetActionResolution.new()
	var descriptor := _target_descriptor_from_action_record(record)
	if not _is_valid_network_target_descriptor(descriptor):
		resolution.state = TARGET_ACTION_RESOLUTION_STALE
		return resolution
	if (
		descriptor.kind == _CombatTargetDescriptor.Kind.ENEMY
		and (
			_is_client_terminal_blocked(descriptor.id)
			or _is_record_older_than_enemy_incarnation(
				record,
				descriptor.id,
				(
					"host_reference_timestamp"
					if record.has("host_reference_timestamp")
					else "host_action_timestamp"
				)
			)
		)
	):
		resolution.state = TARGET_ACTION_RESOLUTION_STALE
		return resolution
	var target := runtime.get_combat_query_facade().resolve_target(descriptor)
	if target == null or not is_instance_valid(target):
		return resolution
	var target_enemy := target as Enemy
	if target_enemy != null:
		var current_revision := target_enemy.get_faction_revision()
		if current_revision < descriptor.revision:
			return resolution
		if current_revision > descriptor.revision:
			resolution.state = TARGET_ACTION_RESOLUTION_STALE
			return resolution
	resolution.state = TARGET_ACTION_RESOLUTION_READY
	resolution.target = target
	return resolution


func _cache_pending_enemy_action(record: Dictionary) -> bool:
	var net_id := int(record.get("net_id", 0))
	var action_id := int(record.get("action_id", 0))
	if (
		net_id <= 0
		or _is_client_terminal_blocked(net_id)
		or _is_record_older_than_enemy_incarnation(
			record,
			net_id,
			"host_action_timestamp"
		)
		or action_id <= int(_client_enemy_action_revisions.get(net_id, 0))
		or _is_action_blocked_by_target_presentation_terminal(record)
		or (
			enemy_spawn_snapshot_times.has(net_id)
			and float(record.get("action_time", -INF))
			< float(enemy_spawn_snapshot_times.get(net_id, -INF))
		)
	):
		return false
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
