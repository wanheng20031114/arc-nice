extends "res://scene/pvp/mirage_pvp.gd"
## Capture-only input driver. Production movement, physics, map and vision remain active.

const DEMO_SECONDS: float = 25.0
const START_POSITION := Vector2(1000, 1225)
const CORNER_POSITION := Vector2(1160, 1225)
const REVEALED_POSITION := Vector2(1160, 1325)
const TARGET_POSITION := Vector2(1120, 1335)
const REPORT_PATH := "res://reports/mirage_demos/2026-09-07/demo-vision.json"

@onready var demo_stage: Label = $CaptureLabels/Panel/Stage
@onready var demo_status: Label = $CaptureLabels/Panel/Status
@onready var demo_elapsed: Label = $CaptureLabels/Panel/Elapsed

var _demo_elapsed: float = 0.0
var _sample_at: float = 0.0
var _ray_blocked: bool = false
var _ray_collider: String = ""
var _samples: Array[Dictionary] = []
var _transitions: Array[Dictionary] = []
var _last_visible: bool = false
var _recorded_initial: bool = false
var _finished: bool = false
var _demo_enemy: PvpPlayer


func _ready() -> void:
	super._ready()
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 720)
	get_window().content_scale_size = Vector2i(1280, 720)
	get_window().position = Vector2i(-1700, -1000)
	process_priority = 200
	_demo_enemy = players[2]
	# The only positional placement: an explicitly disclosed initial training setup.
	local_player.reset_round(START_POSITION)
	_demo_enemy.reset_round(TARGET_POSITION)
	local_player.camera.reset_smoothing()
	phase = "live"
	phase_time_left = Rules.ROUND_SECONDS
	_message = "起始位置预设 · 脚本输入演练"
	hud.show_banner("05 · 真实障碍视野", "A 点预设起始位置 · 跳过购买阶段 · 单机训练靶")
	_refresh_hud()


func _physics_process(delta: float) -> void:
	if _finished:
		return
	_demo_elapsed += delta
	super._physics_process(delta)
	# Read the same physics layer as production visibility; never write visibility.
	var query := PhysicsRayQueryParameters2D.create(local_player.global_position, _demo_enemy.global_position, 1)
	query.collide_with_areas = false
	query.hit_from_inside = true
	var collision: Dictionary = get_world_2d().direct_space_state.intersect_ray(query)
	_ray_blocked = not collision.is_empty()
	_ray_collider = str((collision["collider"] as Node).get_path()) if _ray_blocked else ""


func _collect_local_input(delta: float) -> void:
	var target: Vector2 = _target_for_time()
	var remaining: Vector2 = target - local_player.global_position
	var movement := Vector2.ZERO
	if remaining.length() > 0.25:
		movement = remaining.normalized() * minf(0.5, remaining.length() / (Rules.MOVE_SPEED * delta))
	var aim: Vector2 = local_player.global_position.direction_to(_demo_enemy.global_position)
	_input_sequence += 1
	# Production input queue -> authority_tick -> move_and_slide, every physics tick.
	_accept_input(_local_peer_id, _input_sequence, movement, aim, false)


func _target_for_time() -> Vector2:
	if _demo_elapsed < 4.0:
		return START_POSITION
	if _demo_elapsed < 8.0:
		return CORNER_POSITION
	if _demo_elapsed < 14.0:
		return REVEALED_POSITION
	if _demo_elapsed < 17.0:
		return CORNER_POSITION
	return START_POSITION


func _stage_for_time() -> String:
	if _demo_elapsed < 4.0:
		return "① Default 箱后：停留观察"
	if _demo_elapsed < 8.0:
		return "② 沿箱子上侧移动，绕过右角"
	if _demo_elapsed < 11.0:
		return "③ 继续沿右侧靠近训练靶"
	if _demo_elapsed < 14.0:
		return "④ 视线畅通：敌人与名字出现"
	if _demo_elapsed < 21.0:
		return "⑤ 原路返回，观察遮挡恢复"
	return "⑥ 再次回到箱后：敌人隐藏"


func _process(_delta: float) -> void:
	if _finished or _demo_elapsed <= 0.0:
		return
	# This process runs after the production visibility process (priority 100).
	var enemy_visible: bool = _demo_enemy.visible
	demo_stage.text = _stage_for_time()
	demo_status.text = "敌人节点 visible = %s\n物理射线：%s" % [str(enemy_visible), "命中障碍" if _ray_blocked else "无遮挡"]
	demo_status.modulate = Color(0.77, 0.88, 0.94) if enemy_visible else Color(0.93, 0.77, 0.48)
	demo_elapsed.text = "%04.1f / 25.0 秒 · 原版视野控制器" % _demo_elapsed
	if not _recorded_initial or enemy_visible != _last_visible:
		_transitions.append(_sample())
		_last_visible = enemy_visible
		_recorded_initial = true
	if _demo_elapsed >= _sample_at:
		_samples.append(_sample())
		_sample_at += 0.25
	if _demo_elapsed >= DEMO_SECONDS:
		_finished = true
		_finish_capture.call_deferred()


func _sample() -> Dictionary:
	return {
		"time_seconds": snappedf(_demo_elapsed, 0.001),
		"stage": _stage_for_time(),
		"local_position": [local_player.global_position.x, local_player.global_position.y],
		"enemy_position": [_demo_enemy.global_position.x, _demo_enemy.global_position.y],
		"enemy_visible": _demo_enemy.visible,
		"ray_blocked": _ray_blocked,
		"ray_collider": _ray_collider,
	}


func _finish_capture() -> void:
	var report: Dictionary = {
		"demo": "05-visibility",
		"production_scene": "res://scene/pvp/mirage_pvp.tscn",
		"duration_seconds": _demo_elapsed,
		"renderer": RenderingServer.get_current_rendering_method(),
		"window_size": [get_window().size.x, get_window().size.y],
		"disclosure": [
			"Offline single-machine training scene, not a network multiplayer capture.",
			"Only starting player positions are preset; purchase is skipped to enter the live phase.",
			"Scripted movement is submitted through the real host input queue at half stick strength.",
			"Production authority_tick and move_and_slide perform every subsequent movement.",
			"Enemy visible, shadow mask, map artwork, collision and normal HUD are not overridden.",
		],
		"initial_local_position": [START_POSITION.x, START_POSITION.y],
		"initial_enemy_position": [TARGET_POSITION.x, TARGET_POSITION.y],
		"transitions": _transitions,
		"samples": _samples,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_PATH.get_base_dir()))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("VISION_DEMO_COMPLETE ", JSON.stringify(_transitions))
	get_tree().quit()
