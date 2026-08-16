extends RefCounted
class_name RogueEmergencyRewardSelectionSession

## 紧急作战胜利后的权威奖励选择状态机。
##
## 会话只保存可序列化数据；候选与超时选择均由 content seed、occurrence、
## 稳定玩家身份及奖励合同确定。选择阶段仅做整批奖励容量预检，所有奖励在
## complete_rewards() 中通过一次 Party Economy CAS 提交，避免半结算。

signal state_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 1

const PHASE_IDLE := &"idle"
const PHASE_CHOOSING := &"choosing"
const PHASE_READY := &"ready"
const PHASE_SETTLED := &"settled"

const REASON_NONE := &""
const REASON_INVALID_REQUEST := &"invalid_request"
const REASON_STALE_ROUND := &"stale_round"
const REASON_INVALID_OFFER := &"invalid_offer"
const REASON_INVENTORY_FULL := &"inventory_full"
const REASON_TIMEOUT_CHOICE_LOCKED := &"timeout_choice_locked"
const REASON_PEER_DISCONNECTED := &"peer_disconnected"
const REASON_NOT_READY := &"not_ready"

var _run_state: RunStateStore = null
var _reward_config: RogueCombatRewardConfig = null
var _is_authority := false
var _revision := 0
var _phase: StringName = PHASE_IDLE
var _occurrence_id: StringName = &""
var _content_seed := 0
var _filter_by_player_compatibility := false
var _participant_peer_ids: Array[int] = []
var _peer_states: Dictionary = {}
var _extra_xirang := 0
var _random_item_path := ""
var _random_item_count := 0
var _shared_light_stone_reward := 0
var _settlement_result: Dictionary = {}


func begin_authority(
	run_state: RunStateStore,
	occurrence_id: StringName,
	content_seed: int,
	peer_ids: Array[int],
	reward_config: RogueCombatRewardConfig,
	filter_by_player_compatibility: bool,
	stable_keys_by_peer: Dictionary,
	character_ids_by_peer: Dictionary,
	base_xirang_by_peer: Dictionary
) -> bool:
	_reset()
	if (
		run_state == null
		or occurrence_id == &""
		or reward_config == null
		or not reward_config.validate_config().is_empty()
		or not reward_config.uses_collectible_choices()
		or not reward_config.uses_random_item_reward()
	):
		return false
	var ordered_peer_ids := _normalize_peer_ids(peer_ids)
	if ordered_peer_ids.size() != peer_ids.size() or ordered_peer_ids.is_empty():
		return false
	var offer_result := RogueCombatRewardResolver.build_emergency_collectible_offers(
		occurrence_id,
		content_seed,
		ordered_peer_ids,
		reward_config,
		filter_by_player_compatibility,
		stable_keys_by_peer,
		character_ids_by_peer
	)
	if not bool(offer_result.get("resolved", false)):
		return false
	var random_item := RogueCombatRewardResolver.roll_random_item_reward(
		occurrence_id,
		content_seed,
		reward_config
	)
	if random_item == null:
		return false

	var offers_by_peer := offer_result.get("offers_by_peer", {}) as Dictionary
	var states: Dictionary = {}
	for peer_id in ordered_peer_ids:
		var identity := str(stable_keys_by_peer.get(
			peer_id,
			stable_keys_by_peer.get(str(peer_id), "")
		)).strip_edges()
		var character_id := StringName(character_ids_by_peer.get(
			peer_id,
			character_ids_by_peer.get(str(peer_id), &"")
		))
		var base_xirang_value: Variant = base_xirang_by_peer.get(
			peer_id,
			base_xirang_by_peer.get(str(peer_id), null)
		)
		if (
			identity.is_empty()
			or typeof(base_xirang_value) != TYPE_INT
			or int(base_xirang_value) < 0
			or not offers_by_peer.has(peer_id)
		):
			_reset()
			return false
		if peer_id > 0 and not run_state.has_multiplayer_peer_state(peer_id):
			# 奖励选择只绑定认证 roster，不能借由一次奖励会话创建持久成员。
			_reset()
			return false
		states[peer_id] = {
			"peer_id": peer_id,
			"stable_identity": identity,
			"character_id": String(character_id),
			"base_xirang": int(base_xirang_value),
			"rounds": (offers_by_peer[peer_id] as Array).duplicate(true),
			"selected_paths": [] as Array[String],
			"round_index": 0,
			"remaining_seconds": reward_config.collectible_choice_seconds_per_round,
			"timeout_choice_index": -1,
			"disconnected": false,
			"completed": false,
		}

	_run_state = run_state
	_reward_config = reward_config
	_is_authority = true
	_revision = 1
	_phase = PHASE_CHOOSING
	_occurrence_id = occurrence_id
	_content_seed = content_seed
	_filter_by_player_compatibility = filter_by_player_compatibility
	_participant_peer_ids = ordered_peer_ids
	_peer_states = states
	_extra_xirang = reward_config.roll_xirang(content_seed, occurrence_id)
	_random_item_path = random_item.resource_path
	_random_item_count = reward_config.random_item_reward_count
	_shared_light_stone_reward = reward_config.shared_light_stone_reward
	state_changed.emit(export_state())
	return true


