extends Node
class_name TowerDefenseFateManager

signal state_changed(state: Dictionary)
signal resolution_requested(option_id: StringName, permanent_buff_id: StringName)
signal interlude_completed(next_step_id: StringName)

const STAGE_WAIT_INTERACTIONS := &"wait_interactions"
const STAGE_VOTING := &"voting"
const STAGE_CRITICAL_BUFF_VOTING := &"critical_buff_voting"
const STAGE_RESOLVING := &"resolving"
const STAGE_RESOLVED := &"resolved"
const STAGE_COLLECTIBLE_REWARD := &"collectible_reward"
const FATE_OPTION_OFFER_COUNT := 3
const PERMANENT_BUFF_OFFER_COUNT := 3
const RESULT_DISPLAY_SECONDS := 1.15
const KNOWN_STAGES: Array[StringName] = [
	STAGE_WAIT_INTERACTIONS,
	STAGE_VOTING,
	STAGE_CRITICAL_BUFF_VOTING,
	STAGE_RESOLVING,
	STAGE_RESOLVED,
	STAGE_COLLECTIBLE_REWARD,
]

@export_range(5.0, 300.0, 1.0) var interaction_timeout_seconds := 45.0
@export_range(5.0, 300.0, 1.0) var voting_timeout_seconds := 60.0

var active := false
var completed_day := 0
var next_step_id: StringName = &""
var stage: StringName = STAGE_WAIT_INTERACTIONS
var host_peer_id := 0
var eligible_peer_ids: Array[int] = []
var interacted_peer_ids: Array[int] = []
var votes: Dictionary = {}
var permanent_buff_votes: Dictionary = {}
var available_option_ids: Array[StringName] = []
var available_permanent_buff_ids: Array[StringName] = []
var permanent_buff_offer: Array[StringName] = []
var collectible_offers: Dictionary = {}
var collectible_claimed_peer_ids: Array[int] = []
var collectible_status_by_peer: Dictionary = {}
var winning_option_id: StringName = &""
var winning_permanent_buff_id: StringName = &""
var stage_time_remaining := 0.0
var timeout_recovery_available := false
var state_revision := 0
var random_generator := RandomNumberGenerator.new()
var _finish_generation := 0


func _ready() -> void:
	random_generator.randomize()


func begin_interlude(
	day_number: int,
	resume_step_id: StringName,
	peer_ids: Array[int],
	new_host_peer_id: int,
	option_ids: Array[StringName],
	permanent_buff_ids: Array[StringName]
) -> void:
	active = true
	completed_day = maxi(day_number, 1)
	next_step_id = resume_step_id
	host_peer_id = new_host_peer_id
	eligible_peer_ids = _normalized_peer_ids(peer_ids)
	available_permanent_buff_ids = _normalized_buff_ids(permanent_buff_ids)
	available_option_ids = _roll_fate_option_offer(
		_normalized_option_ids(option_ids)
	)
	interacted_peer_ids.clear()
	votes.clear()
	permanent_buff_votes.clear()
	collectible_offers.clear()
	collectible_claimed_peer_ids.clear()
	collectible_status_by_peer.clear()
	winning_option_id = &""
	winning_permanent_buff_id = &""
	_finish_generation += 1
	_roll_permanent_buff_offer()
	_set_stage(STAGE_WAIT_INTERACTIONS)
	if eligible_peer_ids.is_empty() or available_option_ids.is_empty():
		force_finish()
		return
	_emit_state()


func record_interaction(peer_id: int) -> bool:
	if not active or stage != STAGE_WAIT_INTERACTIONS:
		return false
	if not eligible_peer_ids.has(peer_id):
		return false
	if not interacted_peer_ids.has(peer_id):
		interacted_peer_ids.append(peer_id)
		interacted_peer_ids.sort()
	if interacted_peer_ids.size() >= eligible_peer_ids.size():
		_set_stage(STAGE_VOTING)
	_emit_state()
	return true


func advance_stage_timeout(delta: float) -> void:
	if (
		not active
		or stage not in [
			STAGE_WAIT_INTERACTIONS,
			STAGE_VOTING,
			STAGE_CRITICAL_BUFF_VOTING,
		]
	):
		return
	if timeout_recovery_available:
		return
	var previous_display_seconds := ceili(stage_time_remaining)
	stage_time_remaining = maxf(stage_time_remaining - maxf(delta, 0.0), 0.0)
	if stage_time_remaining <= 0.0:
		timeout_recovery_available = true
	if timeout_recovery_available or ceili(stage_time_remaining) != previous_display_seconds:
		_emit_state()


