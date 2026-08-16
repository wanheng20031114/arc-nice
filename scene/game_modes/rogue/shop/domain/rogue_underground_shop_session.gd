extends RefCounted
class_name RogueUndergroundShopSession

signal session_changed(session_revision: int)

const SCHEMA_VERSION := 2
const OFFER_COUNT := 8

enum Phase {
	IDLE,
	SHOPPING,
	READY_TO_DEPART,
	DEPARTING,
	CLOSED,
}

var _phase := Phase.IDLE
var _occurrence_key := ""
var _route_revision := -1
var _session_revision := 0
var _participant_peer_ids: Array[int] = []
var _exited_peer_ids: Dictionary = {}
var _exited_spectator_peer_ids: Dictionary = {}
var _offers_by_peer: Dictionary = {}
var _consumable_prices_by_peer: Dictionary = {}
var _shelf_revisions: Dictionary = {}
var _purchase_reservations: Dictionary = {}


func start_authoritative(
	occurrence_key: String,
	route_revision: int,
	participant_offers: Dictionary,
	participant_consumable_prices: Dictionary
) -> bool:
	if (
		_phase not in [Phase.IDLE, Phase.CLOSED]
		or occurrence_key.is_empty()
		or route_revision < 0
		or participant_offers.is_empty()
		or participant_consumable_prices.size() != participant_offers.size()
	):
		return false
	var normalized_peer_ids: Array[int] = []
	var normalized_offers: Dictionary = {}
	var normalized_consumable_prices: Dictionary = {}
	for raw_peer_id in participant_offers.keys():
		if typeof(raw_peer_id) != TYPE_INT:
			return false
		var peer_id := int(raw_peer_id)
		if peer_id < 0 or normalized_offers.has(peer_id):
			return false
		if (
			typeof(participant_offers[raw_peer_id]) != TYPE_ARRAY
			or not participant_consumable_prices.has(raw_peer_id)
			or typeof(participant_consumable_prices[raw_peer_id]) != TYPE_ARRAY
		):
			return false
		var offers := participant_offers[raw_peer_id] as Array
		var consumable_prices := (
			participant_consumable_prices[raw_peer_id] as Array
		)
		if (
			not _are_valid_consumable_prices(consumable_prices)
			or not _are_valid_offers(offers, consumable_prices)
		):
			return false
		normalized_peer_ids.append(peer_id)
		normalized_offers[peer_id] = offers.duplicate(true)
		normalized_consumable_prices[peer_id] = consumable_prices.duplicate(true)
	normalized_peer_ids.sort()
	_occurrence_key = occurrence_key
	_route_revision = route_revision
	_session_revision = 1
	_participant_peer_ids = normalized_peer_ids
	_offers_by_peer = normalized_offers
	_consumable_prices_by_peer = normalized_consumable_prices
	_exited_peer_ids.clear()
	_exited_spectator_peer_ids.clear()
	_purchase_reservations.clear()
	_shelf_revisions.clear()
	for peer_id in _participant_peer_ids:
		_shelf_revisions[peer_id] = 0
	_phase = Phase.SHOPPING
	session_changed.emit(_session_revision)
	return true


func apply_snapshot(snapshot: Dictionary) -> bool:
	var prepared := prepare_snapshot(snapshot)
	if not can_commit_prepared_snapshot(prepared):
		return false
	commit_validated_snapshot(prepared)
	return true


func prepare_snapshot(snapshot: Dictionary) -> Dictionary:
	if not _is_valid_snapshot(snapshot):
		return {}
	var incoming_revision := int(snapshot["session_revision"])
	if _occurrence_key == str(snapshot["occurrence_key"]):
		if incoming_revision < _session_revision:
			return {}
		if (
			incoming_revision == _session_revision
			and _get_authoritative_snapshot_core(snapshot) != (
				_get_authoritative_snapshot_core(
					export_snapshot_for_peer(int(snapshot["target_peer_id"]))
				)
			)
		):
			return {}
	return {
		"expected_occurrence_key": _occurrence_key,
		"expected_session_revision": _session_revision,
		"expected_snapshot": export_snapshot_for_peer(
			int(snapshot["target_peer_id"])
		),
		"snapshot": snapshot.duplicate(true),
	}


