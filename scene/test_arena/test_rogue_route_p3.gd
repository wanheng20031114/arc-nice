extends Node2D
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
const ROUTE_CONTRACT_FIELD := "runtime_contract_hash"
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

@export var generation_config: RogueRouteGenerationConfig
@export var auto_initialize := true
@export var manage_return_locally := true
## 0 表示每次进入时生成新 seed；非零值便于复现指定地图。
@export var initial_generation_seed := AUTO_SEED

@onready var world: RogueRouteWorld = $World
@onready var route_board: RogueRouteBoard = $World/RouteBoard
@onready var player_container: Node2D = $World/Players
@onready var map_camera: Camera2D = $World/Camera2D
@onready var role_value: Label = %RoleValue
@onready var character_value: Label = %CharacterValue
@onready var action_points_value: Label = %ActionPointsValue
@onready var seed_value: Label = %SeedValue
@onready var position_value: Label = %PositionValue
@onready var content_overline: Label = %ContentOverline
@onready var content_title: Label = %ContentTitle
@onready var content_body: Label = %ContentBody
@onready var content_meta: Label = %ContentMeta
@onready var regenerate_button: Button = %RegenerateButton
@onready var hint_label: Label = %Hint
@onready var status_message: Label = %StatusMessage
@onready var move_confirmation: ConfirmationDialog = $MoveConfirmation

var _route_graph: RogueRouteGraph = null
var _runtime_state: RogueRouteRuntimeState = null
var _authority_enabled := true
var _route_ready := false
var _pending_node_id := INVALID_NODE_ID
var _pending_revision := -1
var player: Player = null
var peer_players: Dictionary[int, Player] = {}
var _local_peer_id := 0
var _multiplayer_avatar_mode := false
var _camera_drag_active := false


func _ready() -> void:
	route_board.show_waiting_for_host()
	if manage_return_locally:
		_configure_singleplayer_player()
	_update_character_display()
	_update_authority_ui()
	_update_route_hud()
	_show_node_content(INVALID_NODE_ID, false)
	if auto_initialize:
		call_deferred("_initialize_default_session")
	else:
		_set_status("等待外部会话初始化。", false)


func _physics_process(_delta: float) -> void:
	if player != null and is_instance_valid(player):
		route_board.update_local_player_global_position(player.global_position)
		_clamp_camera_drag_offset()


func _unhandled_input(event: InputEvent) -> void:
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
	_set_status("路线世界已生成。移动角色探索，并走近青色相邻节点。", false)
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
	_configure_camera_world_bounds()
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
	var snapshot := _route_graph.export_layout().duplicate(true)
	snapshot[ROUTE_CONTRACT_FIELD] = _get_runtime_contract_hash()
	return snapshot


func export_state_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	return _runtime_state.export_state().duplicate(true)


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
	if not route_board.can_interact_with_node(node_id):
		_set_status("请先走近目标节点，再确认路线移动。", true)
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
	if not route_board.is_node_in_player_range(target_node_id):
		_set_status("你已离开目标节点范围，本次移动未执行。", true)
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


func configure_multiplayer_players(
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary
) -> bool:
	_clear_player_instances()
	_multiplayer_avatar_mode = true
	_local_peer_id = local_peer_id
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
		push_error("TestRogueRouteP3: 多人路线场景缺少本地角色。")
		return false
	_attach_camera_to_local_player()
	_update_character_display()
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
	return _add_multiplayer_player(
		peer_id,
		player_name,
		character_id,
		clamp_avatar_position(spawn_position)
	)


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
	if player_instance == player:
		player = null
	if map_camera.get_parent() == player_instance:
		world.detach_camera_from_player()
	player_container.remove_child(player_instance)
	player_instance.queue_free()


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
	_attach_camera_to_local_player()


func _instantiate_route_player(character_id: StringName) -> Player:
	var resolved_id := character_id
	if not PlayerCharacterRegistry.is_valid_character_id(resolved_id):
		resolved_id = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var player_instance := PlayerCharacterRegistry.instantiate_character(resolved_id)
	if player_instance == null:
		push_error("TestRogueRouteP3: 无法实例化路线角色 %s。" % resolved_id)
	else:
		# P3 的背景、节点和 HUD 使用平滑过滤；低像素玩家单独保持清晰。
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
	_recenter_camera_on_player()


func _set_local_player_controls_locked(locked: bool) -> void:
	if player != null and is_instance_valid(player):
		player.set_controls_locked(locked)


func _clear_player_instances() -> void:
	world.detach_camera_from_player()
	for child in player_container.get_children():
		player_container.remove_child(child)
		child.queue_free()
	peer_players.clear()
	player = null


func _clear_pending_move(hide_dialog: bool) -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if not is_node_ready():
		return
	if hide_dialog and move_confirmation.visible:
		move_confirmation.hide()
	route_board.set_interaction_locked(false)
	route_board.clear_selection()
	_set_local_player_controls_locked(false)


func _finish_pending_move() -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	route_board.set_interaction_locked(false)
	route_board.clear_selection()
	_set_local_player_controls_locked(false)


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
		"WASD / 左摇杆探索 · 拖动空白处查看地图 · 每次移动消耗 %d AP。"
		% generation_config.move_action_cost
		if _authority_enabled and generation_config != null
		else "WASD / 左摇杆自由探索 · 拖动空白处查看地图；路线由房主确认。"
	)


func _update_character_display() -> void:
	if player == null or not is_instance_valid(player):
		character_value.text = "等待角色"
		return
	var config := PlayerCharacterRegistry.get_config(player.get_character_id())
	character_value.text = (
		config.display_name
		if config != null and not config.display_name.is_empty()
		else str(player.get_character_id())
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
	if generation_config == null:
		return ""
	return generation_config.compute_runtime_contract_hash(
		route_board.get_world_metrics()
	)


func _set_status(message: String, is_error: bool) -> void:
	if not is_node_ready():
		return
	status_message.text = message
	status_message.add_theme_color_override(
		&"font_color",
		Color("e8b978") if is_error else Color("88aaa4")
	)
