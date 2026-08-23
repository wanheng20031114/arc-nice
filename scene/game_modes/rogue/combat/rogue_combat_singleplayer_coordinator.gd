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
signal battle_outcome_committed(victory: bool, occurrence_key: String)

const SINGLEPLAYER_PEER_ID := 0
const INVALID_NODE_ID := -1
const BATTLE_NODE_NAME := "RogueCombatBattle"
const YUANSHI_FIRE_PROJECTILE_POOL_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)
const UNDERGROUND_SEWER_COMBAT_CONFIG_ID := &"underground_sewer_01"
const EMERGENCY_UNDERGROUND_SEWER_COMBAT_CONFIG_ID := (
	&"emergency_underground_sewer_01"
)
const UNDERGROUND_SEWER_FIRE_PROJECTILE_PREWARM_COUNT := 48
const UNDERGROUND_SEWER_FIRE_PROJECTILE_RETAINED_CAPACITY := 192
const SINGLEPLAYER_STABLE_IDENTITY := "singleplayer:local"
const INVALID_REWARD_OFFER_INDEX := -1

var route: RogueRouteGame = null
var active_battle: RogueCombatGame = null
var player_persistent_modifier_projector: PlayerPersistentModifierProjector = null

var _enabled := false
var _settling_outcome := false
var _waiting_for_result_dismissal := false
var _active_node_id := INVALID_NODE_ID
var _active_content_seed := 0
var _active_occurrence_key := ""
var _active_encounter_config: RogueCombatEncounterConfig = null
var _pending_victory := false
var _pending_result: Dictionary = {}
var _consumed_node_ids: Dictionary[int, bool] = {}
var _committed_outcome_occurrences: Dictionary[String, bool] = {}
var _last_result: Dictionary = {}
var _victory_sequence_serial := 0
var _emergency_reward_session: RogueEmergencyRewardSelectionSession = null
var _emergency_reward_overlay: RogueEmergencyRewardChoiceOverlay = null
var _emergency_reward_pending_offer_index := INVALID_REWARD_OFFER_INDEX
var _emergency_reward_settlement_retry_pending := false


func _ready() -> void:
	var parent_route := get_parent() as RogueRouteGame
	if (
		parent_route == null
		or not parent_route.manage_return_locally
	):
		return
	_bind_route(parent_route)


## 嵌入式战役在父场景完成运行模式选择后显式绑定，避免多人场景误启单人作战。
func bind_embedded_route(route_instance: RogueRouteGame) -> bool:
	if route_instance == null or not route_instance.embedded_session:
		return false
	if route != null and route != route_instance:
		return false
	_bind_route(route_instance)
	return _enabled


## Tower 嵌入式探索在创建任何作战 Player 之前注入持久层投影器。
func configure_player_persistent_modifier_projector(
	projector: PlayerPersistentModifierProjector
) -> void:
	player_persistent_modifier_projector = projector


func _bind_route(route_instance: RogueRouteGame) -> void:
	if _enabled or not _has_enabled_singleplayer_combat_pool(route_instance):
		return
	route = route_instance
	route.combat_requested.connect(_on_combat_requested)
	route.combat_result_dismissed.connect(_on_combat_result_dismissed)
	route.host_layout_committed.connect(_on_host_layout_committed)
	route.normal_combat_stage_reset.connect(_on_normal_combat_stage_reset)
	route.normal_combat_snapshot_reconciled.connect(
		_on_normal_combat_snapshot_reconciled
	)
	_enabled = true


static func _has_enabled_singleplayer_combat_pool(
	parent_route: RogueRouteGame
) -> bool:
	if (
		parent_route == null
		or parent_route.floor_definition == null
		or parent_route.floor_definition.normal_combat_pool == null
		or not parent_route.floor_definition.normal_combat_pool.is_ready_to_enable()
		or parent_route.floor_definition.emergency_combat_pool == null
		or not parent_route.floor_definition.emergency_combat_pool.is_ready_to_enable()
	):
		return false
	var configs: Array[RogueCombatEncounterConfig] = []
	configs.append_array(
		parent_route.floor_definition.get_sorted_normal_combat_configs()
	)
	configs.append_array(
		parent_route.floor_definition.get_sorted_emergency_combat_configs()
	)
	if configs.is_empty():
		return false
	for config in configs:
		if (
			config == null
			or not config.is_ready_to_enable()
			or config.support_singleplayer
			!= RogueCombatEncounterConfig.Decision.YES
		):
			return false
	return true


