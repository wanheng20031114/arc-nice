extends Node
class_name RogueRareChestSession

signal state_changed(snapshot: Dictionary)
signal rare_chest_started(snapshot: Dictionary)
signal rare_chest_finished(snapshot: Dictionary)
signal choice_committed(peer_id: int, result: Dictionary)

const SCHEMA_VERSION := 1
const PHASE_IDLE := &"idle"
const PHASE_CHOOSING := &"choosing"
const PHASE_WAITING := &"waiting"
const PHASE_COMPLETED := &"completed"

var _economy: RogueRareChestEconomyCoordinator
var _is_authority := false
var _revision := 0
var _phase: StringName = PHASE_IDLE
var _node_id := -1
var _node_content_seed := 0
var _occurrence_key := ""
var _participant_peer_ids: Array[int] = []
var _active_peer_ids: Array[int] = []
var _spectator_peer_ids: Array[int] = []
var _completed_peer_ids: Dictionary = {}
var _abandoned_peer_ids: Dictionary = {}
var _offers_by_peer: Dictionary = {}
var _offer_revisions_by_peer: Dictionary = {}
var _selected_options_by_peer: Dictionary = {}
var _result_texts_by_peer: Dictionary = {}
var _resolved_node_ids: Dictionary = {}


func reset_authority(economy: RogueRareChestEconomyCoordinator) -> void:
	_reset_runtime(economy)
	_is_authority = true


func reset_remote(economy: RogueRareChestEconomyCoordinator) -> void:
	_reset_runtime(economy)
	_is_authority = false


func _reset_runtime(economy: RogueRareChestEconomyCoordinator) -> void:
	_economy = economy
	_revision = 0
	_phase = PHASE_IDLE
	_node_id = -1
	_node_content_seed = 0
	_occurrence_key = ""
	_participant_peer_ids.clear()
	_active_peer_ids.clear()
	_spectator_peer_ids.clear()
	_completed_peer_ids.clear()
	_abandoned_peer_ids.clear()
	_offers_by_peer.clear()
	_offer_revisions_by_peer.clear()
	_selected_options_by_peer.clear()
	_result_texts_by_peer.clear()
	_resolved_node_ids.clear()


func start_for_node(
	node_id: int,
	node_content_seed: int,
	participant_peer_ids: Array[int],
	participant_stable_keys: Dictionary
) -> bool:
	if (
		not _is_authority
		or _economy == null
		or not _economy.is_configured()
		or is_active()
		or node_id < 0
		or is_node_resolved(node_id)
	):
		return false
	var participants := _normalize_peer_ids(participant_peer_ids)
	if participants.is_empty():
		return false
	var generated_offers: Dictionary = {}
	for peer_id in participants:
		var stable_key := str(
			participant_stable_keys.get(
				peer_id,
				participant_stable_keys.get(str(peer_id), "")
			)
		).strip_edges()
		if stable_key.is_empty():
			return false
		var valid_options := _economy.get_valid_option_ids(peer_id)
		var options := RogueRareChestRegistry.select_options(
			node_content_seed,
			stable_key,
			valid_options
		)
		if options.size() != RogueRareChestRegistry.CHOICE_COUNT:
			return false
		generated_offers[peer_id] = options

	_node_id = node_id
	_node_content_seed = node_content_seed
	_occurrence_key = "%d:%d:rare_chest" % [node_id, node_content_seed]
	_phase = PHASE_CHOOSING
	_participant_peer_ids = participants
	_active_peer_ids = participants.duplicate()
	_spectator_peer_ids.clear()
	_completed_peer_ids.clear()
	_abandoned_peer_ids.clear()
	_offers_by_peer = generated_offers
	_offer_revisions_by_peer.clear()
	_selected_options_by_peer.clear()
	_result_texts_by_peer.clear()
	for peer_id in participants:
		_offer_revisions_by_peer[peer_id] = 1
	_bump_and_emit()
	rare_chest_started.emit(export_state_for_peer())
	return true


