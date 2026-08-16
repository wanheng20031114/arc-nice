extends Node
class_name RogueRareChestEconomyCoordinator

signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 1

var _run_state: RunStateStore
var _player_character_ids: Dictionary = {}
var _revision := 0
var _settled_choices: Dictionary = {}
var _snapshot_target_peer_id := -1


func reset_runtime(
	run_state: RunStateStore,
	player_character_ids: Dictionary = {}
) -> void:
	_run_state = run_state
	_player_character_ids = player_character_ids.duplicate(true)
	_revision = 0
	_settled_choices.clear()
	_snapshot_target_peer_id = -1
	if _run_state != null:
		_run_state.ensure_run_started()


func set_player_character_ids(player_character_ids: Dictionary) -> void:
	_player_character_ids = player_character_ids.duplicate(true)


func is_configured() -> bool:
	return _run_state != null


func get_valid_option_ids(peer_id: int) -> Array[StringName]:
	var result: Array[StringName] = []
	for option_id in RogueRareChestRegistry.get_all_option_ids():
		if _is_option_available(peer_id, option_id):
			result.append(option_id)
	return result


func get_option_availability(
	peer_id: int,
	option_ids: Array[StringName]
) -> Dictionary:
	var result: Dictionary = {}
	for option_id in option_ids:
		var available := _is_option_available(peer_id, option_id)
		result[String(option_id)] = {
			"available": available,
			"disabled_reason": "" if available else _get_unavailable_reason(
				peer_id,
				option_id
			),
		}
	return result


func resolve_choice(
	peer_id: int,
	occurrence_key: String,
	option_id: StringName
) -> Dictionary:
	var settlement_key := _make_settlement_key(occurrence_key, peer_id)
	if _settled_choices.has(settlement_key):
		var replayed := (
			_settled_choices[settlement_key] as Dictionary
		).duplicate(true)
		replayed["replayed"] = true
		return replayed
	if (
		_run_state == null
		or peer_id < 0
		or occurrence_key.is_empty()
		or not RogueRareChestRegistry.has_option(option_id)
		or not _is_option_available(peer_id, option_id)
	):
		return _make_result(false, peer_id, option_id, "invalid_option")
	var stat_id := RogueRareChestRegistry.get_stat_id(option_id)
	var stat_delta := RogueRareChestRegistry.get_stat_delta(option_id)
	var next_status := (
		_run_state.build_party_status_ledger_with_player_stat_bonus(
			peer_id,
			stat_id,
			stat_delta
		)
	)
	if next_status.is_empty():
		return _make_result(false, peer_id, option_id, "stale_or_capped")
	var party_snapshot := _run_state.export_party_economy_snapshot(
		PackedInt32Array([peer_id])
	)
	if party_snapshot.is_empty() or not _commit_status_snapshot(
		party_snapshot,
		next_status
	):
		return _make_result(false, peer_id, option_id, "stale_state")

	_revision += 1
	var result := _make_result(true, peer_id, option_id, "bonus_granted")
	result["occurrence_key"] = occurrence_key
	result["stat_id"] = stat_id
	result["stat_delta"] = stat_delta
	result["heal_delta"] = 10 if option_id == (
		RogueRareChestRegistry.OPTION_MAX_HEALTH
	) else 0
	result["result_text"] = _get_result_text(option_id)
	result["economy_revision"] = _revision
	_settled_choices[settlement_key] = result.duplicate(true)
	economy_changed.emit(export_snapshot(peer_id))
	return result


func has_settled_choice(occurrence_key: String, peer_id: int) -> bool:
	return _settled_choices.has(_make_settlement_key(
		occurrence_key,
		peer_id
	))


func get_settled_result(occurrence_key: String, peer_id: int) -> Dictionary:
	var raw_result: Variant = _settled_choices.get(
		_make_settlement_key(occurrence_key, peer_id)
	)
	return (
		(raw_result as Dictionary).duplicate(true)
		if typeof(raw_result) == TYPE_DICTIONARY
		else {}
	)


## `target_peer_id` controls private settlement visibility. The permanent
## party-status ledger itself continues to travel through the route's shared
## party-economy snapshot; this coordinator only serializes rare-chest logs.
func export_snapshot(target_peer_id: int = -1) -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _revision,
		"target_peer_id": target_peer_id,
		"settled_choices": _export_settled_choices(target_peer_id),
	}


func validate_remote_snapshot(snapshot: Dictionary) -> bool:
	if not validate_remote_snapshot_structure(snapshot):
		return false
	var target_peer_id := int(snapshot["target_peer_id"])
	var decoded: Variant = _decode_settled_choices(
		snapshot["settled_choices"] as Array,
		target_peer_id
	)
	return not (
		int(snapshot["revision"]) < _revision
		or (
			int(snapshot["revision"]) == _revision
			and target_peer_id == _snapshot_target_peer_id
			and (decoded as Dictionary) != _settled_choices
		)
	)


