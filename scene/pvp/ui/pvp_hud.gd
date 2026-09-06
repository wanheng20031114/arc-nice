class_name PvpHUD
extends CanvasLayer

signal buy_ak_requested
signal leave_requested
signal buy_menu_toggled(opened: bool)

const CT_COLOR := Color("79c9ef")
const T_COLOR := Color("e2b86d")
const TEXT_COLOR := Color("eee9de")

@onready var ct_score: Label = %CTScore
@onready var t_score: Label = %TScore
@onready var clock_label: Label = %Clock
@onready var phase_label: Label = %Phase
@onready var round_label: Label = %Round
@onready var ct_alive: Label = %CTAlive
@onready var t_alive: Label = %TAlive
@onready var callout_label: Label = %Callout
@onready var team_label: Label = %Team
@onready var health_label: Label = %Health
@onready var money_label: Label = %Money
@onready var weapon_label: Label = %Weapon
@onready var ammo_label: Label = %Ammo
@onready var slots_label: Label = %Slots
@onready var status_label: Label = %Status
@onready var pickup_label: Label = %Pickup
@onready var buy_overlay: Control = %BuyOverlay
@onready var buy_button: Button = %BuyAK
@onready var buy_status: Label = %BuyStatus
@onready var buy_money: Label = %BuyMoney
@onready var buy_team: Label = %BuyTeam
@onready var scoreboard: Control = %Scoreboard
@onready var ct_roster: RichTextLabel = %CTRoster
@onready var t_roster: RichTextLabel = %TRoster
@onready var leave_overlay: Control = %LeaveOverlay
@onready var end_overlay: Control = %EndOverlay
@onready var banner: PanelContainer = %Banner
@onready var banner_title: Label = %BannerTitle
@onready var banner_detail: Label = %BannerDetail
@onready var kill_labels: Array[Label] = [%Kill0, %Kill1, %Kill2, %Kill3]

var _state: Dictionary = {}
var _kill_entries: Array[Dictionary] = []
var _buy_tween: Tween
var _banner_tween: Tween
var _last_phase := ""


func _ready() -> void:
	buy_overlay.hide()
	scoreboard.hide()
	leave_overlay.hide()
	end_overlay.hide()
	banner.hide()
	%CloseBuy.pressed.connect(func() -> void: set_buy_open(false))
	buy_button.pressed.connect(func() -> void: buy_ak_requested.emit())
	%Continue.pressed.connect(func() -> void: _set_leave_open(false))
	%Leave.pressed.connect(func() -> void: leave_requested.emit())
	%ReturnToLobby.pressed.connect(func() -> void: leave_requested.emit())
	for label: Label in kill_labels:
		label.hide()


func _process(delta: float) -> void:
	var can_aim: bool = not _state.is_empty() and not _state["local_player"].is_empty() and bool(_state["local_player"]["alive"])
	can_aim = can_aim and not buy_overlay.visible and not scoreboard.visible and not leave_overlay.visible and not end_overlay.visible
	%Crosshair.visible = can_aim
	%Crosshair.position = get_viewport().get_mouse_position()
	var mouse_mode := Input.MOUSE_MODE_HIDDEN if can_aim else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != mouse_mode:
		Input.mouse_mode = mouse_mode
	for entry: Dictionary in _kill_entries:
		entry["remaining"] -= delta
	while not _kill_entries.is_empty() and float(_kill_entries[0]["remaining"]) <= 0.0:
		_kill_entries.pop_front()
	_render_kill_feed()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or event.echo:
		return
	if event.physical_keycode == KEY_TAB:
		scoreboard.visible = event.pressed and not buy_overlay.visible and not end_overlay.visible
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_ESCAPE and event.pressed:
		if end_overlay.visible:
			return
		if is_buy_open():
			set_buy_open(false)
		else:
			_set_leave_open(not leave_overlay.visible)
		get_viewport().set_input_as_handled()


func is_buy_open() -> bool:
	return buy_overlay.visible


func set_map(map: Node2D) -> void:
	%Minimap.set_map(map)


