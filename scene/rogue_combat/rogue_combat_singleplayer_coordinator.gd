extends Node
class_name RogueCombatSingleplayerCoordinator

signal battle_started(
	node_id: int,
	occurrence_key: String,
	battle: RogueCombatGame
)
signal battle_returned(
	victory: bool,
	occurrence_key: String,
	result: Dictionary
)

const ENCOUNTER_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const SINGLEPLAYER_PEER_ID := 0
const INVALID_NODE_ID := -1
const BATTLE_NODE_NAME := "RogueCombatBattle"

@export var encounter_config: RogueCombatEncounterConfig = ENCOUNTER_CONFIG

var route: TestRogueRouteP3 = null
var active_battle: RogueCombatGame = null

var _enabled := false
var _settling_outcome := false
var _waiting_for_result_dismissal := false
var _active_node_id := INVALID_NODE_ID
var _active_content_seed := 0
var _active_occurrence_key := ""
var _pending_victory := false
var _pending_result: Dictionary = {}
var _consumed_node_ids: Dictionary[int, bool] = {}
var _last_result: Dictionary = {}
var _victory_sequence_serial := 0


func _ready() -> void:
	var parent_route := get_parent() as TestRogueRouteP3
	if (
		parent_route == null
		or not parent_route.manage_return_locally
		or encounter_config == null
		or not encounter_config.is_ready_to_enable()
		or encounter_config.support_singleplayer
		!= RogueCombatEncounterConfig.Decision.YES
	):
		return
	route = parent_route
	route.normal_combat_requested.connect(_on_normal_combat_requested)
	route.combat_result_dismissed.connect(_on_combat_result_dismissed)
	route.host_layout_committed.connect(_on_host_layout_committed)
	route.normal_combat_stage_reset.connect(_on_normal_combat_stage_reset)
	_enabled = true


func _exit_tree() -> void:
	_victory_sequence_serial += 1
	if route != null and is_instance_valid(route):
		route.combat_victory_presentation.interrupt_and_reset()
		route.combat_scene_transition.hide_immediately()
	_disconnect_route_signals()
	active_battle = null
	route = null


func is_enabled() -> bool:
	return _enabled


func is_node_consumed(node_id: int) -> bool:
	return _consumed_node_ids.has(node_id)


func get_active_battle() -> RogueCombatGame:
	return active_battle


func get_last_result() -> Dictionary:
	return _last_result.duplicate(true)


func _on_host_layout_committed(
	_layout_snapshot: Dictionary,
	_state_snapshot: Dictionary
) -> void:
	# 节点 ID 只在当前生成布局内有意义；重新生成路线后必须清空消费记录。
	if active_battle == null:
		_consumed_node_ids.clear()


func _on_normal_combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> void:
	if not _enabled or route == null:
		return
	if _consumed_node_ids.has(node_id):
		route.complete_normal_combat(occurrence_key)
		return
	if active_battle != null or _settling_outcome:
		push_error("单人 Rouge 作战协调器收到重叠的战斗请求。")
		return
	if not encounter_config.is_ready_to_enable():
		_recover_route_from_start_failure(occurrence_key)
		return

	var occurrence_campaign := _build_occurrence_campaign(occurrence_key)
	if occurrence_campaign == null:
		_recover_route_from_start_failure(occurrence_key)
		return
	var combat_scene := load(encounter_config.combat_scene_path) as PackedScene
	if combat_scene == null:
		push_error(
			"无法加载单人 Rouge 作战场景：%s"
			% encounter_config.combat_scene_path
		)
		_recover_route_from_start_failure(occurrence_key)
		return
	var instance := combat_scene.instantiate()
	var battle := instance as RogueCombatGame
	if battle == null:
		if instance != null:
			instance.free()
		push_error("Rouge 作战场景根节点必须是 RogueCombatGame。")
		_recover_route_from_start_failure(occurrence_key)
		return

	var scene_contract_errors := battle.validate_encounter_scene_contract(
		encounter_config.spawn_point_mask
	)
	if not scene_contract_errors.is_empty():
		for error in scene_contract_errors:
			push_error(error)
		battle.free()
		_recover_route_from_start_failure(occurrence_key)
		return
	_configure_battle_before_tree(battle, occurrence_campaign)

	_active_node_id = node_id
	_active_content_seed = content_seed
	_active_occurrence_key = occurrence_key
	active_battle = battle
	_settling_outcome = false
	_waiting_for_result_dismissal = false
	_pending_result.clear()
	route.hide_combat_result()
	route.set_route_presentation_enabled(false)
	battle.combat_outcome_started.connect(
		_on_battle_outcome_started.bind(battle)
	)
	route.add_child(battle)
	if battle.player == null:
		push_error("单人 Rouge 作战场景未能创建玩家。")
		_dispose_active_battle()
		_recover_route_from_start_failure(occurrence_key)
		return
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null:
		battle.player.set_run_max_health_penalty(
			run_state.get_max_health_penalty_for_peer(SINGLEPLAYER_PEER_ID)
		)

	# Game._ready() 会先应用普通模式的 1000 息壤。若选择继承，则在新增
	# 战场后的首个物理帧前立即覆盖，确保玩家没有一帧使用错误经济状态。
	if (
		encounter_config.inherit_route_xirang
		== RogueCombatEncounterConfig.Decision.YES
		and route.player != null
		and is_instance_valid(route.player)
	):
		_set_player_xirang(battle.player, route.player.current_xirang)
	battle.random_generator.seed = content_seed
	battle_started.emit(node_id, occurrence_key, battle)
	_activate_battle_when_prepared(battle, occurrence_key)


