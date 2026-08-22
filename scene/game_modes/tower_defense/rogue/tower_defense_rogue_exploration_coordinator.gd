extends Node
class_name TowerDefenseRogueExplorationCoordinator

const MultiplayerReconnectTypesScript := preload(
	"res://scene/multiplayer/reconnect/multiplayer_reconnect_types.gd"
)
const SNAPSHOT_SCHEMA_VERSION := 2
const INVALID_DAY := 0
const DEFAULT_ROGUE_CORE_HEALTH := 100
const COMBAT_ACTION_LOCK_OWNER := &"tower_rogue_exploration"
const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/combat/audio/spatial_audio_voice_limiter.gd"
)

signal exploration_started(day_number: int, snapshot: Dictionary)
signal exploration_snapshot_changed(snapshot: Dictionary)
signal exploration_finished(day_number: int, failed: bool)


class TowerAudioPlaybackLease:
	extends RefCounted

	var player_ref: WeakRef = null
	var parent_ref: WeakRef = null
	var stream: AudioStream = null
	var playback: AudioStreamPlayback = null
	var was_paused := false
	var preserve_playback := false


@onready var _route: RogueRouteGame = $RogueRoute
@onready var _multiplayer_combat_coordinator: RogueCombatMultiplayerCoordinator = (
	$RogueCombatCoordinator
)

var _runtime: TowerDefenseGame = null
var _campaign: TowerDefenseCampaignCoordinator = null
var _progression: TowerDefenseProgressionConfig = null
var _player_roster: TowerDefensePlayerRosterCoordinator = null
var _home_defense: TowerDefenseHomeDefenseCoordinator = null
var _plant_placement: TowerDefensePlantPlacementCoordinator = null
var _plant_placement_controller: PlantPlacementController = null
var _multiplayer_adapter: TowerDefenseMultiplayerModeAdapter = null
var _terrain_decay_timer: Timer = null
var _production: ProductionCoordinator = null
var _research: ResearchCoordinator = null
var _fate: FateCoordinator = null
var _net_manager: NetManagerStore = null
var _run_state: RunStateStore = null
var _persistent_modifier_projector: TowerRoguePlayerPersistentModifierProjector = null

var _active := false
var _multiplayer_snapshot_apply_in_progress := false
var _active_day := INVALID_DAY
var _next_step_id: StringName = &""
var _map_generation_epoch := 0
var _daily_grant_ledger: Dictionary[int, int] = {}
var _requires_fresh_map := false
var _finishing := false
var _presentation_exit_pending := false
var _presentation_exit_completing := false
var _tower_runtime_frozen := false
var _route_identity_configured := false

var _saved_process_modes: Dictionary = {}
var _saved_visibility: Dictionary = {}
var _saved_audio_playback_leases: Array[TowerAudioPlaybackLease] = []
var _saved_tower_environment: Environment = null
var _saved_tower_camera_enabled := false
var _saved_terrain_decay_time_left := 0.0
var _saved_terrain_decay_was_running := false
var _saved_production_processing_enabled := false
var _saved_research_processing_enabled := false
var _saved_placement_input_enabled := false
var _saved_placement_unhandled_input_enabled := false
var _saved_tower_core_current := 0
var _saved_tower_core_maximum := 0
var _rogue_core_current := DEFAULT_ROGUE_CORE_HEALTH
var _rogue_core_maximum := DEFAULT_ROGUE_CORE_HEALTH
var _rogue_core_initialized := false


func _ready() -> void:
	_route.embedded_session = true
	_route.set_embedded_presentation_active(false)
	set_process(false)


func setup(
	runtime: TowerDefenseGame,
	campaign: TowerDefenseCampaignCoordinator,
	progression: TowerDefenseProgressionConfig,
	player_roster: TowerDefensePlayerRosterCoordinator,
	home_defense: TowerDefenseHomeDefenseCoordinator,
	plant_placement: TowerDefensePlantPlacementCoordinator,
	plant_placement_controller: PlantPlacementController,
	multiplayer_adapter: TowerDefenseMultiplayerModeAdapter,
	terrain_decay_timer: Timer,
	production: ProductionCoordinator,
	research: ResearchCoordinator,
	fate: FateCoordinator,
	run_state: RunStateStore
) -> bool:
	_runtime = runtime
	_campaign = campaign
	_progression = progression
	_player_roster = player_roster
	_home_defense = home_defense
	_plant_placement = plant_placement
	_plant_placement_controller = plant_placement_controller
	_multiplayer_adapter = multiplayer_adapter
	_terrain_decay_timer = terrain_decay_timer
	_production = production
	_research = research
	_fate = fate
	_run_state = run_state
	_net_manager = NetManagerStore.get_autoload_instance()
	_persistent_modifier_projector = TowerRoguePlayerPersistentModifierProjector.new()
	if (
		not _persistent_modifier_projector.setup(_research, _fate)
		or not _route.configure_player_persistent_modifier_projector(
			_persistent_modifier_projector
		)
	):
		return false
	_multiplayer_combat_coordinator.configure_player_persistent_modifier_projector(
		_persistent_modifier_projector
	)
	if not is_bound():
		return false
	# 多人身份在 Tower 场景 Ready 时可能尚未完成会话认证；setup 只绑定
	# 静态依赖，首次权威进入/首份 active 快照再严格校验 roster + stable key。
	if (
		_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and not _ensure_route_runtime_identity()
	):
		return false
	_connect_route_signals()
	_connect_run_state_signals()
	_route.set_embedded_presentation_active(false)
	return true


func is_bound() -> bool:
	return (
		_runtime != null
		and _campaign != null
		and _progression != null
		and _player_roster != null
		and _home_defense != null
		and _plant_placement != null
		and _plant_placement_controller != null
		and _multiplayer_adapter != null
		and _terrain_decay_timer != null
		and _production != null
		and _research != null
		and _fate != null
		and _persistent_modifier_projector != null
		and _run_state != null
		and _route != null
		and _multiplayer_combat_coordinator != null
		and not _progression.compute_runtime_contract_hash().is_empty()
	)


func _configure_route_runtime_identity() -> bool:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_route.set_authority_enabled(true)
		return _route.configure_embedded_singleplayer_player()
	var prepared := _prepare_route_runtime_identity()
	if not _can_commit_prepared_route_runtime_identity(prepared):
		_discard_prepared_route_runtime_identity(prepared)
		return false
	_commit_validated_route_runtime_identity(prepared, true)
	return _multiplayer_combat_coordinator.is_enabled()


