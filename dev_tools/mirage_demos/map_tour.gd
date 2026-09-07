extends Node2D
## Scripted observation camera over the unchanged production map scene.

@onready var camera: Camera2D = $Camera
@onready var heading: Label = $CaptureLabels/Panel/Title
@onready var detail: Label = $CaptureLabels/Panel/Detail

func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	get_window().content_scale_size = Vector2i(1280, 720)
	get_window().position = Vector2i(-1700, -1000)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	_run.call_deferred()

func _run() -> void:
	await get_tree().create_timer(2.8).timeout
	await _visit("B 点与公寓", "白车、箱体、超市入口及当前建筑轮廓", Vector2(560, 535), 1.28, 3.0, 2.8)
	await _visit("中路 / VIP / 猫道", "实际场景镜头 · 可观察现有通路与贴图重复", Vector2(1070, 820), 1.4, 3.0, 2.8)
	await _visit("A 点与宫殿", "Default、Triple、Tetris 与 A1 门拱的当前表现", Vector2(1140, 1270), 1.28, 3.0, 3.0)
	await _visit("当前 Mirage 2D 全图", "自动镜头录制 · 地图场景总览，不代表玩家可见范围", Vector2(960, 855), 0.43, 3.2, 2.5)
	print("MAP_TOUR_COMPLETE: unchanged production map, scripted observation camera")
	get_tree().quit()

func _visit(title: String, description: String, location: Vector2, magnification: float, travel: float, hold: float) -> void:
	heading.text = title
	detail.text = description
	var movement := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	movement.tween_property(camera, "position", location, travel)
	movement.tween_property(camera, "zoom", Vector2.ONE * magnification, travel)
	await movement.finished
	await get_tree().create_timer(hold).timeout
