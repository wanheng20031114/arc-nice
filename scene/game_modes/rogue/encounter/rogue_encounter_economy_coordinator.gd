extends Node
class_name RogueEncounterEconomyCoordinator

signal economy_changed(snapshot: Dictionary)

const SCHEMA_VERSION := 3
const PURCHASE_COST := 10
const FREE_PURCHASE_CHANCE := 0.5
const SLIME_HELP_COST := 10
const SLIME_COLLECTIBLE_REWARD_COUNT := 3
const SLIME_GEL_REWARD_COUNT := 10
const SLIME_HELP_COLLECTIBLE_CHANCE := 0.5
const SLIME_XIRANG_REWARD_AMOUNTS: Array[int] = [500, 1000, 2000, 5000]
const ENCOUNTER_CHICKEN_BRO := &"chicken_bro"
const ENCOUNTER_SLIME_TALKERS := &"slime_talkers"
const ENCOUNTER_GHOST_SHADOW := &"ghost_shadow"
const ENCOUNTER_FLUORESCENT_PIT := &"fluorescent_pit"
const OPTION_PURCHASE := &"purchase_basketball"
const OPTION_FREE := &"ask_for_free"
const OPTION_HELP_SLIMES := &"help_slimes"
const OPTION_KICK_SLIMES := &"kick_slimes"
const OPTION_LEAVE_SLIMES := &"leave_slimes"
const OPTION_GHOST_RUN_AWAY := &"ghost_run_away"
const OPTION_GHOST_WHO_ARE_YOU := &"ghost_who_are_you"
const OPTION_EXPLORE_PIT := &"explore_pit"
const OPTION_LEAVE_PIT := &"leave_pit"
const PLANK_PATH := "res://resources/config/materials/material_plank.tres"
const BASKETBALL_PATH := "res://resources/config/collectibles/collectible_basketball.tres"
const WATER_BOTTLE_PATH := "res://resources/config/materials/material_water_bottle.tres"
const GEL_PATH := "res://resources/config/materials/material_gel.tres"

const RESULT_GRANTED_PAID := &"granted_paid"
const RESULT_GRANTED_FREE := &"granted_free"
const RESULT_FREE_FAILED := &"free_failed"
const RESULT_INSUFFICIENT_PLANKS := &"insufficient_planks"
const RESULT_ALL_INVENTORIES_FULL := &"all_inventories_full"
const RESULT_STALE_STATE := &"stale_state"
const RESULT_INVALID_REQUEST := &"invalid_request"
const RESULT_SLIME_HELP_COLLECTIBLES := &"slime_help_collectibles"
const RESULT_SLIME_HELP_XIRANG := &"slime_help_xirang"
const RESULT_SLIME_INSUFFICIENT_WATER := &"slime_insufficient_water"
const RESULT_SLIME_KICK_INVENTORY := &"slime_kick_inventory"
const RESULT_SLIME_KICK_WAREHOUSE := &"slime_kick_warehouse"
const RESULT_SLIME_KICK_DROPPED := &"slime_kick_dropped"
const RESULT_SLIME_LEFT := &"slime_left"
const RESULT_GHOST_FLED := &"ghost_fled"
const RESULT_GHOST_VANISHED := &"ghost_vanished"
const RESULT_PIT_NOTHING := &"pit_nothing"
const RESULT_PIT_XIRANG := &"pit_xirang"
const RESULT_PIT_FALL := &"pit_fall"
const RESULT_PIT_COLLECTIBLE := &"pit_collectible"
const RESULT_PIT_BOTTOM := &"pit_bottom"
const RESULT_PIT_RADIATION := &"pit_radiation"
const RESULT_PIT_LEFT := &"pit_left"
const GHOST_IDENTITY_SPECIAL_OUTCOME := &"ghost_identity_special"

const PIT_XIRANG_MINIMUM := 5
const PIT_XIRANG_MAXIMUM := 100
const PIT_CORE_DAMAGE := 2
const PIT_MAX_HEALTH_PENALTY := 20

var _run_state: RunStateStore
var _player_character_ids: Dictionary = {}
var _economy_revision := 0
var _settled_occurrences: Dictionary = {}


func configure(
	run_state: RunStateStore,
	player_character_ids: Dictionary = {}
) -> void:
	reset_runtime(run_state, player_character_ids)


func reset_runtime(
	run_state: RunStateStore,
	player_character_ids: Dictionary = {}
) -> void:
	_run_state = run_state
	set_player_character_ids(player_character_ids)
	_economy_revision = 0
	_settled_occurrences.clear()
	if _run_state != null:
		_run_state.ensure_run_started()


func is_configured() -> bool:
	return _run_state != null


func set_player_character_ids(player_character_ids: Dictionary) -> void:
	_player_character_ids = player_character_ids.duplicate(true)


func can_afford_purchase(peer_ids: Array[int]) -> bool:
	if _run_state == null:
		return false
	var plank := load(PLANK_PATH) as PickupConfig
	return (
		plank != null
		and _run_state.get_party_item_total(plank, _to_packed_peer_ids(peer_ids))
		>= PURCHASE_COST
	)


func get_party_item_total(item: PickupConfig, peer_ids: Array[int] = []) -> int:
	if _run_state == null:
		return 0
	return _run_state.get_party_item_total(item, _to_packed_peer_ids(peer_ids))


func has_party_item(item: PickupConfig, peer_ids: Array[int] = []) -> bool:
	return get_party_item_total(item, peer_ids) > 0


func can_afford_slime_help(peer_ids: Array[int]) -> bool:
	if _run_state == null:
		return false
	var water_bottle := load(WATER_BOTTLE_PATH) as PickupConfig
	return (
		water_bottle != null
		and _run_state.get_party_item_total(
			water_bottle,
			_to_packed_peer_ids(peer_ids)
		) >= SLIME_HELP_COST
	)


func get_option_availability(
	encounter_id: StringName,
	peer_ids: Array[int]
) -> Dictionary:
	match encounter_id:
		ENCOUNTER_CHICKEN_BRO:
			return {
				String(OPTION_PURCHASE): can_afford_purchase(peer_ids),
				String(OPTION_FREE): true,
			}
		ENCOUNTER_SLIME_TALKERS:
			return {
				String(OPTION_HELP_SLIMES): can_afford_slime_help(peer_ids),
				String(OPTION_KICK_SLIMES): true,
				String(OPTION_LEAVE_SLIMES): true,
			}
		ENCOUNTER_GHOST_SHADOW:
			return {
				String(OPTION_GHOST_RUN_AWAY): true,
				String(OPTION_GHOST_WHO_ARE_YOU): true,
			}
		ENCOUNTER_FLUORESCENT_PIT:
			return {
				String(OPTION_EXPLORE_PIT): true,
				String(OPTION_LEAVE_PIT): true,
			}
		_:
			return {}


