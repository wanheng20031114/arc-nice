extends Node
class_name RogueUndergroundShopController

signal host_snapshot_committed(target_peer_id: int, snapshot: Dictionary)
signal purchase_requested(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
)
signal sell_requested(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
)
signal exit_ack_requested(
	occurrence_key: String,
	expected_session_revision: int
)
signal route_presentation_requested(active: bool)
signal presentation_state_changed

@export var view_path: NodePath
@export var transition_path: NodePath

@onready var economy: RogueUndergroundShopEconomyCoordinator = $Economy
@onready var view: RogueUndergroundShopView = get_node(view_path)
@onready var transition: RogueUndergroundShopTransition = get_node(
	transition_path
)

var _config: RogueUndergroundShopConfig = null
var _run_state: RunStateStore = null
var _session := RogueUndergroundShopSession.new()
var _authority_enabled := false
var _local_peer_id := 0
var _player_names: Dictionary = {}
var _player_character_ids: Dictionary = {}
var _participant_stable_keys: Dictionary = {0: "singleplayer:local"}
var _local_snapshot: Dictionary = {}
var _local_occurrence_key := ""
var _local_exit_requested := false
var _transition_active := false
var _presentation_serial := 0
var _request_sequence := 0


func _ready() -> void:
	_connect_session()


func configure(
	config: RogueUndergroundShopConfig,
	run_state: RunStateStore
) -> bool:
	if (
		config == null
		or not config.validate_config().is_empty()
		or run_state == null
	):
		return false
	_config = config
	_run_state = run_state
	return economy.configure(_config, _run_state, _session)


func set_identity_context(
	authority_enabled: bool,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary,
	participant_stable_keys: Dictionary
) -> void:
	_authority_enabled = authority_enabled
	_local_peer_id = local_peer_id
	_player_names = player_names.duplicate(true)
	_player_character_ids = player_character_ids.duplicate(true)
	_participant_stable_keys = participant_stable_keys.duplicate(true)
	if not _participant_stable_keys.has(0):
		_participant_stable_keys[0] = "singleplayer:local"


func reset_runtime(
	authority_enabled: bool,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary,
	participant_stable_keys: Dictionary
) -> bool:
	set_identity_context(
		authority_enabled,
		local_peer_id,
		player_names,
		player_character_ids,
		participant_stable_keys
	)
	_presentation_serial += 1
	_local_snapshot.clear()
	_local_occurrence_key = ""
	_local_exit_requested = false
	_transition_active = false
	transition.hide_immediately()
	view.close_immediately()
	route_presentation_requested.emit(true)
	presentation_state_changed.emit()
	_disconnect_session()
	_session = RogueUndergroundShopSession.new()
	_connect_session()
	return (
		_config != null
		and _run_state != null
		and economy.configure(_config, _run_state, _session)
	)


func start_authoritative_for_node(
	layout_hash: String,
	node_id: int,
	node_seed: int,
	visit_count: int,
	route_revision: int,
	participant_peer_ids: Array[int]
) -> bool:
	if (
		not _authority_enabled
		or _config == null
		or layout_hash.is_empty()
		or node_id < 0
		or visit_count != 1
		or route_revision < 0
		or participant_peer_ids.is_empty()
		or _session.get_phase() not in [
			RogueUndergroundShopSession.Phase.IDLE,
			RogueUndergroundShopSession.Phase.CLOSED,
		]
	):
		return false
	var offers_by_peer: Dictionary = {}
	var consumable_prices_by_peer: Dictionary = {}
	for peer_id in participant_peer_ids:
		var character_id := StringName(
			_player_character_ids.get(
				peer_id,
				PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
			)
		)
		var stable_key := str(_participant_stable_keys.get(peer_id, ""))
		if stable_key.is_empty():
			return false
		var offers := RogueUndergroundShopOfferGenerator.generate_offers(
			_config,
			node_seed,
			stable_key,
			character_id
		)
		if offers.size() != RogueUndergroundShopSession.OFFER_COUNT:
			return false
		var consumable_prices := (
			RogueUndergroundShopOfferGenerator.generate_consumable_prices(
				_config,
				node_seed,
				stable_key
			)
		)
		if consumable_prices.size() != _config.consumable_listings.size():
			return false
		offers_by_peer[peer_id] = offers
		consumable_prices_by_peer[peer_id] = consumable_prices
	var occurrence_key := make_occurrence_key(
		layout_hash,
		node_id,
		node_seed
	)
	return _session.start_authoritative(
		occurrence_key,
		route_revision,
		offers_by_peer,
		consumable_prices_by_peer
	)