func reset_remote(reward_config: RogueCombatRewardConfig) -> bool:
	_reset()
	if reward_config == null or not reward_config.validate_config().is_empty():
		return false
	_reward_config = reward_config
	return true


func restore_authority(
	run_state: RunStateStore,
	reward_config: RogueCombatRewardConfig,
	snapshot: Dictionary
) -> bool:
	_reset()
	if run_state == null or reward_config == null:
		return false
	_reward_config = reward_config
	var prepared := _decode_snapshot(snapshot)
	if prepared.is_empty():
		_reset()
		return false
	_run_state = run_state
	_is_authority = true
	_apply_prepared_snapshot(prepared)
	for peer_id in _participant_peer_ids:
		if peer_id > 0 and not _run_state.has_multiplayer_peer_state(peer_id):
			_reset()
			return false
	return true


func apply_snapshot(snapshot: Dictionary) -> bool:
	if _reward_config == null:
		return false
	var prepared := _decode_snapshot(snapshot)
	if prepared.is_empty() or int(prepared.get("revision", -1)) < _revision:
		return false
	_apply_prepared_snapshot(prepared)
	return true


func is_configured() -> bool:
	return _reward_config != null and _phase != PHASE_IDLE


func is_authority() -> bool:
	return _is_authority


func get_revision() -> int:
	return _revision


func get_phase() -> StringName:
	return _phase


func is_choosing() -> bool:
	return _phase == PHASE_CHOOSING


func is_ready_to_settle() -> bool:
	return _phase == PHASE_READY


func is_settled() -> bool:
	return _phase == PHASE_SETTLED


func get_participant_peer_ids() -> Array[int]:
	return _participant_peer_ids.duplicate()


func get_extra_xirang() -> int:
	return _extra_xirang


func get_random_item_path() -> String:
	return _random_item_path


func get_random_item_count() -> int:
	return _random_item_count


func get_shared_light_stone_reward() -> int:
	return _shared_light_stone_reward


func get_peer_state(peer_id: int) -> Dictionary:
	if not _peer_states.has(peer_id):
		return {}
	return (_peer_states[peer_id] as Dictionary).duplicate(true)


func get_current_offer_paths(peer_id: int) -> Array[String]:
	if not _peer_states.has(peer_id):
		return []
	var state := _peer_states[peer_id] as Dictionary
	if bool(state.get("completed", false)):
		return []
	var round_index := int(state.get("round_index", -1))
	var rounds := state.get("rounds", []) as Array
	if round_index < 0 or round_index >= rounds.size():
		return []
	var result: Array[String] = []
	for raw_path in (rounds[round_index] as Dictionary).get("paths", []) as Array:
		result.append(str(raw_path))
	return result


func submit_choice(
	peer_id: int,
	occurrence_id: String,
	round_index: int,
	offer_index: int
) -> Dictionary:
	if (
		not _is_authority
		or _phase != PHASE_CHOOSING
		or occurrence_id != String(_occurrence_id)
		or not _peer_states.has(peer_id)
	):
		return _make_choice_result(false, REASON_INVALID_REQUEST, peer_id)
	var state := _peer_states[peer_id] as Dictionary
	if bool(state.get("disconnected", false)):
		return _make_choice_result(false, REASON_PEER_DISCONNECTED, peer_id)
	if int(state.get("round_index", -1)) != round_index:
		return _make_choice_result(false, REASON_STALE_ROUND, peer_id)
	return _try_accept_choice(peer_id, offer_index)


