extends Control
class_name UpgradeProgressBlock

enum State {
	EMPTY,
	COMPLETED,
	AFFORDABLE,
}

const EMPTY_COLOR := Color(0.09, 0.105, 0.11, 1.0)
const PULSE_MIN_ALPHA := 0.18
const PULSE_MAX_ALPHA := 1.0
const PULSE_MIN_SCALE := Vector2(0.9, 0.9)
const PULSE_MAX_SCALE := Vector2(1.12, 1.12)
const PULSE_HALF_DURATION := 0.9

@onready var glow_panel: Panel = $Glow
@onready var core_panel: Panel = $Core

var pulse_tween: Tween
var glow_style: StyleBoxFlat
var core_style: StyleBoxFlat


func _ready() -> void:
	glow_style = glow_panel.get_theme_stylebox("panel").duplicate()
	core_style = core_panel.get_theme_stylebox("panel").duplicate()
	glow_panel.add_theme_stylebox_override("panel", glow_style)
	core_panel.add_theme_stylebox_override("panel", core_style)
	glow_panel.pivot_offset = glow_panel.size * 0.5
	set_state(State.EMPTY, Color.WHITE)


func set_state(state: State, accent_color: Color) -> void:
	if pulse_tween != null:
		pulse_tween.kill()
		pulse_tween = null

	_configure_accent(accent_color)
	glow_panel.modulate.a = 1.0
	glow_panel.scale = Vector2.ONE

	match state:
		State.COMPLETED:
			glow_panel.visible = true
			var solid_color := accent_color.darkened(0.08)
			core_style.bg_color = solid_color
			core_style.border_color = solid_color
			glow_style.bg_color = Color(
				accent_color.r,
				accent_color.g,
				accent_color.b,
				0.18,
			)
			glow_style.border_color = Color.TRANSPARENT
			glow_style.shadow_color = Color(
				accent_color.r,
				accent_color.g,
				accent_color.b,
				0.58,
			)
		State.AFFORDABLE:
			glow_panel.visible = true
			core_style.bg_color = EMPTY_COLOR
			core_style.border_color = accent_color.darkened(0.22)
			_configure_affordable_glow(accent_color)
			glow_panel.modulate.a = PULSE_MIN_ALPHA
			glow_panel.scale = PULSE_MIN_SCALE
			pulse_tween = create_tween().bind_node(self).set_loops()
			pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			pulse_tween.tween_property(
				glow_panel,
				"modulate:a",
				PULSE_MAX_ALPHA,
				PULSE_HALF_DURATION,
			)
			pulse_tween.parallel().tween_property(
				glow_panel,
				"scale",
				PULSE_MAX_SCALE,
				PULSE_HALF_DURATION,
			)
			pulse_tween.tween_property(
				glow_panel,
				"modulate:a",
				PULSE_MIN_ALPHA,
				PULSE_HALF_DURATION,
			)
			pulse_tween.parallel().tween_property(
				glow_panel,
				"scale",
				PULSE_MIN_SCALE,
				PULSE_HALF_DURATION,
			)
		_:
			glow_panel.visible = false
			core_style.bg_color = EMPTY_COLOR
			core_style.border_color = Color(0.16, 0.18, 0.18, 1.0)


func _configure_accent(accent_color: Color) -> void:
	glow_style.shadow_color = Color(
		accent_color.r,
		accent_color.g,
		accent_color.b,
		0.78,
	)


func _configure_affordable_glow(accent_color: Color) -> void:
	glow_style.bg_color = Color(
		accent_color.r,
		accent_color.g,
		accent_color.b,
		0.34,
	)
	glow_style.border_color = Color(
		accent_color.r,
		accent_color.g,
		accent_color.b,
		0.92,
	)
