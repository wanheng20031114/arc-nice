extends Node
class_name TowerDefenseFateFlowCoordinator

const XIAOCONG_INTERACTION_DISTANCE := 220.0

signal local_interaction_requested
signal local_fate_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
)
signal local_collectible_choice_requested(choice_index: int)
signal state_snapshot_changed(snapshot: Dictionary)

var runtime: TowerDefenseGame
var campaign_coordinator: TowerDefenseCampaignCoordinator
var fate_coordinator: FateCoordinator
var fate_manager: TowerDefenseFateManager
var xiaocong_fate_interlude: XiaocongFateInterlude
var enemy_spawn_timer: Timer
var state_timer: Timer
var plant_terrain_decay_timer: Timer
var production_coordinator: ProductionCoordinator
var research_coordinator: ResearchCoordinator
var plant_placement_controller: PlantPlacementController
var wave_hud: TowerDefenseWaveHUD
var tower_defense_status_hud: TowerDefenseStatusHUD
var tower_defense_minimap: TowerDefenseMinimap
var player_spawn: Marker2D

var frozen_terrain_decay_time_left := 0.0
var remote_entry_in_progress := false
var remote_departure_in_progress := false
var remote_departure_covered := false
var pending_remote_flow_state: Dictionary = {}


func setup(
	runtime_instance: TowerDefenseGame,
	configured_campaign: TowerDefenseCampaignCoordinator,
	configured_fate_coordinator: FateCoordinator,
	configured_fate_manager: TowerDefenseFateManager,
	configured_interlude: XiaocongFateInterlude,
	configured_enemy_spawn_timer: Timer,
	configured_state_timer: Timer,
	configured_terrain_decay_timer: Timer,
	configured_production: ProductionCoordinator,
	configured_research: ResearchCoordinator,
	configured_placement: PlantPlacementController,
	configured_wave_hud: TowerDefenseWaveHUD,
	configured_status_hud: TowerDefenseStatusHUD,
	configured_minimap: TowerDefenseMinimap,
	configured_player_spawn: Marker2D
) -> void:
	runtime = runtime_instance
	campaign_coordinator = configured_campaign
	fate_coordinator = configured_fate_coordinator
	fate_manager = configured_fate_manager
	xiaocong_fate_interlude = configured_interlude
	enemy_spawn_timer = configured_enemy_spawn_timer
	state_timer = configured_state_timer
	plant_terrain_decay_timer = configured_terrain_decay_timer
	production_coordinator = configured_production
	research_coordinator = configured_research
	plant_placement_controller = configured_placement
	wave_hud = configured_wave_hud
	tower_defense_status_hud = configured_status_hud
	tower_defense_minimap = configured_minimap
	player_spawn = configured_player_spawn
	_connect_runtime_signals()
	configure_local_context()