func _exit_tree() -> void:
	_victory_sequence_serial += 1
	_reset_emergency_reward_selection()
	if route != null and is_instance_valid(route):
		route.combat_victory_presentation.interrupt_and_reset()
		route.combat_scene_transition.hide_immediately()
	_disconnect_route_signals()
	active_battle = null
	route = null


func _process(delta: float) -> void:
	if (
		_emergency_reward_session == null
		or not _settling_outcome
		or not _pending_victory
	):
		return
	if (
		_emergency_reward_session.is_choosing()
		and not _has_locked_emergency_reward_choice()
	):
		_emergency_reward_session.advance(delta)
	if (
		_emergency_reward_session != null
		and _emergency_reward_session.is_ready_to_settle()
		and not _emergency_reward_settlement_retry_pending
	):
		_complete_emergency_rewards()


func _has_locked_emergency_reward_choice() -> bool:
	if _emergency_reward_pending_offer_index != INVALID_REWARD_OFFER_INDEX:
		return true
	if _emergency_reward_session == null:
		return false
	var peer_state := _emergency_reward_session.get_peer_state(
		SINGLEPLAYER_PEER_ID
	)
	return int(peer_state.get(
		"timeout_choice_index",
		INVALID_REWARD_OFFER_INDEX
	)) != INVALID_REWARD_OFFER_INDEX


func is_enabled() -> bool:
	return _enabled


func is_runtime_busy() -> bool:
	return (
		active_battle != null
		or _settling_outcome
		or _waiting_for_result_dismissal
		or _emergency_reward_session != null
		or _emergency_reward_pending_offer_index != INVALID_REWARD_OFFER_INDEX
		or _emergency_reward_settlement_retry_pending
	)


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
		_committed_outcome_occurrences.clear()


