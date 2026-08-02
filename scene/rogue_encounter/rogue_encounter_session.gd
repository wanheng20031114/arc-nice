extends Node
class_name RogueEncounterSession

signal state_changed(snapshot: Dictionary)
signal encounter_started(snapshot: Dictionary)
signal encounter_finished(snapshot: Dictionary)
signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 1
const VOTING_TIMEOUT_SECONDS := 60.0

const PHASE_IDLE := &"idle"
const PHASE_INTRO := &"intro"
const PHASE_VOTING := &"voting"
const PHASE_RESOLVING := &"resolving"
const PHASE_RESULT := &"result"
const PHASE_COMPLETED := &"completed"

const _VALID_PHASES := [
	PHASE_IDLE,
	PHASE_INTRO,
	PHASE_VOTING,
	PHASE_RESOLVING,
	PHASE_RESULT,
	PHASE_COMPLETED,
]

var _economy: RogueEncounterEconomyCoordinator
var _is_authority := false
var _revision := 0
var _phase: StringName = PHASE_IDLE
var _node_id := -1
var _content_pool_id: StringName = &""
var _node_content_seed := 0
var _occurrence_key := ""
var _encounter_id: StringName = &""
var _remaining_seconds := 0.0
var _voting_timer_running := false
var _last_broadcast_remaining_second := -1
var _authority_peer_ids: Array[int] = []
var _participant_peer_ids: Array[int] = []
var _active_peer_ids: Array[int] = []
var _spectator_peer_ids: Array[int] = []
var _disconnected_peer_ids: Array[int] = []
var _intro_confirmed: Dictionary = {}
var _votes: Dictionary = {}
var _abstained: Dictionary = {}
var _option_availability: Dictionary = {}
var _winning_option: StringName = &""
var _economy_result: Dictionary = {}
var _economy_snapshot: Dictionary = {}
var _resolved_node_ids: Dictionary = {}
var _settlement_committed := false


func initialize_authority(
	economy: RogueEncounterEconomyCoordinator,
	peer_ids: Array[int]
) -> void:
	reset_authority(economy, peer_ids)


func initialize_remote(economy: RogueEncounterEconomyCoordinator) -> void:
	reset_remote(economy)


func reset_authority(
	economy: RogueEncounterEconomyCoordinator,
	peer_ids: Array[int]
) -> void:
	_reset_runtime_state(economy)
	_is_authority = true
	_authority_peer_ids = _normalize_peer_ids(peer_ids)


func reset_remote(economy: RogueEncounterEconomyCoordinator) -> void:
	_reset_runtime_state(economy)
	_is_authority = false


func _reset_runtime_state(economy: RogueEncounterEconomyCoordinator) -> void:
	if (
		_economy != null
		and _economy.economy_changed.is_connected(_on_economy_changed)
	):
		_economy.economy_changed.disconnect(_on_economy_changed)
	_economy = economy
	_revision = 0
	_phase = PHASE_IDLE
	_node_id = -1
	_content_pool_id = &""
	_node_content_seed = 0
	_occurrence_key = ""
	_encounter_id = &""
	_remaining_seconds = 0.0
	_voting_timer_running = false
	_last_broadcast_remaining_second = -1
	_authority_peer_ids.clear()
	_participant_peer_ids.clear()
	_active_peer_ids.clear()
	_spectator_peer_ids.clear()
	_disconnected_peer_ids.clear()
	_intro_confirmed.clear()
	_votes.clear()
	_abstained.clear()
	_option_availability.clear()
	_winning_option = &""
	_economy_result.clear()
	_economy_snapshot.clear()
	_resolved_node_ids.clear()
	_settlement_committed = false
	if _economy != null and not _economy.economy_changed.is_connected(
		_on_economy_changed
	):
		_economy.economy_changed.connect(_on_economy_changed)