## Encounter sessions use one dispatch point so adding content does not add another
## hard-coded economy call to the session state machine. The legacy chicken entry
## remains public for existing callers and regression tests.
func resolve_encounter(
	encounter_id: StringName,
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = "",
	round_index: int = 0
) -> Dictionary:
	match encounter_id:
		ENCOUNTER_CHICKEN_BRO:
			return resolve_chicken_bro(
				option_id,
				node_content_seed,
				eligible_peer_ids,
				occurrence_key
			)
		ENCOUNTER_SLIME_TALKERS:
			return resolve_slime_talkers(
				option_id,
				node_content_seed,
				eligible_peer_ids,
				occurrence_key
			)
		ENCOUNTER_GHOST_SHADOW:
			return resolve_ghost_shadow(
				option_id,
				node_content_seed,
				eligible_peer_ids,
				occurrence_key
			)
		ENCOUNTER_FLUORESCENT_PIT:
			return resolve_fluorescent_pit(
				option_id,
				node_content_seed,
				eligible_peer_ids,
				occurrence_key,
				round_index
			)
		_:
			return _make_result(false, RESULT_INVALID_REQUEST)


## 鬼影没有资源收支，因此不会推进经济 revision 或写入结算账本。
## 固定结果本身是幂等的，仍由通用 Session 写入权威遭遇快照。
func resolve_ghost_shadow(
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = ""
) -> Dictionary:
	if (
		_run_state == null
		or option_id not in [
			OPTION_GHOST_RUN_AWAY,
			OPTION_GHOST_WHO_ARE_YOU,
		]
		or _normalize_peer_ids(eligible_peer_ids).is_empty()
	):
		return _make_result(false, RESULT_INVALID_REQUEST)
	if option_id == OPTION_GHOST_WHO_ARE_YOU:
		return _resolve_ghost_who_are_you(
			node_content_seed,
			eligible_peer_ids,
			occurrence_key
		)
	return _make_ghost_result(RESULT_GHOST_FLED, option_id)


## “你是？”的窄扩展入口。未来只需在此根据明确条件返回新的权威结果；
## 当前条件尚未设计，始终采用普通的“鬼影消失”结果。
func _resolve_ghost_who_are_you(
	_node_content_seed: int,
	_eligible_peer_ids: Array[int],
	_occurrence_key: String
) -> Dictionary:
	return _make_ghost_result(
		RESULT_GHOST_VANISHED,
		OPTION_GHOST_WHO_ARE_YOU,
		GHOST_IDENTITY_SPECIAL_OUTCOME
	)


## “荧光坑洞”的每一次下探都是一次独立结算。round_index 同时进入
## 随机 salt 与幂等键，确保重复 RPC 复用结果，而下一轮仍能重新抽取。
func resolve_fluorescent_pit(
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = "",
	round_index: int = 0
) -> Dictionary:
	var normalized_round_index := maxi(round_index, 0)
	var round_occurrence_key := _make_pit_round_occurrence_key(
		occurrence_key,
		normalized_round_index
	)
	if (
		not round_occurrence_key.is_empty()
		and _settled_occurrences.has(round_occurrence_key)
	):
		return (
			(_settled_occurrences[round_occurrence_key] as Dictionary).duplicate(
				true
			)
		)
	if (
		_run_state == null
		or option_id not in [OPTION_EXPLORE_PIT, OPTION_LEAVE_PIT]
	):
		return _make_result(false, RESULT_INVALID_REQUEST)
	var ordered_peer_ids := _normalize_peer_ids(eligible_peer_ids)
	if ordered_peer_ids.is_empty():
		return _make_result(false, RESULT_INVALID_REQUEST)
	for peer_id in ordered_peer_ids:
		if peer_id > 0:
			_run_state.ensure_multiplayer_peer_state(peer_id)

	if option_id == OPTION_LEAVE_PIT:
		var leave_result := _make_pit_result(
			RESULT_PIT_LEFT,
			option_id,
			normalized_round_index,
			ordered_peer_ids,
			"还是赶紧走吧"
		)
		leave_result["terminal"] = true
		return _finalize_resolution(
			leave_result,
			round_occurrence_key,
			ordered_peer_ids
		)

	var outcome_bucket := RogueEncounterRandom.choose_index(
		node_content_seed,
		StringName("fluorescent_pit_outcome|round:%d" % normalized_round_index),
		100
	)
	if outcome_bucket < 30:
		return _finalize_resolution(
			_make_pit_result(
				RESULT_PIT_NOTHING,
				option_id,
				normalized_round_index,
				ordered_peer_ids,
				"往下几米后，什么也没有发现"
			),
			round_occurrence_key,
			ordered_peer_ids
		)
	if outcome_bucket < 50:
		return _resolve_pit_xirang(
			node_content_seed,
			normalized_round_index,
			ordered_peer_ids,
			round_occurrence_key
		)
	if outcome_bucket < 80:
		return _resolve_pit_fall(
			normalized_round_index,
			ordered_peer_ids,
			round_occurrence_key
		)
	if outcome_bucket < 85:
		return _resolve_pit_collectible(
			node_content_seed,
			normalized_round_index,
			ordered_peer_ids,
			round_occurrence_key
		)
	if outcome_bucket < 99:
		var bottom_result := _make_pit_result(
			RESULT_PIT_BOTTOM,
			option_id,
			normalized_round_index,
			ordered_peer_ids,
			"这就到底了？"
		)
		bottom_result["disable_explore"] = true
		return _finalize_resolution(
			bottom_result,
			round_occurrence_key,
			ordered_peer_ids
		)
	return _resolve_pit_radiation(
		normalized_round_index,
		ordered_peer_ids,
		round_occurrence_key
	)


func _resolve_pit_xirang(
	node_content_seed: int,
	round_index: int,
	ordered_peer_ids: Array[int],
	round_occurrence_key: String
) -> Dictionary:
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var xirang_ledger := party_snapshot.get("xirang_ledger", {}) as Dictionary
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or not _is_valid_xirang_ledger(xirang_ledger)
	):
		return _make_result(false, RESULT_STALE_STATE)
	var expected_inventory_revisions := _get_expected_inventory_revisions(
		inventory_snapshots,
		ordered_peer_ids
	)
	var expected_xirang_revision := int(xirang_ledger["revision"])
	var next_snapshot := party_snapshot.duplicate(true)
	var next_xirang_ledger := next_snapshot["xirang_ledger"] as Dictionary
	var next_values := next_xirang_ledger["values"] as Dictionary
	var xirang_amount := PIT_XIRANG_MINIMUM + RogueEncounterRandom.choose_index(
		node_content_seed,
		StringName("fluorescent_pit_xirang|round:%d" % round_index),
		PIT_XIRANG_MAXIMUM - PIT_XIRANG_MINIMUM + 1
	)
	var xirang_totals: Array[Dictionary] = []
	var personal_detail_by_peer: Dictionary = {}
	for peer_id in ordered_peer_ids:
		var peer_key := str(peer_id)
		var next_total := int(next_values.get(peer_key, 0)) + xirang_amount
		next_values[peer_key] = next_total
		xirang_totals.append({"peer_id": peer_id, "total": next_total})
		personal_detail_by_peer[peer_id] = "获得息壤：%d" % xirang_amount
	next_xirang_ledger["revision"] = expected_xirang_revision + 1
	if not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		expected_xirang_revision,
		next_xirang_ledger
	):
		return _make_result(false, RESULT_STALE_STATE)
	var result := _make_pit_result(
		RESULT_PIT_XIRANG,
		OPTION_EXPLORE_PIT,
		round_index,
		ordered_peer_ids,
		"发现一些散落的息壤",
		"全队每人获得息壤：%d" % xirang_amount,
		personal_detail_by_peer
	)
	result.merge({
		"reward_kind": "xirang",
		"reward_granted": true,
		"xirang_reward_each": xirang_amount,
		"xirang_totals": xirang_totals,
	}, true)
	return _finalize_resolution(
		result,
		round_occurrence_key,
		ordered_peer_ids,
		true
	)


