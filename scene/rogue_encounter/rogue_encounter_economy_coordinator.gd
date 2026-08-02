extends Node
class_name RogueEncounterEconomyCoordinator

signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 1
const PURCHASE_COST := 10
const FREE_PURCHASE_CHANCE := 0.5
const OPTION_PURCHASE := &"purchase_basketball"
const OPTION_FREE := &"ask_for_free"
const PLANK_PATH := "res://resources/config/materials/material_plank.tres"
const BASKETBALL_PATH := "res://resources/config/collectibles/collectible_basketball.tres"

const RESULT_GRANTED_PAID := &"granted_paid"
const RESULT_GRANTED_FREE := &"granted_free"
const RESULT_FREE_FAILED := &"free_failed"
const RESULT_INSUFFICIENT_PLANKS := &"insufficient_planks"
const RESULT_ALL_INVENTORIES_FULL := &"all_inventories_full"
const RESULT_STALE_STATE := &"stale_state"
const RESULT_INVALID_REQUEST := &"invalid_request"

var _run_state: RunStateStore
var _economy_revision := 0
var _settled_occurrences: Dictionary = {}


func configure(run_state: RunStateStore) -> void:
	reset_runtime(run_state)


func reset_runtime(run_state: RunStateStore) -> void:
	_run_state = run_state
	_economy_revision = 0
	_settled_occurrences.clear()
	if _run_state != null:
		_run_state.ensure_run_started()


func is_configured() -> bool:
	return _run_state != null


func can_afford_purchase(peer_ids: Array[int]) -> bool:
	if _run_state == null:
		return false
	var plank := load(PLANK_PATH) as PickupConfig
	return (
		plank != null
		and _run_state.get_party_item_total(plank, _to_packed_peer_ids(peer_ids))
		>= PURCHASE_COST
	)


func get_party_item_total(item: PickupConfig, peer_ids: Array[int] = []) -> int:
	if _run_state == null:
		return 0
	return _run_state.get_party_item_total(item, _to_packed_peer_ids(peer_ids))


func has_party_item(item: PickupConfig, peer_ids: Array[int] = []) -> bool:
	return get_party_item_total(item, peer_ids) > 0


## 重连时迁移已结算结果中的玩家引用。这里推进一次经济 revision，但不
## 发 signal；调用方会把迁移后的经济快照并入同一次遭遇状态广播，避免
## economy_changed 回调额外推进 encounter revision。
func migrate_peer_references(old_peer_id: int, new_peer_id: int) -> bool:
	if old_peer_id < 0 or new_peer_id < 0 or old_peer_id == new_peer_id:
		return false
	var changed := false
	for raw_occurrence_key in _settled_occurrences.keys():
		var occurrence_key := str(raw_occurrence_key)
		var previous := _settled_occurrences[raw_occurrence_key] as Dictionary
		var migrated := migrate_result_peer_references(
			previous,
			old_peer_id,
			new_peer_id
		)
		if migrated == previous:
			continue
		_settled_occurrences[occurrence_key] = migrated
		changed = true
	if changed:
		_economy_revision += 1
	return changed


func migrate_result_peer_references(
	result: Dictionary,
	old_peer_id: int,
	new_peer_id: int
) -> Dictionary:
	var migrated := result.duplicate(true)
	if int(migrated.get("receiver_peer_id", -1)) == old_peer_id:
		migrated["receiver_peer_id"] = new_peer_id
	var payments := migrated.get("player_payments", {}) as Dictionary
	if payments.has(old_peer_id):
		var old_payment := int(payments[old_peer_id])
		payments.erase(old_peer_id)
		payments[new_peer_id] = int(payments.get(new_peer_id, 0)) + old_payment
		migrated["player_payments"] = payments
	return migrated