func start_for_node(
	node_id: int,
	content_pool_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int]
) -> bool:
	if (
		not _is_authority
		or _economy == null
		or is_active()
		or node_id < 0
		or is_node_resolved(node_id)
	):
		return false
	var encounter_id := RogueEncounterRegistry.select_encounter(
		content_pool_id,
		node_content_seed
	)
	if encounter_id.is_empty():
		return false
	var participants := _normalize_peer_ids(
		eligible_peer_ids if not eligible_peer_ids.is_empty() else _authority_peer_ids
	)
	if participants.is_empty():
		return false

	_node_id = node_id
	_content_pool_id = content_pool_id
	_node_content_seed = node_content_seed
	_occurrence_key = "%d:%d" % [node_id, node_content_seed]
	_encounter_id = encounter_id
	_phase = PHASE_INTRO
	_remaining_seconds = VOTING_TIMEOUT_SECONDS
	_voting_timer_running = false
	_last_broadcast_remaining_second = ceili(VOTING_TIMEOUT_SECONDS)
	_participant_peer_ids = participants.duplicate()
	_active_peer_ids = participants.duplicate()
	_spectator_peer_ids.clear()
	_disconnected_peer_ids.clear()
	_intro_confirmed.clear()
	_votes.clear()
	_abstained.clear()
	_winning_option = &""
	_economy_result.clear()
	_settlement_committed = false
	_option_availability.clear()
	_refresh_option_availability()
	_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	_bump_revision()
	var snapshot := export_state()
	state_changed.emit(snapshot)
	encounter_started.emit(snapshot)
	return true


## 由全屏 reveal 动画完成回调触发；start_for_node 本身不会偷跑 60 秒。
func start_voting_timer(
	occurrence_key: String,
	expected_revision: int
) -> bool:
	if (
		not _is_authority
		or occurrence_key != _occurrence_key
		or expected_revision != _revision
		or _phase not in [PHASE_INTRO, PHASE_VOTING]
		or _voting_timer_running
	):
		return false
	_voting_timer_running = true
	_last_broadcast_remaining_second = ceili(_remaining_seconds)
	_bump_and_emit()
	return true


func submit_intro_ack(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int
) -> bool:
	if (
		not _can_accept_request(peer_id, occurrence_key, expected_revision)
		or _phase not in [PHASE_INTRO, PHASE_VOTING]
		or _intro_confirmed.has(peer_id)
	):
		return false
	_intro_confirmed[peer_id] = true
	if _phase == PHASE_INTRO:
		_phase = PHASE_VOTING
	_bump_and_emit()
	return true