func retry_timeout_choice(peer_id: int, occurrence_id: String) -> Dictionary:
	if (
		not _is_authority
		or _phase != PHASE_CHOOSING
		or occurrence_id != String(_occurrence_id)
		or not _peer_states.has(peer_id)
	):
		return _make_choice_result(false, REASON_INVALID_REQUEST, peer_id)
	var state := _peer_states[peer_id] as Dictionary
	var timeout_choice_index := int(state.get("timeout_choice_index", -1))
	if timeout_choice_index < 0:
		return _make_choice_result(false, REASON_INVALID_REQUEST, peer_id)
	return _try_accept_choice(peer_id, timeout_choice_index)


## 推进每名在线玩家自己的逐轮30秒倒计时。一次较大的 delta 可跨过两轮；
## 若超时自动项因容量不足未通过，则锁定该项并停在当前轮等待整理重试。
func advance(delta: float) -> bool:
	if not _is_authority or _phase != PHASE_CHOOSING or delta <= 0.0:
		return false
	var timer_changed := false
	var choice_changed := false
	for peer_id in _participant_peer_ids:
		var state := _peer_states[peer_id] as Dictionary
		if bool(state.get("completed", false)):
			continue
		# 满包后已经锁定的手动/超时项必须由玩家整理背包后显式重试；
		# authority 仍继续推进其他在线玩家，但不会在后台悄悄替其领奖。
		if (
			int(state.get("timeout_choice_index", -1)) >= 0
			and float(state.get("remaining_seconds", 0.0)) <= 0.0
		):
			continue
		var remaining_delta := delta
		while remaining_delta > 0.0 and not bool(state.get("completed", false)):
			var remaining := maxf(float(state.get("remaining_seconds", 0.0)), 0.0)
			if remaining_delta < remaining:
				var before_second := ceili(remaining)
				remaining -= remaining_delta
				state["remaining_seconds"] = remaining
				timer_changed = timer_changed or ceili(remaining) != before_second
				remaining_delta = 0.0
				continue
			remaining_delta = maxf(remaining_delta - remaining, 0.0)
			state["remaining_seconds"] = 0.0
			timer_changed = true
			if int(state.get("timeout_choice_index", -1)) < 0:
				state["timeout_choice_index"] = (
					RogueCombatRewardResolver.select_emergency_timeout_offer_index(
						_occurrence_id,
						_content_seed,
						str(state.get("stable_identity", "")),
						int(state.get("round_index", 0)),
						_reward_config
					)
				)
			var result := _try_accept_choice(
				peer_id,
				int(state.get("timeout_choice_index", -1))
			)
			if not bool(result.get("accepted", false)):
				remaining_delta = 0.0
			else:
				choice_changed = true
			state = _peer_states[peer_id] as Dictionary
	if timer_changed and not choice_changed:
		_bump_revision()
	return timer_changed or choice_changed


func mark_peer_disconnected(peer_id: int, occurrence_id: String) -> bool:
	if (
		not _is_authority
		or _phase not in [PHASE_CHOOSING, PHASE_READY]
		or occurrence_id != String(_occurrence_id)
		or not _peer_states.has(peer_id)
	):
		return false
	var state := _peer_states[peer_id] as Dictionary
	if bool(state.get("completed", false)):
		if bool(state.get("disconnected", false)):
			return true
		# 已完成两轮但仍在等队友时断线，也必须冻结为断线完成态。保留已选
		# 路径仅用于快照审计；最终结算会放弃尚未入包的全部物品。
		state["disconnected"] = true
		_bump_revision()
		return true
	state["remaining_seconds"] = 0.0
	state["timeout_choice_index"] = -1
	state["disconnected"] = true
	state["completed"] = true
	_update_phase_after_choice()
	_bump_revision()
	return true


