extends "res://scene/pvp/mirage_pvp.gd"
## Recording-only choreography. The scene, inventory and damage code are production.
## Targets are repositioned/reset explicitly; health reductions only come from bullets.

var demo_case := "weapons"
var demo_time := 0.0
var demo_step := 0
var demo_duration := 28.0
var demo_result_path := "res://reports/mirage_demos/2026-09-07/combat-weapons-result.json"
var demo_actions: Array[Dictionary] = []
var demo_observed: Array[Dictionary] = []
var demo_failures: Array[String] = []
var demo_aim := Vector2.UP
var demo_move := Vector2.ZERO
var demo_trial: Dictionary = {}
var demo_last_target_health := 100
var demo_finished := false
var demo_schedule: Array[Dictionary] = []

@onready var demo_panel: PanelContainer = $DemoOverlay/ActionPanel
@onready var demo_title: Label = $DemoOverlay/ActionPanel/Rows/Title
@onready var demo_action: Label = $DemoOverlay/ActionPanel/Rows/Action
@onready var demo_note: Label = $DemoOverlay/ActionPanel/Rows/Note
@onready var demo_health_panel: PanelContainer = $DemoOverlay/TargetPanel
@onready var demo_health: Label = $DemoOverlay/TargetPanel/Rows/Health
@onready var demo_target_detail: Label = $DemoOverlay/TargetPanel/Rows/Detail
@onready var demo_result_label: Label = $DemoOverlay/TargetPanel/Rows/Results

func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--case="):
			demo_case = argument.trim_prefix("--case=")
		elif argument.begins_with("--result="):
			demo_result_path = argument.trim_prefix("--result=")
	super._ready()
	get_window().size = Vector2i(1280, 720)
	get_window().content_scale_size = Vector2i(1280, 720)
	local_player.camera.position_smoothing_enabled = false
	local_player.display_name = "维什戴尔 · 演示玩家"
	local_player.name_label.text = local_player.display_name
	players[2].display_name = "固定靶 · 真实生命值"
	players[2].name_label.text = players[2].display_name
	if demo_case == "damage":
		demo_duration = 23.5
		demo_title.text = "04 / 身体命中与爆头"
		demo_schedule = [
			{"at": 0.6, "do": "open_buy"}, {"at": 1.1, "do": "buy_ak"},
			{"at": 1.8, "do": "close_buy"}, {"at": 2.1, "do": "slot2"},
			{"at": 2.5, "do": "range"}, {"at": 3.1, "do": "prepare_deagle_body"},
			{"at": 4.0, "do": "fire_trial"}, {"at": 7.4, "do": "prepare_deagle_head"},
			{"at": 9.0, "do": "fire_trial"}, {"at": 12.0, "do": "new_round_range"},
			{"at": 12.5, "do": "slot1"}, {"at": 13.0, "do": "prepare_ak_body"},
			{"at": 14.0, "do": "fire_trial"}, {"at": 17.4, "do": "prepare_ak_head"},
			{"at": 19.0, "do": "fire_trial"}, {"at": 21.0, "do": "damage_summary"},
		]
	else:
		demo_title.text = "03 / 购买、丢枪、拾取与换弹"
		demo_schedule = [
			{"at": 2.0, "do": "open_buy"}, {"at": 4.8, "do": "buy_ak"},
			{"at": 6.4, "do": "close_buy"}, {"at": 8.0, "do": "drop"},
			{"at": 10.8, "do": "pickup"}, {"at": 13.0, "do": "slot2"},
			{"at": 15.0, "do": "slot1"}, {"at": 17.0, "do": "practice_fire"},
			{"at": 17.3, "do": "practice_fire"}, {"at": 17.6, "do": "practice_fire"},
			{"at": 19.0, "do": "reload"}, {"at": 22.5, "do": "weapons_summary"},
		]
	demo_action.text = "出生自带沙漠之鹰 · 资金 $4000"
	demo_note.text = "本地演练 · 原生 HUD / 实际库存与弹药"
	demo_health_panel.visible = demo_case == "damage"
	_record("scene_ready", "Production Mirage scene, locally scripted demonstration")

func _collect_local_input(_delta: float) -> void:
	# The director supplies aim/movement through the production authority ingress.
	_input_sequence += 1
	_accept_input(_local_peer_id, _input_sequence, demo_move, demo_aim, false)
	var mouse := InputEventMouseMotion.new()
	mouse.position = get_viewport().get_canvas_transform() * (local_player.global_position + demo_aim * 136.0)
	get_viewport().push_input(mouse, true)