func _configure_battle_before_tree(
	battle: RogueCombatGame,
	campaign: WaveCampaignConfig
) -> void:
	battle.name = BATTLE_NODE_NAME
	battle.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	battle.singleplayer_campaign = campaign
	battle.multiplayer_campaign = campaign
	battle.event_title = encounter_config.event_title
	battle.pre_wave_duration = float(encounter_config.preparation_seconds)
	battle.combat_time_limit_seconds = float(
		encounter_config.combat_limit_seconds
	)
	battle.deadline_start = (
		RogueCombatGame.DeadlineStart.PREPARATION_START
		if encounter_config.deadline_start
		== RogueCombatEncounterConfig.DeadlineStart.PREPARATION_START
		else RogueCombatGame.DeadlineStart.WAVE_START
	)
	battle.enemy_pickup_drops_enabled = (
		encounter_config.enemy_pickup_drops
		== RogueCombatEncounterConfig.Decision.YES
	)
	# 派生场景本身保持关闭；只有确认过完整策略的协调器才会打开自动流程。
	battle.auto_start_waves = true
	battle.defer_runtime_activation()


func _build_occurrence_campaign(
	occurrence_key: String
) -> WaveCampaignConfig:
	return encounter_config.build_occurrence_campaign(occurrence_key)


func _activate_battle_when_prepared(
	battle: RogueCombatGame,
	occurrence_key: String
) -> void:
	if not battle.is_runtime_preparation_complete():
		await battle.runtime_preparation_completed
	if (
		battle != active_battle
		or not is_instance_valid(battle)
		or occurrence_key != _active_occurrence_key
		or _settling_outcome
	):
		return
	battle.activate_runtime()


func _on_battle_outcome_started(
	victory: bool,
	failure_reason: String,
	battle: RogueCombatGame
) -> void:
	if battle != active_battle or _settling_outcome:
		return
	_settling_outcome = true
	call_deferred(
		&"_freeze_and_resolve_active_outcome",
		victory,
		failure_reason,
		battle
	)


## 战斗结果可能由 CharacterBody2D 的碰撞回调触发。禁用战场根节点会
## 递归禁用其 CollisionObject 子节点，因此必须离开物理回调后再执行。
func _freeze_and_resolve_active_outcome(
	victory: bool,
	failure_reason: String,
	battle: RogueCombatGame
) -> void:
	if battle != active_battle or not is_instance_valid(battle):
		_settling_outcome = false
		return
	battle.process_mode = Node.PROCESS_MODE_DISABLED
	_resolve_active_outcome(victory, failure_reason)


func _resolve_active_outcome(victory: bool, failure_reason: String) -> void:
	if active_battle == null or route == null:
		return
	_pending_victory = victory
	_pending_result = (
		_resolve_victory_result()
		if victory
		else {
			"victory": false,
			"failure_reason": failure_reason,
		}
	)
	_last_result = _pending_result.duplicate(true)
	if victory:
		_consumed_node_ids[_active_node_id] = true
	elif (
		encounter_config.consume_node_on_failure
		== RogueCombatEncounterConfig.Decision.YES
	):
		_consumed_node_ids[_active_node_id] = true
	if victory:
		_play_victory_return_sequence()
		return

	var should_show_result := (
		encounter_config.show_failure_result
		== RogueCombatEncounterConfig.Decision.YES
	)
	if not should_show_result:
		_finalize_return_from_battle()
		return
	if (
		encounter_config.return_to_route_before_result
		== RogueCombatEncounterConfig.Decision.YES
	):
		var returned_result := _pending_result.duplicate(true)
		_finalize_return_from_battle()
		if route != null:
			route.show_combat_result(returned_result)
		return

	_waiting_for_result_dismissal = true
	if not route.show_combat_result(_pending_result):
		_waiting_for_result_dismissal = false
		_finalize_return_from_battle()


