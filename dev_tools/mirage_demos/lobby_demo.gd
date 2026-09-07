extends Node

## Automated capture only. All room widgets, roster and match HUD are production scenes.
const OUT := "res://reports/mirage_demos/2026-09-07/"
const PORT := 48981
var role := "host"
var elapsed := 0.0
var finishing := false
var events: Array[Dictionary] = []
var failures: Array[String] = []
var wall_start := 0
@onready var lobby: Control = get_parent()
@onready var net: NetManagerStore = NetManagerStore.get_autoload_instance()
@onready var caption: Label = $DemoOverlay/Panel/Rows/Caption
@onready var panel: PanelContainer = $DemoOverlay/Panel

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
	wall_start = Time.get_ticks_msec()
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 720)
	get_window().content_scale_size = Vector2i(1280, 720)
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_node("/root/GameLoadCoordinator").loading_failed.connect(_fail)
	net.connection_failed.connect(_fail)
	_start.call_deferred()

func _process(delta: float) -> void:
	elapsed += delta
	if not finishing and (Time.get_ticks_msec() - wall_start > 150000 or (role == "host" and elapsed > 42.0)):
		_fail("演示等待超时")

func _start() -> void:
	# Only move this button-free annotation/controller. The real lobby stays the scene root.
	reparent(get_tree().root)
	lobby.username_input.text = "演示房主" if role == "host" else "演示队员"
	lobby.username_confirm_btn.pressed.emit()
	lobby.lan_mode_button.pressed.emit()
	lobby.port_spin.value = PORT
	lobby.max_players_spin.value = 4
	if role == "host":
		await _run_host()
	else:
		$DemoOverlay.hide()
		await _run_client()

func _run_host() -> void:
	for index in range(lobby.game_mode_selector.item_count):
		if lobby.game_mode_selector.get_item_id(index) == 9:
			lobby.game_mode_selector.select(index)
			lobby.game_mode_selector.item_selected.emit(index)
	lobby.host_button.pressed.emit()
	_record("host_created_by_production_button")
	_write_marker("host-ready")
	caption.text = "两端真实 LAN 连接\n等待第二位玩家加入房间"
	if not await _until(func() -> bool: return net.connected_players.size() == 2): return
	_record("two_real_peers_registered")
	caption.text = "两位玩家均固定为维什戴尔\n未选队时，开始按钮不可用"
	if not lobby.start_game_btn.disabled: _fail("未选队时开始按钮没有禁用"); return
	await _hold(4.0)
	lobby.ct_team_btn.pressed.emit()
	_record("host_clicked_CT")
	caption.text = "房主点击 CT\n名单由主机成员账本同步"
	await _hold(4.0)
	_write_marker("choose-t")
	if not await _until(func() -> bool: return net.are_pvp_teams_ready()): return
	await get_tree().process_frame
	_record("client_clicked_T_roster_confirmed")
	caption.text = "另一进程点击 T\n双方各一人，开始按钮已可用"
	if lobby.start_game_btn.disabled: _fail("双方就绪后开始按钮仍禁用"); return
	await _hold(5.0)
	lobby.start_game_btn.pressed.emit()
	_record("host_clicked_start")
	caption.text = "通过正式加载器进入 Mirage\n等待两端完成加载屏障"
	if not await _until(_match_ready): return
	panel.position = Vector2(24, 480)
	_record("production_match_IN_GAME")
	caption.text = "两端已进入实际对局\n100 生命 · 自带沙漠之鹰"
	await _hold(6.0)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_TAB
	key.pressed = true
	Input.parse_input_event(key)
	caption.text = "自动按住 Tab\n实际比分面板显示 CT / T 名单"
	_record("TAB_scoreboard_open")
	await _hold(4.0)
	key = InputEventKey.new()
	key.physical_keycode = KEY_TAB
	key.pressed = false
	Input.parse_input_event(key)
	caption.text = "选队 → 开局流程演示完成\n自动操作；并非真人操作录像"
	await _hold(3.0)
	_finish()

