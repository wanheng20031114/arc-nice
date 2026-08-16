extends Node
class_name TowerDefenseFateFlowCoordinator

const COMBAT_ACTION_LOCK_OWNER := &"tower_fate_interlude"

const XIAOCONG_INTERACTION_DISTANCE := 220.0

signal local_interaction_requested
signal local_fate_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
)
signal local_collectible_choice_requested(choice_index: int)
signal state_snapshot_changed(snapshot: Dictionary)

var campaign_coordinator: TowerDefenseCampaignCoordinator
var rogue_exploration_coordinator: TowerDefenseRogueExplorationCoordinator
var fate_coordinator: FateCoordinator
var fate_manager: TowerDefenseFateManager
var player_roster_coordinator: TowerDefensePlayerRosterCoordinator
var plant_placement_coordinator: TowerDefensePlantPlacementCoordinator
var presentation_coordinator: TowerDefensePresentationCoordinator
var multiplayer_adapter: TowerDefenseMultiplayerModeAdapter
var multiplayer_gateway: MultiplayerGameplayGateway
var xiaocong_fate_interlude: XiaocongFateInterlude
var plant_terrain_decay_timer: Timer
var production_coordinator: ProductionCoordinator
var research_coordinator: ResearchCoordinator
var plant_placement_controller: PlantPlacementController
var wave_hud: TowerDefenseWaveHUD
var tower_defense_status_hud: TowerDefenseStatusHUD
var tower_defense_minimap: TowerDefenseMinimap

var interlude_systems_frozen := false
var frozen_placement_input_enabled := false
var frozen_placement_unhandled_input_enabled := false
var frozen_production_processing_enabled := false
var frozen_research_processing_enabled := false
var frozen_terrain_decay_was_running := false
var frozen_terrain_decay_time_left := 0.0
var authority_departure_in_progress := false
var remote_entry_in_progress := false
var remote_departure_in_progress := false
var remote_departure_covered := false
var remote_fate_conclusion_pending := false
var remote_fate_presentation_deferred := false
var pending_remote_flow_state: Dictionary = {}


func setup(
	configured_campaign: TowerDefenseCampaignCoordinator,
	configured_rogue_exploration: TowerDefenseRogueExplorationCoordinator,
	configured_fate_coordinator: FateCoordinator,
	configured_fate_manager: TowerDefenseFateManager,
	configured_player_roster: TowerDefensePlayerRosterCoordinator,
	configured_plant_placement: TowerDefensePlantPlacementCoordinator,
	configured_presentation: TowerDefensePresentationCoordinator,
	configured_multiplayer_adapter: TowerDefenseMultiplayerModeAdapter,
	configured_multiplayer_gateway: MultiplayerGameplayGateway,
	configured_interlude: XiaocongFateInterlude,
	configured_terrain_decay_timer: Timer,
	configured_production: ProductionCoordinator,
	configured_research: ResearchCoordinator,
	configured_placement: PlantPlacementController,
	configured_wave_hud: TowerDefenseWaveHUD,
	configured_status_hud: TowerDefenseStatusHUD,
	configured_minimap: TowerDefenseMinimap
) -> void:
	campaign_coordinator = configured_campaign
	rogue_exploration_coordinator = configured_rogue_exploration
	fate_coordinator = configured_fate_coordinator
	fate_manager = configured_fate_manager
	player_roster_coordinator = configured_player_roster
	plant_placement_coordinator = configured_plant_placement
	presentation_coordinator = configured_presentation
	multiplayer_adapter = configured_multiplayer_adapter
	multiplayer_gateway = configured_multiplayer_gateway
	xiaocong_fate_interlude = configured_interlude
	plant_terrain_decay_timer = configured_terrain_decay_timer
	production_coordinator = configured_production
	research_coordinator = configured_research
	plant_placement_controller = configured_placement
	wave_hud = configured_wave_hud
	tower_defense_status_hud = configured_status_hud
	tower_defense_minimap = configured_minimap
	_connect_runtime_signals()
	configure_local_context()