func submit_vote(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> bool:
	if (
		not _can_accept_request(peer_id, occurrence_key, expected_revision)
		or _phase != PHASE_VOTING
		or not _intro_confirmed.has(peer_id)
		or not _is_option_available(option_id)
		or StringName(_votes.get(peer_id, &"")) == option_id
	):
		return false
	_votes[peer_id] = option_id
	_abstained.erase(peer_id)
	_bump_and_emit()
	_maybe_resolve_early()
	return true


func tick(delta: float) -> void:
	if (
		not _is_authority
		or not _voting_timer_running
		or _phase not in [PHASE_INTRO, PHASE_VOTING]
	):
		return
	_remaining_seconds = maxf(_remaining_seconds - maxf(delta, 0.0), 0.0)
	if _remaining_seconds <= 0.0:
		for peer_id in _active_peer_ids:
			if not _votes.has(peer_id):
				_abstained[peer_id] = true
		_begin_resolution()
		return
	var visible_second := ceili(_remaining_seconds)
	if visible_second != _last_broadcast_remaining_second:
		_last_broadcast_remaining_second = visible_second
		# 仅同步展示时钟，不推进逻辑 revision，避免每秒令在途投票失效。
		state_changed.emit(export_state())
	_maybe_resolve_early()


func remove_peer(peer_id: int) -> bool:
	if not _is_authority or not _participant_peer_ids.has(peer_id):
		return false
	var changed: bool = _active_peer_ids.has(peer_id)
	_active_peer_ids.erase(peer_id)
	if not _disconnected_peer_ids.has(peer_id):
		_disconnected_peer_ids.append(peer_id)
		_disconnected_peer_ids.sort()
		changed = true
	if not changed:
		return false
	_refresh_option_availability()
	_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	_bump_and_emit()
	_maybe_resolve_early()
	return true


func migrate_peer(old_peer_id: int, new_peer_id: int) -> bool:
	var migrates_participant := _participant_peer_ids.has(old_peer_id)
	var migrates_spectator := _spectator_peer_ids.has(old_peer_id)
	if (
		not _is_authority
		or old_peer_id < 0
		or new_peer_id < 0
		or old_peer_id == new_peer_id
		or not (migrates_participant or migrates_spectator)
		or _participant_peer_ids.has(new_peer_id)
		or _spectator_peer_ids.has(new_peer_id)
	):
		return false
	if migrates_spectator:
		_replace_peer_id(_spectator_peer_ids, old_peer_id, new_peer_id)
		_bump_and_emit()
		return true
	_replace_peer_id(_participant_peer_ids, old_peer_id, new_peer_id)
	if _active_peer_ids.has(old_peer_id):
		_replace_peer_id(_active_peer_ids, old_peer_id, new_peer_id)
	elif _phase in [PHASE_INTRO, PHASE_VOTING]:
		_active_peer_ids.append(new_peer_id)
		_active_peer_ids.sort()
	_disconnected_peer_ids.erase(old_peer_id)
	if _intro_confirmed.has(old_peer_id):
		_intro_confirmed[new_peer_id] = _intro_confirmed[old_peer_id]
		_intro_confirmed.erase(old_peer_id)
	if _votes.has(old_peer_id):
		_votes[new_peer_id] = _votes[old_peer_id]
		_votes.erase(old_peer_id)
	if _abstained.has(old_peer_id):
		_abstained[new_peer_id] = _abstained[old_peer_id]
		_abstained.erase(old_peer_id)
	if _economy != null:
		_economy_result = _economy.migrate_result_peer_references(
			_economy_result,
			old_peer_id,
			new_peer_id
		)
		_economy.migrate_peer_references(old_peer_id, new_peer_id)
	# 外层会先迁移 RunState 背包；随后按新参与者集合重导账本，避免重连
	# 全量快照继续携带 old peer 的库存。
	if _economy != null:
		_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	_refresh_option_availability()
	_bump_and_emit()
	_maybe_resolve_early()
	return true


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


func complete_result(occurrence_key: String, expected_revision: int) -> bool:
	if (
		not _is_authority
		or occurrence_key != _occurrence_key
		or expected_revision != _revision
		or _phase != PHASE_RESULT
	):
		return false
	_phase = PHASE_COMPLETED
	_remaining_seconds = 0.0
	_voting_timer_running = false
	_last_broadcast_remaining_second = 0
	_bump_revision()
	var snapshot := export_state()
	state_changed.emit(snapshot)
	encounter_finished.emit(snapshot)
	return true


func export_state() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _revision,
		"phase": String(_phase),
		"node_id": _node_id,
		"content_pool_id": String(_content_pool_id),
		"node_content_seed": _node_content_seed,
		"occurrence_key": _occurrence_key,
		"encounter_id": String(_encounter_id),
		"remaining_seconds": _remaining_seconds,
		"voting_timer_running": _voting_timer_running,
		"participant_peer_ids": _participant_peer_ids.duplicate(),
		"active_peer_ids": _active_peer_ids.duplicate(),
		"spectator_peer_ids": _spectator_peer_ids.duplicate(),
		"disconnected_peer_ids": _disconnected_peer_ids.duplicate(),
		"intro_confirmed_peer_ids": _dictionary_int_keys(_intro_confirmed),
		"votes": _export_votes(),
		"abstained_peer_ids": _dictionary_int_keys(_abstained),
		"option_availability": _option_availability.duplicate(true),
		"winning_option": String(_winning_option),
		"economy_result": _economy_result.duplicate(true),
		"result_text": _get_result_text(),
		"economy_snapshot": _economy_snapshot.duplicate(true),
		"resolved_node_ids": _dictionary_int_keys(_resolved_node_ids),
		"settlement_committed": _settlement_committed,
	}