## 房主唯一调用的鸡哥结算入口。返回值始终可直接写入 encounter snapshot；
## resolved=false 只表示请求/状态过期，应由调用方等待新快照而不是展示结果。
func resolve_chicken_bro(
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = ""
) -> Dictionary:
	if not occurrence_key.is_empty() and _settled_occurrences.has(occurrence_key):
		return (
			(_settled_occurrences[occurrence_key] as Dictionary).duplicate(true)
		)
	if (
		_run_state == null
		or option_id not in [OPTION_PURCHASE, OPTION_FREE]
	):
		return _make_result(false, RESULT_INVALID_REQUEST)
	var ordered_peer_ids := _normalize_peer_ids(eligible_peer_ids)
	if ordered_peer_ids.is_empty():
		return _make_result(false, RESULT_INVALID_REQUEST)
	for peer_id in ordered_peer_ids:
		if peer_id > 0:
			_run_state.ensure_multiplayer_peer_state(peer_id)

	var basketball := load(BASKETBALL_PATH) as PickupConfig
	var plank := load(PLANK_PATH) as PickupConfig
	if basketball == null or plank == null:
		return _make_result(false, RESULT_INVALID_REQUEST)
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	if inventory_snapshots.size() != ordered_peer_ids.size():
		return _make_result(false, RESULT_STALE_STATE)

	var recipient_candidates: Array[int] = []
	for peer_id in ordered_peer_ids:
		if _inventory_has_capacity(
			inventory_snapshots[peer_id] as Dictionary,
			basketball
		):
			recipient_candidates.append(peer_id)
	if recipient_candidates.is_empty():
		return _finalize_resolution(
			_make_result(true, RESULT_ALL_INVENTORIES_FULL),
			occurrence_key,
			ordered_peer_ids
		)

	if (
		option_id == OPTION_FREE
		and not RogueEncounterRandom.succeeds(
			node_content_seed,
			&"free_roll",
			FREE_PURCHASE_CHANCE
		)
	):
		var failed_free := _make_result(true, RESULT_FREE_FAILED)
		failed_free["free_purchase_success"] = false
		return _finalize_resolution(
			failed_free,
			occurrence_key,
			ordered_peer_ids
		)

	if (
		option_id == OPTION_PURCHASE
		and _count_item_path(party_snapshot, PLANK_PATH) < PURCHASE_COST
	):
		return _finalize_resolution(
			_make_result(true, RESULT_INSUFFICIENT_PLANKS),
			occurrence_key,
			ordered_peer_ids
		)

	var receiver_index := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"receiver",
		recipient_candidates.size()
	)
	var receiver_peer_id := recipient_candidates[receiver_index]
	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var expected_inventory_revisions: Dictionary = {}
	var touched_peer_ids: Dictionary = {}
	for peer_id in ordered_peer_ids:
		expected_inventory_revisions[peer_id] = int(
			(inventory_snapshots[peer_id] as Dictionary).get("revision", -1)
		)

	var warehouse_paid := 0
	var player_payments: Dictionary = {}
	if option_id == OPTION_PURCHASE:
		var remaining_cost := PURCHASE_COST
		var ledger := next_snapshot["warehouse_ledger"] as Dictionary
		warehouse_paid = _consume_from_warehouse_ledger(
			ledger,
			PLANK_PATH,
			remaining_cost
		)
		remaining_cost -= warehouse_paid
		if warehouse_paid > 0:
			ledger["revision"] = int(ledger["revision"]) + 1
		var payment_order := ordered_peer_ids.duplicate()
		var rotation := RogueEncounterRandom.choose_index(
			node_content_seed,
			&"payer_rotation",
			payment_order.size()
		)
		payment_order = _rotated_peer_ids(payment_order, rotation)
		for peer_id in payment_order:
			if remaining_cost <= 0:
				break
			var paid := _consume_from_inventory(
				next_inventory_snapshots[peer_id] as Dictionary,
				PLANK_PATH,
				remaining_cost
			)
			if paid <= 0:
				continue
			player_payments[peer_id] = paid
			touched_peer_ids[peer_id] = true
			remaining_cost -= paid
		if remaining_cost > 0:
			return _finalize_resolution(
				_make_result(true, RESULT_INSUFFICIENT_PLANKS),
				occurrence_key,
				ordered_peer_ids
			)

	if not _add_item_to_inventory(
		next_inventory_snapshots[receiver_peer_id] as Dictionary,
		basketball
	):
		return _finalize_resolution(
			_make_result(true, RESULT_ALL_INVENTORIES_FULL),
			occurrence_key,
			ordered_peer_ids
		)
	touched_peer_ids[receiver_peer_id] = true
	for raw_peer_id in touched_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		var next_inventory := next_inventory_snapshots[peer_id] as Dictionary
		next_inventory["revision"] = int(expected_inventory_revisions[peer_id]) + 1

	if not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions
	):
		return _make_result(false, RESULT_STALE_STATE)
	var result_code := (
		RESULT_GRANTED_PAID
		if option_id == OPTION_PURCHASE
		else RESULT_GRANTED_FREE
	)
	var result := _make_result(true, result_code)
	result.merge(
		{
			"reward_granted": true,
			"receiver_peer_id": receiver_peer_id,
			"planks_paid": PURCHASE_COST if option_id == OPTION_PURCHASE else 0,
			"warehouse_paid": warehouse_paid,
			"player_payments": player_payments,
			"free_purchase_success": option_id == OPTION_FREE,
		},
		true
	)
	return _finalize_resolution(result, occurrence_key, ordered_peer_ids, true)


