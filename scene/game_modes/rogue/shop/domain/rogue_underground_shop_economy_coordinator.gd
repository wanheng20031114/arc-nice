extends Node
class_name RogueUndergroundShopEconomyCoordinator

signal transaction_completed(peer_id: int, result: Dictionary)

const SELL_PAGE_SIZE := 8
const SELL_PAGE_COUNT := 3

const RESULT_PURCHASED := &"purchased"
const RESULT_SOLD := &"sold"
const RESULT_INVALID_REQUEST := &"invalid_request"
const RESULT_REQUEST_ID_REUSED := &"request_id_reused"
const RESULT_STALE_STATE := &"stale_state"
const RESULT_OFFER_UNAVAILABLE := &"offer_unavailable"
const RESULT_INSUFFICIENT_XIRANG := &"insufficient_xirang"
const RESULT_INVENTORY_FULL := &"inventory_full"
const RESULT_ITEM_MISMATCH := &"item_mismatch"
const RESULT_ITEM_NOT_SELLABLE := &"item_not_sellable"
const RESULT_TRANSACTION_FAILED := &"transaction_failed"

var _config: RogueUndergroundShopConfig
var _run_state: RunStateStore
var _session: RogueUndergroundShopSession
var _processed_requests: Dictionary = {}


func configure(
	config: RogueUndergroundShopConfig,
	run_state: RunStateStore,
	session: RogueUndergroundShopSession
) -> bool:
	if (
		config == null
		or not config.validate_config().is_empty()
		or run_state == null
		or session == null
	):
		return false
	_config = config
	_run_state = run_state
	_session = session
	_processed_requests.clear()
	_run_state.ensure_run_started()
	return true


func submit_purchase(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int,
	expected_session_revision: int = -1
) -> Dictionary:
	var fingerprint := "purchase|%s|%d|%d|%d|%d|%d" % [
		occurrence_key,
		offer_index,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision,
		expected_session_revision,
	]
	var cached := _find_cached_result(peer_id, request_id, fingerprint)
	if bool(cached.get("found", false)):
		return (cached["result"] as Dictionary).duplicate(true)
	if bool(cached.get("mismatch", false)):
		return _make_result(peer_id, false, RESULT_REQUEST_ID_REUSED)
	if not _is_valid_base_request(peer_id, request_id, occurrence_key):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_INVALID_REQUEST)
		)
	if (
		(expected_session_revision >= 0
		and expected_session_revision != _session.get_session_revision())
		or
		expected_shelf_revision != _session.get_shelf_revision(peer_id)
		or expected_inventory_revision != _get_inventory_revision(peer_id)
		or expected_xirang_revision
		!= _run_state.get_party_xirang_ledger_revision()
	):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_STALE_STATE)
		)
	var offer := _session.get_offer(peer_id, offer_index)
	if offer.is_empty() or bool(offer.get("purchased", false)):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_OFFER_UNAVAILABLE)
		)
	var item := load(str(offer.get("config_path", ""))) as PickupConfig
	var price := int(offer.get("price", 0))
	if item == null or price <= 0:
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_INVALID_REQUEST)
		)
	if _run_state.get_party_xirang_balance(peer_id) < price:
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_INSUFFICIENT_XIRANG)
		)
	var transaction := _prepare_purchase_transaction(
		peer_id,
		item,
		price,
		expected_inventory_revision,
		expected_xirang_revision
	)
	if transaction.is_empty():
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_INVENTORY_FULL)
		)
	var transaction_token := "%d|%s|purchase" % [peer_id, request_id]
	if not _session.reserve_offer_purchase(
		peer_id,
		offer_index,
		expected_shelf_revision,
		transaction_token
	):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_STALE_STATE)
		)
	if not _commit_transaction(
		transaction,
		peer_id,
		expected_inventory_revision,
		expected_xirang_revision
	):
		_session.cancel_offer_purchase(transaction_token)
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_TRANSACTION_FAILED)
		)
	# The reservation makes this final step infallible and contains no await;
	# observers therefore only see the shelf after the economy CAS has committed.
	if not _session.commit_reserved_offer_purchase(transaction_token):
		push_error("地下商店货架提交违反预留不变量。")
	var result := _make_result(peer_id, true, RESULT_PURCHASED)
	result["offer_index"] = offer_index
	result["config_path"] = item.resource_path
	result["price"] = price
	return _finish_request(peer_id, request_id, fingerprint, result)


