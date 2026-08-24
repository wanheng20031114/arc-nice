extends Node
class_name GameplayPauseController

const PAUSE_ACTION := &"pause"

@onready var screen_root: Control = $PauseLayer/ScreenRoot
@onready var main_center: CenterContainer = $PauseLayer/ScreenRoot/MainCenter
@onready var pause_source_label: Label = (
	$PauseLayer/ScreenRoot/MainCenter/PausePanel/Margin/Layout/PauseSource
)
@onready var resume_button: Button = (
	$PauseLayer/ScreenRoot/MainCenter/PausePanel/Margin/Layout/ResumeButton
)
@onready var settings_button: Button = (
	$PauseLayer/ScreenRoot/MainCenter/PausePanel/Margin/Layout/SettingsButton
)
@onready var return_button: Button = (
	$PauseLayer/ScreenRoot/MainCenter/PausePanel/Margin/Layout/ReturnButton
)
@onready var confirm_center: CenterContainer = $PauseLayer/ScreenRoot/ConfirmCenter
@onready var confirm_return_button: Button = (
	$PauseLayer/ScreenRoot/ConfirmCenter/ConfirmPanel/Margin/Layout/Actions/ConfirmButton
)
@onready var cancel_return_button: Button = (
	$PauseLayer/ScreenRoot/ConfirmCenter/ConfirmPanel/Margin/Layout/Actions/CancelButton
)
@onready var settings_panel: SettingsPanel = $PauseLayer/SettingsPanel

var _context_owner: Node = null
var _context_owner_tree_exiting_callback := Callable()
var _exit_handler := Callable()
var _context_is_networked := false
var _context_session_id := 0

var _gameplay_paused := false
var _accumulated_pause_duration_seconds := 0.0
var _pause_wall_started_seconds := -1.0
var _exit_in_progress := false

