extends Node
class_name RogueSupplySession

signal state_changed(snapshot: Dictionary)
signal supply_started(snapshot: Dictionary)
signal supply_finished(snapshot: Dictionary)
signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 2
const VOTING_TIMEOUT_SECONDS := 60.0
const PHASE_IDLE := &"idle"
const PHASE_INTRO := &"intro"
const PHASE_VOTING := &"voting"
const PHASE_COLLECTIBLE_CHOICE := &"collectible_choice"
const PHASE_RESULT := &"result"
const PHASE_COMPLETED := &"completed"

var _economy: RogueSupplyEconomyCoordinator
var _is_authority := false
var _revision := 0
var _phase: StringName = PHASE_IDLE
var _node_id := -1
var _node_content_seed := 0
var _occurrence_key := ""
var _remaining_seconds := 0.0
var _voting_timer_running := false
var _last_broadcast_remaining_second := -1
var _participant_peer_ids: Array[int] = []
var _active_peer_ids: Array[int] = []
var _disconnected_peer_ids: Array[int] = []
var _spectator_peer_ids: Array[int] = []
var _intro_confirmed: Dictionary = {}
var _option_ids: Array[StringName] = []
var _option_availability: Dictionary = {}
var _disabled_option_ids: Dictionary = {}
var _votes: Dictionary = {}
var _abstained: Dictionary = {}
var _winning_option: StringName = &""
var _result: Dictionary = {}
var _collectible_offers: Dictionary = {}
var _collectible_offer_occurrences: Dictionary = {}
var _claimed_peer_ids: Dictionary = {}
var _personal_messages: Dictionary = {}
var _result_ack_peer_ids: Dictionary = {}
var _resolved_node_ids: Dictionary = {}
var _settlement_committed := false
var _economy_snapshot: Dictionary = {}


func reset_authority(
	economy: RogueSupplyEconomyCoordinator,
	_peer_ids: Array[int]
) -> void:
	_reset_runtime(economy)
	_is_authority = true


func reset_remote(economy: RogueSupplyEconomyCoordinator) -> void:
	_reset_runtime(economy)
	_is_authority = false


func _reset_runtime(economy: RogueSupplyEconomyCoordinator) -> void:
	if (
		_economy != null
		and _economy.economy_changed.is_connected(_on_economy_changed)
	):
		_economy.economy_changed.disconnect(_on_economy_changed)
	_economy = economy
	_revision = 0
	_phase = PHASE_IDLE
	_node_id = -1
	_node_content_seed = 0
	_occurrence_key = ""
	_remaining_seconds = 0.0
	_voting_timer_running = false
	_last_broadcast_remaining_second = -1
	_participant_peer_ids.clear()
	_active_peer_ids.clear()
	_disconnected_peer_ids.clear()
	_spectator_peer_ids.clear()
	_intro_confirmed.clear()
	_option_ids.clear()
	_option_availability.clear()
	_disabled_option_ids.clear()
	_votes.clear()
	_abstained.clear()
	_winning_option = &""
	_result.clear()
	_collectible_offers.clear()
	_collectible_offer_occurrences.clear()
	_claimed_peer_ids.clear()
	_personal_messages.clear()
	_result_ack_peer_ids.clear()
	_resolved_node_ids.clear()
	_settlement_committed = false
	_economy_snapshot.clear()
	if _economy != null:
		_economy.economy_changed.connect(_on_economy_changed)