func submit_choice(
	peer_id: int,
	occurrence_key: String,
	expected_offer_revision: int,
	option_id: StringName
) -> bool:
	if (
		not _is_authority
		or _phase != PHASE_CHOOSING
		or occurrence_key != _occurrence_key
		or not _active_peer_ids.has(peer_id)
		or _completed_peer_ids.has(peer_id)
		or not _offers_by_peer.has(peer_id)
		or int(_offer_revisions_by_peer.get(peer_id, 0))
		!= expected_offer_revision
	):
		return false
	var offered_options := _offers_by_peer[peer_id] as Array[StringName]
	if not offered_options.has(option_id):
		return false
	var result := _economy.resolve_choice(
		peer_id,
		_occurrence_key,
		option_id
	)
	if not bool(result.get("resolved", false)):
		return false
	_selected_options_by_peer[peer_id] = option_id
	_result_texts_by_peer[peer_id] = str(result.get("result_text", ""))
	_completed_peer_ids[peer_id] = true
	_offer_revisions_by_peer[peer_id] = expected_offer_revision + 1
	# Route-side healing is deliberately emitted after the permanent-ledger CAS,
	# but before the resulting rare-chest state is broadcast.
	choice_committed.emit(peer_id, result.duplicate(true))
	if _all_participants_completed():
		_complete_current_node()
	else:
		_bump_and_emit()
	return true


func remove_peer(peer_id: int) -> bool:
	if not _is_authority or peer_id < 0:
		return false
	var changed := false
	if _active_peer_ids.has(peer_id):
		_active_peer_ids.erase(peer_id)
		changed = true
	if _participant_peer_ids.has(peer_id) and not _completed_peer_ids.has(peer_id):
		_completed_peer_ids[peer_id] = true
		_abandoned_peer_ids[peer_id] = true
		_offers_by_peer.erase(peer_id)
		_offer_revisions_by_peer.erase(peer_id)
		changed = true
	if _spectator_peer_ids.has(peer_id):
		_spectator_peer_ids.erase(peer_id)
		changed = true
	if not changed:
		return false
	if _phase == PHASE_CHOOSING and _all_participants_completed():
		_complete_current_node()
	else:
		_bump_and_emit()
	return true


## A disconnected participant has already abandoned this occurrence. A new
## transport peer therefore rejoins as a spectator instead of inheriting the
## private offer that was issued to the old identity.
func migrate_peer(old_peer_id: int, new_peer_id: int) -> bool:
	if (
		not _is_authority
		or old_peer_id < 0
		or new_peer_id < 0
		or old_peer_id == new_peer_id
	):
		return false
	var changed := false
	if _active_peer_ids.has(old_peer_id):
		_active_peer_ids.erase(old_peer_id)
		changed = true
	if (
		_participant_peer_ids.has(old_peer_id)
		and not _completed_peer_ids.has(old_peer_id)
	):
		_completed_peer_ids[old_peer_id] = true
		_abandoned_peer_ids[old_peer_id] = true
		_offers_by_peer.erase(old_peer_id)
		_offer_revisions_by_peer.erase(old_peer_id)
		changed = true
	if _spectator_peer_ids.has(old_peer_id):
		_spectator_peer_ids.erase(old_peer_id)
		changed = true
	if _phase != PHASE_IDLE and not _participant_peer_ids.has(new_peer_id):
		if not _spectator_peer_ids.has(new_peer_id):
			_spectator_peer_ids.append(new_peer_id)
			_spectator_peer_ids.sort()
			changed = true
	if changed:
		if _phase == PHASE_CHOOSING and _all_participants_completed():
			_complete_current_node()
		else:
			_bump_and_emit()
	return changed


func add_spectator(peer_id: int) -> bool:
	if (
		not _is_authority
		or peer_id < 0
		or _participant_peer_ids.has(peer_id)
		or _spectator_peer_ids.has(peer_id)
	):
		return false
	_spectator_peer_ids.append(peer_id)
	_spectator_peer_ids.sort()
	_bump_and_emit()
	return true


func export_state_for_peer(target_peer_id: int = -1) -> Dictionary:
	var local_options: Array[String] = []
	if _offers_by_peer.has(target_peer_id):
		for option_id in _offers_by_peer[target_peer_id] as Array[StringName]:
			local_options.append(String(option_id))
	var local_selected := StringName(
		_selected_options_by_peer.get(target_peer_id, &"")
	)
	var personalized_phase := _get_personalized_phase(target_peer_id)
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _revision,
		"global_phase": String(_phase),
		"phase": String(personalized_phase),
		"node_id": _node_id,
		"node_content_seed": _node_content_seed,
		"occurrence_key": _occurrence_key,
		"target_peer_id": target_peer_id,
		"offer_revision": int(
			_offer_revisions_by_peer.get(target_peer_id, 0)
		),
		"local_option_ids": local_options,
		"local_option_availability": (
			_economy.get_option_availability(
				target_peer_id,
				_offers_by_peer[target_peer_id] as Array[StringName]
			)
			if _economy != null and _offers_by_peer.has(target_peer_id)
			else {}
		),
		"local_selected_option_id": String(local_selected),
		"local_result_text": str(
			_result_texts_by_peer.get(target_peer_id, "")
		),
		"participant_peer_ids": _participant_peer_ids.duplicate(),
		"active_peer_ids": _active_peer_ids.duplicate(),
		"spectator_peer_ids": _spectator_peer_ids.duplicate(),
		"completed_peer_ids": _dictionary_int_keys(_completed_peer_ids),
		"abandoned_peer_ids": _dictionary_int_keys(_abandoned_peer_ids),
		"resolved_node_ids": _dictionary_int_keys(_resolved_node_ids),
	}


