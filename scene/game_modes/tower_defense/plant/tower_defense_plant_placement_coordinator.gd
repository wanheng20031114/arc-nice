extends Node
class_name TowerDefensePlantPlacementCoordinator

signal placement_mode_changed(active: bool)
signal placement_input_enabled_changed(enabled: bool)
signal player_controls_lock_changed(locked: bool)
signal plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
)
signal inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
)

var _placement_controller: PlantPlacementController = null
var _plant_system: PlantSystem = null
var _plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator = null
var _run_state: RunStateStore = null
var _local_player: Player = null
var _session_object_pool: SessionObjectPool = null
var _settings_panel: SettingsPanel = null
var _profile_panel: TowerDefensePlayerProfilePanel = null
var _debug_collectible_window: DebugCollectibleWindow = null
var _placement_particles_scene: PackedScene = null
var _removal_smoke_scene: PackedScene = null
var _runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var _local_peer_id := 0
var _sandbox_free_building_enabled := false
var _flow_state: CombatFlowState.State = CombatFlowState.State.PRE_WAVE
var _placement_input_enabled := false
var _last_player_controls_locked := false


func setup(
	placement_controller: PlantPlacementController,
	plant_system: PlantSystem,
	plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator,
	run_state: RunStateStore,
	local_player: Player,
	session_object_pool: SessionObjectPool,
	settings_panel: SettingsPanel,
	profile_panel: TowerDefensePlayerProfilePanel,
	debug_collectible_window: DebugCollectibleWindow,
	placement_particles_scene: PackedScene,
	removal_smoke_scene: PackedScene,
	runtime_mode: int,
	local_peer_id: int,
	sandbox_free_building_enabled: bool,
	initial_flow_state: CombatFlowState.State
) -> bool:
	if (
		placement_controller == null
		or plant_system == null
		or plant_runtime_coordinator == null
		or run_state == null
		or local_player == null
		or session_object_pool == null
	):
		push_error(
			"TowerDefensePlantPlacementCoordinator: 缺少放置系统、玩家或对象池依赖。"
		)
		return false
	if settings_panel == null or profile_panel == null or debug_collectible_window == null:
		push_error("TowerDefensePlantPlacementCoordinator: 缺少强类型 modal 面板依赖。")
		return false
	if placement_particles_scene == null or removal_smoke_scene == null:
		push_error("TowerDefensePlantPlacementCoordinator: 缺少植物放置/移除表现资源。")
		return false

	_placement_controller = placement_controller
	_plant_system = plant_system
	_plant_runtime_coordinator = plant_runtime_coordinator
	_run_state = run_state
	_local_player = local_player
	_session_object_pool = session_object_pool
	_settings_panel = settings_panel
	_profile_panel = profile_panel
	_debug_collectible_window = debug_collectible_window
	_placement_particles_scene = placement_particles_scene
	_removal_smoke_scene = removal_smoke_scene
	_runtime_mode = runtime_mode
	_local_peer_id = maxi(local_peer_id, 0)
	_sandbox_free_building_enabled = sandbox_free_building_enabled
	_flow_state = initial_flow_state
	_last_player_controls_locked = local_player.controls_locked

	_placement_controller.setup(_plant_system, _local_player)
	_configure_controller_session()
	_connect_controller_signals()
	_connect_plant_runtime_signals()
	_connect_modal_signals()
	refresh_interaction_state()
	return true


func is_bound() -> bool:
	return (
		_placement_controller != null
		and _plant_system != null
		and _plant_runtime_coordinator != null
		and _run_state != null
		and _local_player != null
		and _session_object_pool != null
		and _settings_panel != null
		and _profile_panel != null
		and _debug_collectible_window != null
		and _placement_particles_scene != null
		and _removal_smoke_scene != null
	)


func configure_session(
	runtime_mode: int,
	local_peer_id: int,
	sandbox_free_building_enabled: bool
) -> void:
	_runtime_mode = runtime_mode
	_local_peer_id = maxi(local_peer_id, 0)
	_sandbox_free_building_enabled = sandbox_free_building_enabled
	if not is_bound():
		return
	_configure_controller_session()
	refresh_interaction_state()


func set_local_player(local_player: Player) -> void:
	if local_player == null:
		push_error("TowerDefensePlantPlacementCoordinator: 本地玩家不能为空。")
		return
	_local_player = local_player
	_last_player_controls_locked = local_player.controls_locked
	if _placement_controller == null or _plant_system == null:
		return
	_placement_controller.setup(_plant_system, _local_player)
	refresh_interaction_state()