func export_snapshot_for_peer(
	target_peer_id: int,
	transaction_result: Dictionary = {}
) -> Dictionary:
	if (
		_session.get_phase() == RogueUndergroundShopSession.Phase.IDLE
		or _run_state == null
	):
		return {}
	var snapshot := _session.export_snapshot_for_peer(target_peer_id)
	if snapshot.is_empty():
		return {}
	var party_economy := _run_state.export_party_economy_snapshot(
		PackedInt32Array([target_peer_id])
	)
	if party_economy.is_empty():
		return {}
	var sell_slots: Array[Dictionary] = []
	var inventory_revision := -1
	var xirang_revision := -1
	for page_index in RogueUndergroundShopEconomyCoordinator.SELL_PAGE_COUNT:
		var page := economy.get_sell_inventory_page(target_peer_id, page_index)
		if page.is_empty():
			return {}
		if inventory_revision < 0:
			inventory_revision = int(page.get("inventory_revision", -1))
			xirang_revision = int(page.get("xirang_revision", -1))
		for slot_value in page.get("slots", []) as Array:
			var slot := (slot_value as Dictionary).duplicate(true)
			if int(slot.get("slot_index", -1)) >= RunStateStore.INVENTORY_CAPACITY:
				continue
			sell_slots.append(slot)
	snapshot["inventory_revision"] = inventory_revision
	snapshot["xirang_revision"] = xirang_revision
	snapshot["xirang_balance"] = _run_state.get_party_xirang_balance(
		target_peer_id
	)
	snapshot["sell_slots"] = sell_slots
	snapshot["party_economy"] = party_economy
	snapshot["waiting_player_names"] = get_waiting_player_names()
	if not transaction_result.is_empty():
		snapshot["transaction_result"] = transaction_result.duplicate(true)
	return snapshot


func preflight_snapshot(
	snapshot: Dictionary,
	graph: RogueRouteGraph,
	state: RogueRouteRuntimeState
) -> bool:
	if (
		not _is_snapshot_monotonic(snapshot)
		or not _validate_snapshot_against_route(snapshot, graph, state)
		or int(snapshot.get("target_peer_id", -1)) != _local_peer_id
		or typeof(snapshot.get("party_economy")) != TYPE_DICTIONARY
		or not _validate_snapshot_consumable_prices(snapshot)
	):
		return false
	var probe := RogueUndergroundShopSession.new()
	var current := _session.export_snapshot_for_peer(_local_peer_id)
	if not current.is_empty() and not probe.apply_snapshot(current):
		# old→new 重连时客户端 Session 仍只缓存 old 的目标货架；此时
		# export(new) 不是可解码快照。单调性已由真实 Session 字段检查，
		# 用空 probe 验证 Host 下发的 new spectator 快照即可恢复。
		probe = RogueUndergroundShopSession.new()
	if not probe.apply_snapshot(_extract_session_snapshot(snapshot)):
		return false
	return _validate_snapshot_economy_enrichment(snapshot, probe)