func export_snapshot(peer_ids: Array[int] = []) -> Dictionary:
	if _run_state == null:
		return {}
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _economy_revision,
		"settled_occurrences": _export_settled_occurrences(),
		"party_economy": _run_state.export_party_economy_snapshot(
			_to_packed_peer_ids(peer_ids)
		),
	}


func apply_remote_snapshot(snapshot: Dictionary) -> bool:
	if (
		_run_state == null
		or typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < _economy_revision
		or typeof(snapshot.get("party_economy")) != TYPE_DICTIONARY
		or typeof(snapshot.get("settled_occurrences")) != TYPE_ARRAY
	):
		return false
	var decoded_occurrences: Variant = _decode_settled_occurrences(
		snapshot["settled_occurrences"] as Array
	)
	if decoded_occurrences == null:
		return false
	if not _run_state.apply_party_economy_snapshot(
		snapshot["party_economy"] as Dictionary
	):
		return false
	var changed: bool = int(snapshot["revision"]) != _economy_revision
	_economy_revision = int(snapshot["revision"])
	_settled_occurrences = decoded_occurrences as Dictionary
	if changed:
		economy_changed.emit(export_snapshot())
	return true


func _finalize_resolution(
	result: Dictionary,
	occurrence_key: String,
	peer_ids: Array[int],
	economy_was_mutated: bool = false
) -> Dictionary:
	if not bool(result.get("resolved", false)):
		return result
	if not occurrence_key.is_empty() and _settled_occurrences.has(occurrence_key):
		return (
			(_settled_occurrences[occurrence_key] as Dictionary).duplicate(true)
		)
	if economy_was_mutated or not occurrence_key.is_empty():
		_economy_revision += 1
	result["economy_revision"] = _economy_revision
	if not occurrence_key.is_empty():
		_settled_occurrences[occurrence_key] = result.duplicate(true)
	if economy_was_mutated or not occurrence_key.is_empty():
		economy_changed.emit(export_snapshot(peer_ids))
	return result


func _export_settled_occurrences() -> Array[Dictionary]:
	var occurrence_keys: Array[String] = []
	for raw_occurrence_key in _settled_occurrences.keys():
		occurrence_keys.append(str(raw_occurrence_key))
	occurrence_keys.sort()
	var result: Array[Dictionary] = []
	for occurrence_key in occurrence_keys:
		result.append(
			{
				"occurrence_key": occurrence_key,
				"result": (
					_settled_occurrences[occurrence_key] as Dictionary
				).duplicate(true),
			}
		)
	return result


func _decode_settled_occurrences(entries: Array) -> Variant:
	var result: Dictionary = {}
	for raw_entry_value in entries:
		if typeof(raw_entry_value) != TYPE_DICTIONARY:
			return null
		var entry := raw_entry_value as Dictionary
		if (
			typeof(entry.get("occurrence_key")) != TYPE_STRING
			or str(entry["occurrence_key"]).is_empty()
			or typeof(entry.get("result")) != TYPE_DICTIONARY
		):
			return null
		var occurrence_key := str(entry["occurrence_key"])
		if result.has(occurrence_key):
			return null
		result[occurrence_key] = (entry["result"] as Dictionary).duplicate(true)
	return result


func _make_result(resolved: bool, result_code: StringName) -> Dictionary:
	return {
		"resolved": resolved,
		"result_code": String(result_code),
		"reward_granted": false,
		"receiver_peer_id": -1,
		"planks_paid": 0,
		"warehouse_paid": 0,
		"player_payments": {},
		"free_purchase_success": false,
		"economy_revision": _economy_revision,
	}


func _normalize_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	var seen: Dictionary = {}
	for peer_id in peer_ids:
		if peer_id < 0 or seen.has(peer_id):
			continue
		seen[peer_id] = true
		result.append(peer_id)
	result.sort()
	return result


func _to_packed_peer_ids(peer_ids: Array[int]) -> PackedInt32Array:
	var packed := PackedInt32Array()
	for peer_id in peer_ids:
		packed.append(peer_id)
	return packed