func can_commit_prepared_snapshot(prepared: Dictionary) -> bool:
	if (
		prepared.size() != 4
		or typeof(prepared.get("expected_occurrence_key")) != TYPE_STRING
		or typeof(prepared.get("expected_session_revision")) != TYPE_INT
		or typeof(prepared.get("expected_snapshot")) != TYPE_DICTIONARY
		or typeof(prepared.get("snapshot")) != TYPE_DICTIONARY
	):
		return false
	var snapshot := prepared["snapshot"] as Dictionary
	return (
		str(prepared["expected_occurrence_key"]) == _occurrence_key
		and int(prepared["expected_session_revision"]) == _session_revision
		and prepared["expected_snapshot"] == export_snapshot_for_peer(
			int(snapshot.get("target_peer_id", -1))
		)
	)


func commit_validated_snapshot(
	prepared: Dictionary,
	emit_change_signal: bool = true
) -> void:
	var snapshot := prepared["snapshot"] as Dictionary
	_occurrence_key = str(snapshot["occurrence_key"])
	_route_revision = int(snapshot["route_revision"])
	_session_revision = int(snapshot["session_revision"])
	_phase = int(snapshot["phase"])
	_participant_peer_ids.clear()
	for peer_id in snapshot["participant_peer_ids"] as Array:
		_participant_peer_ids.append(int(peer_id))
	_exited_peer_ids.clear()
	_exited_spectator_peer_ids.clear()
	for peer_id in snapshot["exited_peer_ids"] as Array:
		_exited_peer_ids[int(peer_id)] = true
	_offers_by_peer.clear()
	_consumable_prices_by_peer.clear()
	_shelf_revisions.clear()
	var target_peer_id := int(snapshot["target_peer_id"])
	var target_offers := snapshot["offers"] as Array
	var target_consumable_prices := snapshot["consumable_prices"] as Array
	if not target_offers.is_empty():
		_offers_by_peer[target_peer_id] = target_offers.duplicate(true)
		_consumable_prices_by_peer[target_peer_id] = (
			target_consumable_prices.duplicate(true)
		)
		_shelf_revisions[target_peer_id] = int(snapshot["shelf_revision"])
	elif bool(snapshot["target_exited"]):
		_exited_spectator_peer_ids[target_peer_id] = true
	_purchase_reservations.clear()
	if emit_change_signal:
		session_changed.emit(_session_revision)


func publish_prepared_snapshot(_prepared: Dictionary) -> void:
	session_changed.emit(_session_revision)


func export_snapshot_for_peer(target_peer_id: int) -> Dictionary:
	if _phase == Phase.IDLE:
		return {}
	var exited_ids: Array[int] = []
	for peer_id in _participant_peer_ids:
		if _exited_peer_ids.has(peer_id):
			exited_ids.append(peer_id)
	return {
		"schema_version": SCHEMA_VERSION,
		"occurrence_key": _occurrence_key,
		"route_revision": _route_revision,
		"session_revision": _session_revision,
		"phase": _phase,
		"participant_peer_ids": _participant_peer_ids.duplicate(),
		"exited_peer_ids": exited_ids,
		"waiting_peer_ids": get_waiting_peer_ids(),
		"target_peer_id": target_peer_id,
		"target_exited": is_peer_exited(target_peer_id),
		"shelf_revision": get_shelf_revision(target_peer_id),
		"offers": (
			(_offers_by_peer[target_peer_id] as Array).duplicate(true)
			if _offers_by_peer.has(target_peer_id)
			else []
		),
		"consumable_prices": (
			(_consumable_prices_by_peer[target_peer_id] as Array).duplicate(true)
			if _consumable_prices_by_peer.has(target_peer_id)
			else []
		),
	}


func submit_exit(
	peer_id: int,
	occurrence_key: String,
	expected_session_revision: int
) -> Dictionary:
	if occurrence_key != _occurrence_key or peer_id < 0:
		return _result(false, &"invalid_request")
	if is_peer_exited(peer_id):
		return _result(true, &"already_exited")
	if (
		_phase != Phase.SHOPPING
		or not _participant_peer_ids.has(peer_id)
		or expected_session_revision != _session_revision
	):
		return _result(false, &"stale_state")
	_exited_peer_ids[peer_id] = true
	_session_revision += 1
	if get_waiting_peer_ids().is_empty():
		_phase = Phase.READY_TO_DEPART
	session_changed.emit(_session_revision)
	return _result(true, &"exited")


func remove_peer(peer_id: int) -> bool:
	if (
		_phase not in [Phase.SHOPPING, Phase.READY_TO_DEPART]
		or not _participant_peer_ids.has(peer_id)
		or _exited_peer_ids.has(peer_id)
	):
		return false
	_exited_peer_ids[peer_id] = true
	_session_revision += 1
	if get_waiting_peer_ids().is_empty():
		_phase = Phase.READY_TO_DEPART
	session_changed.emit(_session_revision)
	return true


