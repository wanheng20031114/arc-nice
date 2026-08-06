extends RefCounted
class_name LuoxiSpecialGameSession

const Rules := preload("res://scene/game_modes/tower_defense/merchants/luoxi/luoxi_special_game_rules.gd")

var revision: int = 0
var _hidden_outcomes: Array[Dictionary] = []
var _revealed_mask: int = 0
var _pending_item_paths: Array[String] = []
var _pending_item_counts: Array[int] = []
var _pending_xirang: int = 0


func setup(new_revision: int, new_outcomes: Array[Dictionary]) -> bool:
	if new_revision < 0 or new_outcomes.size() != Rules.CARD_COUNT:
		return false
	for outcome in new_outcomes:
		if not Rules.is_valid_outcome(outcome):
			return false

	revision = new_revision
	_hidden_outcomes.clear()
	for outcome in new_outcomes:
		_hidden_outcomes.append(outcome.duplicate(true))
	_revealed_mask = 0
	_pending_item_paths.clear()
	_pending_item_counts.clear()
	_pending_xirang = 0
	return true


func reveal(card_index: int) -> Dictionary:
	if (
		card_index < 0
		or card_index >= _hidden_outcomes.size()
		or is_card_revealed(card_index)
	):
		return {}

	_revealed_mask |= 1 << card_index
	var outcome := _hidden_outcomes[card_index].duplicate(true)
	_accumulate_delayed_reward(outcome)
	return outcome


func get_revealed_count() -> int:
	var revealed_count := 0
	for card_index in range(_hidden_outcomes.size()):
		if is_card_revealed(card_index):
			revealed_count += 1
	return revealed_count


func get_pending_item_paths() -> Array[String]:
	var paths: Array[String] = []
	paths.assign(_pending_item_paths)
	return paths


func get_pending_item_counts() -> Array[int]:
	var counts: Array[int] = []
	counts.assign(_pending_item_counts)
	return counts


func get_pending_xirang() -> int:
	return _pending_xirang


func get_public_state() -> Dictionary:
	var revealed_cards: Array[Dictionary] = []
	for card_index in range(_hidden_outcomes.size()):
		if is_card_revealed(card_index):
			revealed_cards.append({
				"card_index": card_index,
				"outcome": _hidden_outcomes[card_index].duplicate(true),
			})
	return {
		"revision": revision,
		"revealed_count": revealed_cards.size(),
		"revealed_cards": revealed_cards,
	}


func is_card_revealed(card_index: int) -> bool:
	return (
		card_index >= 0
		and card_index < _hidden_outcomes.size()
		and (_revealed_mask & (1 << card_index)) != 0
	)


func _accumulate_delayed_reward(outcome: Dictionary) -> void:
	var kind := int(outcome["kind"])
	if kind == Rules.OutcomeKind.XIRANG:
		_pending_xirang += int(outcome["amount"])
		return
	if (
		kind != Rules.OutcomeKind.COLLECTIBLE
		and kind != Rules.OutcomeKind.MATERIAL
	):
		return

	var item_path := String(outcome["item_path"])
	var amount := int(outcome["amount"])
	var existing_index := _pending_item_paths.find(item_path)
	if existing_index >= 0:
		_pending_item_counts[existing_index] += amount
		return
	_pending_item_paths.append(item_path)
	_pending_item_counts.append(amount)
