extends Node2D
class_name DamageNumber

signal finished(number: DamageNumber)

const DAMAGE_FONT := preload("res://resources/font/ResourceHanRoundedCN-Medium.ttf")
const GROUP_NAME := &"damage_numbers"
const BASE_SIZE := Vector2(38.0, 20.0)
const LIFETIME := 0.72
const FONT_SIZE := 9
const FONT_COLOR := Color(1.0, 0.12, 0.09, 1.0)
const OUTLINE_COLOR := Color(0.28, 0.02, 0.02, 0.98)
const MAGIC_FONT_COLOR := Color(0.74, 0.34, 1.0, 1.0)
const MAGIC_OUTLINE_COLOR := Color(0.16, 0.04, 0.30, 0.98)
const OUTLINE_SIZE := 2

var label: Label = null
var active: bool = false
var elapsed: float = 0.0
var start_global_position := Vector2.ZERO
var float_offset := Vector2.ZERO


func _ready() -> void:
	_ensure_label()
	_deactivate(false)
	set_process(false)


func setup(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> void:
	_ensure_label()
	active = true
	elapsed = 0.0
	visible = true
	set_process(true)
	if not is_in_group(GROUP_NAME):
		add_to_group(GROUP_NAME)

	global_position = spawn_position + Vector2(randf_range(-2.0, 2.0), -9.0)
	start_global_position = global_position
	z_index = 100
	label.text = str(maxi(amount, 0))
	_apply_damage_type_style(damage_type)
	label.modulate = Color.WHITE
	modulate = Color.WHITE
	scale = Vector2.ONE

	var horizontal_sign := 0.0
	if not is_zero_approx(impact_direction.x):
		horizontal_sign = signf(impact_direction.x)
	else:
		horizontal_sign = -1.0 if randf() < 0.5 else 1.0
	float_offset = Vector2(horizontal_sign * randf_range(4.0, 8.0), -14.0)


func _apply_damage_type_style(damage_type: EnemyConfig.DamageType) -> void:
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			label.add_theme_color_override("font_color", MAGIC_FONT_COLOR)
			label.add_theme_color_override("font_outline_color", MAGIC_OUTLINE_COLOR)
		_:
			label.add_theme_color_override("font_color", FONT_COLOR)
			label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)


func is_active() -> bool:
	return active


func get_active_elapsed() -> float:
	return elapsed


func _process(delta: float) -> void:
	if not active:
		return

	elapsed += delta
	var progress := clampf(elapsed / LIFETIME, 0.0, 1.0)
	global_position = start_global_position + float_offset * _ease_out_circ(progress)

	scale = Vector2.ONE
	if elapsed < 0.12:
		var pop_progress := clampf(elapsed / 0.12, 0.0, 1.0)
		label.modulate = Color.WHITE.lerp(
			Color(1.35, 1.35, 1.35, 1.0),
			_ease_out_back(pop_progress)
		)
	elif elapsed < 0.34:
		var settle_progress := clampf((elapsed - 0.12) / 0.22, 0.0, 1.0)
		label.modulate = Color(1.35, 1.35, 1.35, 1.0).lerp(
			Color.WHITE,
			_ease_out_sine(settle_progress)
		)
	else:
		label.modulate = Color.WHITE

	if elapsed > 0.5:
		var fade_progress := clampf((elapsed - 0.5) / 0.22, 0.0, 1.0)
		modulate.a = 1.0 - _ease_out_sine(fade_progress)

	if elapsed >= LIFETIME:
		_deactivate()


func _ensure_label() -> void:
	if label != null:
		return
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
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


func _deactivate(emit_finished: bool = true) -> void:
	active = false
	visible = false
	elapsed = 0.0
	modulate = Color(1.0, 1.0, 1.0, 0.0)
	set_process(false)
	if is_in_group(GROUP_NAME):
		remove_from_group(GROUP_NAME)
	if emit_finished:
		finished.emit(self)


func _ease_out_circ(value: float) -> float:
	return sqrt(1.0 - pow(value - 1.0, 2.0))


func _ease_out_sine(value: float) -> float:
	return sin((value * PI) * 0.5)


func _ease_out_back(value: float) -> float:
	const C1 := 1.70158
	const C3 := C1 + 1.0
	return 1.0 + C3 * pow(value - 1.0, 3.0) + C1 * pow(value - 1.0, 2.0)