## fresh CLIENT_VIEW 先在树外准备完整 Route roster；不会提前修改 Shop
## identity、创建公开 Player 或 reveal 默认 Research/Fate 面板。
func _prepare_route_runtime_identity() -> Dictionary:
	if _route_identity_configured:
		return {"already_configured": true}
	if (
		_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		or _net_manager == null
	):
		return {}
	var player_names := _net_manager.connected_players.duplicate()
	var character_ids := _net_manager.get_player_character_map().duplicate()
	var local_peer_id := _net_manager.get_local_peer_id()
	if local_peer_id <= 0 or not player_names.has(local_peer_id):
		return {}
	var stable_keys: Dictionary = {}
	for peer_id_variant in player_names.keys():
		var peer_id := int(peer_id_variant)
		var stable_key := _net_manager.get_stable_participant_key(peer_id)
		if _net_manager.is_host() and stable_key.is_empty():
			push_error("塔防地下探索玩家 %d 缺少稳定参与者身份。" % peer_id)
			return {}
		if not stable_key.is_empty():
			stable_keys[peer_id] = stable_key
	var prepared_roster := _route.prepare_multiplayer_players(
		local_peer_id,
		player_names,
		character_ids,
		stable_keys
	)
	if prepared_roster.is_empty():
		return {}
	return {
		"already_configured": false,
		"local_peer_id": local_peer_id,
		"roster": prepared_roster,
	}


func _can_commit_prepared_route_runtime_identity(
	prepared: Dictionary
) -> bool:
	if prepared.size() == 1 and bool(prepared.get("already_configured", false)):
		return _route_identity_configured
	return (
		prepared.size() == 3
		and not bool(prepared.get("already_configured", true))
		and not _route_identity_configured
		and typeof(prepared.get("local_peer_id")) == TYPE_INT
		and typeof(prepared.get("roster")) == TYPE_DICTIONARY
		and _route.can_commit_prepared_multiplayer_players(
			prepared["roster"] as Dictionary
		)
	)


func _commit_validated_route_runtime_identity(
	prepared: Dictionary,
	restore_scene_entry: bool
) -> void:
	if bool(prepared["already_configured"]):
		return
	_route.commit_validated_multiplayer_players_with_scene_policy(
		prepared["roster"] as Dictionary,
		restore_scene_entry
	)
	_route.set_authority_enabled(_net_manager.is_host())
	_multiplayer_combat_coordinator.bind_network_dependencies(
		_route,
		_net_manager,
		_run_state,
		RogueCombatMultiplayerCoordinator.SessionProjectionOwner.ENCLOSING_RUNTIME
	)
	_route_identity_configured = true


func _discard_prepared_route_runtime_identity(prepared: Dictionary) -> void:
	if (
		prepared.is_empty()
		or bool(prepared.get("already_configured", false))
	):
		return
	_route.discard_prepared_multiplayer_players(
		prepared.get("roster", {}) as Dictionary
	)
	prepared.clear()


func _ensure_route_runtime_identity() -> bool:
	if _route_identity_configured:
		return true
	_route_identity_configured = _configure_route_runtime_identity()
	return _route_identity_configured


func _connect_route_signals() -> void:
	if not _route.return_requested.is_connected(_on_route_return_requested):
		_route.return_requested.connect(_on_route_return_requested)


func _connect_run_state_signals() -> void:
	if not _run_state.party_status_ledger_changed.is_connected(
		_on_party_status_ledger_changed
	):
		_run_state.party_status_ledger_changed.connect(
			_on_party_status_ledger_changed
		)


func begin_exploration_transfer(
	day_number: int,
	next_step: FlowStepConfig
) -> bool:
	return enter_exploration(day_number, next_step)


func begin_remote_exploration_transfer() -> void:
	return


func cancel_pending_exploration_transfer() -> bool:
	return false


func enter_exploration(day_number: int, next_step: FlowStepConfig) -> bool:
	if (
		not is_bound()
		or day_number < 1
		or day_number > TowerDefenseProgressionConfig.ROGUE_EXPLORATION_DAY_COUNT
		or next_step == null
		or next_step.step_id.is_empty()
		or _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or not _ensure_route_runtime_identity()
	):
		return false
	if _active:
		return _active_day == day_number and _next_step_id == next_step.step_id
	if _presentation_exit_pending:
		return _daily_grant_ledger.has(day_number)
	if _tower_runtime_frozen:
		return false
	# 发放账本同时也是探索日的一次性消费凭证。已完成或失败的同一天
	# 可能因可靠重发再次请求进入；必须幂等确认，不能重开 Rogue/Fate。
	if _daily_grant_ledger.has(day_number):
		return true
	var daily_action_points := _progression.get_daily_rogue_action_points(
		day_number
	)
	if daily_action_points == 0:
		_daily_grant_ledger[day_number] = 0
		_campaign.resume_flow_after_rogue_exploration(next_step.step_id)
		return true

	_next_step_id = next_step.step_id
	_active_day = day_number
	_finishing = false
	# 先完成塔防角色复活的相机/输入副作用，再统一冻结 Tower presentation；
	# 若反过来，revived 回调会在探索已接管后重新启用塔防相机。
	_player_roster.restore_all_players_to_full_health(true)
	_freeze_tower_runtime()
	_activate_rogue_core_for_entry()
	_route.set_embedded_presentation_active(true)
	if not _ensure_authoritative_map():
		_cache_rogue_core_from_run_state()
		_restore_tower_core()
		_restore_tower_runtime()
		_route.set_embedded_presentation_active(false)
		_active_day = INVALID_DAY
		_next_step_id = &""
		_campaign.enter_defeat()
		return false
	if not _route.restore_players_for_route_scene_entry():
		_cache_rogue_core_from_run_state()
		_restore_tower_core()
		_restore_tower_runtime()
		_route.set_embedded_presentation_active(false)
		_active_day = INVALID_DAY
		_next_step_id = &""
		_campaign.enter_defeat()
		return false
	if not _daily_grant_ledger.has(day_number):
		if not _route.grant_authoritative_action_points(daily_action_points):
			_cache_rogue_core_from_run_state()
			_restore_tower_core()
			_restore_tower_runtime()
			_route.set_embedded_presentation_active(false)
			_active_day = INVALID_DAY
			_next_step_id = &""
			_campaign.enter_defeat()
			return false
		_daily_grant_ledger[day_number] = daily_action_points

	if not _campaign.transition_to_rogue_exploration(next_step):
		_cache_rogue_core_from_run_state()
		_restore_tower_core()
		_restore_tower_runtime()
		_route.set_embedded_presentation_active(false)
		_active_day = INVALID_DAY
		_next_step_id = &""
		_campaign.enter_defeat()
		return false
	_active = true
	_multiplayer_adapter.set_merchant_active(false)
	_campaign.publish_flow_state(CombatFlowState.State.ROGUE_EXPLORATION)
	set_process(true)
	var snapshot := export_multiplayer_snapshot_for_peer()
	exploration_started.emit(day_number, snapshot)
	exploration_snapshot_changed.emit(snapshot)
	return true


func _ensure_authoritative_map() -> bool:
	if _route.is_route_ready() and not _requires_fresh_map:
		return _route.get_action_points() == 0
	_requires_fresh_map = false
	_map_generation_epoch += 1
	var seed := randi_range(1, 2147483646)
	return _route.start_authoritative_session(seed, false, 0)