func _on_combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	combat_config_id: StringName
) -> void:
	if not _enabled or route == null:
		return
	if _consumed_node_ids.has(node_id):
		route.abort_briefing_entry(occurrence_key)
		route.complete_normal_combat(occurrence_key)
		return
	if active_battle != null or _settling_outcome:
		push_error("单人 Rouge 作战协调器收到重叠的战斗请求。")
		return
	var resolved_config: RogueCombatEncounterConfig = (
		route.resolve_combat_config(combat_config_id) as RogueCombatEncounterConfig
	)
	_active_encounter_config = resolved_config
	if (
		_active_encounter_config == null
		or not _active_encounter_config.is_ready_to_enable()
		or _active_encounter_config.support_singleplayer
		!= RogueCombatEncounterConfig.Decision.YES
	):
		_recover_route_from_start_failure(occurrence_key)
		return

	var occurrence_campaign := _build_occurrence_campaign(occurrence_key)
	if occurrence_campaign == null:
		_recover_route_from_start_failure(occurrence_key)
		return
	var combat_scene := load(_active_encounter_config.combat_scene_path) as PackedScene
	if combat_scene == null:
		push_error(
			"无法加载单人 Rouge 作战场景：%s"
			% _active_encounter_config.combat_scene_path
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
		_active_encounter_config.get_spawn_point_mask()
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
	_apply_underground_sewer_projectile_pool_overrides(
		battle.session_object_pool,
		_active_encounter_config.encounter_id
	)
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null:
		battle.player.set_run_max_health_penalty(
			run_state.get_max_health_penalty_for_peer(SINGLEPLAYER_PEER_ID)
		)

	# RoguePlayerRosterCoordinator 会先应用肉鸽作战的 1000 息壤。若选择继承，则在新增
	# 战场后的首个物理帧前立即覆盖，确保玩家没有一帧使用错误经济状态。
	if (
		_active_encounter_config.inherit_route_xirang
		== RogueCombatEncounterConfig.Decision.YES
		and route.player != null
		and is_instance_valid(route.player)
	):
		_set_player_xirang(battle.player, route.player.current_xirang)
	battle.random_generator.seed = content_seed
	battle_started.emit(node_id, occurrence_key, battle)
	_activate_battle_when_prepared(battle, occurrence_key)


func _apply_underground_sewer_projectile_pool_overrides(
	pool: SessionObjectPool,
	encounter_id: StringName
) -> void:
	if (
		pool == null
		or not (
			encounter_id == UNDERGROUND_SEWER_COMBAT_CONFIG_ID
			or encounter_id == EMERGENCY_UNDERGROUND_SEWER_COMBAT_CONFIG_ID
		)
	):
		return
	# 火焰弹理论并发约30；48个预热实例保留余量，192回收上限沿用公共池。
	pool.register_scene(
		YUANSHI_FIRE_PROJECTILE_POOL_SCENE,
		UNDERGROUND_SEWER_FIRE_PROJECTILE_PREWARM_COUNT,
		UNDERGROUND_SEWER_FIRE_PROJECTILE_RETAINED_CAPACITY
	)


func _configure_battle_before_tree(
	battle: RogueCombatGame,
	campaign: WaveCampaignConfig
) -> void:
	battle.name = BATTLE_NODE_NAME
	battle.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	battle.singleplayer_campaign = campaign
	battle.multiplayer_campaign = campaign
	battle.event_title = _active_encounter_config.event_title
	battle.pre_wave_duration = float(_active_encounter_config.preparation_seconds)
	battle.combat_time_limit_seconds = float(
		_active_encounter_config.combat_limit_seconds
	)
	battle.deadline_start = (
		RogueCombatGame.DeadlineStart.PREPARATION_START
		if _active_encounter_config.deadline_start
		== RogueCombatEncounterConfig.DeadlineStart.PREPARATION_START
		else RogueCombatGame.DeadlineStart.WAVE_START
	)
	battle.enemy_pickup_drops_enabled = (
		_active_encounter_config.enemy_pickup_drops
		== RogueCombatEncounterConfig.Decision.YES
	)
	# 派生场景本身保持关闭；只有确认过完整策略的协调器才会打开自动流程。
	battle.auto_start_waves = true
	battle.defer_runtime_activation()
	battle.configure_player_persistent_modifier_projector(
		player_persistent_modifier_projector
	)


func _build_occurrence_campaign(
	occurrence_key: String
) -> WaveCampaignConfig:
	return _active_encounter_config.build_occurrence_campaign(occurrence_key)


func _activate_battle_when_prepared(
	battle: RogueCombatGame,
	occurrence_key: String
) -> void:
	var preparation := battle.get_runtime_preparation_snapshot()
	var preparation_generation := preparation.generation
	while preparation.state == RuntimePreparationProvider.PreparationState.PREPARING:
		await battle.runtime_preparation_state_changed
		if battle != active_battle or not is_instance_valid(battle):
			return
		preparation = battle.get_runtime_preparation_snapshot()
		# 旧战斗的等待协程不能接管复用节点后开启的新准备周期。
		if preparation.generation != preparation_generation:
			return
	if (
		battle != active_battle
		or not is_instance_valid(battle)
		or occurrence_key != _active_occurrence_key
		or _settling_outcome
	):
		return
	if preparation.state != RuntimePreparationProvider.PreparationState.READY:
		_dispose_active_battle()
		_recover_route_from_start_failure(occurrence_key)
		return
	route.complete_briefing_entry(occurrence_key)
	var entry_revealed := await route.reveal_normal_combat_entry(
		occurrence_key
	)
	if (
		battle != active_battle
		or not is_instance_valid(battle)
		or occurrence_key != _active_occurrence_key
		or _settling_outcome
	):
		return
	if not entry_revealed:
		_dispose_active_battle()
		_recover_route_from_start_failure(occurrence_key)
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
	_emit_battle_outcome_committed_once(victory, _active_occurrence_key)
	if victory and _uses_emergency_reward_selection():
		_consumed_node_ids[_active_node_id] = true
		if _begin_emergency_reward_selection():
			return
		_pending_result = _make_victory_reward_failure_result(
			&"emergency_reward_session_start_failed"
		)
		_last_result = _pending_result.duplicate(true)
		_play_victory_return_sequence()
		return
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
		_active_encounter_config.consume_node_on_failure
		== RogueCombatEncounterConfig.Decision.YES
	):
		_consumed_node_ids[_active_node_id] = true
	if victory:
		_play_victory_return_sequence()
		return

	var should_show_result := (
		_active_encounter_config.show_failure_result
		== RogueCombatEncounterConfig.Decision.YES
	)
	if not should_show_result:
		_finalize_return_from_battle()
		return
	if (
		_active_encounter_config.return_to_route_before_result
		== RogueCombatEncounterConfig.Decision.YES
	):
		var returned_result := _pending_result.duplicate(true)
		_finalize_return_from_battle()
		if route != null:
			_show_route_combat_result(returned_result)
		return

	_waiting_for_result_dismissal = true
	if not _show_route_combat_result(_pending_result):
		_waiting_for_result_dismissal = false
		_finalize_return_from_battle()