func submit_sell(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_inventory_revision: int,
	expected_xirang_revision: int,
	expected_session_revision: int = -1
) -> Dictionary:
	var fingerprint := "sell|%s|%d|%s|%d|%d|%d" % [
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_inventory_revision,
		expected_xirang_revision,
		expected_session_revision,
	]
	var cached := _find_cached_result(peer_id, request_id, fingerprint)
	if bool(cached.get("found", false)):
		return (cached["result"] as Dictionary).duplicate(true)
	if bool(cached.get("mismatch", false)):
		return _make_result(peer_id, false, RESULT_REQUEST_ID_REUSED)
	if (
		not _is_valid_base_request(peer_id, request_id, occurrence_key)
		or slot_index < 0
		or slot_index >= RunStateStore.INVENTORY_CAPACITY
		or expected_config_path.is_empty()
	):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_INVALID_REQUEST)
		)
	if (
		(expected_session_revision >= 0
		and expected_session_revision != _session.get_session_revision())
		or
		expected_inventory_revision != _get_inventory_revision(peer_id)
		or expected_xirang_revision
		!= _run_state.get_party_xirang_ledger_revision()
	):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_STALE_STATE)
		)
	var slot := _get_inventory_slot(peer_id, slot_index)
	if str(slot.get("config_path", "")) != expected_config_path:
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_ITEM_MISMATCH)
		)
	var item := load(expected_config_path) as PickupConfig
	var sell_price := get_sell_price(item)
	if sell_price <= 0:
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_ITEM_NOT_SELLABLE)
		)
	var transaction := _prepare_sell_transaction(
		peer_id,
		slot_index,
		sell_price,
		expected_inventory_revision,
		expected_xirang_revision
	)
	if (
		transaction.is_empty()
		or not _commit_transaction(
			transaction,
			peer_id,
			expected_inventory_revision,
			expected_xirang_revision
		)
	):
		return _finish_request(
			peer_id,
			request_id,
			fingerprint,
			_make_result(peer_id, false, RESULT_TRANSACTION_FAILED)
		)
	var result := _make_result(peer_id, true, RESULT_SOLD)
	result["slot_index"] = slot_index
	result["config_path"] = expected_config_path
	result["price"] = sell_price
	result["remaining_stack_count"] = int(
		_get_inventory_slot(peer_id, slot_index).get("stack_count", 0)
	)
	return _finish_request(peer_id, request_id, fingerprint, result)


func get_sell_inventory_page(peer_id: int, page_index: int) -> Dictionary:
	if (
		_run_state == null
		or peer_id < 0
		or not _has_peer_economy_state(peer_id)
		or page_index < 0
		or page_index >= SELL_PAGE_COUNT
	):
		return {}
	var slots: Array[Dictionary] = []
	var first_slot := page_index * SELL_PAGE_SIZE
	for card_index in SELL_PAGE_SIZE:
		var slot_index := first_slot + card_index
		if slot_index >= RunStateStore.INVENTORY_CAPACITY:
			slots.append({
				"slot_index": slot_index,
				"config_path": "",
				"stack_count": 0,
				"can_sell": false,
				"sell_price": 0,
				"disabled_reason": "out_of_range",
			})
			continue
		var slot := _get_inventory_slot(peer_id, slot_index)
		var config_path := str(slot.get("config_path", ""))
		var item := (
			load(config_path) as PickupConfig
			if not config_path.is_empty()
			else null
		)
		var sell_price := get_sell_price(item)
		var reason := ""
		if item == null:
			reason = "empty"
		elif item.inventory_locked:
			reason = "locked"
		elif item.pickup_type == PickupConfig.PickupType.BUILDING:
			reason = "building"
		elif sell_price <= 0:
			reason = "unsupported_type"
		slots.append({
			"slot_index": slot_index,
			"config_path": config_path,
			"stack_count": int(slot.get("stack_count", 0)),
			"can_sell": reason.is_empty() and sell_price > 0,
			"sell_price": sell_price,
			"disabled_reason": reason,
		})
	return {
		"page_index": page_index,
		"page_count": SELL_PAGE_COUNT,
		"inventory_revision": _get_inventory_revision(peer_id),
		"xirang_revision": _run_state.get_party_xirang_ledger_revision(),
		"slots": slots,
	}