func _process(delta: float) -> void:
	if demo_finished or not is_node_ready():
		return
	demo_time += delta
	while demo_step < demo_schedule.size() and demo_time >= float(demo_schedule[demo_step].at):
		_execute(str(demo_schedule[demo_step].do))
		demo_step += 1
	var target: PvpPlayer = players[2]
	if target.health < demo_last_target_health:
		_observe_damage(demo_last_target_health, target.health)
	demo_last_target_health = target.health
	demo_panel.visible = not hud.is_buy_open()
	demo_health_panel.visible = demo_case == "damage" and not hud.is_buy_open() and demo_time >= 2.5
	demo_health.text = "%d / 100" % target.health
	if not demo_trial.is_empty():
		demo_target_detail.text = "%s · %s" % ["沙漠之鹰" if demo_trial.weapon == "deagle" else "AK-47", "瞄准头部" if demo_trial.headshot else "瞄准身体"]
	if demo_time >= demo_duration:
		_finish_demo()

func _execute(action: String) -> void:
	match action:
		"open_buy":
			_key(KEY_B)
			demo_action.text = "B：打开购买面板"
		"buy_ak":
			_click_button(hud.get_node("%BuyAK") as Button)
		"close_buy":
			_key(KEY_B)
			demo_action.text = "AK-47 已购买 · 余额来自实际经济系统"
			_expect(local_player.loadout.has("ak") and local_player.money == 1300, "AK purchase is authoritative: $4000 - $2700 = $1300")
		"drop":
			_key(KEY_G)
			demo_action.text = "G：丢出手中 AK-47"
			demo_note.text = "掉落物保留真实弹匣与备弹 · 枪就在脚边"
		"pickup":
			_expect(not local_player.loadout.has("ak") and pickups.size() == 1, "G created one actual dropped AK")
			_key(KEY_F)
			demo_action.text = "F：拾回地上的 AK-47"
			demo_note.text = "拾取走实际距离 / 遮挡 / 库存校验"
		"slot1":
			_key(KEY_1)
			demo_action.text = "1：切换主武器 AK-47"
		"slot2":
			_key(KEY_2)
			demo_action.text = "2：切换副武器沙漠之鹰"
			if demo_case == "weapons":
				_expect(local_player.loadout.has("ak") and pickups.is_empty(), "F restored the dropped AK exactly once")
		"practice_fire":
			demo_action.text = "实际开火三次：观察弹匣 30 → 27"
			_expect(_try_fire(local_player), "Practice shot accepted by production weapon cooldown/ammo rules")
		"reload":
			_expect(local_player.ammo == 27, "Three real shots consumed three cartridges")
			_key(KEY_R)
			demo_action.text = "R：换弹，弹药从备弹转入弹匣"
			demo_note.text = "等待真实 2.2 秒换弹计时 · 观察 27 / 90 → 30 / 87"
		"weapons_summary":
			_expect(local_player.ammo == 30 and local_player.reserve == 87 and local_player.money == 1300, "Reload finished with 30 / 87, money remains $1300")
			demo_action.text = "操作完成：$%d · AK %d / %d" % [local_player.money, local_player.ammo, local_player.reserve]
			demo_note.text = "B 购买 → G 丢出 → F 拾取 → 1 / 2 切换 → R 换弹"
		"range":
			_setup_range()
		"new_round_range":
			_start_round()
			_setup_range()
			demo_action.text = "新一轮固定靶演练 · 切换 AK-47"
		"prepare_deagle_body":
			_prepare_trial("deagle", false)
		"prepare_deagle_head":
			_prepare_trial("deagle", true)
		"prepare_ak_body":
			_prepare_trial("ak", false)
		"prepare_ak_head":
			_prepare_trial("ak", true)
		"fire_trial":
			_expect(local_player.current_weapon == str(demo_trial.weapon), "Trial uses requested actual equipped weapon")
			_expect(_try_fire(local_player), "Damage trial launched a production swept projectile")
		"damage_summary":
			_expect(demo_observed.size() == 4, "Four physical hit trials completed")
			demo_action.text = "四次命中均由实际物理射线结算"
			demo_note.text = "沙鹰：身体 25 / 爆头 100　　AK：身体 20 / 爆头 100"
	_record(action, demo_action.text)