func validate_remote_snapshot_structure(snapshot: Dictionary) -> bool:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
		or typeof(snapshot.get("target_peer_id")) != TYPE_INT
		or int(snapshot["target_peer_id"]) < -1
		or typeof(snapshot.get("settled_choices")) != TYPE_ARRAY
	):
		return false
	var target_peer_id := int(snapshot["target_peer_id"])
	var decoded: Variant = _decode_settled_choices(
		snapshot["settled_choices"] as Array,
		target_peer_id
	)
	if decoded == null:
		return false
	return true


func apply_remote_snapshot(snapshot: Dictionary) -> bool:
	var prepared := prepare_remote_snapshot(snapshot)
	if not can_commit_prepared_remote_snapshot(prepared):
		return false
	commit_validated_remote_snapshot(prepared)
	return true


func prepare_remote_snapshot(
	snapshot: Dictionary,
	structure_only: bool = false
) -> Dictionary:
	if not (
		validate_remote_snapshot_structure(snapshot)
		if structure_only
		else validate_remote_snapshot(snapshot)
	):
		return {}
	var target_peer_id := int(snapshot["target_peer_id"])
	var decoded: Variant = _decode_settled_choices(
		snapshot["settled_choices"] as Array,
		target_peer_id
	)
	if decoded == null:
		return {}
	return {
		"expected_revision": _revision,
		"expected_target_peer_id": _snapshot_target_peer_id,
		"expected_settled_choices": _settled_choices.duplicate(true),
		"revision": int(snapshot["revision"]),
		"target_peer_id": target_peer_id,
		"settled_choices": (decoded as Dictionary).duplicate(true),
	}


func can_commit_prepared_remote_snapshot(prepared: Dictionary) -> bool:
	return (
		prepared.size() == 6
		and int(prepared.get("expected_revision", -1)) == _revision
		and int(prepared.get("expected_target_peer_id", -2))
		== _snapshot_target_peer_id
		and typeof(prepared.get("expected_settled_choices"))
		== TYPE_DICTIONARY
		and prepared["expected_settled_choices"] == _settled_choices
		and typeof(prepared.get("revision")) == TYPE_INT
		and typeof(prepared.get("target_peer_id")) == TYPE_INT
		and typeof(prepared.get("settled_choices")) == TYPE_DICTIONARY
	)


func commit_validated_remote_snapshot(
	prepared: Dictionary,
	emit_change_signal: bool = true
) -> void:
	var target_peer_id := int(prepared["target_peer_id"])
	var decoded := prepared["settled_choices"] as Dictionary
	var changed: bool = (
		int(prepared["revision"]) != _revision
		or target_peer_id != _snapshot_target_peer_id
		or decoded != _settled_choices
	)
	_revision = int(prepared["revision"])
	_snapshot_target_peer_id = target_peer_id
	_settled_choices = decoded.duplicate(true)
	if changed and emit_change_signal:
		economy_changed.emit(export_snapshot(target_peer_id))


func publish_prepared_remote_snapshot(prepared: Dictionary) -> void:
	var changed: bool = (
		int(prepared.get("revision", _revision))
		!= int(prepared.get("expected_revision", _revision))
		or int(prepared.get("target_peer_id", _snapshot_target_peer_id))
		!= int(prepared.get(
			"expected_target_peer_id",
			_snapshot_target_peer_id
		))
		or prepared.get("settled_choices", {})
		!= prepared.get("expected_settled_choices", {})
	)
	if changed:
		economy_changed.emit(export_snapshot(_snapshot_target_peer_id))


func _is_option_available(peer_id: int, option_id: StringName) -> bool:
	if (
		_run_state == null
		or peer_id < 0
		or not RogueRareChestRegistry.has_option(option_id)
	):
		return false
	if option_id == RogueRareChestRegistry.OPTION_AMMO_CAPACITY:
		var character_id := StringName(
			_player_character_ids.get(
				peer_id,
				PlayerCharacterRegistry.get_default_character_id()
			)
		)
		if not PlayerCharacterRegistry.supports_ammunition_reward(character_id):
			return false
	return not _run_state.build_party_status_ledger_with_player_stat_bonus(
		peer_id,
		RogueRareChestRegistry.get_stat_id(option_id),
		RogueRareChestRegistry.get_stat_delta(option_id)
	).is_empty()


