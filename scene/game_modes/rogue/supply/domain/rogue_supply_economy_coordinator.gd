extends Node
class_name RogueSupplyEconomyCoordinator

signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 2
const CORE_HEALTH_REWARD := 10
const LIGHT_STONE_REWARD := 3
const LARGE_XIRANG_REWARD := 5000
const SMALL_XIRANG_REWARD := 1000
const ACTION_POINT_REWARD := 2
const LIGHT_STONE_ACTION_POINT_REWARD := 3
const FLYING_ENVELOPE_PATH := (
	"res://resources/config/collectibles/collectible_flying_envelope.tres"
)

var _run_state: RunStateStore
var _route_state: RogueRouteRuntimeState
var _player_character_ids: Dictionary = {}
var _economy_revision := 0
var _settled_occurrences: Dictionary = {}
var _pending_collectible_offers: Dictionary = {}
var _pending_collectible_sequence := 0


func reset_runtime(
	run_state: RunStateStore,
	route_state: RogueRouteRuntimeState = null,
	player_character_ids: Dictionary = {}
) -> void:
	_run_state = run_state
	_route_state = route_state
	_player_character_ids = player_character_ids.duplicate(true)
	_economy_revision = 0
	_settled_occurrences.clear()
	_pending_collectible_offers.clear()
	_pending_collectible_sequence = 0
	if _run_state != null:
		_run_state.ensure_run_started()


func set_route_state(route_state: RogueRouteRuntimeState) -> void:
	_route_state = route_state


func set_player_character_ids(player_character_ids: Dictionary) -> void:
	_player_character_ids = player_character_ids.duplicate(true)


func is_configured() -> bool:
	return _run_state != null


func get_light_stone_amount() -> int:
	return _run_state.get_party_light_stone_amount() if _run_state != null else 0


func get_option_availability(option_ids: Array[StringName]) -> Dictionary:
	var result: Dictionary = {}
	var light_stone_amount := get_light_stone_amount()
	for option_id in option_ids:
		var available := RogueSupplyRegistry.has_option(option_id)
		if RogueSupplyRegistry.get_light_stone_cost(option_id) > light_stone_amount:
			available = false
		if option_id == RogueSupplyRegistry.OPTION_FLYING_ENVELOPE:
			available = available and not party_has_flying_envelope()
		if option_id == RogueSupplyRegistry.OPTION_GAIN_ACTION_POINTS:
			available = available and can_grant_action_points(
				ACTION_POINT_REWARD
			)
		elif option_id == RogueSupplyRegistry.OPTION_LIGHT_STONE_ACTION_POINTS:
			available = available and can_grant_action_points(
				LIGHT_STONE_ACTION_POINT_REWARD
			)
		result[String(option_id)] = available
	return result


func can_grant_action_points(amount: int) -> bool:
	return (
		_route_state != null
		and _route_state.is_initialized()
		and amount > 0
		and _route_state.action_points
		<= RogueRouteRuntimeState.MAX_ACTION_POINTS - amount
	)


func party_has_flying_envelope(_peer_ids: Array[int] = []) -> bool:
	if _run_state == null:
		return false
	var envelope := load(FLYING_ENVELOPE_PATH) as PickupConfig
	return (
		envelope != null
		and _run_state.get_party_item_total(envelope) > 0
	)


