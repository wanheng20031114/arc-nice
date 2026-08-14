extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/tower_defense_plant_placement_coordinator.tscn"
)
const PLACEMENT_PARTICLES_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/presentation/plant_placement_particles.tscn"
)
const REMOVAL_SMOKE_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/presentation/plant_removal_smoke.tscn"
)
const COORDINATOR_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/plant/"
	+ "tower_defense_plant_placement_coordinator.gd"
)
const TOWER_ROOT_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const TOWER_ROOT_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const TOWER_PLANT_GAMEPLAY_BRIDGE_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/"
	+ "tower_plant_gameplay_bridge.gd"
)
const TOWER_MULTIPLAYER_ADAPTER_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/"
	+ "tower_defense_multiplayer_mode_adapter.gd"
)

var failures: Array[String] = []


class PlacementControllerProbe:
	extends PlantPlacementController

	var active := false
	var input_enabled := true
	var multiplayer_requests_enabled := false
	var configured_inventory_peer_id := -1
	var configured_free_placement := false

	func _ready() -> void:
		pass

	func setup(new_plant_system: PlantSystem, new_owner_player: Player = null) -> void:
		plant_system = new_plant_system
		owner_player = new_owner_player

	func set_multiplayer_request_mode(enabled: bool) -> void:
		multiplayer_requests_enabled = enabled

	func configure_inventory_catalog(
		new_run_state: RunStateStore,
		new_inventory_peer_id: int,
		allow_free_placement: bool
	) -> void:
		run_state = new_run_state
		configured_inventory_peer_id = new_inventory_peer_id
		configured_free_placement = allow_free_placement

	func set_placement_input_enabled(enabled: bool) -> void:
		input_enabled = enabled
		if not enabled:
			cancel_placement()

	func is_active() -> bool:
		return active

	func cancel_placement() -> void:
		if not active:
			return
		active = false
		placement_mode_changed.emit(false)
		player_lock_requested.emit(false)
		placement_cancelled.emit()


class PlayerProbe:
	extends Player

	func _ready() -> void:
		pass

	func set_controls_locked(locked: bool) -> void:
		controls_locked = locked


class SettingsPanelProbe:
	extends SettingsPanel

	var open_state := false

	func _ready() -> void:
		pass

	func is_open() -> bool:
		return open_state


class ProfilePanelProbe:
	extends TowerDefensePlayerProfilePanel

	var open_state := false

	func _ready() -> void:
		pass

	func is_open() -> bool:
		return open_state