## 重连后可把已弃权玩家迁移到新的传输 peer。迁移只改变息壤结果的归属，
## 保留稳定身份、既有选择及弃权完成状态，因此不会重新开放选择或补领物品。
func remap_disconnected_peer(old_peer_id: int, new_peer_id: int) -> bool:
	if (
		not _is_authority
		or _phase not in [PHASE_CHOOSING, PHASE_READY]
		or old_peer_id < 0
		or new_peer_id < 0
		or old_peer_id == new_peer_id
		or not _peer_states.has(old_peer_id)
		or _peer_states.has(new_peer_id)
		or _run_state == null
		or (
			new_peer_id > 0
			and not _run_state.has_multiplayer_peer_state(new_peer_id)
		)
	):
		return false
	var state := _peer_states[old_peer_id] as Dictionary
	if (
		not bool(state.get("disconnected", false))
		or not bool(state.get("completed", false))
	):
		return false
	_peer_states.erase(old_peer_id)
	state["peer_id"] = new_peer_id
	_peer_states[new_peer_id] = state
	_participant_peer_ids.erase(old_peer_id)
	_participant_peer_ids.append(new_peer_id)
	_participant_peer_ids.sort()
	_bump_revision()
	return true


func complete_rewards() -> Dictionary:
	if not _is_authority or _run_state == null:
		return _make_completion_failure(REASON_INVALID_REQUEST)
	if _phase == PHASE_SETTLED:
		return _settlement_result.duplicate(true)
	if _phase != PHASE_READY:
		return _make_completion_failure(REASON_NOT_READY)
	var stable_keys: Dictionary = {}
	var character_ids: Dictionary = {}
	var base_xirang: Dictionary = {}
	var selected_paths: Dictionary = {}
	var forfeited_peer_ids: Array[int] = []
	for peer_id in _participant_peer_ids:
		var state := _peer_states[peer_id] as Dictionary
		stable_keys[peer_id] = str(state.get("stable_identity", ""))
		character_ids[peer_id] = StringName(state.get("character_id", ""))
		base_xirang[peer_id] = int(state.get("base_xirang", 0))
		selected_paths[peer_id] = (
			state.get("selected_paths", []) as Array
		).duplicate()
		if bool(state.get("disconnected", false)):
			forfeited_peer_ids.append(peer_id)
	var result := RogueCombatRewardResolver.commit_emergency_party_rewards(
		_run_state,
		_occurrence_id,
		_content_seed,
		_participant_peer_ids,
		_reward_config,
		_filter_by_player_compatibility,
		stable_keys,
		character_ids,
		base_xirang,
		selected_paths,
		forfeited_peer_ids
	)
	if not bool(result.get("resolved", false)):
		return result
	_settlement_result = result.duplicate(true)
	_phase = PHASE_SETTLED
	_bump_revision()
	return result


func export_state() -> Dictionary:
	if not is_configured():
		return {}
	var participants: Array[Dictionary] = []
	for peer_id in _participant_peer_ids:
		var participant := (
			_peer_states[peer_id] as Dictionary
		).duplicate(true)
		var completed := bool(participant.get("completed", false))
		var round_index := int(participant.get("round_index", 0))
		var rounds := participant.get("rounds", []) as Array
		var current_offers: Array[String] = []
		if not completed and round_index >= 0 and round_index < rounds.size():
			for raw_path in (
				(rounds[round_index] as Dictionary).get("paths", []) as Array
			):
				current_offers.append(str(raw_path))
		participant["current_round_index"] = round_index
		participant["current_offer_paths"] = current_offers
		participant["deadline_seconds_remaining"] = float(
			participant.get("remaining_seconds", 0.0)
		)
		participant["forfeited"] = bool(
			participant.get("disconnected", false)
		)
		participant["complete"] = completed
		participants.append(participant)
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _revision,
		"phase": String(_phase),
		"occurrence_id": String(_occurrence_id),
		"content_seed": _content_seed,
		"reward_contract_hash": _reward_config.compute_runtime_contract_hash(),
		"filter_by_player_compatibility": _filter_by_player_compatibility,
		"extra_xirang": _extra_xirang,
		"random_item_path": _random_item_path,
		"random_item_count": _random_item_count,
		"shared_light_stone_reward": _shared_light_stone_reward,
		"participants": participants,
		"settlement_result": _settlement_result.duplicate(true),
	}


