extends Node2D
class_name RogueRouteGame

signal host_layout_committed(
	layout_snapshot: Dictionary,
	state_snapshot: Dictionary
)
signal host_move_committed(delta: Dictionary)
signal host_briefing_state_committed(briefing_snapshot: Dictionary)
signal briefing_cover_completed(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
)
signal host_encounter_snapshot_committed(
	encounter_snapshot: Dictionary,
	economy_snapshot: Dictionary
)
signal encounter_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
)
signal encounter_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
)
signal encounter_result_ack_requested(
	occurrence_key: String,
	result_sequence: int
)
signal host_shop_snapshot_committed(
	target_peer_id: int,
	shop_snapshot: Dictionary
)
signal shop_purchase_requested(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
)
signal shop_sell_requested(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
)
signal shop_exit_ack_requested(
	occurrence_key: String,
	expected_session_revision: int
)
signal normal_combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String
)
signal normal_combat_stage_reset(occurrence_key: String)
signal combat_result_dismissed
signal return_requested

const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"
const INVALID_NODE_ID := -1
const AUTO_SEED := 0
const ROUTE_CONTRACT_FIELD := "runtime_contract_hash"
const SINGLEPLAYER_PEER_ID := 0
const BRIEFING_STATE_FIELD := "briefing_state"
const BRIEFING_SCHEMA_VERSION := 1
const NORMAL_COMBAT_BRIEFING_ADAPTER_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_normal_combat_briefing_adapter.gd"
)
const FLOOR_DEFINITION_SCRIPT := preload(
	"res://resources/config/rogue_route/rogue_route_floor_definition.gd"
)
const AVATAR_SPAWN_OFFSETS := [
	Vector2.ZERO,
	Vector2(12.0, 0.0),
	Vector2(-12.0, 0.0),
	Vector2(0.0, 12.0),
	Vector2(0.0, -12.0),
	Vector2(12.0, 12.0),
	Vector2(-12.0, 12.0),
	Vector2(12.0, -12.0),
]

enum BriefingPhase {
	NONE,
	PRESENTED,
	ENTERING,
}

@export var floor_definition: FLOOR_DEFINITION_SCRIPT
@export var auto_initialize := true
@export var manage_return_locally := true
## 0 表示每次进入时生成新 seed；非零值便于复现指定地图。
@export var initial_generation_seed := AUTO_SEED

@onready var world: RogueRouteWorld = $World
@onready var route_board: RogueRouteBoard = $World/RouteBoard
@onready var player_container: Node2D = $World/Players
@onready var map_camera: Camera2D = $World/Camera2D
@onready var top_bar: RogueRouteTopBar = $HUD/Root/TopBar
@onready var content_overline: Label = %ContentOverline
@onready var content_title: Label = %ContentTitle
@onready var content_body: Label = %ContentBody
@onready var content_meta: Label = %ContentMeta
@onready var regenerate_button: Button = %RegenerateButton
@onready var hint_label: Label = %Hint
@onready var status_message: Label = %StatusMessage
@onready var route_hud: CanvasLayer = $HUD
@onready var route_inventory_strip: RogueRouteInventoryStrip = (
	$HUD/Root/BottomBar/RogueRouteInventoryStrip
)
@onready var player_profile_panel: RoguePlayerProfilePanel = (
	$RoguePlayerProfilePanel
)
@onready var move_confirmation: RogueRouteMoveConfirmation = $MoveConfirmation
@onready var node_briefing: RogueRouteNodeBriefing = $NodeBriefing
@onready var encounter_scene: RogueEncounterScene = $EncounterScene
@onready var encounter_economy: RogueEncounterEconomyCoordinator = (
	$EncounterEconomy
)
@onready var encounter_session: RogueEncounterSession = $EncounterSession
@onready var underground_shop_controller: RogueUndergroundShopController = (
	$UndergroundShopController
)
@onready var combat_result_overlay: RogueCombatResultOverlay = (
	$CombatResultOverlay
)
@onready var combat_victory_presentation: RogueCombatVictoryPresentation = (
	$CombatVictoryPresentation
)
@onready var combat_scene_transition: RogueSceneTransition = (
	$CombatSceneTransition
)
@onready var run_defeat_overlay: RogueRunDefeatOverlay = $RunDefeatOverlay

## 保留战斗协调器与既有测试使用的 Overlay 访问契约；实际表现已由
## 独立 RogueEncounterScene 承载，权威状态仍留在当前路线根节点。
var encounter_overlay: RogueEncounterOverlay:
	get:
		return (
			encounter_scene.presentation
			if encounter_scene != null
			else null
		)

## 兼容既有外部调用者的只读入口；楼层资源是唯一可配置来源。
var generation_config: RogueRouteGenerationConfig:
	get:
		return (
			floor_definition.generation_config
			if floor_definition != null
			else null
		)

var _route_graph: RogueRouteGraph = null
var _runtime_state: RogueRouteRuntimeState = null
var _authority_enabled := true
var _route_ready := false
var _pending_node_id := INVALID_NODE_ID
var _pending_revision := -1
var _briefing_revision := 0
var _briefing_phase := BriefingPhase.NONE
var _briefing_node_id := INVALID_NODE_ID
var _briefing_occurrence_key := ""
var _briefing_expected_route_revision := -1
var _normal_combat_briefing_adapter: RefCounted = null
var player: Player = null
var peer_players: Dictionary[int, Player] = {}
var _local_peer_id := 0
var _multiplayer_avatar_mode := false
var _camera_drag_active := false
var _encounter_input_locked := false
var _route_reveal_input_locked := false
var _runtime_activated := false
var _encounter_presented_active := false
var _encounter_presentation_serial := 0
var _local_result_hold_completed_occurrence_key := ""
var _normal_combat_active := false
var _normal_combat_node_id := INVALID_NODE_ID
var _normal_combat_content_seed := 0
var _normal_combat_visit_count := 0
var _normal_combat_occurrence_key := ""
var _route_presentation_enabled := true
var _route_presentation_restore_state: Dictionary = {}
var _shop_route_presentation_restore_state: Dictionary = {}
var _player_names: Dictionary = {}
var _player_character_ids: Dictionary = {}
var _player_stable_keys: Dictionary = {SINGLEPLAYER_PEER_ID: "singleplayer:local"}
var _run_state: RunStateStore = null
var _run_failure_presented := false
var _cached_max_health_penalties: Dictionary = {}
var _max_health_transition_by_peer: Dictionary = {}
var _previous_physics_interpolation_enabled := false
var _owns_physics_interpolation_override := false
var _floor_definition_applied := false


func _enter_tree() -> void:
	_floor_definition_applied = _apply_floor_definition_before_children_ready()
	_previous_physics_interpolation_enabled = get_tree().physics_interpolation
	get_tree().physics_interpolation = true
	_owns_physics_interpolation_override = true


func _ready() -> void:
	if not _floor_definition_applied:
		_set_status("路线楼层定义无效，无法初始化路线。", true)
		return
	_normal_combat_briefing_adapter = (
		NORMAL_COMBAT_BRIEFING_ADAPTER_SCRIPT.new(
			floor_definition.default_combat_config
		)
	)
	top_bar.set_floor_title(floor_definition.display_name)
	_connect_runtime_activation_signal()
	_create_encounter_runtime()
	route_board.show_waiting_for_host()
	if not route_board.entry_reveal_finished.is_connected(
		_on_route_entry_reveal_finished
	):
		route_board.entry_reveal_finished.connect(
			_on_route_entry_reveal_finished
		)
	if manage_return_locally:
		_configure_singleplayer_player()
	_connect_party_status_ledger()
	_create_underground_shop_runtime()
	if run_defeat_overlay != null and not run_defeat_overlay.confirmed.is_connected(
		_on_run_defeat_confirmed
	):
		run_defeat_overlay.confirmed.connect(_on_run_defeat_confirmed)
	_update_authority_ui()
	_update_route_hud()
	_show_node_content(INVALID_NODE_ID, false)
	if auto_initialize:
		call_deferred("_initialize_default_session")
	else:
		_set_status("等待外部会话初始化。", false)
	call_deferred("_activate_runtime_when_loader_is_idle")


func _exit_tree() -> void:
	if _owns_physics_interpolation_override:
		get_tree().physics_interpolation = _previous_physics_interpolation_enabled
		_owns_physics_interpolation_override = false


## 父节点先于子节点进入 SceneTree；在这里统一分发楼层依赖，确保
## Board、World 与战斗协调器各自执行 _ready() 时只看到同一份资源。
func _apply_floor_definition_before_children_ready() -> bool:
	var board := get_node_or_null("World/RouteBoard") as RogueRouteBoard
	var background := get_node_or_null(
		"World/Backdrop/RuinsBackground"
	) as Sprite2D
	var combat_coordinator := get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator
	if board == null or background == null or combat_coordinator == null:
		_report_floor_definition_error(
			"RogueRouteGame 的楼层依赖节点结构不完整。"
		)
		return false
	# 先清除子脚本默认值，失败路径也不得让协调器带着隐藏兜底启用。
	board.world_metrics = null
	background.texture = null
	combat_coordinator.encounter_config = null
	if floor_definition == null:
		_report_floor_definition_error("RogueRouteGame 缺少 floor_definition。")
		return false
	var definition_errors := floor_definition.validate_definition()
	if not definition_errors.is_empty():
		_report_floor_definition_error(
			"RogueRouteGame 的 floor_definition 无效：%s"
			% [definition_errors]
		)
		return false
	board.world_metrics = floor_definition.world_metrics
	background.texture = floor_definition.background_texture
	combat_coordinator.encounter_config = (
		floor_definition.default_combat_config
	)
	return true


func _report_floor_definition_error(message: String) -> void:
	# 离树状态允许工具先做无副作用预检；真实场景生命周期中的失败必须可见。
	if is_inside_tree():
		push_error(message)


func _process(delta: float) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.tick(maxf(delta, 0.0))


func _physics_process(_delta: float) -> void:
	if player != null and is_instance_valid(player):
		_clamp_camera_drag_offset()


func _unhandled_input(event: InputEvent) -> void:
	if _is_route_input_locked() or _pending_node_id != INVALID_NODE_ID:
		_camera_drag_active = false
		return
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			return
		_camera_drag_active = mouse_button.pressed
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and _camera_drag_active:
		var mouse_motion := event as InputEventMouseMotion
		var drag_mask := MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE
		if (mouse_motion.button_mask & drag_mask) == 0:
			_camera_drag_active = false
			return
		_apply_camera_drag(mouse_motion.relative)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if (
			key_event.pressed
			and not key_event.echo
			and key_event.keycode == KEY_HOME
		):
			_recenter_camera_on_player()
			get_viewport().set_input_as_handled()


