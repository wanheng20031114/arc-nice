extends Node2D
class_name DamageNumber

const DAMAGE_FONT := preload("res://resources/font/ResourceHanRoundedCN-Medium.ttf")
const GROUP_NAME := &"damage_numbers"
const BASE_SIZE := Vector2(32.0, 16.0)
const LIFETIME := 0.72
const FONT_SIZE := 9
const FONT_COLOR := Color(1.0, 0.12, 0.09, 1.0)
const OUTLINE_COLOR := Color(0.28, 0.02, 0.02, 0.98)
const OUTLINE_SIZE := 2

var label: Label = null


func _ready() -> void:
	add_to_group(GROUP_NAME)


func setup(amount: int, spawn_position: Vector2, impact_direction: Vector2 = Vector2.ZERO) -> void:
	global_position = spawn_position + Vector2(randf_range(-2.0, 2.0), -9.0)
	z_index = 100
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	label.text = str(maxi(amount, 0))
	label.size = BASE_SIZE
	label.position = Vector2(-BASE_SIZE.x * 0.5, -BASE_SIZE.y * 0.5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", DAMAGE_FONT)
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", FONT_COLOR)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	add_child(label)

	var horizontal_sign := 0.0
	if not is_zero_approx(impact_direction.x):
		horizontal_sign = signf(impact_direction.x)
	else:
		horizontal_sign = -1.0 if randf() < 0.5 else 1.0
	var float_offset := Vector2(horizontal_sign * randf_range(4.0, 8.0), -14.0)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position", position + float_offset, LIFETIME).set_trans(Tween.TRANS_CIRC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2(1.08, 1.08), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2.ONE, 0.22).set_delay(0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.22).set_delay(0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(queue_free)