func start_for_node(
	node_id: int,
	node_content_seed: int,
	participant_peer_ids: Array[int]
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
	var excluded: Array[StringName] = []
	if _economy.party_has_flying_envelope(participants):
		excluded.append(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE)
	var options := RogueSupplyRegistry.select_options(
		node_content_seed,
		excluded
	)
	if options.size() != RogueSupplyRegistry.CHOICE_COUNT:
		return false
	_node_id = node_id
	_node_content_seed = node_content_seed
	_occurrence_key = "%d:%d:supply" % [node_id, node_content_seed]
	_phase = PHASE_INTRO
	_remaining_seconds = VOTING_TIMEOUT_SECONDS
	_voting_timer_running = false
	_last_broadcast_remaining_second = ceili(VOTING_TIMEOUT_SECONDS)
	_participant_peer_ids = participants.duplicate()
	_active_peer_ids = participants.duplicate()
	_disconnected_peer_ids.clear()
	_spectator_peer_ids.clear()
	_intro_confirmed.clear()
	_option_ids = options
	_votes.clear()
	_abstained.clear()
	_winning_option = &""
	_result.clear()
	_sync_pending_collectible_offers_from_economy()
	_claimed_peer_ids.clear()
	_prune_personal_messages_to_pending_offers()
	_result_ack_peer_ids.clear()
	_settlement_committed = false
	_disabled_option_ids.clear()
	_refresh_option_availability()
	_economy_snapshot = _economy.export_snapshot(_get_economy_peer_ids())
	_bump_revision()
	var snapshot := export_state()
	state_changed.emit(snapshot)
	supply_started.emit(snapshot)
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
	if not _voting_timer_running:
		_voting_timer_running = true
		_last_broadcast_remaining_second = ceili(_remaining_seconds)
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
		or not _option_ids.has(option_id)
		or not bool(_option_availability.get(String(option_id), false))
		or StringName(_votes.get(peer_id, &"")) == option_id
	):
		return false
	_votes[peer_id] = option_id
	_abstained.erase(peer_id)
	_bump_and_emit()
	_maybe_resolve_vote()
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
		_maybe_resolve_vote(true)
		return
	var visible_second := ceili(_remaining_seconds)
	if visible_second != _last_broadcast_remaining_second:
		_last_broadcast_remaining_second = visible_second
		# 倒计时展示不推进 revision，避免让同一秒在途的可靠投票过期。
		state_changed.emit(export_state())
	_maybe_resolve_vote()


func submit_collectible_choice(
	peer_id: int,
	occurrence_key: String,
	_expected_revision: int,
	offer_index: int
) -> bool:
	if (
		not _is_authority
		or _phase == PHASE_IDLE
		or not _collectible_offers.has(peer_id)
		or str(_collectible_offer_occurrences.get(peer_id, ""))
		!= occurrence_key
	):
		return false
	var raw_paths := _collectible_offers[peer_id] as Array
	var paths: Array[String] = []
	for raw_path in raw_paths:
		paths.append(str(raw_path))
	var claim_result := _economy.claim_collectible(
		peer_id,
		paths,
		offer_index,
		occurrence_key
	)
	if not bool(claim_result.get("claimed", false)):
		if str(claim_result.get("reason", "")) == "inventory_full":
			_personal_messages[peer_id] = "背包已满，请清出一个空位后再次选择。"
			_bump_and_emit()
		return false
	_personal_messages[peer_id] = "已获得%s。" % str(
		claim_result.get("display_name", "收藏品")
	)
	_sync_pending_collectible_offers_from_economy()
	if _collectible_offers.has(peer_id):
		_claimed_peer_ids.erase(peer_id)
	else:
		_claimed_peer_ids[peer_id] = true
	_economy_snapshot = _economy.export_snapshot(_get_economy_peer_ids())
	if _phase == PHASE_COLLECTIBLE_CHOICE:
		_finish_collectible_choice_if_active_done()
	_bump_and_emit()
	return true


func submit_completion(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int
) -> bool:
	if (
		not _can_accept_request(peer_id, occurrence_key, expected_revision)
		or _phase != PHASE_RESULT
		or _result_ack_peer_ids.has(peer_id)
	):
		return false
	_result_ack_peer_ids[peer_id] = true
	if _all_active_result_acked():
		_complete_supply()
	else:
		_bump_and_emit()
	return true


