extends Node
class_name RogueEncounterEconomyCoordinator

signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 2
const PURCHASE_COST := 10
const FREE_PURCHASE_CHANCE := 0.5
const SLIME_HELP_COST := 10
const SLIME_COLLECTIBLE_REWARD_COUNT := 3
const SLIME_GEL_REWARD_COUNT := 10
const SLIME_HELP_COLLECTIBLE_CHANCE := 0.5
const SLIME_XIRANG_REWARD_AMOUNTS: Array[int] = [500, 1000, 2000, 5000]
const ENCOUNTER_CHICKEN_BRO := &"chicken_bro"
const ENCOUNTER_SLIME_TALKERS := &"slime_talkers"
const OPTION_PURCHASE := &"purchase_basketball"
const OPTION_FREE := &"ask_for_free"
const OPTION_HELP_SLIMES := &"help_slimes"
const OPTION_KICK_SLIMES := &"kick_slimes"
const OPTION_LEAVE_SLIMES := &"leave_slimes"
const PLANK_PATH := "res://resources/config/materials/material_plank.tres"
const BASKETBALL_PATH := "res://resources/config/collectibles/collectible_basketball.tres"
const WATER_BOTTLE_PATH := "res://resources/config/materials/material_water_bottle.tres"
const GEL_PATH := "res://resources/config/materials/material_gel.tres"

const RESULT_GRANTED_PAID := &"granted_paid"
const RESULT_GRANTED_FREE := &"granted_free"
const RESULT_FREE_FAILED := &"free_failed"
const RESULT_INSUFFICIENT_PLANKS := &"insufficient_planks"
const RESULT_ALL_INVENTORIES_FULL := &"all_inventories_full"
const RESULT_STALE_STATE := &"stale_state"
const RESULT_INVALID_REQUEST := &"invalid_request"
const RESULT_SLIME_HELP_COLLECTIBLES := &"slime_help_collectibles"
const RESULT_SLIME_HELP_XIRANG := &"slime_help_xirang"
const RESULT_SLIME_INSUFFICIENT_WATER := &"slime_insufficient_water"
const RESULT_SLIME_KICK_INVENTORY := &"slime_kick_inventory"
const RESULT_SLIME_KICK_WAREHOUSE := &"slime_kick_warehouse"
const RESULT_SLIME_KICK_DROPPED := &"slime_kick_dropped"
const RESULT_SLIME_LEFT := &"slime_left"

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


func can_afford_slime_help(peer_ids: Array[int]) -> bool:
	if _run_state == null:
		return false
	var water_bottle := load(WATER_BOTTLE_PATH) as PickupConfig
	return (
		water_bottle != null
		and _run_state.get_party_item_total(
			water_bottle,
			_to_packed_peer_ids(peer_ids)
		) >= SLIME_HELP_COST
	)


func get_option_availability(
	encounter_id: StringName,
	peer_ids: Array[int]
) -> Dictionary:
	match encounter_id:
		ENCOUNTER_CHICKEN_BRO:
			return {
				String(OPTION_PURCHASE): can_afford_purchase(peer_ids),
				String(OPTION_FREE): true,
			}
		ENCOUNTER_SLIME_TALKERS:
			return {
				String(OPTION_HELP_SLIMES): can_afford_slime_help(peer_ids),
				String(OPTION_KICK_SLIMES): true,
				String(OPTION_LEAVE_SLIMES): true,
			}
		_:
			return {}


## Encounter sessions use one dispatch point so adding content does not add another
## hard-coded economy call to the session state machine. The legacy chicken entry
## remains public for existing callers and regression tests.
func resolve_encounter(
	encounter_id: StringName,
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = ""
) -> Dictionary:
	match encounter_id:
		ENCOUNTER_CHICKEN_BRO:
			return resolve_chicken_bro(
				option_id,
				node_content_seed,
				eligible_peer_ids,
				occurrence_key
			)
		ENCOUNTER_SLIME_TALKERS:
			return resolve_slime_talkers(
				option_id,
				node_content_seed,
				eligible_peer_ids,
				occurrence_key
			)
		_:
			return _make_result(false, RESULT_INVALID_REQUEST)


