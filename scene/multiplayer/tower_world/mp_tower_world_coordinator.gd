extends Node
class_name MpTowerWorldCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

const PLANT_HEALTH_FLUSH_INTERVAL_SECONDS := 0.05
# Each record carries 41 raw packed bytes before RPC/ENet framing. Twenty-four
# records stay below the multiplayer packet warning budget.
const PLANT_HEALTH_MAX_RECORDS_PER_PACKET := 24
const MULTIPLAYER_TEAM_PLANT_LIMIT := 256
const CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT
const CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT * 2
const PLANT_PLACEMENT_RATE_PER_SECOND := 4.0
const PLANT_PLACEMENT_RATE_BURST := 8.0
const PLANT_ID_WIRE_MAX_LENGTH := 128
const INVENTORY_ITEM_CONFIG_PATH_WIRE_MAX_LENGTH := 256

signal plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
)
signal inventory_plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
)
signal plant_spawn_broadcast_requested(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal plant_placement_rejection_send_requested(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
)
signal plant_health_batch_broadcast_requested(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
)
signal plant_damage_status_broadcast_requested(
	net_id: int,
	status_mask: int,
	status_revision: int
)
signal plant_removed_broadcast_requested(net_id: int, was_destroyed: bool)

var _session: MultiplayerGameplaySession = null
var _runtime: CombatRuntimeBase = null
var _mode_adapter: TowerDefenseMultiplayerModeAdapter = null
var _net_manager: NetManagerStore = null
var _transactions: MpTransactionsCoordinator = null

var _last_plant_placement_request_ids: Dictionary = {}
var _plant_placement_rate_buckets: Dictionary = {}
var _pending_plant_health_updates: Dictionary = {}
var _plant_health_flush_time_left := PLANT_HEALTH_FLUSH_INTERVAL_SECONDS

# CH5 spawn/removal and CH7 health feedback have independent delivery order.
# All three client-side maps are insertion-bounded to reject unbounded unknown ids.
var _pending_remote_plant_health_updates: Dictionary = {}
var _pending_remote_plant_health_order: Array[int] = []
var _removed_remote_plant_ids: Dictionary = {}
var _removed_remote_plant_id_order: Array[int] = []
var _remote_plant_feedback_revisions: Dictionary = {}
var _remote_plant_feedback_revision_order: Array[int] = []


func bind_session(
	session: MultiplayerGameplaySession,
	runtime: CombatRuntimeBase,
	mode_adapter: TowerDefenseMultiplayerModeAdapter,
	net_manager: NetManagerStore,
	transactions: MpTransactionsCoordinator
) -> void:
	assert(session != null, "MpTowerWorldCoordinator 缺少多人会话。")
	assert(runtime != null, "MpTowerWorldCoordinator 缺少战斗运行时。")
	assert(mode_adapter != null, "MpTowerWorldCoordinator 缺少塔防模式适配器。")
	assert(net_manager != null, "MpTowerWorldCoordinator 缺少网络管理器。")
	assert(transactions != null, "MpTowerWorldCoordinator 缺少事务协调器。")
	if _session != null and _session != session:
		_disconnect_mode_adapter()
		reset_session_state()
	_session = session
	_runtime = runtime
	_mode_adapter = mode_adapter
	_net_manager = net_manager
	_transactions = transactions
	_connect_mode_adapter()


func unbind_session(session: MultiplayerGameplaySession) -> void:
	if _session != session:
		return
	_disconnect_mode_adapter()
	reset_session_state()
	_session = null
	_runtime = null
	_mode_adapter = null
	_net_manager = null
	_transactions = null


func is_bound() -> bool:
	return (
		_session != null
		and is_instance_valid(_session)
		and _runtime != null
		and is_instance_valid(_runtime)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _transactions != null
		and is_instance_valid(_transactions)
	)


func reset_session_state() -> void:
	_last_plant_placement_request_ids.clear()
	_plant_placement_rate_buckets.clear()
	_pending_plant_health_updates.clear()
	_plant_health_flush_time_left = PLANT_HEALTH_FLUSH_INTERVAL_SECONDS
	_clear_remote_plant_health_state()


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_last_plant_placement_request_ids.erase(peer_id)
	_plant_placement_rate_buckets.erase(peer_id)


func update_host(delta: float) -> void:
	if not is_bound() or not _net_manager.is_host():
		return
	_plant_health_flush_time_left -= maxf(delta, 0.0)
	if _plant_health_flush_time_left > 0.0:
		return
	_plant_health_flush_time_left = PLANT_HEALTH_FLUSH_INTERVAL_SECONDS
	_flush_plant_health_updates()


func handle_remote_plant_placement_request(
	sender_id: int,
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	_handle_authoritative_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor
	)


func handle_remote_inventory_plant_placement_request(
	sender_id: int,
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	_handle_authoritative_inventory_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func build_live_plant_records() -> Array[Dictionary]:
	if not is_bound():
		return []
	var records: Array[Dictionary] = []
	for snapshot in _mode_adapter.get_multiplayer_plant_snapshots():
		var net_id := int(snapshot.get("net_id", 0))
		if net_id <= 0:
			continue
		records.append(snapshot.duplicate(true))
	records.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("net_id", 0)) < int(b.get("net_id", 0))
	)
	return records