func _resolve_victory_result() -> Dictionary:
	var reward_player := active_battle.player
	var reward_eligible := (
		reward_player != null
		and is_instance_valid(reward_player)
		and (
			not reward_player.is_dead
			or encounter_config.reward_dead_players_on_victory
			== RogueCombatEncounterConfig.Decision.YES
		)
	)
	if not reward_eligible:
		return {
			"victory": true,
			"extra_xirang": 0,
			"loot": _make_empty_loot_result(),
		}

	reward_player.grant_xirang_reward(encounter_config.extra_xirang, false)
	var result := RogueCombatRewardResolver.resolve_reward(
		active_battle.run_state,
		StringName(_active_occurrence_key),
		_active_content_seed,
		SINGLEPLAYER_PEER_ID,
		encounter_config.extra_xirang,
		encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES,
		reward_player
	)
	result["victory"] = true
	return result


func _make_empty_loot_result() -> Dictionary:
	return {
		"config_path": "",
		"id": "",
		"name": "",
		"rarity": -1,
		"rarity_name": "",
		"granted": false,
		"failure_reason": &"reward_ineligible",
	}


func _on_combat_result_dismissed() -> void:
	if not _waiting_for_result_dismissal:
		return
	_waiting_for_result_dismissal = false
	call_deferred(&"_finalize_return_from_battle")


func _play_victory_return_sequence() -> void:
	if active_battle == null or route == null:
		return
	_victory_sequence_serial += 1
	var serial := _victory_sequence_serial
	var battle := active_battle
	var completed_occurrence_key := _active_occurrence_key
	var completed_result := _pending_result.duplicate(true)
	var presentation := route.combat_victory_presentation
	var transition := route.combat_scene_transition
	var title_completed := await presentation.play(battle.music_player)
	if not title_completed:
		_recover_interrupted_victory_sequence(
			serial,
			completed_occurrence_key,
			completed_result
		)
		return
	if not _is_current_victory_sequence(
		serial,
		battle,
		completed_occurrence_key
	):
		_recover_interrupted_victory_sequence(
			serial,
			completed_occurrence_key,
			completed_result
		)
		return
	var cover_completed := await transition.cover()
	if not cover_completed:
		_recover_interrupted_victory_sequence(
			serial,
			completed_occurrence_key,
			completed_result
		)
		return
	if not _is_current_victory_sequence(
		serial,
		battle,
		completed_occurrence_key
	):
		_recover_interrupted_victory_sequence(
			serial,
			completed_occurrence_key,
			completed_result
		)
		return
	_copy_battle_xirang_to_route()
	route.complete_normal_combat(completed_occurrence_key)
	route.set_route_presentation_enabled(true)
	_dispose_active_battle()
	var reveal_completed := await transition.reveal()
	if not reveal_completed:
		transition.hide_immediately()
		_cancel_pending_victory_sequence(serial, completed_occurrence_key)
		return
	if (
		serial != _victory_sequence_serial
		or route == null
		or not is_instance_valid(route)
	):
		return
	route.show_combat_result(completed_result)
	_complete_return_lifecycle(
		true,
		completed_occurrence_key,
		completed_result
	)


func _is_current_victory_sequence(
	serial: int,
	battle: RogueCombatGame,
	occurrence_key: String
) -> bool:
	return (
		serial == _victory_sequence_serial
		and route != null
		and is_instance_valid(route)
		and battle == active_battle
		and is_instance_valid(battle)
		and occurrence_key == _active_occurrence_key
		and route.is_normal_combat_active()
		and occurrence_key == route.get_normal_combat_occurrence_key()
		and _pending_victory
		and _settling_outcome
	)