func _process(_delta: float) -> void:
	if not _active or _finishing or not _is_local_authority():
		return
	if _route.has_run_failed():
		host_handle_exploration_failure()
		return
	if _route.get_action_points() == 0 and is_settled_for_auto_return():
		_finish_exploration(false)


func is_settled_for_auto_return() -> bool:
	return (
		_active
		and _route.get_action_points() == 0
		and _route.is_exploration_settled_for_return()
		and not _multiplayer_combat_coordinator.is_combat_active()
	)


func host_handle_exploration_failure() -> bool:
	if not _active or not _is_local_authority() or not _route.has_run_failed():
		return false
	_requires_fresh_map = true
	_route.acknowledge_embedded_run_failure()
	_finish_exploration(true)
	return true


func _finish_exploration(failed: bool) -> void:
	if not _active or _finishing:
		return
	_finishing = true
	set_process(false)
	var completed_day := _active_day
	var resume_step_id := _next_step_id
	_cache_rogue_core_from_run_state()
	_active = false
	_active_day = INVALID_DAY
	_next_step_id = &""
	_begin_pending_presentation_exit()
	exploration_snapshot_changed.emit(export_multiplayer_snapshot_for_peer())
	exploration_finished.emit(completed_day, failed)
	_finishing = false
	_campaign.resume_flow_after_rogue_exploration(resume_step_id)


func _freeze_tower_runtime() -> void:
	if _tower_runtime_frozen:
		return
	_multiplayer_adapter.cancel_all_luoxi_special_games()
	_plant_placement.close_outer_modals_for_mode_transfer()
	# Lease 采用严格的两阶段提交：先只读捕获全部基线，再产生任何副作用。
	# 子树禁用、cancel_placement 等操作都可能联动输入或暂停态，不能边捕获边改写。
	_saved_tower_core_current = _home_defense.current_base_health
	_saved_tower_core_maximum = _home_defense.maximum_base_health
	_saved_tower_camera_enabled = _runtime.map_camera.enabled
	var tower_environment := _runtime.get_node_or_null(
		"WorldEnvironment"
	) as WorldEnvironment
	if tower_environment != null:
		_saved_tower_environment = tower_environment.environment
	var audio_playback_leases: Array[TowerAudioPlaybackLease] = []
	for child in _runtime.get_children():
		if child == self or child.name in [
			&"MultiplayerGameplayGateway",
			&"MultiplayerModeAdapter",
			&"CampaignCoordinator",
			&"CampaignRuntimePort",
			&"XiaocongFateInterlude",
			&"FateFlowCoordinator",
		]:
			continue
		_saved_process_modes[child] = child.process_mode
		_capture_audio_playback_leases(child, audio_playback_leases)
		if child is CanvasItem:
			_saved_visibility[child] = (child as CanvasItem).visible
		elif child is CanvasLayer:
			_saved_visibility[child] = (child as CanvasLayer).visible
	_saved_audio_playback_leases = audio_playback_leases
	_saved_terrain_decay_was_running = not _terrain_decay_timer.is_stopped()
	if _saved_terrain_decay_was_running:
		_saved_terrain_decay_time_left = _terrain_decay_timer.time_left
	_saved_production_processing_enabled = (
		_production.authoritative_processing_enabled
	)
	_saved_research_processing_enabled = _research.authoritative_processing_enabled
	_saved_placement_input_enabled = _plant_placement_controller.placement_input_enabled
	_saved_placement_unhandled_input_enabled = (
		_plant_placement_controller.is_processing_unhandled_input()
	)

	_tower_runtime_frozen = true
	_runtime.map_camera.enabled = false
	if tower_environment != null:
		tower_environment.environment = null
	# Music/循环声只暂停当前 playback；一次性 SFX 直接终止，不能在数分钟后续播。
	for audio_lease in _saved_audio_playback_leases:
		var audio_player := _get_current_audio_player(audio_lease)
		if audio_player == null:
			continue
		if audio_lease.preserve_playback:
			_set_audio_stream_paused(audio_player, true)
		else:
			_stop_transient_audio(audio_player)
	if _saved_terrain_decay_was_running:
		_terrain_decay_timer.stop()
	_production.set_authoritative_processing_enabled(false)
	_research.set_authoritative_processing_enabled(false)
	_plant_placement.cancel_placement()
	_plant_placement_controller.set_placement_input_enabled(false)
	_plant_placement_controller.set_process_unhandled_input(false)
	_player_roster.set_combat_action_lock_for_all(
		COMBAT_ACTION_LOCK_OWNER,
		true
	)
	for child_variant in _saved_process_modes.keys():
		var child := _get_valid_saved_node(child_variant)
		if child != null:
			child.process_mode = Node.PROCESS_MODE_DISABLED
	for child_variant in _saved_visibility.keys():
		var child := _get_valid_saved_node(child_variant)
		if child != null:
			child.set(&"visible", false)


func _restore_tower_runtime() -> void:
	if not _tower_runtime_frozen:
		return
	# PROCESS_MODE_DISABLED 的归还会让 Godot 自行改写 stream_paused；先为
	# 当前播放代留守卫，防止它覆盖原暂停或冻结期新 playback 的状态。
	var audio_pause_restore_guards: Array[TowerAudioPlaybackLease] = (
		_build_audio_pause_restore_guards()
	)
	var tower_environment := _runtime.get_node_or_null(
		"WorldEnvironment"
	) as WorldEnvironment
	if tower_environment != null:
		tower_environment.environment = _saved_tower_environment
	_runtime.map_camera.enabled = _saved_tower_camera_enabled
	for child_variant in _saved_process_modes.keys():
		var child := _get_valid_saved_node(child_variant)
		if child != null and child.get_parent() == _runtime:
			child.process_mode = int(_saved_process_modes[child_variant])
	for child_variant in _saved_visibility.keys():
		var child := _get_valid_saved_node(child_variant)
		if child is CanvasItem and child.get_parent() == _runtime:
			(child as CanvasItem).visible = bool(_saved_visibility[child_variant])
		elif child is CanvasLayer and child.get_parent() == _runtime:
			(child as CanvasLayer).visible = bool(_saved_visibility[child_variant])
	for restore_guard in audio_pause_restore_guards:
		var audio_player := _get_current_audio_player(restore_guard)
		if audio_player != null:
			_set_audio_stream_paused(audio_player, restore_guard.was_paused)
	_saved_process_modes.clear()
	_saved_visibility.clear()
	_saved_audio_playback_leases.clear()
	_saved_tower_environment = null
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		_production.set_authoritative_processing_enabled(
			_saved_production_processing_enabled
		)
		_research.set_authoritative_processing_enabled(
			_saved_research_processing_enabled
		)
	if _saved_terrain_decay_was_running and _terrain_decay_timer.is_stopped():
		_terrain_decay_timer.start(
			_saved_terrain_decay_time_left
			if _saved_terrain_decay_time_left > 0.0
			else _terrain_decay_timer.wait_time
		)
	_saved_terrain_decay_time_left = 0.0
	_saved_terrain_decay_was_running = false
	_plant_placement_controller.set_placement_input_enabled(
		_saved_placement_input_enabled
	)
	_plant_placement_controller.set_process_unhandled_input(
		_saved_placement_unhandled_input_enabled
	)
	_player_roster.set_combat_action_lock_for_all(
		COMBAT_ACTION_LOCK_OWNER,
		false
	)
	_tower_runtime_frozen = false