func _resolve_pit_fall(
	round_index: int,
	ordered_peer_ids: Array[int],
	round_occurrence_key: String
) -> Dictionary:
	var transaction := _prepare_pit_status_transaction(ordered_peer_ids)
	if transaction.is_empty():
		return _make_result(false, RESULT_STALE_STATE)
	var next_status := transaction["next_status"] as Dictionary
	var core_before := int(next_status["core_current"])
	var core_after := maxi(core_before - PIT_CORE_DAMAGE, 0)
	next_status["core_current"] = core_after
	next_status["revision"] = int(transaction["expected_status_revision"]) + 1
	if not _commit_pit_status_transaction(transaction):
		return _make_result(false, RESULT_STALE_STATE)
	var core_maximum := int(next_status["core_maximum"])
	var result := _make_pit_result(
		RESULT_PIT_FALL,
		OPTION_EXPLORE_PIT,
		round_index,
		ordered_peer_ids,
		"你一脚踩空，不慎滑落",
		"核心生命：%d → %d / %d" % [core_before, core_after, core_maximum]
	)
	result.merge({
		"core_damage": PIT_CORE_DAMAGE,
		"core_before": core_before,
		"core_after": core_after,
		"core_maximum": core_maximum,
		"terminal": core_after <= 0,
		"run_failed": core_after <= 0,
	}, true)
	return _finalize_resolution(
		result,
		round_occurrence_key,
		ordered_peer_ids,
		true
	)


func _resolve_pit_collectible(
	node_content_seed: int,
	round_index: int,
	ordered_peer_ids: Array[int],
	round_occurrence_key: String
) -> Dictionary:
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	if inventory_snapshots.size() != ordered_peer_ids.size():
		return _make_result(false, RESULT_STALE_STATE)
	var expected_inventory_revisions := _get_expected_inventory_revisions(
		inventory_snapshots,
		ordered_peer_ids
	)
	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var touched_peer_ids: Dictionary = {}
	var collectible_rewards: Array[Dictionary] = []
	var personal_detail_by_peer: Dictionary = {}
	var any_reward_granted := false
	for peer_id in ordered_peer_ids:
		var reward_pool := _get_pit_collectible_pool_for_peer(peer_id)
		if reward_pool.is_empty():
			return _make_result(false, RESULT_INVALID_REQUEST)
		var item := reward_pool[
			RogueEncounterRandom.choose_index(
				node_content_seed,
				StringName(
					"fluorescent_pit_collectible|round:%d|peer:%d"
					% [round_index, peer_id]
				),
				reward_pool.size()
			)
		]
		var granted := _add_item_to_inventory(
			next_inventory_snapshots[peer_id] as Dictionary,
			item
		)
		if granted:
			touched_peer_ids[peer_id] = true
			any_reward_granted = true
		var rarity_name := PickupConfig.get_collectible_rarity_label(
			int(item.collectible_rarity)
		)
		var detail_text := (
			"获得：%s（%s）" % [item.display_name, rarity_name]
			if granted
			else "背包已满，未获得：%s（%s）" % [item.display_name, rarity_name]
		)
		personal_detail_by_peer[peer_id] = detail_text
		collectible_rewards.append({
			"peer_id": peer_id,
			"rolled_path": item.resource_path,
			"rolled_paths": [item.resource_path],
			"granted_paths": [item.resource_path] if granted else [],
			"name": item.display_name,
			"rarity": int(item.collectible_rarity),
			"rarity_name": rarity_name,
			"granted": granted,
			"failure_reason": "" if granted else "inventory_full",
			"discarded_count": 0 if granted else 1,
		})
	_bump_touched_inventory_revisions(
		next_inventory_snapshots,
		expected_inventory_revisions,
		touched_peer_ids
	)
	if any_reward_granted and not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions
	):
		return _make_result(false, RESULT_STALE_STATE)
	var result := _make_pit_result(
		RESULT_PIT_COLLECTIBLE,
		OPTION_EXPLORE_PIT,
		round_index,
		ordered_peer_ids,
		"捡到一个亮晶晶的物品",
		"每位玩家独立抽取一件不高于史诗品质的收藏品",
		personal_detail_by_peer
	)
	result.merge({
		"reward_kind": "collectibles",
		"reward_granted": any_reward_granted,
		"collectible_rewards": collectible_rewards,
	}, true)
	return _finalize_resolution(
		result,
		round_occurrence_key,
		ordered_peer_ids,
		any_reward_granted
	)


func _resolve_pit_radiation(
	round_index: int,
	ordered_peer_ids: Array[int],
	round_occurrence_key: String
) -> Dictionary:
	var transaction := _prepare_pit_status_transaction(ordered_peer_ids)
	if transaction.is_empty():
		return _make_result(false, RESULT_STALE_STATE)
	var next_status := transaction["next_status"] as Dictionary
	var penalty_values := next_status["max_health_penalties"] as Dictionary
	var penalty_totals: Array[Dictionary] = []
	var personal_detail_by_peer: Dictionary = {}
	for peer_id in ordered_peer_ids:
		var peer_key := str(peer_id)
		var penalty_before := int(penalty_values.get(peer_key, 0))
		var penalty_after := penalty_before + PIT_MAX_HEALTH_PENALTY
		penalty_values[peer_key] = penalty_after
		penalty_totals.append({
			"peer_id": peer_id,
			"before": penalty_before,
			"after": penalty_after,
			"penalty_before": penalty_before,
			"penalty_after": penalty_after,
		})
		personal_detail_by_peer[peer_id] = (
			"最大生命惩罚：%d → %d" % [penalty_before, penalty_after]
		)
	next_status["revision"] = int(transaction["expected_status_revision"]) + 1
	if not _commit_pit_status_transaction(transaction):
		return _make_result(false, RESULT_STALE_STATE)
	var result := _make_pit_result(
		RESULT_PIT_RADIATION,
		OPTION_EXPLORE_PIT,
		round_index,
		ordered_peer_ids,
		"糟糕！是放射性元素！赶紧走！",
		"所有玩家的最大生命值减少20",
		personal_detail_by_peer
	)
	result.merge({
		"terminal": true,
		"max_health_penalty_added": PIT_MAX_HEALTH_PENALTY,
		"max_health_penalty_totals": penalty_totals,
	}, true)
	return _finalize_resolution(
		result,
		round_occurrence_key,
		ordered_peer_ids,
		true
	)


func _prepare_pit_status_transaction(
	ordered_peer_ids: Array[int]
) -> Dictionary:
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var status := party_snapshot.get("party_status_ledger", {}) as Dictionary
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or not _is_valid_party_status_ledger(status)
	):
		return {}
	var next_snapshot := party_snapshot.duplicate(true)
	return {
		"party_snapshot": party_snapshot,
		"next_snapshot": next_snapshot,
		"expected_inventory_revisions": _get_expected_inventory_revisions(
			inventory_snapshots,
			ordered_peer_ids
		),
		"expected_status_revision": int(status["revision"]),
		"next_status": next_snapshot["party_status_ledger"] as Dictionary,
	}