func is_bound() -> bool:
	return (
		campaign_coordinator != null
		and rogue_exploration_coordinator != null
		and fate_coordinator != null
		and fate_manager != null
		and player_roster_coordinator != null
		and plant_placement_coordinator != null
		and presentation_coordinator != null
		and multiplayer_adapter != null
		and multiplayer_gateway != null
		and xiaocong_fate_interlude != null
		and plant_terrain_decay_timer != null
		and production_coordinator != null
		and research_coordinator != null
		and plant_placement_controller != null
		and wave_hud != null
		and tower_defense_status_hud != null
		and tower_defense_minimap != null
	)


func _connect_runtime_signals() -> void:
	if not fate_manager.state_changed.is_connected(_on_fate_state_changed):
		fate_manager.state_changed.connect(_on_fate_state_changed)
	if not fate_manager.interlude_completed.is_connected(_on_interlude_completed):
		fate_manager.interlude_completed.connect(_on_interlude_completed)
	if not xiaocong_fate_interlude.interaction_requested.is_connected(
		_on_local_interaction_requested
	):
		xiaocong_fate_interlude.interaction_requested.connect(
			_on_local_interaction_requested
		)
	if not xiaocong_fate_interlude.fate_choice_submitted.is_connected(
		_on_local_fate_choice_submitted
	):
		xiaocong_fate_interlude.fate_choice_submitted.connect(
			_on_local_fate_choice_submitted
		)
	if not xiaocong_fate_interlude.collectible_choice_submitted.is_connected(
		_on_local_collectible_choice_submitted
	):
		xiaocong_fate_interlude.collectible_choice_submitted.connect(
			_on_local_collectible_choice_submitted
		)


func configure_local_context() -> void:
	var character_ids := player_roster_coordinator.player_character_ids.duplicate()
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and player_roster_coordinator.local_player != null
	):
		character_ids[0] = player_roster_coordinator.local_player.character_id
	xiaocong_fate_interlude.configure_local_player(
		player_roster_coordinator.local_player,
		_get_local_peer_id(),
		character_ids
	)


func _get_local_peer_id() -> int:
	return (
		0
		if player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else player_roster_coordinator.local_peer_id
	)


func _get_peer_ids() -> Array[int]:
	return player_roster_coordinator.get_active_peer_ids()


func _get_player(peer_id: int) -> Player:
	return player_roster_coordinator.get_player_for_runtime_peer(peer_id)


func _on_local_interaction_requested() -> void:
	local_interaction_requested.emit()