func _activate_rogue_core_for_entry() -> void:
	var fresh_map := not _route.is_route_ready() or _requires_fresh_map
	if fresh_map or not _rogue_core_initialized:
		_rogue_core_current = DEFAULT_ROGUE_CORE_HEALTH
		_rogue_core_maximum = DEFAULT_ROGUE_CORE_HEALTH
		_rogue_core_initialized = true
	_run_state.set_party_core_health(
		_rogue_core_current,
		_rogue_core_maximum
	)


func _cache_rogue_core_from_run_state() -> void:
	_rogue_core_current = _run_state.get_party_core_health()
	_rogue_core_maximum = _run_state.get_party_core_maximum_health()
	_rogue_core_initialized = true


func _restore_tower_core() -> void:
	_run_state.set_party_core_health(
		_saved_tower_core_current,
		_saved_tower_core_maximum,
		false
	)
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		_home_defense.set_authoritative_base_health(
			_saved_tower_core_maximum,
			_saved_tower_core_current
		)


func _capture_audio_playback_leases(
	node: Node,
	leases: Array[TowerAudioPlaybackLease]
) -> void:
	# 嵌套 Rogue 是独立音频域；即使未来层级调整，也不能纳入 Tower 租约。
	if node == self or self.is_ancestor_of(node):
		return
	if _is_audio_player(node) and _audio_player_has_playback(node):
		var stream := _get_audio_stream(node)
		var playback := _get_audio_playback(node)
		if stream != null and playback != null:
			var lease := TowerAudioPlaybackLease.new()
			lease.player_ref = weakref(node)
			lease.parent_ref = weakref(node.get_parent())
			lease.stream = stream
			lease.playback = playback
			lease.was_paused = _is_audio_stream_paused(node)
			lease.preserve_playback = _is_continuous_audio(stream)
			leases.append(lease)
	for child in node.get_children():
		_capture_audio_playback_leases(child, leases)


func _get_current_audio_player(lease: TowerAudioPlaybackLease) -> Node:
	if lease == null or lease.player_ref == null or lease.parent_ref == null:
		return null
	var audio_player := lease.player_ref.get_ref() as Node
	var original_parent := lease.parent_ref.get_ref() as Node
	if (
		audio_player == null
		or original_parent == null
		or not is_instance_valid(audio_player)
		or not is_instance_valid(original_parent)
		or not audio_player.is_inside_tree()
		or audio_player.get_parent() != original_parent
		or not _runtime.is_ancestor_of(audio_player)
		or self.is_ancestor_of(audio_player)
		or _get_audio_stream(audio_player) != lease.stream
		or _get_audio_playback(audio_player) != lease.playback
	):
		return null
	return audio_player


func _build_audio_pause_restore_guards() -> Array[TowerAudioPlaybackLease]:
	var guards: Array[TowerAudioPlaybackLease] = []
	for saved_lease in _saved_audio_playback_leases:
		if saved_lease.player_ref == null:
			continue
		var audio_player := saved_lease.player_ref.get_ref() as Node
		if (
			audio_player == null
			or not is_instance_valid(audio_player)
			or not audio_player.is_inside_tree()
			or not _runtime.is_ancestor_of(audio_player)
			or self.is_ancestor_of(audio_player)
			or not _audio_player_has_playback(audio_player)
		):
			continue
		var stream := _get_audio_stream(audio_player)
		var playback := _get_audio_playback(audio_player)
		if stream == null or playback == null:
			continue
		var guard := TowerAudioPlaybackLease.new()
		guard.player_ref = weakref(audio_player)
		guard.parent_ref = weakref(audio_player.get_parent())
		guard.stream = stream
		guard.playback = playback
		# 旧租约完全匹配时归还入口基线；否则只守住冻结期新播放代的现状。
		guard.was_paused = (
			saved_lease.was_paused
			if _get_current_audio_player(saved_lease) == audio_player
			else _is_audio_stream_paused(audio_player)
		)
		guards.append(guard)
	return guards


static func _is_audio_player(node: Node) -> bool:
	return (
		node is AudioStreamPlayer
		or node is AudioStreamPlayer2D
		or node is AudioStreamPlayer3D
	)


static func _audio_player_has_playback(node: Node) -> bool:
	if node is AudioStreamPlayer:
		return (node as AudioStreamPlayer).has_stream_playback()
	if node is AudioStreamPlayer2D:
		return (node as AudioStreamPlayer2D).has_stream_playback()
	if node is AudioStreamPlayer3D:
		return (node as AudioStreamPlayer3D).has_stream_playback()
	return false


static func _get_audio_stream(node: Node) -> AudioStream:
	if node is AudioStreamPlayer:
		return (node as AudioStreamPlayer).stream
	if node is AudioStreamPlayer2D:
		return (node as AudioStreamPlayer2D).stream
	if node is AudioStreamPlayer3D:
		return (node as AudioStreamPlayer3D).stream
	return null


static func _get_audio_playback(node: Node) -> AudioStreamPlayback:
	if node is AudioStreamPlayer:
		return (node as AudioStreamPlayer).get_stream_playback()
	if node is AudioStreamPlayer2D:
		return (node as AudioStreamPlayer2D).get_stream_playback()
	if node is AudioStreamPlayer3D:
		return (node as AudioStreamPlayer3D).get_stream_playback()
	return null


static func _is_continuous_audio(stream: AudioStream) -> bool:
	# Bus 只负责混音，不能把 Music 上的一次性提示误判成可恢复的循环播放。
	if stream is AudioStreamMP3:
		return (stream as AudioStreamMP3).loop
	if stream is AudioStreamOggVorbis:
		return (stream as AudioStreamOggVorbis).loop
	if stream is AudioStreamWAV:
		return (
			(stream as AudioStreamWAV).loop_mode
			!= AudioStreamWAV.LOOP_DISABLED
		)
	# Generator 没有自然结束点，语义上也是长生命周期 playback。
	return stream is AudioStreamGenerator


static func _is_audio_stream_paused(node: Node) -> bool:
	if node is AudioStreamPlayer:
		return (node as AudioStreamPlayer).stream_paused
	if node is AudioStreamPlayer2D:
		return (node as AudioStreamPlayer2D).stream_paused
	if node is AudioStreamPlayer3D:
		return (node as AudioStreamPlayer3D).stream_paused
	return false