func resolve_option(
	option_id: StringName,
	node_content_seed: int,
	participant_peer_ids: Array[int],
	occurrence_key: String,
	prepared_collectible_offers: Dictionary = {}
) -> Dictionary:
	if occurrence_key.is_empty():
		return _make_result(false, option_id, "invalid_occurrence")
	if _settled_occurrences.has(occurrence_key):
		return (_settled_occurrences[occurrence_key] as Dictionary).duplicate(true)
	var peers := _prepare_peer_ids(participant_peer_ids)
	if (
		_run_state == null
		or peers.is_empty()
		or not RogueSupplyRegistry.has_option(option_id)
	):
		return _make_result(false, option_id, "invalid_request")
	var result: Dictionary
	match option_id:
		RogueSupplyRegistry.OPTION_CORE_REPAIR:
			result = _resolve_core_repair(peers, option_id)
		RogueSupplyRegistry.OPTION_GAIN_LIGHT_STONES:
			result = _resolve_light_stone_change(
				peers,
				option_id,
				LIGHT_STONE_REWARD
			)
		RogueSupplyRegistry.OPTION_LIGHT_STONE_XIRANG:
			result = _resolve_xirang_reward(
				peers,
				option_id,
				LARGE_XIRANG_REWARD,
				-RogueSupplyRegistry.LIGHT_STONE_COST
			)
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES:
			result = _resolve_collectible_begin(
				peers,
				option_id,
				prepared_collectible_offers,
				occurrence_key
			)
		RogueSupplyRegistry.OPTION_GAIN_XIRANG:
			result = _resolve_xirang_reward(
				peers,
				option_id,
				SMALL_XIRANG_REWARD,
				0
			)
		RogueSupplyRegistry.OPTION_FLYING_ENVELOPE:
			result = _resolve_flying_envelope(
				peers,
				option_id,
				node_content_seed
			)
		RogueSupplyRegistry.OPTION_GAIN_ACTION_POINTS:
			result = _resolve_action_points(
				peers,
				option_id,
				ACTION_POINT_REWARD,
				false
			)
		RogueSupplyRegistry.OPTION_LIGHT_STONE_ACTION_POINTS:
			result = _resolve_action_points(
				peers,
				option_id,
				LIGHT_STONE_ACTION_POINT_REWARD,
				true
			)
		_:
			result = _make_result(false, option_id, "invalid_option")
	if not bool(result.get("resolved", false)):
		return result
	_economy_revision += 1
	result["economy_revision"] = _economy_revision
	_settled_occurrences[occurrence_key] = result.duplicate(true)
	economy_changed.emit(export_snapshot(peers))
	return result


func build_collectible_offers(
	node_content_seed: int,
	participant_peer_ids: Array[int]
) -> Dictionary:
	var result: Dictionary = {}
	for peer_id in _prepare_peer_ids(participant_peer_ids):
		var offer_paths := _build_collectible_offer_for_peer(
			node_content_seed,
			peer_id
		)
		if offer_paths.size() != 3:
			return {}
		result[peer_id] = offer_paths
	return result


func claim_collectible(
	peer_id: int,
	offer_paths: Array[String],
	offer_index: int,
	occurrence_key: String
) -> Dictionary:
	var claim_key := "%s|collectible:%d" % [occurrence_key, peer_id]
	if _settled_occurrences.has(claim_key):
		return (_settled_occurrences[claim_key] as Dictionary).duplicate(true)
	if (
		_run_state == null
		or peer_id < 0
		or offer_index < 0
	):
		return {"claimed": false, "reason": "invalid_request"}
	var pending_key := _make_collectible_claim_key(occurrence_key, peer_id)
	if not _pending_collectible_offers.has(pending_key):
		return {"claimed": false, "reason": "stale_offer"}
	var pending := _pending_collectible_offers[pending_key] as Dictionary
	var authoritative_paths := pending.get("paths", []) as Array
	if (
		str(pending.get("occurrence_key", "")) != occurrence_key
		or offer_index >= authoritative_paths.size()
		or offer_paths != authoritative_paths
	):
		return {"claimed": false, "reason": "stale_offer"}
	var config_path := str(authoritative_paths[offer_index])
	var item := CollectibleRegistry.get_for_path(config_path)
	if (
		item == null
		or not CollectibleRegistry.is_standard_random_collectible(item)
		or not _is_collectible_compatible_with_character(
			item,
			_get_character_id_for_peer(peer_id)
		)
	):
		return {"claimed": false, "reason": "invalid_collectible"}
	var inventory_revision := _get_inventory_revision(peer_id)
	if not _try_add_item_if_revision(peer_id, item, inventory_revision):
		return {"claimed": false, "reason": "inventory_full"}
	_economy_revision += 1
	var result := {
		"claimed": true,
		"peer_id": peer_id,
		"config_path": config_path,
		"display_name": item.display_name,
		"economy_revision": _economy_revision,
	}
	_settled_occurrences[claim_key] = result.duplicate(true)
	_pending_collectible_offers.erase(pending_key)
	economy_changed.emit(export_snapshot([peer_id]))
	return result


func has_pending_collectible_claims() -> bool:
	return not _pending_collectible_offers.is_empty()


func get_pending_collectible_offers() -> Dictionary:
	var result: Dictionary = {}
	for pending in _get_sorted_pending_collectible_entries():
		var peer_id := int(pending.get("peer_id", -1))
		if peer_id >= 0 and not result.has(peer_id):
			result[peer_id] = (pending.get("paths", []) as Array).duplicate()
	return result