var _network_session_id := 0
var _network_pause_revision := 0
var _network_pause_state := false
var _network_pause_actor_peer_id := 0
var _network_request_pending := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	screen_root.hide()
	main_center.show()
	confirm_center.hide()
	resume_button.pressed.connect(_on_resume_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	return_button.pressed.connect(_on_return_pressed)
	confirm_return_button.pressed.connect(_on_confirm_return_pressed)
	cancel_return_button.pressed.connect(_on_cancel_return_pressed)
	settings_panel.closed.connect(_on_settings_panel_closed)
	_set_pause_controls_disabled(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _has_context() or _exit_in_progress or _network_request_pending:
		return
	if not event.is_action_pressed(PAUSE_ACTION):
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	get_viewport().set_input_as_handled()
	UIAudio.play_click()
	if settings_panel.is_open():
		settings_panel.close()
		return
	if confirm_center.visible:
		_show_main_menu()
		return
	if _gameplay_paused:
		request_pause(false)
	else:
		request_pause(true)


func register_context(owner: Node, exit_handler: Callable) -> void:
	if owner == null or not is_instance_valid(owner):
		push_error("GameplayPause: 无法注册无效的玩法上下文。")
		return
	if not exit_handler.is_valid():
		push_error("GameplayPause: 玩法上下文必须提供有效的退出处理器。")
		return
	if _context_owner == owner:
		_exit_handler = exit_handler
		return
	if _context_owner != null:
		_clear_registered_context()
	_context_owner = owner
	_exit_handler = exit_handler
	_context_is_networked = NetManager.is_multiplayer_active()
	_context_session_id = (
		NetManager.get_game_session_incarnation() if _context_is_networked else 0
	)
	_exit_in_progress = false
	_network_request_pending = false
	_context_owner_tree_exiting_callback = Callable(
		self,
		"_on_context_owner_tree_exiting"
	).bind(owner.get_instance_id())
	owner.tree_exiting.connect(_context_owner_tree_exiting_callback, CONNECT_ONE_SHOT)
	_set_pause_controls_disabled(false)
	if (
		_context_is_networked
		and _context_session_id > 0
		and _network_session_id == _context_session_id
		and _network_pause_revision > 0
	):
		_apply_committed_pause_state(
			_network_pause_state,
			_network_pause_actor_peer_id,
			true
		)


func unregister_context(owner: Node) -> void:
	if owner == null or _context_owner != owner:
		return
	_clear_registered_context()


func open_menu() -> void:
	request_pause(true)


func request_pause(desired: bool) -> void:
	if not _has_context() or _exit_in_progress:
		return
	if desired == _gameplay_paused:
		if desired:
			_show_main_menu()
		return
	if _context_is_networked:
		if _network_request_pending:
			return
		_network_request_pending = true
		_set_pause_controls_disabled(true)
		var request_accepted: bool = NetManager.request_game_pause(desired)
		if not request_accepted:
			_network_request_pending = false
			_set_pause_controls_disabled(false)
		return
	_apply_committed_pause_state(desired, 0, true)


func is_gameplay_paused() -> bool:
	return _gameplay_paused


func get_gameplay_time_seconds() -> float:
	var wall_now := _get_wall_time_seconds()
	if not _has_context():
		return wall_now
	var paused_duration := _accumulated_pause_duration_seconds
	if _gameplay_paused and _pause_wall_started_seconds >= 0.0:
		paused_duration += maxf(wall_now - _pause_wall_started_seconds, 0.0)
	return wall_now - paused_duration


func apply_network_pause_state(
	session_id: int,
	revision: int,
	paused: bool,
	actor_peer_id: int
) -> void:
	# NetManager 用全零快照作为会话清理哨兵；它必须能解除旧会话
	# 留下的 SceneTree 暂停，但不能伪装成一个可继续递增的会话版本。
	if session_id == 0:
		if revision != 0 or paused or actor_peer_id != 0:
			return
		_network_session_id = 0
		_network_pause_revision = 0
		_network_pause_state = false
		_network_pause_actor_peer_id = 0
		_network_request_pending = false
		_set_pause_controls_disabled(_exit_in_progress)
		# 清理哨兵是网络会话退出的最终保险，即使玩法 owner 已先离树，
		# 也不能把全局 SceneTree 暂停泄漏到大厅或主菜单。
		get_tree().paused = false
		if _has_context() and _context_is_networked and not _exit_in_progress:
			_apply_committed_pause_state(false, 0, true)
		return
	if (
		session_id < 0
		or revision < 0
		or (revision == 0 and (paused or actor_peer_id != 0))
		or (revision > 0 and actor_peer_id <= 0)
	):
		return
	if session_id != NetManager.get_game_session_incarnation():
		return
	var session_changed := _network_session_id != session_id
	if _network_session_id != session_id:
		_network_session_id = session_id
		_network_pause_revision = 0
		_network_pause_state = false
		_network_pause_actor_peer_id = 0
	if revision < _network_pause_revision:
		return
	if (
		not session_changed
		and revision == _network_pause_revision
		and (
			paused != _network_pause_state
			or actor_peer_id != _network_pause_actor_peer_id
		)
	):
		return
	var committed_state_changed := paused != _network_pause_state
	_network_pause_revision = revision
	_network_pause_state = paused
	_network_pause_actor_peer_id = actor_peer_id
	_network_request_pending = false
	_set_pause_controls_disabled(_exit_in_progress)
	if (
		_has_context()
		and _context_is_networked
		and _context_session_id == session_id
		and not _exit_in_progress
	):
		if committed_state_changed or _gameplay_paused != paused:
			_apply_committed_pause_state(paused, actor_peer_id, true)
		elif paused:
			_refresh_pause_source_label()


func force_unpause_for_transition() -> void:
	_exit_in_progress = true
	_network_request_pending = false
	_update_pause_clock(false)
	_gameplay_paused = false
	_close_secondary_panels_and_flush()
	screen_root.hide()
	_set_pause_controls_disabled(false)
	var tree := get_tree()
	if tree != null:
		tree.paused = false


func _apply_committed_pause_state(
	paused: bool,
	actor_peer_id: int,
	apply_scene_tree_pause: bool
) -> void:
	_update_pause_clock(paused)
	_gameplay_paused = paused
	if apply_scene_tree_pause:
		get_tree().paused = paused
	if paused:
		_network_pause_actor_peer_id = actor_peer_id
		_show_main_menu()
	else:
		_close_secondary_panels_and_flush()
		screen_root.hide()


func _show_main_menu() -> void:
	confirm_center.hide()
	main_center.show()
	screen_root.show()
	_refresh_pause_source_label()
	resume_button.grab_focus()


func _refresh_pause_source_label() -> void:
	pause_source_label.text = (
		"玩家 %d 暂停了游戏" % _network_pause_actor_peer_id
		if _context_is_networked and _network_pause_actor_peer_id > 0
		else "游戏进程已暂停"
	)


func _show_return_confirmation() -> void:
	main_center.hide()
	confirm_center.show()
	cancel_return_button.grab_focus()


func _open_settings() -> void:
	main_center.hide()
	confirm_center.hide()
	screen_root.hide()
	settings_panel.open()


func _close_secondary_panels_and_flush() -> void:
	confirm_center.hide()
	main_center.show()
	if settings_panel.is_open():
		settings_panel.close()
	else:
		UserSettings.flush_pending_save()


func _set_pause_controls_disabled(disabled: bool) -> void:
	resume_button.disabled = disabled
	settings_button.disabled = disabled
	return_button.disabled = disabled
	confirm_return_button.disabled = disabled
	cancel_return_button.disabled = disabled


func _on_resume_pressed() -> void:
	request_pause(false)


func _on_settings_pressed() -> void:
	_open_settings()


func _on_return_pressed() -> void:
	_show_return_confirmation()


func _on_cancel_return_pressed() -> void:
	_show_main_menu()


func _on_confirm_return_pressed() -> void:
	if _exit_in_progress or not _exit_handler.is_valid():
		return
	_exit_in_progress = true
	_network_request_pending = false
	_set_pause_controls_disabled(true)
	var handler := _exit_handler
	# 离场清理可能需要等待公网 lease。确认层保持可处理且玩法树继续暂停，
	# 真正的恢复与场景切换由会话 handler 在网络清理完成后负责。
	UserSettings.flush_pending_save()
	handler.call()


func _on_settings_panel_closed() -> void:
	if _has_context() and _gameplay_paused and not _exit_in_progress:
		_show_main_menu()


func _on_context_owner_tree_exiting(owner_instance_id: int) -> void:
	if (
		_context_owner == null
		or not is_instance_valid(_context_owner)
		or _context_owner.get_instance_id() != owner_instance_id
	):
		return
	force_unpause_for_transition()
	_context_owner = null
	_context_owner_tree_exiting_callback = Callable()
	_exit_handler = Callable()
	_context_is_networked = false
	_context_session_id = 0
	_exit_in_progress = false
	_reset_pause_clock_after_context()


func _clear_registered_context() -> void:
	force_unpause_for_transition()
	if (
		_context_owner != null
		and is_instance_valid(_context_owner)
		and _context_owner_tree_exiting_callback.is_valid()
		and _context_owner.tree_exiting.is_connected(
			_context_owner_tree_exiting_callback
		)
	):
		_context_owner.tree_exiting.disconnect(_context_owner_tree_exiting_callback)
	_context_owner = null
	_context_owner_tree_exiting_callback = Callable()
	_exit_handler = Callable()
	_context_is_networked = false
	_context_session_id = 0
	_exit_in_progress = false
	_reset_pause_clock_after_context()


func _has_context() -> bool:
	return _context_owner != null and is_instance_valid(_context_owner)


func _update_pause_clock(paused: bool) -> void:
	if paused == _gameplay_paused:
		return
	var wall_now := _get_wall_time_seconds()
	if paused:
		_pause_wall_started_seconds = wall_now
		return
	if _pause_wall_started_seconds >= 0.0:
		_accumulated_pause_duration_seconds += maxf(
			wall_now - _pause_wall_started_seconds,
			0.0
		)
	_pause_wall_started_seconds = -1.0


func _reset_pause_clock_after_context() -> void:
	_accumulated_pause_duration_seconds = 0.0
	_pause_wall_started_seconds = -1.0


func _get_wall_time_seconds() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