func set_flow_state(flow_state: CombatFlowState.State) -> void:
	_flow_state = flow_state
	refresh_interaction_state()


func refresh_interaction_state() -> void:
	if not is_bound():
		return
	var input_enabled := evaluate_placement_input_enabled(
		true,
		_local_player.is_dead,
		_flow_state,
		has_exclusive_modal_open()
	)
	_placement_controller.set_placement_input_enabled(input_enabled)
	_placement_controller.set_process_unhandled_input(input_enabled)
	if input_enabled != _placement_input_enabled:
		_placement_input_enabled = input_enabled
		placement_input_enabled_changed.emit(input_enabled)
	_refresh_player_controls_lock()


func is_placement_input_enabled() -> bool:
	return _placement_input_enabled


func cancel_placement() -> void:
	if _placement_controller != null and _placement_controller.is_active():
		_placement_controller.cancel_placement()


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> bool:
	if not is_bound():
		return false
	refresh_interaction_state()
	if (
		_local_player.is_dead
		or _flow_state in [
			CombatFlowState.State.FATE_INTERLUDE,
			CombatFlowState.State.ROGUE_EXPLORATION,
		]
		or has_exclusive_modal_open()
	):
		return false
	var inventory_peer_id := resolve_inventory_peer_id(
		_runtime_mode,
		_local_peer_id
	)
	var item: PickupConfig = (
		_run_state.get_item_for_peer(inventory_peer_id, slot_index)
		if inventory_peer_id > 0
		else _run_state.get_item(slot_index)
	)
	var current_revision := (
		_run_state.get_inventory_revision_for_peer(inventory_peer_id)
		if inventory_peer_id > 0
		else _run_state.get_inventory_revision()
	)
	if (
		item == null
		or item.pickup_type != PickupConfig.PickupType.BUILDING
		or item.placeable_plant_id == &""
		or item.resource_path.is_empty()
		or (
			expected_inventory_revision >= 0
			and expected_inventory_revision != current_revision
		)
	):
		return false
	var config := _plant_system.get_config(item.placeable_plant_id)
	if (
		config == null
		or not config.is_valid()
		or (
			_runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
			and not config.supports_multiplayer
		)
	):
		return false
	var started := _placement_controller.begin_inventory_placement(
		config,
		slot_index,
		current_revision,
		item.resource_path
	)
	if started:
		refresh_interaction_state()
	return started


func notify_plant_modal_ui_visibility_changed(is_open: bool) -> void:
	if is_open:
		cancel_placement()
	refresh_interaction_state()


func notify_exclusive_modal_opened() -> void:
	cancel_placement()
	refresh_interaction_state()


func has_exclusive_modal_open() -> bool:
	return (
		(_settings_panel != null and _settings_panel.is_open())
		or (_profile_panel != null and _profile_panel.is_open())
		or (
			_debug_collectible_window != null
			and _debug_collectible_window.is_open()
		)
		or _has_open_plant_modal_ui()
	)


func present_plant_placement(plant: PlantDefense) -> bool:
	if plant == null or not is_instance_valid(plant) or _session_object_pool == null:
		return false
	var effect_position := plant.get_lifecycle_vfx_global_position()
	if not WorldEffectVisibility.is_position_near_viewport(self, effect_position):
		return false
	var effect := _session_object_pool.try_acquire(
		_placement_particles_scene
	) as PlantPlacementParticles
	if effect == null:
		return false
	effect.global_position = effect_position
	effect.reset_physics_interpolation()
	effect.restart_effect(plant, plant.get_lifecycle_particle_scale())
	return true


func present_plant_removal(plant: PlantDefense) -> bool:
	if plant == null or not is_instance_valid(plant) or _session_object_pool == null:
		return false
	var effect_position := plant.get_lifecycle_vfx_global_position()
	if not WorldEffectVisibility.is_position_near_viewport(self, effect_position):
		return false
	var effect := _session_object_pool.try_acquire(
		_removal_smoke_scene
	) as PlantRemovalSmoke
	if effect == null:
		return false
	effect.global_position = effect_position
	effect.reset_physics_interpolation()
	effect.restart_effect(plant.get_lifecycle_particle_scale(), plant.is_dead)
	return true


static func evaluate_placement_input_enabled(
	has_local_player: bool,
	local_player_dead: bool,
	flow_state: CombatFlowState.State,
	exclusive_modal_open: bool
) -> bool:
	return (
		has_local_player
		and not local_player_dead
		and flow_state not in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
			CombatFlowState.State.FATE_INTERLUDE,
			CombatFlowState.State.ROGUE_EXPLORATION,
		]
		and not exclusive_modal_open
	)