func validate_remote_state(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if decoded.is_empty() or not validate_remote_state_structure(snapshot):
		return false
	var incoming_revision := int(decoded["revision"])
	if incoming_revision < _revision:
		return false
	return not (
		incoming_revision == _revision
		and _phase != PHASE_IDLE
		and export_state_for_peer(int(decoded["target_peer_id"])) != snapshot
	)


func validate_remote_state_structure(snapshot: Dictionary) -> bool:
	return not _decode_state(snapshot).is_empty()


func apply_remote_state(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if decoded.is_empty() or int(decoded["revision"]) < _revision:
		return false
	var target_peer_id := int(decoded["target_peer_id"])
	var was_active := is_active()
	var previous_phase := _phase
	_revision = int(decoded["revision"])
	_phase = StringName(decoded["global_phase"])
	_node_id = int(decoded["node_id"])
	_node_content_seed = int(decoded["node_content_seed"])
	_occurrence_key = str(decoded["occurrence_key"])
	_participant_peer_ids = decoded["participant_peer_ids"] as Array[int]
	_active_peer_ids = decoded["active_peer_ids"] as Array[int]
	_spectator_peer_ids = decoded["spectator_peer_ids"] as Array[int]
	_completed_peer_ids = decoded["completed_peer_ids"] as Dictionary
	_abandoned_peer_ids = decoded["abandoned_peer_ids"] as Dictionary
	_resolved_node_ids = decoded["resolved_node_ids"] as Dictionary
	_offers_by_peer.clear()
	_offer_revisions_by_peer.clear()
	_selected_options_by_peer.clear()
	_result_texts_by_peer.clear()
	if target_peer_id >= 0:
		var local_options := decoded["local_option_ids"] as Array[StringName]
		if not local_options.is_empty():
			_offers_by_peer[target_peer_id] = local_options
		_offer_revisions_by_peer[target_peer_id] = int(
			decoded["offer_revision"]
		)
		var selected := StringName(decoded["local_selected_option_id"])
		if not selected.is_empty():
			_selected_options_by_peer[target_peer_id] = selected
		_result_texts_by_peer[target_peer_id] = str(
			decoded["local_result_text"]
		)
	var applied := export_state_for_peer(target_peer_id)
	state_changed.emit(applied)
	if not was_active and is_active():
		rare_chest_started.emit(applied)
	if previous_phase != PHASE_COMPLETED and _phase == PHASE_COMPLETED:
		rare_chest_finished.emit(applied)
	return true


func is_active() -> bool:
	return _phase == PHASE_CHOOSING


func is_node_resolved(node_id: int) -> bool:
	return _resolved_node_ids.has(node_id)


func get_phase() -> StringName:
	return _phase


func get_occurrence_key() -> String:
	return _occurrence_key


func get_revision() -> int:
	return _revision


func get_participant_peer_ids() -> Array[int]:
	return _participant_peer_ids.duplicate()


func get_economy_peer_ids() -> Array[int]:
	# participant_peer_ids 是历史进度集合；断线放弃的旧 transport id 必须
	# 保留在其中供 UI 显示，但绝不能再交给 RunState 的创建型导出接口。
	var result := _active_peer_ids.duplicate()
	for peer_id in _spectator_peer_ids:
		if not result.has(peer_id):
			result.append(peer_id)
	result.sort()
	return result


func _complete_current_node() -> void:
	_resolved_node_ids[_node_id] = true
	_phase = PHASE_COMPLETED
	_bump_revision()
	var snapshot := export_state_for_peer()
	state_changed.emit(snapshot)
	rare_chest_finished.emit(snapshot)


func _all_participants_completed() -> bool:
	if _participant_peer_ids.is_empty():
		return false
	for peer_id in _participant_peer_ids:
		if not _completed_peer_ids.has(peer_id):
			return false
	return true


func _get_personalized_phase(target_peer_id: int) -> StringName:
	if _phase == PHASE_IDLE:
		return PHASE_IDLE
	if _phase == PHASE_COMPLETED:
		return PHASE_COMPLETED
	if (
		_active_peer_ids.has(target_peer_id)
		and _offers_by_peer.has(target_peer_id)
		and not _completed_peer_ids.has(target_peer_id)
	):
		return PHASE_CHOOSING
	return PHASE_WAITING


func _decode_state(snapshot: Dictionary) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
		or typeof(snapshot.get("global_phase")) != TYPE_STRING
		or StringName(snapshot["global_phase"]) not in [
			PHASE_IDLE,
			PHASE_CHOOSING,
			PHASE_COMPLETED,
		]
		or typeof(snapshot.get("phase")) != TYPE_STRING
		or StringName(snapshot["phase"]) not in [
			PHASE_IDLE,
			PHASE_CHOOSING,
			PHASE_WAITING,
			PHASE_COMPLETED,
		]
		or typeof(snapshot.get("local_option_ids")) != TYPE_ARRAY
		or typeof(snapshot.get("local_option_availability")) != TYPE_DICTIONARY
	):
		return {}
	var participants: Variant = _decode_int_array(
		snapshot.get("participant_peer_ids")
	)
	var active: Variant = _decode_int_array(snapshot.get("active_peer_ids"))
	var spectators: Variant = _decode_int_array(
		snapshot.get("spectator_peer_ids")
	)
	var completed: Variant = _decode_int_set(
		snapshot.get("completed_peer_ids")
	)
	var abandoned: Variant = _decode_int_set(
		snapshot.get("abandoned_peer_ids")
	)
	var resolved_nodes: Variant = _decode_int_set(
		snapshot.get("resolved_node_ids")
	)
	var local_options: Variant = _decode_option_ids(
		snapshot["local_option_ids"] as Array
	)
	if (
		participants == null
		or active == null
		or spectators == null
		or completed == null
		or abandoned == null
		or resolved_nodes == null
		or local_options == null
	):
		return {}
	var selected := StringName(snapshot.get("local_selected_option_id", &""))
	if not selected.is_empty() and not (local_options as Array[StringName]).has(selected):
		return {}
	return {
		"revision": int(snapshot["revision"]),
		"global_phase": str(snapshot["global_phase"]),
		"node_id": int(snapshot.get("node_id", -1)),
		"node_content_seed": int(snapshot.get("node_content_seed", 0)),
		"occurrence_key": str(snapshot.get("occurrence_key", "")),
		"target_peer_id": int(snapshot.get("target_peer_id", -1)),
		"offer_revision": int(snapshot.get("offer_revision", 0)),
		"local_option_ids": local_options,
		"local_selected_option_id": String(selected),
		"local_result_text": str(snapshot.get("local_result_text", "")),
		"participant_peer_ids": participants,
		"active_peer_ids": active,
		"spectator_peer_ids": spectators,
		"completed_peer_ids": completed,
		"abandoned_peer_ids": abandoned,
		"resolved_node_ids": resolved_nodes,
	}


func _decode_option_ids(values: Array) -> Variant:
	var result: Array[StringName] = []
	for raw_option_id in values:
		var option_id := StringName(raw_option_id)
		if not RogueRareChestRegistry.has_option(option_id) or result.has(option_id):
			return null
		result.append(option_id)
	if result.size() not in [0, RogueRareChestRegistry.CHOICE_COUNT]:
		return null
	return result


func _decode_int_array(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return null
	var result: Array[int] = []
	for raw_value in value as Array:
		if typeof(raw_value) != TYPE_INT:
			return null
		var int_value := int(raw_value)
		if int_value < 0 or result.has(int_value):
			return null
		result.append(int_value)
	result.sort()
	return result


func _decode_int_set(value: Variant) -> Variant:
	var values: Variant = _decode_int_array(value)
	if values == null:
		return null
	var result: Dictionary = {}
	for int_value in values as Array[int]:
		result[int_value] = true
	return result


func _dictionary_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for raw_key in source.keys():
		var key := int(raw_key)
		if key >= 0 and not result.has(key):
			result.append(key)
	result.sort()
	return result


func _normalize_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id >= 0 and not result.has(peer_id):
			result.append(peer_id)
	result.sort()
	return result


func _bump_revision() -> void:
	_revision += 1


func _bump_and_emit() -> void:
	_bump_revision()
	state_changed.emit(export_state_for_peer())