func build_live_plant_ids() -> PackedInt32Array:
	var live_ids := PackedInt32Array()
	for record in build_live_plant_records():
		live_ids.append(int(record.get("net_id", 0)))
	return live_ids


func get_plant(net_id: int) -> PlantDefense:
	if not is_bound() or net_id <= 0:
		return null
	return _mode_adapter.get_multiplayer_plant_node(net_id)


func is_remote_plant_removed(net_id: int) -> bool:
	return net_id > 0 and _removed_remote_plant_ids.has(net_id)


func find_live_plant_ids_missing_from_manifest(
	plant_id_set: Dictionary
) -> PackedInt32Array:
	var removed_ids := PackedInt32Array()
	if not is_bound() or _net_manager.is_host():
		return removed_ids
	for plant_snapshot in build_live_plant_records():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		if plant_net_id > 0 and not plant_id_set.has(plant_net_id):
			removed_ids.append(plant_net_id)
	return removed_ids


func reconcile_runtime_manifest(
	plant_id_set: Dictionary,
	positive_plant_ids: PackedInt32Array,
	removed_ids: PackedInt32Array
) -> void:
	if not is_bound() or _net_manager.is_host():
		return
	for net_id in positive_plant_ids:
		_clear_remote_plant_removed_marker(net_id)
	for plant_net_id in removed_ids:
		if plant_net_id > 0 and not plant_id_set.has(plant_net_id):
			_mark_remote_plant_removed(plant_net_id)
			_mode_adapter.apply_remote_plant_removed(plant_net_id, false, true)
	for plant_snapshot in build_live_plant_records():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		if plant_net_id > 0 and plant_id_set.has(plant_net_id):
			apply_pending_remote_plant_health(plant_net_id)