func _try_accept_choice(peer_id: int, offer_index: int) -> Dictionary:
	var state := _peer_states[peer_id] as Dictionary
	if bool(state.get("completed", false)):
		return _make_choice_result(false, REASON_INVALID_REQUEST, peer_id)
	var round_index := int(state.get("round_index", -1))
	var rounds := state.get("rounds", []) as Array
	if round_index < 0 or round_index >= rounds.size():
		return _make_choice_result(false, REASON_STALE_ROUND, peer_id)
	var paths := (rounds[round_index] as Dictionary).get("paths", []) as Array
	if offer_index < 0 or offer_index >= paths.size():
		return _make_choice_result(false, REASON_INVALID_OFFER, peer_id)
	var locked_index := int(state.get("timeout_choice_index", -1))
	if locked_index >= 0 and offer_index != locked_index:
		return _make_choice_result(
			false,
			REASON_TIMEOUT_CHOICE_LOCKED,
			peer_id
		)
	var selected_paths: Array[String] = []
	for raw_path in state.get("selected_paths", []) as Array:
		selected_paths.append(str(raw_path))
	var selected_path := str(paths[offer_index])
	selected_paths.append(selected_path)
	var random_item := load(_random_item_path) as PickupConfig
	var preflight := RogueCombatRewardResolver.preflight_emergency_peer_rewards(
		_run_state,
		peer_id,
		selected_paths,
		random_item,
		_random_item_count
	)
	if not bool(preflight.get("can_commit", false)):
		var reason := StringName(preflight.get(
			"failure_reason",
			REASON_INVENTORY_FULL
		))
		if (
			reason == REASON_INVENTORY_FULL
			and (
				int(state.get("timeout_choice_index", -1)) != offer_index
				or float(state.get("remaining_seconds", 0.0)) != 0.0
			)
		):
			state["timeout_choice_index"] = offer_index
			state["remaining_seconds"] = 0.0
			_bump_revision()
		return _make_choice_result(false, reason, peer_id)
	state["selected_paths"] = selected_paths
	state["round_index"] = round_index + 1
	state["timeout_choice_index"] = -1
	if int(state["round_index"]) >= _reward_config.collectible_choice_round_count:
		state["remaining_seconds"] = 0.0
		state["completed"] = true
	else:
		state["remaining_seconds"] = (
			_reward_config.collectible_choice_seconds_per_round
		)
	_update_phase_after_choice()
	_bump_revision()
	var result := _make_choice_result(true, REASON_NONE, peer_id)
	result["selected_path"] = selected_path
	result["selected_round_index"] = round_index
	result["next_round_index"] = int(state.get("round_index", 0))
	return result


func _update_phase_after_choice() -> void:
	if _phase != PHASE_CHOOSING:
		return
	for peer_id in _participant_peer_ids:
		if not bool((_peer_states[peer_id] as Dictionary).get("completed", false)):
			return
	_phase = PHASE_READY


func _bump_revision() -> void:
	_revision += 1
	state_changed.emit(export_state())


