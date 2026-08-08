extends PanelContainer
class_name RogueRouteTopBar

const CORE_NORMAL_COLOR := Color(0.42, 0.82, 1.0, 1.0)
const CORE_CRITICAL_COLOR := Color(1.0, 0.31, 0.28, 1.0)
const CORE_DAMAGE_FLASH_COLOR := Color(1.32, 0.58, 0.52, 1.0)
const CORE_DAMAGE_FLASH_SECONDS := 0.42

@onready var core_stat: VBoxContainer = $TopLayout/CoreStat
@onready var core_value: Label = %CoreValue
@onready var core_progress: ProgressBar = %CoreProgress
@onready var action_points_value: Label = %ActionPointsValue
@onready var light_stone_value: Label = %LightStoneValue
@onready var xirang_value: Label = %XirangValue
@onready var floor_title: Label = $TopLayout/TitleBlock/Title

var _core_damage_tween: Tween = null
var _cached_core_current := -1


func _exit_tree() -> void:
	if _core_damage_tween != null:
		_core_damage_tween.kill()
		_core_damage_tween = null


func set_floor_title(title: String) -> void:
	floor_title.text = title.strip_edges()


func set_action_points(amount: int) -> void:
	action_points_value.text = "—" if amount < 0 else str(amount)


func set_shared_light_stone(amount: int) -> void:
	light_stone_value.text = str(maxi(amount, 0))


func set_personal_xirang(amount: int) -> void:
	xirang_value.text = str(maxi(amount, 0))


func set_core_health(current_health: int, maximum_health: int) -> void:
	var safe_maximum := maxi(maximum_health, 1)
	var safe_current := clampi(current_health, 0, safe_maximum)
	var was_damaged := _cached_core_current >= 0 and safe_current < _cached_core_current
	_cached_core_current = safe_current
	core_value.text = "%d/%d" % [safe_current, safe_maximum]
	core_progress.max_value = float(safe_maximum)
	core_progress.value = float(safe_current)
	var ratio := float(safe_current) / float(safe_maximum)
	core_value.add_theme_color_override(
		&"font_color",
		CORE_CRITICAL_COLOR if ratio <= 0.25 else CORE_NORMAL_COLOR
	)
	if was_damaged:
		_pulse_core_damage()


func _pulse_core_damage() -> void:
	if _core_damage_tween != null:
		_core_damage_tween.kill()
	core_stat.self_modulate = CORE_DAMAGE_FLASH_COLOR
	_core_damage_tween = create_tween()
	_core_damage_tween.tween_property(
		core_stat,
		"self_modulate",
		Color.WHITE,
		CORE_DAMAGE_FLASH_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_core_damage_tween.finished.connect(
		func() -> void: _core_damage_tween = null,
		CONNECT_ONE_SHOT
	)