func set_buy_open(opened: bool) -> void:
	if opened and end_overlay.visible:
		return
	if _buy_tween and _buy_tween.is_running():
		_buy_tween.kill()
	buy_overlay.visible = opened
	if opened:
		leave_overlay.hide()
		scoreboard.hide()
		buy_overlay.modulate.a = 0.0
		_buy_tween = create_tween()
		_buy_tween.tween_property(buy_overlay, "modulate:a", 1.0, 0.16)
		_refresh_buy_panel()
	buy_menu_toggled.emit(opened or leave_overlay.visible)


func _set_leave_open(opened: bool) -> void:
	leave_overlay.visible = opened
	if opened:
		scoreboard.hide()
	buy_menu_toggled.emit(opened or buy_overlay.visible)


func update_match_state(state: Dictionary) -> void:
	_state = state
	var local: Dictionary = state["local_player"]
	var phase: String = state["phase"]
	var scores: Dictionary = state["scores"]
	var seconds := maxi(0, ceili(float(state["phase_time_left"])))
	ct_score.text = str(scores["CT"])
	t_score.text = str(scores["T"])
	clock_label.text = "%02d:%02d" % [seconds / 60, seconds % 60]
	clock_label.modulate = T_COLOR if seconds <= 10 and phase == "live" else TEXT_COLOR
	round_label.text = "第 %02d 回合   /   先赢 7 回合" % int(state["round_number"])
	phase_label.text = {"loading": "等待玩家", "buy": "冻结 · 购买", "live": "交战中", "round_end": "回合结束", "match_end": "比赛结束"}[phase]
	callout_label.text = state["callout"]
	if local.is_empty():
		status_label.text = "等待玩家进入地图…"
		buy_button.disabled = true
		if phase == "match_end":
			_show_match_end(state["winner_team"], scores, "")
		return
	var team: String = local["team"]
	team_label.text = "%s  /  %s" % [team, "反恐精英" if team == "CT" else "恐怖分子"]
	team_label.modulate = CT_COLOR if team == "CT" else T_COLOR
	health_label.text = "%03d" % int(local["health"])
	health_label.modulate = Color("ed826c") if int(local["health"]) <= 25 else TEXT_COLOR
	money_label.text = "$ %s" % _format_money(int(local["money"]))
	var weapon: String = local["current_weapon"]
	weapon_label.text = _weapon_name(weapon)
	ammo_label.text = "%02d  /  %03d" % [int(local["ammo"]), int(local["reserve"])] if weapon != "empty" else "—  /  —"
	var loadout: Dictionary = local["loadout"]
	slots_label.text = "1  %s     2  %s" % ["AK-47" if loadout.has("ak") else "空", "沙漠之鹰" if loadout.has("deagle") else "空"]
	if not local["alive"]:
		status_label.text = "已阵亡  ·  观战存活队友"
	elif local["reloading"]:
		status_label.text = "换弹中…"
	elif phase == "buy":
		status_label.text = "冻结购买时间  ·  B 打开武器库"
	else:
		status_label.text = ""
	var nearby: String = state["nearby_weapon"]
	pickup_label.text = "F  拾取 %s" % _weapon_name(nearby) if not nearby.is_empty() and local["alive"] else ""
	_update_roster(state["players"])
	%Minimap.update_players(state["players"], int(state["local_peer_id"]), team)
	if phase != _last_phase:
		if phase == "live":
			set_buy_open(false)
		elif phase == "match_end":
			set_buy_open(false)
			_set_leave_open(false)
			_show_match_end(state["winner_team"], scores, team)
		_last_phase = phase
	if buy_overlay.visible:
		_refresh_buy_panel()