func _commit_pit_status_transaction(transaction: Dictionary) -> bool:
	var party_snapshot := transaction["party_snapshot"] as Dictionary
	var next_snapshot := transaction["next_snapshot"] as Dictionary
	return _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		transaction["expected_inventory_revisions"] as Dictionary,
		-1,
		{},
		int(transaction["expected_status_revision"]),
		transaction["next_status"] as Dictionary
	)


## Host-only settlement for the talking-slime encounter. Every branch is cached
## by occurrence_key, including leave and discarded rewards, so an RPC replay can
## never spend water or grant rewards twice.
func resolve_slime_talkers(
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = ""
) -> Dictionary:
	if not occurrence_key.is_empty() and _settled_occurrences.has(occurrence_key):
		return (
			(_settled_occurrences[occurrence_key] as Dictionary).duplicate(true)
		)
	if (
		_run_state == null
		or option_id not in [
			OPTION_HELP_SLIMES,
			OPTION_KICK_SLIMES,
			OPTION_LEAVE_SLIMES,
		]
	):
		return _make_result(false, RESULT_INVALID_REQUEST)
	var ordered_peer_ids := _normalize_peer_ids(eligible_peer_ids)
	if ordered_peer_ids.is_empty():
		return _make_result(false, RESULT_INVALID_REQUEST)
	for peer_id in ordered_peer_ids:
		if peer_id > 0:
			_run_state.ensure_multiplayer_peer_state(peer_id)

	if option_id == OPTION_LEAVE_SLIMES:
		return _finalize_resolution(
			_make_slime_result(true, RESULT_SLIME_LEFT, option_id),
			occurrence_key,
			ordered_peer_ids
		)
	if option_id == OPTION_HELP_SLIMES:
		return _resolve_slime_help(
			node_content_seed,
			ordered_peer_ids,
			occurrence_key
		)
	return _resolve_slime_kick(
		node_content_seed,
		ordered_peer_ids,
		occurrence_key
	)


func _resolve_slime_help(
	node_content_seed: int,
	ordered_peer_ids: Array[int],
	occurrence_key: String
) -> Dictionary:
	var water_bottle := load(WATER_BOTTLE_PATH) as PickupConfig
	if water_bottle == null:
		return _make_result(false, RESULT_INVALID_REQUEST)
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var xirang_ledger := party_snapshot.get("xirang_ledger", {}) as Dictionary
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or not _is_valid_xirang_ledger(xirang_ledger)
	):
		return _make_result(false, RESULT_STALE_STATE)
	if _count_item_path(party_snapshot, WATER_BOTTLE_PATH) < SLIME_HELP_COST:
		return _finalize_resolution(
			_make_slime_result(
				true,
				RESULT_SLIME_INSUFFICIENT_WATER,
				OPTION_HELP_SLIMES
			),
			occurrence_key,
			ordered_peer_ids
		)

	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var expected_inventory_revisions := _get_expected_inventory_revisions(
		inventory_snapshots,
		ordered_peer_ids
	)
	var expected_xirang_revision := int(xirang_ledger["revision"])
	var next_xirang_ledger := next_snapshot["xirang_ledger"] as Dictionary
	var touched_peer_ids: Dictionary = {}
	var ledger := next_snapshot["warehouse_ledger"] as Dictionary
	var warehouse_paid := _consume_from_warehouse_ledger(
		ledger,
		WATER_BOTTLE_PATH,
		SLIME_HELP_COST
	)
	var remaining_cost := SLIME_HELP_COST - warehouse_paid
	if warehouse_paid > 0:
		ledger["revision"] = int(ledger["revision"]) + 1
	var player_payments: Dictionary = {}
	var payment_order := ordered_peer_ids.duplicate()
	var rotation := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"slime_water_payer_rotation",
		payment_order.size()
	)
	payment_order = _rotated_peer_ids(payment_order, rotation)
	for peer_id in payment_order:
		if remaining_cost <= 0:
			break
		var paid := _consume_from_inventory(
			next_inventory_snapshots[peer_id] as Dictionary,
			WATER_BOTTLE_PATH,
			remaining_cost
		)
		if paid <= 0:
			continue
		player_payments[peer_id] = paid
		touched_peer_ids[peer_id] = true
		remaining_cost -= paid
	if remaining_cost > 0:
		return _make_result(false, RESULT_STALE_STATE)

	var result: Dictionary
	if RogueEncounterRandom.succeeds(
		node_content_seed,
		&"slime_help_reward_kind",
		SLIME_HELP_COLLECTIBLE_CHANCE
	):
		var reward_pool := CollectibleRegistry.get_standard_random_pool_up_to(
			PickupConfig.CollectibleRarity.RARE
		)
		if reward_pool.is_empty():
			return _make_result(false, RESULT_INVALID_REQUEST)
		var rewards: Array[Dictionary] = []
		for peer_id in ordered_peer_ids:
			var rolled_paths: Array[String] = []
			var granted_paths: Array[String] = []
			var peer_inventory := next_inventory_snapshots[peer_id] as Dictionary
			for reward_index in SLIME_COLLECTIBLE_REWARD_COUNT:
				var salt := StringName(
					"slime_collectible_%d_%d" % [peer_id, reward_index]
				)
				var item := reward_pool[
					RogueEncounterRandom.choose_index(
						node_content_seed,
						salt,
						reward_pool.size()
					)
				]
				rolled_paths.append(item.resource_path)
				if _add_item_count_to_wire_slots(
					peer_inventory.get("slots", []) as Array,
					item,
					1
				) == 1:
					granted_paths.append(item.resource_path)
					touched_peer_ids[peer_id] = true
			rewards.append({
				"peer_id": peer_id,
				"rolled_paths": rolled_paths,
				"granted_paths": granted_paths,
				"discarded_count": rolled_paths.size() - granted_paths.size(),
			})
		result = _make_slime_result(
			true,
			RESULT_SLIME_HELP_COLLECTIBLES,
			OPTION_HELP_SLIMES
		)
		result["reward_kind"] = "collectibles"
		result["collectible_rewards"] = rewards
	else:
		var amount_index := RogueEncounterRandom.choose_index(
			node_content_seed,
			&"slime_xirang_tier",
			SLIME_XIRANG_REWARD_AMOUNTS.size()
		)
		var xirang_amount := SLIME_XIRANG_REWARD_AMOUNTS[amount_index]
		var next_values := next_xirang_ledger["values"] as Dictionary
		var xirang_totals: Array[Dictionary] = []
		for peer_id in ordered_peer_ids:
			var peer_key := str(peer_id)
			var next_total := int(next_values.get(peer_key, 0)) + xirang_amount
			next_values[peer_key] = next_total
			xirang_totals.append({"peer_id": peer_id, "total": next_total})
		next_xirang_ledger["revision"] = expected_xirang_revision + 1
		result = _make_slime_result(
			true,
			RESULT_SLIME_HELP_XIRANG,
			OPTION_HELP_SLIMES
		)
		result["reward_kind"] = "xirang"
		result["xirang_reward_each"] = xirang_amount
		result["xirang_totals"] = xirang_totals

	_bump_touched_inventory_revisions(
		next_inventory_snapshots,
		expected_inventory_revisions,
		touched_peer_ids
	)
	if not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		expected_xirang_revision,
		next_xirang_ledger
	):
		return _make_result(false, RESULT_STALE_STATE)
	result.merge({
		"water_paid": SLIME_HELP_COST,
		"warehouse_paid": warehouse_paid,
		"player_payments": player_payments,
	}, true)
	return _finalize_resolution(result, occurrence_key, ordered_peer_ids, true)