## Host-only settlement for the talking-slime encounter. Every branch is cached
## by occurrence_key, including leave and discarded rewards, so an RPC replay can
## never spend water or grant rewards twice.
func resolve_slime_talkers(
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
		or option_id not in [
			OPTION_HELP_SLIMES,
			OPTION_KICK_SLIMES,
			OPTION_LEAVE_SLIMES,
		]
	):
		return _make_result(false, RESULT_INVALID_REQUEST)
	var ordered_peer_ids := _normalize_peer_ids(eligible_peer_ids)
	if ordered_peer_ids.is_empty():
		return _make_result(false, RESULT_INVALID_REQUEST)
	for peer_id in ordered_peer_ids:
		if peer_id > 0:
			_run_state.ensure_multiplayer_peer_state(peer_id)

	if option_id == OPTION_LEAVE_SLIMES:
		return _finalize_resolution(
			_make_slime_result(true, RESULT_SLIME_LEFT, option_id),
			occurrence_key,
			ordered_peer_ids
		)
	if option_id == OPTION_HELP_SLIMES:
		return _resolve_slime_help(
			node_content_seed,
			ordered_peer_ids,
			occurrence_key
		)
	return _resolve_slime_kick(
		node_content_seed,
		ordered_peer_ids,
		occurrence_key
	)


func _resolve_slime_help(
	node_content_seed: int,
	ordered_peer_ids: Array[int],
	occurrence_key: String
) -> Dictionary:
	var water_bottle := load(WATER_BOTTLE_PATH) as PickupConfig
	if water_bottle == null:
		return _make_result(false, RESULT_INVALID_REQUEST)
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var xirang_ledger := party_snapshot.get("xirang_ledger", {}) as Dictionary
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or not _is_valid_xirang_ledger(xirang_ledger)
	):
		return _make_result(false, RESULT_STALE_STATE)
	if _count_item_path(party_snapshot, WATER_BOTTLE_PATH) < SLIME_HELP_COST:
		return _finalize_resolution(
			_make_slime_result(
				true,
				RESULT_SLIME_INSUFFICIENT_WATER,
				OPTION_HELP_SLIMES
			),
			occurrence_key,
			ordered_peer_ids
		)

	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var expected_inventory_revisions := _get_expected_inventory_revisions(
		inventory_snapshots,
		ordered_peer_ids
	)
	var expected_xirang_revision := int(xirang_ledger["revision"])
	var next_xirang_ledger := next_snapshot["xirang_ledger"] as Dictionary
	var touched_peer_ids: Dictionary = {}
	var ledger := next_snapshot["warehouse_ledger"] as Dictionary
	var warehouse_paid := _consume_from_warehouse_ledger(
		ledger,
		WATER_BOTTLE_PATH,
		SLIME_HELP_COST
	)
	var remaining_cost := SLIME_HELP_COST - warehouse_paid
	if warehouse_paid > 0:
		ledger["revision"] = int(ledger["revision"]) + 1
	var player_payments: Dictionary = {}
	var payment_order := ordered_peer_ids.duplicate()
	var rotation := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"slime_water_payer_rotation",
		payment_order.size()
	)
	payment_order = _rotated_peer_ids(payment_order, rotation)
	for peer_id in payment_order:
		if remaining_cost <= 0:
			break
		var paid := _consume_from_inventory(
			next_inventory_snapshots[peer_id] as Dictionary,
			WATER_BOTTLE_PATH,
			remaining_cost
		)
		if paid <= 0:
			continue
		player_payments[peer_id] = paid
		touched_peer_ids[peer_id] = true
		remaining_cost -= paid
	if remaining_cost > 0:
		return _make_result(false, RESULT_STALE_STATE)

	var result: Dictionary
	if RogueEncounterRandom.succeeds(
		node_content_seed,
		&"slime_help_reward_kind",
		SLIME_HELP_COLLECTIBLE_CHANCE
	):
		var reward_pool := CollectibleRegistry.get_standard_random_pool_up_to(
			PickupConfig.CollectibleRarity.RARE
		)
		if reward_pool.is_empty():
			return _make_result(false, RESULT_INVALID_REQUEST)
		var rewards: Array[Dictionary] = []
		for peer_id in ordered_peer_ids:
			var rolled_paths: Array[String] = []
			var granted_paths: Array[String] = []
			var peer_inventory := next_inventory_snapshots[peer_id] as Dictionary
			for reward_index in SLIME_COLLECTIBLE_REWARD_COUNT:
				var salt := StringName(
					"slime_collectible_%d_%d" % [peer_id, reward_index]
				)
				var item := reward_pool[
					RogueEncounterRandom.choose_index(
						node_content_seed,
						salt,
						reward_pool.size()
					)
				]
				rolled_paths.append(item.resource_path)
				if _add_item_count_to_wire_slots(
					peer_inventory.get("slots", []) as Array,
					item,
					1
				) == 1:
					granted_paths.append(item.resource_path)
					touched_peer_ids[peer_id] = true
			rewards.append({
				"peer_id": peer_id,
				"rolled_paths": rolled_paths,
				"granted_paths": granted_paths,
				"discarded_count": rolled_paths.size() - granted_paths.size(),
			})
		result = _make_slime_result(
			true,
			RESULT_SLIME_HELP_COLLECTIBLES,
			OPTION_HELP_SLIMES
		)
		result["reward_kind"] = "collectibles"
		result["collectible_rewards"] = rewards
	else:
		var amount_index := RogueEncounterRandom.choose_index(
			node_content_seed,
			&"slime_xirang_tier",
			SLIME_XIRANG_REWARD_AMOUNTS.size()
		)
		var xirang_amount := SLIME_XIRANG_REWARD_AMOUNTS[amount_index]
		var next_values := next_xirang_ledger["values"] as Dictionary
		var xirang_totals: Array[Dictionary] = []
		for peer_id in ordered_peer_ids:
			var peer_key := str(peer_id)
			var next_total := int(next_values.get(peer_key, 0)) + xirang_amount
			next_values[peer_key] = next_total
			xirang_totals.append({"peer_id": peer_id, "total": next_total})
		next_xirang_ledger["revision"] = expected_xirang_revision + 1
		result = _make_slime_result(
			true,
			RESULT_SLIME_HELP_XIRANG,
			OPTION_HELP_SLIMES
		)
		result["reward_kind"] = "xirang"
		result["xirang_reward_each"] = xirang_amount
		result["xirang_totals"] = xirang_totals

	_bump_touched_inventory_revisions(
		next_inventory_snapshots,
		expected_inventory_revisions,
		touched_peer_ids
	)
	if not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		expected_xirang_revision,
		next_xirang_ledger
	):
		return _make_result(false, RESULT_STALE_STATE)
	result.merge({
		"water_paid": SLIME_HELP_COST,
		"warehouse_paid": warehouse_paid,
		"player_payments": player_payments,
	}, true)
	return _finalize_resolution(result, occurrence_key, ordered_peer_ids, true)