func get_pending_collectible_occurrence(peer_id: int) -> String:
	for pending in _get_sorted_pending_collectible_entries():
		if int(pending.get("peer_id", -1)) == peer_id:
			return str(pending.get("occurrence_key", ""))
	return ""


func export_snapshot(peer_ids: Array[int] = []) -> Dictionary:
	if _run_state == null:
		return {}
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _economy_revision,
		"settled_occurrences": _export_settled_occurrences(),
		"pending_collectible_offers": _export_pending_collectible_offers(),
		"party_economy": _run_state.export_party_economy_snapshot(
			_to_packed_peer_ids(_normalize_peer_ids(peer_ids))
		),
	}


func apply_remote_snapshot(snapshot: Dictionary) -> bool:
	if not validate_remote_snapshot(snapshot):
		return false
	var decoded_occurrences: Variant = _decode_settled_occurrences(
		snapshot["settled_occurrences"] as Array
	)
	if decoded_occurrences == null:
		return false
	var decoded_pending: Variant = _decode_pending_collectible_offers(
		snapshot["pending_collectible_offers"] as Array
	)
	if decoded_pending == null:
		return false
	if not _run_state.apply_party_economy_snapshot(
		snapshot["party_economy"] as Dictionary
	):
		return false
	var changed := int(snapshot["revision"]) != _economy_revision
	_economy_revision = int(snapshot["revision"])
	_settled_occurrences = decoded_occurrences as Dictionary
	_pending_collectible_offers = decoded_pending as Dictionary
	_pending_collectible_sequence = _get_max_pending_collectible_sequence()
	if changed:
		economy_changed.emit(export_snapshot())
	return true


func validate_remote_snapshot(snapshot: Dictionary) -> bool:
	if (
		_run_state == null
		or typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < _economy_revision
		or typeof(snapshot.get("settled_occurrences")) != TYPE_ARRAY
		or typeof(snapshot.get("pending_collectible_offers")) != TYPE_ARRAY
		or typeof(snapshot.get("party_economy")) != TYPE_DICTIONARY
	):
		return false
	if _decode_settled_occurrences(
		snapshot["settled_occurrences"] as Array
	) == null:
		return false
	if _decode_pending_collectible_offers(
		snapshot["pending_collectible_offers"] as Array
	) == null:
		return false
	return _run_state.validate_party_economy_snapshot(
		snapshot["party_economy"] as Dictionary
	)


## 重连只迁移经济日志中的身份引用；RunState 本体由外层先原子 remap。
## 这里不单独发 signal，Session 会把迁移后的结果和账本并入同一状态广播。
func migrate_peer_references(old_peer_id: int, new_peer_id: int) -> bool:
	if old_peer_id < 0 or new_peer_id < 0 or old_peer_id == new_peer_id:
		return false
	var changed := false
	var migrated_occurrences: Dictionary = {}
	var old_claim_suffix := "|collectible:%d" % old_peer_id
	var new_claim_suffix := "|collectible:%d" % new_peer_id
	for raw_key in _settled_occurrences.keys():
		var old_key := str(raw_key)
		var new_key := old_key
		if old_key.ends_with(old_claim_suffix):
			new_key = old_key.trim_suffix(old_claim_suffix) + new_claim_suffix
			changed = true
		if migrated_occurrences.has(new_key):
			return false
		var previous := _settled_occurrences[raw_key] as Dictionary
		var migrated := migrate_result_peer_references(
			previous,
			old_peer_id,
			new_peer_id
		)
		changed = changed or migrated != previous
		migrated_occurrences[new_key] = migrated
	var migrated_character_ids := _player_character_ids.duplicate(true)
	if migrated_character_ids.has(old_peer_id):
		if migrated_character_ids.has(new_peer_id):
			return false
		var character_id: Variant = migrated_character_ids[old_peer_id]
		migrated_character_ids.erase(old_peer_id)
		migrated_character_ids[new_peer_id] = character_id
		changed = true
	var migrated_pending: Dictionary = {}
	for raw_pending_key in _pending_collectible_offers.keys():
		var pending := (
			_pending_collectible_offers[raw_pending_key] as Dictionary
		).duplicate(true)
		var peer_id := int(pending.get("peer_id", -1))
		if peer_id == old_peer_id:
			pending["peer_id"] = new_peer_id
			peer_id = new_peer_id
			changed = true
		var pending_key := _make_collectible_claim_key(
			str(pending.get("occurrence_key", "")),
			peer_id
		)
		if migrated_pending.has(pending_key):
			return false
		migrated_pending[pending_key] = pending
	if changed:
		_pending_collectible_offers = migrated_pending
	if not changed:
		return false
	_settled_occurrences = migrated_occurrences
	_player_character_ids = migrated_character_ids
	_economy_revision += 1
	return true


