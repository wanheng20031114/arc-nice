extends "res://scene/pvp/mirage_pvp.gd"
## Replays audited defects through the unchanged production movement/collision.

var demo_move := Vector2.ZERO
var events: Array[Dictionary] = []
@onready var title_label: Label = $CaptureLabels/Panel/Title
@onready var detail_label: Label = $CaptureLabels/Panel/Detail
@onready var readout: Label = $CaptureLabels/Readout

func _ready() -> void:
	super._ready()
	get_window().size = Vector2i(1280, 720)
	get_window().content_scale_size = Vector2i(1280, 720)
	get_window().position = Vector2i(-1700, -1000)
	local_player.camera.position_smoothing_enabled = false
	phase = "live"
	phase_time_left = 90.0
	_run_demo.call_deferred()

func _collect_local_input(_delta: float) -> void:
	_input_sequence += 1
	_accept_input(_local_peer_id, _input_sequence, demo_move, Vector2.RIGHT, false)

func _process(_delta: float) -> void:
	if not is_instance_valid(local_player):
		return
	readout.text = "实际角色坐标  (%0.1f, %0.1f)   |   移动输入 %s" % [local_player.position.x, local_player.position.y, "D →" if demo_move == Vector2.RIGHT else "S ↓" if demo_move == Vector2.DOWN else "停止"]

func _place_at(position: Vector2) -> void:
	demo_move = Vector2.ZERO
	local_player.global_position = position
	local_player.network_position = position
	local_player.camera.global_position = position
	local_player.camera.reset_smoothing()
	_refresh_hud()

func _run_demo() -> void:
	await get_tree().physics_frame
	_place_at(Vector2(1380, 1136))
	title_label.text = "问题复现 1 / A1 门拱堵路"
	detail_label.text = "本地自动操作 · 布置起点后，仅通过真实移动碰撞前进"
	await get_tree().create_timer(3.0).timeout
	demo_move = Vector2.RIGHT
	await get_tree().create_timer(2.0).timeout
	events.append({"event": "A1_right_input_blocked", "x": local_player.position.x, "y": local_player.position.y})
	assert(local_player.position.x < 1429.6)
	detail_label.text = "持续向右输入，角色停在门柱前；尝试从下沿绕过"
	demo_move = Vector2.DOWN
	await get_tree().create_timer(0.42).timeout
	demo_move = Vector2.RIGHT
	await get_tree().create_timer(2.0).timeout
	demo_move = Vector2.ZERO
	assert(local_player.position.x < 1429.6)
	events.append({"event": "A1_lower_gap_blocked", "x": local_player.position.x, "y": local_player.position.y})
	detail_label.text = "下沿净空 11.4 px，角色直径 14 px；实际无法穿过"
	await get_tree().create_timer(2.5).timeout
	_place_at(Vector2(540, 820.6))
	title_label.text = "问题复现 2 / 超市 → VIP → 中路"
	detail_label.text = "切换演示起点 · 现有碰撞允许一条额外的横向直通路线"
	await get_tree().create_timer(2.5).timeout
	demo_move = Vector2.RIGHT
	await get_tree().create_timer(5.28).timeout
	demo_move = Vector2.ZERO
	events.append({"event": "market_to_mid_unintended_route", "x": local_player.position.x, "y": local_player.position.y, "target_x": 1068.0})
	assert(local_player.position.x > 1050.0)
	detail_label.text = "实际连续走过约 528 px；这条错误贯通尚未修复"
	await get_tree().create_timer(3.0).timeout
	var file := FileAccess.open("res://reports/mirage_demos/2026-09-07/demo-issues.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"kind": "scripted actual-game defect reproduction", "staging": "Only initial player positions are set. Motion uses production authoritative input and move_and_slide; map, collision and visibility unchanged.", "events": events}, "\t"))
	file.close()
	print("ISSUES_DEMO_COMPLETE: ", events)
	get_tree().quit()