func _resolve_slime_kick(
	node_content_seed: int,
	ordered_peer_ids: Array[int],
	occurrence_key: String
) -> Dictionary:
	var gel := load(GEL_PATH) as PickupConfig
	if gel == null:
		return _make_result(false, RESULT_INVALID_REQUEST)
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var xirang_ledger := party_snapshot.get("xirang_ledger", {}) as Dictionary
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or not _is_valid_xirang_ledger(xirang_ledger)
	):
		return _make_result(false, RESULT_STALE_STATE)
	var receiver_peer_id := ordered_peer_ids[
		RogueEncounterRandom.choose_index(
			node_content_seed,
			&"slime_gel_receiver",
			ordered_peer_ids.size()
		)
	]
	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var expected_inventory_revisions := _get_expected_inventory_revisions(
		inventory_snapshots,
		ordered_peer_ids
	)
	var expected_xirang_revision := int(xirang_ledger["revision"])
	var next_xirang_ledger := next_snapshot["xirang_ledger"] as Dictionary
	var target_inventory := next_inventory_snapshots[receiver_peer_id] as Dictionary
	var target_slots := target_inventory.get("slots", []) as Array
	var destination := "discarded"
	var result_code := RESULT_SLIME_KICK_DROPPED
	var touched_warehouse_ids: Array[int] = []
	var transaction_required := false
	if _get_wire_slot_capacity(target_slots, gel) >= SLIME_GEL_REWARD_COUNT:
		_add_item_count_to_wire_slots(target_slots, gel, SLIME_GEL_REWARD_COUNT)
		target_inventory["revision"] = (
			int(expected_inventory_revisions[receiver_peer_id]) + 1
		)
		destination = "inventory"
		result_code = RESULT_SLIME_KICK_INVENTORY
		transaction_required = true
	else:
		var warehouse_add := _try_add_item_count_to_warehouse_ledger(
			next_snapshot["warehouse_ledger"] as Dictionary,
			gel,
			SLIME_GEL_REWARD_COUNT
		)
		if bool(warehouse_add.get("success", false)):
			touched_warehouse_ids.assign(
				warehouse_add.get("warehouse_net_ids", []) as Array
			)
			destination = "warehouse"
			result_code = RESULT_SLIME_KICK_WAREHOUSE
			transaction_required = true

	if transaction_required and not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		expected_xirang_revision,
		next_xirang_ledger
	):
		return _make_result(false, RESULT_STALE_STATE)
	var result := _make_slime_result(true, result_code, OPTION_KICK_SLIMES)
	result.merge({
		"reward_kind": "gel",
		"reward_granted": destination != "discarded",
		"receiver_peer_id": receiver_peer_id,
		"gel_count": SLIME_GEL_REWARD_COUNT,
		"gel_destination": destination,
		"gel_warehouse_net_ids": touched_warehouse_ids,
	}, true)
	return _finalize_resolution(
		result,
		occurrence_key,
		ordered_peer_ids,
		transaction_required
	)


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
	for field_name in ["collectible_rewards", "xirang_totals"]:
		var entries := migrated.get(field_name, []) as Array
		for raw_entry_value in entries:
			if typeof(raw_entry_value) != TYPE_DICTIONARY:
				continue
			var entry := raw_entry_value as Dictionary
			if int(entry.get("peer_id", -1)) == old_peer_id:
				entry["peer_id"] = new_peer_id
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