func apply_remote_state(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if decoded.is_empty():
		return false
	var incoming_revision := int(decoded["revision"])
	if incoming_revision < _revision:
		return false
	if (
		incoming_revision == _revision
		and not _occurrence_key.is_empty()
		and str(decoded["occurrence_key"]) != _occurrence_key
	):
		return false
	var previous_active := is_active()
	var previous_phase := _phase
	var incoming_economy := decoded["economy_snapshot"] as Dictionary
	if (
		_economy != null
		and not incoming_economy.is_empty()
		and not _economy.apply_remote_snapshot(incoming_economy)
	):
		return false
	_revision = incoming_revision
	_phase = StringName(decoded["phase"])
	_node_id = int(decoded["node_id"])
	_content_pool_id = StringName(decoded["content_pool_id"])
	_node_content_seed = int(decoded["node_content_seed"])
	_occurrence_key = str(decoded["occurrence_key"])
	_encounter_id = StringName(decoded["encounter_id"])
	_remaining_seconds = float(decoded["remaining_seconds"])
	_voting_timer_running = bool(decoded["voting_timer_running"])
	_last_broadcast_remaining_second = ceili(_remaining_seconds)
	_participant_peer_ids = decoded["participant_peer_ids"] as Array[int]
	_active_peer_ids = decoded["active_peer_ids"] as Array[int]
	_spectator_peer_ids = decoded["spectator_peer_ids"] as Array[int]
	_disconnected_peer_ids = decoded["disconnected_peer_ids"] as Array[int]
	_intro_confirmed = decoded["intro_confirmed"] as Dictionary
	_votes = decoded["votes"] as Dictionary
	_abstained = decoded["abstained"] as Dictionary
	_option_availability = decoded["option_availability"] as Dictionary
	_winning_option = StringName(decoded["winning_option"])
	_economy_result = decoded["economy_result"] as Dictionary
	_economy_snapshot = incoming_economy
	_resolved_node_ids = decoded["resolved_node_ids"] as Dictionary
	_settlement_committed = bool(decoded["settlement_committed"])
	var applied_snapshot := export_state()
	state_changed.emit(applied_snapshot)
	if not previous_active and is_active():
		encounter_started.emit(applied_snapshot)
	if previous_phase != PHASE_COMPLETED and _phase == PHASE_COMPLETED:
		encounter_finished.emit(applied_snapshot)
	return true


func is_active() -> bool:
	return _phase in [
		PHASE_INTRO,
		PHASE_VOTING,
		PHASE_RESOLVING,
		PHASE_RESULT,
	]


func is_node_resolved(node_id: int) -> bool:
	return _resolved_node_ids.has(node_id)


func get_phase() -> StringName:
	return _phase


func get_occurrence_key() -> String:
	return _occurrence_key


func get_revision() -> int:
	return _revision


func _can_accept_request(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int
) -> bool:
	return (
		_is_authority
		and peer_id >= 0
		and _active_peer_ids.has(peer_id)
		and not _spectator_peer_ids.has(peer_id)
		and occurrence_key == _occurrence_key
		and expected_revision == _revision
	)


func _is_option_available(option_id: StringName) -> bool:
	return bool(_option_availability.get(String(option_id), false))


func _refresh_option_availability() -> bool:
	if (
		not _is_authority
		or _economy == null
		or _phase not in [PHASE_INTRO, PHASE_VOTING]
	):
		return false
	var next_availability := {
		String(RogueEncounterEconomyCoordinator.OPTION_PURCHASE): (
			not _active_peer_ids.is_empty()
			and _economy.can_afford_purchase(_active_peer_ids)
		),
		String(RogueEncounterEconomyCoordinator.OPTION_FREE): true,
	}
	if next_availability == _option_availability:
		return false
	_option_availability = next_availability
	return true


func _maybe_resolve_early() -> void:
	if _phase not in [PHASE_INTRO, PHASE_VOTING] or _active_peer_ids.is_empty():
		return
	for peer_id in _active_peer_ids:
		if not _votes.has(peer_id):
			return
	_begin_resolution()


func _begin_resolution() -> void:
	if _phase not in [PHASE_INTRO, PHASE_VOTING]:
		return
	_winning_option = _select_winning_option()
	if _winning_option.is_empty():
		return
	_phase = PHASE_RESOLVING
	_remaining_seconds = 0.0
	_voting_timer_running = false
	_last_broadcast_remaining_second = 0
	_bump_and_emit()
	var result := _economy.resolve_chicken_bro(
		_winning_option,
		_node_content_seed,
		_active_peer_ids,
		_occurrence_key
	)
	if not bool(result.get("resolved", false)):
		_phase = PHASE_VOTING
		_remaining_seconds = 0.0
		_voting_timer_running = true
		_bump_and_emit()
		return
	_economy_result = result.duplicate(true)
	_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	_settlement_committed = true
	_resolved_node_ids[_node_id] = true
	_phase = PHASE_RESULT
	_bump_and_emit()


func _select_winning_option() -> StringName:
	var available_options: Array[StringName] = []
	for option_id in [
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		RogueEncounterEconomyCoordinator.OPTION_FREE,
	]:
		if _is_option_available(option_id):
			available_options.append(option_id)
	if available_options.is_empty():
		return &""
	var tallies: Dictionary = {}
	for peer_id in _active_peer_ids:
		if not _votes.has(peer_id):
			continue
		var option_id := StringName(_votes[peer_id])
		if not available_options.has(option_id):
			continue
		tallies[option_id] = int(tallies.get(option_id, 0)) + 1
	if tallies.is_empty():
		return available_options[
			RogueEncounterRandom.choose_index(
				_node_content_seed,
				&"no_vote",
				available_options.size()
			)
		]
	var highest_count := 0
	var tied_options: Array[StringName] = []
	for option_id in available_options:
		var vote_count := int(tallies.get(option_id, 0))
		if vote_count < highest_count:
			continue
		if vote_count > highest_count:
			highest_count = vote_count
			tied_options.clear()
		tied_options.append(option_id)
	if tied_options.size() == 1:
		return tied_options[0]
	return tied_options[
		RogueEncounterRandom.choose_index(
			_node_content_seed,
			&"tie_break",
			tied_options.size()
		)
	]


func _decode_state(snapshot: Dictionary) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
		or typeof(snapshot.get("phase")) != TYPE_STRING
		or StringName(snapshot["phase"]) not in _VALID_PHASES
		or typeof(snapshot.get("node_id")) != TYPE_INT
		or typeof(snapshot.get("node_content_seed")) != TYPE_INT
		or typeof(snapshot.get("remaining_seconds")) not in [TYPE_FLOAT, TYPE_INT]
		or float(snapshot["remaining_seconds"]) < 0.0
		or typeof(snapshot.get("voting_timer_running")) != TYPE_BOOL
	):
		return {}
	var participant_peer_ids: Variant = _decode_peer_id_array(
		snapshot.get("participant_peer_ids")
	)
	var active_peer_ids: Variant = _decode_peer_id_array(snapshot.get("active_peer_ids"))
	var spectator_peer_ids: Variant = _decode_peer_id_array(snapshot.get("spectator_peer_ids"))
	var disconnected_peer_ids: Variant = _decode_peer_id_array(
		snapshot.get("disconnected_peer_ids")
	)
	var intro_confirmed_ids: Variant = _decode_peer_id_array(
		snapshot.get("intro_confirmed_peer_ids")
	)
	var abstained_ids: Variant = _decode_peer_id_array(snapshot.get("abstained_peer_ids"))
	var resolved_node_ids: Variant = _decode_nonnegative_int_array(
		snapshot.get("resolved_node_ids")
	)
	if (
		participant_peer_ids == null
		or active_peer_ids == null
		or spectator_peer_ids == null
		or disconnected_peer_ids == null
		or intro_confirmed_ids == null
		or abstained_ids == null
		or resolved_node_ids == null
	):
		return {}
	for peer_id in active_peer_ids as Array[int]:
		if not (participant_peer_ids as Array[int]).has(peer_id):
			return {}
	var decoded_votes: Variant = _decode_votes(
		snapshot.get("votes"),
		participant_peer_ids as Array[int]
	)
	if decoded_votes == null:
		return {}
	if (
		typeof(snapshot.get("option_availability")) != TYPE_DICTIONARY
		or typeof(snapshot.get("economy_result")) != TYPE_DICTIONARY
		or typeof(snapshot.get("economy_snapshot")) != TYPE_DICTIONARY
		or typeof(snapshot.get("settlement_committed")) != TYPE_BOOL
	):
		return {}
	return {
		"revision": int(snapshot["revision"]),
		"phase": str(snapshot["phase"]),
		"node_id": int(snapshot["node_id"]),
		"content_pool_id": str(snapshot.get("content_pool_id", "")),
		"node_content_seed": int(snapshot["node_content_seed"]),
		"occurrence_key": str(snapshot.get("occurrence_key", "")),
		"encounter_id": str(snapshot.get("encounter_id", "")),
		"remaining_seconds": float(snapshot["remaining_seconds"]),
		"voting_timer_running": bool(snapshot["voting_timer_running"]),
		"participant_peer_ids": participant_peer_ids,
		"active_peer_ids": active_peer_ids,
		"spectator_peer_ids": spectator_peer_ids,
		"disconnected_peer_ids": disconnected_peer_ids,
		"intro_confirmed": _int_array_to_dictionary(
			intro_confirmed_ids as Array[int]
		),
		"votes": decoded_votes,
		"abstained": _int_array_to_dictionary(abstained_ids as Array[int]),
		"option_availability": (
			snapshot["option_availability"] as Dictionary
		).duplicate(true),
		"winning_option": str(snapshot.get("winning_option", "")),
		"economy_result": (
			snapshot["economy_result"] as Dictionary
		).duplicate(true),
		"economy_snapshot": (
			snapshot["economy_snapshot"] as Dictionary
		).duplicate(true),
		"resolved_node_ids": _int_array_to_dictionary(
			resolved_node_ids as Array[int]
		),
		"settlement_committed": bool(snapshot["settlement_committed"]),
	}


