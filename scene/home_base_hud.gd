extends CanvasLayer
class_name HomeBaseHUD

const NORMAL_TEXT_COLOR := Color(0.78, 0.91, 1.0, 1.0)
const LOW_HEALTH_TEXT_COLOR := Color(1.0, 0.48, 0.34, 1.0)
const DAMAGE_FLASH_COLOR := Color(1.0, 0.26, 0.2, 1.0)

@onready var panel: PanelContainer = $TopLeftMargin/BasePanel
@onready var health_label: Label = $TopLeftMargin/BasePanel/ContentMargin/Content/Health

var current_health: int = -1
var maximum_health: int = 1
var damage_tween: Tween = null


func set_base_health(new_current: int, new_maximum: int) -> void:
	var safe_maximum := maxi(new_maximum, 1)
	var safe_current := clampi(new_current, 0, safe_maximum)
	var took_damage := current_health >= 0 and safe_current < current_health
	current_health = safe_current
	maximum_health = safe_maximum
	health_label.text = "基地 %d/%d" % [current_health, maximum_health]
	var resting_color := _get_resting_text_color()
	if took_damage:
		_play_damage_flash(resting_color)
	else:
		_stop_damage_tween()
		health_label.modulate = resting_color
		panel.self_modulate = Color.WHITE


func _get_resting_text_color() -> Color:
	return (
		LOW_HEALTH_TEXT_COLOR
		if current_health * 4 <= maximum_health
		else NORMAL_TEXT_COLOR
	)


func _play_damage_flash(resting_color: Color) -> void:
	_stop_damage_tween()
	health_label.modulate = DAMAGE_FLASH_COLOR
	panel.self_modulate = Color(1.18, 0.68, 0.62, 1.0)
	damage_tween = create_tween().set_parallel(true)
	damage_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	damage_tween.tween_property(health_label, "modulate", resting_color, 0.28)
	damage_tween.tween_property(panel, "self_modulate", Color.WHITE, 0.28)


func _stop_damage_tween() -> void:
	if damage_tween != null:
		damage_tween.kill()
		damage_tween = null
