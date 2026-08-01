extends Control
class_name TestRogueRouteP3

signal host_layout_committed(
	layout_snapshot: Dictionary,
	state_snapshot: Dictionary
)
signal host_move_committed(delta: Dictionary)
signal return_requested

const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"
const INVALID_NODE_ID := -1
const AUTO_SEED := 0

@export var generation_config: RogueRouteGenerationConfig
@export var auto_initialize := true
@export var manage_return_locally := true
## 0 表示每次进入时生成新 seed；非零值便于复现指定地图。
@export var initial_generation_seed := AUTO_SEED

@onready var route_board: RogueRouteBoard = $Page/Layout/Main/RouteBoard
@onready var role_value: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/Stats/RoleValue
)
@onready var character_value: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/Stats/CharacterValue
)
@onready var action_points_value: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/Stats/ActionPointsValue
)
@onready var seed_value: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/Stats/SeedValue
)
@onready var position_value: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/Stats/PositionValue
)
@onready var content_overline: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/ContentOverline
)
@onready var content_title: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/ContentTitle
)
@onready var content_body: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/ContentBody
)
@onready var content_meta: Label = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/ContentMeta
)
@onready var regenerate_button: Button = (
	$Page/Layout/Main/Sidebar/SidebarMargin/SidebarContent/RegenerateButton
)
@onready var hint_label: Label = $Page/Layout/Footer/Hint
@onready var status_message: Label = $Page/Layout/Footer/StatusMessage
@onready var move_confirmation: ConfirmationDialog = $MoveConfirmation

var _route_graph: RogueRouteGraph = null
var _runtime_state: RogueRouteRuntimeState = null
var _authority_enabled := true
var _route_ready := false
var _pending_node_id := INVALID_NODE_ID
var _pending_revision := -1


func _ready() -> void:
	route_board.show_waiting_for_host()
	_update_character_display()
	_update_authority_ui()
	_update_route_hud()
	_show_node_content(INVALID_NODE_ID, false)
	if auto_initialize:
		call_deferred("_initialize_default_session")
	else:
		_set_status("等待外部会话初始化。", false)


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
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)
	_set_status("路线已生成。点击青色相邻节点规划下一步。", false)
	if announce_full_snapshot:
		host_layout_committed.emit(
			export_layout_snapshot(),
			export_state_snapshot()
		)
	return true


func start_client_waiting() -> void:
	_clear_pending_move(true)
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
	state_snapshot: Dictionary
) -> bool:
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

	_clear_pending_move(true)
	set_authority_enabled(false)
	if not route_board.present_graph(
		imported_graph,
		generation_config,
		imported_state.current_node_id,
		imported_state.action_points,
		imported_state.visited_counts,
		false
	):
		_set_status("客户端路线视觉层初始化失败。", true)
		return false
	_bind_runtime_state(imported_graph, imported_state)
	_route_ready = true
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)
	_set_status("已同步房主路线。当前为只读模式。", false)
	return true


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
	return _route_graph.export_layout().duplicate(true)


func export_state_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	return _runtime_state.export_state().duplicate(true)


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
	pass


func _initialize_default_session() -> void:
	if auto_initialize and not is_route_ready():
		start_authoritative_session(initial_generation_seed)


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
	if not _authority_enabled or not is_route_ready():
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
	_show_node_content(node_id, true)
	move_confirmation.dialog_text = (
		"移动至「%s」？\n本次消耗 %d 行动力，确认后剩余 %d。"
		% [
			_get_node_display_name(node_id),
			generation_config.move_action_cost,
			_runtime_state.action_points - generation_config.move_action_cost,
		]
	)
	move_confirmation.popup_centered(Vector2i(460, 210))


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
	if not _runtime_state.try_move(
		target_node_id,
		generation_config.move_action_cost,
		expected_revision
	):
		_set_status("路线状态已变化，本次移动未执行。", true)
	_finish_pending_move()


func _on_move_confirmation_canceled() -> void:
	_finish_pending_move()
	if is_route_ready():
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
	host_move_committed.emit(delta.duplicate(true))
	_set_status(
		"已移动至%s，消耗 %d 行动力。"
		% [
			_get_node_display_name(int(delta.get("to_node_id", INVALID_NODE_ID))),
			int(delta.get("move_cost", 0)),
		],
		false
	)


func _on_regenerate_button_pressed() -> void:
	if not _authority_enabled:
		return
	start_authoritative_session()


func _on_return_button_pressed() -> void:
	_clear_pending_move(true)
	return_requested.emit()
	if manage_return_locally:
		call_deferred("_return_to_main_menu")


func _return_to_main_menu() -> void:
	if not is_inside_tree():
		return
	var error := get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
	if error != OK:
		_set_status("无法返回主菜单：%s" % error_string(error), true)


func _clear_pending_move(hide_dialog: bool) -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if not is_node_ready():
		return
	if hide_dialog and move_confirmation.visible:
		move_confirmation.hide()
	route_board.set_interaction_locked(false)
	route_board.clear_selection()


func _finish_pending_move() -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	route_board.set_interaction_locked(false)
	route_board.clear_selection()


func _update_route_hud() -> void:
	if not is_route_ready():
		action_points_value.text = "—"
		seed_value.text = "—"
		position_value.text = "等待同步"
		return
	action_points_value.text = str(_runtime_state.action_points)
	seed_value.text = str(_route_graph.generation_seed)
	var coord := _route_graph.id_to_coord(_runtime_state.current_node_id)
	position_value.text = "#%d · (%d, %d)" % [
		_runtime_state.current_node_id,
		coord.x,
		coord.y,
	]


func _update_authority_ui() -> void:
	if not is_node_ready():
		return
	role_value.text = (
		("单人房主" if manage_return_locally else "房主 · 可操作")
		if _authority_enabled
		else "队伍成员 · 只读"
	)
	role_value.add_theme_color_override(
		&"font_color",
		Color("7fe7dc") if _authority_enabled else Color("a4b0ad")
	)
	regenerate_button.disabled = not _authority_enabled
	hint_label.text = (
		"点击发光的相邻节点并确认；每次移动消耗 %d AP，可沿连线自由往返。"
		% generation_config.move_action_cost
		if _authority_enabled and generation_config != null
		else "路线由房主操作；你可以查看邻近节点名称与队伍当前位置。"
	)


func _update_character_display() -> void:
	character_value.text = "共享小队"


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


func _set_status(message: String, is_error: bool) -> void:
	if not is_node_ready():
		return
	status_message.text = message
	status_message.add_theme_color_override(
		&"font_color",
		Color("e8b978") if is_error else Color("88aaa4")
	)