func _decode_snapshot(snapshot: Dictionary) -> Dictionary:
	if (
		_reward_config == null
		or int(snapshot.get("schema_version", -1)) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot.get("revision", -1)) < 1
		or typeof(snapshot.get("phase")) != TYPE_STRING
		or typeof(snapshot.get("occurrence_id")) != TYPE_STRING
		or str(snapshot.get("occurrence_id", "")).is_empty()
		or typeof(snapshot.get("content_seed")) != TYPE_INT
		or typeof(snapshot.get("reward_contract_hash")) != TYPE_STRING
		or str(snapshot.get("reward_contract_hash", ""))
		!= _reward_config.compute_runtime_contract_hash()
		or typeof(snapshot.get("filter_by_player_compatibility")) != TYPE_BOOL
		or typeof(snapshot.get("participants")) != TYPE_ARRAY
		or typeof(snapshot.get("settlement_result")) != TYPE_DICTIONARY
	):
		return {}
	var phase := StringName(snapshot.get("phase", ""))
	if phase not in [PHASE_CHOOSING, PHASE_READY, PHASE_SETTLED]:
		return {}
	var occurrence_id := StringName(snapshot.get("occurrence_id", ""))
	var content_seed := int(snapshot.get("content_seed", 0))
	var filter_by_compatibility := bool(
		snapshot.get("filter_by_player_compatibility", false)
	)
	var peer_ids: Array[int] = []
	var raw_states_by_peer: Dictionary = {}
	var stable_keys: Dictionary = {}
	var character_ids: Dictionary = {}
	for raw_state_value in snapshot.get("participants", []) as Array:
		if typeof(raw_state_value) != TYPE_DICTIONARY:
			return {}
		var raw_state := raw_state_value as Dictionary
		var peer_id := int(raw_state.get("peer_id", -1))
		var identity := str(raw_state.get("stable_identity", "")).strip_edges()
		if (
			peer_id < 0
			or peer_ids.has(peer_id)
			or identity.is_empty()
			or stable_keys.values().has(identity)
		):
			return {}
		peer_ids.append(peer_id)
		raw_states_by_peer[peer_id] = raw_state
		stable_keys[peer_id] = identity
		character_ids[peer_id] = StringName(raw_state.get("character_id", ""))
	peer_ids.sort()
	if peer_ids.is_empty():
		return {}
	var offer_result := RogueCombatRewardResolver.build_emergency_collectible_offers(
		occurrence_id,
		content_seed,
		peer_ids,
		_reward_config,
		filter_by_compatibility,
		stable_keys,
		character_ids
	)
	if not bool(offer_result.get("resolved", false)):
		return {}
	var expected_offers := offer_result.get("offers_by_peer", {}) as Dictionary
	var random_item := RogueCombatRewardResolver.roll_random_item_reward(
		occurrence_id,
		content_seed,
		_reward_config
	)
	if (
		random_item == null
		or typeof(snapshot.get("extra_xirang")) != TYPE_INT
		or int(snapshot.get("extra_xirang", -1))
		!= _reward_config.roll_xirang(content_seed, occurrence_id)
		or typeof(snapshot.get("random_item_path")) != TYPE_STRING
		or str(snapshot.get("random_item_path", "")) != random_item.resource_path
		or typeof(snapshot.get("random_item_count")) != TYPE_INT
		or int(snapshot.get("random_item_count", -1))
		!= _reward_config.random_item_reward_count
		or typeof(snapshot.get("shared_light_stone_reward")) != TYPE_INT
		or int(snapshot.get("shared_light_stone_reward", -1))
		!= _reward_config.shared_light_stone_reward
	):
		return {}

	var prepared_states: Dictionary = {}
	var all_completed := true
	for peer_id in peer_ids:
		var raw_state := raw_states_by_peer[peer_id] as Dictionary
		if (
			typeof(raw_state.get("base_xirang")) != TYPE_INT
			or int(raw_state.get("base_xirang", -1)) < 0
			or typeof(raw_state.get("rounds")) != TYPE_ARRAY
			or raw_state.get("rounds", []) != expected_offers[peer_id]
			or typeof(raw_state.get("selected_paths")) != TYPE_ARRAY
			or typeof(raw_state.get("round_index")) != TYPE_INT
			or typeof(raw_state.get("remaining_seconds"))
			not in [TYPE_INT, TYPE_FLOAT]
			or typeof(raw_state.get("timeout_choice_index")) != TYPE_INT
			or typeof(raw_state.get("disconnected")) != TYPE_BOOL
			or typeof(raw_state.get("completed")) != TYPE_BOOL
		):
			return {}
		var selected_paths: Array[String] = []
		var seen_paths: Dictionary = {}
		var raw_selected := raw_state.get("selected_paths", []) as Array
		if raw_selected.size() > _reward_config.collectible_choice_round_count:
			return {}
		for round_index in range(raw_selected.size()):
			if typeof(raw_selected[round_index]) != TYPE_STRING:
				return {}
			var config_path := str(raw_selected[round_index])
			var round_paths := (
				(expected_offers[peer_id] as Array)[round_index] as Dictionary
			).get("paths", []) as Array
			if config_path not in round_paths or seen_paths.has(config_path):
				return {}
			selected_paths.append(config_path)
			seen_paths[config_path] = true
		var completed := bool(raw_state.get("completed", false))
		var disconnected := bool(raw_state.get("disconnected", false))
		var round_index := int(raw_state.get("round_index", -1))
		var remaining_seconds := float(raw_state.get("remaining_seconds", -1.0))
		var timeout_choice_index := int(
			raw_state.get("timeout_choice_index", -2)
		)
		if (
			round_index != selected_paths.size()
			or round_index < 0
			or round_index > _reward_config.collectible_choice_round_count
			or remaining_seconds < 0.0
			or remaining_seconds
			> _reward_config.collectible_choice_seconds_per_round
			or timeout_choice_index < -1
			or timeout_choice_index
			>= _reward_config.collectible_choice_offer_count
			or (disconnected and not completed)
			or (
				completed
				and not disconnected
				and round_index
				!= _reward_config.collectible_choice_round_count
			)
			or (not completed and round_index >= _reward_config.collectible_choice_round_count)
			or (completed and remaining_seconds != 0.0)
		):
			return {}
		all_completed = all_completed and completed
		prepared_states[peer_id] = {
			"peer_id": peer_id,
			"stable_identity": str(stable_keys[peer_id]),
			"character_id": String(character_ids[peer_id]),
			"base_xirang": int(raw_state.get("base_xirang", 0)),
			"rounds": (expected_offers[peer_id] as Array).duplicate(true),
			"selected_paths": selected_paths,
			"round_index": round_index,
			"remaining_seconds": remaining_seconds,
			"timeout_choice_index": timeout_choice_index,
			"disconnected": disconnected,
			"completed": completed,
		}
	if (
		(phase == PHASE_CHOOSING and all_completed)
		or (phase in [PHASE_READY, PHASE_SETTLED] and not all_completed)
		or (
			phase == PHASE_SETTLED
			and not bool(
				(snapshot.get("settlement_result", {}) as Dictionary).get(
					"resolved",
					false
				)
			)
		)
		or (
			phase != PHASE_SETTLED
			and not (snapshot.get("settlement_result", {}) as Dictionary).is_empty()
		)
	):
		return {}
	return {
		"revision": int(snapshot.get("revision", 1)),
		"phase": phase,
		"occurrence_id": occurrence_id,
		"content_seed": content_seed,
		"filter_by_player_compatibility": filter_by_compatibility,
		"participant_peer_ids": peer_ids,
		"peer_states": prepared_states,
		"extra_xirang": int(snapshot.get("extra_xirang", 0)),
		"random_item_path": random_item.resource_path,
		"random_item_count": int(snapshot.get("random_item_count", 0)),
		"shared_light_stone_reward": int(
			snapshot.get("shared_light_stone_reward", 0)
		),
		"settlement_result": (
			snapshot.get("settlement_result", {}) as Dictionary
		).duplicate(true),
	}