func _resolve_slime_kick(
	node_content_seed: int,
	ordered_peer_ids: Array[int],
	occurrence_key: String
) -> Dictionary:
	var gel := load(GEL_PATH) as PickupConfig
	if gel == null:
		return _make_result(false, RESULT_INVALID_REQUEST)
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	var xirang_ledger := party_snapshot.get("xirang_ledger", {}) as Dictionary
	if (
		inventory_snapshots.size() != ordered_peer_ids.size()
		or not _is_valid_xirang_ledger(xirang_ledger)
	):
		return _make_result(false, RESULT_STALE_STATE)
	var receiver_peer_id := ordered_peer_ids[
		RogueEncounterRandom.choose_index(
			node_content_seed,
			&"slime_gel_receiver",
			ordered_peer_ids.size()
		)
	]
	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var expected_inventory_revisions := _get_expected_inventory_revisions(
		inventory_snapshots,
		ordered_peer_ids
	)
	var expected_xirang_revision := int(xirang_ledger["revision"])
	var next_xirang_ledger := next_snapshot["xirang_ledger"] as Dictionary
	var target_inventory := next_inventory_snapshots[receiver_peer_id] as Dictionary
	var target_slots := target_inventory.get("slots", []) as Array
	var destination := "discarded"
	var result_code := RESULT_SLIME_KICK_DROPPED
	var touched_warehouse_ids: Array[int] = []
	var transaction_required := false
	if _get_wire_slot_capacity(target_slots, gel) >= SLIME_GEL_REWARD_COUNT:
		_add_item_count_to_wire_slots(target_slots, gel, SLIME_GEL_REWARD_COUNT)
		target_inventory["revision"] = (
			int(expected_inventory_revisions[receiver_peer_id]) + 1
		)
		destination = "inventory"
		result_code = RESULT_SLIME_KICK_INVENTORY
		transaction_required = true
	else:
		var warehouse_add := _try_add_item_count_to_warehouse_ledger(
			next_snapshot["warehouse_ledger"] as Dictionary,
			gel,
			SLIME_GEL_REWARD_COUNT
		)
		if bool(warehouse_add.get("success", false)):
			touched_warehouse_ids.assign(
				warehouse_add.get("warehouse_net_ids", []) as Array
			)
			destination = "warehouse"
			result_code = RESULT_SLIME_KICK_WAREHOUSE
			transaction_required = true

	if transaction_required and not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		expected_xirang_revision,
		next_xirang_ledger
	):
		return _make_result(false, RESULT_STALE_STATE)
	var result := _make_slime_result(true, result_code, OPTION_KICK_SLIMES)
	result.merge({
		"reward_kind": "gel",
		"reward_granted": destination != "discarded",
		"receiver_peer_id": receiver_peer_id,
		"gel_count": SLIME_GEL_REWARD_COUNT,
		"gel_destination": destination,
		"gel_warehouse_net_ids": touched_warehouse_ids,
	}, true)
	return _finalize_resolution(
		result,
		occurrence_key,
		ordered_peer_ids,
		transaction_required
	)


## 重连时迁移已结算结果中的玩家引用。这里推进一次经济 revision，但不
## 发 signal；调用方会把迁移后的经济快照并入同一次遭遇状态广播，避免
## economy_changed 回调额外推进 encounter revision。
func migrate_peer_references(old_peer_id: int, new_peer_id: int) -> bool:
	if old_peer_id < 0 or new_peer_id < 0 or old_peer_id == new_peer_id:
		return false
	var changed := false
	for raw_occurrence_key in _settled_occurrences.keys():
		var occurrence_key := str(raw_occurrence_key)
		var previous := _settled_occurrences[raw_occurrence_key] as Dictionary
		var migrated := migrate_result_peer_references(
			previous,
			old_peer_id,
			new_peer_id
		)
		if migrated == previous:
			continue
		_settled_occurrences[occurrence_key] = migrated
		changed = true
	if changed:
		_economy_revision += 1
	return changed


func migrate_result_peer_references(
	result: Dictionary,
	old_peer_id: int,
	new_peer_id: int
) -> Dictionary:
	var migrated := result.duplicate(true)
	if int(migrated.get("receiver_peer_id", -1)) == old_peer_id:
		migrated["receiver_peer_id"] = new_peer_id
	var payments := migrated.get("player_payments", {}) as Dictionary
	if payments.has(old_peer_id):
		var old_payment := int(payments[old_peer_id])
		payments.erase(old_peer_id)
		payments[new_peer_id] = int(payments.get(new_peer_id, 0)) + old_payment
		migrated["player_payments"] = payments
	var recipients := migrated.get("round_recipient_peer_ids", []) as Array
	for index in recipients.size():
		if int(recipients[index]) == old_peer_id:
			recipients[index] = new_peer_id
	if not recipients.is_empty():
		recipients.sort()
		migrated["round_recipient_peer_ids"] = recipients
	var personal_details := (
		migrated.get("personal_detail_by_peer", {}) as Dictionary
	)
	if personal_details.has(old_peer_id):
		var detail: Variant = personal_details[old_peer_id]
		personal_details.erase(old_peer_id)
		personal_details[new_peer_id] = detail
		migrated["personal_detail_by_peer"] = personal_details
	for field_name in [
		"collectible_rewards",
		"xirang_totals",
		"max_health_penalty_totals",
	]:
		var entries := migrated.get(field_name, []) as Array
		for raw_entry_value in entries:
			if typeof(raw_entry_value) != TYPE_DICTIONARY:
				continue
			var entry := raw_entry_value as Dictionary
			if int(entry.get("peer_id", -1)) == old_peer_id:
				entry["peer_id"] = new_peer_id
	return migrated