func _index_inventory_snapshots(party_snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for raw_inventory_value in party_snapshot.get("inventories", []) as Array:
		var inventory_snapshot := raw_inventory_value as Dictionary
		var peer_id := int(inventory_snapshot.get("peer_id", -1))
		if peer_id < 0 or result.has(peer_id):
			return {}
		result[peer_id] = inventory_snapshot
	return result


func _inventory_has_capacity(
	inventory_snapshot: Dictionary,
	item: PickupConfig
) -> bool:
	if item == null or not item.can_store_in_inventory:
		return false
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	for raw_slot_value in inventory_snapshot.get("slots", []) as Array:
		var slot := raw_slot_value as Dictionary
		var path := str(slot.get("config_path", ""))
		if path.is_empty():
			return true
		if (
			item.stackable
			and path == item.resource_path
			and int(slot.get("stack_count", 0)) < stack_limit
		):
			return true
	return false


func _count_item_path(party_snapshot: Dictionary, config_path: String) -> int:
	var total := 0
	var ledger := party_snapshot.get("warehouse_ledger", {}) as Dictionary
	for raw_warehouse_value in ledger.get("warehouses", []) as Array:
		for raw_slot_value in (raw_warehouse_value as Dictionary).get("slots", []) as Array:
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) == config_path:
				total += int(slot.get("stack_count", 0))
	for raw_inventory_value in party_snapshot.get("inventories", []) as Array:
		for raw_slot_value in (raw_inventory_value as Dictionary).get("slots", []) as Array:
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) == config_path:
				total += int(slot.get("stack_count", 0))
	return total


func _consume_from_warehouse_ledger(
	ledger: Dictionary,
	config_path: String,
	requested_count: int
) -> int:
	var warehouses := ledger.get("warehouses", []) as Array
	warehouses.sort_custom(
		func(left: Variant, right: Variant) -> bool:
			return int((left as Dictionary).get("warehouse_net_id", -1)) < int(
				(right as Dictionary).get("warehouse_net_id", -1)
			)
	)
	var remaining := requested_count
	for raw_warehouse_value in warehouses:
		if remaining <= 0:
			break
		var warehouse := raw_warehouse_value as Dictionary
		var warehouse_changed := false
		for raw_slot_value in warehouse.get("slots", []) as Array:
			if remaining <= 0:
				break
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) != config_path:
				continue
			var stored_count := int(slot.get("stack_count", 0))
			var consumed := mini(stored_count, remaining)
			_set_wire_slot_count(slot, stored_count - consumed)
			remaining -= consumed
			warehouse_changed = warehouse_changed or consumed > 0
		if warehouse_changed:
			warehouse["revision"] = int(warehouse.get("revision", 0)) + 1
	return requested_count - remaining


func _consume_from_inventory(
	inventory_snapshot: Dictionary,
	config_path: String,
	requested_count: int
) -> int:
	var remaining := requested_count
	for raw_slot_value in inventory_snapshot.get("slots", []) as Array:
		if remaining <= 0:
			break
		var slot := raw_slot_value as Dictionary
		if str(slot.get("config_path", "")) != config_path:
			continue
		var stored_count := int(slot.get("stack_count", 0))
		var consumed := mini(stored_count, remaining)
		_set_wire_slot_count(slot, stored_count - consumed)
		remaining -= consumed
	return requested_count - remaining


func _set_wire_slot_count(slot: Dictionary, next_count: int) -> void:
	if next_count > 0:
		slot["stack_count"] = next_count
		return
	slot["config_path"] = ""
	slot["stack_count"] = 0


func _add_item_to_inventory(
	inventory_snapshot: Dictionary,
	item: PickupConfig
) -> bool:
	var slots := inventory_snapshot.get("slots", []) as Array
	if item.stackable:
		var stack_limit := PickupConfig.get_inventory_stack_limit(item)
		for raw_slot_value in slots:
			var slot := raw_slot_value as Dictionary
			if (
				str(slot.get("config_path", "")) == item.resource_path
				and int(slot.get("stack_count", 0)) < stack_limit
			):
				slot["stack_count"] = int(slot["stack_count"]) + 1
				return true
	for raw_slot_value in slots:
		var slot := raw_slot_value as Dictionary
		if not str(slot.get("config_path", "")).is_empty():
			continue
		slot["config_path"] = item.resource_path
		slot["stack_count"] = 1
		return true
	return false


func _rotated_peer_ids(peer_ids: Array[int], offset: int) -> Array[int]:
	if peer_ids.is_empty():
		return []
	var result: Array[int] = []
	for index in peer_ids.size():
		result.append(peer_ids[(index + offset) % peer_ids.size()])
	return result