func _get_unavailable_reason(peer_id: int, option_id: StringName) -> String:
	if not RogueRareChestRegistry.has_option(option_id):
		return "无效选项"
	if option_id == RogueRareChestRegistry.OPTION_AMMO_CAPACITY:
		var character_id := StringName(
			_player_character_ids.get(
				peer_id,
				PlayerCharacterRegistry.get_default_character_id()
			)
		)
		if not PlayerCharacterRegistry.supports_ammunition_reward(character_id):
			return "当前角色没有弹夹容量"
	return "已达到永久强化上限"


func _commit_status_snapshot(
	party_snapshot: Dictionary,
	next_status: Dictionary
) -> bool:
	var expected_inventory_revisions: Dictionary = {}
	for raw_inventory_value in party_snapshot.get("inventories", []) as Array:
		var inventory := raw_inventory_value as Dictionary
		expected_inventory_revisions[int(inventory.get("peer_id", -1))] = int(
			inventory.get("revision", -1)
		)
	return _run_state.apply_authoritative_party_transaction(
		party_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		-1,
		{},
		int((party_snapshot["party_status_ledger"] as Dictionary)["revision"]),
		next_status
	)


func _get_result_text(option_id: StringName) -> String:
	match option_id:
		RogueRareChestRegistry.OPTION_MAX_HEALTH:
			return "最大生命值永久提高了10点，并回复了10点生命值。"
		RogueRareChestRegistry.OPTION_PHYSICAL_DEFENSE:
			return "物理防御永久提高了2点。"
		RogueRareChestRegistry.OPTION_MAGIC_DEFENSE:
			return "法术防御永久提高了1点。"
		RogueRareChestRegistry.OPTION_MOVE_SPEED:
			return "移动速度永久提高了5点。"
		RogueRareChestRegistry.OPTION_AMMO_CAPACITY:
			return "弹夹容量永久提高了1点。"
		RogueRareChestRegistry.OPTION_ATTACK_DAMAGE:
			return "攻击力永久提高了2点。"
		RogueRareChestRegistry.OPTION_DODGE_PERCENT_POINTS:
			return "闪避率永久提高了1%。"
	return ""


func _make_result(
	resolved: bool,
	peer_id: int,
	option_id: StringName,
	result_code: String
) -> Dictionary:
	return {
		"resolved": resolved,
		"peer_id": peer_id,
		"option_id": option_id,
		"result_code": result_code,
	}


func _export_settled_choices(target_peer_id: int) -> Array[Dictionary]:
	if target_peer_id < 0:
		return []
	var keys := _settled_choices.keys()
	keys.sort()
	var result: Array[Dictionary] = []
	for raw_key in keys:
		var settlement := _settled_choices[raw_key] as Dictionary
		if int(settlement.get("peer_id", -1)) != target_peer_id:
			continue
		result.append({
			"settlement_key": str(raw_key),
			"result": settlement.duplicate(true),
		})
	return result


func _decode_settled_choices(
	entries: Array,
	target_peer_id: int
) -> Variant:
	var result: Dictionary = {}
	for raw_entry_value in entries:
		if typeof(raw_entry_value) != TYPE_DICTIONARY:
			return null
		var entry := raw_entry_value as Dictionary
		if (
			typeof(entry.get("settlement_key")) != TYPE_STRING
			or typeof(entry.get("result")) != TYPE_DICTIONARY
		):
			return null
		var settlement_key := str(entry["settlement_key"])
		var settlement := entry["result"] as Dictionary
		var occurrence_key := str(settlement.get("occurrence_key", ""))
		var peer_id := int(settlement.get("peer_id", -1))
		var option_id := StringName(settlement.get("option_id", &""))
		var expected_stat_id := RogueRareChestRegistry.get_stat_id(option_id)
		var expected_stat_delta := RogueRareChestRegistry.get_stat_delta(option_id)
		if (
			settlement_key.is_empty()
			or result.has(settlement_key)
			or peer_id < 0
			or peer_id != target_peer_id
			or occurrence_key.is_empty()
			or settlement_key != _make_settlement_key(
				occurrence_key,
				peer_id
			)
			or not bool(settlement.get("resolved", false))
			or not RogueRareChestRegistry.has_option(option_id)
			or StringName(settlement.get("stat_id", &"")) != expected_stat_id
			or int(settlement.get("stat_delta", 0)) != expected_stat_delta
			or int(settlement.get("heal_delta", 0))
			!= (
				10
				if option_id == RogueRareChestRegistry.OPTION_MAX_HEALTH
				else 0
			)
			or StringName(settlement.get("result_code", &""))
			!= &"bonus_granted"
		):
			return null
		result[settlement_key] = settlement.duplicate(true)
	return result


func _make_settlement_key(occurrence_key: String, peer_id: int) -> String:
	return "%s|peer:%d" % [occurrence_key, peer_id]