func get_sell_price(item: PickupConfig) -> int:
	if (
		_config == null
		or item == null
		or item.inventory_locked
		or not item.can_store_in_inventory
	):
		return 0
	match item.pickup_type:
		PickupConfig.PickupType.MATERIAL:
			return _config.material_sell_price
		PickupConfig.PickupType.COLLECTIBLE:
			return _config.collectible_sell_price
		PickupConfig.PickupType.HEALTH:
			return (
				_config.health_potion_sell_price
				if item.resource_path == _config.health_potion_path
				else 0
			)
		_:
			return 0


func _is_valid_base_request(
	peer_id: int,
	request_id: String,
	occurrence_key: String
) -> bool:
	return (
		_config != null
		and _run_state != null
		and _session != null
		and peer_id >= 0
		and _has_peer_economy_state(peer_id)
		and not request_id.is_empty()
		and occurrence_key == _session.get_occurrence_key()
		and _session.get_phase() == RogueUndergroundShopSession.Phase.SHOPPING
		and _session.get_participant_peer_ids().has(peer_id)
		and not _session.is_peer_exited(peer_id)
	)


func _prepare_purchase_transaction(
	peer_id: int,
	item: PickupConfig,
	price: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> Dictionary:
	var transaction := _export_peer_transaction(peer_id)
	if transaction.is_empty():
		return {}
	var inventory := transaction["inventory"] as Dictionary
	var slots := inventory["slots"] as Array
	var target_slot := -1
	if item.stackable:
		for slot_index in slots.size():
			var slot := slots[slot_index] as Dictionary
			if (
				str(slot.get("config_path", "")) == item.resource_path
				and int(slot.get("stack_count", 0))
				< PickupConfig.get_inventory_stack_limit(item)
			):
				target_slot = slot_index
				break
	if target_slot < 0:
		for slot_index in slots.size():
			if str((slots[slot_index] as Dictionary).get("config_path", "")).is_empty():
				target_slot = slot_index
				break
	if target_slot < 0:
		return {}
	var target := slots[target_slot] as Dictionary
	if str(target.get("config_path", "")).is_empty():
		target["config_path"] = item.resource_path
		target["stack_count"] = 1
	else:
		target["stack_count"] = int(target["stack_count"]) + 1
	inventory["revision"] = expected_inventory_revision + 1
	_apply_xirang_delta(
		transaction["xirang_ledger"] as Dictionary,
		peer_id,
		-price,
		expected_xirang_revision
	)
	return transaction


func _prepare_sell_transaction(
	peer_id: int,
	slot_index: int,
	sell_price: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> Dictionary:
	var transaction := _export_peer_transaction(peer_id)
	if transaction.is_empty():
		return {}
	var inventory := transaction["inventory"] as Dictionary
	var slots := inventory["slots"] as Array
	var slot := slots[slot_index] as Dictionary
	var count := int(slot.get("stack_count", 0))
	if count <= 0:
		return {}
	if count > 1:
		slot["stack_count"] = count - 1
	else:
		slot["config_path"] = ""
		slot["stack_count"] = 0
	inventory["revision"] = expected_inventory_revision + 1
	_apply_xirang_delta(
		transaction["xirang_ledger"] as Dictionary,
		peer_id,
		sell_price,
		expected_xirang_revision
	)
	return transaction


func _export_peer_transaction(peer_id: int) -> Dictionary:
	var peer_ids := PackedInt32Array([peer_id])
	var snapshot := _run_state.export_party_economy_snapshot(peer_ids)
	var inventories := snapshot.get("inventories", []) as Array
	if inventories.size() != 1:
		return {}
	return {
		"snapshot": snapshot,
		"inventory": inventories[0] as Dictionary,
		"xirang_ledger": snapshot["xirang_ledger"] as Dictionary,
	}


func _apply_xirang_delta(
	ledger: Dictionary,
	peer_id: int,
	delta: int,
	expected_revision: int
) -> void:
	var values := ledger["values"] as Dictionary
	var key := str(peer_id)
	values[key] = int(values.get(key, 0)) + delta
	ledger["revision"] = expected_revision + 1


func _commit_transaction(
	transaction: Dictionary,
	peer_id: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	return _run_state.apply_authoritative_party_transaction(
		transaction["snapshot"] as Dictionary,
		_run_state.get_shared_warehouse_ledger_revision(),
		{peer_id: expected_inventory_revision},
		expected_xirang_revision
	)


func _get_inventory_slot(peer_id: int, slot_index: int) -> Dictionary:
	return (
		_run_state.get_inventory_slot_state(slot_index)
		if peer_id == 0
		else _run_state.get_inventory_slot_state_for_peer(peer_id, slot_index)
	)


func _get_inventory_revision(peer_id: int) -> int:
	return (
		_run_state.get_inventory_revision()
		if peer_id == 0
		else _run_state.get_inventory_revision_for_peer(peer_id)
	)


func _find_cached_result(
	peer_id: int,
	request_id: String,
	fingerprint: String
) -> Dictionary:
	if request_id.is_empty():
		return {}
	var key := "%d|%s" % [peer_id, request_id]
	if not _processed_requests.has(key):
		return {}
	var cached := _processed_requests[key] as Dictionary
	if str(cached.get("fingerprint", "")) != fingerprint:
		return {"mismatch": true}
	return {
		"found": true,
		"result": (cached["result"] as Dictionary).duplicate(true),
	}


func _finish_request(
	peer_id: int,
	request_id: String,
	fingerprint: String,
	result: Dictionary
) -> Dictionary:
	if not request_id.is_empty():
		_processed_requests["%d|%s" % [peer_id, request_id]] = {
			"fingerprint": fingerprint,
			"result": result.duplicate(true),
		}
	transaction_completed.emit(peer_id, result.duplicate(true))
	return result


func _make_result(
	peer_id: int,
	success: bool,
	result_code: StringName
) -> Dictionary:
	return {
		"success": success,
		"result_code": String(result_code),
		"peer_id": peer_id,
		"session_revision": (
			_session.get_session_revision() if _session != null else -1
		),
		"shelf_revision": (
			_session.get_shelf_revision(peer_id) if _session != null else -1
		),
		"inventory_revision": (
			_get_inventory_revision(peer_id)
			if _run_state != null and _has_peer_economy_state(peer_id)
			else -1
		),
		"xirang_revision": (
			_run_state.get_party_xirang_ledger_revision()
			if _run_state != null
			else -1
		),
		"xirang_balance": (
			_run_state.get_party_xirang_balance(peer_id)
			if _run_state != null and _has_peer_economy_state(peer_id)
			else 0
		),
	}


func _has_peer_economy_state(peer_id: int) -> bool:
	return (
		peer_id == 0
		or (
			peer_id > 0
			and _run_state != null
			and _run_state.has_multiplayer_peer_state(peer_id)
		)
	)