func _make_slime_result(
	resolved: bool,
	result_code: StringName,
	option_id: StringName
) -> Dictionary:
	var result := _make_result(resolved, result_code)
	result.merge({
		"encounter_id": String(ENCOUNTER_SLIME_TALKERS),
		"option_id": String(option_id),
		"reward_kind": "none",
		"water_paid": 0,
		"collectible_rewards": [],
		"xirang_reward_each": 0,
		"xirang_totals": [],
		"gel_count": 0,
		"gel_destination": "none",
		"gel_warehouse_net_ids": [],
	}, true)
	return result


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


func _get_expected_inventory_revisions(
	inventory_snapshots: Dictionary,
	peer_ids: Array[int]
) -> Dictionary:
	var result: Dictionary = {}
	for peer_id in peer_ids:
		if not inventory_snapshots.has(peer_id):
			return {}
		result[peer_id] = int(
			(inventory_snapshots[peer_id] as Dictionary).get("revision", -1)
		)
	return result


func _bump_touched_inventory_revisions(
	inventory_snapshots: Dictionary,
	expected_revisions: Dictionary,
	touched_peer_ids: Dictionary
) -> void:
	for raw_peer_id in touched_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		if (
			not inventory_snapshots.has(peer_id)
			or not expected_revisions.has(peer_id)
		):
			continue
		var inventory_snapshot := inventory_snapshots[peer_id] as Dictionary
		inventory_snapshot["revision"] = int(expected_revisions[peer_id]) + 1


func _is_valid_xirang_ledger(ledger: Dictionary) -> bool:
	if (
		typeof(ledger.get("schema_version")) != TYPE_INT
		or int(ledger["schema_version"]) != 1
		or typeof(ledger.get("revision")) != TYPE_INT
		or int(ledger["revision"]) < 0
		or typeof(ledger.get("values")) != TYPE_DICTIONARY
	):
		return false
	for raw_peer_key in (ledger["values"] as Dictionary).keys():
		if typeof(raw_peer_key) != TYPE_STRING:
			return false
		var peer_key := str(raw_peer_key)
		if not peer_key.is_valid_int() or str(peer_key.to_int()) != peer_key:
			return false
		var raw_value: Variant = (ledger["values"] as Dictionary)[raw_peer_key]
		if typeof(raw_value) != TYPE_INT or int(raw_value) < 0:
			return false
	return true


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