func _apply_prepared_snapshot(prepared: Dictionary) -> void:
	_revision = int(prepared.get("revision", 0))
	_phase = StringName(prepared.get("phase", PHASE_IDLE))
	_occurrence_id = StringName(prepared.get("occurrence_id", ""))
	_content_seed = int(prepared.get("content_seed", 0))
	_filter_by_player_compatibility = bool(
		prepared.get("filter_by_player_compatibility", false)
	)
	_participant_peer_ids.assign(
		prepared.get("participant_peer_ids", []) as Array
	)
	_peer_states = (
		prepared.get("peer_states", {}) as Dictionary
	).duplicate(true)
	_extra_xirang = int(prepared.get("extra_xirang", 0))
	_random_item_path = str(prepared.get("random_item_path", ""))
	_random_item_count = int(prepared.get("random_item_count", 0))
	_shared_light_stone_reward = int(
		prepared.get("shared_light_stone_reward", 0)
	)
	_settlement_result = (
		prepared.get("settlement_result", {}) as Dictionary
	).duplicate(true)


func _make_choice_result(
	accepted: bool,
	reason: StringName,
	peer_id: int
) -> Dictionary:
	var round_index := -1
	if _peer_states.has(peer_id):
		round_index = int(
			(_peer_states[peer_id] as Dictionary).get("round_index", -1)
		)
	return {
		"accepted": accepted,
		"reason": reason,
		"failure_reason": reason,
		"peer_id": peer_id,
		"round_index": round_index,
		"phase": String(_phase),
		"revision": _revision,
	}


func _make_completion_failure(reason: StringName) -> Dictionary:
	return {
		"resolved": false,
		"failure_reason": reason,
	}


func _normalize_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id < 0 or result.has(peer_id):
			continue
		result.append(peer_id)
	result.sort()
	return result


func _reset() -> void:
	_run_state = null
	_reward_config = null
	_is_authority = false
	_revision = 0
	_phase = PHASE_IDLE
	_occurrence_id = &""
	_content_seed = 0
	_filter_by_player_compatibility = false
	_participant_peer_ids.clear()
	_peer_states.clear()
	_extra_xirang = 0
	_random_item_path = ""
	_random_item_count = 0
	_shared_light_stone_reward = 0
	_settlement_result.clear()