func _emit_battle_outcome_committed_once(
	victory: bool,
	occurrence_key: String
) -> void:
	if (
		occurrence_key.is_empty()
		or _committed_outcome_occurrences.has(occurrence_key)
	):
		return
	_committed_outcome_occurrences[occurrence_key] = true
	battle_outcome_committed.emit(victory, occurrence_key)


func _uses_emergency_reward_selection() -> bool:
	return (
		route != null
		and _active_encounter_config != null
		and _active_encounter_config.reward_config != null
		and _active_encounter_config.reward_config.uses_collectible_choices()
		and route.is_emergency_combat_config_id(
			_active_encounter_config.encounter_id
		)
	)


func _begin_emergency_reward_selection() -> bool:
	if (
		active_battle == null
		or active_battle.player == null
		or not is_instance_valid(active_battle.player)
		or active_battle.run_state == null
		or route == null
		or route.emergency_reward_choice_overlay == null
	):
		return false
	_reset_emergency_reward_selection()
	_emergency_reward_overlay = route.emergency_reward_choice_overlay
	_emergency_reward_session = RogueEmergencyRewardSelectionSession.new()
	var choice_callable := Callable(self, "_on_emergency_reward_choice_selected")
	var inventory_callable := Callable(
		self,
		"_on_emergency_reward_inventory_requested"
	)
	var state_callable := Callable(
		self,
		"_on_emergency_reward_state_changed"
	)
	_emergency_reward_overlay.choice_selected.connect(choice_callable)
	_emergency_reward_overlay.inventory_requested.connect(inventory_callable)
	_emergency_reward_session.state_changed.connect(state_callable)
	active_battle.player_profile_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	var reward_player := active_battle.player
	var began := _emergency_reward_session.begin_authority(
		active_battle.run_state,
		StringName(_active_occurrence_key),
		_active_content_seed,
		[SINGLEPLAYER_PEER_ID] as Array[int],
		_active_encounter_config.reward_config,
		_active_encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES,
		{SINGLEPLAYER_PEER_ID: SINGLEPLAYER_STABLE_IDENTITY},
		{SINGLEPLAYER_PEER_ID: reward_player.get_character_id()},
		{SINGLEPLAYER_PEER_ID: reward_player.get_xirang()}
	)
	if not began:
		push_error("单人紧急作战奖励选择会话初始化失败。")
		_reset_emergency_reward_selection()
		return false
	_refresh_emergency_reward_overlay()
	return true


func _on_emergency_reward_state_changed(_snapshot: Dictionary) -> void:
	_refresh_emergency_reward_overlay()