func start_authoritative_session(
	generation_seed: int = AUTO_SEED,
	announce_full_snapshot: bool = true
) -> bool:
	if generation_config == null:
		_set_status("路线生成配置缺失。", true)
		return false
	var config_errors := generation_config.validate_config()
	if not config_errors.is_empty():
		_set_status("路线配置无效：%s" % "；".join(config_errors), true)
		return false

	var resolved_seed := generation_seed
	if resolved_seed == AUTO_SEED:
		resolved_seed = randi_range(1, 2147483646)
	var generated_graph := RogueRouteGenerator.generate(
		generation_config,
		resolved_seed
	)
	if generated_graph == null:
		_set_status("路线图生成失败。", true)
		return false
	var generated_state := RogueRouteRuntimeState.new()
	if not generated_state.initialize(
		generated_graph,
		generation_config.initial_action_points
	):
		_set_status("路线运行状态初始化失败。", true)
		return false
	_reset_briefing_runtime(true)
	_reset_normal_combat_stage(true)
	_reset_encounter_runtime(true)
	_reset_underground_shop_runtime(true)

	_set_route_reveal_input_locked(false)
	_clear_pending_move(true)
	set_authority_enabled(true)
	if not route_board.present_graph(
		generated_graph,
		generation_config,
		generated_state.current_node_id,
		generated_state.action_points,
		generated_state.visited_counts,
		true
	):
		_set_status("路线图视觉层初始化失败。", true)
		return false
	_bind_runtime_state(generated_graph, generated_state)
	_route_ready = true
	_configure_camera_world_bounds()
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)
	_set_status("路线世界已生成。可自由探索，点击青色相邻节点即可选择路线。", false)
	if announce_full_snapshot:
		host_layout_committed.emit(
			export_layout_snapshot(),
			export_state_snapshot()
		)
	_try_play_route_entry_reveal()
	return true


func start_client_waiting() -> void:
	_set_route_reveal_input_locked(false)
	_reset_briefing_runtime(true)
	_clear_pending_move(true)
	_reset_normal_combat_stage(true)
	_reset_encounter_runtime(false)
	_reset_underground_shop_runtime(false)
	_disconnect_runtime_state()
	_route_graph = null
	_runtime_state = null
	_route_ready = false
	set_authority_enabled(false)
	route_board.show_waiting_for_host()
	_update_route_hud()
	_show_node_content(INVALID_NODE_ID, false)
	_set_status("正在等待房主同步路线图…", false)


func apply_full_snapshot(
	layout_snapshot: Dictionary,
	state_snapshot: Dictionary,
	encounter_snapshot: Dictionary = {},
	economy_snapshot: Dictionary = {},
	shop_snapshot: Dictionary = {}
) -> bool:
	var briefing_value: Variant = state_snapshot.get(BRIEFING_STATE_FIELD)
	if typeof(briefing_value) != TYPE_DICTIONARY:
		_set_status("房主路线状态缺少作战简报快照。", true)
		return false
	var briefing_snapshot := (briefing_value as Dictionary).duplicate(true)
	if str(layout_snapshot.get(ROUTE_CONTRACT_FIELD, "")) != (
		_get_runtime_contract_hash()
	):
		_set_status("房主路线版本与本地运行配置不兼容。", true)
		return false
	var imported_graph := RogueRouteGraph.import_layout(layout_snapshot)
	if imported_graph == null:
		_set_status("房主路线布局快照无效。", true)
		return false
	var incoming_action_points := int(state_snapshot.get("action_points", -1))
	if incoming_action_points < 0:
		_set_status("房主路线状态快照无效。", true)
		return false
	var imported_state := RogueRouteRuntimeState.new()
	if not imported_state.initialize(imported_graph, incoming_action_points):
		_set_status("无法创建客户端路线状态。", true)
		return false
	if not imported_state.apply_remote_state(state_snapshot):
		_set_status("房主路线状态与布局不匹配。", true)
		return false
	if not _validate_briefing_state_against(
		briefing_snapshot,
		imported_graph,
		imported_state
	):
		_set_status("房主作战简报状态与路线不匹配。", true)
		return false
	if (
		not shop_snapshot.is_empty()
		and (
			underground_shop_controller == null
			or not underground_shop_controller.preflight_snapshot(
			shop_snapshot,
			imported_graph,
			imported_state
			)
		)
	):
		_set_status("房主地下商店快照无效或已过期。", true)
		return false
	var layout_changed := (
		_route_graph == null
		or _route_graph.compute_layout_hash()
		!= imported_graph.compute_layout_hash()
	)
	var route_rewound := _is_full_snapshot_rewound(
		imported_graph,
		imported_state
	)
	var encounter_rewound := false
	if encounter_session != null and not encounter_snapshot.is_empty():
		var incoming_encounter_revision := int(
			encounter_snapshot.get("revision", -1)
		)
		var current_encounter_snapshot := encounter_session.export_state()
		var current_encounter_revision := int(
			current_encounter_snapshot.get("revision", -1)
		)
		encounter_rewound = (
			incoming_encounter_revision < current_encounter_revision
			or (
				incoming_encounter_revision == current_encounter_revision
				and not str(current_encounter_snapshot.get(
					"occurrence_key",
					""
				)).is_empty()
				and str(encounter_snapshot.get("occurrence_key", ""))
				!= str(current_encounter_snapshot.get("occurrence_key", ""))
			)
		)
	var presentation_rewound := (
		layout_changed or route_rewound or encounter_rewound
	)
	if not presentation_rewound and is_route_ready():
		var incoming_briefing_revision := int(
			briefing_snapshot["revision"]
		)
		if (
			incoming_briefing_revision < _briefing_revision
			or (
				incoming_briefing_revision == _briefing_revision
				and briefing_snapshot != export_briefing_state_snapshot()
			)
		):
			_set_status("房主作战简报快照已过期或发生冲突。", true)
			return false
	if presentation_rewound:
		_reset_briefing_runtime(true)
		_reset_normal_combat_stage(true)
		_reset_encounter_runtime(false)
		_reset_underground_shop_runtime(false)

	_set_route_reveal_input_locked(false)
	if _briefing_phase == BriefingPhase.NONE:
		_clear_pending_move(true)
	elif move_confirmation.visible:
		move_confirmation.dismiss()
	set_authority_enabled(false)
	if not route_board.present_graph(
		imported_graph,
		generation_config,
		imported_state.current_node_id,
		imported_state.action_points,
		imported_state.visited_counts,
		false,
		layout_changed or route_rewound or encounter_rewound
	):
		_set_status("客户端路线视觉层初始化失败。", true)
		return false
	_bind_runtime_state(imported_graph, imported_state)
	_route_ready = true
	if not apply_briefing_state_snapshot(briefing_snapshot):
		_set_status("房主作战简报状态与路线不匹配。", true)
		return false
	if _briefing_phase != BriefingPhase.NONE:
		route_board.select_node(_briefing_node_id)
	_refresh_route_input_lock()
	if (
		not encounter_snapshot.is_empty()
		and not apply_encounter_snapshot(
			encounter_snapshot,
			economy_snapshot
		)
	):
		_set_status("房主遭遇或经济快照无效。", true)
		return false
	if not shop_snapshot.is_empty() and not apply_shop_snapshot(shop_snapshot):
		_set_status("房主地下商店快照无效或已过期。", true)
		return false
	_configure_camera_world_bounds()
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)
	_set_status("已同步房主路线。当前为只读模式。", false)
	_try_play_route_entry_reveal()
	return true


func _is_full_snapshot_rewound(
	imported_graph: RogueRouteGraph,
	imported_state: RogueRouteRuntimeState
) -> bool:
	if (
		_route_graph == null
		or _runtime_state == null
		or imported_graph == null
		or imported_state == null
		or _route_graph.compute_layout_hash()
		!= imported_graph.compute_layout_hash()
	):
		return false
	if imported_state.state_revision < _runtime_state.state_revision:
		return true
	return (
		imported_state.state_revision == _runtime_state.state_revision
		and imported_state.export_state() != _runtime_state.export_state()
	)


func apply_move_delta(delta: Dictionary) -> bool:
	if (
		_authority_enabled
		or not is_route_ready()
		or not _runtime_state.apply_remote_move_delta(delta)
	):
		return false
	_set_status(
		"房主已将队伍移动至%s。"
		% _get_node_display_name(_runtime_state.current_node_id),
		false
	)
	return true


func export_layout_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	var snapshot := _route_graph.export_layout().duplicate(true)
	snapshot[ROUTE_CONTRACT_FIELD] = _get_runtime_contract_hash()
	return snapshot


func export_state_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	var snapshot := _runtime_state.export_state().duplicate(true)
	snapshot[BRIEFING_STATE_FIELD] = export_briefing_state_snapshot()
	return snapshot


func export_briefing_state_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	return {
		"schema_version": BRIEFING_SCHEMA_VERSION,
		"layout_hash": _route_graph.compute_layout_hash(),
		"revision": _briefing_revision,
		"phase": _briefing_phase,
		"node_id": _briefing_node_id,
		"occurrence_key": _briefing_occurrence_key,
		"expected_route_revision": _briefing_expected_route_revision,
	}


## 客户端只接受可由本地路线完整复算的权威简报状态。旧 revision 会被忽略，
## 同 revision 的不同内容会被拒绝，避免过期包重新打开或重复提交简报。
func apply_briefing_state_snapshot(snapshot: Dictionary) -> bool:
	if (
		_authority_enabled
		or not is_route_ready()
		or not _validate_briefing_state_against(
			snapshot,
			_route_graph,
			_runtime_state
		)
	):
		return false
	var incoming_revision := int(snapshot["revision"])
	if incoming_revision < _briefing_revision:
		return true
	if incoming_revision == _briefing_revision:
		return snapshot == export_briefing_state_snapshot()
	var previous_phase := _briefing_phase
	_assign_briefing_state(snapshot)
	_sync_briefing_presentation(previous_phase)
	return true


## 战场已经在遮盖下完成本地准备后，由协调器调用。入口遮盖不存在时返回
## true，以兼容直接构造战斗阶段的底层 smoke；正式简报路径一定会执行 reveal。
func reveal_normal_combat_entry(occurrence_key: String) -> bool:
	if (
		occurrence_key.is_empty()
		or not _normal_combat_active
		or occurrence_key != _normal_combat_occurrence_key
	):
		return false
	if not combat_scene_transition.visible:
		return true
	var revealed := await combat_scene_transition.reveal()
	return (
		revealed
		and _normal_combat_active
		and occurrence_key == _normal_combat_occurrence_key
	)


## Host 在全员战场准备屏障到齐时结束权威 ENTERING 状态；各端正在进行的
## reveal 不受 NONE 快照影响，仍由本地协调器独立等待完成。
func complete_briefing_entry(occurrence_key: String) -> bool:
	if (
		not _authority_enabled
		or _briefing_phase != BriefingPhase.ENTERING
		or occurrence_key.is_empty()
		or occurrence_key != _briefing_occurrence_key
	):
		return false
	return _commit_host_briefing_state(
		BriefingPhase.NONE,
		INVALID_NODE_ID,
		"",
		-1
	)