class DebugWindowProbe:
	extends DebugCollectibleWindow

	var open_state := false

	func _ready() -> void:
		pass

	func is_open() -> bool:
		return open_state


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var coordinator := (
		COORDINATOR_SCENE.instantiate()
		as TowerDefensePlantPlacementCoordinator
	)
	_expect(coordinator != null, "PlantPlacement 必须由原生 .tscn 实例化。")
	root.add_child(coordinator)

	var coordinator_source := FileAccess.get_file_as_string(
		COORDINATOR_SCRIPT_PATH
	)
	var tower_root_source := FileAccess.get_file_as_string(TOWER_ROOT_SCRIPT_PATH)
	var tower_root_scene := FileAccess.get_file_as_string(TOWER_ROOT_SCENE_PATH)
	var tower_plant_gameplay_bridge_source := FileAccess.get_file_as_string(
		TOWER_PLANT_GAMEPLAY_BRIDGE_SCRIPT_PATH
	)
	var tower_multiplayer_adapter_source := FileAccess.get_file_as_string(
		TOWER_MULTIPLAYER_ADAPTER_SCRIPT_PATH
	)
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("has_method(")
		and not coordinator_source.contains(".call(")
		and not coordinator_source.contains("Callable("),
		"PlantPlacement 不得通过 current_scene 或动态调用猜测依赖。"
	)
	_expect(
		coordinator_source.contains("get_nodes_in_group(&\"plant_defense\")")
		and coordinator_source.contains("node as PlantDefense"),
		"植物 modal 检查必须保留类型过滤，不得按方法名猜测节点。"
	)
	_expect(
		tower_root_scene.count(
			"[node name=\"PlantPlacementCoordinator\" parent=\".\" instance="
		) == 1
		and tower_root_source.contains("plant_placement_coordinator.setup(")
		and tower_root_scene.count(
			"[node name=\"TowerPlantGameplayPort\" type=\"Node\" parent=\".\"]"
		) == 1
		and tower_plant_gameplay_bridge_source.contains(
			"mode_adapter.begin_inventory_building_placement("
		)
		and tower_multiplayer_adapter_source.contains(
			"_plant_placement_coordinator.begin_inventory_building_placement("
		),
		"塔防根场景必须静态搭建并通过强类型 gameplay port 委托 PlantPlacementCoordinator。"
	)

	var controller := PlacementControllerProbe.new()
	var plant_system := PlantSystem.new()
	var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
	var run_state := RunStateStore.new()
	var local_player := PlayerProbe.new()
	var object_pool := SessionObjectPool.new()
	var settings_panel := SettingsPanelProbe.new()
	var profile_panel := ProfilePanelProbe.new()
	var debug_window := DebugWindowProbe.new()
	var configured := coordinator.setup(
		controller,
		plant_system,
		plant_runtime,
		run_state,
		local_player,
		object_pool,
		settings_panel,
		profile_panel,
		debug_window,
		PLACEMENT_PARTICLES_SCENE,
		REMOVAL_SMOKE_SCENE,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		17,
		true,
		CombatFlowState.State.PRE_WAVE
	)
	_expect(configured and coordinator.is_bound(), "强类型 setup 必须完整绑定依赖。")
	_expect(
		plant_runtime.placement_presentation_requested.is_connected(
			coordinator.present_plant_placement
		)
		and plant_runtime.removal_presentation_requested.is_connected(
			coordinator.present_plant_removal
		)
		and plant_runtime.modal_ui_visibility_changed.is_connected(
			coordinator.notify_plant_modal_ui_visibility_changed
		),
		"PlantRuntime 的表现与 modal 信号必须在协调器内部强类型绑定。"
	)
	_expect(
		controller.multiplayer_requests_enabled
		and controller.configured_inventory_peer_id == 17
		and controller.configured_free_placement,
		"HOST 配置必须把本地 peer 与沙盒开关显式交给放置控制器。"
	)
	_expect(
		controller.input_enabled and not local_player.controls_locked,
		"无 modal 的 PRE_WAVE 必须允许输入且不锁玩家。"
	)
	coordinator.configure_session(
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		17,
		false
	)
	_expect(
		not controller.multiplayer_requests_enabled
		and controller.configured_inventory_peer_id == 0
		and not controller.configured_free_placement,
		"切回单人会话必须清除多人请求、peer 与免费放置状态。"
	)
	coordinator.configure_session(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		17,
		true
	)

	controller.active = true
	controller.placement_mode_changed.emit(true)
	_expect(local_player.controls_locked, "进入放置模式必须锁定玩家移动。")
	controller.cancel_placement()
	_expect(not local_player.controls_locked, "退出放置模式必须释放玩家移动。")

	settings_panel.open_state = true
	settings_panel.opened.emit()
	_expect(
		not controller.input_enabled and local_player.controls_locked,
		"打开强类型 modal 必须关闭放置输入并锁定玩家。"
	)
	settings_panel.open_state = false
	settings_panel.closed.emit()
	_expect(
		controller.input_enabled and not local_player.controls_locked,
		"关闭最后一个 modal 必须恢复放置输入与玩家移动。"
	)

	coordinator.set_flow_state(CombatFlowState.State.FATE_INTERLUDE)
	_expect(
		not controller.input_enabled,
		"FATE_INTERLUDE 必须关闭放置输入。"
	)
	coordinator.set_flow_state(CombatFlowState.State.ROGUE_EXPLORATION)
	_expect(
		not controller.input_enabled,
		"ROGUE_EXPLORATION 必须关闭放置输入。"
	)
	coordinator.set_flow_state(CombatFlowState.State.WAVE_ACTIVE)
	_expect(controller.input_enabled, "离开阻塞流程后必须恢复放置输入。")

	var free_request_trace: Array = []
	coordinator.plant_placement_requested.connect(
		func(request_id: int, plant_id: StringName, anchor: Vector2i) -> void:
			free_request_trace.assign([request_id, plant_id, anchor])
	)
	controller.multiplayer_placement_requested.emit(9, &"corn", Vector2i(4, 6))
	_expect(
		free_request_trace == [9, &"corn", Vector2i(4, 6)],
		"自由放置请求必须原样转发，不得在 UI 协调器中提交权威状态。"
	)
	var inventory_request_trace: Array = []
	coordinator.inventory_plant_placement_requested.connect(
		func(
			request_id: int,
			plant_id: StringName,
			anchor: Vector2i,
			slot_index: int,
			expected_revision: int,
			item_path: String
		) -> void:
			inventory_request_trace.assign([
				request_id,
				plant_id,
				anchor,
				slot_index,
				expected_revision,
				item_path,
			])
	)
	controller.inventory_placement_requested.emit(
		10,
		&"oak_warehouse",
		Vector2i(8, 3),
		2,
		31,
		"res://fixture/building.tres"
	)
	_expect(
		inventory_request_trace == [
			10,
			&"oak_warehouse",
			Vector2i(8, 3),
			2,
			31,
			"res://fixture/building.tres",
		],
		"背包放置请求必须保留 slot、revision 与资源路径。"
	)

	_expect(
		TowerDefensePlantPlacementCoordinator.resolve_inventory_peer_id(
			CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
			17
		) == 0
		and TowerDefensePlantPlacementCoordinator.resolve_inventory_peer_id(
			CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
			17
		) == 17,
		"背包读取 peer 选择必须保持单人 0、多人本地 peer 的旧语义。"
	)

	coordinator.free()
	controller.free()
	plant_system.free()
	plant_runtime.free()
	run_state.free()
	local_player.free()
	object_pool.free()
	settings_panel.free()
	profile_panel.free()
	debug_window.free()
	if failures.is_empty():
		print("TOWER_DEFENSE_PLANT_PLACEMENT_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