func receive_plant_spawn(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: String,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> PlantDefense:
	if (
		not _is_client_bound()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		return null
	_clear_remote_plant_removed_marker(net_id)
	_mode_adapter.apply_remote_plant_spawn(
		request_id,
		owner_peer_id,
		net_id,
		StringName(plant_id),
		anchor,
		current_health,
		maximum_health,
		health_revision
	)
	return get_plant(net_id)


func receive_plant_placement_rejected(request_id: int, reason: String) -> void:
	if not _is_client_bound():
		return
	_mode_adapter.apply_remote_plant_placement_rejected(
		request_id,
		StringName(reason)
	)


func receive_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if (
		not _is_client_bound()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		return
	_apply_or_defer_remote_plant_health(
		net_id,
		current_health,
		maximum_health,
		health_revision
	)


func receive_plant_health_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
) -> void:
	if not _is_client_bound():
		return
	var record_count := mini(
		net_ids.size(),
		mini(
			health_values.size(),
			mini(
				maximum_values.size(),
				mini(
					revisions.size(),
					mini(
						damage_values.size(),
						mini(
							healing_values.size(),
							mini(
								directions.size(),
								mini(damage_types.size(), world_positions.size())
							)
						)
					)
				)
			)
		)
	)
	for record_index in range(record_count):
		var net_id := net_ids[record_index]
		var health_revision := revisions[record_index]
		if (
			net_id <= 0
			or not _NetConstants.is_valid_network_combat_value(health_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(maximum_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(health_revision)
			or not _NetConstants.is_valid_network_combat_value(damage_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(healing_values[record_index])
		):
			continue
		var live_plant_before := get_plant(net_id)
		var stale_for_live_plant := (
			live_plant_before != null
			and is_instance_valid(live_plant_before)
			and health_revision <= live_plant_before.health_revision
		)
		_apply_or_defer_remote_plant_health(
			net_id,
			health_values[record_index],
			maximum_values[record_index],
			health_revision
		)
		var applied_damage := damage_values[record_index]
		var applied_healing := healing_values[record_index]
		if applied_damage <= 0 and applied_healing <= 0:
			continue
		if not _accept_remote_plant_feedback_revision(net_id, health_revision):
			continue
		if stale_for_live_plant:
			continue
		if applied_damage > 0:
			_runtime.show_combat_number(
				applied_damage,
				world_positions[record_index],
				DamageNumberPool.CombatNumberKind.DAMAGE,
				directions[record_index],
				int(damage_types[record_index]) as EnemyConfig.DamageType,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)
		if applied_healing > 0:
			_runtime.show_combat_number(
				applied_healing,
				world_positions[record_index],
				DamageNumberPool.CombatNumberKind.HEALING,
				Vector2.ZERO,
				EnemyConfig.DamageType.PHYSICAL,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)


func receive_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	if not _is_client_bound() or net_id <= 0:
		return
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	plant.apply_remote_damage_status_mask(status_mask, status_revision)


func receive_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if not _is_client_bound() or net_id <= 0:
		return
	_mark_remote_plant_removed(net_id)
	_mode_adapter.apply_remote_plant_removed(net_id, was_destroyed)


func apply_pending_remote_plant_health(net_id: int) -> void:
	if not _is_client_bound():
		return
	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	_erase_pending_remote_plant_health(net_id)
	_mode_adapter.apply_remote_plant_health(
		net_id,
		int(pending.get("current_health", 0)),
		int(pending.get("maximum_health", 1)),
		int(pending.get("health_revision", -1))
	)


func _on_local_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_handle_authoritative_plant_placement_request(
			_net_manager.get_local_peer_id(),
			request_id,
			String(plant_id),
			anchor
		)
	elif _net_manager.is_client():
		plant_placement_request_to_host.emit(request_id, String(plant_id), anchor)


func _on_local_inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_handle_authoritative_inventory_plant_placement_request(
			_net_manager.get_local_peer_id(),
			request_id,
			String(plant_id),
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)
	elif _net_manager.is_client():
		inventory_plant_placement_request_to_host.emit(
			request_id,
			String(plant_id),
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)


func _handle_authoritative_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id_wire: String,
	anchor: Vector2i
) -> void:
	if not _is_host_bound():
		return
	if not _transactions.consume_remote_transaction_admission(requester_peer_id):
		return
	if (
		request_id <= 0
		or plant_id_wire.is_empty()
		or plant_id_wire.length() > PLANT_ID_WIRE_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(requester_peer_id):
		return
	var last_request_id := int(_last_plant_placement_request_ids.get(requester_peer_id, 0))
	if request_id <= last_request_id:
		_request_placement_rejection(requester_peer_id, request_id, &"stale_request")
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_request_placement_rejection(
			requester_peer_id,
			request_id,
			&"team_limit_reached"
		)
		return
	_mode_adapter.request_authoritative_plant_placement(
		requester_peer_id,
		request_id,
		StringName(plant_id_wire),
		anchor
	)


func _handle_authoritative_inventory_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id_wire: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not _is_host_bound():
		return
	if not _transactions.consume_remote_transaction_admission(requester_peer_id):
		return
	if (
		request_id <= 0
		or plant_id_wire.is_empty()
		or plant_id_wire.length() > PLANT_ID_WIRE_MAX_LENGTH
		or slot_index < 0
		or slot_index >= RunStateStore.INVENTORY_CAPACITY
		or expected_inventory_revision < 0
		or item_config_path.is_empty()
		or item_config_path.length() > INVENTORY_ITEM_CONFIG_PATH_WIRE_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(requester_peer_id):
		return
	var last_request_id := int(_last_plant_placement_request_ids.get(requester_peer_id, 0))
	if request_id <= last_request_id:
		_request_placement_rejection(requester_peer_id, request_id, &"stale_request")
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_request_placement_rejection(
			requester_peer_id,
			request_id,
			&"team_limit_reached"
		)
		return
	_mode_adapter.request_authoritative_inventory_plant_placement(
		requester_peer_id,
		request_id,
		StringName(plant_id_wire),
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func _get_authoritative_team_plant_count() -> int:
	var plant_count := _mode_adapter.get_authoritative_team_plant_count()
	# A Host without its authoritative registry must fail closed.
	return MULTIPLAYER_TEAM_PLANT_LIMIT if plant_count < 0 else plant_count


func _request_placement_rejection(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
) -> void:
	plant_placement_rejection_send_requested.emit(
		requester_peer_id,
		request_id,
		reason
	)


func _consume_peer_rate_token(peer_id: int, now_seconds: float = -1.0) -> bool:
	if peer_id <= 0:
		return false
	var now := Time.get_ticks_msec() / 1000.0 if now_seconds < 0.0 else now_seconds
	var bucket: Dictionary
	if _plant_placement_rate_buckets.has(peer_id):
		bucket = _plant_placement_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": PLANT_PLACEMENT_RATE_BURST,
			"last_time": now,
		}
		_plant_placement_rate_buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", PLANT_PLACEMENT_RATE_BURST))
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(
		PLANT_PLACEMENT_RATE_BURST,
		tokens + maxf(now - last_time, 0.0) * PLANT_PLACEMENT_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _on_host_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _is_host_bound():
		return
	if (
		net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpTowerWorldCoordinator: 植物生成生命值超出 signed int32 契约。")
		return
	plant_spawn_broadcast_requested.emit(
		request_id,
		owner_peer_id,
		net_id,
		plant_id,
		anchor,
		current_health,
		maximum_health,
		health_revision
	)


func _on_host_plant_placement_rejected(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
) -> void:
	if _is_host_bound():
		_request_placement_rejection(requester_peer_id, request_id, reason)


func _on_host_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _is_host_bound():
		return
	if (
		net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpTowerWorldCoordinator: 植物生命更新超出 signed int32 契约。")
		return
	var previous := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) > health_revision:
		return
	previous["current_health"] = current_health
	previous["maximum_health"] = maximum_health
	previous["health_revision"] = health_revision
	_pending_plant_health_updates[net_id] = previous


func _on_host_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	if not _is_host_bound() or net_id <= 0 or status_revision <= 0:
		return
	plant_damage_status_broadcast_requested.emit(
		net_id,
		status_mask,
		status_revision
	)


func _on_host_plant_damage_applied(
	net_id: int,
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	world_position: Vector2
) -> void:
	if (
		not _is_host_bound()
		or net_id <= 0
		or applied_damage <= 0
		or not impact_direction.is_finite()
		or not world_position.is_finite()
	):
		return
	var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if update.is_empty():
		return
	var safe_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	if safe_damage_type == EnemyConfig.DamageType.MAGIC:
		update["magic_damage"] = int(update.get("magic_damage", 0)) + applied_damage
		update["magic_direction"] = impact_direction
	else:
		update["physical_damage"] = int(update.get("physical_damage", 0)) + applied_damage
		update["physical_direction"] = impact_direction
	var physical_damage := int(update.get("physical_damage", 0))
	var magic_damage := int(update.get("magic_damage", 0))
	var use_magic := magic_damage > physical_damage
	update["damage"] = physical_damage + magic_damage
	update["impact_direction"] = (
		update.get("magic_direction", Vector2.ZERO)
		if use_magic
		else update.get("physical_direction", Vector2.ZERO)
	)
	update["damage_type"] = int(
		EnemyConfig.DamageType.MAGIC
		if use_magic
		else EnemyConfig.DamageType.PHYSICAL
	)
	update["world_position"] = world_position
	_pending_plant_health_updates[net_id] = update


func _on_host_plant_healing_applied(
	net_id: int,
	applied_healing: int,
	world_position: Vector2
) -> void:
	if (
		not _is_host_bound()
		or net_id <= 0
		or applied_healing <= 0
		or not world_position.is_finite()
	):
		return
	var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if update.is_empty():
		return
	update["healing"] = int(update.get("healing", 0)) + applied_healing
	update["world_position"] = world_position
	_pending_plant_health_updates[net_id] = update


func _on_host_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if not _is_host_bound() or net_id <= 0:
		return
	if _pending_plant_health_updates.has(net_id):
		_send_pending_plant_health_updates([net_id])
	_pending_plant_health_updates.erase(net_id)
	plant_removed_broadcast_requested.emit(net_id, was_destroyed)


func _flush_plant_health_updates() -> void:
	if not _is_host_bound() or _pending_plant_health_updates.is_empty():
		return
	var net_ids: Array[int] = []
	for net_id_variant in _pending_plant_health_updates.keys():
		var net_id := int(net_id_variant)
		if not _NetConstants.is_valid_network_combat_value(net_id):
			push_error("MpTowerWorldCoordinator: 拒绝序列化越界植物 net_id。")
			_pending_plant_health_updates.erase(net_id_variant)
			continue
		net_ids.append(net_id)
	net_ids.sort()
	_send_pending_plant_health_updates(net_ids)
	for net_id in net_ids:
		_pending_plant_health_updates.erase(net_id)


func _send_pending_plant_health_updates(net_ids: Array[int]) -> void:
	for chunk_start in range(0, net_ids.size(), PLANT_HEALTH_MAX_RECORDS_PER_PACKET):
		var chunk_end := mini(
			chunk_start + PLANT_HEALTH_MAX_RECORDS_PER_PACKET,
			net_ids.size()
		)
		var chunk_ids := PackedInt32Array()
		var health_values := PackedInt32Array()
		var maximum_values := PackedInt32Array()
		var revisions := PackedInt32Array()
		var damage_values := PackedInt32Array()
		var healing_values := PackedInt32Array()
		var directions := PackedVector2Array()
		var damage_types := PackedByteArray()
		var world_positions := PackedVector2Array()
		for record_index in range(chunk_start, chunk_end):
			var net_id := net_ids[record_index]
			var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
			if update.is_empty():
				continue
			var current_health := int(update.get("current_health", 0))
			var maximum_health := int(update.get("maximum_health", 1))
			var health_revision := int(update.get("health_revision", 0))
			var applied_damage := int(update.get("damage", 0))
			var applied_healing := int(update.get("healing", 0))
			if (
				not _NetConstants.is_valid_network_combat_value(net_id)
				or not _NetConstants.is_valid_network_combat_value(current_health)
				or not _NetConstants.is_valid_network_combat_value(maximum_health)
				or not _NetConstants.is_valid_network_combat_value(health_revision)
				or not _NetConstants.is_valid_network_combat_value(applied_damage)
				or not _NetConstants.is_valid_network_combat_value(applied_healing)
			):
				push_error("MpTowerWorldCoordinator: 拒绝序列化越界植物战斗值。")
				continue
			chunk_ids.append(net_id)
			health_values.append(current_health)
			maximum_values.append(maximum_health)
			revisions.append(health_revision)
			damage_values.append(applied_damage)
			healing_values.append(applied_healing)
			directions.append(update.get("impact_direction", Vector2.ZERO) as Vector2)
			damage_types.append(int(update.get("damage_type", EnemyConfig.DamageType.PHYSICAL)))
			world_positions.append(update.get("world_position", Vector2.ZERO) as Vector2)
		if chunk_ids.is_empty():
			continue
		plant_health_batch_broadcast_requested.emit(
			chunk_ids,
			health_values,
			maximum_values,
			revisions,
			damage_values,
			healing_values,
			directions,
			damage_types,
			world_positions
		)


func _apply_or_defer_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _is_client_bound() or net_id <= 0 or health_revision < 0:
		return
	if _removed_remote_plant_ids.has(net_id):
		return
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		_cache_remote_plant_health(
			net_id,
			current_health,
			maximum_health,
			health_revision
		)
		return
	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	var selected_health := current_health
	var selected_maximum := maximum_health
	var selected_revision := health_revision
	if int(pending.get("health_revision", -1)) >= health_revision:
		selected_health = int(pending.get("current_health", current_health))
		selected_maximum = int(pending.get("maximum_health", maximum_health))
		selected_revision = int(pending.get("health_revision", health_revision))
	_erase_pending_remote_plant_health(net_id)
	_mode_adapter.apply_remote_plant_health(
		net_id,
		selected_health,
		selected_maximum,
		selected_revision
	)


func _cache_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	var previous := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) >= health_revision:
		return
	if previous.is_empty():
		while (
			_pending_remote_plant_health_updates.size()
			>= CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES
			and not _pending_remote_plant_health_order.is_empty()
		):
			var evicted_net_id := int(_pending_remote_plant_health_order.pop_front())
			_pending_remote_plant_health_updates.erase(evicted_net_id)
		_pending_remote_plant_health_order.append(net_id)
	_pending_remote_plant_health_updates[net_id] = {
		"current_health": current_health,
		"maximum_health": maximum_health,
		"health_revision": health_revision,
	}


func _erase_pending_remote_plant_health(net_id: int) -> void:
	if not _pending_remote_plant_health_updates.erase(net_id):
		return
	_pending_remote_plant_health_order.erase(net_id)


func _mark_remote_plant_removed(net_id: int) -> void:
	if net_id <= 0:
		return
	_erase_pending_remote_plant_health(net_id)
	if _removed_remote_plant_ids.has(net_id):
		return
	while (
		_removed_remote_plant_ids.size()
		>= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
		and not _removed_remote_plant_id_order.is_empty()
	):
		var evicted_net_id := int(_removed_remote_plant_id_order.pop_front())
		_removed_remote_plant_ids.erase(evicted_net_id)
	_removed_remote_plant_ids[net_id] = true
	_removed_remote_plant_id_order.append(net_id)


func _clear_remote_plant_removed_marker(net_id: int) -> void:
	if net_id <= 0 or not _removed_remote_plant_ids.erase(net_id):
		return
	_removed_remote_plant_id_order.erase(net_id)


func _accept_remote_plant_feedback_revision(net_id: int, health_revision: int) -> bool:
	if net_id <= 0 or health_revision < 0:
		return false
	if health_revision <= int(_remote_plant_feedback_revisions.get(net_id, -1)):
		return false
	if not _remote_plant_feedback_revisions.has(net_id):
		while (
			_remote_plant_feedback_revisions.size()
			>= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
			and not _remote_plant_feedback_revision_order.is_empty()
		):
			var evicted_net_id := int(_remote_plant_feedback_revision_order.pop_front())
			_remote_plant_feedback_revisions.erase(evicted_net_id)
		_remote_plant_feedback_revision_order.append(net_id)
	_remote_plant_feedback_revisions[net_id] = health_revision
	return true


func _clear_remote_plant_health_state() -> void:
	_pending_remote_plant_health_updates.clear()
	_pending_remote_plant_health_order.clear()
	_removed_remote_plant_ids.clear()
	_removed_remote_plant_id_order.clear()
	_remote_plant_feedback_revisions.clear()
	_remote_plant_feedback_revision_order.clear()


func _connect_mode_adapter() -> void:
	var bindings: Array[Array] = [
		[_mode_adapter.plant_placement_requested, _on_local_plant_placement_requested],
		[
			_mode_adapter.inventory_plant_placement_requested,
			_on_local_inventory_plant_placement_requested,
		],
		[_mode_adapter.plant_spawned, _on_host_plant_spawned],
		[_mode_adapter.plant_placement_rejected, _on_host_plant_placement_rejected],
		[_mode_adapter.plant_health_changed, _on_host_plant_health_changed],
		[
			_mode_adapter.plant_damage_status_changed,
			_on_host_plant_damage_status_changed,
		],
		[_mode_adapter.plant_damage_applied, _on_host_plant_damage_applied],
		[_mode_adapter.plant_healing_applied, _on_host_plant_healing_applied],
		[_mode_adapter.plant_removed, _on_host_plant_removed],
	]
	for binding in bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if not source.is_connected(target):
			source.connect(target)


func _disconnect_mode_adapter() -> void:
	if _mode_adapter == null or not is_instance_valid(_mode_adapter):
		return
	var bindings: Array[Array] = [
		[_mode_adapter.plant_placement_requested, _on_local_plant_placement_requested],
		[
			_mode_adapter.inventory_plant_placement_requested,
			_on_local_inventory_plant_placement_requested,
		],
		[_mode_adapter.plant_spawned, _on_host_plant_spawned],
		[_mode_adapter.plant_placement_rejected, _on_host_plant_placement_rejected],
		[_mode_adapter.plant_health_changed, _on_host_plant_health_changed],
		[
			_mode_adapter.plant_damage_status_changed,
			_on_host_plant_damage_status_changed,
		],
		[_mode_adapter.plant_damage_applied, _on_host_plant_damage_applied],
		[_mode_adapter.plant_healing_applied, _on_host_plant_healing_applied],
		[_mode_adapter.plant_removed, _on_host_plant_removed],
	]
	for binding in bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if source.is_connected(target):
			source.disconnect(target)


func _is_host_bound() -> bool:
	return is_bound() and _net_manager.is_host()


func _is_client_bound() -> bool:
	return is_bound() and _net_manager.is_client() and not _net_manager.is_host()
