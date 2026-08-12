extends Node
class_name RogueEncounterSession

signal state_changed(snapshot: Dictionary)
signal encounter_started(snapshot: Dictionary)
signal encounter_finished(snapshot: Dictionary)
signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 5
const VOTING_TIMEOUT_SECONDS := 60.0
const MAX_RESULT_PAGE_COUNT := 4

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
var _run_state: RunStateStore
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
var _result_pages: Array[Dictionary] = []
var _round_index := 0
var _result_sequence := 0
var _disabled_option_ids: Array[StringName] = []
var _round_recipient_peer_ids: Array[int] = []
var _result_ack_peer_ids: Dictionary = {}
var _terminal_result := false
var _run_failed := false
var _personal_result_pages: Dictionary = {}
var _economy_snapshot: Dictionary = {}
var _resolved_node_ids: Dictionary = {}
var _encountered_encounter_ids: Array[StringName] = []
var _settlement_committed := false


func initialize_authority(
	economy: RogueEncounterEconomyCoordinator,
	peer_ids: Array[int],
	run_state: RunStateStore = null
) -> void:
	reset_authority(economy, peer_ids, run_state)


func initialize_remote(
	economy: RogueEncounterEconomyCoordinator,
	run_state: RunStateStore = null
) -> void:
	reset_remote(economy, run_state)


func reset_authority(
	economy: RogueEncounterEconomyCoordinator,
	peer_ids: Array[int],
	run_state: RunStateStore = null
) -> void:
	_reset_runtime_state(economy, run_state)
	_is_authority = true
	_authority_peer_ids = _normalize_peer_ids(peer_ids)


func reset_remote(
	economy: RogueEncounterEconomyCoordinator,
	run_state: RunStateStore = null
) -> void:
	_reset_runtime_state(economy, run_state)
	_is_authority = false


func _reset_runtime_state(
	economy: RogueEncounterEconomyCoordinator,
	run_state: RunStateStore
) -> void:
	if (
		_economy != null
		and _economy.economy_changed.is_connected(_on_economy_changed)
	):
		_economy.economy_changed.disconnect(_on_economy_changed)
	_economy = economy
	_run_state = run_state
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
	_result_pages.clear()
	_round_index = 0
	_result_sequence = 0
	_disabled_option_ids.clear()
	_round_recipient_peer_ids.clear()
	_result_ack_peer_ids.clear()
	_terminal_result = false
	_run_failed = false
	_personal_result_pages.clear()
	_economy_snapshot.clear()
	_resolved_node_ids.clear()
	_encountered_encounter_ids.clear()
	if _run_state != null:
		_run_state.ensure_run_started()
		_encountered_encounter_ids = _run_state.get_rogue_encountered_ids()
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
		or not _economy.is_configured()
		or is_active()
		or node_id < 0
		or is_node_resolved(node_id)
	):
		return false
	var participants := _normalize_peer_ids(
		eligible_peer_ids if not eligible_peer_ids.is_empty() else _authority_peer_ids
	)
	if participants.is_empty():
		return false
	if _run_state != null:
		_encountered_encounter_ids = _run_state.get_rogue_encountered_ids()
	var encounter_id := RogueEncounterRegistry.select_encounter_for_run(
		content_pool_id,
		node_content_seed,
		_encountered_encounter_ids
	)
	if (
		encounter_id.is_empty()
		or not RogueEncounterRegistry.has_encounter(encounter_id)
	):
		return false
	# 选择与参与者均已验证，且尚未写入任何 Session 阶段字段；此时提交
	# RunState，失败会干净返回，不留下半启动的 active Session。
	if _run_state != null:
		if not _run_state.record_rogue_encounter(encounter_id):
			return false
		_encountered_encounter_ids = _run_state.get_rogue_encountered_ids()
	elif not _encountered_encounter_ids.has(encounter_id):
		_encountered_encounter_ids.append(encounter_id)

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
	_result_pages.clear()
	_round_index = 0
	_result_sequence = 0
	_disabled_option_ids.clear()
	_round_recipient_peer_ids.clear()
	_result_ack_peer_ids.clear()
	_terminal_result = false
	_run_failed = false
	_personal_result_pages.clear()
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
	_round_recipient_peer_ids.erase(peer_id)
	_result_ack_peer_ids.erase(peer_id)
	_refresh_option_availability()
	_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	if (
		_phase == PHASE_RESULT
		and _encounter_uses_result_ack()
		and _all_round_recipients_acked()
	):
		_finish_result_ack_barrier()
		return true
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
	if _round_recipient_peer_ids.has(old_peer_id):
		_replace_peer_id(_round_recipient_peer_ids, old_peer_id, new_peer_id)
	if _result_ack_peer_ids.has(old_peer_id):
		_result_ack_peer_ids[new_peer_id] = true
		_result_ack_peer_ids.erase(old_peer_id)
	if _personal_result_pages.has(old_peer_id):
		_personal_result_pages[new_peer_id] = (
			_personal_result_pages[old_peer_id] as Array
		).duplicate(true)
		_personal_result_pages.erase(old_peer_id)
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
		or _encounter_uses_result_ack()
	):
		return false
	_complete_encounter()
	return true