func _decode_peer_id_array(value: Variant) -> Variant:
	var result: Array[int] = []
	var seen: Dictionary = {}
	if typeof(value) != TYPE_ARRAY:
		return null
	for raw_peer_id in value as Array:
		if typeof(raw_peer_id) != TYPE_INT:
			return null
		var peer_id := int(raw_peer_id)
		if peer_id < 0 or seen.has(peer_id):
			return null
		seen[peer_id] = true
		result.append(peer_id)
	result.sort()
	return result


func _decode_nonnegative_int_array(value: Variant) -> Variant:
	return _decode_peer_id_array(value)


func _decode_votes(value: Variant, participants: Array[int]) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return null
	var result: Dictionary = {}
	for raw_vote_value in value as Array:
		if typeof(raw_vote_value) != TYPE_DICTIONARY:
			return null
		var vote := raw_vote_value as Dictionary
		if (
			typeof(vote.get("peer_id")) != TYPE_INT
			or typeof(vote.get("option_id")) != TYPE_STRING
		):
			return null
		var peer_id := int(vote["peer_id"])
		var option_id := StringName(vote["option_id"])
		if (
			not participants.has(peer_id)
			or result.has(peer_id)
			or option_id not in [
				RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
				RogueEncounterEconomyCoordinator.OPTION_FREE,
			]
		):
			return null
		result[peer_id] = option_id
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