func _recover_interrupted_victory_sequence(
	serial: int,
	occurrence_key: String,
	result: Dictionary
) -> void:
	if (
		serial != _victory_sequence_serial
		or occurrence_key != _active_occurrence_key
	):
		return
	_victory_sequence_serial += 1
	if route != null and is_instance_valid(route):
		route.combat_victory_presentation.interrupt_and_reset()
		route.combat_scene_transition.hide_immediately()
		_copy_battle_xirang_to_route()
		if (
			route.is_normal_combat_active()
			and occurrence_key == route.get_normal_combat_occurrence_key()
		):
			route.complete_normal_combat(occurrence_key)
		route.set_route_presentation_enabled(true)
	_dispose_active_battle()
	if route != null and is_instance_valid(route):
		route.show_combat_result(result)
	_complete_return_lifecycle(true, occurrence_key, result)


func _on_normal_combat_stage_reset(occurrence_key: String) -> void:
	if (
		(active_battle == null and not _settling_outcome)
		or (
			not occurrence_key.is_empty()
			and occurrence_key != _active_occurrence_key
		)
	):
		return
	_cancel_pending_victory_sequence(
		_victory_sequence_serial,
		_active_occurrence_key
	)


func _cancel_pending_victory_sequence(
	serial: int,
	occurrence_key: String
) -> void:
	if (
		serial != _victory_sequence_serial
		or occurrence_key != _active_occurrence_key
	):
		return
	_victory_sequence_serial += 1
	_dispose_active_battle()
	_pending_victory = false
	_pending_result.clear()
	_settling_outcome = false
	_waiting_for_result_dismissal = false
	_active_node_id = INVALID_NODE_ID
	_active_content_seed = 0
	_active_occurrence_key = ""


func _finalize_return_from_battle() -> void:
	if active_battle == null or route == null:
		return
	var completed_occurrence_key := _active_occurrence_key
	var completed_result := _pending_result.duplicate(true)
	var completed_victory := _pending_victory
	_copy_battle_xirang_to_route()
	route.complete_normal_combat(completed_occurrence_key)
	route.set_route_presentation_enabled(true)
	_dispose_active_battle()
	_complete_return_lifecycle(
		completed_victory,
		completed_occurrence_key,
		completed_result
	)


func _complete_return_lifecycle(
	completed_victory: bool,
	completed_occurrence_key: String,
	completed_result: Dictionary
) -> void:
	_pending_result.clear()
	_pending_victory = false
	_settling_outcome = false
	_waiting_for_result_dismissal = false
	_active_node_id = INVALID_NODE_ID
	_active_content_seed = 0
	_active_occurrence_key = ""
	battle_returned.emit(
		completed_victory,
		completed_occurrence_key,
		completed_result
	)


func _copy_battle_xirang_to_route() -> void:
	if (
		active_battle == null
		or active_battle.player == null
		or not is_instance_valid(active_battle.player)
		or route == null
		or route.player == null
		or not is_instance_valid(route.player)
	):
		return
	_set_player_xirang(route.player, active_battle.player.current_xirang)


func _set_player_xirang(target: Player, amount: int) -> void:
	var normalized_amount := maxi(amount, 0)
	if target.current_xirang == normalized_amount:
		return
	target.current_xirang = normalized_amount
	target.xirang_changed.emit(target.current_xirang, 0)


func _dispose_active_battle() -> void:
	var battle := active_battle
	active_battle = null
	if battle == null or not is_instance_valid(battle):
		return
	if battle.get_parent() != null:
		battle.get_parent().remove_child(battle)
	battle.free()


func _recover_route_from_start_failure(occurrence_key: String) -> void:
	if route == null:
		return
	_victory_sequence_serial += 1
	route.combat_victory_presentation.interrupt_and_reset()
	route.combat_scene_transition.hide_immediately()
	route.complete_normal_combat(occurrence_key)
	route.set_route_presentation_enabled(true)


func _disconnect_route_signals() -> void:
	_enabled = false
	if route == null or not is_instance_valid(route):
		return
	var request_callable := Callable(self, "_on_normal_combat_requested")
	if route.normal_combat_requested.is_connected(request_callable):
		route.normal_combat_requested.disconnect(request_callable)
	var dismissed_callable := Callable(self, "_on_combat_result_dismissed")
	if route.combat_result_dismissed.is_connected(dismissed_callable):
		route.combat_result_dismissed.disconnect(dismissed_callable)
	var layout_callable := Callable(self, "_on_host_layout_committed")
	if route.host_layout_committed.is_connected(layout_callable):
		route.host_layout_committed.disconnect(layout_callable)
	var reset_callable := Callable(self, "_on_normal_combat_stage_reset")
	if route.normal_combat_stage_reset.is_connected(reset_callable):
		route.normal_combat_stage_reset.disconnect(reset_callable)