func can_host_recover(peer_id: int) -> bool:
	return (
		active
		and timeout_recovery_available
		and peer_id == host_peer_id
		and stage in [
			STAGE_WAIT_INTERACTIONS,
			STAGE_VOTING,
			STAGE_CRITICAL_BUFF_VOTING,
		]
	)


func request_timeout_recovery(peer_id: int) -> bool:
	if not can_host_recover(peer_id):
		return false
	match stage:
		STAGE_WAIT_INTERACTIONS:
			interacted_peer_ids = eligible_peer_ids.duplicate()
			_set_stage(STAGE_VOTING)
			_emit_state()
		STAGE_VOTING:
			_fill_missing_votes_for_host_recovery()
			_resolve_vote()
		STAGE_CRITICAL_BUFF_VOTING:
			_fill_missing_critical_buff_votes_for_host_recovery()
			_resolve_critical_buff_vote()
	return true


func remove_eligible_peer(peer_id: int) -> bool:
	if not active or not eligible_peer_ids.has(peer_id):
		return false
	eligible_peer_ids.erase(peer_id)
	interacted_peer_ids.erase(peer_id)
	votes.erase(peer_id)
	permanent_buff_votes.erase(peer_id)
	collectible_offers.erase(peer_id)
	collectible_claimed_peer_ids.erase(peer_id)
	collectible_status_by_peer.erase(peer_id)

	if eligible_peer_ids.is_empty():
		force_finish()
		return true

	match stage:
		STAGE_WAIT_INTERACTIONS:
			if interacted_peer_ids.size() >= eligible_peer_ids.size():
				_set_stage(STAGE_VOTING)
			_emit_state()
		STAGE_VOTING:
			if _all_eligible_peers_have_votes(votes):
				_resolve_vote()
			else:
				_emit_state()
		STAGE_CRITICAL_BUFF_VOTING:
			if _all_eligible_peers_have_votes(permanent_buff_votes):
				_resolve_critical_buff_vote()
			else:
				_emit_state()
		STAGE_COLLECTIBLE_REWARD:
			if collectible_claimed_peer_ids.size() >= eligible_peer_ids.size():
				finalize_resolution()
			else:
				_emit_state()
		_:
			_emit_state()
	return true


func submit_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> bool:
	if not active or stage not in [STAGE_VOTING, STAGE_CRITICAL_BUFF_VOTING]:
		return false
	if not eligible_peer_ids.has(peer_id) or not interacted_peer_ids.has(peer_id):
		return false
	if stage == STAGE_CRITICAL_BUFF_VOTING:
		return _submit_critical_buff_vote(peer_id, option_id, permanent_buff_id)
	if not available_option_ids.has(option_id):
		return false
	var option_config := TowerDefenseFateRegistry.get_option_config(option_id)
	if option_config == null:
		return false
	if (
		available_permanent_buff_ids.size()
		< option_config.required_available_permanent_buff_count()
	):
		return false
	if option_id == TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT:
		if not permanent_buff_offer.has(permanent_buff_id):
			return false
		permanent_buff_votes[peer_id] = permanent_buff_id
	else:
		if permanent_buff_id != &"":
			return false
		permanent_buff_votes.erase(peer_id)
	votes[peer_id] = option_id
	_emit_state()
	if _all_eligible_peers_have_votes(votes):
		_resolve_vote()
	return true


func begin_collectible_reward(offers_by_peer: Dictionary) -> void:
	if not active or stage != STAGE_RESOLVING:
		return
	collectible_offers = offers_by_peer.duplicate(true)
	collectible_claimed_peer_ids.clear()
	collectible_status_by_peer.clear()
	_set_stage(STAGE_COLLECTIBLE_REWARD)
	_emit_state()


func record_collectible_result(peer_id: int, success: bool, status: String) -> bool:
	if not active or stage != STAGE_COLLECTIBLE_REWARD:
		return false
	if not eligible_peer_ids.has(peer_id):
		return false
	collectible_status_by_peer[peer_id] = status
	if success and not collectible_claimed_peer_ids.has(peer_id):
		collectible_claimed_peer_ids.append(peer_id)
		collectible_claimed_peer_ids.sort()
	_emit_state()
	if collectible_claimed_peer_ids.size() >= eligible_peer_ids.size():
		finalize_resolution()
	return true


func notify_external_state_changed() -> void:
	if active:
		_emit_state()


func finalize_resolution() -> void:
	if not active or stage not in [STAGE_RESOLVING, STAGE_COLLECTIBLE_REWARD]:
		return
	_set_stage(STAGE_RESOLVED)
	_emit_state()
	_finish_generation += 1
	var generation := _finish_generation
	_finish_after_delay(generation)