func remove_peer(peer_id: int) -> bool:
	if (
		not _is_authority
		or not (
			_participant_peer_ids.has(peer_id)
			or _collectible_offers.has(peer_id)
		)
	):
		return false
	var changed := _active_peer_ids.has(peer_id)
	_active_peer_ids.erase(peer_id)
	if not _disconnected_peer_ids.has(peer_id):
		_disconnected_peer_ids.append(peer_id)
		_disconnected_peer_ids.sort()
		changed = true
	if not changed:
		return false
	_result_ack_peer_ids.erase(peer_id)
	_refresh_option_availability()
	if _phase == PHASE_INTRO and _all_active_intro_confirmed():
		_phase = PHASE_VOTING
	_bump_and_emit()
	if _phase == PHASE_VOTING:
		_maybe_resolve_vote()
	elif _phase == PHASE_COLLECTIBLE_CHOICE:
		_finish_collectible_choice_if_active_done()
	elif _phase == PHASE_RESULT and _all_active_result_acked():
		_complete_supply()
	return true


func migrate_peer(old_peer_id: int, new_peer_id: int) -> bool:
	var migrates_participant := _participant_peer_ids.has(old_peer_id)
	var migrates_spectator := _spectator_peer_ids.has(old_peer_id)
	var migrates_pending_claim := _collectible_offers.has(old_peer_id)
	if (
		not _is_authority
		or old_peer_id < 0
		or new_peer_id < 0
		or old_peer_id == new_peer_id
		or not (
			migrates_participant
			or migrates_spectator
			or migrates_pending_claim
		)
		or _participant_peer_ids.has(new_peer_id)
		or _spectator_peer_ids.has(new_peer_id)
		or _collectible_offers.has(new_peer_id)
	):
		return false
	if migrates_participant:
		_replace_peer_id(_participant_peer_ids, old_peer_id, new_peer_id)
		if _active_peer_ids.has(old_peer_id):
			_replace_peer_id(_active_peer_ids, old_peer_id, new_peer_id)
		elif _phase in [PHASE_INTRO, PHASE_VOTING, PHASE_COLLECTIBLE_CHOICE, PHASE_RESULT]:
			_active_peer_ids.append(new_peer_id)
			_active_peer_ids.sort()
		_disconnected_peer_ids.erase(old_peer_id)
	elif migrates_spectator:
		_replace_peer_id(_spectator_peer_ids, old_peer_id, new_peer_id)
	_migrate_dictionary_key(_intro_confirmed, old_peer_id, new_peer_id)
	if _phase == PHASE_VOTING and not _intro_confirmed.has(new_peer_id):
		# 已进入投票阶段后重连的参与者已经恢复到完整物资界面，不再要求
		# 一个只会在 intro 阶段自动发送的旧确认包。
		_intro_confirmed[new_peer_id] = true
	_migrate_dictionary_key(_votes, old_peer_id, new_peer_id)
	_migrate_dictionary_key(_abstained, old_peer_id, new_peer_id)
	_migrate_dictionary_key(_claimed_peer_ids, old_peer_id, new_peer_id)
	_migrate_dictionary_key(_personal_messages, old_peer_id, new_peer_id)
	_migrate_dictionary_key(_result_ack_peer_ids, old_peer_id, new_peer_id)
	_result = _economy.migrate_result_peer_references(
		_result,
		old_peer_id,
		new_peer_id
	)
	_economy.migrate_peer_references(old_peer_id, new_peer_id)
	_sync_pending_collectible_offers_from_economy()
	_refresh_option_availability()
	_economy_snapshot = _economy.export_snapshot(_get_economy_peer_ids())
	_bump_and_emit()
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