func _refresh_buy_panel() -> void:
	if _state.is_empty():
		return
	var local: Dictionary = _state["local_player"]
	if local.is_empty():
		buy_button.disabled = true
		buy_status.text = "等待玩家进入地图…"
		return
	buy_money.text = "$ %s" % _format_money(int(local["money"]))
	buy_team.text = "%s  /  维什戴尔" % local["team"]
	buy_team.modulate = CT_COLOR if local["team"] == "CT" else T_COLOR
	var owned: bool = local["loadout"].has("ak")
	var permitted: bool = _state["buy_allowed"] and local["alive"]
	var affordable := int(local["money"]) >= 2700
	buy_button.disabled = not permitted or not affordable or owned
	buy_button.text = "已持有 AK-47" if owned else "购买 AK-47    $ 2,700"
	if not local["alive"]:
		buy_status.text = "阵亡后无法购买，下一回合重新装备。"
	elif _state["phase"] != "buy":
		buy_status.text = "购买时间已结束。下一回合可在出生区购买。"
	elif not permitted:
		buy_status.text = "返回己方出生区后可购买。"
	elif owned:
		buy_status.text = "AK-47 已在主武器槽。按 1 切换，G 丢出。"
	elif not affordable:
		buy_status.text = "余额不足，还需 $ %s。" % _format_money(2700 - int(local["money"]))
	else:
		buy_status.text = "可购买  ·  本回合冻结时间剩余 %d 秒" % ceili(float(_state["phase_time_left"]))


func _update_roster(players: Array) -> void:
	var ct_rows := "[table=3][cell]队员[/cell][cell]击杀[/cell][cell]阵亡[/cell]"
	var t_rows := ct_rows
	var living := {"CT": 0, "T": 0}
	var totals := {"CT": 0, "T": 0}
	for player: Dictionary in players:
		var team: String = player["team"]
		totals[team] += 1
		if player["alive"]:
			living[team] += 1
		var display_name: String = player["display_name"]
		display_name = display_name.replace("[", "[lb]")
		var color := "eee9de" if player["alive"] else "74817e"
		var marker := "●" if player["alive"] else "×"
		var row := "[cell expand=1][color=#%s]%s  %s[/color][/cell][cell]%s[/cell][cell]%s[/cell]" % [color, marker, display_name, player["kills"], player["deaths"]]
		if team == "CT":
			ct_rows += row
		else:
			t_rows += row
	ct_roster.text = ct_rows + "[/table]"
	t_roster.text = t_rows + "[/table]"
	ct_alive.text = "CT  %d/%d 存活" % [living["CT"], totals["CT"]]
	t_alive.text = "T  %d/%d 存活" % [living["T"], totals["T"]]


func add_kill_feed(killer_name: String, victim_name: String, weapon: String, headshot: bool) -> void:
	_kill_entries.append({"text": "%s  ›  %s  %s  ›  %s" % [killer_name, _weapon_name(weapon), "爆头" if headshot else "", victim_name], "remaining": 6.0})
	if _kill_entries.size() > kill_labels.size():
		_kill_entries.pop_front()
	_render_kill_feed()


func _render_kill_feed() -> void:
	for index: int in kill_labels.size():
		var label: Label = kill_labels[index]
		label.visible = index < _kill_entries.size()
		if label.visible:
			label.text = _kill_entries[index]["text"]
			label.modulate.a = clampf(float(_kill_entries[index]["remaining"]) / 0.6, 0.0, 1.0)


func show_banner(title: String, detail: String = "") -> void:
	if _banner_tween and _banner_tween.is_running():
		_banner_tween.kill()
	banner_title.text = title
	banner_detail.text = detail
	banner.modulate.a = 0.0
	banner.show()
	_banner_tween = create_tween()
	_banner_tween.tween_property(banner, "modulate:a", 1.0, 0.18)
	_banner_tween.tween_interval(3.0)
	_banner_tween.tween_property(banner, "modulate:a", 0.0, 0.35)
	_banner_tween.tween_callback(banner.hide)


func _show_match_end(winner: String, scores: Dictionary, local_team: String) -> void:
	end_overlay.show()
	%EndTitle.text = "胜利" if winner == local_team and not winner.is_empty() else "比赛结束"
	%EndTitle.modulate = CT_COLOR if winner == "CT" else T_COLOR
	%EndDetail.text = "%s 赢得荒漠迷城" % winner if not winner.is_empty() else "比赛已结束，可返回大厅重新加入。"
	%EndScore.text = "CT   %s   :   %s   T" % [scores["CT"], scores["T"]]
	buy_menu_toggled.emit(true)


static func _weapon_name(weapon: String) -> String:
	match weapon:
		"deagle": return "沙漠之鹰"
		"ak": return "AK-47"
		_: return "空手"


static func _format_money(amount: int) -> String:
	return "%d,%03d" % [amount / 1000, amount % 1000] if amount >= 1000 else str(amount)