func force_finish() -> void:
	if not active:
		return
	_finish_generation += 1
	var resume_step_id := next_step_id
	active = false
	_set_stage(STAGE_WAIT_INTERACTIONS)
	_emit_state()
	interlude_completed.emit(resume_step_id)


func export_state() -> Dictionary:
	return {
		"active": active,
		"completed_day": completed_day,
		"next_step_id": String(next_step_id),
		"stage": String(stage),
		"host_peer_id": host_peer_id,
		"eligible_peer_ids": eligible_peer_ids.duplicate(),
		"interacted_peer_ids": interacted_peer_ids.duplicate(),
		"votes": _string_name_values_to_wire(votes),
		"permanent_buff_votes": _string_name_values_to_wire(permanent_buff_votes),
		"available_option_ids": _string_names_to_wire(available_option_ids),
		"available_permanent_buff_ids": _string_names_to_wire(
			available_permanent_buff_ids
		),
		"permanent_buff_offer": _string_names_to_wire(permanent_buff_offer),
		"available_permanent_buff_count": available_permanent_buff_ids.size(),
		"collectible_offers": collectible_offers.duplicate(true),
		"collectible_claimed_peer_ids": collectible_claimed_peer_ids.duplicate(),
		"collectible_status_by_peer": collectible_status_by_peer.duplicate(true),
		"winning_option_id": String(winning_option_id),
		"winning_permanent_buff_id": String(winning_permanent_buff_id),
		"stage_time_remaining": stage_time_remaining,
		"timeout_recovery_available": timeout_recovery_available,
		"revision": state_revision,
	}


func apply_remote_state(state: Dictionary) -> void:
	var incoming_revision := int(state.get("revision", -1))
	if incoming_revision < state_revision:
		return
	var incoming_stage := StringName(state.get("stage", STAGE_WAIT_INTERACTIONS))
	if not KNOWN_STAGES.has(incoming_stage):
		return
	var incoming_options := _variant_to_registered_option_ids(
		state.get("available_option_ids", [])
	)
	var incoming_buffs := _variant_to_registered_buff_ids(
		state.get("available_permanent_buff_ids", [])
	)
	var incoming_offer := _variant_to_registered_buff_ids(
		state.get("permanent_buff_offer", [])
	)
	var incoming_winner := StringName(state.get("winning_option_id", ""))
	var incoming_winning_buff := StringName(
		state.get("winning_permanent_buff_id", "")
	)
	if (
		(not incoming_winner.is_empty() and TowerDefenseFateRegistry.get_option_config(incoming_winner) == null)
		or (not incoming_winning_buff.is_empty() and TowerDefenseFateRegistry.get_permanent_buff_config(incoming_winning_buff) == null)
	):
		return
	if (
		incoming_stage == STAGE_CRITICAL_BUFF_VOTING
		and (
			incoming_winner != TowerDefenseFateRegistry.OPTION_CRITICAL_CORE
			or incoming_offer.size() != PERMANENT_BUFF_OFFER_COUNT
		)
	):
		return
	active = bool(state.get("active", false))
	completed_day = maxi(int(state.get("completed_day", 0)), 0)
	next_step_id = StringName(state.get("next_step_id", ""))
	stage = incoming_stage
	host_peer_id = int(state.get("host_peer_id", 0))
	eligible_peer_ids = _variant_to_int_array(state.get("eligible_peer_ids", []))
	interacted_peer_ids = _variant_to_int_array(state.get("interacted_peer_ids", []))
	votes = _wire_values_to_option_ids(state.get("votes", {}))
	permanent_buff_votes = _wire_values_to_buff_ids(
		state.get("permanent_buff_votes", {})
	)
	available_option_ids = incoming_options
	available_permanent_buff_ids = incoming_buffs
	permanent_buff_offer = incoming_offer
	collectible_offers = (
		state.get("collectible_offers", {}) as Dictionary
	).duplicate(true)
	collectible_claimed_peer_ids = _variant_to_int_array(
		state.get("collectible_claimed_peer_ids", [])
	)
	collectible_status_by_peer = (
		state.get("collectible_status_by_peer", {}) as Dictionary
	).duplicate(true)
	winning_option_id = incoming_winner
	winning_permanent_buff_id = incoming_winning_buff
	stage_time_remaining = maxf(float(state.get("stage_time_remaining", 0.0)), 0.0)
	timeout_recovery_available = bool(
		state.get("timeout_recovery_available", false)
	)
	state_revision = incoming_revision
	state_changed.emit(export_state())