func export_state() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _revision,
		"phase": String(_phase),
		"node_id": _node_id,
		"node_content_seed": _node_content_seed,
		"occurrence_key": _occurrence_key,
		"remaining_seconds": _remaining_seconds,
		"voting_timer_running": _voting_timer_running,
		"participant_peer_ids": _participant_peer_ids.duplicate(),
		"active_peer_ids": _active_peer_ids.duplicate(),
		"disconnected_peer_ids": _disconnected_peer_ids.duplicate(),
		"spectator_peer_ids": _spectator_peer_ids.duplicate(),
		"intro_confirmed_peer_ids": _dictionary_int_keys(_intro_confirmed),
		"option_ids": _string_name_array_to_strings(_option_ids),
		"option_availability": _option_availability.duplicate(true),
		"votes": _export_votes(),
		"abstained_peer_ids": _dictionary_int_keys(_abstained),
		"winning_option": String(_winning_option),
		"result": _result.duplicate(true),
		"result_text": str(_result.get("result_text", "")),
		"collectible_offers": _export_collectible_offers(),
		"claimed_peer_ids": _dictionary_int_keys(_claimed_peer_ids),
		"personal_messages": _export_personal_messages(),
		"result_ack_peer_ids": _dictionary_int_keys(_result_ack_peer_ids),
		"resolved_node_ids": _dictionary_int_keys(_resolved_node_ids),
		"settlement_committed": _settlement_committed,
		"light_stone_amount": (
			_economy.get_light_stone_amount() if _economy != null else 0
		),
		"economy_snapshot": _economy_snapshot.duplicate(true),
	}


