extends Node
class_name TowerDefenseFateManager

signal state_changed(state: Dictionary)
signal resolution_requested(option_index: int, permanent_buff_id: int)
signal interlude_completed(next_step_id: StringName)

const STAGE_WAIT_INTERACTIONS := &"wait_interactions"
const STAGE_VOTING := &"voting"
const STAGE_RESOLVING := &"resolving"
const STAGE_RESOLVED := &"resolved"
const STAGE_COLLECTIBLE_REWARD := &"collectible_reward"
const PERMANENT_BUFF_IDS: Array[int] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
const RESULT_DISPLAY_SECONDS := 1.15

var active := false
var completed_day := 0
var next_step_id: StringName = &""
var stage: StringName = STAGE_WAIT_INTERACTIONS
var eligible_peer_ids: Array[int] = []
var interacted_peer_ids: Array[int] = []
var votes: Dictionary = {}
var permanent_buff_votes: Dictionary = {}
var permanent_buff_offer: Array[int] = []
var active_permanent_buff_ids: Array[int] = []
var collectible_offers: Dictionary = {}
var collectible_claimed_peer_ids: Array[int] = []
var collectible_status_by_peer: Dictionary = {}
var winning_option_index := -1
var winning_permanent_buff_id := 0
var state_revision := 0
var random_generator := RandomNumberGenerator.new()
var _finish_generation := 0


func _ready() -> void:
	random_generator.randomize()


func begin_interlude(
	day_number: int,
	resume_step_id: StringName,
	peer_ids: Array[int]
) -> void:
	active = true
	completed_day = maxi(day_number, 1)
	next_step_id = resume_step_id
	stage = STAGE_WAIT_INTERACTIONS
	eligible_peer_ids = _normalized_peer_ids(peer_ids)
	interacted_peer_ids.clear()
	votes.clear()
	permanent_buff_votes.clear()
	collectible_offers.clear()
	collectible_claimed_peer_ids.clear()
	collectible_status_by_peer.clear()
	winning_option_index = -1
	winning_permanent_buff_id = 0
	_finish_generation += 1
	_roll_permanent_buff_offer()
	if eligible_peer_ids.is_empty():
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
		stage = STAGE_VOTING
	_emit_state()
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
				stage = STAGE_VOTING
			_emit_state()
		STAGE_VOTING:
			if votes.size() >= eligible_peer_ids.size():
				_resolve_vote()
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


func submit_vote(peer_id: int, option_index: int, permanent_buff_id: int) -> bool:
	if not active or stage != STAGE_VOTING:
		return false
	if not eligible_peer_ids.has(peer_id) or not interacted_peer_ids.has(peer_id):
		return false
	if option_index < 0 or option_index >= 10:
		return false
	if option_index in [0, 7] and get_available_permanent_buff_ids().is_empty():
		return false
	if option_index == 0:
		if not permanent_buff_offer.has(permanent_buff_id):
			return false
		permanent_buff_votes[peer_id] = permanent_buff_id
	else:
		permanent_buff_votes.erase(peer_id)
	votes[peer_id] = option_index
	_emit_state()
	if votes.size() >= eligible_peer_ids.size():
		_resolve_vote()
	return true


func begin_collectible_reward(offers_by_peer: Dictionary) -> void:
	if not active or stage != STAGE_RESOLVING:
		return
	collectible_offers = offers_by_peer.duplicate(true)
	collectible_claimed_peer_ids.clear()
	collectible_status_by_peer.clear()
	stage = STAGE_COLLECTIBLE_REWARD
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


func activate_permanent_buff(buff_id: int) -> bool:
	if not PERMANENT_BUFF_IDS.has(buff_id):
		return false
	if active_permanent_buff_ids.has(buff_id):
		return false
	active_permanent_buff_ids.append(buff_id)
	active_permanent_buff_ids.sort()
	return true


func get_available_permanent_buff_ids() -> Array[int]:
	var result: Array[int] = []
	for buff_id in PERMANENT_BUFF_IDS:
		if not active_permanent_buff_ids.has(buff_id):
			result.append(buff_id)
	return result


func has_permanent_buff(buff_id: int) -> bool:
	return active_permanent_buff_ids.has(buff_id)


## The game wrapper owns a few fate payload fields (for example pending stone
## recipients). Bump the same authoritative revision when one of those fields
## changes so clients never retain an older partial-resolution UI.
func notify_external_state_changed() -> void:
	if active:
		_emit_state()


func choose_random_available_permanent_buff() -> int:
	var available := get_available_permanent_buff_ids()
	if available.is_empty():
		return 0
	return available[random_generator.randi_range(0, available.size() - 1)]


func finalize_resolution() -> void:
	if not active or stage not in [STAGE_RESOLVING, STAGE_COLLECTIBLE_REWARD]:
		return
	stage = STAGE_RESOLVED
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
	stage = STAGE_WAIT_INTERACTIONS
	_emit_state()
	interlude_completed.emit(resume_step_id)