func is_bound() -> bool:
	return (
		runtime != null
		and campaign_coordinator != null
		and fate_coordinator != null
		and fate_manager != null
		and xiaocong_fate_interlude != null
		and enemy_spawn_timer != null
		and state_timer != null
		and plant_terrain_decay_timer != null
		and production_coordinator != null
		and research_coordinator != null
		and plant_placement_controller != null
		and wave_hud != null
		and tower_defense_status_hud != null
		and tower_defense_minimap != null
		and player_spawn != null
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
	var character_ids := runtime.multiplayer_player_character_ids.duplicate()
	if (
		runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and runtime.player != null
	):
		character_ids[0] = runtime.player.character_id
	xiaocong_fate_interlude.configure_local_player(
		runtime.player,
		_get_local_peer_id(),
		character_ids
	)


func _get_local_peer_id() -> int:
	return (
		0
		if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else runtime.multiplayer_local_peer_id
	)


func _get_peer_ids() -> Array[int]:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return [0]
	var peer_ids: Array[int] = []
	for peer_variant in runtime.peer_players:
		var peer_id := int(peer_variant)
		if peer_id > 0:
			peer_ids.append(peer_id)
	peer_ids.sort()
	return peer_ids


func _get_player(peer_id: int) -> Player:
	if (
		runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and peer_id == 0
	):
		return runtime.player
	return runtime.get_player_for_peer(peer_id)


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


func apply_remote_state(state: Dictionary) -> void:
	fate_coordinator.apply_remote_runtime_state(state)
	fate_manager.apply_remote_state(state)


func _on_fate_state_changed(_state: Dictionary) -> void:
	var snapshot := get_state_snapshot()
	configure_local_context()
	xiaocong_fate_interlude.apply_fate_state(snapshot)
	if fate_manager.active:
		if not (
			runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
			and remote_entry_in_progress
		):
			present_locally(fate_manager.completed_day)
	elif (
		campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE
		and runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		begin_remote_departure()
	state_snapshot_changed.emit(snapshot)


func enter_interlude(next_step: FlowStepConfig) -> void:
	set_interlude_systems_frozen(true)
	campaign_coordinator.wave_state = CombatFlowState.State.FATE_INTERLUDE
	set_player_combat_locked(true)
	campaign_coordinator.next_flow_step_after_rest = next_step
	campaign_coordinator.countdown_seconds = 0
	enemy_spawn_timer.stop()
	state_timer.stop()
	var completed_day := runtime._get_day_number_for_wave(
		campaign_coordinator.current_wave_index + 1
	)
	runtime._emit_multiplayer_flow_state(CombatFlowState.State.FATE_INTERLUDE)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	if campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE:
		return
	runtime._set_merchant_active(false)
	runtime.transition_world_to_day()
	runtime._force_revive_dead_players()
	present_locally(completed_day)
	teleport_authoritative_players_to_room()
	await xiaocong_fate_interlude.play_room_reveal()
	if campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE:
		return
	fate_coordinator.begin_interlude(
		completed_day,
		runtime._get_flow_step_id(next_step),
		_get_peer_ids(),
		_get_local_peer_id()
	)


func present_locally(day_number: int) -> void:
	runtime.transition_world_to_day()
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
	state_timer.stop()
	enemy_spawn_timer.stop()
	campaign_coordinator.wave_state = CombatFlowState.State.FATE_INTERLUDE
	set_player_combat_locked(true)
	if remote_entry_in_progress:
		return
	if xiaocong_fate_interlude.is_active:
		present_locally(day_number)
	else:
		begin_remote_entry(day_number)


func begin_remote_entry(day_number: int) -> void:
	if remote_entry_in_progress:
		return
	remote_entry_in_progress = true
	remote_departure_in_progress = false
	remote_departure_covered = false
	pending_remote_flow_state.clear()
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	if (
		runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE
	):
		remote_entry_in_progress = false
		return
	runtime.transition_world_to_day()
	runtime._set_local_merchants_active(false)
	present_locally(day_number)
	await xiaocong_fate_interlude.play_room_reveal()
	remote_entry_in_progress = false


func begin_remote_departure() -> void:
	if remote_departure_in_progress:
		return
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
	runtime.apply_remote_flow_state(
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
	pending_remote_flow_state.clear()


func leave_presentation() -> void:
	xiaocong_fate_interlude.set_active(false)
	set_interlude_systems_frozen(false)
	if tower_defense_status_hud != null:
		tower_defense_status_hud.show()
	if tower_defense_minimap != null:
		tower_defense_minimap.show()
	set_player_combat_locked(false)
	runtime._refresh_player_modal_ui_lock()
	runtime._update_plant_placement_input_state()


func set_interlude_systems_frozen(frozen: bool) -> void:
	if plant_placement_controller != null:
		plant_placement_controller.set_placement_input_enabled(not frozen)
		plant_placement_controller.set_process_unhandled_input(not frozen)
	if frozen:
		runtime._cancel_plant_placement()
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	if production_coordinator != null:
		production_coordinator.set_authoritative_processing_enabled(not frozen)
	if research_coordinator != null:
		research_coordinator.set_authoritative_processing_enabled(not frozen)
	if plant_terrain_decay_timer == null:
		return
	if frozen:
		if not plant_terrain_decay_timer.is_stopped():
			frozen_terrain_decay_time_left = plant_terrain_decay_timer.time_left
			plant_terrain_decay_timer.stop()
		return
	if plant_terrain_decay_timer.is_stopped():
		plant_terrain_decay_timer.start(
			frozen_terrain_decay_time_left
			if frozen_terrain_decay_time_left > 0.0
			else plant_terrain_decay_timer.wait_time
		)
	frozen_terrain_decay_time_left = 0.0


func set_player_combat_locked(locked: bool) -> void:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		if (
			runtime.player != null
			and is_instance_valid(runtime.player)
			and not runtime.player.is_dead
		):
			runtime.player.set_combat_actions_locked(locked)
			runtime.player.set_controls_locked(false)
		return
	for player_variant in runtime.peer_players.values():
		var player_instance := player_variant as Player
		if (
			player_instance != null
			and is_instance_valid(player_instance)
			and not player_instance.is_dead
		):
			player_instance.set_combat_actions_locked(locked)
			player_instance.set_controls_locked(false)


func teleport_authoritative_players_to_room() -> void:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var peer_ids := _get_peer_ids()
	for slot_index in range(peer_ids.size()):
		var peer_id := peer_ids[slot_index]
		var player_instance := _get_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		runtime._teleport_fate_player_authoritatively(
			peer_id,
			player_instance,
			xiaocong_fate_interlude.get_player_spawn_position(slot_index)
		)


func restore_authoritative_players_from_room() -> void:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var peer_ids := _get_peer_ids()
	for slot_index in range(peer_ids.size()):
		var peer_id := peer_ids[slot_index]
		var player_instance := _get_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		var spawn_offset := (
			Vector2.ZERO
			if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
			else runtime._get_multiplayer_spawn_offset(
				int(runtime.multiplayer_spawn_slot_indices.get(peer_id, slot_index))
			)
		)
		runtime._teleport_fate_player_authoritatively(
			peer_id,
			player_instance,
			player_spawn.global_position + spawn_offset
		)


func _on_interlude_completed(next_step_id: StringName) -> void:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var winning_option_id := fate_manager.winning_option_id
	await xiaocong_fate_interlude.play_outcome_message(winning_option_id)
	await xiaocong_fate_interlude.cover_scene_for_transfer()
	fate_coordinator.clear_pending_rewards()
	leave_presentation()
	restore_authoritative_players_from_room()
	runtime._resume_flow_after_fate_interlude(next_step_id)
	await xiaocong_fate_interlude.reveal_world_after_transfer()