func add_exited_spectator(peer_id: int) -> bool:
	if (
		peer_id <= 0
		or _participant_peer_ids.has(peer_id)
		or _exited_spectator_peer_ids.has(peer_id)
	):
		return false
	_exited_spectator_peer_ids[peer_id] = true
	_session_revision += 1
	session_changed.emit(_session_revision)
	return true


func migrate_peer_as_exited(old_peer_id: int, new_peer_id: int) -> bool:
	if (
		_phase == Phase.IDLE
		or old_peer_id < 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not _participant_peer_ids.has(old_peer_id)
		or _participant_peer_ids.has(new_peer_id)
		or _exited_spectator_peer_ids.has(new_peer_id)
	):
		return false
	# old participant 与 new spectator 在同一 revision 内切换，避免监听者
	# 观察到 new 尚未登记退出的中间快照。
	_exited_peer_ids[old_peer_id] = true
	_exited_spectator_peer_ids[new_peer_id] = true
	_session_revision += 1
	if get_waiting_peer_ids().is_empty() and _phase == Phase.SHOPPING:
		_phase = Phase.READY_TO_DEPART
	session_changed.emit(_session_revision)
	return true


func begin_departing(expected_session_revision: int) -> bool:
	if (
		_phase != Phase.READY_TO_DEPART
		or expected_session_revision != _session_revision
	):
		return false
	_phase = Phase.DEPARTING
	_session_revision += 1
	session_changed.emit(_session_revision)
	return true


func cancel_departing(expected_session_revision: int) -> bool:
	if (
		_phase != Phase.DEPARTING
		or expected_session_revision != _session_revision
	):
		return false
	_phase = Phase.READY_TO_DEPART
	_session_revision += 1
	session_changed.emit(_session_revision)
	return true


func close() -> bool:
	if _phase != Phase.DEPARTING:
		return false
	_phase = Phase.CLOSED
	_session_revision += 1
	_purchase_reservations.clear()
	session_changed.emit(_session_revision)
	return true


func reserve_offer_purchase(
	peer_id: int,
	offer_index: int,
	expected_shelf_revision: int,
	transaction_token: String
) -> bool:
	if (
		transaction_token.is_empty()
		or _purchase_reservations.has(transaction_token)
		or _phase != Phase.SHOPPING
		or is_peer_exited(peer_id)
		or expected_shelf_revision != get_shelf_revision(peer_id)
	):
		return false
	var offer := get_offer(peer_id, offer_index)
	if offer.is_empty() or bool(offer.get("purchased", false)):
		return false
	for reservation in _purchase_reservations.values():
		if (
			int((reservation as Dictionary).get("peer_id", -1)) == peer_id
			and int((reservation as Dictionary).get("offer_index", -1))
			== offer_index
		):
			return false
	_purchase_reservations[transaction_token] = {
		"peer_id": peer_id,
		"offer_index": offer_index,
		"shelf_revision": expected_shelf_revision,
	}
	return true


func cancel_offer_purchase(transaction_token: String) -> void:
	_purchase_reservations.erase(transaction_token)


func commit_reserved_offer_purchase(transaction_token: String) -> bool:
	if not _purchase_reservations.has(transaction_token):
		return false
	var reservation := _purchase_reservations[transaction_token] as Dictionary
	_purchase_reservations.erase(transaction_token)
	var peer_id := int(reservation["peer_id"])
	var offer_index := int(reservation["offer_index"])
	var offers := _offers_by_peer.get(peer_id, []) as Array
	var offer := offers[offer_index] as Dictionary
	offer["purchased"] = true
	_shelf_revisions[peer_id] = get_shelf_revision(peer_id) + 1
	_session_revision += 1
	session_changed.emit(_session_revision)
	return true


func get_offer(peer_id: int, offer_index: int) -> Dictionary:
	if not _offers_by_peer.has(peer_id):
		return {}
	var offers := _offers_by_peer[peer_id] as Array
	if offer_index < 0 or offer_index >= offers.size():
		return {}
	return (offers[offer_index] as Dictionary).duplicate(true)


func get_shelf_revision(peer_id: int) -> int:
	return int(_shelf_revisions.get(peer_id, -1))