func _refresh_emergency_reward_overlay() -> void:
	if (
		_emergency_reward_session == null
		or _emergency_reward_overlay == null
		or not is_instance_valid(_emergency_reward_overlay)
	):
		return
	if _emergency_reward_session.is_ready_to_settle():
		if _emergency_reward_settlement_retry_pending:
			_show_emergency_reward_settlement_retry()
		else:
			_emergency_reward_overlay.set_waiting("两轮选择已完成 · 正在发放奖励")
		return
	if not _emergency_reward_session.is_choosing():
		return
	var peer_state := _emergency_reward_session.get_peer_state(
		SINGLEPLAYER_PEER_ID
	)
	if peer_state.is_empty():
		return
	var round_index := int(peer_state.get("round_index", 0))
	var remaining_seconds := float(peer_state.get("remaining_seconds", 0.0))
	var timeout_offer_index := int(
		peer_state.get("timeout_choice_index", INVALID_REWARD_OFFER_INDEX)
	)
	var locked_offer_index := timeout_offer_index
	if _emergency_reward_pending_offer_index != INVALID_REWARD_OFFER_INDEX:
		locked_offer_index = _emergency_reward_pending_offer_index
	_emergency_reward_overlay.show_round(
		_emergency_reward_session.get_current_offer_paths(
			SINGLEPLAYER_PEER_ID
		),
		round_index + 1,
		_active_encounter_config.reward_config.collectible_choice_round_count,
		remaining_seconds,
		"请选择其中一件收藏品",
		locked_offer_index == INVALID_REWARD_OFFER_INDEX,
		true
	)
	if locked_offer_index != INVALID_REWARD_OFFER_INDEX:
		_emergency_reward_overlay.set_choice_pending(
			locked_offer_index,
			"当前收藏品选择已保留"
		)
		_emergency_reward_overlay.show_inventory_full_error()
		_emergency_reward_overlay.countdown_timer.stop()


func _on_emergency_reward_choice_selected(
	round_number: int,
	offer_index: int
) -> void:
	if _emergency_reward_session == null:
		return
	if (
		_emergency_reward_session.is_ready_to_settle()
		and _emergency_reward_settlement_retry_pending
	):
		_complete_emergency_rewards()
		return
	if not _emergency_reward_session.is_choosing():
		return
	var requested_offer_index := offer_index
	if _emergency_reward_pending_offer_index != INVALID_REWARD_OFFER_INDEX:
		requested_offer_index = _emergency_reward_pending_offer_index
	var choice_result := _emergency_reward_session.submit_choice(
		SINGLEPLAYER_PEER_ID,
		_active_occurrence_key,
		round_number - 1,
		requested_offer_index
	)
	if bool(choice_result.get("accepted", false)):
		_emergency_reward_pending_offer_index = INVALID_REWARD_OFFER_INDEX
		_refresh_emergency_reward_overlay()
		if _emergency_reward_session.is_ready_to_settle():
			_complete_emergency_rewards()
		return
	var reason := StringName(choice_result.get(
		"reason",
		RogueEmergencyRewardSelectionSession.REASON_INVALID_REQUEST
	))
	if reason == RogueEmergencyRewardSelectionSession.REASON_INVENTORY_FULL:
		_emergency_reward_pending_offer_index = requested_offer_index
		_refresh_emergency_reward_overlay()
		return
	push_error("单人紧急作战收藏品选择失败：%s" % String(reason))
	_refresh_emergency_reward_overlay()


func _on_emergency_reward_inventory_requested() -> void:
	if (
		active_battle == null
		or not is_instance_valid(active_battle)
		or active_battle.player_profile_panel == null
	):
		return
	active_battle.player_profile_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	active_battle.player_profile_panel.open()


func _complete_emergency_rewards() -> void:
	if (
		_emergency_reward_session == null
		or not _emergency_reward_session.is_ready_to_settle()
	):
		return
	_emergency_reward_settlement_retry_pending = false
	var batch_result := _emergency_reward_session.complete_rewards()
	if not bool(batch_result.get("resolved", false)):
		var reason := StringName(batch_result.get(
			"failure_reason",
			RogueCombatRewardResolver.FAILURE_TRANSACTION_CONFLICT
		))
		if reason in [
			RogueCombatRewardResolver.FAILURE_INVENTORY_FULL,
			RogueCombatRewardResolver.FAILURE_TRANSACTION_CONFLICT,
		]:
			_emergency_reward_settlement_retry_pending = true
			_show_emergency_reward_settlement_retry(reason)
			return
		push_error("单人紧急作战奖励原子结算失败：%s" % String(reason))
		_finish_emergency_reward_resolution(
			_make_victory_reward_failure_result(reason)
		)
		return
	var results_by_peer := batch_result.get("results_by_peer", {}) as Dictionary
	var result := results_by_peer.get(SINGLEPLAYER_PEER_ID, {}) as Dictionary
	if result.is_empty():
		_finish_emergency_reward_resolution(
			_make_victory_reward_failure_result(
				&"missing_local_reward_result"
			)
		)
		return
	var final_xirang_by_peer := (
		batch_result.get("final_xirang_by_peer", {}) as Dictionary
	)
	_set_player_xirang(
		active_battle.player,
		int(final_xirang_by_peer.get(
			SINGLEPLAYER_PEER_ID,
			active_battle.player.get_xirang()
		))
	)
	result["shared_light_stone_reward"] = int(
		batch_result.get("shared_light_stone_reward", 0)
	)
	result["random_item_path"] = str(
		batch_result.get("random_item_path", "")
	)
	result["random_item_count"] = int(
		batch_result.get("random_item_count", 0)
	)
	result["victory"] = true
	_finish_emergency_reward_resolution(result)