func _run_client() -> void:
	if not await _until(func() -> bool: return FileAccess.file_exists(OUT + "lobby-host-ready.signal")): return
	lobby.join_ip_input.text = "127.0.0.1"
	lobby.join_button.pressed.emit()
	if not await _until(func() -> bool: return net.connection_state == NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY): return
	_record("client_registered_via_production_join_button")
	if not await _until(func() -> bool: return FileAccess.file_exists(OUT + "lobby-choose-t.signal")): return
	lobby.t_team_btn.pressed.emit()
	_record("client_clicked_production_T_button")
	if not await _until(_match_ready): return
	_record("client_production_match_IN_GAME")
	if not await _until(func() -> bool: return FileAccess.file_exists(OUT + "lobby-finished.signal")): return
	_finish()

func _match_ready() -> bool:
	return (get_tree().current_scene is MiragePvp
		and net.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and not get_node("/root/GameLoadCoordinator").is_loading())

func _until(predicate: Callable) -> bool:
	while not finishing:
		if predicate.call(): return true
		await get_tree().process_frame
	return false

func _hold(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

func _write_marker(name: String) -> void:
	var file := FileAccess.open(OUT + "lobby-" + name + ".signal", FileAccess.WRITE)
	file.store_string(str(Time.get_ticks_msec()))

func _record(event: String) -> void:
	var roster: Array[Dictionary] = []
	for raw_peer_id in net.connected_players:
		var id := int(raw_peer_id)
		roster.append({"peer_id": id, "name": net.get_player_name_by_id(id),
			"team": net.get_player_team(id), "character": str(net.get_player_character_id(id))})
	var entry := {"event": event, "video_seconds": snappedf(elapsed, 0.001),
		"wall_elapsed_ms": Time.get_ticks_msec() - wall_start,
		"state": int(net.connection_state), "local_peer_id": net.get_local_peer_id(),
		"session_id": net.get_game_session_incarnation(), "roster": roster}
	events.append(entry)
	print("LOBBY_DEMO_", role.to_upper(), ": ", JSON.stringify(entry))

func _fail(message: String) -> void:
	if finishing: return
	if role == "client" and FileAccess.file_exists(OUT + "lobby-finished.signal"):
		_finish.call_deferred()
		return
	failures.append(message)
	push_error("LOBBY_DEMO: " + message)
	_finish.call_deferred()

func _finish() -> void:
	if finishing: return
	finishing = true
	_record("capture_finished")
	var report := {"title": "01 双进程 LAN：CT/T 选队至实战 HUD", "role": role,
		"automated": true, "production_lobby": "res://scene/multiplayer/multiplayer_lobby.tscn",
		"production_loader": "GameLoadCoordinator", "network": "Two Godot processes, ENet 127.0.0.1:%d" % PORT,
		"protocol": NetManagerStore.NetConstants.PROTOCOL_VERSION,
		"events": events, "failures": failures, "video_simulation_seconds": elapsed,
		"limitations": ["自动点击正式按钮与注入 Tab 输入；并非真人操作录像。", "本机双进程真实 LAN 回环，不代表互联网或公网部署验证。", "Godot Movie Maker 固定 30 fps 离线采帧；模拟时间和实际墙钟时间可能不同。", "只有房主画面被录制；另一端无头运行正式大厅和对局。", "字幕是演示标注；玩家名单、队伍与比分均来自生产场景和真实网络状态。", "当前地图复刻质量问题仍在，参见 mirage_fidelity_audit.md。"]}
	var name := "demo-lobby.json" if role == "host" else "demo-lobby-client.json"
	var file := FileAccess.open(OUT + name, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	if role == "host": _write_marker("finished")
	net.disconnect_from_game()
	get_tree().quit(0 if failures.is_empty() else 1)