func migrate_result_peer_references(
	result: Dictionary,
	old_peer_id: int,
	new_peer_id: int
) -> Dictionary:
	var migrated := result.duplicate(true)
	for scalar_field in ["peer_id", "receiver_peer_id"]:
		if int(migrated.get(scalar_field, -1)) == old_peer_id:
			migrated[scalar_field] = new_peer_id
	for array_field in ["xirang_totals"]:
		var entries := migrated.get(array_field, []) as Array
		for entry_index in entries.size():
			if typeof(entries[entry_index]) != TYPE_DICTIONARY:
				continue
			var entry := entries[entry_index] as Dictionary
			if int(entry.get("peer_id", -1)) == old_peer_id:
				entry["peer_id"] = new_peer_id
				entries[entry_index] = entry
		if not entries.is_empty():
			migrated[array_field] = entries
	return migrated


func _resolve_core_repair(
	peers: Array[int],
	option_id: StringName
) -> Dictionary:
	var snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(peers)
	)
	var status := (snapshot["party_status_ledger"] as Dictionary).duplicate(true)
	status["revision"] = int(status["revision"]) + 1
	status["core_current"] = int(status["core_current"]) + CORE_HEALTH_REWARD
	status["core_maximum"] = int(status["core_maximum"]) + CORE_HEALTH_REWARD
	if not _commit_party_snapshot(snapshot, {}, {}, status):
		return _make_result(false, option_id, "stale_state")
	var result := _make_result(true, option_id, "core_repaired")
	result["result_text"] = "核心生命值上限与当前生命值各提高了10点。"
	result["core_current"] = int(status["core_current"])
	result["core_maximum"] = int(status["core_maximum"])
	return result


func _resolve_light_stone_change(
	peers: Array[int],
	option_id: StringName,
	delta: int
) -> Dictionary:
	var snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(peers)
	)
	var light := (snapshot["light_stone_ledger"] as Dictionary).duplicate(true)
	var next_amount := int(light["amount"]) + delta
	if next_amount < 0:
		return _make_result(false, option_id, "insufficient_light_stones")
	light["revision"] = int(light["revision"]) + 1
	light["amount"] = next_amount
	if not _commit_party_snapshot(snapshot, {}, {}, {}, light):
		return _make_result(false, option_id, "stale_state")
	var result := _make_result(true, option_id, "light_stones_changed")
	result["light_stone_delta"] = delta
	result["light_stone_amount"] = next_amount
	result["result_text"] = "全队获得了3块光石。" if delta > 0 else "消耗了1块光石。"
	return result


func _resolve_xirang_reward(
	peers: Array[int],
	option_id: StringName,
	amount_each: int,
	light_stone_delta: int
) -> Dictionary:
	var snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(peers)
	)
	var xirang := (snapshot["xirang_ledger"] as Dictionary).duplicate(true)
	var values := xirang["values"] as Dictionary
	var totals: Array[Dictionary] = []
	for peer_id in peers:
		var peer_key := str(peer_id)
		values[peer_key] = int(values.get(peer_key, 0)) + amount_each
		totals.append({"peer_id": peer_id, "total": int(values[peer_key])})
	xirang["revision"] = int(xirang["revision"]) + 1
	var light: Dictionary = {}
	if light_stone_delta != 0:
		light = (snapshot["light_stone_ledger"] as Dictionary).duplicate(true)
		var next_amount := int(light["amount"]) + light_stone_delta
		if next_amount < 0:
			return _make_result(false, option_id, "insufficient_light_stones")
		light["revision"] = int(light["revision"]) + 1
		light["amount"] = next_amount
	if not _commit_party_snapshot(snapshot, {}, xirang, {}, light):
		return _make_result(false, option_id, "stale_state")
	var result := _make_result(true, option_id, "xirang_granted")
	result["xirang_reward_each"] = amount_each
	result["xirang_totals"] = totals
	result["light_stone_delta"] = light_stone_delta
	result["result_text"] = "每位玩家获得了%d息壤水晶。" % amount_each
	return result