static func _set_audio_stream_paused(node: Node, paused: bool) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stream_paused = paused
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stream_paused = paused
	elif node is AudioStreamPlayer3D:
		(node as AudioStreamPlayer3D).stream_paused = paused


static func _stop_transient_audio(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		var player_2d := node as AudioStreamPlayer2D
		SPATIAL_AUDIO_VOICE_LIMITER.preempt_all_voice_claims(player_2d)
	elif node is AudioStreamPlayer3D:
		(node as AudioStreamPlayer3D).stop()


static func _get_valid_saved_node(value: Variant) -> Node:
	if value == null or not is_instance_valid(value):
		return null
	return value as Node


func get_route() -> RogueRouteGame:
	return _route


func get_combat_coordinator() -> Node:
	if _runtime != null and _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return _route.get_node_or_null("SingleplayerCombatCoordinator")
	return _multiplayer_combat_coordinator


func is_exploration_active() -> bool:
	return _active


func is_tower_runtime_suspended() -> bool:
	return _active or _presentation_exit_pending


## 重连会在 Rogue 已冻结塔防子树之后创建新的 Player。该节点必须加入
## 同一份表现租约，否则它会在隐藏的塔防世界中继续处理本地输入和角色
## 状态。把它的原始 process/visibility 纳入既有恢复账本，Rogue 退出时
## 即可与入口时存在的玩家原子恢复，不需要重跑整套冻结流程。
func synchronize_reconnected_player_suspension(peer_id: int) -> bool:
	if (
		peer_id <= 0
		or not _tower_runtime_frozen
		or not is_tower_runtime_suspended()
		or _player_roster == null
	):
		return false
	var player_instance := _player_roster.get_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return false
	if not _saved_process_modes.has(player_instance):
		_saved_process_modes[player_instance] = player_instance.process_mode
	if not _saved_visibility.has(player_instance):
		_saved_visibility[player_instance] = player_instance.visible
	player_instance.set_combat_action_lock(COMBAT_ACTION_LOCK_OWNER, true)
	player_instance.process_mode = Node.PROCESS_MODE_DISABLED
	player_instance.visible = false
	return true


func has_pending_presentation_exit() -> bool:
	return _presentation_exit_pending


func complete_pending_presentation_exit() -> bool:
	if not _presentation_exit_pending or _presentation_exit_completing:
		return false
	_presentation_exit_completing = true
	# pending 在整个同步恢复事务中继续持有 Tower world suspension；
	# HomeDefense/玩家恢复会同步发信号，不能让观察者看见半恢复的伪空闲态。
	_restore_tower_core()
	_route.set_embedded_presentation_active(false)
	_restore_tower_runtime()
	# Tower 的场景 owner 在 Player 清空瞬态之后立即重投影完整命运层；
	# 建筑光环继续由各建筑 owner 重算，不会被带入地下作战。
	_fate.apply_player_modifiers_to_all()
	_player_roster.restore_all_players_to_full_health(
		_runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)
	_presentation_exit_pending = false
	_presentation_exit_completing = false
	return true


func _begin_pending_presentation_exit() -> void:
	if _presentation_exit_pending:
		return
	_presentation_exit_pending = true
	# 保留最后一帧路线画面给小葱转场遮罩，但停止路线输入、动画和角色模拟。
	_route.process_mode = Node.PROCESS_MODE_DISABLED


func export_multiplayer_snapshot_for_peer(peer_id: int = -1) -> Dictionary:
	var tower_core_current := _home_defense.current_base_health
	var tower_core_maximum := _home_defense.maximum_base_health
	if _active or _finishing or _presentation_exit_pending:
		tower_core_current = _saved_tower_core_current
		tower_core_maximum = _saved_tower_core_maximum
	var player_upgrade_ledger := _run_state.export_player_upgrade_ledger()
	var party_economy := _run_state.export_party_economy_snapshot()
	var party_xirang_ledger := _run_state.export_party_xirang_ledger()
	var party_status_ledger := _run_state.export_party_status_ledger()
	var research_runtime_state := _research.export_runtime_state()
	var fate_persistent_modifiers := (
		_fate.export_persistent_player_modifier_snapshot()
	)
	if (
		player_upgrade_ledger.is_empty()
		or party_economy.is_empty()
		or party_xirang_ledger.is_empty()
		or party_status_ledger.is_empty()
		or research_runtime_state.is_empty()
		or fate_persistent_modifiers.is_empty()
	):
		return {}
	var snapshot := {
		"schema_version": SNAPSHOT_SCHEMA_VERSION,
		"progression_contract_hash": _progression.compute_runtime_contract_hash(),
		"player_upgrade_ledger": player_upgrade_ledger,
		"party_economy": party_economy,
		"party_xirang_ledger": party_xirang_ledger,
		"party_status_ledger": party_status_ledger,
		"research_runtime_state": research_runtime_state,
		"fate_persistent_player_modifiers": fate_persistent_modifiers,
		"active": _active,
		"day": _active_day,
		"map_generation_epoch": _map_generation_epoch,
		"daily_grant_ledger": _export_daily_grant_ledger(),
		"next_step_id": String(_next_step_id),
		"tower_core_current": tower_core_current,
		"tower_core_maximum": tower_core_maximum,
	}
	if _active and _route.is_route_ready():
		snapshot["route_layout"] = _route.export_layout_snapshot()
		snapshot["route_state"] = _route.export_state_snapshot()
		snapshot["encounter"] = _route.export_encounter_snapshot(peer_id)
		snapshot["economy"] = _route.export_encounter_economy_snapshot(peer_id)
		snapshot["shop"] = _route.export_shop_snapshot_for_peer(peer_id)
	return snapshot


func _export_daily_grant_ledger() -> Dictionary:
	var result := {}
	for day_number in _daily_grant_ledger.keys():
		result[str(day_number)] = _daily_grant_ledger[day_number]
	return result


func apply_multiplayer_snapshot(snapshot: Dictionary) -> bool:
	if (
		_multiplayer_snapshot_apply_in_progress
		or _route == null
		or not _route.try_begin_full_snapshot_transaction()
	):
		return false
	_multiplayer_snapshot_apply_in_progress = true
	var applied := _apply_multiplayer_snapshot_guarded(snapshot)
	_multiplayer_snapshot_apply_in_progress = false
	_route.end_full_snapshot_transaction()
	return applied


## public wrapper 持有同步重入门；内部可以在任一 prepare/CAS 分支直接
## 返回，wrapper 仍会可靠释放门，不把 signal 回调排队到下一代快照。
func _apply_multiplayer_snapshot_guarded(snapshot: Dictionary) -> bool:
	var prepared := _preflight_multiplayer_snapshot(snapshot)
	if prepared.is_empty():
		return false
	var incoming_active := bool(prepared["active"])
	var prepared_progression := (
		prepared["prepared_player_upgrade_ledger"] as Dictionary
	)
	var prepared_party_economy := (
		prepared["prepared_party_economy"] as Dictionary
	)
	var prepared_research := (
		prepared["prepared_research_runtime_state"] as Dictionary
	)
	var prepared_fate := (
		prepared["prepared_fate_persistent_modifiers"] as Dictionary
	)
	var prepared_identity := (
		prepared.get("prepared_route_runtime_identity", {}) as Dictionary
	)
	var prepared_route := (
		prepared.get("prepared_route_full_snapshot", {}) as Dictionary
	)
	var prepared_player_progression := (
		prepared.get("prepared_route_player_progression", {}) as Dictionary
	)
	var prepared_persistent_modifiers := (
		prepared.get("prepared_route_persistent_modifiers", {}) as Dictionary
	)
	if (
		not _run_state.can_commit_prepared_player_upgrade_ledger(
			prepared_progression
		)
		or not _run_state.can_commit_prepared_party_economy_snapshot(
			prepared_party_economy
		)
		or not _research.can_commit_prepared_multiplayer_runtime_state(
			prepared_research
		)
		or not _fate.can_commit_prepared_persistent_player_modifier_snapshot(
			prepared_fate
		)
	):
		_discard_prepared_multiplayer_snapshot(prepared)
		return false
	if incoming_active and (
		not _can_commit_prepared_route_runtime_identity(prepared_identity)
		or not _route.can_commit_prepared_full_snapshot(prepared_route)
		or not _route.can_commit_prepared_authoritative_player_progression(
			prepared_player_progression
		)
		or not _persistent_modifier_projector.can_commit_prepared_for_players(
			prepared_persistent_modifiers
		)
	):
		_discard_prepared_multiplayer_snapshot(prepared)
		return false
	var was_active := _active
	var entering_exploration_boundary := (
		incoming_active
		and (
			not was_active
			or int(prepared["day"]) != _active_day
			or int(prepared["map_generation_epoch"]) != _map_generation_epoch
		)
	)
	# 从这里开始只有经 prepare/CAS 证明的无失败写入口；所有信号、UI 与
	# reveal 均延迟到 Route/party/成长/Research/Fate/identity/Player 齐备。
	if incoming_active:
		_route.begin_validated_authoritative_player_projection(
			prepared_player_progression
		)
		_route.commit_validated_full_snapshot(prepared_route, false)
	else:
		_run_state.commit_validated_party_economy_snapshot(
			prepared_party_economy,
			false
		)
	_run_state.commit_validated_player_upgrade_ledger(
		prepared_progression,
		false
	)
	_research.commit_validated_multiplayer_runtime_state(
		prepared_research,
		false
	)
	_fate.commit_validated_persistent_player_modifier_snapshot(
		prepared_fate,
		false
	)
	if incoming_active:
		_commit_validated_route_runtime_identity(prepared_identity, false)
		_route.commit_validated_authoritative_player_progression(
			prepared_player_progression
		)
		_route.commit_validated_authoritative_player_xirang(
			prepared_player_progression
		)
		_persistent_modifier_projector.commit_validated_for_players(
			prepared_persistent_modifiers
		)
		# active 全量快照已原子应用其 party economy；在任何跨信道的
		# Tower 基地恢复到达前，锁存本次 Rogue 核心恢复账本。
		_cache_rogue_core_from_run_state()
	_active = incoming_active
	_active_day = int(prepared["day"])
	_map_generation_epoch = int(prepared["map_generation_epoch"])
	_daily_grant_ledger.clear()
	var prepared_ledger := prepared["daily_grant_ledger"] as Dictionary
	for day_number_variant in prepared_ledger.keys():
		_daily_grant_ledger[int(day_number_variant)] = int(
			prepared_ledger[day_number_variant]
		)
	_next_step_id = StringName(prepared["next_step_id"])
	if incoming_active and not was_active:
		_presentation_exit_pending = false
		_freeze_tower_runtime()
		# 晚加入客户端可能先收到探索快照、后收到塔防全量状态；冻结时本地
		# HomeDefense 仍是默认值，因此必须以 Host 在进入探索前保存的核心值
		# 覆盖恢复账本，退出时才不会把真实基地血量回滚成默认值。
		_saved_tower_core_current = int(prepared["tower_core_current"])
		_saved_tower_core_maximum = int(prepared["tower_core_maximum"])
		set_process(false)
	elif not incoming_active and was_active:
		_saved_tower_core_current = int(prepared["tower_core_current"])
		_saved_tower_core_maximum = int(prepared["tower_core_maximum"])
		_begin_pending_presentation_exit()
	elif not incoming_active and _presentation_exit_pending:
		# inactive 快照可能因流程状态广播或可靠重发重复到达；只刷新 Host
		# 保存的塔防核心边界，不能重复退出表现或再次改写 Rogue 核心账本。
		_saved_tower_core_current = int(prepared["tower_core_current"])
		_saved_tower_core_maximum = int(prepared["tower_core_maximum"])
	elif incoming_active:
		# 同一 active 会话的重复全量同步不应回血或重建布局，但仍需刷新
		# Tower 恢复边界，覆盖客户端较晚到达的本地默认/旧塔防状态。
		_saved_tower_core_current = int(prepared["tower_core_current"])
		_saved_tower_core_maximum = int(prepared["tower_core_maximum"])
	if incoming_active:
		_route.stage_validated_authoritative_player_projection_publish(
			prepared_player_progression,
			entering_exploration_boundary
		)
	# 所有 owner 与 Player 都已提交，先发布账本，再允许 Route UI/reveal。
	if incoming_active:
		_route.publish_prepared_full_snapshot_changes(prepared_route)
	else:
		_run_state.publish_prepared_party_economy_snapshot(
			prepared_party_economy
		)
	_run_state.publish_prepared_player_upgrade_ledger(prepared_progression)
	_research.publish_prepared_multiplayer_runtime_state(prepared_research)
	_fate.publish_prepared_persistent_player_modifier_snapshot(prepared_fate)
	if incoming_active:
		_route.publish_validated_authoritative_player_projection(
			prepared_player_progression
		)
		if not was_active:
			_route.set_embedded_presentation_active(true)
		_route.complete_prepared_full_snapshot_presentation()
	return true


func _discard_prepared_multiplayer_snapshot(prepared: Dictionary) -> void:
	if prepared.is_empty():
		return
	var prepared_route := prepared.get(
		"prepared_route_full_snapshot",
		{}
	) as Dictionary
	if not prepared_route.is_empty():
		_route.discard_prepared_full_snapshot(prepared_route)
	var prepared_identity := prepared.get(
		"prepared_route_runtime_identity",
		{}
	) as Dictionary
	if not prepared_identity.is_empty():
		_discard_prepared_route_runtime_identity(prepared_identity)


func _preflight_multiplayer_snapshot(snapshot: Dictionary) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SNAPSHOT_SCHEMA_VERSION
		or typeof(snapshot.get("progression_contract_hash")) != TYPE_STRING
		or str(snapshot["progression_contract_hash"])
		!= _progression.compute_runtime_contract_hash()
		or typeof(snapshot.get("player_upgrade_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("party_economy")) != TYPE_DICTIONARY
		or typeof(snapshot.get("party_xirang_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("party_status_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("research_runtime_state")) != TYPE_DICTIONARY
		or typeof(snapshot.get("fate_persistent_player_modifiers"))
		!= TYPE_DICTIONARY
		or typeof(snapshot.get("active")) != TYPE_BOOL
		or typeof(snapshot.get("day")) != TYPE_INT
		or typeof(snapshot.get("map_generation_epoch")) != TYPE_INT
		or int(snapshot["map_generation_epoch"]) < _map_generation_epoch
		or typeof(snapshot.get("daily_grant_ledger")) != TYPE_DICTIONARY
		or typeof(snapshot.get("next_step_id")) != TYPE_STRING
		or typeof(snapshot.get("tower_core_current")) != TYPE_INT
		or typeof(snapshot.get("tower_core_maximum")) != TYPE_INT
	):
		return {}
	var prepared_player_upgrade_ledger := (
		_run_state.prepare_player_upgrade_ledger(
			snapshot["player_upgrade_ledger"] as Dictionary,
			true
		)
	)
	var incoming_active := bool(snapshot["active"])
	var party_economy_snapshot := snapshot["party_economy"] as Dictionary
	if (
		party_economy_snapshot.get("xirang_ledger", {})
		!= snapshot["party_xirang_ledger"]
		or party_economy_snapshot.get("party_status_ledger", {})
		!= snapshot["party_status_ledger"]
	):
		return {}
	var prepared_party_economy := (
		_run_state.prepare_party_economy_snapshot(
			party_economy_snapshot,
			false
		)
		if incoming_active
		else _run_state.prepare_party_economy_snapshot_or_current_if_fully_stale(
			party_economy_snapshot
		)
	)
	var prepared_research_runtime_state := (
		_research.prepare_multiplayer_runtime_state(
			snapshot["research_runtime_state"] as Dictionary,
			true
		)
	)
	var prepared_fate_persistent_modifiers := (
		_fate.prepare_persistent_player_modifier_snapshot(
			snapshot["fate_persistent_player_modifiers"] as Dictionary,
			true
		)
	)
	if (
		prepared_player_upgrade_ledger.is_empty()
		or prepared_party_economy.is_empty()
		or prepared_research_runtime_state.is_empty()
		or prepared_fate_persistent_modifiers.is_empty()
		or not _research_levels_cover_progression_members(
			prepared_player_upgrade_ledger,
			prepared_research_runtime_state
		)
	):
		return {}
	var tower_core_current := int(snapshot["tower_core_current"])
	var tower_core_maximum := int(snapshot["tower_core_maximum"])
	if (
		tower_core_maximum <= 0
		or tower_core_current < 0
		or tower_core_current > tower_core_maximum
	):
		return {}
	var incoming_day := int(snapshot["day"])
	var incoming_epoch := int(snapshot["map_generation_epoch"])
	if incoming_active and (
		incoming_day < 1
		or incoming_day > TowerDefenseProgressionConfig.ROGUE_EXPLORATION_DAY_COUNT
		or str(snapshot["next_step_id"]).is_empty()
	):
		return {}
	# active outer 是 reveal Route Player 的同代权威屏障。若 Research/Fate
	# 独立信道已推进到更高 revision，旧 CH0 不能用旧永久层构建 Player；
	# 等待 Host 的下一份自包含 outer 快照收敛。
	if incoming_active and (
		bool(prepared_research_runtime_state["stale"])
		or bool(prepared_fate_persistent_modifiers["stale"])
	):
		return {}
	if not incoming_active and (
		incoming_day != INVALID_DAY
		or not str(snapshot["next_step_id"]).is_empty()
		or (
			(_active or _presentation_exit_pending)
			and incoming_epoch != _map_generation_epoch
		)
	):
		return {}
	var ledger := _decode_daily_grant_ledger(
		snapshot["daily_grant_ledger"] as Dictionary
	)
	if ledger.size() != (snapshot["daily_grant_ledger"] as Dictionary).size():
		return {}
	for day_number in _daily_grant_ledger.keys():
		if (
			not ledger.has(day_number)
			or ledger[day_number] != _daily_grant_ledger[day_number]
		):
			return {}
	if incoming_active and not ledger.has(incoming_day):
		return {}
	if incoming_active and _is_active_snapshot_superseded_by_campaign(
		incoming_day,
		StringName(snapshot["next_step_id"])
	):
		return {}
	# 一个 active 会话不能被另一日/另一地图的 active 快照原地替换；
	# pending 也只能由显式视觉退出消费。否则乱序重发会绕过 Fate 并
	# 复用上一份 Tower 冻结租约。
	if incoming_active and (
		_presentation_exit_pending
		or (
			_active
			and (
				incoming_day != _active_day
				or incoming_epoch != _map_generation_epoch
			)
		)
		or (not _active and _daily_grant_ledger.has(incoming_day))
	):
		return {}
	var prepared := snapshot.duplicate(true)
	prepared["daily_grant_ledger"] = ledger
	prepared["prepared_player_upgrade_ledger"] = (
		prepared_player_upgrade_ledger
	)
	prepared["prepared_party_economy"] = (
		prepared_party_economy
	)
	prepared["prepared_research_runtime_state"] = (
		prepared_research_runtime_state
	)
	prepared["prepared_fate_persistent_modifiers"] = (
		prepared_fate_persistent_modifiers
	)
	if incoming_active:
		for field_name in ["route_layout", "route_state", "encounter", "economy", "shop"]:
			if typeof(snapshot.get(field_name)) != TYPE_DICTIONARY:
				return {}
		var route_economy := snapshot["economy"] as Dictionary
		var route_party_economy := route_economy.get(
			"party_economy",
			{}
		) as Dictionary
		if (
			route_party_economy.get("xirang_ledger", {})
			!= snapshot["party_xirang_ledger"]
			or route_party_economy.get("party_status_ledger", {})
			!= snapshot["party_status_ledger"]
		):
			return {}
		var prepared_identity := _prepare_route_runtime_identity()
		if not _can_commit_prepared_route_runtime_identity(prepared_identity):
			_discard_prepared_route_runtime_identity(prepared_identity)
			return {}
		var validation_peer_id := (
			_route.get_configured_local_peer_id()
			if bool(prepared_identity["already_configured"])
			else int(prepared_identity["local_peer_id"])
		)
		if validation_peer_id < 0:
			_discard_prepared_route_runtime_identity(prepared_identity)
			return {}
		var prepared_route := _route.prepare_full_snapshot(
			snapshot["route_layout"] as Dictionary,
			snapshot["route_state"] as Dictionary,
			snapshot["encounter"] as Dictionary,
			snapshot["economy"] as Dictionary,
			snapshot["shop"] as Dictionary,
			validation_peer_id,
			party_economy_snapshot
		)
		if prepared_route.is_empty():
			_discard_prepared_route_runtime_identity(prepared_identity)
			return {}
		var prepared_player_progression := (
			_route.prepare_authoritative_player_progression(
				prepared_player_upgrade_ledger,
				prepared_route,
				(
					prepared_identity["roster"] as Dictionary
					if not bool(prepared_identity["already_configured"])
					else {}
				)
			)
		)
		var players_for_projection := (
			(prepared_identity["roster"] as Dictionary)["players"] as Dictionary
			if not bool(prepared_identity["already_configured"])
			else _route.get_players_for_persistent_projection()
		)
		var prepared_persistent_modifiers := (
			_persistent_modifier_projector.prepare_for_players(
				players_for_projection,
				prepared_research_runtime_state,
				prepared_fate_persistent_modifiers
			)
		)
		if (
			prepared_player_progression.is_empty()
			or prepared_persistent_modifiers.is_empty()
		):
			_route.discard_prepared_full_snapshot(prepared_route)
			_discard_prepared_route_runtime_identity(prepared_identity)
			return {}
		prepared["prepared_route_runtime_identity"] = prepared_identity
		prepared["prepared_route_full_snapshot"] = prepared_route
		prepared["prepared_route_player_progression"] = (
			prepared_player_progression
		)
		prepared["prepared_route_persistent_modifiers"] = (
			prepared_persistent_modifiers
		)
	return prepared


func _research_levels_cover_progression_members(
	prepared_progression: Dictionary,
	prepared_research: Dictionary
) -> bool:
	var progression_values := prepared_progression.get("values", {}) as Dictionary
	var research_levels := prepared_research.get("player_levels", {}) as Dictionary
	if progression_values.is_empty() or research_levels.is_empty():
		return false
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return research_levels.has(0)
	for peer_id in _run_state.get_registered_multiplayer_peer_ids():
		if not progression_values.has(peer_id) or not research_levels.has(peer_id):
			return false
	return true


func _is_active_snapshot_superseded_by_campaign(
	incoming_day: int,
	incoming_next_step_id: StringName
) -> bool:
	var flow_state := _campaign.wave_state
	if flow_state == CombatFlowState.State.ROGUE_EXPLORATION:
		return false
	# Fate/终局只能出现在本次 Rogue 的逻辑退出之后；跨信道晚到的
	# active 快照已经被该权威流程淘汰，不能重新取得 Tower 冻结租约。
	if flow_state in [
		CombatFlowState.State.FATE_INTERLUDE,
		CombatFlowState.State.VICTORY,
		CombatFlowState.State.DEFEAT,
	]:
		return true
	var campaign_day := _campaign.get_day_number_for_wave(
		maxi(_campaign.current_wave_index + 1, 1)
	)
	if incoming_day > 0 and incoming_day < campaign_day:
		return true
	var current_step_id := _campaign.get_flow_step_id(
		_campaign.current_flow_step
	)
	return (
		not current_step_id.is_empty()
		and current_step_id == incoming_next_step_id
	)


func _decode_daily_grant_ledger(raw_ledger: Dictionary) -> Dictionary[int, int]:
	var result: Dictionary[int, int] = {}
	for raw_day in raw_ledger.keys():
		if typeof(raw_day) != TYPE_STRING or typeof(raw_ledger[raw_day]) != TYPE_INT:
			return {}
		var day_text := str(raw_day)
		if not day_text.is_valid_int():
			return {}
		var day_number := int(day_text)
		var amount := int(raw_ledger[raw_day])
		if (
			day_number < 1
			or day_number > TowerDefenseProgressionConfig.ROGUE_EXPLORATION_DAY_COUNT
			or amount != _progression.get_daily_rogue_action_points(day_number)
		):
			return {}
		result[day_number] = amount
	return result


func host_remove_disconnected_peer(peer_id: int) -> void:
	if not _is_local_authority() or peer_id <= 0:
		return
	_route.host_remove_encounter_peer(peer_id)
	_route.host_remove_shop_peer(peer_id)
	_route.remove_multiplayer_player(peer_id)
	exploration_snapshot_changed.emit(export_multiplayer_snapshot_for_peer())


func host_migrate_reconnected_peer(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if not _is_local_authority() or old_peer_id <= 0 or new_peer_id <= 0:
		return false
	var migrated := _route.migrate_multiplayer_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	)
	if not migrated:
		var fallback_position := Vector2.ZERO
		var host_player := _route.get_player_for_peer(
			_net_manager.get_host_peer_id() if _net_manager != null else 0
		)
		if host_player != null:
			fallback_position = host_player.global_position
		migrated = _route.add_multiplayer_player(
			new_peer_id,
			player_name,
			character_id,
			_route.clamp_avatar_position(fallback_position)
		)
	if not migrated:
		return false
	_route.host_migrate_encounter_peer(old_peer_id, new_peer_id)
	_route.host_migrate_shop_peer_as_exited(old_peer_id, new_peer_id)
	if _net_manager != null:
		var stable_key := _net_manager.get_stable_participant_key(new_peer_id)
		if not stable_key.is_empty():
			_route.set_multiplayer_participant_stable_key(new_peer_id, stable_key)
	# 路线身份与当前内嵌作战身份属于同一个重连事务。内嵌 Player 结果可在
	# 本调用前后到达，作战协调器会按 new peer 汇合，不能靠监听顺序探测节点。
	if not _multiplayer_combat_coordinator.handle_reconnected_identity_committed(
		old_peer_id,
		new_peer_id
	):
		return false
	exploration_snapshot_changed.emit(export_multiplayer_snapshot_for_peer(new_peer_id))
	return true


func handle_reconnected_member_ready(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome
) -> bool:
	if not _is_local_authority() or _multiplayer_combat_coordinator == null:
		return false
	return _multiplayer_combat_coordinator.handle_reconnected_member_ready(
		old_peer_id,
		new_peer_id,
		outcome
	)


func _on_route_return_requested() -> void:
	if _route.has_run_failed():
		host_handle_exploration_failure()


func _on_party_status_ledger_changed(_snapshot: Dictionary) -> void:
	# Rogue economy 更新与 inactive 探索快照同走可靠 channel 0；因此
	# active 期间最后一次信号一定先于该退出快照。Tower 基地恢复使用
	# emit_change_signal=false，不会把 channel 5 的 Tower 核心写进缓存。
	if _active:
		_cache_rogue_core_from_run_state()


func _is_local_authority() -> bool:
	return (
		_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		or (
			_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
			and _net_manager != null
			and _net_manager.is_host()
		)
	)