func _dictionary_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for raw_key in source.keys():
		result.append(int(raw_key))
	result.sort()
	return result


func _get_result_text() -> String:
	match StringName(_economy_result.get("result_code", &"")):
		RogueEncounterEconomyCoordinator.RESULT_GRANTED_PAID:
			return "一手交钱，一手交球。"
		RogueEncounterEconomyCoordinator.RESULT_GRANTED_FREE:
			return "好吧，那就送你了。"
		RogueEncounterEconomyCoordinator.RESULT_FREE_FAILED:
			return "哪有什么好的事情。"
		RogueEncounterEconomyCoordinator.RESULT_ALL_INVENTORIES_FULL:
			return "所有玩家背包均已满，交易未完成。"
		RogueEncounterEconomyCoordinator.RESULT_INSUFFICIENT_PLANKS:
			return "木板不足，交易未完成。"
		_:
			return ""


func _export_votes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for peer_id in _dictionary_int_keys(_votes):
		result.append(
			{
				"peer_id": peer_id,
				"option_id": String(StringName(_votes[peer_id])),
			}
		)
	return result


func _int_array_to_dictionary(values: Array[int]) -> Dictionary:
	var result: Dictionary = {}
	for value in values:
		result[value] = true
	return result


func _replace_peer_id(values: Array[int], old_peer_id: int, new_peer_id: int) -> void:
	var index := values.find(old_peer_id)
	if index >= 0:
		values[index] = new_peer_id
		values.sort()


func _bump_revision() -> void:
	_revision += 1


func _bump_and_emit() -> void:
	_bump_revision()
	state_changed.emit(export_state())


func _on_economy_changed(snapshot: Dictionary) -> void:
	_economy_snapshot = (
		_economy.export_snapshot(_participant_peer_ids)
		if _is_authority and _economy != null
		else snapshot.duplicate(true)
	)
	economy_changed.emit(_economy_snapshot.duplicate(true))
	if _refresh_option_availability():
		_bump_and_emit()