func apply_remote_state(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if decoded.is_empty():
		return false
	var incoming_revision := int(decoded["revision"])
	if incoming_revision < _revision:
		return false
	var incoming_economy := decoded["economy_snapshot"] as Dictionary
	if (
		_economy != null
		and not incoming_economy.is_empty()
		and not _economy.apply_remote_snapshot(incoming_economy)
	):
		return false
	var was_active := is_active()
	var previous_phase := _phase
	_revision = incoming_revision
	_phase = StringName(decoded["phase"])
	_node_id = int(decoded["node_id"])
	_node_content_seed = int(decoded["node_content_seed"])
	_occurrence_key = str(decoded["occurrence_key"])
	_remaining_seconds = float(decoded["remaining_seconds"])
	_voting_timer_running = bool(decoded["voting_timer_running"])
	_last_broadcast_remaining_second = ceili(_remaining_seconds)
	_participant_peer_ids = decoded["participant_peer_ids"] as Array[int]
	_active_peer_ids = decoded["active_peer_ids"] as Array[int]
	_disconnected_peer_ids = decoded["disconnected_peer_ids"] as Array[int]
	_spectator_peer_ids = decoded["spectator_peer_ids"] as Array[int]
	_intro_confirmed = decoded["intro_confirmed"] as Dictionary
	_option_ids = decoded["option_ids"] as Array[StringName]
	_option_availability = decoded["option_availability"] as Dictionary
	_votes = decoded["votes"] as Dictionary
	_abstained = decoded["abstained"] as Dictionary
	_winning_option = StringName(decoded["winning_option"])
	_result = decoded["result"] as Dictionary
	_collectible_offers = decoded["collectible_offers"] as Dictionary
	_collectible_offer_occurrences = (
		decoded["collectible_offer_occurrences"] as Dictionary
	)
	_claimed_peer_ids = decoded["claimed_peer_ids"] as Dictionary
	_personal_messages = decoded["personal_messages"] as Dictionary
	_result_ack_peer_ids = decoded["result_ack_peer_ids"] as Dictionary
	_resolved_node_ids = decoded["resolved_node_ids"] as Dictionary
	_settlement_committed = bool(decoded["settlement_committed"])
	_economy_snapshot = incoming_economy
	var applied := export_state()
	state_changed.emit(applied)
	if not was_active and is_active():
		supply_started.emit(applied)
	if previous_phase != PHASE_COMPLETED and _phase == PHASE_COMPLETED:
		supply_finished.emit(applied)
	return true


func validate_remote_state(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if (
		decoded.is_empty()
		or not validate_remote_state_structure(snapshot)
		or int(decoded["revision"]) < _revision
	):
		return false
	var incoming_economy := decoded["economy_snapshot"] as Dictionary
	return (
		_economy == null
		or incoming_economy.is_empty()
		or _economy.validate_remote_snapshot(incoming_economy)
	)


func validate_remote_state_structure(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if decoded.is_empty():
		return false
	var incoming_economy := decoded["economy_snapshot"] as Dictionary
	return (
		_economy == null
		or incoming_economy.is_empty()
		or _economy.validate_remote_snapshot_structure(incoming_economy)
	)


func is_active() -> bool:
	return _phase in [
		PHASE_INTRO,
		PHASE_VOTING,
		PHASE_COLLECTIBLE_CHOICE,
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


func get_participant_peer_ids() -> Array[int]:
	return _participant_peer_ids.duplicate()


func get_economy_peer_ids() -> Array[int]:
	return _get_economy_peer_ids()


func has_pending_collectible_for_peer(peer_id: int) -> bool:
	return _collectible_offers.has(peer_id)


func get_pending_collectible_occurrence_for_peer(peer_id: int) -> String:
	return str(_collectible_offer_occurrences.get(peer_id, ""))


func _maybe_resolve_vote(force_timeout: bool = false) -> void:
	if _phase not in [PHASE_INTRO, PHASE_VOTING] or _active_peer_ids.is_empty():
		return
	if not force_timeout:
		for peer_id in _active_peer_ids:
			if not _votes.has(peer_id):
				return
	var winning_option := _select_winning_option(force_timeout)
	if winning_option.is_empty():
		return
	_winning_option = winning_option
	var prepared_collectible_offers: Dictionary = {}
	if _winning_option == RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES:
		prepared_collectible_offers = _economy.build_collectible_offers(
			_node_content_seed,
			_participant_peer_ids
		)
		if prepared_collectible_offers.size() != _participant_peer_ids.size():
			_disable_option_for_occurrence(_winning_option)
			_recover_or_finish_failed_resolution(force_timeout)
			return
	var result := _economy.resolve_option(
		_winning_option,
		_node_content_seed,
		_participant_peer_ids,
		_occurrence_key,
		prepared_collectible_offers
	)
	if not bool(result.get("resolved", false)):
		_refresh_option_availability()
		_disable_option_for_occurrence(_winning_option)
		_recover_or_finish_failed_resolution(force_timeout)
		return
	_result = result.duplicate(true)
	_settlement_committed = true
	_remaining_seconds = 0.0
	_voting_timer_running = false
	_last_broadcast_remaining_second = 0
	_economy_snapshot = _economy.export_snapshot(_get_economy_peer_ids())
	if _winning_option == RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES:
		_sync_pending_collectible_offers_from_economy()
		_phase = PHASE_COLLECTIBLE_CHOICE
	else:
		_phase = PHASE_RESULT
	_result_ack_peer_ids.clear()
	_bump_and_emit()


func _select_winning_option(allow_no_vote_fallback: bool = false) -> StringName:
	var counts: Dictionary = {}
	for peer_id in _active_peer_ids:
		var option_id := StringName(_votes.get(peer_id, &""))
		if (
			_option_ids.has(option_id)
			and bool(_option_availability.get(String(option_id), false))
		):
			counts[option_id] = int(counts.get(option_id, 0)) + 1
	var highest_count := 0
	var tied: Array[StringName] = []
	for option_id in _option_ids:
		var count := int(counts.get(option_id, 0))
		if count > highest_count:
			highest_count = count
			tied = [option_id]
		elif count > 0 and count == highest_count:
			tied.append(option_id)
	if tied.is_empty():
		if not allow_no_vote_fallback:
			return &""
		for option_id in _option_ids:
			if bool(_option_availability.get(String(option_id), false)):
				tied.append(option_id)
		if tied.is_empty():
			return &""
	return tied[RogueSupplyRandom.choose_index(
		_node_content_seed,
		(&"supply_timeout_no_vote" if highest_count == 0 else &"supply_vote_tie"),
		tied.size()
	)]


func _disable_option_for_occurrence(option_id: StringName) -> void:
	if not option_id.is_empty():
		_disabled_option_ids[option_id] = true
		_option_availability[String(option_id)] = false


func _recover_or_finish_failed_resolution(force_timeout: bool) -> void:
	_votes.clear()
	_abstained.clear()
	_winning_option = &""
	if force_timeout and _has_available_option():
		_maybe_resolve_vote(true)
		return
	if not _has_available_option():
		_result = {
			"resolved": false,
			"result_code": "no_available_supply_option",
			"result_text": "当前物资均无法安全结算，本次清点已结束。",
		}
		_remaining_seconds = 0.0
		_voting_timer_running = false
		_phase = PHASE_RESULT
		_result_ack_peer_ids.clear()
	_bump_and_emit()


func _has_available_option() -> bool:
	for option_id in _option_ids:
		if bool(_option_availability.get(String(option_id), false)):
			return true
	return false


func _complete_supply() -> void:
	if _phase != PHASE_RESULT:
		return
	_resolved_node_ids[_node_id] = true
	_phase = PHASE_COMPLETED
	_bump_revision()
	var snapshot := export_state()
	state_changed.emit(snapshot)
	supply_finished.emit(snapshot)


func _finish_collectible_choice_if_active_done() -> bool:
	if _phase != PHASE_COLLECTIBLE_CHOICE:
		return false
	for peer_id in _active_peer_ids:
		if _collectible_offers.has(peer_id):
			return false
	_result["pending_collectible_choices"] = (
		_economy.has_pending_collectible_claims()
	)
	_result["result_text"] = (
		"在线玩家已完成选择；离线玩家重连后仍可领取。"
		if _economy.has_pending_collectible_claims()
		else "每位玩家都选择了自己的收藏品。"
	)
	_phase = PHASE_RESULT
	_result_ack_peer_ids.clear()
	return true


func _all_active_intro_confirmed() -> bool:
	if _active_peer_ids.is_empty():
		return false
	for peer_id in _active_peer_ids:
		if not _intro_confirmed.has(peer_id):
			return false
	return true


func _all_active_result_acked() -> bool:
	for peer_id in _active_peer_ids:
		if not _result_ack_peer_ids.has(peer_id):
			return false
	return true


func _sync_pending_collectible_offers_from_economy() -> void:
	_collectible_offers = (
		_economy.get_pending_collectible_offers()
		if _economy != null
		else {}
	)
	_collectible_offer_occurrences.clear()
	for raw_peer_id in _collectible_offers.keys():
		var peer_id := int(raw_peer_id)
		# claimed 只描述“当前没有待领取项”；新 occurrence 入队后必须
		# 立即撤销旧标志，否则 Overlay 会把新三选一卡片全部禁用。
		_claimed_peer_ids.erase(peer_id)
		_collectible_offer_occurrences[peer_id] = (
			_economy.get_pending_collectible_occurrence(peer_id)
		)


func _get_economy_peer_ids() -> Array[int]:
	var result := _participant_peer_ids.duplicate()
	for source in [
		_spectator_peer_ids,
		_disconnected_peer_ids,
		_collectible_offers.keys(),
		_claimed_peer_ids.keys(),
	]:
		for raw_peer_id in source:
			var peer_id := int(raw_peer_id)
			if peer_id >= 0 and not result.has(peer_id):
				result.append(peer_id)
	result.sort()
	return result


func _prune_personal_messages_to_pending_offers() -> void:
	for raw_peer_id in _personal_messages.keys():
		if not _collectible_offers.has(int(raw_peer_id)):
			_personal_messages.erase(raw_peer_id)


func _refresh_option_availability() -> void:
	_option_availability = _economy.get_option_availability(_option_ids)
	if _option_ids.has(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
	):
		var offers := _economy.build_collectible_offers(
			_node_content_seed,
			_participant_peer_ids
		)
		var option_key := String(
			RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
		)
		_option_availability[option_key] = (
			bool(_option_availability.get(option_key, false))
			and offers.size() == _participant_peer_ids.size()
		)
	for raw_option_id in _disabled_option_ids.keys():
		_option_availability[String(StringName(raw_option_id))] = false


func _can_accept_request(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int
) -> bool:
	return (
		_is_authority
		and peer_id >= 0
		and _active_peer_ids.has(peer_id)
		and occurrence_key == _occurrence_key
		and expected_revision == _revision
	)


func _decode_state(snapshot: Dictionary) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
		or typeof(snapshot.get("remaining_seconds")) not in [TYPE_FLOAT, TYPE_INT]
		or float(snapshot["remaining_seconds"]) < 0.0
		or typeof(snapshot.get("voting_timer_running")) != TYPE_BOOL
		or typeof(snapshot.get("phase")) != TYPE_STRING
		or StringName(snapshot["phase"]) not in [
			PHASE_IDLE,
			PHASE_INTRO,
			PHASE_VOTING,
			PHASE_COLLECTIBLE_CHOICE,
			PHASE_RESULT,
			PHASE_COMPLETED,
		]
	):
		return {}
	var participant_peer_ids: Variant = _decode_int_array(
		snapshot.get("participant_peer_ids")
	)
	var active_peer_ids: Variant = _decode_int_array(
		snapshot.get("active_peer_ids")
	)
	var disconnected_peer_ids: Variant = _decode_int_array(
		snapshot.get("disconnected_peer_ids")
	)
	var spectator_peer_ids: Variant = _decode_int_array(
		snapshot.get("spectator_peer_ids")
	)
	var option_ids: Variant = _decode_option_ids(snapshot.get("option_ids"))
	if (
		participant_peer_ids == null
		or active_peer_ids == null
		or disconnected_peer_ids == null
		or spectator_peer_ids == null
		or option_ids == null
		or typeof(snapshot.get("option_availability")) != TYPE_DICTIONARY
		or typeof(snapshot.get("votes")) != TYPE_ARRAY
		or typeof(snapshot.get("result")) != TYPE_DICTIONARY
		or typeof(snapshot.get("collectible_offers")) != TYPE_ARRAY
		or typeof(snapshot.get("personal_messages")) != TYPE_ARRAY
		or typeof(snapshot.get("economy_snapshot")) != TYPE_DICTIONARY
	):
		return {}
	var intro: Variant = _decode_int_set(snapshot.get("intro_confirmed_peer_ids"))
	var abstained: Variant = _decode_int_set(snapshot.get("abstained_peer_ids"))
	var claimed: Variant = _decode_int_set(snapshot.get("claimed_peer_ids"))
	var result_acks: Variant = _decode_int_set(snapshot.get("result_ack_peer_ids"))
	var resolved_nodes: Variant = _decode_int_set(snapshot.get("resolved_node_ids"))
	var votes: Variant = _decode_votes(
		snapshot["votes"] as Array,
		option_ids as Array[StringName]
	)
	var offers: Variant = _decode_collectible_offers(
		snapshot["collectible_offers"] as Array
	)
	var messages: Variant = _decode_personal_messages(
		snapshot["personal_messages"] as Array
	)
	if (
		intro == null
		or abstained == null
		or claimed == null
		or result_acks == null
		or resolved_nodes == null
		or votes == null
		or offers == null
		or messages == null
	):
		return {}
	return {
		"revision": int(snapshot["revision"]),
		"phase": str(snapshot["phase"]),
		"node_id": int(snapshot.get("node_id", -1)),
		"node_content_seed": int(snapshot.get("node_content_seed", 0)),
		"occurrence_key": str(snapshot.get("occurrence_key", "")),
		"remaining_seconds": float(snapshot["remaining_seconds"]),
		"voting_timer_running": bool(snapshot["voting_timer_running"]),
		"participant_peer_ids": participant_peer_ids,
		"active_peer_ids": active_peer_ids,
		"disconnected_peer_ids": disconnected_peer_ids,
		"spectator_peer_ids": spectator_peer_ids,
		"intro_confirmed": intro,
		"option_ids": option_ids,
		"option_availability": (snapshot["option_availability"] as Dictionary).duplicate(true),
		"votes": votes,
		"abstained": abstained,
		"winning_option": str(snapshot.get("winning_option", "")),
		"result": (snapshot["result"] as Dictionary).duplicate(true),
		"collectible_offers": (offers as Dictionary)["offers"],
		"collectible_offer_occurrences": (
			(offers as Dictionary)["occurrences"]
		),
		"claimed_peer_ids": claimed,
		"personal_messages": messages,
		"result_ack_peer_ids": result_acks,
		"resolved_node_ids": resolved_nodes,
		"settlement_committed": bool(snapshot.get("settlement_committed", false)),
		"economy_snapshot": (snapshot["economy_snapshot"] as Dictionary).duplicate(true),
	}


func _export_votes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for peer_id in _dictionary_int_keys(_votes):
		result.append({
			"peer_id": peer_id,
			"option_id": String(StringName(_votes[peer_id])),
		})
	return result


func _export_collectible_offers() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for peer_id in _dictionary_int_keys(_collectible_offers):
		result.append({
			"peer_id": peer_id,
			"occurrence_key": str(
				_collectible_offer_occurrences.get(peer_id, "")
			),
			"paths": (_collectible_offers[peer_id] as Array).duplicate(),
		})
	return result


func _export_personal_messages() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for peer_id in _dictionary_int_keys(_personal_messages):
		result.append({
			"peer_id": peer_id,
			"message": str(_personal_messages[peer_id]),
		})
	return result


func _decode_votes(entries: Array, option_ids: Array[StringName]) -> Variant:
	var result: Dictionary = {}
	for raw_entry_value in entries:
		if typeof(raw_entry_value) != TYPE_DICTIONARY:
			return null
		var entry := raw_entry_value as Dictionary
		var peer_id := int(entry.get("peer_id", -1))
		var option_id := StringName(entry.get("option_id", &""))
		if peer_id < 0 or result.has(peer_id) or not option_ids.has(option_id):
			return null
		result[peer_id] = option_id
	return result


func _decode_collectible_offers(entries: Array) -> Variant:
	var result: Dictionary = {}
	var occurrences: Dictionary = {}
	for raw_entry_value in entries:
		if typeof(raw_entry_value) != TYPE_DICTIONARY:
			return null
		var entry := raw_entry_value as Dictionary
		var peer_id := int(entry.get("peer_id", -1))
		var occurrence_key := str(entry.get("occurrence_key", ""))
		if (
			peer_id < 0
			or occurrence_key.is_empty()
			or result.has(peer_id)
			or typeof(entry.get("paths")) != TYPE_ARRAY
		):
			return null
		var paths: Array[String] = []
		for raw_path in entry["paths"] as Array:
			if typeof(raw_path) != TYPE_STRING or str(raw_path).is_empty():
				return null
			paths.append(str(raw_path))
		result[peer_id] = paths
		occurrences[peer_id] = occurrence_key
	return {"offers": result, "occurrences": occurrences}


func _decode_personal_messages(entries: Array) -> Variant:
	var result: Dictionary = {}
	for raw_entry_value in entries:
		if typeof(raw_entry_value) != TYPE_DICTIONARY:
			return null
		var entry := raw_entry_value as Dictionary
		var peer_id := int(entry.get("peer_id", -1))
		if peer_id < 0 or result.has(peer_id):
			return null
		result[peer_id] = str(entry.get("message", ""))
	return result


func _decode_option_ids(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return null
	var result: Array[StringName] = []
	for raw_option_id in value as Array:
		var option_id := StringName(raw_option_id)
		if not RogueSupplyRegistry.has_option(option_id) or result.has(option_id):
			return null
		result.append(option_id)
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


func _string_name_array_to_strings(source: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in source:
		result.append(String(value))
	return result


func _normalize_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id >= 0 and not result.has(peer_id):
			result.append(peer_id)
	result.sort()
	return result


func _replace_peer_id(peer_ids: Array[int], old_peer_id: int, new_peer_id: int) -> void:
	peer_ids.erase(old_peer_id)
	if not peer_ids.has(new_peer_id):
		peer_ids.append(new_peer_id)
	peer_ids.sort()


func _migrate_dictionary_key(source: Dictionary, old_key: int, new_key: int) -> void:
	if not source.has(old_key):
		return
	source[new_key] = source[old_key]
	source.erase(old_key)


func _bump_revision() -> void:
	_revision += 1


func _bump_and_emit() -> void:
	_bump_revision()
	state_changed.emit(export_state())


func _on_economy_changed(snapshot: Dictionary) -> void:
	_economy_snapshot = snapshot.duplicate(true)
	economy_changed.emit(snapshot.duplicate(true))