func get_consumable_price(peer_id: int, config_path: String) -> int:
	if config_path.is_empty() or not _consumable_prices_by_peer.has(peer_id):
		return 0
	for entry in _consumable_prices_by_peer[peer_id] as Array:
		if str((entry as Dictionary).get("config_path", "")) == config_path:
			return int((entry as Dictionary).get("price", 0))
	return 0


func get_waiting_peer_ids() -> Array[int]:
	var waiting: Array[int] = []
	for peer_id in _participant_peer_ids:
		if not _exited_peer_ids.has(peer_id):
			waiting.append(peer_id)
	return waiting


func is_peer_exited(peer_id: int) -> bool:
	return (
		_exited_peer_ids.has(peer_id)
		or _exited_spectator_peer_ids.has(peer_id)
	)


func can_depart() -> bool:
	return _phase == Phase.READY_TO_DEPART


func get_phase() -> Phase:
	return _phase


func get_occurrence_key() -> String:
	return _occurrence_key


func get_route_revision() -> int:
	return _route_revision


func get_session_revision() -> int:
	return _session_revision


func get_participant_peer_ids() -> Array[int]:
	return _participant_peer_ids.duplicate()


func get_snapshot_target_peer_ids() -> Array[int]:
	var result := _participant_peer_ids.duplicate()
	for raw_peer_id in _exited_spectator_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		if not result.has(peer_id):
			result.append(peer_id)
	result.sort()
	return result


func _are_valid_offers(offers: Array, consumable_prices: Array) -> bool:
	if offers.size() != OFFER_COUNT:
		return false
	var price_by_path: Dictionary = {}
	for entry in consumable_prices:
		var price_entry := entry as Dictionary
		price_by_path[str(price_entry["config_path"])] = int(price_entry["price"])
	for offer_index in offers.size():
		if typeof(offers[offer_index]) != TYPE_DICTIONARY:
			return false
		var offer := offers[offer_index] as Dictionary
		var kind := str(offer.get("kind", ""))
		if (
			int(offer.get("offer_index", -1)) != offer_index
			or str(offer.get("config_path", "")).is_empty()
			or kind not in ["collectible", "consumable"]
			or int(offer.get("price", 0)) <= 0
			or typeof(offer.get("purchased", false)) != TYPE_BOOL
		):
			return false
		if (
			kind == "consumable"
			and int(price_by_path.get(str(offer["config_path"]), 0))
			!= int(offer["price"])
		):
			return false
	return true


func _are_valid_consumable_prices(prices: Array) -> bool:
	if prices.size() < RogueUndergroundShopConfig.MINIMUM_CONSUMABLE_LISTING_COUNT:
		return false
	var seen_paths: Dictionary = {}
	for entry_value in prices:
		if typeof(entry_value) != TYPE_DICTIONARY:
			return false
		var entry := entry_value as Dictionary
		if (
			typeof(entry.get("config_path")) != TYPE_STRING
			or str(entry["config_path"]).is_empty()
			or seen_paths.has(str(entry["config_path"]))
			or typeof(entry.get("price_tier")) != TYPE_INT
			or typeof(entry.get("price")) != TYPE_INT
		):
			return false
		var price_tier := int(entry["price_tier"])
		var price := int(entry["price"])
		var band := _get_consumable_price_band(price_tier)
		if (
			band.z <= 0
			or price < band.x
			or price > band.y
			or price % band.z != 0
		):
			return false
		seen_paths[str(entry["config_path"])] = true
	return true


func _get_consumable_price_band(price_tier: int) -> Vector3i:
	match price_tier:
		RogueUndergroundShopListing.PriceTier.LOW:
			return RogueUndergroundShopConfig.LOW_CONSUMABLE_PRICE_BAND
		RogueUndergroundShopListing.PriceTier.MEDIUM:
			return RogueUndergroundShopConfig.MEDIUM_CONSUMABLE_PRICE_BAND
		RogueUndergroundShopListing.PriceTier.HIGH:
			return RogueUndergroundShopConfig.HIGH_CONSUMABLE_PRICE_BAND
		_:
			return Vector3i.ZERO


