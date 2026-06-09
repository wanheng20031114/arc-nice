extends Node2D
class_name XirangDrop

@export var config: XirangDropConfig = preload("res://resources/config/xirang_drop.tres")

@onready var sprite: Sprite2D = $Sprite2D
@onready var amount_label: Label = $AmountLabel

var xirang_value: int = 1
var target_player: Player = null
var is_attracting: bool = false
var is_collected: bool = false
var can_detect_player: bool = false
var movement_tween: Tween = null


func _ready() -> void:
	amount_label.visible = false
	set_process(false)
	_apply_config_to_visual()


func _process(_delta: float) -> void:
	if not can_detect_player or is_attracting or is_collected:
		return
	if not is_instance_valid(target_player):
		return

	var attraction_radius_squared := config.attraction_radius * config.attraction_radius
	if global_position.distance_squared_to(target_player.global_position) <= attraction_radius_squared:
		_start_attraction()


func setup(amount: int, player: Player, spawn_position: Vector2, landing_offset: Vector2) -> void:
	xirang_value = maxi(amount, 1)
	target_player = player
	global_position = spawn_position
	_play_scatter_motion(landing_offset)


func _play_scatter_motion(landing_offset: Vector2) -> void:
	if config == null:
		return

	sprite.scale = config.icon_scale * config.spawn_scale_multiplier
	var landing_position := global_position + landing_offset
	movement_tween = create_tween().set_parallel(true)
	movement_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	movement_tween.tween_property(self, "global_position", landing_position, config.scatter_duration)
	movement_tween.tween_property(
		sprite,
		"scale",
		config.icon_scale,
		config.scatter_duration * 0.7
	)
	movement_tween.finished.connect(_enable_attraction_detection)


func _enable_attraction_detection() -> void:
	if is_collected:
		return

	can_detect_player = true
	set_process(true)
	if is_instance_valid(target_player):
		var attraction_radius_squared := config.attraction_radius * config.attraction_radius
		if global_position.distance_squared_to(target_player.global_position) <= attraction_radius_squared:
			_start_attraction()


func _start_attraction() -> void:
	if is_attracting or is_collected:
		return

	is_attracting = true
	can_detect_player = false
	set_process(false)

	if movement_tween != null:
		movement_tween.kill()

	movement_tween = create_tween()
	movement_tween.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	movement_tween.tween_method(
		_move_toward_player,
		0.0,
		1.0,
		config.attraction_duration
	)
	movement_tween.tween_callback(_collect)


func _move_toward_player(progress: float) -> void:
	if not is_instance_valid(target_player):
		if movement_tween != null:
			movement_tween.kill()
		queue_free()
		return

	global_position = global_position.lerp(target_player.global_position, progress)


func _collect() -> void:
	if is_collected:
		return
	if not is_instance_valid(target_player):
		queue_free()
		return

	is_collected = true
	target_player.add_xirang(xirang_value)
	amount_label.text = "+%d" % xirang_value
	amount_label.visible = true
	amount_label.modulate.a = 1.0

	var feedback_tween := create_tween().set_parallel(true)
	feedback_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	feedback_tween.tween_property(sprite, "scale", Vector2.ZERO, 0.1)
	feedback_tween.tween_property(
		amount_label,
		"position:y",
		amount_label.position.y - config.label_rise_distance,
		0.42
	)
	feedback_tween.tween_property(
		amount_label,
		"modulate:a",
		0.0,
		config.label_fade_duration
	).set_delay(0.1)
	feedback_tween.finished.connect(queue_free)


func _apply_config_to_visual() -> void:
	if config == null:
		push_warning("Xirang drop config is missing.")
		set_process(false)
		return

	sprite.texture = config.icon_texture
	sprite.scale = config.icon_scale