## 单机由本地 cover 完成后直接调用；联机仅由 MpRogueRoute 的全员
## cover-ready 屏障调用。tuple 与当前权威状态必须完全一致，且 route revision
## 仍停留在确认前，因而重复 ready 不可能再次扣除行动力。
func host_commit_briefed_move(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> bool:
	if (
		not _authority_enabled
		or not is_route_ready()
		or _briefing_phase != BriefingPhase.ENTERING
		or _briefing_node_id < 0
		or _briefing_node_id >= _runtime_state.visited_counts.size()
		or occurrence_key.is_empty()
		or occurrence_key != _briefing_occurrence_key
		or briefing_revision != _briefing_revision
		or expected_route_revision != _briefing_expected_route_revision
		or _runtime_state.state_revision != expected_route_revision
	):
		return false
	# 普通作战仅在首次踏入时允许提交。即便出现被篡改或过时的简报包，
	# 已访问节点也不能再因该包扣行动力、转场或重开战斗。
	if int(_runtime_state.visited_counts[_briefing_node_id]) != 0:
		call_deferred(
			&"_recover_failed_briefing_entry",
			"该普通作战节点已完成探索。"
		)
		return false
	var rejection_reason := _runtime_state.get_move_rejection_reason(
		_briefing_node_id,
		generation_config.move_action_cost,
		expected_route_revision
	)
	if not rejection_reason.is_empty():
		call_deferred(
			&"_recover_failed_briefing_entry",
			rejection_reason
		)
		return false
	if not _begin_shop_departure_for_route_move():
		call_deferred(
			&"_recover_failed_briefing_entry",
			"仍有玩家停留在地下商店。"
		)
		return false
	if not _runtime_state.try_move(
		_briefing_node_id,
		generation_config.move_action_cost,
		expected_route_revision
	):
		_cancel_shop_departure_for_failed_move()
		call_deferred(
			&"_recover_failed_briefing_entry",
			"路线状态已变化，本次作战未启动。"
		)
		return false
	return true


func abort_briefing_entry(occurrence_key: String) -> void:
	if (
		_briefing_phase == BriefingPhase.ENTERING
		and not occurrence_key.is_empty()
		and occurrence_key == _briefing_occurrence_key
	):
		if _authority_enabled:
			_commit_host_briefing_state(
				BriefingPhase.NONE,
				INVALID_NODE_ID,
				"",
				-1
			)
		else:
			_reset_briefing_runtime(false)
	combat_scene_transition.hide_immediately()


func hide_combat_entry_transition() -> void:
	combat_scene_transition.hide_immediately()


func export_encounter_snapshot() -> Dictionary:
	if encounter_session == null:
		return {}
	var snapshot := encounter_session.export_state().duplicate(true)
	# 线路协议会把经济账本作为独立字段发送。保留 Session 内部完整快照，
	# 但在线路视图中只留下空占位，避免每次倒计时广播重复携带仓库与背包。
	snapshot["economy_snapshot"] = {}
	return snapshot


func export_encounter_economy_snapshot() -> Dictionary:
	if encounter_economy == null:
		return {}
	if encounter_session != null:
		var session_snapshot := encounter_session.export_state()
		var embedded := session_snapshot.get("economy_snapshot", {}) as Dictionary
		if not embedded.is_empty():
			return embedded.duplicate(true)
	return encounter_economy.export_snapshot(
		_get_active_encounter_peer_ids()
	).duplicate(true)


func apply_encounter_snapshot(
	encounter_snapshot: Dictionary,
	economy_snapshot: Dictionary
) -> bool:
	if encounter_session == null or encounter_snapshot.is_empty():
		return false
	var atomic_snapshot := encounter_snapshot.duplicate(true)
	var embedded := atomic_snapshot.get("economy_snapshot", {}) as Dictionary
	if (
		not embedded.is_empty()
		and not economy_snapshot.is_empty()
		and embedded != economy_snapshot
	):
		return false
	if embedded.is_empty():
		if economy_snapshot.is_empty():
			return false
		atomic_snapshot["economy_snapshot"] = economy_snapshot.duplicate(true)
	# Session 会先让 Economy 校验并提交账本，成功后才写入自身阶段字段；
	# 任一经济字段无效时，遭遇 revision/phase 也保持原值。
	return encounter_session.apply_remote_state(atomic_snapshot)


func export_shop_snapshot_for_peer(
	target_peer_id: int,
	transaction_result: Dictionary = {}
) -> Dictionary:
	if underground_shop_controller == null:
		return {}
	return underground_shop_controller.export_snapshot_for_peer(
		target_peer_id,
		transaction_result
	)


func apply_shop_snapshot(snapshot: Dictionary) -> bool:
	if (
		underground_shop_controller == null
		or _route_graph == null
		or _runtime_state == null
	):
		return false
	return underground_shop_controller.apply_snapshot(
		snapshot,
		_route_graph,
		_runtime_state
	)


func host_submit_shop_purchase(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	if not _authority_enabled or underground_shop_controller == null:
		return false
	return underground_shop_controller.host_submit_purchase(
		peer_id,
		request_id,
		occurrence_key,
		offer_index,
		expected_session_revision,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func host_submit_shop_sell(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	if not _authority_enabled or underground_shop_controller == null:
		return false
	return underground_shop_controller.host_submit_sell(
		peer_id,
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_session_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func host_submit_shop_exit(
	peer_id: int,
	occurrence_key: String,
	expected_session_revision: int
) -> bool:
	if not _authority_enabled or underground_shop_controller == null:
		return false
	return underground_shop_controller.host_submit_exit(
		peer_id,
		occurrence_key,
		expected_session_revision
	)


func host_remove_shop_peer(peer_id: int) -> void:
	if _authority_enabled and underground_shop_controller != null:
		underground_shop_controller.remove_peer(peer_id)


func host_migrate_shop_peer_as_exited(old_peer_id: int, new_peer_id: int) -> void:
	if _authority_enabled and underground_shop_controller != null:
		underground_shop_controller.migrate_peer_as_exited(
			old_peer_id,
			new_peer_id
		)


func host_add_shop_spectator(peer_id: int) -> void:
	if _authority_enabled and underground_shop_controller != null:
		underground_shop_controller.add_spectator(peer_id)


func get_shop_waiting_peer_ids() -> Array[int]:
	if underground_shop_controller == null:
		return []
	return underground_shop_controller.get_waiting_peer_ids()


func is_shop_departure_ready() -> bool:
	return (
		underground_shop_controller != null
		and underground_shop_controller.is_departure_ready()
	)


func is_encounter_active() -> bool:
	return (
		_normal_combat_active
		or
		_encounter_input_locked
		or _is_local_shop_presentation_active()
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
	)


func is_normal_combat_active() -> bool:
	return _normal_combat_active


func get_normal_combat_occurrence_key() -> String:
	return _normal_combat_occurrence_key


## 客户端只接受能由当前权威路线状态完整复算出的作战启动数据。
## 相同启动包可安全重放；不同 occurrence 不会覆盖正在进行的作战。
func apply_normal_combat_started(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> bool:
	if _authority_enabled or not _validate_normal_combat_start(
		node_id,
		content_seed,
		occurrence_key
	):
		return false
	if _normal_combat_active:
		return (
			node_id == _normal_combat_node_id
			and content_seed == _normal_combat_content_seed
			and occurrence_key == _normal_combat_occurrence_key
		)
	if (
		_encounter_input_locked
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
	):
		return false
	_begin_normal_combat_stage(node_id, content_seed, occurrence_key)
	_set_status("房主已发起普通作战，正在进入战斗区域。", false)
	return true


func complete_normal_combat(occurrence_key: String) -> bool:
	if (
		not _normal_combat_active
		or occurrence_key.is_empty()
		or occurrence_key != _normal_combat_occurrence_key
	):
		return false
	_clear_normal_combat_state()
	_set_encounter_input_locked(
		encounter_session != null and encounter_session.is_active()
	)
	_set_status("普通作战阶段已结束。", false)
	return true


func set_route_presentation_enabled(enabled: bool) -> void:
	if not is_node_ready() or enabled == _route_presentation_enabled:
		return
	_route_presentation_enabled = enabled
	if not enabled:
		_route_presentation_restore_state = {
			"world_visible": world.visible,
			"hud_visible": ($HUD as CanvasLayer).visible,
			"move_confirmation_visible": move_confirmation.visible,
			"encounter_overlay_visible": encounter_overlay.visible,
			"camera_enabled": map_camera.enabled,
		}
		world.visible = false
		($HUD as CanvasLayer).visible = false
		move_confirmation.visible = false
		encounter_overlay.visible = false
		map_camera.enabled = false
		_camera_drag_active = false
		return
	world.visible = bool(
		_route_presentation_restore_state.get("world_visible", true)
	)
	($HUD as CanvasLayer).visible = bool(
		_route_presentation_restore_state.get("hud_visible", true)
	)
	move_confirmation.visible = bool(
		_route_presentation_restore_state.get(
			"move_confirmation_visible",
			false
		)
	)
	encounter_overlay.visible = bool(
		_route_presentation_restore_state.get(
			"encounter_overlay_visible",
			false
		)
	)
	map_camera.enabled = bool(
		_route_presentation_restore_state.get("camera_enabled", true)
	)
	_route_presentation_restore_state.clear()


func show_combat_result(result: Dictionary) -> bool:
	if combat_result_overlay == null or typeof(result.get("victory")) != TYPE_BOOL:
		return false
	var victory := bool(result["victory"])
	if not victory:
		var failure_reason_value: Variant = result.get("failure_reason", "")
		if typeof(failure_reason_value) not in [TYPE_STRING, TYPE_STRING_NAME]:
			return false
		combat_result_overlay.show_failure(str(failure_reason_value))
		return true
	if typeof(result.get("extra_xirang")) != TYPE_INT:
		return false
	var extra_xirang := int(result["extra_xirang"])
	if extra_xirang < 0 or typeof(result.get("loot")) != TYPE_DICTIONARY:
		return false
	var loot := result["loot"] as Dictionary
	if typeof(loot.get("config_path")) != TYPE_STRING:
		return false
	var config_path := str(loot["config_path"])
	var loot_config: PickupConfig = null
	if not config_path.is_empty():
		if not ResourceLoader.exists(config_path, "PickupConfig"):
			return false
		loot_config = load(config_path) as PickupConfig
		if loot_config == null:
			return false
	var inventory_full := (
		StringName(loot.get("failure_reason", &"")) == &"inventory_full"
	)
	combat_result_overlay.show_victory(
		extra_xirang,
		loot_config.display_name if loot_config != null else "",
		loot_config.icon_texture if loot_config != null else null,
		inventory_full
	)
	return true


func hide_combat_result() -> void:
	if combat_result_overlay != null:
		combat_result_overlay.hide_immediately()


func get_route_revision() -> int:
	return _runtime_state.state_revision if is_route_ready() else -1


func get_runtime_contract_hash() -> String:
	return _get_runtime_contract_hash()


func is_route_ready() -> bool:
	return (
		_route_ready
		and _route_graph != null
		and _runtime_state != null
		and _runtime_state.is_initialized()
	)


func set_authority_enabled(enabled: bool) -> void:
	_authority_enabled = enabled
	if not is_node_ready():
		return
	if not _authority_enabled:
		_clear_pending_move(true)
	route_board.set_authority_enabled(_authority_enabled)
	_sync_underground_shop_identity_context()
	_update_authority_ui()


## 与 GameLoadCoordinator 的通用场景准备契约保持一致。
func is_runtime_preparation_complete() -> bool:
	return is_route_ready()


func get_runtime_preparation_progress() -> Dictionary:
	return {
		"completed": 1 if is_route_ready() else 0,
		"total": 1,
		"stage": (
			"路线图已就绪"
			if is_route_ready()
			else "正在生成 P3 路线图…"
		),
	}


func activate_runtime() -> void:
	_runtime_activated = true
	_try_play_route_entry_reveal()


func _connect_runtime_activation_signal() -> void:
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	var finished_callable := Callable(self, "_on_loading_finished")
	if (
		loader != null
		and loader.has_signal("loading_finished")
		and not loader.is_connected(&"loading_finished", finished_callable)
	):
		loader.connect(&"loading_finished", finished_callable)


func _activate_runtime_when_loader_is_idle() -> void:
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	if loader == null or not bool(loader.call("is_loading")):
		activate_runtime()


func _on_loading_finished(_multiplayer_load: bool) -> void:
	activate_runtime()


func _try_play_route_entry_reveal() -> void:
	if not _runtime_activated or not is_route_ready() or not is_node_ready():
		return
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	if loader != null and bool(loader.call("is_loading")):
		return
	if is_encounter_active():
		route_board.complete_entry_reveal()
		_set_route_reveal_input_locked(false)
		return
	if not route_board.is_entry_reveal_prepared():
		return
	_set_route_reveal_input_locked(true)
	route_board.play_entry_reveal()


func _on_route_entry_reveal_finished() -> void:
	_set_route_reveal_input_locked(false)


func host_submit_encounter_intro_ack(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int
) -> bool:
	return (
		_authority_enabled
		and encounter_session != null
		and encounter_session.submit_intro_ack(
			peer_id,
			occurrence_key,
			expected_revision
		)
	)


func host_submit_encounter_vote(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> bool:
	return (
		_authority_enabled
		and encounter_session != null
		and encounter_session.submit_vote(
			peer_id,
			occurrence_key,
			expected_revision,
			option_id
		)
	)


func host_submit_encounter_result_ack(
	peer_id: int,
	occurrence_key: String,
	result_sequence: int
) -> bool:
	return (
		_authority_enabled
		and encounter_session != null
		and encounter_session.submit_result_ack(
			peer_id,
			occurrence_key,
			result_sequence
		)
	)


func host_remove_encounter_peer(peer_id: int) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.remove_peer(peer_id)


func host_migrate_encounter_peer(old_peer_id: int, new_peer_id: int) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.migrate_peer(old_peer_id, new_peer_id)


func host_add_encounter_spectator(peer_id: int) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.add_spectator(peer_id)


func _initialize_default_session() -> void:
	if auto_initialize and not is_route_ready():
		start_authoritative_session(initial_generation_seed)


func _create_underground_shop_runtime() -> void:
	if (
		underground_shop_controller == null
		or floor_definition == null
		or floor_definition.underground_shop_config == null
		or _run_state == null
		or not underground_shop_controller.configure(
			floor_definition.underground_shop_config,
			_run_state
		)
	):
		push_error("RogueRouteGame: 地下商店控制器配置失败。")
		return
	_sync_underground_shop_identity_context()


func _sync_underground_shop_identity_context() -> void:
	if underground_shop_controller == null:
		return
	underground_shop_controller.set_identity_context(
		_authority_enabled,
		_get_local_encounter_peer_id(),
		_player_names,
		_player_character_ids,
		_player_stable_keys
	)


func _reset_underground_shop_runtime(authority: bool) -> void:
	if underground_shop_controller == null:
		return
	if not underground_shop_controller.reset_runtime(
		authority,
		_get_local_encounter_peer_id(),
		_player_names,
		_player_character_ids,
		_player_stable_keys
	):
		push_error("RogueRouteGame: 地下商店控制器重置失败。")


func _try_start_underground_shop_for_node(
	node_id: int,
	visit_count: int
) -> bool:
	if (
		not _authority_enabled
		or not is_route_ready()
		or visit_count != 1
		or not _route_graph.is_valid_node_id(node_id)
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.UNDERGROUND_SHOP
		or underground_shop_controller == null
	):
		return false
	return underground_shop_controller.start_authoritative_for_node(
		_route_graph.compute_layout_hash(),
		node_id,
		_route_graph.get_node_content_seed(node_id),
		visit_count,
		_runtime_state.state_revision,
		_get_active_encounter_peer_ids()
	)


func _on_shop_controller_host_snapshot_committed(
	target_peer_id: int,
	snapshot: Dictionary
) -> void:
	host_shop_snapshot_committed.emit(target_peer_id, snapshot.duplicate(true))


func _on_shop_controller_purchase_requested(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	shop_purchase_requested.emit(
		request_id,
		occurrence_key,
		offer_index,
		expected_session_revision,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func _on_shop_controller_sell_requested(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	shop_sell_requested.emit(
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_session_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func _on_shop_controller_exit_ack_requested(
	occurrence_key: String,
	expected_session_revision: int
) -> void:
	shop_exit_ack_requested.emit(occurrence_key, expected_session_revision)


func _on_shop_controller_presentation_state_changed() -> void:
	_refresh_route_input_lock()






func _set_shop_route_presentation_active(active: bool) -> void:
	if not is_node_ready():
		return
	var bottom_bar := $HUD/Root/BottomBar as Control
	if not active:
		if _shop_route_presentation_restore_state.is_empty():
			_shop_route_presentation_restore_state = {
				"world_visible": world.visible,
				"world_process_mode": world.process_mode,
				"bottom_bar_visible": bottom_bar.visible,
				"camera_enabled": map_camera.enabled,
			}
		if move_confirmation.visible:
			move_confirmation.dismiss()
		world.hide()
		world.process_mode = Node.PROCESS_MODE_DISABLED
		bottom_bar.hide()
		map_camera.enabled = false
		_camera_drag_active = false
		return
	if _shop_route_presentation_restore_state.is_empty():
		return
	world.visible = bool(
		_shop_route_presentation_restore_state.get("world_visible", true)
	)
	world.process_mode = int(
		_shop_route_presentation_restore_state.get(
			"world_process_mode",
			Node.PROCESS_MODE_INHERIT
		)
	)
	bottom_bar.visible = bool(
		_shop_route_presentation_restore_state.get(
			"bottom_bar_visible",
			true
		)
	)
	map_camera.enabled = bool(
		_shop_route_presentation_restore_state.get("camera_enabled", true)
	)
	_shop_route_presentation_restore_state.clear()
	world.reset_physics_interpolation()


func _is_local_shop_presentation_active() -> bool:
	return (
		underground_shop_controller != null
		and underground_shop_controller.is_presentation_active()
	)


func _get_shop_waiting_player_names() -> PackedStringArray:
	if underground_shop_controller == null:
		return PackedStringArray()
	return underground_shop_controller.get_waiting_player_names()




func _create_encounter_runtime() -> void:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	encounter_economy.reset_runtime(run_state, _player_character_ids)
	encounter_session.reset_remote(encounter_economy)
	if not encounter_session.state_changed.is_connected(
		_on_encounter_state_changed
	):
		encounter_session.state_changed.connect(_on_encounter_state_changed)
	if not encounter_session.economy_changed.is_connected(
		_on_encounter_economy_changed
	):
		encounter_session.economy_changed.connect(
			_on_encounter_economy_changed
		)
	if encounter_scene != null:
		if not encounter_scene.intro_ack_requested.is_connected(
			_on_encounter_intro_ack_requested
		):
			encounter_scene.intro_ack_requested.connect(
				_on_encounter_intro_ack_requested
			)
		if not encounter_scene.vote_requested.is_connected(
			_on_encounter_vote_requested
		):
			encounter_scene.vote_requested.connect(
				_on_encounter_vote_requested
			)
		if not encounter_scene.encounter_revealed.is_connected(
			_on_encounter_revealed
		):
			encounter_scene.encounter_revealed.connect(
				_on_encounter_revealed
			)
		if not encounter_scene.result_hold_completed.is_connected(
			_on_encounter_result_hold_completed
		):
			encounter_scene.result_hold_completed.connect(
				_on_encounter_result_hold_completed
			)
		if not encounter_overlay.result_ack_requested.is_connected(
			_on_encounter_result_ack_requested
		):
			encounter_overlay.result_ack_requested.connect(
				_on_encounter_result_ack_requested
			)
	_configure_encounter_overlay_context()


func _reset_encounter_runtime(authority: bool) -> void:
	_encounter_presentation_serial += 1
	_encounter_presented_active = false
	_local_result_hold_completed_occurrence_key = ""
	if encounter_scene != null:
		encounter_scene.hide_immediately()
	_set_route_presentation_active(true)
	_set_encounter_input_locked(false)
	_create_encounter_runtime()
	if authority:
		encounter_session.reset_authority(
			encounter_economy,
			_get_active_encounter_peer_ids()
		)


func _reset_normal_combat_stage(restore_presentation: bool) -> void:
	var interrupted_occurrence_key := _normal_combat_occurrence_key
	if _briefing_phase != BriefingPhase.NONE:
		if _authority_enabled and is_route_ready():
			_commit_host_briefing_state(
				BriefingPhase.NONE,
				INVALID_NODE_ID,
				"",
				-1
			)
		else:
			_reset_briefing_runtime(false)
	_clear_normal_combat_state()
	if not is_node_ready():
		return
	combat_victory_presentation.interrupt_and_reset()
	combat_scene_transition.hide_immediately()
	hide_combat_result()
	if restore_presentation:
		set_route_presentation_enabled(true)
	_set_encounter_input_locked(
		encounter_session != null and encounter_session.is_active()
	)
	normal_combat_stage_reset.emit(interrupted_occurrence_key)


func _clear_normal_combat_state() -> void:
	_normal_combat_active = false
	_normal_combat_node_id = INVALID_NODE_ID
	_normal_combat_content_seed = 0
	_normal_combat_visit_count = 0
	_normal_combat_occurrence_key = ""


func _begin_normal_combat_stage(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> void:
	_normal_combat_active = true
	_normal_combat_node_id = node_id
	_normal_combat_content_seed = content_seed
	_normal_combat_visit_count = int(_runtime_state.visited_counts[node_id])
	_normal_combat_occurrence_key = occurrence_key
	_set_encounter_input_locked(true)


func _validate_normal_combat_start(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> bool:
	if (
		not is_route_ready()
		or occurrence_key.is_empty()
		or not _route_graph.is_valid_node_id(node_id)
		or _runtime_state.current_node_id != node_id
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.NORMAL_COMBAT
		or _route_graph.get_node_content_seed(node_id) != content_seed
		or node_id >= _runtime_state.visited_counts.size()
	):
		return false
	var visit_count := int(_runtime_state.visited_counts[node_id])
	return (
		visit_count == 1
		and occurrence_key == _make_normal_combat_occurrence_key(
			node_id,
			content_seed,
			visit_count
		)
	)


func _make_normal_combat_occurrence_key(
	node_id: int,
	content_seed: int,
	visit_count: int
) -> String:
	if (
		_route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or visit_count != 1
	):
		return ""
	return "combat:%s:%d:%d:%d" % [
		_route_graph.compute_layout_hash(),
		node_id,
		content_seed,
		visit_count,
	]


func _commit_host_briefing_state(
	phase: int,
	node_id: int,
	occurrence_key: String,
	expected_route_revision: int
) -> bool:
	if not _authority_enabled or not is_route_ready():
		return false
	var snapshot := {
		"schema_version": BRIEFING_SCHEMA_VERSION,
		"layout_hash": _route_graph.compute_layout_hash(),
		"revision": _briefing_revision + 1,
		"phase": phase,
		"node_id": node_id,
		"occurrence_key": occurrence_key,
		"expected_route_revision": expected_route_revision,
	}
	if not _validate_briefing_state_against(
		snapshot,
		_route_graph,
		_runtime_state
	):
		return false
	var previous_phase := _briefing_phase
	_assign_briefing_state(snapshot)
	_sync_briefing_presentation(previous_phase)
	host_briefing_state_committed.emit(snapshot.duplicate(true))
	return true


func _assign_briefing_state(snapshot: Dictionary) -> void:
	_briefing_revision = int(snapshot["revision"])
	_briefing_phase = int(snapshot["phase"])
	_briefing_node_id = int(snapshot["node_id"])
	_briefing_occurrence_key = str(snapshot["occurrence_key"])
	_briefing_expected_route_revision = int(
		snapshot["expected_route_revision"]
	)


func _validate_briefing_state_against(
	snapshot: Dictionary,
	graph: RogueRouteGraph,
	state: RogueRouteRuntimeState
) -> bool:
	if (
		graph == null
		or state == null
		or generation_config == null
		or typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != BRIEFING_SCHEMA_VERSION
		or typeof(snapshot.get("layout_hash")) != TYPE_STRING
		or str(snapshot["layout_hash"]) != graph.compute_layout_hash()
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
		or typeof(snapshot.get("phase")) != TYPE_INT
		or typeof(snapshot.get("node_id")) != TYPE_INT
		or typeof(snapshot.get("occurrence_key")) != TYPE_STRING
		or typeof(snapshot.get("expected_route_revision")) != TYPE_INT
	):
		return false
	var phase := int(snapshot["phase"])
	var node_id := int(snapshot["node_id"])
	var occurrence_key := str(snapshot["occurrence_key"])
	var expected_route_revision := int(
		snapshot["expected_route_revision"]
	)
	if phase == BriefingPhase.NONE:
		return (
			node_id == INVALID_NODE_ID
			and occurrence_key.is_empty()
			and expected_route_revision == -1
		)
	if phase not in [BriefingPhase.PRESENTED, BriefingPhase.ENTERING]:
		return false
	if (
		node_id < 0
		or not graph.is_valid_node_id(node_id)
		or node_id >= state.visited_counts.size()
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.NORMAL_COMBAT
		or occurrence_key.is_empty()
		or expected_route_revision < 0
	):
		return false

	var visit_count := 0
	if state.state_revision == expected_route_revision:
		if (
			not graph.has_edge(state.current_node_id, node_id)
			or int(state.visited_counts[node_id]) != 0
			or not state.get_move_rejection_reason(
				node_id,
				generation_config.move_action_cost,
				expected_route_revision
			).is_empty()
		):
			return false
		visit_count = 1
		if (
			_normal_combat_briefing_adapter == null
			or _build_normal_combat_briefing_model(
				node_id,
				state.action_points
			) == null
		):
			return false
	elif (
		phase == BriefingPhase.ENTERING
		and state.state_revision == expected_route_revision + 1
		and state.current_node_id == node_id
		and int(state.visited_counts[node_id]) == 1
	):
		visit_count = 1
	else:
		return false
	var expected_occurrence_key := "combat:%s:%d:%d:%d" % [
		graph.compute_layout_hash(),
		node_id,
		graph.get_node_content_seed(node_id),
		visit_count,
	]
	return occurrence_key == expected_occurrence_key


func _build_normal_combat_briefing_model(
	node_id: int,
	current_action_points: int
) -> RogueRouteNodeBriefingModel:
	if (
		_normal_combat_briefing_adapter == null
		or generation_config == null
		or node_id < 0
	):
		return null
	var node_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.NORMAL_COMBAT
	)
	return _normal_combat_briefing_adapter.call(
		&"build_model",
		node_config,
		current_action_points,
		generation_config.move_action_cost
	) as RogueRouteNodeBriefingModel


func _sync_briefing_presentation(previous_phase: int) -> void:
	if not is_node_ready():
		return
	if _briefing_phase == BriefingPhase.NONE:
		node_briefing.dismiss()
		if (
			previous_phase == BriefingPhase.ENTERING
			and not _normal_combat_active
		):
			combat_scene_transition.hide_immediately()
		_pending_node_id = INVALID_NODE_ID
		_pending_revision = -1
		route_board.clear_selection()
		_refresh_route_input_lock()
		return
	_pending_node_id = _briefing_node_id
	_pending_revision = _briefing_expected_route_revision
	route_board.select_node(_briefing_node_id)
	route_board.set_interaction_locked(true)
	_set_local_player_controls_locked(true)
	_camera_drag_active = false
	if _briefing_phase == BriefingPhase.PRESENTED:
		var model := _build_normal_combat_briefing_model(
			_briefing_node_id,
			_runtime_state.action_points
		)
		if model == null:
			push_error("普通作战简报模型构建失败。")
			return
		node_briefing.present(model, _authority_enabled)
		return
	node_briefing.dismiss()
	if not combat_scene_transition.visible:
		call_deferred(
			&"_cover_then_submit_briefed_move",
			_briefing_revision,
			_briefing_occurrence_key
		)


func _cover_then_submit_briefed_move(
	briefing_revision: int,
	occurrence_key: String
) -> void:
	if (
		_briefing_phase != BriefingPhase.ENTERING
		or briefing_revision != _briefing_revision
		or occurrence_key != _briefing_occurrence_key
	):
		return
	var covered := await combat_scene_transition.cover()
	if (
		not covered
		or _briefing_phase != BriefingPhase.ENTERING
		or briefing_revision != _briefing_revision
		or occurrence_key != _briefing_occurrence_key
	):
		return
	briefing_cover_completed.emit(
		occurrence_key,
		briefing_revision,
		_briefing_expected_route_revision
	)
	if _authority_enabled and manage_return_locally:
		host_commit_briefed_move(
			occurrence_key,
			briefing_revision,
			_briefing_expected_route_revision
		)


func _recover_failed_briefing_entry(message: String) -> void:
	if _briefing_phase != BriefingPhase.ENTERING:
		return
	if not _commit_host_briefing_state(
		BriefingPhase.NONE,
		INVALID_NODE_ID,
		"",
		-1
	):
		return
	_set_status(message, true)
	var revealed := await combat_scene_transition.reveal()
	if not revealed:
		combat_scene_transition.hide_immediately()


func _reset_briefing_runtime(interrupt_transition: bool) -> void:
	_briefing_revision = 0
	_briefing_phase = BriefingPhase.NONE
	_briefing_node_id = INVALID_NODE_ID
	_briefing_occurrence_key = ""
	_briefing_expected_route_revision = -1
	if not is_node_ready():
		return
	node_briefing.dismiss()
	if interrupt_transition:
		combat_scene_transition.hide_immediately()
	route_board.clear_selection()
	_refresh_route_input_lock()


func _configure_encounter_overlay_context() -> void:
	if encounter_scene == null:
		return
	var local_peer_id := _get_local_encounter_peer_id()
	var names := _player_names.duplicate(true)
	var character_ids := _player_character_ids.duplicate(true)
	if names.is_empty():
		names[local_peer_id] = "玩家"
	if character_ids.is_empty() and player != null:
		character_ids[local_peer_id] = player.get_character_id()
	encounter_scene.configure_local_context(
		local_peer_id,
		names,
		character_ids
	)


func _get_local_encounter_peer_id() -> int:
	return _local_peer_id if _local_peer_id > 0 else SINGLEPLAYER_PEER_ID


func _get_active_encounter_peer_ids() -> Array[int]:
	var result: Array[int] = []
	for peer_id_variant in peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			result.append(peer_id)
	if result.is_empty():
		result.append(_get_local_encounter_peer_id())
	result.sort()
	return result


func _try_start_encounter_for_node(node_id: int) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or encounter_session == null
		or _route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
		or encounter_session.is_active()
		or encounter_session.is_node_resolved(node_id)
	):
		return false
	var type_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	)
	if type_config == null or type_config.content_pool_id == &"":
		return false
	return encounter_session.start_for_node(
		node_id,
		type_config.content_pool_id,
		_route_graph.get_node_content_seed(node_id),
		_get_active_encounter_peer_ids()
	)


func _try_start_normal_combat_for_node(
	node_id: int,
	target_visit_count: int
) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or _encounter_input_locked
		or not is_route_ready()
		or not _route_graph.is_valid_node_id(node_id)
		or _runtime_state.current_node_id != node_id
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.NORMAL_COMBAT
		or node_id >= _runtime_state.visited_counts.size()
		or target_visit_count != 1
		or int(_runtime_state.visited_counts[node_id]) != target_visit_count
		or get_signal_connection_list(&"normal_combat_requested").is_empty()
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
	):
		return false
	var content_seed := _route_graph.get_node_content_seed(node_id)
	var occurrence_key := _make_normal_combat_occurrence_key(
		node_id,
		content_seed,
		target_visit_count
	)
	if occurrence_key.is_empty():
		return false
	_begin_normal_combat_stage(node_id, content_seed, occurrence_key)
	_set_status("已进入普通作战节点，正在准备战斗。", false)
	normal_combat_requested.emit(node_id, content_seed, occurrence_key)
	return true


func _on_encounter_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	if manage_return_locally:
		host_submit_encounter_intro_ack(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision
		)
		return
	encounter_intro_ack_requested.emit(occurrence_key, expected_revision)


func _on_encounter_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	if manage_return_locally:
		host_submit_encounter_vote(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision,
			option_id
		)
		return
	encounter_vote_requested.emit(
		occurrence_key,
		expected_revision,
		option_id
	)


func _on_encounter_revealed(
	occurrence_key: String,
	_expected_revision: int
) -> void:
	if not _authority_enabled or encounter_session == null:
		return
	if encounter_session.get_occurrence_key() != occurrence_key:
		return
	encounter_session.start_voting_timer(
		occurrence_key,
		encounter_session.get_revision()
	)


func _on_encounter_result_hold_completed(
	occurrence_key: String,
	_expected_revision: int
) -> void:
	if encounter_session == null:
		return
	if encounter_session.get_occurrence_key() != occurrence_key:
		return
	_local_result_hold_completed_occurrence_key = occurrence_key
	if _authority_enabled:
		encounter_session.complete_result(
			occurrence_key,
			encounter_session.get_revision()
		)
	_try_dismiss_locally_completed_encounter()


func _on_encounter_result_ack_requested(
	occurrence_key: String,
	result_sequence: int
) -> void:
	if (
		encounter_session == null
		or encounter_session.get_occurrence_key() != occurrence_key
		or result_sequence <= 0
	):
		return
	_local_result_hold_completed_occurrence_key = occurrence_key
	if manage_return_locally:
		host_submit_encounter_result_ack(
			_get_local_encounter_peer_id(),
			occurrence_key,
			result_sequence
		)
	else:
		encounter_result_ack_requested.emit(
			occurrence_key,
			result_sequence
		)
	_try_dismiss_locally_completed_encounter()


func _on_encounter_state_changed(snapshot: Dictionary) -> void:
	if encounter_scene != null:
		encounter_scene.apply_state(
			_decorate_local_max_health_result(snapshot)
		)
	var phase := StringName(snapshot.get("phase", &"idle"))
	var encounter_active := phase not in [&"idle", &"completed"]
	if encounter_active and not _encounter_presented_active:
		_encounter_presented_active = true
		_local_result_hold_completed_occurrence_key = ""
		_encounter_presentation_serial += 1
		_set_encounter_input_locked(true)
		_present_encounter(_encounter_presentation_serial)
	elif phase == &"completed" and _encounter_presented_active:
		_try_dismiss_locally_completed_encounter()
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _try_dismiss_locally_completed_encounter() -> void:
	if (
		not _encounter_presented_active
		or encounter_session == null
		or encounter_session.get_phase() != &"completed"
		or _local_result_hold_completed_occurrence_key
		!= encounter_session.get_occurrence_key()
	):
		return
	_encounter_presented_active = false
	_encounter_presentation_serial += 1
	_dismiss_encounter(_encounter_presentation_serial)


func _on_encounter_economy_changed(_snapshot: Dictionary) -> void:
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _emit_host_encounter_snapshot() -> void:
	var encounter_snapshot := export_encounter_snapshot()
	var economy_snapshot := export_encounter_economy_snapshot()
	if encounter_snapshot.is_empty() or economy_snapshot.is_empty():
		return
	host_encounter_snapshot_committed.emit(
		encounter_snapshot,
		economy_snapshot
	)


func _present_encounter(presentation_serial: int) -> void:
	if encounter_scene == null:
		return
	await encounter_scene.cover_route_for_encounter()
	if presentation_serial != _encounter_presentation_serial:
		return
	_set_route_presentation_active(false)
	encounter_scene.apply_state(
		_decorate_local_max_health_result(export_encounter_snapshot())
	)
	await encounter_scene.reveal_encounter()
	if presentation_serial != _encounter_presentation_serial:
		return


func _dismiss_encounter(presentation_serial: int) -> void:
	if encounter_scene != null:
		await encounter_scene.cover_encounter_for_route()
	if presentation_serial != _encounter_presentation_serial:
		return
	_set_route_presentation_active(true)
	if encounter_scene != null:
		await encounter_scene.reveal_route_after_encounter()
	if presentation_serial != _encounter_presentation_serial:
		return
	var completed_state := encounter_session.export_state() if encounter_session != null else {}
	if bool(completed_state.get("run_failed", false)):
		_show_run_defeat()
		return
	_set_encounter_input_locked(false)


func _show_run_defeat() -> void:
	if _run_failure_presented or run_defeat_overlay == null:
		return
	_run_failure_presented = true
	_set_encounter_input_locked(true)
	run_defeat_overlay.show_defeat(not manage_return_locally)


func _on_run_defeat_confirmed() -> void:
	return_requested.emit()
	if manage_return_locally:
		call_deferred(&"_return_to_main_menu")


func _set_encounter_input_locked(locked: bool) -> void:
	_encounter_input_locked = locked
	_camera_drag_active = false
	if not is_node_ready():
		return
	if locked:
		# 遭遇/作战优先于路线入场演出。同步快照可能在展开 Tween
		# 进行中到达，必须先收束演出，避免隐藏 World 后冻结 Tween 与锁。
		route_board.complete_entry_reveal()
		_set_route_reveal_input_locked(false)
		_clear_pending_move(true)
	_refresh_route_input_lock()


func _set_route_reveal_input_locked(locked: bool) -> void:
	if _route_reveal_input_locked == locked:
		return
	_route_reveal_input_locked = locked
	_camera_drag_active = false
	if not is_node_ready():
		return
	if locked:
		_clear_pending_move(true)
	_refresh_route_input_lock()


func _is_route_input_locked() -> bool:
	return (
		_encounter_input_locked
		or _route_reveal_input_locked
		or _briefing_phase != BriefingPhase.NONE
		or _is_local_shop_presentation_active()
	)


func _refresh_route_input_lock() -> void:
	if not is_node_ready():
		return
	var locked := (
		_is_route_input_locked()
		or _pending_node_id != INVALID_NODE_ID
	)
	route_board.set_interaction_locked(locked)
	_set_local_player_controls_locked(locked)
	_update_authority_ui()


func _is_shop_departure_blocked() -> bool:
	return (
		underground_shop_controller != null
		and underground_shop_controller.is_departure_blocked()
	)


func _begin_shop_departure_for_route_move() -> bool:
	return (
		underground_shop_controller == null
		or underground_shop_controller.begin_departing()
	)


func _cancel_shop_departure_for_failed_move() -> void:
	if underground_shop_controller != null:
		underground_shop_controller.cancel_departing()


func _set_route_presentation_active(active: bool) -> void:
	if not is_node_ready():
		return
	if active:
		world.process_mode = Node.PROCESS_MODE_INHERIT
		world.show()
		route_hud.visible = true
		world.reset_physics_interpolation()
		return
	if move_confirmation.visible:
		move_confirmation.dismiss()
	route_hud.visible = false
	world.hide()
	world.process_mode = Node.PROCESS_MODE_DISABLED


func _bind_runtime_state(
	new_graph: RogueRouteGraph,
	new_state: RogueRouteRuntimeState
) -> void:
	_disconnect_runtime_state()
	_route_graph = new_graph
	_runtime_state = new_state
	_runtime_state.state_changed.connect(_on_runtime_state_changed)
	_runtime_state.move_committed.connect(_on_runtime_move_committed)


func _disconnect_runtime_state() -> void:
	if _runtime_state == null:
		return
	var state_callable := Callable(self, "_on_runtime_state_changed")
	var move_callable := Callable(self, "_on_runtime_move_committed")
	if _runtime_state.state_changed.is_connected(state_callable):
		_runtime_state.state_changed.disconnect(state_callable)
	if _runtime_state.move_committed.is_connected(move_callable):
		_runtime_state.move_committed.disconnect(move_callable)


func _on_route_board_node_pressed(node_id: int) -> void:
	if (
		not _authority_enabled
		or not is_route_ready()
	):
		return
	if _is_shop_departure_blocked():
		_set_status(
			"仍在等待这些玩家退出地下商店：%s"
			% "、".join(_get_shop_waiting_player_names()),
			true
		)
		return
	if _is_route_input_locked() or _pending_node_id != INVALID_NODE_ID:
		return
	if not route_board.can_interact_with_node(node_id):
		_set_status("该节点当前不可移动。", true)
		return
	var rejection_reason := _runtime_state.get_move_rejection_reason(
		node_id,
		generation_config.move_action_cost,
		_runtime_state.state_revision
	)
	if not rejection_reason.is_empty():
		_set_status(rejection_reason, true)
		return
	_pending_node_id = node_id
	_pending_revision = _runtime_state.state_revision
	route_board.select_node(node_id)
	route_board.set_interaction_locked(true)
	_set_local_player_controls_locked(true)
	_camera_drag_active = false
	_show_node_content(node_id, true)
	if (
		_route_graph.get_node_type(node_id)
		== RogueRouteGraph.NodeType.NORMAL_COMBAT
		and int(_runtime_state.visited_counts[node_id]) == 0
	):
		var occurrence_key := _make_normal_combat_occurrence_key(
			node_id,
			_route_graph.get_node_content_seed(node_id),
			int(_runtime_state.visited_counts[node_id]) + 1
		)
		if not _commit_host_briefing_state(
			BriefingPhase.PRESENTED,
			node_id,
			occurrence_key,
			_pending_revision
		):
			_set_status("普通作战简报无法生成，本次移动未执行。", true)
			_finish_pending_move()
		return
	move_confirmation.present(
		_get_node_display_name(node_id),
		_runtime_state.action_points,
		generation_config.move_action_cost
	)


func _on_move_confirmation_confirmed() -> void:
	var target_node_id := _pending_node_id
	var expected_revision := _pending_revision
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if not _authority_enabled or not is_route_ready():
		_finish_pending_move()
		return
	var rejection_reason := _runtime_state.get_move_rejection_reason(
		target_node_id,
		generation_config.move_action_cost,
		expected_revision
	)
	if not rejection_reason.is_empty():
		_set_status(rejection_reason, true)
		_finish_pending_move()
		return
	if not _begin_shop_departure_for_route_move():
		_set_status(
			"仍在等待这些玩家退出地下商店：%s"
			% "、".join(_get_shop_waiting_player_names()),
			true
		)
		_finish_pending_move()
		return
	if not _runtime_state.try_move(
		target_node_id,
		generation_config.move_action_cost,
		expected_revision
	):
		_cancel_shop_departure_for_failed_move()
		_set_status("路线状态已变化，本次移动未执行。", true)
	_finish_pending_move()


func _on_move_confirmation_canceled() -> void:
	_finish_pending_move()
	if is_route_ready():
		_show_node_content(_runtime_state.current_node_id, false)


func _on_node_briefing_confirmed() -> void:
	if (
		not _authority_enabled
		or not is_route_ready()
		or _briefing_phase != BriefingPhase.PRESENTED
		or _pending_node_id != _briefing_node_id
		or _pending_revision != _briefing_expected_route_revision
	):
		return
	if not _commit_host_briefing_state(
		BriefingPhase.ENTERING,
		_briefing_node_id,
		_briefing_occurrence_key,
		_briefing_expected_route_revision
	):
		_set_status("路线状态已变化，本次作战未启动。", true)
		_commit_host_briefing_state(
			BriefingPhase.NONE,
			INVALID_NODE_ID,
			"",
			-1
		)


func _on_node_briefing_canceled() -> void:
	if (
		not _authority_enabled
		or not is_route_ready()
		or _briefing_phase != BriefingPhase.PRESENTED
	):
		return
	if not _commit_host_briefing_state(
		BriefingPhase.NONE,
		INVALID_NODE_ID,
		"",
		-1
	):
		return
	_set_status("已取消普通作战；行动力与路线位置未发生变化。", false)
	_show_node_content(_runtime_state.current_node_id, false)


func _on_runtime_state_changed(_snapshot: Dictionary) -> void:
	if not is_route_ready():
		return
	if not route_board.update_runtime_state(
		_runtime_state.current_node_id,
		_runtime_state.action_points,
		_runtime_state.visited_counts,
		true
	):
		_set_status("路线视觉层拒绝了最新状态。", true)
		return
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)


func _on_runtime_move_committed(delta: Dictionary) -> void:
	if not _authority_enabled:
		return
	if underground_shop_controller != null:
		underground_shop_controller.close_departing()
	host_move_committed.emit(delta.duplicate(true))
	_set_status(
		"已移动至%s，消耗 %d 行动力。"
		% [
			_get_node_display_name(int(delta.get("to_node_id", INVALID_NODE_ID))),
			int(delta.get("move_cost", 0)),
		],
		false
	)
	var target_node_id := int(delta.get("to_node_id", INVALID_NODE_ID))
	var normal_combat_started := _try_start_normal_combat_for_node(
		target_node_id,
		int(delta.get("target_visit_count", 0))
	)
	if (
		not normal_combat_started
		and _briefing_phase == BriefingPhase.ENTERING
		and _briefing_node_id == target_node_id
	):
		abort_briefing_entry(_briefing_occurrence_key)
	_try_start_underground_shop_for_node(
		target_node_id,
		int(delta.get("target_visit_count", 0))
	)
	_try_start_encounter_for_node(target_node_id)


func _on_combat_result_overlay_dismissed() -> void:
	combat_result_dismissed.emit()


func _on_regenerate_button_pressed() -> void:
	if (
		not _authority_enabled
		or _is_route_input_locked()
		or _pending_node_id != INVALID_NODE_ID
	):
		return
	start_authoritative_session()


func _return_to_main_menu() -> void:
	if not is_inside_tree():
		return
	var error := get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
	if error != OK:
		_set_status("无法返回主菜单：%s" % error_string(error), true)


func configure_multiplayer_players(
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary,
	participant_stable_keys: Dictionary = {}
) -> bool:
	_clear_player_instances()
	_multiplayer_avatar_mode = true
	_local_peer_id = local_peer_id
	_player_names = player_names.duplicate(true)
	_player_character_ids = player_character_ids.duplicate(true)
	_player_stable_keys = participant_stable_keys.duplicate(true)
	_sync_encounter_player_character_ids()
	var peer_ids: Array[int] = []
	for peer_id_variant in player_names:
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			peer_ids.append(peer_id)
	peer_ids.sort()
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		var character_id := StringName(
			player_character_ids.get(
				peer_id,
				PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
			)
		)
		_add_multiplayer_player(
			peer_id,
			str(player_names.get(peer_id, "Player %d" % peer_id)),
			character_id,
			_get_avatar_spawn_position(index)
		)
	if player == null:
		push_error("RogueRouteGame: 多人路线场景缺少本地角色。")
		return false
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_attach_camera_to_local_player()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()
	return true


func add_multiplayer_player(
	peer_id: int,
	player_name: String,
	character_id: StringName,
	spawn_position: Vector2
) -> bool:
	if (
		not _multiplayer_avatar_mode
		or peer_id <= 0
		or peer_players.has(peer_id)
		or not spawn_position.is_finite()
	):
		return false
	var added := _add_multiplayer_player(
		peer_id,
		player_name,
		character_id,
		clamp_avatar_position(spawn_position)
	)
	if added:
		_player_names[peer_id] = player_name
		_player_character_ids[peer_id] = character_id
		_sync_encounter_player_character_ids()
		_sync_route_player_xirang_from_run_state()
		_sync_party_status_from_run_state()
		_configure_encounter_overlay_context()
		_sync_underground_shop_identity_context()
	return added


func set_multiplayer_participant_stable_key(
	peer_id: int,
	stable_key: String
) -> bool:
	if (
		peer_id <= 0
		or stable_key.is_empty()
		or not peer_players.has(peer_id)
	):
		return false
	_player_stable_keys[peer_id] = stable_key
	_sync_underground_shop_identity_context()
	return true


func migrate_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if (
		not _multiplayer_avatar_mode
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or peer_players.has(new_peer_id)
	):
		return false
	var player_instance := get_player_for_peer(old_peer_id)
	if (
		player_instance == null
		or player_instance.get_character_id() != character_id
	):
		return false
	var preserved_position := player_instance.global_position
	var preserved_velocity := player_instance.velocity
	peer_players.erase(old_peer_id)
	peer_players[new_peer_id] = player_instance
	_player_names.erase(old_peer_id)
	_player_character_ids.erase(old_peer_id)
	var stable_key := str(_player_stable_keys.get(old_peer_id, ""))
	_player_stable_keys.erase(old_peer_id)
	_player_names[new_peer_id] = player_name
	_player_character_ids[new_peer_id] = character_id
	if not stable_key.is_empty():
		_player_stable_keys[new_peer_id] = stable_key
	_sync_encounter_player_character_ids()
	player_instance.name = "RoutePlayer_%d" % new_peer_id
	if old_peer_id == _local_peer_id:
		_local_peer_id = new_peer_id
	_configure_multiplayer_player_node(
		player_instance,
		new_peer_id,
		player_name
	)
	player_instance.global_position = preserved_position
	player_instance.velocity = preserved_velocity
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()
	return true


func _add_multiplayer_player(
	peer_id: int,
	player_name: String,
	character_id: StringName,
	spawn_position: Vector2
) -> bool:
	var player_instance := _instantiate_route_player(character_id)
	if player_instance == null:
		return false
	player_instance.name = "RoutePlayer_%d" % peer_id
	player_instance.global_position = spawn_position
	player_container.add_child(player_instance)
	peer_players[peer_id] = player_instance
	_configure_multiplayer_player_node(player_instance, peer_id, player_name)
	return true


func _configure_multiplayer_player_node(
	player_instance: Player,
	peer_id: int,
	player_name: String
) -> void:
	var accepts_local_input := peer_id == _local_peer_id
	player_instance.configure_multiplayer_control(
		peer_id,
		accepts_local_input,
		player_name,
		accepts_local_input,
		accepts_local_input
	)
	player_instance.set_world_movement_mode(true, false)
	player_instance.set_multiplayer_visual_smoothing_enabled(
		not accepts_local_input
	)
	player_instance.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_ON
		if accepts_local_input
		else Node.PHYSICS_INTERPOLATION_MODE_OFF
	)
	player_instance.set_physics_process(accepts_local_input)
	if accepts_local_input:
		player = player_instance
		_bind_player_profile(player_instance)


func get_player_for_peer(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_local_avatar_snapshot() -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	return {
		"position": player.global_position,
		"velocity": player.velocity,
		"facing": player.get_multiplayer_facing_id(),
		"anim_state": player.get_multiplayer_anim_state(),
	}


func apply_avatar_snapshot(
	peer_id: int,
	remote_position: Vector2,
	remote_velocity: Vector2,
	facing_id: int,
	anim_state: int,
	correct_local_player: bool = false
) -> bool:
	var player_instance := get_player_for_peer(peer_id)
	if (
		player_instance == null
		or not remote_position.is_finite()
		or not remote_velocity.is_finite()
	):
		return false
	if peer_id == _local_peer_id and not correct_local_player:
		return true
	player_instance.apply_world_movement_snapshot(
		clamp_avatar_position(remote_position),
		remote_velocity,
		clampi(facing_id, 0, 3),
		maxi(anim_state, 0)
	)
	return true


func clamp_avatar_position(candidate: Vector2) -> Vector2:
	var bounds := route_board.get_world_bounds().grow(-10.0)
	return Vector2(
		clampf(candidate.x, bounds.position.x, bounds.end.x),
		clampf(candidate.y, bounds.position.y, bounds.end.y)
	)


func is_avatar_position_in_world(candidate: Vector2) -> bool:
	return candidate.is_finite() and route_board.get_world_bounds().grow(-8.0).has_point(
		candidate
	)


func remove_multiplayer_player(peer_id: int) -> void:
	var player_instance := peer_players.get(peer_id) as Player
	if player_instance == null:
		return
	peer_players.erase(peer_id)
	_player_names.erase(peer_id)
	_player_character_ids.erase(peer_id)
	_player_stable_keys.erase(peer_id)
	_sync_encounter_player_character_ids()
	if player_instance == player:
		player = null
		_bind_player_profile(null)
	if map_camera.get_parent() == player_instance:
		world.detach_camera_from_player()
	player_container.remove_child(player_instance)
	player_instance.queue_free()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()


func _configure_singleplayer_player() -> void:
	if player != null and is_instance_valid(player):
		return
	var character_id := PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null:
		character_id = run_state.get_selected_character_id()
	var player_instance := _instantiate_route_player(character_id)
	if player_instance == null:
		return
	player_instance.name = "Player"
	player_instance.global_position = _get_avatar_spawn_position(0)
	player_container.add_child(player_instance)
	player_instance.set_world_movement_mode(true, false)
	player_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	player_instance.reset_physics_interpolation()
	player = player_instance
	_bind_player_profile(player_instance)
	_local_peer_id = SINGLEPLAYER_PEER_ID
	_player_names = {SINGLEPLAYER_PEER_ID: "玩家"}
	_player_character_ids = {SINGLEPLAYER_PEER_ID: character_id}
	_player_stable_keys = {SINGLEPLAYER_PEER_ID: "singleplayer:local"}
	_sync_encounter_player_character_ids()
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_attach_camera_to_local_player()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()


func _sync_route_player_xirang_from_run_state() -> void:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return
	if _multiplayer_avatar_mode:
		var peer_ids: Array[int] = []
		for raw_peer_id in peer_players.keys():
			var peer_id := int(raw_peer_id)
			if peer_id > 0:
				peer_ids.append(peer_id)
		peer_ids.sort()
		for peer_id in peer_ids:
			_apply_route_player_xirang(
				peer_players.get(peer_id) as Player,
				run_state.get_party_xirang_balance(peer_id)
			)
		return
	_apply_route_player_xirang(
		player,
		run_state.get_party_xirang_balance(SINGLEPLAYER_PEER_ID)
	)


func _apply_route_player_xirang(player_instance: Player, amount: int) -> void:
	if player_instance == null or not is_instance_valid(player_instance):
		return
	var resolved_amount := maxi(amount, 0)
	if player_instance == player:
		_update_personal_xirang_hud(resolved_amount)
	if player_instance.current_xirang == resolved_amount:
		return
	var delta := resolved_amount - player_instance.current_xirang
	player_instance.current_xirang = resolved_amount
	player_instance.xirang_changed.emit(resolved_amount, delta)


func _update_personal_xirang_hud(amount: int) -> void:
	if not is_node_ready() or top_bar == null:
		return
	top_bar.set_personal_xirang(amount)


## 光石的持久化与结算规则尚未进入 RunState；路线会话接入后只需调用此入口更新 UI。
func set_shared_light_stone_amount(amount: int) -> void:
	if not is_node_ready() or top_bar == null:
		return
	top_bar.set_shared_light_stone(amount)


func _on_party_xirang_ledger_changed(_snapshot: Dictionary) -> void:
	_sync_route_player_xirang_from_run_state()


func _connect_party_status_ledger() -> void:
	_run_state = get_node_or_null("/root/RunState") as RunStateStore
	if _run_state == null:
		_bind_local_inventory_strip(null)
		_update_core_hud(100, 100)
		return
	_bind_local_inventory_strip(player)
	if not _run_state.party_status_ledger_changed.is_connected(
		_on_party_status_ledger_changed
	):
		_run_state.party_status_ledger_changed.connect(
			_on_party_status_ledger_changed
		)
	if not _run_state.party_xirang_ledger_changed.is_connected(
		_on_party_xirang_ledger_changed
	):
		_run_state.party_xirang_ledger_changed.connect(
			_on_party_xirang_ledger_changed
		)
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_cache_max_health_penalties(_run_state.export_party_status_ledger())


func _on_party_status_ledger_changed(snapshot: Dictionary) -> void:
	var before_max_health: Dictionary = {}
	var players_by_status_peer: Dictionary = {}
	for raw_peer_id in peer_players.keys():
		var dictionary_peer_id := int(raw_peer_id)
		var peer_player := peer_players.get(dictionary_peer_id) as Player
		if peer_player != null and is_instance_valid(peer_player):
			# RunState 的重连 remap 会先把仍在树中的 Player.peer_id 暂存为
			# new peer，再同步发出账本信号；此刻 peer_players 的字典键仍可能是
			# old peer。必须以节点真实身份读取信号快照，不能调用会 ensure 状态的
			# RunState getter，否则刚移除的 old peer 会被重新创建。
			var status_peer_id := (
				peer_player.peer_id
				if peer_player.peer_id > 0
				else dictionary_peer_id
			)
			before_max_health[status_peer_id] = peer_player.max_health
			players_by_status_peer[status_peer_id] = peer_player
	if not _multiplayer_avatar_mode and player != null and is_instance_valid(player):
		before_max_health[SINGLEPLAYER_PEER_ID] = player.max_health
		players_by_status_peer[SINGLEPLAYER_PEER_ID] = player
	_update_core_hud(
		int(snapshot.get("core_current", 100)),
		int(snapshot.get("core_maximum", 100))
	)
	var incoming_penalties := snapshot.get("max_health_penalties", {}) as Dictionary
	for raw_peer_id in players_by_status_peer.keys():
		var peer_id := int(raw_peer_id)
		var peer_player := players_by_status_peer.get(peer_id) as Player
		if peer_player == null or not is_instance_valid(peer_player):
			continue
		peer_player.set_run_max_health_penalty(
			_get_status_snapshot_penalty(incoming_penalties, peer_id)
		)
	for raw_peer_key in incoming_penalties.keys():
		var peer_id := int(raw_peer_key)
		var penalty_after := int(incoming_penalties[raw_peer_key])
		var penalty_before := int(_cached_max_health_penalties.get(peer_id, 0))
		if penalty_after <= penalty_before or not before_max_health.has(peer_id):
			continue
		var peer_player := players_by_status_peer.get(peer_id) as Player
		if peer_player == null or not is_instance_valid(peer_player):
			continue
		_max_health_transition_by_peer[peer_id] = {
			"before": int(before_max_health[peer_id]),
			"after": peer_player.max_health,
			"penalty_after": penalty_after,
		}
	_cache_max_health_penalties(snapshot)


func _get_status_snapshot_penalty(
	penalties: Dictionary,
	peer_id: int
) -> int:
	return maxi(
		int(penalties.get(str(peer_id), penalties.get(peer_id, 0))),
		0
	)


func _cache_max_health_penalties(snapshot: Dictionary) -> void:
	_cached_max_health_penalties.clear()
	var penalties := snapshot.get("max_health_penalties", {}) as Dictionary
	for raw_peer_key in penalties.keys():
		_cached_max_health_penalties[int(raw_peer_key)] = int(
			penalties[raw_peer_key]
		)


func _decorate_local_max_health_result(snapshot: Dictionary) -> Dictionary:
	var decorated := snapshot.duplicate(true)
	var economy_result := decorated.get("economy_result", {}) as Dictionary
	if StringName(economy_result.get("result_code", &"")) != &"pit_radiation":
		return decorated
	var local_peer_id := _get_local_encounter_peer_id()
	var transition := (
		_max_health_transition_by_peer.get(local_peer_id, {}) as Dictionary
	)
	if transition.is_empty():
		return decorated
	var expected_penalty_after := -1
	var penalty_totals := economy_result.get(
		"max_health_penalty_totals",
		[]
	) as Array
	for raw_entry in penalty_totals:
		if typeof(raw_entry) != TYPE_DICTIONARY:
			continue
		var entry := raw_entry as Dictionary
		if int(entry.get("peer_id", -1)) == local_peer_id:
			expected_penalty_after = int(entry.get("after", -1))
			break
	if expected_penalty_after != int(transition.get("penalty_after", -2)):
		return decorated
	var personal_pages := decorated.get("personal_result_pages", {}) as Dictionary
	personal_pages[local_peer_id] = [{
		"speaker": "",
		"text": "最大生命：%d → %d" % [
			int(transition.get("before", 1)),
			int(transition.get("after", 1)),
		],
		"is_narration": true,
	}]
	decorated["personal_result_pages"] = personal_pages
	return decorated


func _sync_party_status_from_run_state() -> void:
	if _run_state == null:
		_run_state = get_node_or_null("/root/RunState") as RunStateStore
	if _run_state == null:
		_update_core_hud(100, 100)
		return
	_update_core_hud(
		_run_state.get_party_core_health(),
		_run_state.get_party_core_maximum_health()
	)
	if _multiplayer_avatar_mode:
		for raw_peer_id in peer_players.keys():
			var peer_id := int(raw_peer_id)
			var player_instance := peer_players.get(peer_id) as Player
			if player_instance != null and is_instance_valid(player_instance):
				player_instance.set_run_max_health_penalty(
					_run_state.get_max_health_penalty_for_peer(peer_id)
				)
		return
	if player != null and is_instance_valid(player):
		player.set_run_max_health_penalty(
			_run_state.get_max_health_penalty_for_peer(SINGLEPLAYER_PEER_ID)
		)


func _update_core_hud(current_health: int, maximum_health: int) -> void:
	if not is_node_ready() or top_bar == null:
		return
	top_bar.set_core_health(current_health, maximum_health)


func _instantiate_route_player(character_id: StringName) -> Player:
	var resolved_id := character_id
	if not PlayerCharacterRegistry.is_valid_character_id(resolved_id):
		resolved_id = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var player_instance := PlayerCharacterRegistry.instantiate_character(resolved_id)
	if player_instance == null:
		push_error("RogueRouteGame: 无法实例化路线角色 %s。" % resolved_id)
	else:
		# Rogue 路线使用像素素材；角色与路线节点都固定走最近邻采样。
		player_instance.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return player_instance


func _get_avatar_spawn_position(index: int) -> Vector2:
	var offset: Vector2 = AVATAR_SPAWN_OFFSETS[
		index % AVATAR_SPAWN_OFFSETS.size()
	]
	return route_board.get_default_spawn_global_position(generation_config) + offset


func _attach_camera_to_local_player() -> void:
	if map_camera == null or player == null:
		return
	world.attach_camera_to_player(player)


func _configure_camera_world_bounds() -> void:
	world.configure_world_bounds()
	_clamp_camera_drag_offset()


func _apply_camera_drag(screen_delta: Vector2) -> void:
	world.apply_camera_drag(player, screen_delta, get_viewport_rect().size)


func _clamp_camera_drag_offset() -> void:
	world.clamp_camera_drag(player, get_viewport_rect().size)


func _recenter_camera_on_player() -> void:
	_camera_drag_active = false
	world.recenter_camera(player, get_viewport_rect().size)


func _on_recenter_button_pressed() -> void:
	if _is_route_input_locked() or _pending_node_id != INVALID_NODE_ID:
		return
	_recenter_camera_on_player()


func _on_route_inventory_bag_requested() -> void:
	if player_profile_panel != null:
		player_profile_panel.open()


func _bind_player_profile(player_instance: Player) -> void:
	if player_profile_panel != null:
		player_profile_panel.bind_player(player_instance)
	_bind_local_inventory_strip(player_instance)


func _bind_local_inventory_strip(player_instance: Player) -> void:
	if route_inventory_strip == null:
		return
	if player_instance == null or _run_state == null:
		route_inventory_strip.bind_run_state(null)
		return
	route_inventory_strip.bind_run_state(
		_run_state,
		maxi(player_instance.peer_id, SINGLEPLAYER_PEER_ID)
	)


func _set_local_player_controls_locked(locked: bool) -> void:
	if player != null and is_instance_valid(player):
		player.set_controls_locked(locked)


func _clear_player_instances() -> void:
	_bind_player_profile(null)
	world.detach_camera_from_player()
	for child in player_container.get_children():
		player_container.remove_child(child)
		child.queue_free()
	peer_players.clear()
	_player_names.clear()
	_player_character_ids.clear()
	_sync_encounter_player_character_ids()
	player = null


func _sync_encounter_player_character_ids() -> void:
	if encounter_economy != null:
		encounter_economy.set_player_character_ids(_player_character_ids)


func _clear_pending_move(hide_dialog: bool) -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if not is_node_ready():
		return
	if hide_dialog and move_confirmation.visible:
		move_confirmation.dismiss()
	route_board.clear_selection()
	_refresh_route_input_lock()


func _finish_pending_move() -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if move_confirmation.visible:
		move_confirmation.dismiss()
	route_board.clear_selection()
	_refresh_route_input_lock()


func _update_route_hud() -> void:
	if not is_route_ready():
		top_bar.set_action_points(-1)
		return
	top_bar.set_action_points(_runtime_state.action_points)


func _update_authority_ui() -> void:
	if not is_node_ready():
		return
	regenerate_button.disabled = not _authority_enabled or _is_route_input_locked()
	hint_label.text = (
		"遭遇或作战进行中；路线移动与地图拖动已锁定。"
		if _encounter_input_locked
		else "地下路线正在展开…"
		if _route_reveal_input_locked
		else
		"WASD / 左摇杆探索 · 拖动空白处查看地图 · 每次移动消耗 %d AP。"
		% generation_config.move_action_cost
		if _authority_enabled and generation_config != null
		else "WASD / 左摇杆自由探索 · 拖动空白处查看地图；路线由房主确认。"
	)

func _show_node_content(node_id: int, is_preview: bool) -> void:
	if not is_route_ready() or not _route_graph.is_valid_node_id(node_id):
		content_overline.text = "CONTENT PLACEHOLDER"
		content_title.text = "等待路线数据"
		content_body.text = "房主生成或同步路线后，这里会显示当前节点的占位信息。"
		content_meta.text = "尚未载入"
		return
	var display_name := _get_node_display_name(node_id)
	var node_type := _route_graph.get_node_type(node_id)
	content_overline.text = "移动预览" if is_preview else "当前节点"
	content_title.text = display_name
	if node_type == RogueRouteGraph.NodeType.EMPTY:
		content_body.text = (
			"这里暂时没有事件内容。空白节点仍属于路线的一部分，"
			+ "可以用于绕行或返回。"
		)
	elif node_type == RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER:
		content_body.text = (
			"首次抵达会触发全队共享的神奇遭遇；已完成节点回访时"
			+ "不会重复结算。"
		)
	elif node_type == RogueRouteGraph.NodeType.NORMAL_COMBAT:
		content_body.text = (
			"抵达前将显示全队共享的作战简报；仅房主能够确认，"
			+ "确认前不会扣除行动力。"
		)
	else:
		content_body.text = (
			"「%s」的正式内容尚未接入。本阶段仅验证节点选择、"
			+ "行动力扣除与共享小队移动。"
		) % display_name
	var coord := _route_graph.id_to_coord(node_id)
	content_meta.text = "节点 #%d · 坐标 (%d, %d) · 内容种子 %d" % [
		node_id,
		coord.x,
		coord.y,
		_route_graph.get_node_content_seed(node_id),
	]


func _get_node_display_name(node_id: int) -> String:
	if _route_graph == null or not _route_graph.is_valid_node_id(node_id):
		return "未知节点"
	var node_type := _route_graph.get_node_type(node_id)
	if node_type == RogueRouteGraph.NodeType.EMPTY:
		return "空白区域"
	if generation_config != null:
		var type_config := generation_config.get_type_config(node_type)
		if type_config != null and not type_config.display_name.is_empty():
			return type_config.display_name
	return "未知节点"


func _get_runtime_contract_hash() -> String:
	if floor_definition == null:
		return ""
	return floor_definition.compute_runtime_contract_hash()


func _set_status(message: String, is_error: bool) -> void:
	if not is_node_ready():
		return
	status_message.text = message
	status_message.add_theme_color_override(
		&"font_color",
		Color("e8b978") if is_error else Color("88aaa4")
	)