func _on_local_fate_choice_submitted(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	local_fate_vote_requested.emit(option_id, permanent_buff_id)


func _on_local_collectible_choice_submitted(choice_index: int) -> void:
	local_collectible_choice_requested.emit(choice_index)


func request_interaction(peer_id: int) -> void:
	var player_instance := _get_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return
	if (
		player_instance.global_position.distance_to(
			xiaocong_fate_interlude.global_position
		) > XIAOCONG_INTERACTION_DISTANCE
	):
		return
	if not fate_manager.record_interaction(peer_id):
		fate_manager.request_timeout_recovery(peer_id)


func request_fate_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	fate_manager.submit_vote(peer_id, option_id, permanent_buff_id)


func request_collectible_choice(peer_id: int, choice_index: int) -> void:
	fate_coordinator.request_collectible_choice(peer_id, choice_index)


func is_collectible_choice_pending_for_peer(peer_id: int) -> bool:
	return fate_coordinator.is_collectible_choice_pending_for_peer(peer_id)


func get_state_snapshot() -> Dictionary:
	var state := fate_manager.export_state()
	state.merge(fate_coordinator.export_runtime_state(), true)
	return state


func apply_remote_state(state: Dictionary) -> bool:
	var incoming_revision := int(state.get("revision", -1))
	if (
		fate_coordinator.has_remote_persistent_player_modifier_snapshot
		and incoming_revision
		< fate_coordinator.persistent_player_modifier_revision
	):
		return true
	if not fate_coordinator.apply_remote_runtime_state(state):
		return false
	fate_manager.apply_remote_state(state)
	return fate_manager.state_revision == incoming_revision


func _on_fate_state_changed(_state: Dictionary) -> void:
	var snapshot := get_state_snapshot()
	configure_local_context()
	var is_remote_client := (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)
	var remote_presentation_ready := (
		is_remote_client
		and campaign_coordinator.wave_state
		== CombatFlowState.State.FATE_INTERLUDE
		and not rogue_exploration_coordinator.has_pending_presentation_exit()
		and not remote_entry_in_progress
	)
	if not is_remote_client or remote_presentation_ready:
		xiaocong_fate_interlude.apply_fate_state(snapshot)
		remote_fate_presentation_deferred = false
	else:
		# FateManager 已持有最新权威状态。这里只记录表现需要延后同步，
		# 避免再造一份状态镜像，也避免快照抢先激活房间并绕过 Rogue 黑幕。
		remote_fate_presentation_deferred = true
	if fate_manager.active:
		remote_fate_conclusion_pending = false
		if not is_remote_client or remote_presentation_ready:
			present_locally(fate_manager.completed_day)
	elif is_remote_client:
		if not remote_presentation_ready:
			# Repair 可在 Host outcome 窗口只送来 inactive Fate 快照，随后
			# 才送 FATE flow。先保留结论，等入口取得表现权后再安全离场。
			remote_fate_conclusion_pending = true
		elif campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE:
			begin_remote_departure()
	state_snapshot_changed.emit(snapshot)


func enter_interlude(next_step: FlowStepConfig) -> void:
	multiplayer_adapter.cancel_all_luoxi_special_games()
	plant_placement_coordinator.close_outer_modals_for_mode_transfer()
	var rogue_handoff := (
		rogue_exploration_coordinator.has_pending_presentation_exit()
	)
	if not rogue_handoff:
		set_interlude_systems_frozen(true)
	# Fate 先取得自己的战斗锁，再让 Rogue 在黑幕下释放旧租约。
	# 两个 owner 的重叠保证转场边界不存在一帧可战斗窗口。
	set_player_combat_locked(true)
	campaign_coordinator.transition_to_fate_interlude(next_step)
	var completed_day := campaign_coordinator.get_day_number_for_wave(
		campaign_coordinator.current_wave_index + 1
	)
	multiplayer_adapter.publish_flow_state(CombatFlowState.State.FATE_INTERLUDE)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	var completed_rogue_handoff := _complete_pending_rogue_presentation_exit()
	if campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE:
		set_interlude_systems_frozen(false)
		set_player_combat_locked(false)
		plant_placement_coordinator.refresh_interaction_state()
		await xiaocong_fate_interlude.reveal_world_after_transfer()
		return
	if rogue_handoff or completed_rogue_handoff:
		set_interlude_systems_frozen(true)
		set_player_combat_locked(true)
	multiplayer_adapter.set_merchant_active(false)
	presentation_coordinator.transition_world_to_day()
	player_roster_coordinator.force_revive_dead_players(true)
	present_locally(completed_day)
	teleport_authoritative_players_to_room()
	await xiaocong_fate_interlude.play_room_reveal()
	if campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE:
		await xiaocong_fate_interlude.cover_scene_for_transfer()
		leave_presentation()
		restore_authoritative_players_from_room()
		await xiaocong_fate_interlude.reveal_world_after_transfer()
		return
	fate_coordinator.begin_interlude(
		completed_day,
		campaign_coordinator.get_flow_step_id(next_step),
		_get_peer_ids(),
		_get_local_peer_id()
	)


func present_locally(day_number: int) -> void:
	presentation_coordinator.transition_world_to_day()
	if not xiaocong_fate_interlude.is_active:
		xiaocong_fate_interlude.set_active(true, day_number)
	wave_hud.hide_all()
	if tower_defense_status_hud != null:
		tower_defense_status_hud.hide()
	if tower_defense_minimap != null:
		tower_defense_minimap.hide()
	set_player_combat_locked(true)


func should_defer_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> bool:
	var typed_state := state as CombatFlowState.State
	if typed_state != CombatFlowState.State.FATE_INTERLUDE:
		# 非 Fate flow 是跨信道 repair 的最终裁决；丢弃此前仅用于等待
		# FATE flow 的表现标志，避免陈旧 inactive 状态污染下一次幕间。
		remote_fate_presentation_deferred = false
		remote_fate_conclusion_pending = false
	if remote_entry_in_progress and typed_state != CombatFlowState.State.FATE_INTERLUDE:
		pending_remote_flow_state = {
			"step_id": step_id,
			"state": state,
			"seconds": seconds,
		}
		return true
	if remote_entry_in_progress:
		# 同一可靠通道上更新的 Fate 状态比此前暂存的离场状态更新。
		pending_remote_flow_state.clear()
	if (
		campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE
		or typed_state == CombatFlowState.State.FATE_INTERLUDE
		or not xiaocong_fate_interlude.is_active
		or remote_departure_covered
	):
		return false
	pending_remote_flow_state = {
		"step_id": step_id,
		"state": state,
		"seconds": seconds,
	}
	begin_remote_departure()
	return true


func is_leaving_remote_interlude(state: CombatFlowState.State) -> bool:
	return (
		campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE
		and state != CombatFlowState.State.FATE_INTERLUDE
		and xiaocong_fate_interlude.is_active
	)


func apply_remote_interlude_flow(day_number: int) -> void:
	var rogue_handoff := (
		rogue_exploration_coordinator.has_pending_presentation_exit()
	)
	# Client 可能已由 Campaign 预先取得 Fate freeze lease。先原子提交
	# flow state/timer，再关闭旧 modal，确保其 closed 信号刷新放置输入时
	# 仍保持禁用。
	campaign_coordinator.synchronize_remote_fate_interlude_state()
	multiplayer_adapter.cancel_all_luoxi_special_games()
	plant_placement_coordinator.close_outer_modals_for_mode_transfer()
	if not rogue_handoff:
		set_interlude_systems_frozen(true)
	set_player_combat_locked(true)
	if remote_entry_in_progress:
		return
	if rogue_handoff:
		begin_remote_entry(day_number)
	elif xiaocong_fate_interlude.is_active:
		present_locally(day_number)
	else:
		begin_remote_entry(day_number)


func begin_remote_entry(day_number: int) -> void:
	if remote_entry_in_progress:
		return
	var rogue_handoff := (
		rogue_exploration_coordinator.has_pending_presentation_exit()
	)
	remote_entry_in_progress = true
	remote_departure_in_progress = false
	remote_departure_covered = false
	pending_remote_flow_state.clear()
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	var completed_rogue_handoff := _complete_pending_rogue_presentation_exit()
	if not pending_remote_flow_state.is_empty():
		await _apply_pending_remote_flow_from_covered_entry(false)
		return
	if not _is_remote_entry_context_current():
		await _abort_remote_entry_from_cover(false)
		return
	if rogue_handoff or completed_rogue_handoff:
		set_interlude_systems_frozen(true)
		set_player_combat_locked(true)
	presentation_coordinator.transition_world_to_day()
	multiplayer_adapter.set_local_merchants_active(false)
	present_locally(day_number)
	_apply_deferred_remote_fate_presentation()
	while true:
		await xiaocong_fate_interlude.play_room_reveal()
		_apply_deferred_remote_fate_presentation()
		if (
			pending_remote_flow_state.is_empty()
			and _is_remote_entry_context_current()
		):
			remote_entry_in_progress = false
			if remote_fate_conclusion_pending:
				remote_fate_conclusion_pending = false
				begin_remote_departure()
			return
		await xiaocong_fate_interlude.cover_scene_for_transfer()
		if not pending_remote_flow_state.is_empty():
			await _apply_pending_remote_flow_from_covered_entry(true)
			return
		if not _is_remote_entry_context_current():
			await _abort_remote_entry_from_cover(true)
			return
		# 更新的 Fate 流程状态取消了揭幕期间暂存的离场状态；房间仍然
		# 拥有表现权，重新揭幕即可，无需重新取得冻结租约。


func _is_remote_entry_context_current() -> bool:
	return (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and campaign_coordinator.wave_state
		== CombatFlowState.State.FATE_INTERLUDE
	)


func _apply_deferred_remote_fate_presentation() -> void:
	if not remote_fate_presentation_deferred:
		return
	remote_fate_presentation_deferred = false
	xiaocong_fate_interlude.apply_fate_state(get_state_snapshot())


func _apply_pending_remote_flow_from_covered_entry(
	room_was_active: bool
) -> void:
	var deferred_flow_state := pending_remote_flow_state.duplicate()
	pending_remote_flow_state.clear()
	remote_fate_presentation_deferred = false
	remote_fate_conclusion_pending = false
	remote_entry_in_progress = false
	if room_was_active:
		# 入口协程已经取得全黑遮罩；把它作为离场 cover 直接交给 Campaign，
		# 避免 should_defer 再次回绕到 outcome + cover 动画。
		remote_departure_in_progress = true
		remote_departure_covered = true
	set_player_combat_locked(false)
	campaign_coordinator.apply_remote_flow_state(
		StringName(deferred_flow_state.get("step_id", "")),
		int(
			deferred_flow_state.get(
				"state",
				int(CombatFlowState.State.INTERMISSION)
			)
		),
		int(deferred_flow_state.get("seconds", 0))
	)
	if room_was_active:
		return
	plant_placement_coordinator.refresh_interaction_state()
	await xiaocong_fate_interlude.reveal_world_after_transfer()
	remote_departure_in_progress = false
	remote_departure_covered = false


func _abort_remote_entry_from_cover(room_was_active: bool) -> void:
	remote_entry_in_progress = false
	remote_fate_conclusion_pending = false
	remote_fate_presentation_deferred = false
	if room_was_active:
		leave_presentation()
	else:
		set_interlude_systems_frozen(false)
		set_player_combat_locked(false)
		plant_placement_coordinator.refresh_interaction_state()
	await xiaocong_fate_interlude.reveal_world_after_transfer()
	remote_departure_in_progress = false
	remote_departure_covered = false


func _complete_pending_rogue_presentation_exit() -> bool:
	if not rogue_exploration_coordinator.has_pending_presentation_exit():
		return false
	return rogue_exploration_coordinator.complete_pending_presentation_exit()


func begin_remote_departure() -> void:
	if remote_departure_in_progress:
		return
	remote_fate_conclusion_pending = false
	remote_departure_in_progress = true
	await xiaocong_fate_interlude.play_outcome_message(
		fate_manager.winning_option_id
	)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	remote_departure_covered = true
	if pending_remote_flow_state.is_empty():
		return
	var deferred_flow_state := pending_remote_flow_state.duplicate()
	pending_remote_flow_state.clear()
	campaign_coordinator.apply_remote_flow_state(
		StringName(deferred_flow_state.get("step_id", "")),
		int(
			deferred_flow_state.get(
				"state",
				int(CombatFlowState.State.INTERMISSION)
			)
		),
		int(deferred_flow_state.get("seconds", 0))
	)


func complete_remote_flow_transition() -> void:
	leave_presentation()
	finish_remote_return()


func finish_remote_return() -> void:
	await xiaocong_fate_interlude.reveal_world_after_transfer()
	remote_entry_in_progress = false
	remote_departure_in_progress = false
	remote_departure_covered = false
	remote_fate_conclusion_pending = false
	remote_fate_presentation_deferred = false
	pending_remote_flow_state.clear()


func leave_presentation() -> void:
	xiaocong_fate_interlude.set_active(false)
	remote_fate_conclusion_pending = false
	remote_fate_presentation_deferred = false
	set_interlude_systems_frozen(false)
	if tower_defense_status_hud != null:
		tower_defense_status_hud.show()
	if tower_defense_minimap != null:
		tower_defense_minimap.show()
	set_player_combat_locked(false)
	plant_placement_coordinator.refresh_interaction_state()


func set_interlude_systems_frozen(frozen: bool) -> void:
	if frozen == interlude_systems_frozen:
		return
	interlude_systems_frozen = frozen
	if frozen:
		frozen_placement_input_enabled = (
			plant_placement_controller.placement_input_enabled
		)
		frozen_placement_unhandled_input_enabled = (
			plant_placement_controller.is_processing_unhandled_input()
		)
		# cancel_placement 可能按旧 Campaign flow 刷新输入；先结束放置，
		# 再施加 Fate 的显式禁用，才能保证租约持有期间始终不可操作。
		plant_placement_coordinator.cancel_placement()
		plant_placement_controller.set_placement_input_enabled(false)
		plant_placement_controller.set_process_unhandled_input(false)
	else:
		plant_placement_controller.set_placement_input_enabled(
			frozen_placement_input_enabled
		)
		plant_placement_controller.set_process_unhandled_input(
			frozen_placement_unhandled_input_enabled
		)
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return
	if frozen:
		frozen_production_processing_enabled = (
			production_coordinator.authoritative_processing_enabled
		)
		frozen_research_processing_enabled = (
			research_coordinator.authoritative_processing_enabled
		)
		production_coordinator.set_authoritative_processing_enabled(false)
		research_coordinator.set_authoritative_processing_enabled(false)
		frozen_terrain_decay_was_running = (
			not plant_terrain_decay_timer.is_stopped()
		)
		if frozen_terrain_decay_was_running:
			frozen_terrain_decay_time_left = plant_terrain_decay_timer.time_left
			plant_terrain_decay_timer.stop()
		return
	production_coordinator.set_authoritative_processing_enabled(
		frozen_production_processing_enabled
	)
	research_coordinator.set_authoritative_processing_enabled(
		frozen_research_processing_enabled
	)
	if frozen_terrain_decay_was_running and plant_terrain_decay_timer.is_stopped():
		plant_terrain_decay_timer.start(
			frozen_terrain_decay_time_left
			if frozen_terrain_decay_time_left > 0.0
			else plant_terrain_decay_timer.wait_time
		)
	frozen_terrain_decay_was_running = false
	frozen_terrain_decay_time_left = 0.0


func set_player_combat_locked(locked: bool) -> void:
	player_roster_coordinator.set_combat_action_lock_for_all(
		COMBAT_ACTION_LOCK_OWNER,
		locked
	)


func synchronize_reconnected_player_presentation_lease(peer_id: int) -> bool:
	if (
		campaign_coordinator.wave_state
		!= CombatFlowState.State.FATE_INTERLUDE
		or peer_id <= 0
	):
		return false
	if not _get_peer_ids().has(peer_id):
		return false
	var player_instance := _get_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return false
	player_instance.set_combat_action_lock(COMBAT_ACTION_LOCK_OWNER, true)
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		_teleport_player_authoritatively(
			peer_id,
			player_instance,
			xiaocong_fate_interlude.get_player_spawn_position(
				player_roster_coordinator.get_spawn_slot_index(peer_id)
			)
		)
	return true


func teleport_authoritative_players_to_room() -> void:
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return
	for peer_id in _get_peer_ids():
		var player_instance := _get_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		_teleport_player_authoritatively(
			peer_id,
			player_instance,
			xiaocong_fate_interlude.get_player_spawn_position(
				player_roster_coordinator.get_spawn_slot_index(peer_id)
			)
		)


func restore_authoritative_players_from_room() -> void:
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return
	var peer_ids := _get_peer_ids()
	for slot_index in range(peer_ids.size()):
		var peer_id := peer_ids[slot_index]
		var player_instance := _get_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		_teleport_player_authoritatively(
			peer_id,
			player_instance,
			player_roster_coordinator.get_world_spawn_position(
				peer_id,
				slot_index
			)
		)


func _teleport_player_authoritatively(
	peer_id: int,
	player_instance: Player,
	target_position: Vector2
) -> void:
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		if not multiplayer_gateway.player_teleport_requested.has_connections():
			push_error("FateFlowCoordinator: 多人权威传送缺少会话处理器。")
			return
		multiplayer_gateway.player_teleport_requested.emit(
			peer_id,
			target_position
		)
		return
	player_instance.global_position = target_position
	player_instance.velocity = Vector2.ZERO
	player_instance.reset_physics_interpolation()


func _on_interlude_completed(next_step_id: StringName) -> void:
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or authority_departure_in_progress
	):
		return
	authority_departure_in_progress = true
	var winning_option_id := fate_manager.winning_option_id
	await xiaocong_fate_interlude.play_outcome_message(winning_option_id)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	fate_coordinator.clear_pending_rewards()
	leave_presentation()
	restore_authoritative_players_from_room()
	if campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE:
		campaign_coordinator.resume_flow_after_fate_interlude(next_step_id)
	await xiaocong_fate_interlude.reveal_world_after_transfer()
	authority_departure_in_progress = false
