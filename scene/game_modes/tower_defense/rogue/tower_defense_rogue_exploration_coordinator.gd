extends Node
class_name TowerDefenseRogueExplorationCoordinator

const MultiplayerReconnectTypesScript := preload(
	"res://scene/multiplayer/reconnect/multiplayer_reconnect_types.gd"
)
const SNAPSHOT_SCHEMA_VERSION := 1
const INVALID_DAY := 0
const DEFAULT_ROGUE_CORE_HEALTH := 100
const COMBAT_ACTION_LOCK_OWNER := &"tower_rogue_exploration"

signal exploration_started(day_number: int, snapshot: Dictionary)
signal exploration_snapshot_changed(snapshot: Dictionary)
signal exploration_finished(day_number: int, failed: bool)

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
var _net_manager: NetManagerStore = null
var _run_state: RunStateStore = null

var _active := false
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
var _saved_music_paused: Dictionary = {}
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
	_run_state = run_state
	_net_manager = NetManagerStore.get_autoload_instance()
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
		and _run_state != null
		and _route != null
		and _multiplayer_combat_coordinator != null
		and not _progression.compute_runtime_contract_hash().is_empty()
	)


func _configure_route_runtime_identity() -> bool:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_route.set_authority_enabled(true)
		return _route.configure_embedded_singleplayer_player()
	if _net_manager == null:
		return false
	var player_names := _net_manager.connected_players.duplicate()
	var character_ids := _net_manager.get_player_character_map().duplicate()
	var local_peer_id := _net_manager.get_local_peer_id()
	if local_peer_id <= 0 or not player_names.has(local_peer_id):
		return false
	var stable_keys: Dictionary = {}
	for peer_id_variant in player_names.keys():
		var peer_id := int(peer_id_variant)
		var stable_key := _net_manager.get_stable_participant_key(peer_id)
		if _net_manager.is_host() and stable_key.is_empty():
			push_error("塔防地下探索玩家 %d 缺少稳定参与者身份。" % peer_id)
			return false
		if not stable_key.is_empty():
			stable_keys[peer_id] = stable_key
	if not _route.configure_multiplayer_players(
		local_peer_id,
		player_names,
		character_ids,
		stable_keys
	):
		return false
	_route.set_authority_enabled(_net_manager.is_host())
	_multiplayer_combat_coordinator.bind_network_dependencies(
		_route,
		_net_manager,
		_run_state,
		RogueCombatMultiplayerCoordinator.SessionProjectionOwner.ENCLOSING_RUNTIME
	)
	return _multiplayer_combat_coordinator.is_enabled()


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
	if not _route.restore_embedded_players_to_full_health():
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
		_capture_music_pause_state(child)
		if _has_property(child, &"visible"):
			_saved_visibility[child] = bool(child.get(&"visible"))
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
	# AudioStreamPlayer 会在所属节点停处理时改变暂停态；先显式暂停同一个
	# playback，再禁用子树，恢复时才能继续原播放位置。
	for player_variant in _saved_music_paused.keys():
		var audio_player := _get_valid_saved_node(player_variant)
		if audio_player != null:
			audio_player.set(&"stream_paused", true)
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
	var tower_environment := _runtime.get_node_or_null(
		"WorldEnvironment"
	) as WorldEnvironment
	if tower_environment != null:
		tower_environment.environment = _saved_tower_environment
	_runtime.map_camera.enabled = _saved_tower_camera_enabled
	for child_variant in _saved_process_modes.keys():
		var child := _get_valid_saved_node(child_variant)
		if child != null:
			child.process_mode = int(_saved_process_modes[child_variant])
	for child_variant in _saved_visibility.keys():
		var child := _get_valid_saved_node(child_variant)
		if child != null:
			child.set(&"visible", bool(_saved_visibility[child_variant]))
	for player_variant in _saved_music_paused.keys():
		var audio_player := _get_valid_saved_node(player_variant)
		if audio_player != null:
			audio_player.set(
				&"stream_paused",
				bool(_saved_music_paused[player_variant])
			)
	_saved_process_modes.clear()
	_saved_visibility.clear()
	_saved_music_paused.clear()
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


func _capture_music_pause_state(node: Node) -> void:
	var has_playback := false
	if node is AudioStreamPlayer:
		has_playback = (node as AudioStreamPlayer).has_stream_playback()
	elif node is AudioStreamPlayer2D:
		has_playback = (node as AudioStreamPlayer2D).has_stream_playback()
	elif node is AudioStreamPlayer3D:
		has_playback = (node as AudioStreamPlayer3D).has_stream_playback()
	if has_playback:
		_saved_music_paused[node] = bool(node.get(&"stream_paused"))
	for child in node.get_children():
		_capture_music_pause_state(child)


static func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false


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
	var snapshot := {
		"schema_version": SNAPSHOT_SCHEMA_VERSION,
		"progression_contract_hash": _progression.compute_runtime_contract_hash(),
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
	var prepared := _preflight_multiplayer_snapshot(snapshot)
	if prepared.is_empty():
		return false
	var incoming_active := bool(prepared["active"])
	var was_active := _active
	var entering_exploration_boundary := (
		incoming_active
		and (
			not was_active
			or int(prepared["day"]) != _active_day
			or int(prepared["map_generation_epoch"]) != _map_generation_epoch
		)
	)
	if incoming_active:
		if not _ensure_route_runtime_identity():
			return false
		if not _route.apply_full_snapshot(
			prepared["route_layout"] as Dictionary,
			prepared["route_state"] as Dictionary,
			prepared["encounter"] as Dictionary,
			prepared["economy"] as Dictionary,
			prepared["shop"] as Dictionary
		):
			return false
		if (
			entering_exploration_boundary
			and not _route.restore_embedded_players_to_full_health()
		):
			return false
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
		_route.set_embedded_presentation_active(true)
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
	return true


func _preflight_multiplayer_snapshot(snapshot: Dictionary) -> Dictionary:
	if (
		typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != SNAPSHOT_SCHEMA_VERSION
		or typeof(snapshot.get("progression_contract_hash")) != TYPE_STRING
		or str(snapshot["progression_contract_hash"])
		!= _progression.compute_runtime_contract_hash()
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
	var tower_core_current := int(snapshot["tower_core_current"])
	var tower_core_maximum := int(snapshot["tower_core_maximum"])
	if (
		tower_core_maximum <= 0
		or tower_core_current < 0
		or tower_core_current > tower_core_maximum
	):
		return {}
	var incoming_active := bool(snapshot["active"])
	var incoming_day := int(snapshot["day"])
	var incoming_epoch := int(snapshot["map_generation_epoch"])
	if incoming_active and (
		incoming_day < 1
		or incoming_day > TowerDefenseProgressionConfig.ROGUE_EXPLORATION_DAY_COUNT
		or str(snapshot["next_step_id"]).is_empty()
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
	if incoming_active:
		for field_name in ["route_layout", "route_state", "encounter", "economy", "shop"]:
			if typeof(snapshot.get(field_name)) != TYPE_DICTIONARY:
				return {}
	return prepared


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