func _validate_snapshot_consumable_prices(snapshot: Dictionary) -> bool:
	if _config == null or typeof(snapshot.get("consumable_prices")) != TYPE_ARRAY:
		return false
	var participant_ids := snapshot.get("participant_peer_ids", []) as Array
	var target_peer_id := int(snapshot.get("target_peer_id", -1))
	var prices := snapshot.get("consumable_prices", []) as Array
	if not participant_ids.has(target_peer_id):
		return prices.is_empty()
	if prices.size() != _config.consumable_listings.size():
		return false
	var expected_tiers: Dictionary = {}
	for listing in _config.consumable_listings:
		if listing == null:
			return false
		expected_tiers[listing.get_config_path()] = int(listing.price_tier)
	var seen_paths: Dictionary = {}
	for entry_value in prices:
		if typeof(entry_value) != TYPE_DICTIONARY:
			return false
		var entry := entry_value as Dictionary
		var config_path := str(entry.get("config_path", ""))
		if (
			not expected_tiers.has(config_path)
			or seen_paths.has(config_path)
			or int(entry.get("price_tier", -1))
			!= int(expected_tiers[config_path])
		):
			return false
		seen_paths[config_path] = true
	return seen_paths.size() == expected_tiers.size()


func _validate_snapshot_economy_enrichment(
	snapshot: Dictionary,
	price_session: RogueUndergroundShopSession
) -> bool:
	if (
		_run_state == null
		or typeof(snapshot.get("sell_slots")) != TYPE_ARRAY
	):
		return false
	var party_economy := snapshot.get("party_economy", {}) as Dictionary
	if not _run_state.validate_party_economy_snapshot(party_economy):
		return false
	var inventories := party_economy.get("inventories", []) as Array
	if inventories.size() != 1:
		return false
	var inventory := inventories[0] as Dictionary
	if (
		int(inventory.get("peer_id", -1)) != _local_peer_id
		or typeof(snapshot.get("inventory_revision")) != TYPE_INT
		or int(snapshot["inventory_revision"])
		!= int(inventory.get("revision", -1))
	):
		return false
	var xirang_ledger := party_economy.get("xirang_ledger", {}) as Dictionary
	var xirang_values := xirang_ledger.get("values", {}) as Dictionary
	var balance_value: Variant = xirang_values.get(
		_local_peer_id,
		xirang_values.get(str(_local_peer_id), null)
	)
	if (
		typeof(snapshot.get("xirang_revision")) != TYPE_INT
		or int(snapshot["xirang_revision"])
		!= int(xirang_ledger.get("revision", -1))
		or typeof(snapshot.get("xirang_balance")) != TYPE_INT
		or typeof(balance_value) != TYPE_INT
		or int(snapshot["xirang_balance"]) != int(balance_value)
	):
		return false
	var inventory_slots := inventory.get("slots", []) as Array
	var sell_slots := snapshot.get("sell_slots", []) as Array
	if (
		inventory_slots.size() != RunStateStore.INVENTORY_CAPACITY
		or sell_slots.size() != RunStateStore.INVENTORY_CAPACITY
	):
		return false
	var inventory_by_index: Dictionary = {}
	for slot_value in inventory_slots:
		var slot := slot_value as Dictionary
		inventory_by_index[int(slot.get("slot_index", -1))] = slot
	var seen_sell_indices: Dictionary = {}
	for slot_value in sell_slots:
		var slot := slot_value as Dictionary
		if (
			typeof(slot.get("slot_index")) != TYPE_INT
			or typeof(slot.get("config_path")) != TYPE_STRING
			or typeof(slot.get("stack_count")) != TYPE_INT
			or typeof(slot.get("can_sell")) != TYPE_BOOL
			or typeof(slot.get("sell_price")) != TYPE_INT
			or typeof(slot.get("disabled_reason")) != TYPE_STRING
		):
			return false
		var slot_index := int(slot.get("slot_index", -1))
		if (
			slot_index < 0
			or slot_index >= RunStateStore.INVENTORY_CAPACITY
			or seen_sell_indices.has(slot_index)
			or not inventory_by_index.has(slot_index)
		):
			return false
		seen_sell_indices[slot_index] = true
		var inventory_slot := inventory_by_index[slot_index] as Dictionary
		var config_path := str(inventory_slot.get("config_path", ""))
		var item := (
			load(config_path) as PickupConfig
			if not config_path.is_empty()
			else null
		)
		var sell_price := economy.get_sell_price_for_session(
			_local_peer_id,
			item,
			price_session
		)
		var disabled_reason := ""
		if item == null:
			disabled_reason = "empty"
		elif item.inventory_locked:
			disabled_reason = "locked"
		elif item.pickup_type == PickupConfig.PickupType.BUILDING:
			disabled_reason = "building"
		elif sell_price <= 0:
			disabled_reason = "unsupported_type"
		if (
			str(slot["config_path"]) != config_path
			or int(slot.get("stack_count", -1))
			!= int(inventory_slot.get("stack_count", -2))
			or int(slot["sell_price"]) != sell_price
			or str(slot["disabled_reason"]) != disabled_reason
			or bool(slot["can_sell"])
			!= (disabled_reason.is_empty() and sell_price > 0)
		):
			return false
	return seen_sell_indices.size() == RunStateStore.INVENTORY_CAPACITY