func _resolve_collectible_begin(
	peers: Array[int],
	option_id: StringName,
	prepared_offers: Dictionary,
	occurrence_key: String
) -> Dictionary:
	if not _validate_collectible_offers(peers, prepared_offers):
		return _make_result(false, option_id, "invalid_collectible_offers")
	var result := _resolve_light_stone_change(peers, option_id, -1)
	if not bool(result.get("resolved", false)):
		return result
	result["result_code"] = "collectible_choices_started"
	result["pending_collectible_choices"] = true
	result["result_text"] = "每位玩家可以选择一件收藏品。"
	_pending_collectible_sequence += 1
	for peer_id in peers:
		var claim_key := _make_collectible_claim_key(occurrence_key, peer_id)
		_pending_collectible_offers[claim_key] = {
			"peer_id": peer_id,
			"occurrence_key": occurrence_key,
			"sequence": _pending_collectible_sequence,
			"paths": (prepared_offers[peer_id] as Array).duplicate(),
		}
	return result


func _resolve_flying_envelope(
	peers: Array[int],
	option_id: StringName,
	node_content_seed: int
) -> Dictionary:
	var envelope := load(FLYING_ENVELOPE_PATH) as PickupConfig
	if envelope == null:
		return _make_result(false, option_id, "missing_envelope_config")
	if party_has_flying_envelope(peers):
		return _make_result(false, option_id, "already_owned")
	var candidates: Array[int] = []
	for peer_id in peers:
		if _can_add_item(peer_id, envelope):
			candidates.append(peer_id)
	var result := _make_result(true, option_id, "envelope_dropped")
	if candidates.is_empty():
		result["result_text"] = "所有玩家的背包都已满，会飞的信封离开了。"
		result["reward_dropped"] = true
		return result
	var receiver_index := RogueSupplyRandom.choose_index(
		node_content_seed,
		&"supply_flying_envelope_receiver",
		candidates.size()
	)
	var receiver_peer_id := candidates[receiver_index]
	var inventory_revision := _get_inventory_revision(receiver_peer_id)
	if not _try_add_item_if_revision(
		receiver_peer_id,
		envelope,
		inventory_revision
	):
		return _make_result(false, option_id, "stale_inventory")
	result["result_code"] = "envelope_granted"
	result["reward_granted"] = true
	result["receiver_peer_id"] = receiver_peer_id
	result["config_path"] = FLYING_ENVELOPE_PATH
	result["result_text"] = "会飞的信封选择了一名背包有空位的玩家。"
	return result


func _resolve_action_points(
	peers: Array[int],
	option_id: StringName,
	amount: int,
	consume_light_stone: bool
) -> Dictionary:
	if not can_grant_action_points(amount):
		return _make_result(false, option_id, "action_point_grant_failed")
	if consume_light_stone:
		var cost_result := _resolve_light_stone_change(peers, option_id, -1)
		if not bool(cost_result.get("resolved", false)):
			return cost_result
	if not _route_state.grant_action_points(amount):
		return _make_result(false, option_id, "action_point_grant_failed")
	var result := _make_result(true, option_id, "action_points_granted")
	result["action_points_delta"] = amount
	result["action_points"] = _route_state.action_points
	result["light_stone_delta"] = -1 if consume_light_stone else 0
	result["result_text"] = "全队获得了%d点行动力。" % amount
	return result


func _validate_collectible_offers(
	peers: Array[int],
	offers: Dictionary
) -> bool:
	if offers.size() != peers.size():
		return false
	for peer_id in peers:
		if not offers.has(peer_id):
			return false
		var raw_paths := offers[peer_id] as Array
		if raw_paths.size() != 3:
			return false
		var seen_paths: Dictionary = {}
		for raw_path in raw_paths:
			var config_path := str(raw_path)
			var item := CollectibleRegistry.get_for_path(config_path)
			if (
				config_path.is_empty()
				or seen_paths.has(config_path)
				or item == null
				or not CollectibleRegistry.is_standard_random_collectible(item)
				or not _is_collectible_compatible_with_character(
					item,
					_get_character_id_for_peer(peer_id)
				)
			):
				return false
			seen_paths[config_path] = true
	return true