static func resolve_inventory_peer_id(runtime_mode: int, local_peer_id: int) -> int:
	return (
		maxi(local_peer_id, 0)
		if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)


func _configure_controller_session() -> void:
	_placement_controller.set_multiplayer_request_mode(
		_runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	)
	_placement_controller.configure_inventory_catalog(
		_run_state,
		resolve_inventory_peer_id(_runtime_mode, _local_peer_id),
		_sandbox_free_building_enabled
	)


func _connect_controller_signals() -> void:
	if not _placement_controller.player_lock_requested.is_connected(
		_on_controller_player_lock_requested
	):
		_placement_controller.player_lock_requested.connect(
			_on_controller_player_lock_requested
		)
	if not _placement_controller.placement_mode_changed.is_connected(
		_on_controller_placement_mode_changed
	):
		_placement_controller.placement_mode_changed.connect(
			_on_controller_placement_mode_changed
		)
	if not _placement_controller.multiplayer_placement_requested.is_connected(
		_on_controller_multiplayer_placement_requested
	):
		_placement_controller.multiplayer_placement_requested.connect(
			_on_controller_multiplayer_placement_requested
		)
	if not _placement_controller.inventory_placement_requested.is_connected(
		_on_controller_inventory_placement_requested
	):
		_placement_controller.inventory_placement_requested.connect(
			_on_controller_inventory_placement_requested
		)


func _connect_plant_runtime_signals() -> void:
	if not _plant_runtime_coordinator.placement_presentation_requested.is_connected(
		present_plant_placement
	):
		_plant_runtime_coordinator.placement_presentation_requested.connect(
			present_plant_placement
		)
	if not _plant_runtime_coordinator.removal_presentation_requested.is_connected(
		present_plant_removal
	):
		_plant_runtime_coordinator.removal_presentation_requested.connect(
			present_plant_removal
		)
	if not _plant_runtime_coordinator.modal_ui_visibility_changed.is_connected(
		notify_plant_modal_ui_visibility_changed
	):
		_plant_runtime_coordinator.modal_ui_visibility_changed.connect(
			notify_plant_modal_ui_visibility_changed
		)


func _connect_modal_signals() -> void:
	if not _settings_panel.opened.is_connected(_on_exclusive_modal_opened):
		_settings_panel.opened.connect(_on_exclusive_modal_opened)
	if not _settings_panel.closed.is_connected(_on_exclusive_modal_closed):
		_settings_panel.closed.connect(_on_exclusive_modal_closed)
	if not _profile_panel.opened.is_connected(_on_exclusive_modal_opened):
		_profile_panel.opened.connect(_on_exclusive_modal_opened)
	if not _profile_panel.closed.is_connected(_on_exclusive_modal_closed):
		_profile_panel.closed.connect(_on_exclusive_modal_closed)
	if not _debug_collectible_window.visibility_changed.is_connected(
		_on_debug_collectible_visibility_changed
	):
		_debug_collectible_window.visibility_changed.connect(
			_on_debug_collectible_visibility_changed
		)


func _on_controller_player_lock_requested(_locked: bool) -> void:
	_refresh_player_controls_lock()


func _on_controller_placement_mode_changed(active: bool) -> void:
	if active and has_exclusive_modal_open():
		_placement_controller.cancel_placement()
		return
	_refresh_player_controls_lock()
	placement_mode_changed.emit(active)


func _on_controller_multiplayer_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	plant_placement_requested.emit(request_id, plant_id, anchor)


func _on_controller_inventory_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	inventory_plant_placement_requested.emit(
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func _on_exclusive_modal_opened() -> void:
	notify_exclusive_modal_opened()


func _on_exclusive_modal_closed() -> void:
	refresh_interaction_state()


func _on_debug_collectible_visibility_changed() -> void:
	if _debug_collectible_window.is_open():
		notify_exclusive_modal_opened()
	else:
		refresh_interaction_state()


func _refresh_player_controls_lock() -> void:
	if _local_player == null or not is_instance_valid(_local_player) or _local_player.is_dead:
		return
	var locked := (
		has_exclusive_modal_open()
		or (
			_placement_controller != null
			and _placement_controller.is_active()
		)
	)
	_local_player.set_controls_locked(locked)
	if locked != _last_player_controls_locked:
		_last_player_controls_locked = locked
		player_controls_lock_changed.emit(locked)


func _has_open_plant_modal_ui() -> bool:
	if not is_inside_tree():
		return false
	for node in get_tree().get_nodes_in_group(&"plant_defense"):
		var plant := node as PlantDefense
		if plant != null and plant.is_modal_ui_open():
			return true
	return false