func _show_emergency_reward_settlement_retry(
	reason: StringName = RogueCombatRewardResolver.FAILURE_INVENTORY_FULL
) -> void:
	if (
		_emergency_reward_session == null
		or _emergency_reward_overlay == null
		or not is_instance_valid(_emergency_reward_overlay)
		or _active_encounter_config == null
	):
		return
	var peer_state := _emergency_reward_session.get_peer_state(
		SINGLEPLAYER_PEER_ID
	)
	var rounds := peer_state.get("rounds", []) as Array
	var selected_paths := peer_state.get("selected_paths", []) as Array
	if rounds.is_empty() or selected_paths.is_empty():
		return
	var last_round := rounds[rounds.size() - 1] as Dictionary
	var offer_paths := last_round.get("paths", []) as Array
	var selected_path := str(selected_paths[selected_paths.size() - 1])
	var selected_offer_index := offer_paths.find(selected_path)
	_emergency_reward_overlay.show_round(
		offer_paths,
		rounds.size(),
		_active_encounter_config.reward_config.collectible_choice_round_count,
		0.0,
		"奖励发放需要重新确认",
		false,
		true
	)
	_emergency_reward_overlay.set_choice_pending(selected_offer_index)
	_emergency_reward_overlay.show_inventory_full_error(
		(
			"结算状态已变化 · 请重试发放"
			if reason == RogueCombatRewardResolver.FAILURE_TRANSACTION_CONFLICT
			else "背包空间不足 · 奖励选择已保留，请整理背包后重试"
		)
	)


func _finish_emergency_reward_resolution(result: Dictionary) -> void:
	_pending_result = result.duplicate(true)
	_last_result = _pending_result.duplicate(true)
	_reset_emergency_reward_selection()
	_play_victory_return_sequence()


func _make_victory_reward_failure_result(reason: StringName) -> Dictionary:
	return {
		"victory": true,
		"extra_xirang": 0,
		"loot": _make_empty_loot_result(),
		"item_rewards": [],
		"reward_failure_reason": reason,
	}