## 房主唯一调用的鸡哥结算入口。返回值始终可直接写入 encounter snapshot；
## resolved=false 只表示请求/状态过期，应由调用方等待新快照而不是展示结果。
func resolve_chicken_bro(
	option_id: StringName,
	node_content_seed: int,
	eligible_peer_ids: Array[int],
	occurrence_key: String = ""
) -> Dictionary:
	if not occurrence_key.is_empty() and _settled_occurrences.has(occurrence_key):
		return (
			(_settled_occurrences[occurrence_key] as Dictionary).duplicate(true)
		)
	if (
		_run_state == null
		or option_id not in [OPTION_PURCHASE, OPTION_FREE]
	):
		return _make_result(false, RESULT_INVALID_REQUEST)
	var ordered_peer_ids := _normalize_peer_ids(eligible_peer_ids)
	if ordered_peer_ids.is_empty():
		return _make_result(false, RESULT_INVALID_REQUEST)
	for peer_id in ordered_peer_ids:
		if peer_id > 0:
			_run_state.ensure_multiplayer_peer_state(peer_id)

	var basketball := load(BASKETBALL_PATH) as PickupConfig
	var plank := load(PLANK_PATH) as PickupConfig
	if basketball == null or plank == null:
		return _make_result(false, RESULT_INVALID_REQUEST)
	var party_snapshot := _run_state.export_party_economy_snapshot(
		_to_packed_peer_ids(ordered_peer_ids)
	)
	var inventory_snapshots := _index_inventory_snapshots(party_snapshot)
	if inventory_snapshots.size() != ordered_peer_ids.size():
		return _make_result(false, RESULT_STALE_STATE)

	var recipient_candidates: Array[int] = []
	for peer_id in ordered_peer_ids:
		if _inventory_has_capacity(
			inventory_snapshots[peer_id] as Dictionary,
			basketball
		):
			recipient_candidates.append(peer_id)
	if recipient_candidates.is_empty():
		return _finalize_resolution(
			_make_result(true, RESULT_ALL_INVENTORIES_FULL),
			occurrence_key,
			ordered_peer_ids
		)

	if (
		option_id == OPTION_FREE
		and not RogueEncounterRandom.succeeds(
			node_content_seed,
			&"free_roll",
			FREE_PURCHASE_CHANCE
		)
	):
		var failed_free := _make_result(true, RESULT_FREE_FAILED)
		failed_free["free_purchase_success"] = false
		return _finalize_resolution(
			failed_free,
			occurrence_key,
			ordered_peer_ids
		)

	if (
		option_id == OPTION_PURCHASE
		and _count_item_path(party_snapshot, PLANK_PATH) < PURCHASE_COST
	):
		return _finalize_resolution(
			_make_result(true, RESULT_INSUFFICIENT_PLANKS),
			occurrence_key,
			ordered_peer_ids
		)

	var receiver_index := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"receiver",
		recipient_candidates.size()
	)
	var receiver_peer_id := recipient_candidates[receiver_index]
	var next_snapshot := party_snapshot.duplicate(true)
	var next_inventory_snapshots := _index_inventory_snapshots(next_snapshot)
	var expected_inventory_revisions: Dictionary = {}
	var touched_peer_ids: Dictionary = {}
	for peer_id in ordered_peer_ids:
		expected_inventory_revisions[peer_id] = int(
			(inventory_snapshots[peer_id] as Dictionary).get("revision", -1)
		)

	var warehouse_paid := 0
	var player_payments: Dictionary = {}
	if option_id == OPTION_PURCHASE:
		var remaining_cost := PURCHASE_COST
		var ledger := next_snapshot["warehouse_ledger"] as Dictionary
		warehouse_paid = _consume_from_warehouse_ledger(
			ledger,
			PLANK_PATH,
			remaining_cost
		)
		remaining_cost -= warehouse_paid
		if warehouse_paid > 0:
			ledger["revision"] = int(ledger["revision"]) + 1
		var payment_order := ordered_peer_ids.duplicate()
		var rotation := RogueEncounterRandom.choose_index(
			node_content_seed,
			&"payer_rotation",
			payment_order.size()
		)
		payment_order = _rotated_peer_ids(payment_order, rotation)
		for peer_id in payment_order:
			if remaining_cost <= 0:
				break
			var paid := _consume_from_inventory(
				next_inventory_snapshots[peer_id] as Dictionary,
				PLANK_PATH,
				remaining_cost
			)
			if paid <= 0:
				continue
			player_payments[peer_id] = paid
			touched_peer_ids[peer_id] = true
			remaining_cost -= paid
		if remaining_cost > 0:
			return _finalize_resolution(
				_make_result(true, RESULT_INSUFFICIENT_PLANKS),
				occurrence_key,
				ordered_peer_ids
			)

	if not _add_item_to_inventory(
		next_inventory_snapshots[receiver_peer_id] as Dictionary,
		basketball
	):
		return _finalize_resolution(
			_make_result(true, RESULT_ALL_INVENTORIES_FULL),
			occurrence_key,
			ordered_peer_ids
		)
	touched_peer_ids[receiver_peer_id] = true
	for raw_peer_id in touched_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		var next_inventory := next_inventory_snapshots[peer_id] as Dictionary
		next_inventory["revision"] = int(expected_inventory_revisions[peer_id]) + 1

	if not _run_state.apply_authoritative_party_transaction(
		next_snapshot,
		int((party_snapshot["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions
	):
		return _make_result(false, RESULT_STALE_STATE)
	var result_code := (
		RESULT_GRANTED_PAID
		if option_id == OPTION_PURCHASE
		else RESULT_GRANTED_FREE
	)
	var result := _make_result(true, result_code)
	result.merge(
		{
			"reward_granted": true,
			"receiver_peer_id": receiver_peer_id,
			"planks_paid": PURCHASE_COST if option_id == OPTION_PURCHASE else 0,
			"warehouse_paid": warehouse_paid,
			"player_payments": player_payments,
			"free_purchase_success": option_id == OPTION_FREE,
		},
		true
	)
	return _finalize_resolution(result, occurrence_key, ordered_peer_ids, true)


func export_snapshot(peer_ids: Array[int] = []) -> Dictionary:
	if _run_state == null:
		return {}
	return {
		"schema_version": SCHEMA_VERSION,
		"revision": _economy_revision,
		"settled_occurrences": _export_settled_occurrences(),
		"party_economy": _run_state.export_party_economy_snapshot(
			_to_packed_peer_ids(peer_ids)
		),
	}


func apply_remote_snapshot(snapshot: Dictionary) -> bool:
	if (
		_run_state == null
		or typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SCHEMA_VERSION
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < _economy_revision
		or typeof(snapshot.get("party_economy")) != TYPE_DICTIONARY
		or typeof(snapshot.get("settled_occurrences")) != TYPE_ARRAY
	):
		return false
	var decoded_occurrences: Variant = _decode_settled_occurrences(
		snapshot["settled_occurrences"] as Array
	)
	if decoded_occurrences == null:
		return false
	if not _run_state.apply_party_economy_snapshot(
		snapshot["party_economy"] as Dictionary
	):
		return false
	var changed: bool = int(snapshot["revision"]) != _economy_revision
	_economy_revision = int(snapshot["revision"])
	_settled_occurrences = decoded_occurrences as Dictionary
	if changed:
		economy_changed.emit(export_snapshot())
	return true


func _finalize_resolution(
	result: Dictionary,
	occurrence_key: String,
	peer_ids: Array[int],
	economy_was_mutated: bool = false
) -> Dictionary:
	if not bool(result.get("resolved", false)):
		return result
	if not occurrence_key.is_empty() and _settled_occurrences.has(occurrence_key):
		return (
			(_settled_occurrences[occurrence_key] as Dictionary).duplicate(true)
		)
	if economy_was_mutated or not occurrence_key.is_empty():
		_economy_revision += 1
	result["economy_revision"] = _economy_revision
	if not occurrence_key.is_empty():
		_settled_occurrences[occurrence_key] = result.duplicate(true)
	if economy_was_mutated or not occurrence_key.is_empty():
		economy_changed.emit(export_snapshot(peer_ids))
	return result


func _export_settled_occurrences() -> Array[Dictionary]:
	var occurrence_keys: Array[String] = []
	for raw_occurrence_key in _settled_occurrences.keys():
		occurrence_keys.append(str(raw_occurrence_key))
	occurrence_keys.sort()
	var result: Array[Dictionary] = []
	for occurrence_key in occurrence_keys:
		result.append(
			{
				"occurrence_key": occurrence_key,
				"result": (
					_settled_occurrences[occurrence_key] as Dictionary
				).duplicate(true),
			}
		)
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


func _make_result(resolved: bool, result_code: StringName) -> Dictionary:
	return {
		"resolved": resolved,
		"result_code": String(result_code),
		"reward_granted": false,
		"receiver_peer_id": -1,
		"planks_paid": 0,
		"warehouse_paid": 0,
		"player_payments": {},
		"free_purchase_success": false,
		"economy_revision": _economy_revision,
	}


func _make_slime_result(
	resolved: bool,
	result_code: StringName,
	option_id: StringName
) -> Dictionary:
	var result := _make_result(resolved, result_code)
	result.merge({
		"encounter_id": String(ENCOUNTER_SLIME_TALKERS),
		"option_id": String(option_id),
		"reward_kind": "none",
		"water_paid": 0,
		"collectible_rewards": [],
		"xirang_reward_each": 0,
		"xirang_totals": [],
		"gel_count": 0,
		"gel_destination": "none",
		"gel_warehouse_net_ids": [],
	}, true)
	return result


func _make_ghost_result(
	result_code: StringName,
	option_id: StringName,
	special_outcome_key: StringName = &""
) -> Dictionary:
	var result := _make_result(true, result_code)
	result.merge({
		"encounter_id": String(ENCOUNTER_GHOST_SHADOW),
		"option_id": String(option_id),
		"special_outcome_key": String(special_outcome_key),
	}, true)
	return result


func _make_pit_result(
	result_code: StringName,
	option_id: StringName,
	round_index: int,
	recipient_peer_ids: Array[int],
	common_result_text: String,
	common_detail_text: String = "",
	personal_detail_by_peer: Dictionary = {}
) -> Dictionary:
	var result := _make_result(true, result_code)
	result.merge({
		"encounter_id": String(ENCOUNTER_FLUORESCENT_PIT),
		"option_id": String(option_id),
		"terminal": false,
		"run_failed": false,
		"disable_explore": false,
		"round_index": round_index,
		"round_recipient_peer_ids": recipient_peer_ids.duplicate(),
		"common_result_text": common_result_text,
		"common_detail_text": common_detail_text,
		"personal_detail_by_peer": personal_detail_by_peer.duplicate(true),
	}, true)
	return result


func _make_pit_round_occurrence_key(
	occurrence_key: String,
	round_index: int
) -> String:
	if occurrence_key.is_empty():
		return ""
	var round_suffix := "|round:%d" % round_index
	if occurrence_key.ends_with(round_suffix):
		return occurrence_key
	return occurrence_key + round_suffix


func _get_pit_collectible_pool_for_peer(peer_id: int) -> Array[PickupConfig]:
	var character_id := _get_character_id_for_peer(peer_id)
	var result: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_standard_random_pool_up_to(
		PickupConfig.CollectibleRarity.EPIC
	):
		if (
			item != null
			and item.can_store_in_inventory
			and _is_collectible_compatible_with_character(item, character_id)
		):
			result.append(item)
	return result


func _get_character_id_for_peer(peer_id: int) -> StringName:
	var fallback := _run_state.get_selected_character_id()
	if peer_id <= 0:
		return fallback
	var character_id := StringName(
		_player_character_ids.get(peer_id, fallback)
	)
	return (
		character_id
		if PlayerCharacterRegistry.is_valid_character_id(character_id)
		else fallback
	)


func _is_collectible_compatible_with_character(
	item: PickupConfig,
	character_id: StringName
) -> bool:
	if item == null:
		return false
	# 与当前角色脚本保持同一能力口径：Weishidaier/Tiyi 继承
	# AmmoRangedPlayer；Hoe Cat 使用默认 false；Tango 虽重写投射物方法，
	# 但为避免批量齐射 RPC 分歧，当前实现明确返回 false。
	var supports_ammunition := character_id in [
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		PlayerCharacterRegistry.TIYI_ID,
	]
	var supports_projectile_patterns := supports_ammunition
	if item.requires_projectile_primary_attack and not supports_projectile_patterns:
		return false
	if item.requires_ammunition and not supports_ammunition:
		return false
	return true


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


func _to_packed_peer_ids(peer_ids: Array[int]) -> PackedInt32Array:
	var packed := PackedInt32Array()
	for peer_id in peer_ids:
		packed.append(peer_id)
	return packed


func _index_inventory_snapshots(party_snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for raw_inventory_value in party_snapshot.get("inventories", []) as Array:
		var inventory_snapshot := raw_inventory_value as Dictionary
		var peer_id := int(inventory_snapshot.get("peer_id", -1))
		if peer_id < 0 or result.has(peer_id):
			return {}
		result[peer_id] = inventory_snapshot
	return result


func _get_expected_inventory_revisions(
	inventory_snapshots: Dictionary,
	peer_ids: Array[int]
) -> Dictionary:
	var result: Dictionary = {}
	for peer_id in peer_ids:
		if not inventory_snapshots.has(peer_id):
			return {}
		result[peer_id] = int(
			(inventory_snapshots[peer_id] as Dictionary).get("revision", -1)
		)
	return result


func _bump_touched_inventory_revisions(
	inventory_snapshots: Dictionary,
	expected_revisions: Dictionary,
	touched_peer_ids: Dictionary
) -> void:
	for raw_peer_id in touched_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		if (
			not inventory_snapshots.has(peer_id)
			or not expected_revisions.has(peer_id)
		):
			continue
		var inventory_snapshot := inventory_snapshots[peer_id] as Dictionary
		inventory_snapshot["revision"] = int(expected_revisions[peer_id]) + 1


func _is_valid_xirang_ledger(ledger: Dictionary) -> bool:
	if (
		typeof(ledger.get("schema_version")) != TYPE_INT
		or int(ledger["schema_version"]) != 1
		or typeof(ledger.get("revision")) != TYPE_INT
		or int(ledger["revision"]) < 0
		or typeof(ledger.get("values")) != TYPE_DICTIONARY
	):
		return false
	for raw_peer_key in (ledger["values"] as Dictionary).keys():
		if typeof(raw_peer_key) != TYPE_STRING:
			return false
		var peer_key := str(raw_peer_key)
		if not peer_key.is_valid_int() or str(peer_key.to_int()) != peer_key:
			return false
		var raw_value: Variant = (ledger["values"] as Dictionary)[raw_peer_key]
		if typeof(raw_value) != TYPE_INT or int(raw_value) < 0:
			return false
	return true


func _is_valid_party_status_ledger(ledger: Dictionary) -> bool:
	if (
		typeof(ledger.get("schema_version")) != TYPE_INT
		or int(ledger["schema_version"]) != 1
		or typeof(ledger.get("revision")) != TYPE_INT
		or int(ledger["revision"]) < 0
		or typeof(ledger.get("core_current")) != TYPE_INT
		or typeof(ledger.get("core_maximum")) != TYPE_INT
		or int(ledger["core_maximum"]) <= 0
		or int(ledger["core_current"]) < 0
		or int(ledger["core_current"]) > int(ledger["core_maximum"])
		or typeof(ledger.get("max_health_penalties")) != TYPE_DICTIONARY
	):
		return false
	for raw_peer_key in (ledger["max_health_penalties"] as Dictionary).keys():
		if typeof(raw_peer_key) != TYPE_STRING:
			return false
		var peer_key := str(raw_peer_key)
		if not peer_key.is_valid_int() or str(peer_key.to_int()) != peer_key:
			return false
		var raw_penalty: Variant = (
			ledger["max_health_penalties"] as Dictionary
		)[raw_peer_key]
		if typeof(raw_penalty) != TYPE_INT or int(raw_penalty) < 0:
			return false
	return true


func _inventory_has_capacity(
	inventory_snapshot: Dictionary,
	item: PickupConfig
) -> bool:
	if item == null or not item.can_store_in_inventory:
		return false
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	for raw_slot_value in inventory_snapshot.get("slots", []) as Array:
		var slot := raw_slot_value as Dictionary
		var path := str(slot.get("config_path", ""))
		if path.is_empty():
			return true
		if (
			item.stackable
			and path == item.resource_path
			and int(slot.get("stack_count", 0)) < stack_limit
		):
			return true
	return false


func _count_item_path(party_snapshot: Dictionary, config_path: String) -> int:
	var total := 0
	var ledger := party_snapshot.get("warehouse_ledger", {}) as Dictionary
	for raw_warehouse_value in ledger.get("warehouses", []) as Array:
		for raw_slot_value in (raw_warehouse_value as Dictionary).get("slots", []) as Array:
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) == config_path:
				total += int(slot.get("stack_count", 0))
	for raw_inventory_value in party_snapshot.get("inventories", []) as Array:
		for raw_slot_value in (raw_inventory_value as Dictionary).get("slots", []) as Array:
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) == config_path:
				total += int(slot.get("stack_count", 0))
	return total


func _consume_from_warehouse_ledger(
	ledger: Dictionary,
	config_path: String,
	requested_count: int
) -> int:
	var warehouses := ledger.get("warehouses", []) as Array
	warehouses.sort_custom(
		func(left: Variant, right: Variant) -> bool:
			return int((left as Dictionary).get("warehouse_net_id", -1)) < int(
				(right as Dictionary).get("warehouse_net_id", -1)
			)
	)
	var remaining := requested_count
	for raw_warehouse_value in warehouses:
		if remaining <= 0:
			break
		var warehouse := raw_warehouse_value as Dictionary
		var warehouse_changed := false
		for raw_slot_value in warehouse.get("slots", []) as Array:
			if remaining <= 0:
				break
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) != config_path:
				continue
			var stored_count := int(slot.get("stack_count", 0))
			var consumed := mini(stored_count, remaining)
			_set_wire_slot_count(slot, stored_count - consumed)
			remaining -= consumed
			warehouse_changed = warehouse_changed or consumed > 0
		if warehouse_changed:
			warehouse["revision"] = int(warehouse.get("revision", 0)) + 1
	return requested_count - remaining


func _consume_from_inventory(
	inventory_snapshot: Dictionary,
	config_path: String,
	requested_count: int
) -> int:
	var remaining := requested_count
	for raw_slot_value in inventory_snapshot.get("slots", []) as Array:
		if remaining <= 0:
			break
		var slot := raw_slot_value as Dictionary
		if str(slot.get("config_path", "")) != config_path:
			continue
		var stored_count := int(slot.get("stack_count", 0))
		var consumed := mini(stored_count, remaining)
		_set_wire_slot_count(slot, stored_count - consumed)
		remaining -= consumed
	return requested_count - remaining


func _set_wire_slot_count(slot: Dictionary, next_count: int) -> void:
	if next_count > 0:
		slot["stack_count"] = next_count
		return
	slot["config_path"] = ""
	slot["stack_count"] = 0


func _get_wire_slot_capacity(slots: Array, item: PickupConfig) -> int:
	if (
		item == null
		or not item.can_store_in_inventory
		or item.resource_path.is_empty()
	):
		return 0
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	var capacity := 0
	for raw_slot_value in slots:
		if typeof(raw_slot_value) != TYPE_DICTIONARY:
			return 0
		var slot := raw_slot_value as Dictionary
		var path := str(slot.get("config_path", ""))
		if path.is_empty():
			capacity += stack_limit
		elif item.stackable and path == item.resource_path:
			capacity += maxi(stack_limit - int(slot.get("stack_count", 0)), 0)
	return capacity


## Full-batch insertion. Insufficient capacity leaves every slot untouched.
func _add_item_count_to_wire_slots(
	slots: Array,
	item: PickupConfig,
	count: int
) -> int:
	if count <= 0 or _get_wire_slot_capacity(slots, item) < count:
		return 0
	var remaining := count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	if item.stackable:
		for raw_slot_value in slots:
			if remaining <= 0:
				break
			var slot := raw_slot_value as Dictionary
			if str(slot.get("config_path", "")) != item.resource_path:
				continue
			var room := maxi(stack_limit - int(slot.get("stack_count", 0)), 0)
			var added := mini(room, remaining)
			slot["stack_count"] = int(slot.get("stack_count", 0)) + added
			remaining -= added
	for raw_slot_value in slots:
		if remaining <= 0:
			break
		var slot := raw_slot_value as Dictionary
		if not str(slot.get("config_path", "")).is_empty():
			continue
		var added := mini(stack_limit, remaining)
		slot["config_path"] = item.resource_path
		slot["stack_count"] = added
		remaining -= added
	return count - remaining


func _try_add_item_count_to_warehouse_ledger(
	ledger: Dictionary,
	item: PickupConfig,
	count: int
) -> Dictionary:
	if item == null or count <= 0:
		return {"success": false, "warehouse_net_ids": []}
	var warehouses := ledger.get("warehouses", []) as Array
	warehouses.sort_custom(
		func(left: Variant, right: Variant) -> bool:
			return int((left as Dictionary).get("warehouse_net_id", -1)) < int(
				(right as Dictionary).get("warehouse_net_id", -1)
			)
	)
	var total_capacity := 0
	for raw_warehouse_value in warehouses:
		total_capacity += _get_wire_slot_capacity(
			(raw_warehouse_value as Dictionary).get("slots", []) as Array,
			item
		)
	if total_capacity < count:
		return {"success": false, "warehouse_net_ids": []}
	var remaining := count
	var touched_warehouse_ids: Array[int] = []
	for raw_warehouse_value in warehouses:
		if remaining <= 0:
			break
		var warehouse := raw_warehouse_value as Dictionary
		var slots := warehouse.get("slots", []) as Array
		var added := _add_item_count_to_wire_slots(
			slots,
			item,
			mini(_get_wire_slot_capacity(slots, item), remaining)
		)
		if added <= 0:
			continue
		remaining -= added
		warehouse["revision"] = int(warehouse.get("revision", 0)) + 1
		touched_warehouse_ids.append(int(warehouse.get("warehouse_net_id", -1)))
	if remaining != 0:
		return {"success": false, "warehouse_net_ids": []}
	ledger["revision"] = int(ledger.get("revision", 0)) + 1
	return {
		"success": true,
		"warehouse_net_ids": touched_warehouse_ids,
	}


func _add_item_to_inventory(
	inventory_snapshot: Dictionary,
	item: PickupConfig
) -> bool:
	return _add_item_count_to_wire_slots(
		inventory_snapshot.get("slots", []) as Array,
		item,
		1
	) == 1


func _rotated_peer_ids(peer_ids: Array[int], offset: int) -> Array[int]:
	if peer_ids.is_empty():
		return []
	var result: Array[int] = []
	for index in peer_ids.size():
		result.append(peer_ids[(index + offset) % peer_ids.size()])
	return result