func _resolve_vote() -> void:
	winning_option_id = _choose_majority_value(votes, available_option_ids)
	winning_permanent_buff_id = &""
	if winning_option_id == TowerDefenseFateRegistry.OPTION_CRITICAL_CORE:
		permanent_buff_votes.clear()
		_roll_permanent_buff_offer()
		if permanent_buff_offer.size() != PERMANENT_BUFF_OFFER_COUNT:
			push_error("濒危核心无法生成完整的三项全局增益投票。")
			force_finish()
			return
		_set_stage(STAGE_CRITICAL_BUFF_VOTING)
		_emit_state()
		return
	_set_stage(STAGE_RESOLVING)
	if winning_option_id == TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT:
		var eligible_buff_votes: Dictionary = {}
		for peer_variant in votes:
			if StringName(votes[peer_variant]) != winning_option_id:
				continue
			if permanent_buff_votes.has(peer_variant):
				eligible_buff_votes[peer_variant] = StringName(
					permanent_buff_votes[peer_variant]
				)
		winning_permanent_buff_id = _choose_majority_value(
			eligible_buff_votes,
			permanent_buff_offer
		)
	_emit_state()
	resolution_requested.emit(winning_option_id, winning_permanent_buff_id)


func _submit_critical_buff_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> bool:
	if (
		winning_option_id != TowerDefenseFateRegistry.OPTION_CRITICAL_CORE
		or option_id != winning_option_id
		or not permanent_buff_offer.has(permanent_buff_id)
	):
		return false
	permanent_buff_votes[peer_id] = permanent_buff_id
	_emit_state()
	if _all_eligible_peers_have_votes(permanent_buff_votes):
		_resolve_critical_buff_vote()
	return true


func _resolve_critical_buff_vote() -> void:
	if not active or stage != STAGE_CRITICAL_BUFF_VOTING:
		return
	winning_permanent_buff_id = _choose_majority_value(
		permanent_buff_votes,
		permanent_buff_offer
	)
	if winning_permanent_buff_id.is_empty():
		push_error("濒危核心全局增益投票没有可结算的选项。")
		force_finish()
		return
	_set_stage(STAGE_RESOLVING)
	_emit_state()
	resolution_requested.emit(winning_option_id, winning_permanent_buff_id)


func _choose_majority_value(
	source_votes: Dictionary,
	ordered_values: Array[StringName]
) -> StringName:
	var counts: Dictionary = {}
	for value_variant in source_votes.values():
		var value := StringName(value_variant)
		counts[value] = int(counts.get(value, 0)) + 1
	var best_value: StringName = &""
	var best_count := -1
	for value in ordered_values:
		var count := int(counts.get(value, 0))
		if count > best_count:
			best_count = count
			best_value = value
	return best_value


func _roll_permanent_buff_offer() -> void:
	var available: Array[StringName] = available_permanent_buff_ids.duplicate()
	_shuffle_string_names(available)
	permanent_buff_offer.clear()
	for buff_index in range(mini(PERMANENT_BUFF_OFFER_COUNT, available.size())):
		permanent_buff_offer.append(available[buff_index])


func _roll_fate_option_offer(
	candidate_option_ids: Array[StringName]
) -> Array[StringName]:
	var candidates: Array[StringName] = []
	for option_id in candidate_option_ids:
		var config := TowerDefenseFateRegistry.get_option_config(option_id)
		if config == null:
			continue
		if (
			available_permanent_buff_ids.size()
			< config.required_available_permanent_buff_count()
		):
			continue
		candidates.append(option_id)
	_shuffle_string_names(candidates)
	var offer: Array[StringName] = []
	for option_index in range(
		mini(FATE_OPTION_OFFER_COUNT, candidates.size())
	):
		offer.append(candidates[option_index])
	return offer