func apply_snapshot(
	snapshot: Dictionary,
	graph: RogueRouteGraph,
	state: RogueRouteRuntimeState
) -> bool:
	if (
		_authority_enabled
		or snapshot.is_empty()
		or _run_state == null
		or not preflight_snapshot(snapshot, graph, state)
	):
		return false
	var party_economy := snapshot.get("party_economy", {}) as Dictionary
	if party_economy.is_empty():
		return false
	var session_snapshot := _extract_session_snapshot(snapshot)
	var decoded_session := RogueUndergroundShopSession.new()
	if not decoded_session.apply_snapshot(session_snapshot):
		return false
	if not _run_state.apply_party_economy_snapshot(party_economy):
		return false
	if not _session.apply_snapshot(session_snapshot):
		return false
	_local_snapshot = snapshot.duplicate(true)
	_sync_local_presentation(_local_snapshot)
	return true


func host_submit_purchase(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	if not _authority_enabled:
		return false
	var result := economy.submit_purchase(
		peer_id,
		request_id,
		occurrence_key,
		offer_index,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision,
		expected_session_revision
	)
	_publish_snapshot_for_peer(peer_id, result)
	return bool(result.get("success", false))


func host_submit_sell(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	if not _authority_enabled:
		return false
	var result := economy.submit_sell(
		peer_id,
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_inventory_revision,
		expected_xirang_revision,
		expected_session_revision
	)
	_publish_snapshot_for_peer(peer_id, result)
	return bool(result.get("success", false))


func host_submit_exit(
	peer_id: int,
	occurrence_key: String,
	expected_session_revision: int
) -> bool:
	if not _authority_enabled:
		return false
	var result := _session.submit_exit(
		peer_id,
		occurrence_key,
		expected_session_revision
	)
	if not bool(result.get("success", false)):
		_publish_snapshot_for_peer(peer_id, result)
	return bool(result.get("success", false))


func remove_peer(peer_id: int) -> void:
	if _authority_enabled:
		_session.remove_peer(peer_id)


func migrate_peer_as_exited(old_peer_id: int, new_peer_id: int) -> void:
	if (
		not _authority_enabled
		or _session.get_phase() == RogueUndergroundShopSession.Phase.IDLE
	):
		return
	_session.migrate_peer_as_exited(old_peer_id, new_peer_id)


func add_spectator(peer_id: int) -> void:
	if (
		not _authority_enabled
		or _session.get_phase() == RogueUndergroundShopSession.Phase.IDLE
	):
		return
	_session.add_exited_spectator(peer_id)


func get_waiting_peer_ids() -> Array[int]:
	return _session.get_waiting_peer_ids()


func get_waiting_player_names() -> PackedStringArray:
	var result := PackedStringArray()
	for peer_id in _session.get_waiting_peer_ids():
		result.append(str(_player_names.get(peer_id, "玩家 %d" % peer_id)))
	return result


func is_departure_ready() -> bool:
	return _session.can_depart()


func is_departure_blocked() -> bool:
	return (
		_session.get_phase() == RogueUndergroundShopSession.Phase.SHOPPING
		and not _session.get_waiting_peer_ids().is_empty()
	)


func begin_departing() -> bool:
	var phase := _session.get_phase()
	if phase in [
		RogueUndergroundShopSession.Phase.IDLE,
		RogueUndergroundShopSession.Phase.CLOSED,
	]:
		return true
	if phase != RogueUndergroundShopSession.Phase.READY_TO_DEPART:
		return false
	return _session.begin_departing(_session.get_session_revision())


func cancel_departing() -> bool:
	if _session.get_phase() != RogueUndergroundShopSession.Phase.DEPARTING:
		return false
	return _session.cancel_departing(_session.get_session_revision())


func close_departing() -> bool:
	return _session.close()


func is_presentation_active() -> bool:
	return _transition_active or view.visible


func get_session_revision() -> int:
	return _session.get_session_revision()


func get_session_route_revision() -> int:
	return _session.get_route_revision()


func get_phase() -> int:
	return int(_session.get_phase())


static func make_occurrence_key(
	layout_hash: String,
	node_id: int,
	node_seed: int
) -> String:
	return "shop:%s:%d:%d:1" % [layout_hash, node_id, node_seed]


func _connect_session() -> void:
	if not _session.session_changed.is_connected(_on_session_changed):
		_session.session_changed.connect(_on_session_changed)


func _disconnect_session() -> void:
	if _session.session_changed.is_connected(_on_session_changed):
		_session.session_changed.disconnect(_on_session_changed)


func _on_session_changed(_session_revision: int) -> void:
	if not _authority_enabled:
		return
	for peer_id in _session.get_snapshot_target_peer_ids():
		_publish_snapshot_for_peer(peer_id)


func _publish_snapshot_for_peer(
	peer_id: int,
	transaction_result: Dictionary = {}
) -> void:
	if not _authority_enabled:
		return
	var snapshot := export_snapshot_for_peer(peer_id, transaction_result)
	if snapshot.is_empty():
		return
	if peer_id == _local_peer_id:
		_local_snapshot = snapshot.duplicate(true)
		_sync_local_presentation(_local_snapshot)
	host_snapshot_committed.emit(peer_id, snapshot.duplicate(true))


func _validate_snapshot_against_route(
	snapshot: Dictionary,
	graph: RogueRouteGraph,
	state: RogueRouteRuntimeState
) -> bool:
	if (
		graph == null
		or state == null
		or int(snapshot.get("route_revision", -1)) < 0
		or int(snapshot.get("route_revision", -1)) > state.state_revision
	):
		return false
	var probe := RogueUndergroundShopSession.new()
	if not probe.apply_snapshot(_extract_session_snapshot(snapshot)):
		return false
	var phase := int(snapshot.get("phase", -1))
	if phase not in [
		RogueUndergroundShopSession.Phase.SHOPPING,
		RogueUndergroundShopSession.Phase.READY_TO_DEPART,
	]:
		return true
	var node_id := state.current_node_id
	if (
		not graph.is_valid_node_id(node_id)
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.UNDERGROUND_SHOP
		or int(state.visited_counts[node_id]) < 1
	):
		return false
	return str(snapshot.get("occurrence_key", "")) == make_occurrence_key(
		graph.compute_layout_hash(),
		node_id,
		graph.get_node_content_seed(node_id)
	)


func _is_snapshot_monotonic(snapshot: Dictionary) -> bool:
	var current_occurrence := _session.get_occurrence_key()
	if current_occurrence.is_empty():
		return true
	var incoming_occurrence := str(snapshot.get("occurrence_key", ""))
	if incoming_occurrence == current_occurrence:
		return int(snapshot.get("session_revision", -1)) >= (
			_session.get_session_revision()
		)
	return int(snapshot.get("route_revision", -1)) > (
		_session.get_route_revision()
	)


func _extract_session_snapshot(snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for field_name in [
		"schema_version",
		"occurrence_key",
		"route_revision",
		"session_revision",
		"phase",
		"participant_peer_ids",
		"exited_peer_ids",
		"waiting_peer_ids",
		"target_peer_id",
		"target_exited",
		"shelf_revision",
		"offers",
		"consumable_prices",
	]:
		if snapshot.has(field_name):
			result[field_name] = snapshot[field_name]
	return result.duplicate(true)


func _sync_local_presentation(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var occurrence_key := str(snapshot.get("occurrence_key", ""))
	if occurrence_key != _local_occurrence_key:
		_local_occurrence_key = occurrence_key
		_local_exit_requested = false
	view.present_shop_snapshot(snapshot)
	view.present_sell_inventory(snapshot.get("sell_slots", []) as Array)
	var transaction_result := snapshot.get("transaction_result", {}) as Dictionary
	if not transaction_result.is_empty():
		view.set_transaction_pending(false)
		if not bool(transaction_result.get("success", false)):
			view.present_transaction_error(
				_get_result_message(
					StringName(transaction_result.get("result_code", ""))
				)
			)
	var target_exited := bool(snapshot.get("target_exited", false))
	if target_exited:
		_local_exit_requested = true
		if view.visible and not _transition_active:
			view.close_immediately()
			route_presentation_requested.emit(true)
			presentation_state_changed.emit()
		return
	if _local_exit_requested:
		if not _transition_active:
			call_deferred(&"_submit_local_exit_ack")
		return
	if (
		int(snapshot.get("phase", -1))
		== RogueUndergroundShopSession.Phase.SHOPPING
		and not view.visible
		and not _transition_active
	):
		call_deferred(&"_enter_presentation", occurrence_key)


func _enter_presentation(occurrence_key: String) -> void:
	if (
		occurrence_key.is_empty()
		or occurrence_key != _local_occurrence_key
		or _local_exit_requested
		or _transition_active
		or view.visible
	):
		return
	_presentation_serial += 1
	var serial := _presentation_serial
	_transition_active = true
	presentation_state_changed.emit()
	if not await transition.cover():
		_transition_active = false
		presentation_state_changed.emit()
		return
	if (
		serial != _presentation_serial
		or occurrence_key != _local_occurrence_key
		or _local_exit_requested
	):
		return
	route_presentation_requested.emit(false)
	view.open_session()
	view.present_shop_snapshot(_local_snapshot)
	view.present_sell_inventory(_local_snapshot.get("sell_slots", []) as Array)
	await transition.reveal()
	if serial != _presentation_serial:
		return
	_transition_active = false
	presentation_state_changed.emit()


func _on_view_exit_requested() -> void:
	if (
		_local_exit_requested
		or _transition_active
		or _local_snapshot.is_empty()
		or bool(_local_snapshot.get("target_exited", false))
	):
		return
	_local_exit_requested = true
	_presentation_serial += 1
	var serial := _presentation_serial
	_transition_active = true
	view.set_exit_enabled(false)
	view.set_transaction_pending(true, "正在离开商店…")
	presentation_state_changed.emit()
	if not await transition.cover():
		_transition_active = false
		presentation_state_changed.emit()
		return
	if serial != _presentation_serial:
		return
	view.close_immediately()
	route_presentation_requested.emit(true)
	await transition.reveal()
	if serial != _presentation_serial:
		return
	_transition_active = false
	presentation_state_changed.emit()
	_submit_local_exit_ack()


func _on_view_purchase_requested(offer_index: int) -> void:
	if not _can_submit_transaction():
		return
	var request_id := _next_request_id(&"purchase")
	var occurrence_key := str(_local_snapshot["occurrence_key"])
	var session_revision := int(_local_snapshot["session_revision"])
	var shelf_revision := int(_local_snapshot["shelf_revision"])
	var inventory_revision := int(_local_snapshot["inventory_revision"])
	var xirang_revision := int(_local_snapshot["xirang_revision"])
	view.set_transaction_pending(true, "正在确认购买…")
	if _authority_enabled:
		host_submit_purchase(
			_local_peer_id,
			request_id,
			occurrence_key,
			offer_index,
			session_revision,
			shelf_revision,
			inventory_revision,
			xirang_revision
		)
	else:
		purchase_requested.emit(
			request_id,
			occurrence_key,
			offer_index,
			session_revision,
			shelf_revision,
			inventory_revision,
			xirang_revision
		)


func _on_view_sell_requested(
	slot_index: int,
	expected_config_path: String
) -> void:
	if not _can_submit_transaction():
		return
	var request_id := _next_request_id(&"sell")
	var occurrence_key := str(_local_snapshot["occurrence_key"])
	var session_revision := int(_local_snapshot["session_revision"])
	var inventory_revision := int(_local_snapshot["inventory_revision"])
	var xirang_revision := int(_local_snapshot["xirang_revision"])
	view.set_transaction_pending(true, "正在确认出售…")
	if _authority_enabled:
		host_submit_sell(
			_local_peer_id,
			request_id,
			occurrence_key,
			slot_index,
			expected_config_path,
			session_revision,
			inventory_revision,
			xirang_revision
		)
	else:
		sell_requested.emit(
			request_id,
			occurrence_key,
			slot_index,
			expected_config_path,
			session_revision,
			inventory_revision,
			xirang_revision
		)


func _on_view_sell_inventory_requested() -> void:
	if not _local_snapshot.is_empty():
		view.present_sell_inventory(
			_local_snapshot.get("sell_slots", []) as Array
		)


func _on_view_sell_page_requested(page_index: int) -> void:
	if _local_snapshot.is_empty():
		return
	var page := economy.get_sell_inventory_page(_local_peer_id, page_index)
	if page.is_empty():
		return
	_local_snapshot["inventory_revision"] = int(
		page.get("inventory_revision", -1)
	)
	_local_snapshot["xirang_revision"] = int(page.get("xirang_revision", -1))
	view.present_sell_inventory_page(page)


func _can_submit_transaction() -> bool:
	return (
		not _local_exit_requested
		and not _transition_active
		and not _local_snapshot.is_empty()
		and int(_local_snapshot.get("phase", -1))
		== RogueUndergroundShopSession.Phase.SHOPPING
		and not bool(_local_snapshot.get("target_exited", false))
	)


func _next_request_id(operation: StringName) -> String:
	_request_sequence += 1
	return "%d:%s:%s:%d" % [
		_local_peer_id,
		String(operation),
		_local_occurrence_key,
		_request_sequence,
	]


func _submit_local_exit_ack() -> void:
	if (
		not _local_exit_requested
		or _transition_active
		or _local_snapshot.is_empty()
		or bool(_local_snapshot.get("target_exited", false))
	):
		return
	var occurrence_key := str(_local_snapshot.get("occurrence_key", ""))
	var expected_revision := int(
		_local_snapshot.get("session_revision", -1)
	)
	if _authority_enabled:
		host_submit_exit(
			_local_peer_id,
			occurrence_key,
			expected_revision
		)
	else:
		exit_ack_requested.emit(occurrence_key, expected_revision)


func _get_result_message(result_code: StringName) -> String:
	match result_code:
		&"insufficient_xirang":
			return "息壤不足，无法购买。"
		&"inventory_full":
			return "背包已满，无法购买。"
		&"item_not_sellable":
			return "该物品不可出售。"
		&"item_mismatch":
			return "背包内容已经变化，请重新选择。"
		&"offer_unavailable":
			return "该商品已经售罄。"
		&"request_id_reused":
			return "交易请求已失效，请重试。"
		&"stale_state":
			return "商店状态已更新，请重试。"
		_:
			return "交易未完成，请重试。"