func _commit_party_snapshot(
	snapshot: Dictionary,
	changed_inventory_revisions: Dictionary = {},
	next_xirang: Dictionary = {},
	next_status: Dictionary = {},
	next_light_stone: Dictionary = {}
) -> bool:
	var expected_inventory_revisions: Dictionary = {}
	for raw_inventory_value in snapshot.get("inventories", []) as Array:
		var inventory := raw_inventory_value as Dictionary
		expected_inventory_revisions[int(inventory.get("peer_id", -1))] = int(
			inventory.get("revision", -1)
		)
	for raw_peer_id in changed_inventory_revisions.keys():
		expected_inventory_revisions[int(raw_peer_id)] = int(
			changed_inventory_revisions[raw_peer_id]
		)
	return _run_state.apply_authoritative_party_transaction(
		snapshot,
		int((snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		int((snapshot["xirang_ledger"] as Dictionary)["revision"])
			if not next_xirang.is_empty() else -1,
		next_xirang,
		int((snapshot["party_status_ledger"] as Dictionary)["revision"])
			if not next_status.is_empty() else -1,
		next_status,
		int((snapshot["light_stone_ledger"] as Dictionary)["revision"])
			if not next_light_stone.is_empty() else -1,
		next_light_stone
	)


func _build_collectible_offer_for_peer(
	node_content_seed: int,
	peer_id: int
) -> Array[String]:
	var character_id := _get_character_id_for_peer(peer_id)
	var pool: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_standard_random_pool():
		if (
			item != null
			and item.can_store_in_inventory
			and _is_collectible_compatible_with_character(item, character_id)
		):
			pool.append(item)
	var rarity_roll := RogueSupplyRandom.choose_index(
		node_content_seed,
		StringName("supply_collectible_rarity|peer:%d" % peer_id),
		100
	)
	var featured_position := RogueSupplyRandom.choose_index(
		node_content_seed,
		StringName("supply_collectible_featured|peer:%d" % peer_id),
		3
	)
	var pattern := _get_rarity_pattern(rarity_roll, featured_position)
	var selected: Array[String] = []
	for choice_index in range(3):
		var eligible: Array[PickupConfig] = []
		for item in pool:
			if (
				int(item.collectible_rarity) == pattern[choice_index]
				and not selected.has(item.resource_path)
			):
				eligible.append(item)
		if eligible.is_empty():
			for item in pool:
				if not selected.has(item.resource_path):
					eligible.append(item)
		if eligible.is_empty():
			return []
		eligible.sort_custom(func(a: PickupConfig, b: PickupConfig) -> bool:
			return a.resource_path < b.resource_path
		)
		var selected_index := RogueSupplyRandom.choose_index(
			node_content_seed,
			StringName(
				"supply_collectible_pick|peer:%d|choice:%d"
				% [peer_id, choice_index]
			),
			eligible.size()
		)
		selected.append(eligible[selected_index].resource_path)
	return selected


func _get_rarity_pattern(roll: int, featured_position: int) -> Array[int]:
	if roll < 50:
		return [0, 0, 0]
	if roll < 80:
		return [1, 1, 1]
	if roll < 92:
		return [2, 2, 2]
	if roll < 95:
		var one := [2, 2, 2]
		one[featured_position] = 3
		return one
	if roll < 98:
		var two := [3, 3, 3]
		two[featured_position] = 2
		return two
	return [3, 3, 3]


func _get_character_id_for_peer(peer_id: int) -> StringName:
	var fallback := _run_state.get_selected_character_id()
	var character_id := StringName(_player_character_ids.get(peer_id, fallback))
	return (
		character_id
		if PlayerCharacterRegistry.is_valid_character_id(character_id)
		else fallback
	)


func _is_collectible_compatible_with_character(
	item: PickupConfig,
	character_id: StringName
) -> bool:
	var supports_ammunition := character_id in [
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		PlayerCharacterRegistry.TIYI_ID,
	]
	if item.requires_projectile_primary_attack and not supports_ammunition:
		return false
	if item.requires_ammunition and not supports_ammunition:
		return false
	return true


func _prepare_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var peers := _normalize_peer_ids(peer_ids)
	for peer_id in peers:
		if peer_id > 0:
			_run_state.ensure_multiplayer_peer_state(peer_id)
	return peers


func _normalize_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id >= 0 and not result.has(peer_id):
			result.append(peer_id)
	result.sort()
	return result


func _to_packed_peer_ids(peer_ids: Array[int]) -> PackedInt32Array:
	var result := PackedInt32Array()
	for peer_id in peer_ids:
		result.append(peer_id)
	return result


func _can_add_item(peer_id: int, item: PickupConfig) -> bool:
	return (
		_run_state.can_add_item_count(item, 1)
		if peer_id == 0
		else _run_state.can_add_item_count_for_peer(peer_id, item, 1)
	)


func _get_inventory_revision(peer_id: int) -> int:
	return (
		_run_state.get_inventory_revision()
		if peer_id == 0
		else _run_state.get_inventory_revision_for_peer(peer_id)
	)


func _try_add_item_if_revision(
	peer_id: int,
	item: PickupConfig,
	expected_revision: int
) -> bool:
	var items: Array[PickupConfig] = [item]
	var counts: Array[int] = [1]
	return (
		_run_state.try_add_item_counts_if_revision(
			items,
			counts,
			expected_revision
		)
		if peer_id == 0
		else _run_state.try_add_item_counts_for_peer_if_revision(
			peer_id,
			items,
			counts,
			expected_revision
		)
	)


func _make_result(
	resolved: bool,
	option_id: StringName,
	result_code: String
) -> Dictionary:
	return {
		"resolved": resolved,
		"option_id": String(option_id),
		"result_code": result_code,
		"result_text": "",
		"economy_revision": _economy_revision,
	}


func _export_settled_occurrences() -> Array[Dictionary]:
	var keys: Array[String] = []
	for raw_key in _settled_occurrences.keys():
		keys.append(str(raw_key))
	keys.sort()
	var result: Array[Dictionary] = []
	for occurrence_key in keys:
		result.append({
			"occurrence_key": occurrence_key,
			"result": (_settled_occurrences[occurrence_key] as Dictionary).duplicate(true),
		})
	return result


func _export_pending_collectible_offers() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for pending in _get_sorted_pending_collectible_entries():
		result.append({
			"peer_id": int(pending.get("peer_id", -1)),
			"occurrence_key": str(pending.get("occurrence_key", "")),
			"sequence": int(pending.get("sequence", 0)),
			"paths": (pending.get("paths", []) as Array).duplicate(),
		})
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


func _decode_pending_collectible_offers(entries: Array) -> Variant:
	var result: Dictionary = {}
	for raw_entry_value in entries:
		if typeof(raw_entry_value) != TYPE_DICTIONARY:
			return null
		var entry := raw_entry_value as Dictionary
		var peer_id := int(entry.get("peer_id", -1))
		var occurrence_key := str(entry.get("occurrence_key", ""))
		var sequence := int(entry.get("sequence", -1))
		var pending_key := _make_collectible_claim_key(
			occurrence_key,
			peer_id
		)
		if (
			peer_id < 0
			or occurrence_key.is_empty()
			or sequence <= 0
			or result.has(pending_key)
			or typeof(entry.get("paths")) != TYPE_ARRAY
		):
			return null
		var paths: Array[String] = []
		var seen_paths: Dictionary = {}
		for raw_path in entry["paths"] as Array:
			var config_path := str(raw_path)
			if (
				typeof(raw_path) != TYPE_STRING
				or config_path.is_empty()
				or seen_paths.has(config_path)
			):
				return null
			seen_paths[config_path] = true
			paths.append(config_path)
		if paths.size() != 3:
			return null
		result[pending_key] = {
			"peer_id": peer_id,
			"occurrence_key": occurrence_key,
			"sequence": sequence,
			"paths": paths,
		}
	return result


func _get_sorted_pending_collectible_entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_pending in _pending_collectible_offers.values():
		result.append((raw_pending as Dictionary).duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sequence_a := int(a.get("sequence", 0))
		var sequence_b := int(b.get("sequence", 0))
		if sequence_a != sequence_b:
			return sequence_a < sequence_b
		var occurrence_a := str(a.get("occurrence_key", ""))
		var occurrence_b := str(b.get("occurrence_key", ""))
		if occurrence_a != occurrence_b:
			return occurrence_a < occurrence_b
		return int(a.get("peer_id", -1)) < int(b.get("peer_id", -1))
	)
	return result


func _get_max_pending_collectible_sequence() -> int:
	var result := 0
	for raw_pending in _pending_collectible_offers.values():
		result = maxi(result, int((raw_pending as Dictionary).get("sequence", 0)))
	return result


func _make_collectible_claim_key(
	occurrence_key: String,
	peer_id: int
) -> String:
	return "%s|collectible:%d" % [occurrence_key, peer_id]