func _resolve_victory_result() -> Dictionary:
	var reward_player := active_battle.player
	var reward_eligible := (
		reward_player != null
		and is_instance_valid(reward_player)
		and (
			not reward_player.is_dead
			or _active_encounter_config.reward_dead_players_on_victory
			== RogueCombatEncounterConfig.Decision.YES
		)
	)
	if not reward_eligible:
		return {
			"victory": true,
			"extra_xirang": 0,
			"loot": _make_empty_loot_result(),
			"item_rewards": [],
		}

	var peer_ids: Array[int] = [SINGLEPLAYER_PEER_ID]
	var batch_result := RogueCombatRewardResolver.resolve_party_rewards(
		active_battle.run_state,
		StringName(_active_occurrence_key),
		_active_content_seed,
		peer_ids,
		_active_encounter_config.reward_config,
		_active_encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES,
		{SINGLEPLAYER_PEER_ID: reward_player},
		{SINGLEPLAYER_PEER_ID: reward_player.get_xirang()},
		{SINGLEPLAYER_PEER_ID: "singleplayer:local"}
	)
	if not bool(batch_result.get("resolved", false)):
		push_error(
			"单人 Rouge 作战奖励原子结算失败：%s"
			% str(batch_result.get("failure_reason", "unknown"))
		)
		return {
			"victory": true,
			"extra_xirang": 0,
			"loot": _make_empty_loot_result(),
			"item_rewards": [],
			"reward_failure_reason": batch_result.get(
				"failure_reason",
				RogueCombatRewardResolver.FAILURE_TRANSACTION_CONFLICT
			),
		}
	var results_by_peer := batch_result.get("results_by_peer", {}) as Dictionary
	var result := results_by_peer.get(SINGLEPLAYER_PEER_ID, {}) as Dictionary
	if result.is_empty():
		return {
			"victory": true,
			"extra_xirang": 0,
			"loot": _make_empty_loot_result(),
			"item_rewards": [],
			"reward_failure_reason": &"missing_local_reward_result",
		}
	var final_xirang_by_peer := (
		batch_result.get("final_xirang_by_peer", {}) as Dictionary
	)
	_set_player_xirang(
		reward_player,
		int(final_xirang_by_peer.get(
			SINGLEPLAYER_PEER_ID,
			reward_player.get_xirang()
		))
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


func _show_route_combat_result(result: Dictionary) -> bool:
	if route == null or not is_instance_valid(route):
		return false
	if not route.show_combat_result(result):
		return false
	if (
		bool(result.get("victory", false))
		and not (result.get("item_rewards", []) as Array).is_empty()
		and route.combat_result_overlay != null
	):
		route.combat_result_overlay.present_reward_result(result)
	return true


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
	if not _settle_active_battle_and_restore_route_player():
		push_error("单人 Rogue 作战无法提交返回边界，保留战场等待修复。")
		return
	route.complete_normal_combat(completed_occurrence_key)
	_dispose_active_battle()
	route.set_route_presentation_enabled(true)
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
	_show_route_combat_result(completed_result)
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
	if route != null and is_instance_valid(route):
		route.combat_victory_presentation.interrupt_and_reset()
		route.combat_scene_transition.hide_immediately()
		if not _settle_active_battle_and_restore_route_player():
			push_error("单人 Rogue 中断返回无法提交边界，保留战场等待修复。")
			return
		_victory_sequence_serial += 1
		if (
			route.is_normal_combat_active()
			and occurrence_key == route.get_normal_combat_occurrence_key()
		):
			route.complete_normal_combat(occurrence_key)
	else:
		return
	_dispose_active_battle()
	if route != null and is_instance_valid(route):
		route.set_route_presentation_enabled(true)
		_show_route_combat_result(result)
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


## 权威全快照已决定最终路线/Briefing/经济。旧战场只做本地释放，不能
## 再走普通 cancel 的结算与 Route abort 路径覆盖新状态。
func _on_normal_combat_snapshot_reconciled(occurrence_key: String) -> void:
	if (
		occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
		or (active_battle == null and not _settling_outcome)
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
	_active_encounter_config = null


func _cancel_pending_victory_sequence(
	serial: int,
	occurrence_key: String
) -> void:
	if (
		serial != _victory_sequence_serial
		or occurrence_key != _active_occurrence_key
	):
		return
	if (
		active_battle != null
		and is_instance_valid(active_battle)
		and active_battle.runtime_activated
		and not _settle_active_battle_and_restore_route_player()
	):
		push_error("单人 Rogue 取消作战时无法提交已激活战场，拒绝释放。")
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
	_active_encounter_config = null


func _finalize_return_from_battle() -> void:
	if active_battle == null or route == null:
		return
	var completed_occurrence_key := _active_occurrence_key
	var completed_result := _pending_result.duplicate(true)
	var completed_victory := _pending_victory
	if not _settle_active_battle_and_restore_route_player():
		push_error("单人 Rogue 作战结束无法提交返回边界，保留战场等待修复。")
		return
	route.complete_normal_combat(completed_occurrence_key)
	_dispose_active_battle()
	route.set_route_presentation_enabled(true)
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
	_active_encounter_config = null
	battle_returned.emit(
		completed_victory,
		completed_occurrence_key,
		completed_result
	)


## 已激活战斗的所有离场都先经过这个提交屏障：本地 staged 余额进入 party
## 账本，再由完整成长快照恢复路线 Player 的面板、满血与无异常状态。
func _settle_active_battle_and_restore_route_player() -> bool:
	if not _copy_battle_xirang_to_route():
		return false
	if route == null or not is_instance_valid(route):
		return false
	return route.restore_players_for_route_scene_entry()


func _copy_battle_xirang_to_route() -> bool:
	if (
		active_battle == null
		or active_battle.player == null
		or not is_instance_valid(active_battle.player)
	):
		return false
	var final_xirang := active_battle.player.current_xirang
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if (
		run_state == null
		or not run_state.set_party_xirang_balance(
			SINGLEPLAYER_PEER_ID,
			final_xirang
		)
	):
		push_error("单人 Rogue 作战返回时无法提交最终息壤账本。")
		return false
	if (
		route == null
		or not is_instance_valid(route)
		or route.player == null
		or not is_instance_valid(route.player)
	):
		return false
	_set_player_xirang(route.player, final_xirang)
	return route.player.current_xirang == final_xirang


func _set_player_xirang(target: Player, amount: int) -> void:
	target.set_xirang_balance(amount)


func prepare_active_runtime_for_scene_teardown() -> void:
	if active_battle != null and is_instance_valid(active_battle):
		active_battle.prepare_for_scene_teardown()


func _dispose_active_battle() -> void:
	_reset_emergency_reward_selection()
	var battle := active_battle
	active_battle = null
	if battle == null or not is_instance_valid(battle):
		return
	battle.prepare_for_scene_teardown()
	if battle.get_parent() != null:
		battle.get_parent().remove_child(battle)
	battle.free()


func _reset_emergency_reward_selection() -> void:
	var overlay := _emergency_reward_overlay
	var session := _emergency_reward_session
	_emergency_reward_overlay = null
	_emergency_reward_session = null
	_emergency_reward_pending_offer_index = INVALID_REWARD_OFFER_INDEX
	_emergency_reward_settlement_retry_pending = false
	if session != null:
		var state_callable := Callable(
			self,
			"_on_emergency_reward_state_changed"
		)
		if session.state_changed.is_connected(state_callable):
			session.state_changed.disconnect(state_callable)
	if overlay != null and is_instance_valid(overlay):
		var choice_callable := Callable(
			self,
			"_on_emergency_reward_choice_selected"
		)
		var inventory_callable := Callable(
			self,
			"_on_emergency_reward_inventory_requested"
		)
		if overlay.choice_selected.is_connected(choice_callable):
			overlay.choice_selected.disconnect(choice_callable)
		if overlay.inventory_requested.is_connected(inventory_callable):
			overlay.inventory_requested.disconnect(inventory_callable)
		overlay.hide_and_reset()
	if (
		active_battle != null
		and is_instance_valid(active_battle)
		and active_battle.player_profile_panel != null
	):
		if active_battle.player_profile_panel.is_open():
			active_battle.player_profile_panel.close()
		active_battle.player_profile_panel.process_mode = (
			Node.PROCESS_MODE_INHERIT
		)


func _recover_route_from_start_failure(occurrence_key: String) -> void:
	_active_encounter_config = null
	if route == null:
		return
	_victory_sequence_serial += 1
	route.combat_victory_presentation.interrupt_and_reset()
	route.abort_briefing_entry(occurrence_key)
	route.complete_normal_combat(occurrence_key)
	route.set_route_presentation_enabled(true)


func _disconnect_route_signals() -> void:
	_enabled = false
	if route == null or not is_instance_valid(route):
		return
	var request_callable := Callable(self, "_on_combat_requested")
	if route.combat_requested.is_connected(request_callable):
		route.combat_requested.disconnect(request_callable)
	var dismissed_callable := Callable(self, "_on_combat_result_dismissed")
	if route.combat_result_dismissed.is_connected(dismissed_callable):
		route.combat_result_dismissed.disconnect(dismissed_callable)
	var layout_callable := Callable(self, "_on_host_layout_committed")
	if route.host_layout_committed.is_connected(layout_callable):
		route.host_layout_committed.disconnect(layout_callable)
	var reset_callable := Callable(self, "_on_normal_combat_stage_reset")
	if route.normal_combat_stage_reset.is_connected(reset_callable):
		route.normal_combat_stage_reset.disconnect(reset_callable)
	var snapshot_reset_callable := Callable(
		self,
		"_on_normal_combat_snapshot_reconciled"
	)
	if route.normal_combat_snapshot_reconciled.is_connected(
		snapshot_reset_callable
	):
		route.normal_combat_snapshot_reconciled.disconnect(
			snapshot_reset_callable
		)