func _get_wire_slot_capacity(slots: Array, item: PickupConfig) -> int:
	if (
		item == null
		or not item.can_store_in_inventory
		or item.resource_path.is_empty()
	):
		return 0
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	var capacity := 0
	for raw_slot_value in slots:
		if typeof(raw_slot_value) != TYPE_DICTIONARY:
			return 0
		var slot := raw_slot_value as Dictionary
		var path := str(slot.get("config_path", ""))
		if path.is_empty():
			capacity += stack_limit
		elif item.stackable and path == item.resource_path:
			capacity += maxi(stack_limit - int(slot.get("stack_count", 0)), 0)
	return capacity


## Full-batch insertion. Insufficient capacity leaves every slot untouched.
func _add_item_count_to_wire_slots(
	slots: Array,
	item: PickupConfig,
	count: int
) -> int:
	if count <= 0 or _get_wire_slot_capacity(slots, item) < count:
		return 0
	var remaining := count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	if item.stackable:
		for raw_slot_value in slots:
			if remaining <= 0:
				break
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) != item.resource_path:
				continue
			var room := maxi(stack_limit - int(slot.get("stack_count", 0)), 0)
			var added := mini(room, remaining)
			slot["stack_count"] = int(slot.get("stack_count", 0)) + added
			remaining -= added
	for raw_slot_value in slots:
		if remaining <= 0:
			break
		var slot := raw_slot_value as Dictionary
		if not str(slot.get("config_path", "")).is_empty():
			continue
		var added := mini(stack_limit, remaining)
		slot["config_path"] = item.resource_path
		slot["stack_count"] = added
		remaining -= added
	return count - remaining


func _try_add_item_count_to_warehouse_ledger(
	ledger: Dictionary,
	item: PickupConfig,
	count: int
) -> Dictionary:
	if item == null or count <= 0:
		return {"success": false, "warehouse_net_ids": []}
	var warehouses := ledger.get("warehouses", []) as Array
	warehouses.sort_custom(
		func(left: Variant, right: Variant) -> bool:
			return int((left as Dictionary).get("warehouse_net_id", -1)) < int(
				(right as Dictionary).get("warehouse_net_id", -1)
			)
	)
	var total_capacity := 0
	for raw_warehouse_value in warehouses:
		total_capacity += _get_wire_slot_capacity(
			(raw_warehouse_value as Dictionary).get("slots", []) as Array,
			item
		)
	if total_capacity < count:
		return {"success": false, "warehouse_net_ids": []}
	var remaining := count
	var touched_warehouse_ids: Array[int] = []
	for raw_warehouse_value in warehouses:
		if remaining <= 0:
			break
		var warehouse := raw_warehouse_value as Dictionary
		var slots := warehouse.get("slots", []) as Array
		var added := _add_item_count_to_wire_slots(
			slots,
			item,
			mini(_get_wire_slot_capacity(slots, item), remaining)
		)
		if added <= 0:
			continue
		remaining -= added
		warehouse["revision"] = int(warehouse.get("revision", 0)) + 1
		touched_warehouse_ids.append(int(warehouse.get("warehouse_net_id", -1)))
	if remaining != 0:
		return {"success": false, "warehouse_net_ids": []}
	ledger["revision"] = int(ledger.get("revision", 0)) + 1
	return {
		"success": true,
		"warehouse_net_ids": touched_warehouse_ids,
	}


func _add_item_to_inventory(
	inventory_snapshot: Dictionary,
	item: PickupConfig
) -> bool:
	return _add_item_count_to_wire_slots(
		inventory_snapshot.get("slots", []) as Array,
		item,
		1
	) == 1


func _rotated_peer_ids(peer_ids: Array[int], offset: int) -> Array[int]:
	if peer_ids.is_empty():
		return []
	var result: Array[int] = []
	for index in peer_ids.size():
		result.append(peer_ids[(index + offset) % peer_ids.size()])
	return result