func export_state() -> Dictionary:
	return {
		"active": active,
		"completed_day": completed_day,
		"next_step_id": next_step_id,
		"stage": stage,
		"eligible_peer_ids": eligible_peer_ids.duplicate(),
		"interacted_peer_ids": interacted_peer_ids.duplicate(),
		"votes": votes.duplicate(true),
		"permanent_buff_votes": permanent_buff_votes.duplicate(true),
		"permanent_buff_offer": permanent_buff_offer.duplicate(),
		"active_permanent_buff_ids": active_permanent_buff_ids.duplicate(),
		"available_permanent_buff_count": get_available_permanent_buff_ids().size(),
		"collectible_offers": collectible_offers.duplicate(true),
		"collectible_claimed_peer_ids": collectible_claimed_peer_ids.duplicate(),
		"collectible_status_by_peer": collectible_status_by_peer.duplicate(true),
		"winning_option_index": winning_option_index,
		"winning_permanent_buff_id": winning_permanent_buff_id,
		"revision": state_revision,
	}


func apply_remote_state(state: Dictionary) -> void:
	var incoming_revision := int(state.get("revision", 0))
	if incoming_revision < state_revision:
		return
	active = bool(state.get("active", false))
	completed_day = maxi(int(state.get("completed_day", 0)), 0)
	next_step_id = StringName(state.get("next_step_id", &""))
	stage = StringName(state.get("stage", STAGE_WAIT_INTERACTIONS))
	eligible_peer_ids = _variant_to_int_array(state.get("eligible_peer_ids", []))
	interacted_peer_ids = _variant_to_int_array(state.get("interacted_peer_ids", []))
	votes = (state.get("votes", {}) as Dictionary).duplicate(true)
	permanent_buff_votes = (
		state.get("permanent_buff_votes", {}) as Dictionary
	).duplicate(true)
	permanent_buff_offer = _variant_to_int_array(
		state.get("permanent_buff_offer", [])
	)
	active_permanent_buff_ids = _variant_to_int_array(
		state.get("active_permanent_buff_ids", [])
	)
	collectible_offers = (
		state.get("collectible_offers", {}) as Dictionary
	).duplicate(true)
	collectible_claimed_peer_ids = _variant_to_int_array(
		state.get("collectible_claimed_peer_ids", [])
	)
	collectible_status_by_peer = (
		state.get("collectible_status_by_peer", {}) as Dictionary
	).duplicate(true)
	winning_option_index = int(state.get("winning_option_index", -1))
	winning_permanent_buff_id = int(state.get("winning_permanent_buff_id", 0))
	state_revision = incoming_revision
	state_changed.emit(export_state())


func _resolve_vote() -> void:
	stage = STAGE_RESOLVING
	winning_option_index = _choose_majority_value(votes, range(10))
	winning_permanent_buff_id = 0
	if winning_option_index == 0:
		var eligible_buff_votes: Dictionary = {}
		for peer_variant in votes:
			if int(votes[peer_variant]) != 0:
				continue
			if permanent_buff_votes.has(peer_variant):
				eligible_buff_votes[peer_variant] = int(
					permanent_buff_votes[peer_variant]
				)
		winning_permanent_buff_id = _choose_majority_value(
			eligible_buff_votes,
			permanent_buff_offer
		)
	_emit_state()
	resolution_requested.emit(winning_option_index, winning_permanent_buff_id)


func _choose_majority_value(source_votes: Dictionary, ordered_values: Variant) -> int:
	var counts: Dictionary = {}
	for value_variant in source_votes.values():
		var value := int(value_variant)
		counts[value] = int(counts.get(value, 0)) + 1
	var best_value := -1
	var best_count := -1
	for value_variant in ordered_values:
		var value := int(value_variant)
		var count := int(counts.get(value, 0))
		if count > best_count:
			best_count = count
			best_value = value
	return best_value


func _roll_permanent_buff_offer() -> void:
	var available := get_available_permanent_buff_ids()
	for source_index in range(available.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary := available[source_index]
		available[source_index] = available[target_index]
		available[target_index] = temporary
	permanent_buff_offer.clear()
	for buff_index in range(mini(3, available.size())):
		permanent_buff_offer.append(available[buff_index])


func _normalized_peer_ids(peer_ids: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for peer_id in peer_ids:
		if peer_id < 0 or result.has(peer_id):
			continue
		result.append(peer_id)
	result.sort()
	return result


func _variant_to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			result.append(int(entry))
	result.sort()
	return result


func _emit_state() -> void:
	state_revision += 1
	state_changed.emit(export_state())


func _finish_after_delay(generation: int) -> void:
	await get_tree().create_timer(RESULT_DISPLAY_SECONDS).timeout
	if generation != _finish_generation or not active or stage != STAGE_RESOLVED:
		return
	force_finish()