func _shuffle_string_names(values: Array[StringName]) -> void:
	for source_index in range(values.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary: StringName = values[source_index]
		values[source_index] = values[target_index]
		values[target_index] = temporary


func _fill_missing_votes_for_host_recovery() -> void:
	var fallback_option := StringName(votes.get(host_peer_id, &""))
	if not available_option_ids.has(fallback_option):
		fallback_option = available_option_ids[0]
	var fallback_config := TowerDefenseFateRegistry.get_option_config(fallback_option)
	if (
		fallback_config != null
		and available_permanent_buff_ids.size()
		< fallback_config.required_available_permanent_buff_count()
	):
		for option_id in available_option_ids:
			var option_config := TowerDefenseFateRegistry.get_option_config(option_id)
			if (
				option_config != null
				and available_permanent_buff_ids.size()
				>= option_config.required_available_permanent_buff_count()
			):
				fallback_option = option_id
				break
	var fallback_buff := StringName(permanent_buff_votes.get(host_peer_id, &""))
	if not permanent_buff_offer.has(fallback_buff):
		fallback_buff = permanent_buff_offer[0] if not permanent_buff_offer.is_empty() else &""
	for peer_id in eligible_peer_ids:
		if votes.has(peer_id):
			continue
		votes[peer_id] = fallback_option
		if fallback_option == TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT:
			permanent_buff_votes[peer_id] = fallback_buff


func _fill_missing_critical_buff_votes_for_host_recovery() -> void:
	var fallback_buff := StringName(permanent_buff_votes.get(host_peer_id, &""))
	if not permanent_buff_offer.has(fallback_buff):
		fallback_buff = permanent_buff_offer[0]
	for peer_id in eligible_peer_ids:
		if not permanent_buff_votes.has(peer_id):
			permanent_buff_votes[peer_id] = fallback_buff


func _all_eligible_peers_have_votes(source_votes: Dictionary) -> bool:
	for peer_id in eligible_peer_ids:
		if not source_votes.has(peer_id):
			return false
	return true


func _set_stage(new_stage: StringName) -> void:
	stage = new_stage
	timeout_recovery_available = false
	match stage:
		STAGE_WAIT_INTERACTIONS:
			stage_time_remaining = interaction_timeout_seconds
		STAGE_VOTING, STAGE_CRITICAL_BUFF_VOTING:
			stage_time_remaining = voting_timeout_seconds
		_:
			stage_time_remaining = 0.0


func _normalized_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id < 0 or result.has(peer_id):
			continue
		result.append(peer_id)
	result.sort()
	return result


func _normalized_option_ids(option_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for option_id in option_ids:
		if (
			TowerDefenseFateRegistry.get_option_config(option_id) != null
			and not result.has(option_id)
		):
			result.append(option_id)
	return result


func _normalized_buff_ids(buff_ids: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for buff_id in buff_ids:
		if (
			TowerDefenseFateRegistry.get_permanent_buff_config(buff_id) != null
			and not result.has(buff_id)
		):
			result.append(buff_id)
	return result


func _variant_to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			var parsed := int(entry)
			if parsed >= 0 and not result.has(parsed):
				result.append(parsed)
	result.sort()
	return result


func _variant_to_registered_option_ids(value: Variant) -> Array[StringName]:
	var result: Array[StringName] = []
	if value is Array or value is PackedStringArray:
		for entry in value:
			var config := TowerDefenseFateRegistry.get_option_config_by_wire_id(str(entry))
			if config != null and not result.has(config.option_id):
				result.append(config.option_id)
	return result


func _variant_to_registered_buff_ids(value: Variant) -> Array[StringName]:
	var result: Array[StringName] = []
	if value is Array or value is PackedStringArray:
		for entry in value:
			var config := TowerDefenseFateRegistry.get_permanent_buff_config_by_wire_id(
				str(entry)
			)
			if config != null and not result.has(config.buff_id):
				result.append(config.buff_id)
	return result


func _wire_values_to_option_ids(value: Variant) -> Dictionary:
	var result := {}
	if not (value is Dictionary):
		return result
	for peer_variant in value:
		var config := TowerDefenseFateRegistry.get_option_config_by_wire_id(
			str(value[peer_variant])
		)
		if config != null:
			result[int(peer_variant)] = config.option_id
	return result


func _wire_values_to_buff_ids(value: Variant) -> Dictionary:
	var result := {}
	if not (value is Dictionary):
		return result
	for peer_variant in value:
		var config := TowerDefenseFateRegistry.get_permanent_buff_config_by_wire_id(
			str(value[peer_variant])
		)
		if config != null:
			result[int(peer_variant)] = config.buff_id
	return result


func _string_names_to_wire(values: Array[StringName]) -> PackedStringArray:
	var result := PackedStringArray()
	for value in values:
		result.append(String(value))
	return result


func _string_name_values_to_wire(source: Dictionary) -> Dictionary:
	var result := {}
	for key_variant in source:
		result[int(key_variant)] = String(StringName(source[key_variant]))
	return result


func _emit_state() -> void:
	state_revision += 1
	state_changed.emit(export_state())


func _finish_after_delay(generation: int) -> void:
	await get_tree().create_timer(RESULT_DISPLAY_SECONDS).timeout
	if generation != _finish_generation or not active or stage != STAGE_RESOLVED:
		return
	force_finish()