func _is_valid_snapshot(snapshot: Dictionary) -> bool:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or str(snapshot.get("occurrence_key", "")).is_empty()
		or typeof(snapshot.get("route_revision")) != TYPE_INT
		or int(snapshot["route_revision"]) < 0
		or typeof(snapshot.get("session_revision")) != TYPE_INT
		or int(snapshot["session_revision"]) < 1
		or typeof(snapshot.get("phase")) != TYPE_INT
		or int(snapshot["phase"]) < Phase.SHOPPING
		or int(snapshot["phase"]) > Phase.CLOSED
		or typeof(snapshot.get("participant_peer_ids")) != TYPE_ARRAY
		or typeof(snapshot.get("exited_peer_ids")) != TYPE_ARRAY
		or typeof(snapshot.get("waiting_peer_ids")) != TYPE_ARRAY
		or typeof(snapshot.get("target_peer_id")) != TYPE_INT
		or typeof(snapshot.get("target_exited")) != TYPE_BOOL
		or typeof(snapshot.get("shelf_revision")) != TYPE_INT
		or typeof(snapshot.get("offers")) != TYPE_ARRAY
		or typeof(snapshot.get("consumable_prices")) != TYPE_ARRAY
	):
		return false
	var participant_ids: Array[int] = []
	var participant_set: Dictionary = {}
	for raw_peer_id in snapshot["participant_peer_ids"] as Array:
		if typeof(raw_peer_id) != TYPE_INT or int(raw_peer_id) < 0:
			return false
		var peer_id := int(raw_peer_id)
		if participant_set.has(peer_id):
			return false
		participant_set[peer_id] = true
		participant_ids.append(peer_id)
	if participant_ids.is_empty():
		return false
	var exited_set: Dictionary = {}
	for raw_peer_id in snapshot["exited_peer_ids"] as Array:
		if (
			typeof(raw_peer_id) != TYPE_INT
			or not participant_set.has(int(raw_peer_id))
			or exited_set.has(int(raw_peer_id))
		):
			return false
		exited_set[int(raw_peer_id)] = true
	var expected_waiting: Array[int] = []
	for peer_id in participant_ids:
		if not exited_set.has(peer_id):
			expected_waiting.append(peer_id)
	var raw_waiting := snapshot["waiting_peer_ids"] as Array
	if raw_waiting.size() != expected_waiting.size():
		return false
	for waiting_index in expected_waiting.size():
		if (
			typeof(raw_waiting[waiting_index]) != TYPE_INT
			or int(raw_waiting[waiting_index]) != expected_waiting[waiting_index]
		):
			return false
	var phase := int(snapshot["phase"])
	if phase == Phase.SHOPPING and expected_waiting.is_empty():
		return false
	if phase in [Phase.READY_TO_DEPART, Phase.DEPARTING, Phase.CLOSED] and not expected_waiting.is_empty():
		return false
	var target_peer_id := int(snapshot["target_peer_id"])
	if target_peer_id < 0:
		return false
	var offers := snapshot["offers"] as Array
	var consumable_prices := snapshot["consumable_prices"] as Array
	if participant_set.has(target_peer_id):
		return (
			_are_valid_consumable_prices(consumable_prices)
			and _are_valid_offers(offers, consumable_prices)
			and int(snapshot["shelf_revision"]) >= 0
			and bool(snapshot["target_exited"]) == exited_set.has(target_peer_id)
		)
	return (
		offers.is_empty()
		and consumable_prices.is_empty()
		and int(snapshot["shelf_revision"]) == -1
		and bool(snapshot["target_exited"])
	)


func _get_authoritative_snapshot_core(snapshot: Dictionary) -> Dictionary:
	return {
		"schema_version": snapshot.get("schema_version"),
		"occurrence_key": snapshot.get("occurrence_key"),
		"route_revision": snapshot.get("route_revision"),
		"session_revision": snapshot.get("session_revision"),
		"phase": snapshot.get("phase"),
		"participant_peer_ids": (
			(snapshot.get("participant_peer_ids", []) as Array).duplicate()
		),
		"exited_peer_ids": (
			(snapshot.get("exited_peer_ids", []) as Array).duplicate()
		),
		"waiting_peer_ids": (
			(snapshot.get("waiting_peer_ids", []) as Array).duplicate()
		),
		"target_peer_id": snapshot.get("target_peer_id"),
		"target_exited": snapshot.get("target_exited"),
		"shelf_revision": snapshot.get("shelf_revision"),
		"offers": (snapshot.get("offers", []) as Array).duplicate(true),
		"consumable_prices": (
			(snapshot.get("consumable_prices", []) as Array).duplicate(true)
		),
	}


func _result(success: bool, code: StringName) -> Dictionary:
	return {
		"success": success,
		"result_code": String(code),
		"session_revision": _session_revision,
		"phase": _phase,
		"waiting_peer_ids": get_waiting_peer_ids(),
	}