func _setup_range() -> void:
	# Recording fixture only: move the existing two production players to clear Mid.
	phase = "live"
	phase_time_left = Rules.ROUND_SECONDS
	local_player.global_position = Vector2(1056, 820)
	local_player.network_position = local_player.global_position
	players[2].reset_round(Vector2(1192, 817))
	local_player.camera.global_position = local_player.global_position
	local_player.camera.reset_smoothing()
	demo_last_target_health = players[2].health
	demo_note.text = "脚本布置固定靶；生命值仅由真实子弹扣除"
	hud.show_banner("固定靶演练", "已跳过冻结时间 · 目标生命值由真实命中扣除")

func _prepare_trial(weapon: String, headshot: bool) -> void:
	players[2].reset_round(Vector2(1192, 817))
	demo_last_target_health = players[2].health
	demo_trial = {"weapon": weapon, "headshot": headshot, "before": players[2].health,
		"expected_damage": Rules.damage(weapon, headshot)}
	var hit_point: Vector2 = players[2].head_hitbox.global_position if headshot else players[2].body_hitbox.global_position
	demo_aim = (hit_point - local_player.global_position - Vector2(0, -1)).normalized()
	local_player.aim_direction = demo_aim
	demo_action.text = "%s · %s测试" % ["沙漠之鹰" if weapon == "deagle" else "AK-47", "爆头" if headshot else "身体命中"]
	demo_note.text = "新靶重置到 100 HP，画面数字读取 target.health"

func _observe_damage(before: int, after: int) -> void:
	var observed := demo_trial.duplicate(true)
	observed["at_seconds"] = snappedf(demo_time, 0.001)
	observed["health_before"] = before
	observed["health_after"] = after
	observed["observed_damage"] = before - after
	demo_observed.append(observed)
	_expect(before - after == int(demo_trial.expected_damage), "Observed health delta equals weapon damage for this physical hitbox")
	demo_action.text = "实测：%d → %d HP（-%d）" % [before, after, before - after]
	var results: PackedStringArray = []
	for result: Dictionary in demo_observed:
		results.append("%s%s：%d → %d" % ["沙鹰" if result.weapon == "deagle" else "AK", "爆头" if result.headshot else "身体", result.health_before, result.health_after])
	demo_result_label.text = "\n".join(results)

func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	get_viewport().push_input(event)
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	get_viewport().push_input(release)

func _click_button(button: Button) -> void:
	_expect(button.is_visible_in_tree() and not button.disabled, "Actual HUD purchase button is visible and enabled")
	var press := InputEventMouseButton.new()
	press.position = button.get_global_rect().get_center()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	get_viewport().push_input(press, true)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	get_viewport().push_input(release, true)

func _record(action: String, description: String) -> void:
	demo_actions.append({"at_seconds": snappedf(demo_time, 0.001), "action": action,
		"description": description, "weapon": local_player.current_weapon,
		"money": local_player.money, "ammo": local_player.ammo, "reserve": local_player.reserve,
		"dropped_weapons": pickups.size(), "target_health": players[2].health})

func _expect(condition: bool, description: String) -> void:
	if not condition:
		demo_failures.append(description)
		push_error("COMBAT_DEMO: " + description)

func _finish_demo() -> void:
	demo_finished = true
	var result := {"case": demo_case, "duration_seconds": demo_time,
		"scene": "res://scene/pvp/mirage_pvp.tscn", "runtime_viewport": [1280, 720],
		"movie_output_note": "Actual encoded dimensions are measured with ffprobe; MovieMaker may initialize at UserSettings size before this scene sets its viewport.",
		"character": "weishidaier", "bullet_speed": Rules.BULLET_SPEED,
		"ak_price": Rules.AK_PRICE, "actions": demo_actions, "observed_damage": demo_observed,
		"final_inventory": local_player.serialize(), "failures": demo_failures,
		"fixture_disclosure": "Local recording choreography repositions/reset existing targets and starts rounds. Input uses native B/G/F/R/1/2 key events and actual HUD mouse clicks. Production request_action, authority_tick, _try_fire and PhysicsDirectSpaceState2D projectile sweeps execute all outcomes. No health reduction is scripted."}
	var output := FileAccess.open(demo_result_path, FileAccess.WRITE)
	assert(output != null, "Demo result directory must exist before recording")
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print("COMBAT_DEMO_%s: %d actions, %d actual hits, %d failures" % [demo_case.to_upper(), demo_actions.size(), demo_observed.size(), demo_failures.size()])
	get_tree().quit(0 if demo_failures.is_empty() else 1)