## 结果确认不依赖易过期的状态 revision；服务端以 occurrence、结果序号和
## peer 三元组幂等接收。只有结算瞬间固定下来的在线玩家需要确认。
func submit_result_ack(
	peer_id: int,
	occurrence_key: String,
	result_sequence: int
) -> bool:
	if (
		not _is_authority
		or _phase != PHASE_RESULT
		or not _encounter_uses_result_ack()
		or occurrence_key != _occurrence_key
		or result_sequence != _result_sequence
		or not _round_recipient_peer_ids.has(peer_id)
		or _result_ack_peer_ids.has(peer_id)
	):
		return false
	_result_ack_peer_ids[peer_id] = true
	if _all_round_recipients_acked():
		_finish_result_ack_barrier()
	else:
		_bump_and_emit()
	return true


func export_state() -> Dictionary:
	var encountered_ids := _encountered_encounter_ids
	if _run_state != null:
		encountered_ids = _run_state.get_rogue_encountered_ids()
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
		"result_pages": _result_pages.duplicate(true),
		"result_text": _get_result_text(),
		"round_index": _round_index,
		"result_sequence": _result_sequence,
		"disabled_option_ids": _string_name_array_to_strings(
			_disabled_option_ids
		),
		"round_recipient_peer_ids": _round_recipient_peer_ids.duplicate(),
		"result_ack_peer_ids": _dictionary_int_keys(_result_ack_peer_ids),
		"terminal_result": _terminal_result,
		"run_failed": _run_failed,
		"personal_result_pages": _personal_result_pages.duplicate(true),
		"economy_snapshot": _economy_snapshot.duplicate(true),
		"resolved_node_ids": _dictionary_int_keys(_resolved_node_ids),
		"encountered_encounter_ids": _string_name_array_to_strings(
			encountered_ids
		),
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
	var decoded_encounter_history: Array[StringName] = []
	decoded_encounter_history.assign(decoded["encountered_encounter_ids"])
	if (
		_run_state != null
		and _run_state.get_rogue_encountered_ids()
		!= decoded_encounter_history
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
	_result_pages = decoded["result_pages"] as Array[Dictionary]
	_round_index = int(decoded["round_index"])
	_result_sequence = int(decoded["result_sequence"])
	_disabled_option_ids = decoded["disabled_option_ids"] as Array[StringName]
	_round_recipient_peer_ids = decoded["round_recipient_peer_ids"] as Array[int]
	_result_ack_peer_ids = decoded["result_ack_peer_ids"] as Dictionary
	_terminal_result = bool(decoded["terminal_result"])
	_run_failed = bool(decoded["run_failed"])
	_personal_result_pages = decoded["personal_result_pages"] as Dictionary
	_economy_snapshot = incoming_economy
	_resolved_node_ids = decoded["resolved_node_ids"] as Dictionary
	_encountered_encounter_ids = decoded_encounter_history
	_settlement_committed = bool(decoded["settlement_committed"])
	var applied_snapshot := export_state()
	state_changed.emit(applied_snapshot)
	if not previous_active and is_active():
		encounter_started.emit(applied_snapshot)
	if previous_phase != PHASE_COMPLETED and _phase == PHASE_COMPLETED:
		encounter_finished.emit(applied_snapshot)
	return true


func validate_remote_state(snapshot: Dictionary) -> bool:
	var decoded := _decode_state(snapshot)
	if decoded.is_empty() or not validate_remote_state_structure(snapshot):
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
	var incoming_economy := decoded["economy_snapshot"] as Dictionary
	var decoded_encounter_history: Array[StringName] = []
	decoded_encounter_history.assign(decoded["encountered_encounter_ids"])
	return (
		(
			_run_state == null
			or not incoming_economy.is_empty()
			or _run_state.get_rogue_encountered_ids()
			== decoded_encounter_history
		)
		and (
			_economy == null
			or incoming_economy.is_empty()
			or _economy.validate_remote_snapshot(incoming_economy)
		)
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
	var reported_availability := _economy.get_option_availability(
		_encounter_id,
		_active_peer_ids
	)
	var next_availability: Dictionary = {}
	for option_id in RogueEncounterRegistry.get_option_ids(_encounter_id):
		var available := bool(
			reported_availability.get(
				String(option_id),
				reported_availability.get(option_id, false)
			)
		)
		next_availability[String(option_id)] = (
			available and not _disabled_option_ids.has(option_id)
		)
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
	var result := _economy.resolve_encounter(
		_encounter_id,
		_winning_option,
		_node_content_seed,
		_active_peer_ids,
		_occurrence_key,
		_round_index
	)
	if not bool(result.get("resolved", false)):
		_phase = PHASE_VOTING
		_remaining_seconds = 0.0
		_voting_timer_running = true
		_bump_and_emit()
		return
	_economy_result = result.duplicate(true)
	_result_sequence += 1
	_round_recipient_peer_ids = _active_peer_ids.duplicate()
	_result_ack_peer_ids.clear()
	_terminal_result = bool(_economy_result.get("terminal", true))
	_run_failed = bool(_economy_result.get("run_failed", false))
	if bool(_economy_result.get("disable_explore", false)):
		_disable_option_permanently(_winning_option)
	_result_pages = _build_common_result_pages(
		_encounter_id,
		_economy_result
	)
	_personal_result_pages = _build_personal_result_pages(_economy_result)
	_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	_settlement_committed = true
	if _terminal_result:
		_resolved_node_ids[_node_id] = true
	if _result_presentation_is_immediate(_economy_result):
		_complete_encounter()
		return
	_phase = PHASE_RESULT
	_bump_and_emit()


func _all_round_recipients_acked() -> bool:
	for peer_id in _round_recipient_peer_ids:
		if not _result_ack_peer_ids.has(peer_id):
			return false
	return true


func _finish_result_ack_barrier() -> void:
	if _phase != PHASE_RESULT:
		return
	if _terminal_result:
		_complete_encounter()
		return
	_round_index += 1
	_phase = PHASE_VOTING
	_remaining_seconds = VOTING_TIMEOUT_SECONDS
	_voting_timer_running = true
	_last_broadcast_remaining_second = ceili(VOTING_TIMEOUT_SECONDS)
	_votes.clear()
	_abstained.clear()
	_winning_option = &""
	_economy_result.clear()
	_result_pages.clear()
	_round_recipient_peer_ids.clear()
	_result_ack_peer_ids.clear()
	_terminal_result = false
	_run_failed = false
	_personal_result_pages.clear()
	_settlement_committed = false
	# 在结果页期间完成身份迁移的玩家不加入上一轮确认对象，但从下一轮
	# 开始可重新参与。仍处于 disconnected 集合中的身份继续排除。
	_active_peer_ids.clear()
	for peer_id in _participant_peer_ids:
		if not _disconnected_peer_ids.has(peer_id):
			_active_peer_ids.append(peer_id)
	_active_peer_ids.sort()
	_refresh_option_availability()
	_economy_snapshot = _economy.export_snapshot(_participant_peer_ids)
	_bump_and_emit()


func _complete_encounter() -> void:
	_phase = PHASE_COMPLETED
	_remaining_seconds = 0.0
	_voting_timer_running = false
	_last_broadcast_remaining_second = 0
	_bump_revision()
	var snapshot := export_state()
	state_changed.emit(snapshot)
	encounter_finished.emit(snapshot)


func _encounter_uses_result_ack() -> bool:
	return RogueEncounterRegistry.requires_result_ack(_encounter_id)


func _disable_option_permanently(option_id: StringName) -> void:
	if option_id.is_empty() or _disabled_option_ids.has(option_id):
		return
	_disabled_option_ids.append(option_id)
	_disabled_option_ids.sort()
	_option_availability[String(option_id)] = false


func _round_salt(base_salt: StringName) -> StringName:
	if _round_index <= 0:
		return base_salt
	return StringName("%s_round_%d" % [String(base_salt), _round_index])


func _select_winning_option() -> StringName:
	var available_options: Array[StringName] = []
	for option_id in RogueEncounterRegistry.get_option_ids(_encounter_id):
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
		var configured_no_vote := (
			RogueEncounterRegistry.get_no_vote_option_id(_encounter_id)
		)
		if available_options.has(configured_no_vote):
			return configured_no_vote
		return available_options[
			RogueEncounterRandom.choose_index(
				_node_content_seed,
				_round_salt(&"no_vote"),
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
			_round_salt(&"tie_break"),
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
		or typeof(snapshot.get("round_index")) != TYPE_INT
		or int(snapshot["round_index"]) < 0
		or typeof(snapshot.get("result_sequence")) != TYPE_INT
		or int(snapshot["result_sequence"]) < 0
		or typeof(snapshot.get("terminal_result")) != TYPE_BOOL
		or typeof(snapshot.get("run_failed")) != TYPE_BOOL
	):
		return {}
	var decoded_phase := StringName(snapshot["phase"])
	var decoded_encounter_id := StringName(snapshot.get("encounter_id", ""))
	if (
		decoded_phase != PHASE_IDLE
		and (
			decoded_encounter_id.is_empty()
			or RogueEncounterRegistry.get_definition(decoded_encounter_id).is_empty()
		)
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
	var round_recipient_ids: Variant = _decode_peer_id_array(
		snapshot.get("round_recipient_peer_ids")
	)
	var result_ack_ids: Variant = _decode_peer_id_array(
		snapshot.get("result_ack_peer_ids")
	)
	var resolved_node_ids: Variant = _decode_nonnegative_int_array(
		snapshot.get("resolved_node_ids")
	)
	var encountered_encounter_ids: Variant = _decode_encounter_id_array(
		snapshot.get("encountered_encounter_ids")
	)
	var disabled_option_ids: Variant = _decode_option_id_array(
		snapshot.get("disabled_option_ids"),
		decoded_encounter_id
	)
	if (
		participant_peer_ids == null
		or active_peer_ids == null
		or spectator_peer_ids == null
		or disconnected_peer_ids == null
		or intro_confirmed_ids == null
		or abstained_ids == null
		or round_recipient_ids == null
		or result_ack_ids == null
		or resolved_node_ids == null
		or encountered_encounter_ids == null
		or disabled_option_ids == null
	):
		return {}
	for peer_id in active_peer_ids as Array[int]:
		if not (participant_peer_ids as Array[int]).has(peer_id):
			return {}
	for peer_id in round_recipient_ids as Array[int]:
		if not (participant_peer_ids as Array[int]).has(peer_id):
			return {}
	for peer_id in result_ack_ids as Array[int]:
		if not (round_recipient_ids as Array[int]).has(peer_id):
			return {}
	var decoded_votes: Variant = _decode_votes(
		snapshot.get("votes"),
		participant_peer_ids as Array[int],
		decoded_encounter_id
	)
	if decoded_votes == null:
		return {}
	var decoded_result_pages: Variant = _decode_result_pages(
		snapshot.get("result_pages")
	)
	var decoded_personal_result_pages: Variant = _decode_personal_result_pages(
		snapshot.get("personal_result_pages"),
		participant_peer_ids as Array[int]
	)
	if decoded_result_pages == null:
		return {}
	if decoded_personal_result_pages == null:
		return {}
	var raw_economy_result: Variant = snapshot.get("economy_result")
	if typeof(raw_economy_result) != TYPE_DICTIONARY:
		return {}
	if (
		decoded_phase in [PHASE_RESULT, PHASE_COMPLETED]
		and (decoded_result_pages as Array[Dictionary]).is_empty()
		and not _result_presentation_is_immediate(
			raw_economy_result as Dictionary
		)
	):
		return {}
	if (
		typeof(snapshot.get("option_availability")) != TYPE_DICTIONARY
		or typeof(snapshot.get("economy_snapshot")) != TYPE_DICTIONARY
		or typeof(snapshot.get("settlement_committed")) != TYPE_BOOL
	):
		return {}
	var typed_encountered_ids: Array[StringName] = []
	typed_encountered_ids.assign(encountered_encounter_ids)
	if (
		_run_state != null
		and not _encounter_history_matches_economy_snapshot(
			typed_encountered_ids,
			snapshot["economy_snapshot"] as Dictionary
		)
	):
		return {}
	return {
		"revision": int(snapshot["revision"]),
		"phase": String(decoded_phase),
		"node_id": int(snapshot["node_id"]),
		"content_pool_id": str(snapshot.get("content_pool_id", "")),
		"node_content_seed": int(snapshot["node_content_seed"]),
		"occurrence_key": str(snapshot.get("occurrence_key", "")),
		"encounter_id": String(decoded_encounter_id),
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
		"result_pages": decoded_result_pages,
		"round_index": int(snapshot["round_index"]),
		"result_sequence": int(snapshot["result_sequence"]),
		"disabled_option_ids": disabled_option_ids,
		"round_recipient_peer_ids": round_recipient_ids,
		"result_ack_peer_ids": _int_array_to_dictionary(
			result_ack_ids as Array[int]
		),
		"terminal_result": bool(snapshot["terminal_result"]),
		"run_failed": bool(snapshot["run_failed"]),
		"personal_result_pages": decoded_personal_result_pages,
		"economy_snapshot": (
			snapshot["economy_snapshot"] as Dictionary
		).duplicate(true),
		"resolved_node_ids": _int_array_to_dictionary(
			resolved_node_ids as Array[int]
		),
		"encountered_encounter_ids": encountered_encounter_ids,
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


func _decode_votes(
	value: Variant,
	participants: Array[int],
	encounter_id: StringName
) -> Variant:
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
			or not RogueEncounterRegistry.is_valid_option(
				encounter_id,
				option_id
			)
		):
			return null
		result[peer_id] = option_id
	return result


func _decode_result_pages(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return null
	var raw_pages := value as Array
	if raw_pages.size() > MAX_RESULT_PAGE_COUNT:
		return null
	var result: Array[Dictionary] = []
	for raw_page_value in raw_pages:
		if typeof(raw_page_value) != TYPE_DICTIONARY:
			return null
		var page := raw_page_value as Dictionary
		if (
			typeof(page.get("speaker")) != TYPE_STRING
			or typeof(page.get("text")) != TYPE_STRING
			or str(page["text"]).is_empty()
			or typeof(page.get("is_narration")) != TYPE_BOOL
		):
			return null
		result.append({
			"speaker": str(page["speaker"]),
			"text": str(page["text"]),
			"is_narration": bool(page["is_narration"]),
		})
	return result


func _decode_personal_result_pages(
	value: Variant,
	participants: Array[int]
) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var result: Dictionary = {}
	for raw_peer_id in (value as Dictionary).keys():
		if typeof(raw_peer_id) != TYPE_INT:
			return null
		var peer_id := int(raw_peer_id)
		if not participants.has(peer_id) or result.has(peer_id):
			return null
		var decoded_pages: Variant = _decode_result_pages(
			(value as Dictionary)[raw_peer_id]
		)
		if decoded_pages == null:
			return null
		result[peer_id] = decoded_pages
	return result


func _decode_option_id_array(
	value: Variant,
	encounter_id: StringName
) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return null
	var result: Array[StringName] = []
	for raw_option_id in value as Array:
		if typeof(raw_option_id) != TYPE_STRING:
			return null
		var option_id := StringName(raw_option_id)
		if (
			result.has(option_id)
			or not RogueEncounterRegistry.is_valid_option(
				encounter_id,
				option_id
			)
		):
			return null
		result.append(option_id)
	result.sort()
	return result


func _decode_encounter_id_array(value: Variant) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return null
	var decoded: Array[StringName] = []
	for raw_encounter_id in value:
		if typeof(raw_encounter_id) != TYPE_STRING:
			return null
		var encounter_id := StringName(raw_encounter_id)
		if (
			decoded.has(encounter_id)
			or not RogueEncounterRegistry.has_encounter(encounter_id)
		):
			return null
		decoded.append(encounter_id)
	var canonical: Array[StringName] = []
	for encounter_id in RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	):
		if decoded.has(encounter_id):
			canonical.append(encounter_id)
	return canonical if canonical == decoded else null


func _encounter_history_matches_economy_snapshot(
	encounter_ids: Array[StringName],
	economy_snapshot: Dictionary
) -> bool:
	# 线路视图发送时会暂时清空经济字段；路由层在预检前会把独立经济包
	# 原子合回。Session 自身的空经济快照仍允许用于本地初始状态。
	if economy_snapshot.is_empty():
		return true
	var party_economy := economy_snapshot.get("party_economy", {}) as Dictionary
	var history_ledger := party_economy.get(
		"rogue_encounter_history_ledger",
		{}
	) as Dictionary
	var decoded: Variant = _decode_encounter_id_array(
		history_ledger.get("encounter_ids")
	)
	if decoded == null:
		return false
	var decoded_ids: Array[StringName] = []
	decoded_ids.assign(decoded)
	return decoded_ids == encounter_ids


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


func _string_name_array_to_strings(source: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in source:
		result.append(String(value))
	return result


func _build_common_result_pages(
	encounter_id: StringName,
	economy_result: Dictionary
) -> Array[Dictionary]:
	if economy_result.has("common_result_text"):
		var pages: Array[Dictionary] = []
		var common_result_text := str(
			economy_result.get("common_result_text", "")
		)
		var common_detail_text := str(
			economy_result.get("common_detail_text", "")
		)
		if not common_result_text.is_empty():
			pages.append(_make_result_page("", common_result_text, true))
		if not common_detail_text.is_empty():
			pages.append(_make_result_page("", common_detail_text, true))
		if not pages.is_empty():
			return pages
	return _build_result_pages(encounter_id, economy_result)


func _build_personal_result_pages(economy_result: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var raw_details: Variant = economy_result.get(
		"personal_detail_by_peer",
		{}
	)
	if typeof(raw_details) != TYPE_DICTIONARY:
		return result
	for raw_peer_id in (raw_details as Dictionary).keys():
		if typeof(raw_peer_id) != TYPE_INT:
			continue
		var peer_id := int(raw_peer_id)
		var detail_text := str((raw_details as Dictionary)[raw_peer_id])
		if peer_id < 0 or detail_text.is_empty():
			continue
		result[peer_id] = [_make_result_page("", detail_text, true)]
	return result


func _build_result_pages(
	encounter_id: StringName,
	economy_result: Dictionary
) -> Array[Dictionary]:
	var result_code := StringName(economy_result.get("result_code", &""))
	if encounter_id == RogueEncounterRegistry.CHICKEN_BRO:
		match result_code:
			RogueEncounterEconomyCoordinator.RESULT_GRANTED_PAID:
				return [_make_result_page("鸡哥", "一手交钱，一手交球。", false)]
			RogueEncounterEconomyCoordinator.RESULT_GRANTED_FREE:
				return [_make_result_page("鸡哥", "好吧，那就送你了。", false)]
			RogueEncounterEconomyCoordinator.RESULT_FREE_FAILED:
				return [_make_result_page("鸡哥", "哪有这么好的事情？", false)]
			RogueEncounterEconomyCoordinator.RESULT_ALL_INVENTORIES_FULL:
				return [_make_result_page(
					"",
					"所有玩家背包均已满，交易未完成。",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_INSUFFICIENT_PLANKS:
				return [_make_result_page("", "木板不足，交易未完成。", true)]
	elif encounter_id == RogueEncounterRegistry.SLIME_TALKERS:
		match result_code:
			RogueEncounterEconomyCoordinator.RESULT_SLIME_HELP_COLLECTIBLES:
				return [
					_make_result_page("史莱姆", "谢谢你，旅行者", false),
					_make_result_page(
						"",
						"史莱姆回礼了你随机的三件收藏品",
						true
					),
				]
			RogueEncounterEconomyCoordinator.RESULT_SLIME_HELP_XIRANG:
				return [
					_make_result_page("史莱姆", "谢谢你，旅行者", false),
					_make_result_page(
						"",
						"史莱姆回礼了你一些息壤水晶",
						true
					),
				]
			RogueEncounterEconomyCoordinator.RESULT_SLIME_INSUFFICIENT_WATER:
				return [_make_result_page(
					"",
					"水瓶不足，无法帮助这些史莱姆。",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_SLIME_KICK_INVENTORY:
				return [
					_make_result_page(
						"",
						"把史莱姆当做路边野狗一样踢死了",
						true
					),
					_make_result_page("", "获得了10份凝胶", true),
				]
			RogueEncounterEconomyCoordinator.RESULT_SLIME_KICK_WAREHOUSE:
				return [
					_make_result_page(
						"",
						"把史莱姆当做路边野狗一样踢死了",
						true
					),
					_make_result_page("", "获得了10份凝胶", true),
				]
			RogueEncounterEconomyCoordinator.RESULT_SLIME_KICK_DROPPED:
				return [
					_make_result_page(
						"",
						"把史莱姆当做路边野狗一样踢死了",
						true
					),
					_make_result_page(
						"",
						"背包与仓库已满，10份凝胶被丢弃了。",
						true
					),
				]
			RogueEncounterEconomyCoordinator.RESULT_SLIME_LEFT:
				return [_make_result_page(
					"",
					"真是一群神奇的生物，你记录了下来，然后便离开了",
					true
				)]
	elif encounter_id == RogueEncounterRegistry.GHOST_SHADOW:
		match result_code:
			RogueEncounterEconomyCoordinator.RESULT_GHOST_FLED:
				return [_make_result_page(
					"",
					"处于安全考虑，逃跑了",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_GHOST_VANISHED:
				return [_make_result_page(
					"",
					"鬼影什么也没有说，消失了",
					true
				)]
	elif encounter_id == RogueEncounterRegistry.SUITCASE_FRENZY:
		match result_code:
			RogueEncounterEconomyCoordinator.RESULT_SUITCASE_ROBOTS_ALERTED:
				return [_make_result_page(
					"",
					"机器人注意到了你！",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_SUITCASE_DESTROYED:
				return [_make_result_page(
					"",
					"皮箱很快就变得千疮百孔，什么都不剩下了。",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_SUITCASE_LEFT:
				return []
	elif encounter_id == RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER:
		match result_code:
			RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_STOMP_GEL, \
			RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_STOMP_WOOD:
				return [_make_result_page(
					"",
					str(economy_result.get("reward_text", "")),
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_STOMP_DROPPED:
				return [_make_result_page(
					"",
					"没有玩家的背包能装下材料，踩死海参后得到的材料被丢弃了。",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_TECHNIQUE:
				return [
					_make_result_page(
						"",
						"海参十分高兴，传授了你一些技术",
						true
					),
					_make_result_page(
						"",
						"所有玩家的冲刺冷却时间缩短1秒，攻击力+10",
						true
					),
				]
			RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_FEAST:
				return [_make_result_page(
					"",
					"每个玩家获得了一个海参",
					true
				)]
			RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_PARTY_INVENTORY_FULL:
				return [_make_result_page(
					"",
					"有玩家的背包没有空位，无法分发海参。",
					true
				)]
	var definition := RogueEncounterRegistry.get_definition(encounter_id)
	return [_make_result_page(
		str(definition.get("default_result_speaker", "")),
		"遭遇已经结束。",
		bool(definition.get("default_result_is_narration", true))
	)]


func _make_result_page(
	speaker: String,
	text: String,
	is_narration: bool
) -> Dictionary:
	return {
		"speaker": speaker,
		"text": text,
		"is_narration": is_narration,
	}


func _get_result_text() -> String:
	if _result_pages.is_empty():
		return ""
	return str(_result_pages[_result_pages.size() - 1].get("text", ""))


func _result_presentation_is_immediate(economy_result: Dictionary) -> bool:
	return StringName(economy_result.get("result_presentation", &"")) == (
		RogueEncounterEconomyCoordinator.RESULT_PRESENTATION_IMMEDIATE
	)


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
